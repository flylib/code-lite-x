import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';
import '../editor/syntax/color_schemes.dart';
import '../editor/syntax/document_highlighter.dart';
import '../editor/syntax/languages.dart';
import '../editor/syntax/tokenizer.dart';
import '../project_explorer/project_explorer_widget.dart' show fileTypeIconWidget;

/// 搜索:查询词 + 选项(`case_sensitive` / `whole_word` / `is_regex` / `max_results` / `file_extension` / `directory`),
/// 返回 `{"status":"ok","matches":[{file_path,line_number,col_start,col_end,line_snippet}]}`(`ApiClient.searchWorkspace`)。
typedef WorkspaceSearch = Future<Map<String, dynamic>> Function(String query, Map<String, dynamic> options);
typedef WorkspaceReplace = Future<Map<String, dynamic>> Function(String query, String replacement, Map<String, dynamic> options);

/// IntelliJ 的 Find in Files(⇧⌘F)/ Replace in Files(⇧⌘R):
/// 顶上是标题、「N 个文件中有 M 处匹配」和文件掩码;下面是输入框(Cc / W / .*)、范围(在项目中 / 目录)、
/// 结果(每行一处,代码带语法颜色、匹配处标黄,右边文件名和行号),底部是选中那处的预览。
/// **边打字边搜**:停下 300 ms 就搜(同 IntelliJ),不用按回车。
class GlobalSearchModal extends StatefulWidget {
  const GlobalSearchModal({
    super.key,
    required this.search,
    required this.onNavigate,
    this.replace,
    this.readFile,
    this.initialQuery,
    this.replaceMode = false,
    this.currentDirectory,
    this.pickDirectory,
    this.colorScheme,
    this.debounce = const Duration(milliseconds: 300),
  });

  final WorkspaceSearch search;
  final WorkspaceReplace? replace;

  /// 读文件(预览用);[path] 是搜索结果里的路径(相对项目)。
  final Future<String?> Function(String path)? readFile;

  /// 打开结果:[line] / [column] 从 0 起。
  final void Function(String filePath, int line, int column) onNavigate;

  /// 带进输入框的文字(编辑器里选中的一行之内的文字);null 用上次搜的。
  final String? initialQuery;
  final bool replaceMode;

  /// 「目录」范围的默认值:当前文件所在目录(相对项目)。
  final String? currentDirectory;

  /// 「目录」旁边的浏览按钮;返回相对项目的目录,取消返回 null。
  final Future<String?> Function()? pickDirectory;
  final EditorColorScheme? colorScheme;
  final Duration debounce;

  static Future<void> show(
    BuildContext context, {
    required WorkspaceSearch search,
    required void Function(String filePath, int line, int column) onNavigate,
    WorkspaceReplace? replace,
    Future<String?> Function(String path)? readFile,
    String? initialQuery,
    bool replaceMode = false,
    String? currentDirectory,
    Future<String?> Function()? pickDirectory,
    EditorColorScheme? colorScheme,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black26,
      builder: (ctx) => GlobalSearchModal(
        search: search,
        onNavigate: onNavigate,
        replace: replace,
        readFile: readFile,
        initialQuery: initialQuery,
        replaceMode: replaceMode,
        currentDirectory: currentDirectory,
        pickDirectory: pickDirectory,
        colorScheme: colorScheme,
      ),
    );
  }

  @override
  State<GlobalSearchModal> createState() => _GlobalSearchModalState();
}

/// 一行结果:同一行的几处匹配合成一行,全部标黄。
class _Hit {
  _Hit(this.path, this.line, this.snippet);

  final String path;

  /// 从 1 起(和搜索结果一致)。
  final int line;
  final String snippet;
  final List<(int, int)> cols = [];

  String get fileName => path.substring(path.lastIndexOf('/') + 1);
  String get dir => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
}

enum _Scope { project, directory }

class _GlobalSearchModalState extends State<GlobalSearchModal> {
  // 关了再开记得上次的(同 IntelliJ)
  static String _lastQuery = '';
  static bool _lastCase = false, _lastWord = false, _lastRegex = false;
  static bool _lastMaskOn = false;
  static String _lastMask = '*.java';

  static const int _maxResults = 1000;
  static const double _rowHeight = 26;

  late final TextEditingController _query = TextEditingController(text: widget.initialQuery ?? _lastQuery);
  final TextEditingController _replaceText = TextEditingController();
  late final TextEditingController _mask = TextEditingController(text: _lastMask);
  late final TextEditingController _directory = TextEditingController(text: widget.currentDirectory ?? '');
  final FocusNode _queryFocus = FocusNode();
  final ScrollController _scroll = ScrollController();
  final ScrollController _previewScroll = ScrollController();

  late bool _caseSensitive = _lastCase, _wholeWord = _lastWord, _regex = _lastRegex, _maskOn = _lastMaskOn;
  late bool _replaceMode = widget.replaceMode;
  _Scope _scope = _Scope.project;

  List<_Hit> _hits = const [];
  int _total = 0;
  bool _truncated = false;
  bool _searching = false;
  String? _error;
  int _selected = 0;
  int _generation = 0;
  Timer? _debounce;

  /// 预览:当前文件的行和每行起始的分词状态。
  String? _previewPath;
  List<String> _previewLines = const [];
  List<int> _previewStates = const [];

  @override
  void initState() {
    super.initState();
    _query.selection = TextSelection(baseOffset: 0, extentOffset: _query.text.length);
    _query.addListener(_onQueryChanged);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _queryFocus.requestFocus();
    });
    if (_query.text.trim().isNotEmpty) _runSearch();
  }

  @override
  void dispose() {
    _debounce?.cancel();
    _lastQuery = _query.text;
    _lastCase = _caseSensitive;
    _lastWord = _wholeWord;
    _lastRegex = _regex;
    _lastMaskOn = _maskOn;
    _lastMask = _mask.text;
    _query.dispose();
    _replaceText.dispose();
    _mask.dispose();
    _directory.dispose();
    _queryFocus.dispose();
    _scroll.dispose();
    _previewScroll.dispose();
    super.dispose();
  }

  String _lastSeenQuery = '';

  void _onQueryChanged() {
    if (_query.text == _lastSeenQuery) return; // 只是选区变了
    _lastSeenQuery = _query.text;
    _schedule();
  }

  /// 停下 [GlobalSearchModal.debounce] 再搜(连续打字只搜最后一次)。
  void _schedule() {
    _debounce?.cancel();
    _debounce = Timer(widget.debounce, _runSearch);
  }

  /// 文件掩码 → 搜索选项里的单个扩展名(`*.java`);多个掩码(`*.java, *.kt`)返回 null,结果出来再筛。
  String? get _singleExtension {
    if (!_maskOn) return null;
    final parts = _maskPatterns;
    if (parts.length != 1) return null;
    final m = RegExp(r'^\*\.([\w.+-]+)$').firstMatch(parts.single);
    return m?.group(1);
  }

  List<String> get _maskPatterns => [for (final p in _mask.text.split(',')) if (p.trim().isNotEmpty) p.trim()];

  bool _maskAccepts(String path) {
    if (!_maskOn || _maskPatterns.isEmpty) return true;
    final name = path.substring(path.lastIndexOf('/') + 1);
    var include = false, anyInclude = false;
    for (final p in _maskPatterns) {
      final negate = p.startsWith('!');
      final glob = negate ? p.substring(1) : p;
      final re = RegExp('^${RegExp.escape(glob).replaceAll(r'\*', '.*').replaceAll(r'\?', '.')}\$', caseSensitive: false);
      if (negate) {
        if (re.hasMatch(name)) return false;
      } else {
        anyInclude = true;
        if (re.hasMatch(name)) include = true;
      }
    }
    return !anyInclude || include;
  }

  Map<String, dynamic> get _options => {
        'case_sensitive': _caseSensitive,
        'whole_word': _wholeWord,
        'is_regex': _regex,
        'max_results': _maxResults,
        if (_singleExtension case final ext?) 'file_extension': ext,
        if (_scope == _Scope.directory && _directory.text.trim().isNotEmpty) 'directory': _directory.text.trim().replaceAll(RegExp(r'^/+|/+$'), ''),
      };

  Future<void> _runSearch() async {
    _debounce?.cancel();
    final q = _query.text;
    final gen = ++_generation;
    if (q.trim().isEmpty) {
      setState(() {
        _hits = const [];
        _total = 0;
        _error = null;
        _searching = false;
      });
      return;
    }
    setState(() => _searching = true);
    final res = await widget.search(q, _options);
    if (!mounted || gen != _generation) return;
    if (res['status'] == 'error') {
      setState(() {
        _error = res['error'] as String? ?? tr('搜索失败', 'Search failed');
        _hits = const [];
        _total = 0;
        _searching = false;
      });
      return;
    }
    final byLine = <String, _Hit>{};
    var total = 0;
    for (final raw in (res['matches'] as List? ?? const [])) {
      final m = raw as Map;
      final path = m['file_path'] as String? ?? '';
      if (!_maskAccepts(path)) continue;
      final line = (m['line_number'] as num?)?.toInt() ?? 1;
      final hit = byLine.putIfAbsent('$path:$line', () => _Hit(path, line, m['line_snippet'] as String? ?? ''));
      hit.cols.add(((m['col_start'] as num?)?.toInt() ?? 0, (m['col_end'] as num?)?.toInt() ?? 0));
      total++;
    }
    setState(() {
      _hits = byLine.values.toList();
      _total = total;
      _truncated = ((res['matches'] as List?)?.length ?? 0) >= _maxResults;
      _error = null;
      _searching = false;
      _selected = 0;
    });
    if (_scroll.hasClients) _scroll.jumpTo(0);
    _loadPreview();
  }

  Future<void> _replaceAll() async {
    final replace = widget.replace;
    final q = _query.text;
    if (replace == null || q.trim().isEmpty || _hits.isEmpty) return;
    final res = await replace(q, _replaceText.text, _options);
    if (!mounted) return;
    final count = (res['replaced_count'] as num?)?.toInt() ?? 0;
    final failed = res['status'] == 'error';
    setState(() {
      _error = failed ? res['error'] as String? : null;
      _status = failed ? null : tr('已替换 $count 处', 'Replaced $count occurrences');
    });
    if (!failed) await _runSearch();
  }

  String? _status;

  Future<void> _loadPreview() async {
    final read = widget.readFile;
    if (read == null || _hits.isEmpty) return;
    final hit = _hits[_selected.clamp(0, _hits.length - 1)];
    if (hit.path != _previewPath) {
      final path = hit.path;
      final text = await read(path);
      if (!mounted || _hits.isEmpty || _hits[_selected.clamp(0, _hits.length - 1)].path != path) return;
      final lines = (text ?? '').split('\n');
      final lang = languages.detect(path, firstLine: lines.isEmpty ? null : lines.first);
      final states = List<int>.filled(lines.length, 0);
      var state = 0;
      for (var i = 0; i < lines.length; i++) {
        states[i] = state;
        state = tokenizeLine(lang, lines[i], state).endState;
      }
      setState(() {
        _previewPath = path;
        _previewLines = lines;
        _previewStates = states;
      });
    }
    // 预览滚到匹配那一行(放在第 3 行左右)
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!_previewScroll.hasClients) return;
      final target = ((hit.line - 3) * _previewLineHeight).clamp(0.0, _previewScroll.position.maxScrollExtent);
      _previewScroll.jumpTo(target);
    });
    setState(() {});
  }

  static const double _previewLineHeight = 18;

  void _select(int i) {
    if (i < 0 || i >= _hits.length || i == _selected) return;
    setState(() => _selected = i);
    _loadPreview();
  }

  bool _closed = false;

  /// 只打开一次:真实的回车会同时来一个按键事件和输入法的「完成」。
  void _open([int? index]) {
    final i = index ?? _selected;
    if (_closed || i < 0 || i >= _hits.length) return;
    _closed = true;
    final hit = _hits[i];
    Navigator.of(context).pop();
    widget.onNavigate(hit.path, hit.line - 1, hit.cols.isEmpty ? 0 : hit.cols.first.$1);
  }

  void _move(int delta) {
    if (_hits.isEmpty) return;
    _select((_selected + delta).clamp(0, _hits.length - 1));
    if (!_scroll.hasClients) return;
    final top = _selected * _rowHeight;
    final pos = _scroll.position;
    if (top < pos.pixels) {
      _scroll.jumpTo(top);
    } else if (top + _rowHeight > pos.pixels + pos.viewportDimension) {
      _scroll.jumpTo(top + _rowHeight - pos.viewportDimension);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final k = e.logicalKey;
    if (k == LogicalKeyboardKey.arrowDown) {
      _move(1);
    } else if (k == LogicalKeyboardKey.arrowUp) {
      _move(-1);
    } else if (k == LogicalKeyboardKey.pageDown) {
      _move(10);
    } else if (k == LogicalKeyboardKey.pageUp) {
      _move(-10);
    } else if ((k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) && _queryFocus.hasPrimaryFocus) {
      _open();
    } else if (k == LogicalKeyboardKey.escape) {
      Navigator.of(context).pop();
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  void _toggle(void Function() change) {
    setState(change);
    _runSearch();
  }

  @override
  Widget build(BuildContext context) {
    final scheme = widget.colorScheme ?? islandsDarkScheme;
    final files = {for (final h in _hits) h.path}.length;
    final summary = _query.text.trim().isEmpty
        ? ''
        : _searching && _hits.isEmpty
            ? tr('正在搜索…', 'Searching…')
            : tr('${_truncated ? '$_total+' : _total} 处匹配,共 $files 个文件', '${_truncated ? '$_total+' : _total} matches in $files files');
    final selected = _hits.isEmpty ? null : _hits[_selected.clamp(0, _hits.length - 1)];
    final size = MediaQuery.sizeOf(context);
    return Align(
      alignment: const Alignment(0, -0.3),
      child: Focus(
        onKeyEvent: _onKey,
        child: Material(
            color: IntelliJTheme.popupBg,
            elevation: 12,
            borderRadius: BorderRadius.circular(8),
            clipBehavior: Clip.antiAlias,
            child: SizedBox(
              width: (size.width - 80).clamp(560.0, 900.0),
              height: (size.height - 80).clamp(420.0, 720.0),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(summary),
                  _inputRow(),
                  if (_replaceMode) _replaceRow(),
                  _scopeRow(),
                  Expanded(flex: 5, child: _results(scheme)),
                  const Divider(height: 1, thickness: 1, color: IntelliJTheme.border),
                  _locationBar(selected),
                  Expanded(flex: 4, child: _preview(scheme, selected)),
                ],
              ),
            ),
          ),
      ),
    );
  }

  Widget _header(String summary) {
    return Container(
      height: 44,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: IntelliJTheme.border))),
      child: Row(
        children: [
          Text(
            _replaceMode ? tr('在文件中替换', 'Replace in Files') : tr('在文件中查找', 'Find in Files'),
            style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13.5, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Text(summary,
                key: const ValueKey('find-summary'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12.5)),
          ),
          // 文件掩码:勾上才生效
          InkWell(
            key: const ValueKey('find-mask-toggle'),
            onTap: () => _toggle(() => _maskOn = !_maskOn),
            borderRadius: BorderRadius.circular(4),
            child: Padding(
              padding: const EdgeInsets.all(4),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  _checkbox(_maskOn),
                  const SizedBox(width: 6),
                  Text(tr('文件掩码:', 'File mask:'), style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12.5)),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          SizedBox(
            width: 130,
            height: 28,
            child: TextField(
              key: const ValueKey('find-mask'),
              controller: _mask,
              enabled: _maskOn,
              onChanged: (_) => _schedule(),
              style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5),
              cursorColor: IntelliJTheme.caret,
              decoration: _boxDecoration(hint: '*.java'),
            ),
          ),
          PopupMenuButton<String>(
            tooltip: tr('常用掩码', 'Recent masks'),
            enabled: _maskOn,
            padding: EdgeInsets.zero,
            icon: const Icon(Icons.expand_more, size: 16, color: IntelliJTheme.textSecondary),
            color: IntelliJTheme.popupBg,
            onSelected: (m) {
              _mask.text = m;
              _runSearch();
            },
            itemBuilder: (_) => [
              for (final m in const ['*.java', '*.kt', '*.xml', '*.yml, *.yaml', '*.properties', '*.sql', '*.md', '*.dart', '*.ts, *.tsx', '*.js', '*.go', '*.py', '*.rs'])
                PopupMenuItem(value: m, height: 30, child: Text(m, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5))),
            ],
          ),
          if (widget.replace != null)
            _iconToggle(
              key: const ValueKey('find-replace-toggle'),
              icon: Icons.find_replace,
              tooltip: _replaceMode ? tr('切换到在文件中查找', 'Switch to Find in Files') : tr('切换到在文件中替换', 'Switch to Replace in Files'),
              active: _replaceMode,
              onTap: () => setState(() => _replaceMode = !_replaceMode),
            ),
        ],
      ),
    );
  }

  Widget _inputRow() {
    final bad = _error != null && _regex;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
      child: Row(
        children: [
          const Icon(Icons.search, size: 18, color: IntelliJTheme.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('find-query'),
              controller: _query,
              focusNode: _queryFocus,
              onSubmitted: (_) => _open(),
              style: TextStyle(color: bad ? IntelliJTheme.diagError : IntelliJTheme.textHigh, fontSize: 14),
              cursorColor: IntelliJTheme.caret,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: tr('要查找的文字', 'Text to find'),
                hintStyle: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 14),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          if (_query.text.isNotEmpty)
            _iconToggle(
              icon: Icons.close,
              tooltip: tr('清除', 'Clear'),
              active: false,
              onTap: () {
                _query.clear();
                _queryFocus.requestFocus();
              },
            ),
          const SizedBox(width: 6),
          _textToggle('Cc', tr('区分大小写', 'Match Case'), _caseSensitive, () => _toggle(() => _caseSensitive = !_caseSensitive)),
          _textToggle('W', tr('全字', 'Words'), _wholeWord, () => _toggle(() => _wholeWord = !_wholeWord)),
          _textToggle('.*', tr('正则表达式', 'Regex'), _regex, () => _toggle(() => _regex = !_regex)),
        ],
      ),
    );
  }

  Widget _replaceRow() {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 4),
      child: Row(
        children: [
          const Icon(Icons.find_replace, size: 18, color: IntelliJTheme.textMuted),
          const SizedBox(width: 8),
          Expanded(
            child: TextField(
              key: const ValueKey('find-replace'),
              controller: _replaceText,
              style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 14),
              cursorColor: IntelliJTheme.caret,
              decoration: InputDecoration(
                isDense: true,
                border: InputBorder.none,
                hintText: tr('替换为', 'Replace with'),
                hintStyle: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 14),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
          TextButton(
            key: const ValueKey('find-replace-all'),
            onPressed: _hits.isEmpty ? null : _replaceAll,
            child: Text(tr('全部替换', 'Replace All'), style: const TextStyle(fontSize: 12.5)),
          ),
        ],
      ),
    );
  }

  Widget _scopeRow() {
    Widget tab(_Scope s, String label) => Padding(
          padding: const EdgeInsets.only(right: 4),
          child: InkWell(
            key: ValueKey('find-scope-${s.name}'),
            onTap: () => _toggle(() => _scope = s),
            borderRadius: BorderRadius.circular(5),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              decoration: BoxDecoration(color: _scope == s ? IntelliJTheme.stripeActiveBg : null, borderRadius: BorderRadius.circular(5)),
              child: Text(label, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5)),
            ),
          ),
        );
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 4, 12, 6),
      decoration: const BoxDecoration(border: Border(top: BorderSide(color: IntelliJTheme.border))),
      child: Row(
        children: [
          tab(_Scope.project, tr('在项目中', 'In Project')),
          tab(_Scope.directory, tr('目录', 'Directory')),
          if (_scope == _Scope.directory) ...[
            const SizedBox(width: 8),
            Expanded(
              child: SizedBox(
                height: 28,
                child: TextField(
                  key: const ValueKey('find-directory'),
                  controller: _directory,
                  onChanged: (_) => _schedule(),
                  style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5),
                  cursorColor: IntelliJTheme.caret,
                  decoration: _boxDecoration(hint: tr('相对项目的目录', 'Directory relative to the project')),
                ),
              ),
            ),
            if (widget.pickDirectory != null)
              _iconToggle(
                icon: Icons.folder_open_outlined,
                tooltip: tr('选择目录', 'Choose Directory'),
                active: false,
                onTap: () async {
                  final dir = await widget.pickDirectory!();
                  if (dir == null || !mounted) return;
                  _directory.text = dir;
                  _runSearch();
                },
              ),
          ] else
            const Spacer(),
          if (_status != null)
            Padding(
              padding: const EdgeInsets.only(left: 8),
              child: Text(_status!, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12)),
            ),
        ],
      ),
    );
  }

  Widget _results(EditorColorScheme scheme) {
    if (_error != null) {
      return Center(
        child: Text(_error!, key: const ValueKey('find-error'), style: const TextStyle(color: IntelliJTheme.diagError, fontSize: 12.5)),
      );
    }
    if (_hits.isEmpty) {
      final q = _query.text.trim();
      return Center(
        child: Text(
          q.isEmpty ? tr('输入要查找的文字,边输边搜', 'Type to search; results update as you type') : (_searching ? '' : tr('没有找到', 'Nothing found')),
          key: const ValueKey('find-empty'),
          style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12.5),
        ),
      );
    }
    return ListView.builder(
      controller: _scroll,
      itemExtent: _rowHeight,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemCount: _hits.length,
      itemBuilder: (context, i) => _row(_hits[i], i, scheme),
    );
  }

  Widget _row(_Hit hit, int i, EditorColorScheme scheme) {
    final selected = i == _selected;
    return GestureDetector(
      onTap: () => _select(i),
      onDoubleTap: () => _open(i),
      child: Container(
        key: ValueKey('find-hit-${hit.path}:${hit.line}'),
        margin: const EdgeInsets.symmetric(horizontal: 6),
        padding: const EdgeInsets.symmetric(horizontal: 10),
        decoration: BoxDecoration(color: selected ? const Color(0xFF2E436E) : null, borderRadius: BorderRadius.circular(5)),
        child: Row(
          children: [
            Expanded(child: _snippet(hit, scheme)),
            const SizedBox(width: 16),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 320),
              child: Text(
                '${hit.fileName} ${hit.line}',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: selected ? IntelliJTheme.textHigh : IntelliJTheme.textMuted, fontSize: 12.5),
              ),
            ),
          ],
        ),
      ),
    );
  }

  /// 一行代码:按语言着色,再把匹配处衬上 IntelliJ 搜索结果的黄底。
  Widget _snippet(_Hit hit, EditorColorScheme scheme) {
    final lang = languages.detect(hit.path);
    final text = hit.snippet;
    final spans = DocumentHighlighter.spansFor(text, tokenizeLine(lang, text, 0).tokens, scheme);
    final marks = _marksIn(text);
    return Text.rich(
      TextSpan(
        style: TextStyle(color: scheme.foreground, fontSize: 13, fontFamily: 'Menlo', fontFamilyFallback: const ['PingFang SC', 'monospace']),
        children: _withMarks(spans, marks),
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }

  /// 去掉首尾空白后的行里,和查询匹配的那几段(按当前的 Cc / W / .* 重新找一遍)。
  List<(int, int)> _marksIn(String text) {
    final q = _query.text;
    if (q.isEmpty) return const [];
    try {
      var pattern = _regex ? q : RegExp.escape(q);
      if (_wholeWord) pattern = '\\b(?:$pattern)\\b';
      final re = RegExp(pattern, caseSensitive: _caseSensitive);
      return [for (final m in re.allMatches(text)) if (m.end > m.start) (m.start, m.end)];
    } on FormatException {
      return const [];
    }
  }

  static const _matchStyle = TextStyle(backgroundColor: Color(0xFF8A6A2E), color: Color(0xFFF2F2F2));

  /// 把着色后的片段在匹配边界处切开,匹配的部分加黄底。
  List<InlineSpan> _withMarks(List<TextSpan> spans, List<(int, int)> marks) {
    if (marks.isEmpty) return spans;
    final out = <InlineSpan>[];
    var pos = 0;
    for (final s in spans) {
      final t = s.text ?? '';
      var i = 0;
      while (i < t.length) {
        final at = pos + i;
        final inMark = marks.where((m) => m.$1 <= at && at < m.$2).firstOrNull;
        int end;
        if (inMark != null) {
          end = (inMark.$2 - pos).clamp(i + 1, t.length);
        } else {
          final next = marks.where((m) => m.$1 > at).map((m) => m.$1).fold<int?>(null, (a, b) => a == null || b < a ? b : a);
          end = next == null ? t.length : (next - pos).clamp(i + 1, t.length);
        }
        final piece = t.substring(i, end);
        out.add(TextSpan(text: piece, style: inMark == null ? s.style : (s.style ?? const TextStyle()).merge(_matchStyle)));
        i = end;
      }
      pos += t.length;
    }
    return out;
  }

  Widget _locationBar(_Hit? hit) {
    return Container(
      height: 30,
      padding: const EdgeInsets.symmetric(horizontal: 16),
      alignment: Alignment.centerLeft,
      child: hit == null
          ? null
          : Row(
              children: [
                fileTypeIconWidget(hit.fileName, size: 14),
                const SizedBox(width: 6),
                Text(hit.fileName, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(hit.dir,
                      key: const ValueKey('find-location'),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12.5)),
                ),
              ],
            ),
    );
  }

  /// 底部预览:选中那处所在的文件,匹配的那一行高亮,匹配处黄底。
  Widget _preview(EditorColorScheme scheme, _Hit? hit) {
    if (hit == null || widget.readFile == null || _previewPath != hit.path) {
      return Container(color: IntelliJTheme.editorBg);
    }
    final lang = languages.detect(hit.path, firstLine: _previewLines.isEmpty ? null : _previewLines.first);
    final style = TextStyle(color: scheme.foreground, fontSize: 12.5, height: 1.3, fontFamily: 'Menlo', fontFamilyFallback: const ['PingFang SC', 'monospace']);
    return Container(
      key: const ValueKey('find-preview'),
      color: IntelliJTheme.editorBg,
      child: ListView.builder(
        controller: _previewScroll,
        itemExtent: _previewLineHeight,
        padding: const EdgeInsets.symmetric(vertical: 4),
        itemCount: _previewLines.length,
        itemBuilder: (context, i) {
          final line = _previewLines[i];
          final current = i == hit.line - 1;
          var spans = DocumentHighlighter.spansFor(line, tokenizeLine(lang, line, _previewStates[i]).tokens, scheme);
          return Container(
            color: current ? IntelliJTheme.currentLineBg : null,
            padding: const EdgeInsets.only(right: 12),
            child: Row(
              children: [
                SizedBox(
                  width: 48,
                  child: Text('${i + 1}',
                      textAlign: TextAlign.right, style: TextStyle(color: current ? IntelliJTheme.lineNumberCurrent : IntelliJTheme.lineNumber, fontSize: 11.5)),
                ),
                const SizedBox(width: 14),
                Expanded(
                  child: Text.rich(
                    TextSpan(style: style, children: current ? _withMarks(spans, [for (final c in hit.cols) (c.$1, c.$2)]) : spans),
                    maxLines: 1,
                    softWrap: false,
                    overflow: TextOverflow.clip,
                  ),
                ),
              ],
            ),
          );
        },
      ),
    );
  }

  InputDecoration _boxDecoration({String? hint}) => InputDecoration(
        isDense: true,
        hintText: hint,
        hintStyle: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12.5),
        filled: true,
        fillColor: IntelliJTheme.islandBg,
        contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 7),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: const BorderSide(color: IntelliJTheme.border)),
        enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: const BorderSide(color: IntelliJTheme.border)),
        disabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: const BorderSide(color: IntelliJTheme.borderSubtle)),
        focusedBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: const BorderSide(color: IntelliJTheme.accentBlue)),
      );

  Widget _checkbox(bool on) => Container(
        width: 14,
        height: 14,
        decoration: BoxDecoration(
          color: on ? IntelliJTheme.accentBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: on ? IntelliJTheme.accentBlue : IntelliJTheme.textMuted),
        ),
        child: on ? const Icon(Icons.check, size: 12, color: Colors.white) : null,
      );

  Widget _textToggle(String label, String tooltip, bool active, VoidCallback onTap) => Tooltip(
        message: tooltip,
        child: InkWell(
          key: ValueKey('find-toggle-$label'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: 30,
            height: 26,
            alignment: Alignment.center,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(
              color: active ? IntelliJTheme.accentBlue.withValues(alpha: 0.25) : null,
              borderRadius: BorderRadius.circular(4),
              border: Border.all(color: active ? IntelliJTheme.accentBlue : Colors.transparent),
            ),
            child: Text(label, style: TextStyle(color: active ? IntelliJTheme.textHigh : IntelliJTheme.textSecondary, fontSize: 13, fontWeight: FontWeight.w600)),
          ),
        ),
      );

  Widget _iconToggle({Key? key, required IconData icon, required String tooltip, required bool active, required VoidCallback onTap}) => Tooltip(
        message: tooltip,
        child: InkWell(
          key: key,
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            margin: const EdgeInsets.only(left: 2),
            decoration: BoxDecoration(color: active ? IntelliJTheme.accentBlue.withValues(alpha: 0.25) : null, borderRadius: BorderRadius.circular(4)),
            child: Icon(icon, size: 16, color: IntelliJTheme.textSecondary),
          ),
        ),
      );
}
