import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/github/github_service.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';
import '../commit/diff_cells.dart';
import '../commit/line_diff.dart';
import '../editor/context_menu_region.dart' show darculaMenuTheme;
import 'pr_store.dart';
import 'pr_widgets.dart';

/// 中间:左行号 36 + 间隔 8 + 右行号 36。
const double _gutterWidth = 80;
const double _blameWidth = 170;

/// GitHub 的 PR diff 每段改动带 3 行上下文;只有这些行能发表评审评论。
const int _contextLines = 3;

const Color _selectionBg = Color(0x40589DF6);

/// 「Diff for Pull Request #号」标签:左 merge-base,右 PR head,并排显示;
/// 行内显示评审评论会话。选中行后右键:Compare with Clipboard / Annotate with Git Blame /
/// Add Review Comment (⇧⌘X) / Mark File as Viewed (⇧⌘S)。
class PrDiffTab extends StatefulWidget {
  const PrDiffTab({super.key, required this.session, required this.onOpenLocal});

  final PrSession session;

  /// 打开本地工作区里的同名文件:[repoPath] 相对仓库根,[line] 从 0 起。
  final void Function(String repoPath, int line) onOpenLocal;

  @override
  State<PrDiffTab> createState() => _PrDiffTabState();
}

/// 列表里的一项:一行代码、一段评论会话、或新评论输入框。
sealed class _Entry {
  const _Entry();
}

class _RowEntry extends _Entry {
  const _RowEntry(this.row);
  final int row;
}

class _ThreadEntry extends _Entry {
  const _ThreadEntry(this.thread);
  final List<PrReviewComment> thread;
}

class _ComposerEntry extends _Entry {
  const _ComposerEntry();
}

class _PrDiffTabState extends State<PrDiffTab> {
  final ScrollController _scroll = ScrollController();
  final FocusNode _focus = FocusNode(debugLabel: 'pr-diff');
  final MenuController _menu = MenuController();
  final GlobalKey _anchorKey = GlobalKey();
  final Map<int, GlobalKey> _blockKeys = {};

  String? _path;
  List<String> _left = const [];
  List<String> _right = const [];
  List<DiffRow> _rows = const [];
  List<int> _blocks = const [];
  int _currentBlock = -1;
  Map<int, int> _leftRow = const {};
  Map<int, int> _rightRow = const {};

  /// 能发表评论的行(行下标)。
  Set<int> _commentable = const {};
  bool _loading = true;
  bool _binary = false;
  String? _error;

  // 选区:同一侧的一段连续行。
  String _selSide = 'RIGHT';
  int? _selAnchor;
  int? _selHead;

  // 正在写的新评论:挂在 [_composeRow] 下,覆盖选区 [_composeFrom]..[_composeRow]。
  int? _composeRow;
  int? _composeFrom;
  String _composeSide = 'RIGHT';

  bool _blameOn = false;
  List<PrBlameRange>? _blame;

  PrSession get _session => widget.session;

  @override
  void initState() {
    super.initState();
    _session.addListener(_onSession);
    _session.ensureLoaded();
    _onSession();
  }

  @override
  void didUpdateWidget(PrDiffTab old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_onSession);
      widget.session.addListener(_onSession);
      _path = null;
      _onSession();
    }
  }

  @override
  void dispose() {
    _session.removeListener(_onSession);
    _scroll.dispose();
    _focus.dispose();
    super.dispose();
  }

  void _onSession() {
    if (!mounted) return;
    final want = _session.diffFile;
    if (_session.detail != null && _session.mergeBase != null && want != null && want != _path) {
      _load(want);
    } else {
      setState(() {}); // 评论 / 已查看状态变了
    }
  }

  Future<void> _load(String path) async {
    _path = path;
    setState(() {
      _loading = true;
      _error = null;
      _binary = false;
      _selAnchor = _selHead = null;
      _composeRow = _composeFrom = null;
      _blame = null;
      _currentBlock = -1;
    });
    final f = _session.fileOf(path);
    if (f == null) {
      setState(() {
        _loading = false;
        _error = tr('文件不在这个 PR 里: $path', 'File is not in this pull request: $path');
      });
      return;
    }
    try {
      final (left, right) = await _session.contents(f);
      if (!mounted || _path != path) return;
      _binary = (left?.contains('\u0000') ?? false) || (right?.contains('\u0000') ?? false);
      _left = _binary ? const [] : splitDiffLines(left ?? '');
      _right = _binary ? const [] : splitDiffLines(right ?? '');
      _recompute();
      if (_blameOn) _loadBlame();
    } on GhException catch (e) {
      if (!mounted || _path != path) return;
      _error = e.message;
    }
    setState(() => _loading = false);
  }

  void _recompute() {
    _rows = sideBySideDiff(_left, _right);
    _blocks = changeBlockStarts(_rows);
    _blockKeys.clear();
    final l = <int, int>{}, r = <int, int>{};
    final changed = <int>[];
    for (var i = 0; i < _rows.length; i++) {
      final row = _rows[i];
      if (row.left != null) l[row.left!] = i;
      if (row.right != null) r[row.right!] = i;
      if (row.kind != DiffRowKind.equal) changed.add(i);
    }
    _leftRow = l;
    _rightRow = r;
    final ok = <int>{};
    for (final c in changed) {
      for (var k = c - _contextLines; k <= c + _contextLines; k++) {
        if (k >= 0 && k < _rows.length) ok.add(k);
      }
    }
    _commentable = ok;
  }

  Future<void> _loadBlame() async {
    final path = _path;
    if (path == null) return;
    try {
      final b = await _session.blame(path);
      if (mounted && _path == path) setState(() => _blame = b);
    } on GhException catch (e) {
      if (mounted) prSnack(context, tr('Blame 失败: ${e.message}', 'Blame failed: ${e.message}'), error: true);
    }
  }

  // ---------------------------------------------------------------------------
  // 选区与操作
  // ---------------------------------------------------------------------------

  (int, int)? get _selection {
    final a = _selAnchor, h = _selHead;
    if (a == null || h == null) return null;
    return a <= h ? (a, h) : (h, a);
  }

  bool _isSelected(int row, String side) {
    final s = _selection;
    return s != null && side == _selSide && row >= s.$1 && row <= s.$2;
  }

  void _select(int row, String side, {bool extend = false}) {
    _focus.requestFocus();
    setState(() {
      if (extend && _selAnchor != null && side == _selSide) {
        _selHead = row;
      } else {
        _selSide = side;
        _selAnchor = _selHead = row;
      }
    });
  }

  /// 选区在该侧对应的文件行号(1 起)。
  List<int> _selectedLines() {
    final s = _selection;
    if (s == null) return const [];
    return [
      for (var i = s.$1; i <= s.$2; i++)
        if ((_selSide == 'LEFT' ? _rows[i].left : _rows[i].right) case final n?) n + 1,
    ];
  }

  bool get _canComment {
    final s = _selection;
    if (s == null || _selectedLines().isEmpty) return false;
    for (var i = s.$1; i <= s.$2; i++) {
      if (!_commentable.contains(i)) return false;
    }
    return true;
  }

  void _startComment() {
    if (!_canComment) {
      prSnack(
          context,
          _selection == null
              ? tr('先选中要评论的行', 'Select the lines to comment on first')
              : tr('GitHub 只允许评论改动附近的行(改动上下 $_contextLines 行内)',
                  'GitHub only allows comments on lines near a change (within $_contextLines lines of it)'));
      return;
    }
    final s = _selection!;
    setState(() {
      _composeRow = s.$2;
      _composeFrom = s.$1;
      _composeSide = _selSide;
    });
  }

  Future<void> _submitComment(String body) async {
    final lines = [
      for (var i = _composeFrom!; i <= _composeRow!; i++)
        if ((_composeSide == 'LEFT' ? _rows[i].left : _rows[i].right) case final n?) n + 1,
    ];
    await _session.addReviewComment(
      path: _path!,
      line: lines.last,
      startLine: lines.length > 1 ? lines.first : null,
      side: _composeSide,
      body: body,
    );
    if (mounted) setState(() => _composeRow = _composeFrom = null);
  }

  bool? get _viewed => _session.viewed.isEmpty ? null : (_session.viewed[_path] ?? false);

  Future<void> _toggleViewed() async {
    final v = _viewed;
    if (v == null || _path == null) return;
    try {
      await _session.setViewed(_path!, !v);
    } on GhException catch (e) {
      if (mounted) prSnack(context, e.message, error: true);
    }
  }

  void _toggleBlame() {
    setState(() => _blameOn = !_blameOn);
    if (_blameOn && _blame == null) _loadBlame();
  }

  Future<void> _compareWithClipboard() async {
    final clip = (await Clipboard.getData(Clipboard.kTextPlain))?.text ?? '';
    final s = _selection;
    final List<String> mine;
    if (s == null) {
      mine = _right;
    } else {
      mine = [
        for (var i = s.$1; i <= s.$2; i++)
          if ((_selSide == 'LEFT' ? _rows[i].left : _rows[i].right) case final n?) (_selSide == 'LEFT' ? _left : _right)[n],
      ];
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      builder: (ctx) => _ClipboardCompareDialog(
        title: s == null
            ? tr('${_path!.split('/').last} ↔ 剪贴板', '${_path!.split('/').last} ↔ Clipboard')
            : tr('选区 ↔ 剪贴板', 'Selection ↔ Clipboard'),
        left: mine,
        right: splitDiffLines(clip),
      ),
    );
  }

  void _openContextMenu(Offset global, int row, String side) {
    if (!_isSelected(row, side)) _select(row, side);
    final box = _anchorKey.currentContext?.findRenderObject() as RenderBox?;
    if (box == null) return;
    _menu.open(position: box.globalToLocal(global));
  }

  void _gotoBlock(int delta) {
    if (_blocks.isEmpty) return;
    final next = (_currentBlock + delta).clamp(0, _blocks.length - 1);
    setState(() => _currentBlock = next);
    final key = _blockKeys[_blocks[next]];
    final ctx = key?.currentContext;
    if (ctx != null) {
      Scrollable.ensureVisible(ctx, alignment: 0.3, duration: const Duration(milliseconds: 150));
      return;
    }
    // 还没构建出来:按行高估个位置跳过去,下一帧再精确对齐。
    if (!_scroll.hasClients) return;
    final estimate = (_blocks[next] * diffRowHeight - _scroll.position.viewportDimension / 3).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(estimate);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final c = _blockKeys[_blocks[next]]?.currentContext;
      if (c != null) Scrollable.ensureVisible(c, alignment: 0.3);
    });
  }

  void _gotoFile(int delta) {
    final files = _session.files;
    if (files.isEmpty) return;
    final i = files.indexWhere((f) => f.path == _path);
    final next = ((i < 0 ? 0 : i) + delta).clamp(0, files.length - 1);
    _session.showFile(files[next].path);
  }

  void _openLocal() {
    final path = _path;
    if (path == null) return;
    final s = _selection;
    var line = 0;
    if (s != null) {
      for (var i = s.$1; i < _rows.length; i++) {
        if (_rows[i].right != null) {
          line = _rows[i].right!;
          break;
        }
      }
    } else if (_currentBlock >= 0 && _blocks.isNotEmpty) {
      line = _rows[_blocks[_currentBlock]].right ?? 0;
    }
    widget.onOpenLocal(path, line);
  }

  // ---------------------------------------------------------------------------
  // 构建
  // ---------------------------------------------------------------------------

  List<_Entry> _entries() {
    final byRow = <int, List<List<PrReviewComment>>>{};
    for (final t in _session.threadsFor(_path ?? '')) {
      final root = t.first;
      final line = root.line;
      if (line == null) continue; // outdated:代码已被后续提交改掉
      final row = (root.side == 'LEFT' ? _leftRow : _rightRow)[line - 1];
      if (row != null) byRow.putIfAbsent(row, () => []).add(t);
    }
    return [
      for (var i = 0; i < _rows.length; i++) ...[
        _RowEntry(i),
        for (final t in byRow[i] ?? const <List<PrReviewComment>>[]) _ThreadEntry(t),
        if (_composeRow == i) const _ComposerEntry(),
      ],
    ];
  }

  @override
  Widget build(BuildContext context) {
    final d = _session.detail;
    if (_session.error != null && d == null) return Center(child: Text(_session.error!, style: diffSmallStyle));
    if (d == null || _session.mergeBase == null) return Center(child: Text(tr('正在加载…', 'Loading…'), style: diffSmallStyle));
    if (_session.files.isEmpty) return Center(child: Text(tr('这个 PR 没有改动文件', 'This pull request has no changed files'), style: diffSmallStyle));

    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.keyX, meta: true, shift: true): _startComment,
        const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true): _toggleViewed,
        const SingleActivator(LogicalKeyboardKey.f7): () => _gotoBlock(1),
        const SingleActivator(LogicalKeyboardKey.f7, shift: true): () => _gotoBlock(-1),
      },
      child: Focus(
        focusNode: _focus,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            _toolbar(d),
            _header(d),
            Expanded(child: _body()),
          ],
        ),
      ),
    );
  }

  Widget _toolbar(PullRequestDetail d) {
    final files = _session.files;
    final index = files.indexWhere((f) => f.path == _path);
    final diffs = _blocks.length;
    final viewed = _viewed;
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: const BoxDecoration(
        color: IntelliJTheme.panelBg,
        border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Row(
        children: [
          DiffToolIcon(icon: Icons.arrow_upward, tooltip: tr('上一处差异 (⇧F7)', 'Previous Difference (⇧F7)'), onTap: diffs == 0 ? null : () => _gotoBlock(-1)),
          DiffToolIcon(icon: Icons.arrow_downward, tooltip: tr('下一处差异 (F7)', 'Next Difference (F7)'), onTap: diffs == 0 ? null : () => _gotoBlock(1)),
          DiffToolIcon(icon: Icons.edit_outlined, tooltip: tr('打开本地文件', 'Open Local File'), onTap: _path == null ? null : _openLocal),
          const SizedBox(width: 6),
          DiffToolIcon(icon: Icons.arrow_back, tooltip: tr('上一个文件', 'Previous File'), onTap: index <= 0 ? null : () => _gotoFile(-1)),
          DiffToolIcon(
            icon: Icons.arrow_forward,
            tooltip: tr('下一个文件', 'Next File'),
            onTap: index < 0 || index >= files.length - 1 ? null : () => _gotoFile(1),
          ),
          const SizedBox(width: 4),
          Flexible(child: _filePicker(files, index)),
          const SizedBox(width: 6),
          DiffToolIcon(icon: Icons.person_search_outlined, tooltip: tr('使用 Git Blame 注解', 'Annotate with Git Blame'), active: _blameOn, onTap: _toggleBlame),
          DiffToolIcon(icon: Icons.refresh, tooltip: tr('刷新', 'Refresh'), onTap: _session.reload),
          const Spacer(),
          if (viewed != null) ...[
            InkWell(
              onTap: _toggleViewed,
              borderRadius: BorderRadius.circular(4),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Icon(viewed ? Icons.check_box : Icons.check_box_outline_blank, size: 15, color: IntelliJTheme.textSecondary),
                    const SizedBox(width: 4),
                    Text(tr('已查看', 'Viewed'), style: diffSmallStyle),
                  ],
                ),
              ),
            ),
            const SizedBox(width: 10),
          ],
          Text(tr('审查:', 'Review:'), style: diffSmallStyle),
          const SizedBox(width: 6),
          OutlinedButton(
            onPressed: () => showSubmitReviewDialog(context, _session),
            style: OutlinedButton.styleFrom(
              visualDensity: VisualDensity.compact,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              minimumSize: const Size(0, 26),
              side: const BorderSide(color: IntelliJTheme.border),
            ),
            child: Text(tr('提交…', 'Submit…'), style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12)),
          ),
          const SizedBox(width: 12),
          Text(
              diffs == 0
                  ? tr('没有差异', 'No differences')
                  : tr('$diffs 处差异', '$diffs ${diffs == 1 ? 'difference' : 'differences'}'),
              style: diffSmallStyle),
        ],
      ),
    );
  }

  Widget _filePicker(List<PrFile> files, int index) {
    return PopupMenuButton<String>(
      tooltip: tr('切换文件', 'Switch File'),
      color: IntelliJTheme.panelBg,
      onSelected: _session.showFile,
      itemBuilder: (_) => [
        for (final f in files)
          PopupMenuItem<String>(
            value: f.path,
            height: 30,
            child: Row(
              children: [
                SizedBox(
                  width: 16,
                  child: _session.viewed[f.path] == true ? const Icon(Icons.check, size: 13, color: IntelliJTheme.textMuted) : null,
                ),
                Flexible(
                  child: Text(
                    f.path,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: prFileColor(f.status), fontSize: 12.5),
                  ),
                ),
              ],
            ),
          ),
      ],
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            Flexible(
              child: Text(
                index < 0 ? '' : files[index].path.split('/').last,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5),
              ),
            ),
            Text('  ${index + 1}/${files.length}', style: diffSmallStyle),
            const Icon(Icons.arrow_drop_down, size: 16, color: IntelliJTheme.textSecondary),
          ],
        ),
      ),
    );
  }

  Widget _header(PullRequestDetail d) {
    final f = _path == null ? null : _session.fileOf(_path!);
    String short(String sha) => sha.length > 8 ? sha.substring(0, 8) : sha;
    Widget side(String sha, String text) => Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10),
          child: Row(
            children: [
              const Icon(Icons.lock_outline, size: 13, color: IntelliJTheme.textMuted),
              const SizedBox(width: 4),
              Flexible(child: Text('${short(sha)}  $text', overflow: TextOverflow.ellipsis, style: diffSmallStyle)),
            ],
          ),
        );
    return Container(
      height: 26,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle))),
      child: Row(
        children: [
          Expanded(child: side(_session.mergeBase!, f == null ? '' : (f.status == 'added' ? tr('(新文件)', '(new file)') : f.basePath))),
          SizedBox(width: _gutterWidth + (_blameOn ? _blameWidth : 0)),
          Expanded(child: side(d.headSha, f == null ? '' : (f.status == 'removed' ? tr('(已删除)', '(deleted)') : f.path))),
        ],
      ),
    );
  }

  Widget _body() {
    if (_loading) return Center(child: Text(tr('正在加载…', 'Loading…'), style: diffSmallStyle));
    if (_error != null) return Center(child: Text(_error!, style: diffSmallStyle));
    if (_binary) return Center(child: Text(tr('二进制文件,不显示差异', 'Binary file, differences not shown'), style: diffSmallStyle));
    final entries = _entries();
    return Theme(
      data: darculaMenuTheme(Theme.of(context)),
      child: MenuAnchor(
        controller: _menu,
        consumeOutsideTap: true,
        menuChildren: _menuItems(),
        child: Container(
          key: _anchorKey,
          color: IntelliJTheme.editorBg,
          child: ListView.builder(
            controller: _scroll,
            itemCount: entries.length,
            itemBuilder: (context, i) => switch (entries[i]) {
              _RowEntry(:final row) => _buildRow(row),
              _ThreadEntry(:final thread) => PrCommentThread(key: ValueKey('thread-${thread.first.id}'), session: _session, thread: thread),
              _ComposerEntry() => _composer(),
            },
          ),
        ),
      ),
    );
  }

  List<Widget> _menuItems() {
    final viewed = _viewed;
    return [
      MenuItemButton(
        leadingIcon: const Icon(Icons.content_paste_go, size: 16),
        onPressed: _compareWithClipboard,
        child: Text(tr('与剪贴板比较', 'Compare with Clipboard')),
      ),
      const Divider(height: 10),
      MenuItemButton(
        onPressed: _toggleBlame,
        child: Text(_blameOn ? tr('关闭注解', 'Close Annotations') : tr('使用 Git Blame 注解', 'Annotate with Git Blame')),
      ),
      MenuItemButton(
        onPressed: _canComment ? _startComment : null,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyX, meta: true, shift: true),
        child: Text(tr('添加审查评论', 'Add Review Comment')),
      ),
      MenuItemButton(
        onPressed: viewed == null ? null : _toggleViewed,
        shortcut: const SingleActivator(LogicalKeyboardKey.keyS, meta: true, shift: true),
        child: Text(viewed == true ? tr('将文件标记为未查看', 'Mark File as Not Viewed') : tr('将文件标记为已查看', 'Mark File as Viewed')),
      ),
    ];
  }

  Widget _composer() {
    final lines = [
      for (var i = _composeFrom!; i <= _composeRow!; i++)
        if ((_composeSide == 'LEFT' ? _rows[i].left : _rows[i].right) case final n?) n + 1,
    ];
    final label = lines.length > 1
        ? tr('第 ${lines.first}–${lines.last} 行', 'lines ${lines.first}–${lines.last}')
        : tr('第 ${lines.first} 行', 'line ${lines.first}');
    return Container(
      margin: const EdgeInsets.fromLTRB(40, 4, 40, 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: IntelliJTheme.panelBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: IntelliJTheme.accentBlue.withValues(alpha: 0.6)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Text(
              _composeSide == 'LEFT'
                  ? tr('评论 旧版本 $label', 'Comment on the old version, $label')
                  : tr('评论 新版本 $label', 'Comment on the new version, $label'),
              style: prMuted),
          const SizedBox(height: 8),
          PrCommentComposer(
            submitLabel: tr('添加评论', 'Add Comment'),
            onSubmit: _submitComment,
            onCancel: () => setState(() => _composeRow = _composeFrom = null),
          ),
        ],
      ),
    );
  }

  Widget _buildRow(int i) {
    final r = _rows[i];
    final blockIndex = _blocks.indexOf(i);
    final isCurrent = _currentBlock >= 0 && blockIndex == _currentBlock;
    final leftText = r.left == null ? null : _left[r.left!];
    final rightText = r.right == null ? null : _right[r.right!];
    final span = r.kind == DiffRowKind.modify ? changedSpan(leftText!, rightText!) : null;
    final (leftBg, rightBg) = diffRowColors(r.kind);

    Widget side(String name, String? text, Color? bg, (int, int)? hl) {
      final selected = _isSelected(i, name);
      return Expanded(
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onTapDown: (_) => _select(i, name, extend: HardwareKeyboard.instance.isShiftPressed),
          onSecondaryTapDown: (d) => _openContextMenu(d.globalPosition, i, name),
          child: Stack(
            fit: StackFit.passthrough,
            children: [
              diffCell(text, bg, hl),
              if (selected) const Positioned.fill(child: IgnorePointer(child: ColoredBox(color: _selectionBg))),
            ],
          ),
        ),
      );
    }

    return SizedBox(
      key: blockIndex >= 0 ? _blockKeys.putIfAbsent(i, GlobalKey.new) : null,
      height: diffRowHeight,
      child: Row(
        children: [
          side('LEFT', leftText, leftBg, span == null ? null : (span.start, span.oldEnd)),
          Container(
            width: _gutterWidth,
            color: isCurrent && r.kind != DiffRowKind.equal ? IntelliJTheme.hoverBg : null,
            child: Row(
              children: [
                diffLineNumber(r.left),
                const SizedBox(width: 8),
                diffLineNumber(r.right),
              ],
            ),
          ),
          if (_blameOn) _blameCell(r.right),
          side('RIGHT', rightText, rightBg, span == null ? null : (span.start, span.newEnd)),
        ],
      ),
    );
  }

  Widget _blameCell(int? line) {
    PrBlameRange? range;
    if (line != null && _blame != null) {
      for (final b in _blame!) {
        if (line + 1 >= b.startLine && line + 1 <= b.endLine) {
          range = b;
          break;
        }
      }
    }
    return Container(
      width: _blameWidth,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      alignment: Alignment.centerLeft,
      color: const Color(0xFF26282C),
      child: range == null
          ? null
          : Text(
              '${prDate(range.date)}  ${range.author}',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
            ),
    );
  }
}

/// PR 文件名的颜色:新增绿、删除灰、改名/修改蓝。
Color prFileColor(String status) => switch (status) {
      'added' => const Color(0xFF629755),
      'removed' => IntelliJTheme.textMuted,
      _ => const Color(0xFF6897BB),
    };

/// 选区(或整个文件)与剪贴板内容的并排比较。
class _ClipboardCompareDialog extends StatelessWidget {
  const _ClipboardCompareDialog({required this.title, required this.left, required this.right});

  final String title;
  final List<String> left;
  final List<String> right;

  @override
  Widget build(BuildContext context) {
    final rows = sideBySideDiff(left, right);
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: IntelliJTheme.panelBg,
      insetPadding: const EdgeInsets.all(32),
      child: SizedBox(
        width: size.width * 0.75,
        height: size.height * 0.7,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 36,
              padding: const EdgeInsets.only(left: 14, right: 6),
              child: Row(
                children: [
                  Expanded(child: Text(title, overflow: TextOverflow.ellipsis, style: prText)),
                  Text(
                    rows.every((r) => r.kind == DiffRowKind.equal)
                        ? tr('内容相同', 'Contents are identical')
                        : tr('${changeBlockStarts(rows).length} 处差异', '${changeBlockStarts(rows).length} ${changeBlockStarts(rows).length == 1 ? 'difference' : 'differences'}'),
                    style: prMuted,
                  ),
                  IconButton(
                    icon: const Icon(Icons.close, size: 16, color: IntelliJTheme.textSecondary),
                    onPressed: () => Navigator.pop(context),
                  ),
                ],
              ),
            ),
            Container(
              height: 24,
              decoration: const BoxDecoration(border: Border.symmetric(horizontal: BorderSide(color: IntelliJTheme.borderSubtle))),
              child: Row(
                children: [
                  Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text(tr('选区', 'Selection'), style: prMuted))),
                  const SizedBox(width: 80),
                  Expanded(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 10), child: Text(tr('剪贴板', 'Clipboard'), style: prMuted))),
                ],
              ),
            ),
            Expanded(
              child: Container(
                color: IntelliJTheme.editorBg,
                child: ListView.builder(
                  itemExtent: diffRowHeight,
                  itemCount: rows.length,
                  itemBuilder: (context, i) {
                    final r = rows[i];
                    final l = r.left == null ? null : left[r.left!];
                    final rt = r.right == null ? null : right[r.right!];
                    final span = r.kind == DiffRowKind.modify ? changedSpan(l!, rt!) : null;
                    final (lb, rb) = diffRowColors(r.kind);
                    return Row(
                      children: [
                        Expanded(child: diffCell(l, lb, span == null ? null : (span.start, span.oldEnd))),
                        SizedBox(
                          width: 80,
                          child: Row(children: [diffLineNumber(r.left), const SizedBox(width: 8), diffLineNumber(r.right)]),
                        ),
                        Expanded(child: diffCell(rt, rb, span == null ? null : (span.start, span.newEnd))),
                      ],
                    );
                  },
                ),
              ),
            ),
          ],
        ),
      ),
    );
  }
}
