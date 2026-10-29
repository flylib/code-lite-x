import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/client/api_client.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';
import '../editor/code_editor_controller.dart';
import 'diff_cells.dart';
import 'line_diff.dart';
import '../notifications/notifications.dart';

/// 中间:左行号 36 + 「>>」恢复按钮 20 + 间隔 4 + 右行号 36。
const double _gutterWidth = 96;
const double _rowHeight = diffRowHeight;
const TextStyle _small = diffSmallStyle;

/// 「Commit: 文件名」标签页:左边 HEAD,右边当前版本,改动处高亮。两侧只读;
/// 双击右侧某行或点 ✎ 跳到源文件对应行。
class DiffTab extends StatefulWidget {
  const DiffTab({
    super.key,
    required this.client,
    required this.repoPath,
    required this.findOpenController,
    required this.onOpenSource,
  });

  final ApiClient client;

  /// 相对仓库根的路径(git status 给出的就是这种)。
  final String repoPath;

  /// 该文件已在编辑器里打开时,返回它的 controller —— 右侧显示未保存的内容,并随编辑刷新。
  final CodeEditorController? Function(String workspacePath) findOpenController;

  /// 跳到源文件:[path] 是相对项目的路径(文件在项目目录外时为绝对路径),[line] 从 0 起。
  final void Function(String path, int line) onOpenSource;

  @override
  State<DiffTab> createState() => _DiffTabState();
}

class _DiffTabState extends State<DiffTab> {
  final ScrollController _scroll = ScrollController();
  List<String> _left = const [];
  List<String> _right = const [];
  List<DiffRow> _rows = const [];
  List<int> _blocks = const [];
  int _currentBlock = -1;
  String _headShort = '';
  String? _error;
  bool _loading = true;

  /// 相对项目的路径;文件不在项目目录下时为绝对路径。
  String _sourcePath = '';
  CodeEditorController? _live;
  Timer? _debounce;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void didUpdateWidget(DiffTab old) {
    super.didUpdateWidget(old);
    if (old.repoPath != widget.repoPath) _load();
  }

  @override
  void dispose() {
    _live?.removeTextListener(_onLiveText);
    _debounce?.cancel();
    _scroll.dispose();
    super.dispose();
  }

  void _onLiveText() {
    _debounce?.cancel();
    _debounce = Timer(const Duration(milliseconds: 300), () => _recompute(_live?.text));
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _error = null;
    });
    final client = widget.client;
    final info = await client.gitCall('git.repo_info');
    if (info['status'] != 'ok') {
      setState(() {
        _loading = false;
        _error = info['error'] as String? ?? tr('不是 Git 仓库', 'Not a Git repository');
      });
      return;
    }
    final top = info['toplevel'] as String;
    final prefix = info['prefix'] as String? ?? '';
    _sourcePath = prefix.isNotEmpty && widget.repoPath.startsWith(prefix)
        ? widget.repoPath.substring(prefix.length)
        : prefix.isEmpty
            ? widget.repoPath
            : '$top/${widget.repoPath}';

    // HEAD 里没有这个文件 = 新增,左侧为空。
    final base = await client.gitCall('git.file_at', {'hash': 'HEAD', 'path': widget.repoPath});
    final head = await client.gitCall('git.log', {'branch': 'HEAD', 'limit': 1});
    final commits = head['commits'] as List?;
    _headShort = commits == null || commits.isEmpty ? '' : (commits.first['hash'] as String).substring(0, 8);
    _left = base['status'] == 'ok' && base['binary'] != true ? _split(base['content'] as String? ?? '') : const [];

    _live?.removeTextListener(_onLiveText);
    _live = widget.findOpenController(_sourcePath);
    _live?.addTextListener(_onLiveText);

    String? current = _live?.text;
    if (current == null) {
      final file = await client.fetchFile(_sourcePath);
      current = file['status'] == 'ok' ? file['content'] as String? ?? '' : ''; // 已删除的文件:右侧为空
    }
    if (!mounted) return;
    _recompute(current);
    setState(() => _loading = false);
  }

  static List<String> _split(String text) => splitDiffLines(text);

  /// 当前版本末尾是否有换行(拆行时去掉了,写回时要还原)。
  bool _rightTrailingNewline = true;

  void _recompute(String? current) {
    if (!mounted || current == null) return;
    _rightTrailingNewline = current.isEmpty || current.endsWith('\n');
    setState(() {
      _right = _split(current);
      _rows = sideBySideDiff(_left, _right);
      _blocks = changeBlockStarts(_rows);
      if (_currentBlock >= _blocks.length) _currentBlock = _blocks.length - 1;
    });
  }

  void _goto(int delta) {
    if (_blocks.isEmpty) return;
    final next = (_currentBlock + delta).clamp(0, _blocks.length - 1);
    setState(() => _currentBlock = next);
    if (!_scroll.hasClients) return;
    final target = (_blocks[next] * _rowHeight - _scroll.position.viewportDimension / 3)
        .clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.animateTo(target, duration: const Duration(milliseconds: 150), curve: Curves.easeOut);
  }

  void _openAtRow(int rowIndex) {
    // 找这一行或它之后最近的一个右侧行号(左侧专有的删除行没有对应位置)。
    for (var r = rowIndex; r < _rows.length; r++) {
      final line = _rows[r].right;
      if (line != null) return widget.onOpenSource(_sourcePath, line);
    }
    widget.onOpenSource(_sourcePath, _right.isEmpty ? 0 : _right.length - 1);
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) return Center(child: Text(tr('正在加载…', 'Loading…'), style: _small));
    if (_error != null) return Center(child: Text(_error!, style: _small));
    final diffs = _blocks.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 工具条:上一处 / 下一处 / 跳到源文件 …… 差异数
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: const BoxDecoration(
            color: IntelliJTheme.panelBg,
            border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
          ),
          child: Row(
            children: [
              DiffToolIcon(icon: Icons.arrow_upward, tooltip: tr('上一处差异', 'Previous Difference'), onTap: diffs == 0 ? null : () => _goto(-1)),
              DiffToolIcon(icon: Icons.arrow_downward, tooltip: tr('下一处差异', 'Next Difference'), onTap: diffs == 0 ? null : () => _goto(1)),
              DiffToolIcon(
                icon: Icons.edit_outlined,
                tooltip: tr('跳转到源', 'Jump to Source'),
                onTap: () => _openAtRow(_currentBlock < 0 || _blocks.isEmpty ? 0 : _blocks[_currentBlock]),
              ),
              DiffToolIcon(icon: Icons.refresh, tooltip: tr('刷新', 'Refresh'), onTap: _load),
              const Spacer(),
              Text(
                diffs == 0
                    ? tr('没有差异', 'No differences')
                    : tr('$diffs 处差异', '$diffs ${diffs == 1 ? 'difference' : 'differences'}'),
                style: _small,
              ),
            ],
          ),
        ),
        // 两侧标题:左 HEAD(只读)、右 当前版本
        Container(
          height: 26,
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle))),
          child: Row(
            children: [
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Row(
                    children: [
                      const Icon(Icons.lock_outline, size: 13, color: IntelliJTheme.textMuted),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          _left.isEmpty && _headShort.isNotEmpty ? tr('$_headShort  (新文件)', '$_headShort  (new file)') : '$_headShort  ${widget.repoPath}',
                          overflow: TextOverflow.ellipsis,
                          style: _small,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: _gutterWidth),
              Expanded(
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 10),
                  child: Text(tr('当前版本', 'Current version'), overflow: TextOverflow.ellipsis, style: _small),
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: Container(
            color: IntelliJTheme.editorBg,
            child: ListView.builder(
              controller: _scroll,
              itemExtent: _rowHeight,
              itemCount: _rows.length,
              itemBuilder: (context, i) => _buildRow(i, isCurrent: _currentBlock >= 0 && _blocks.isNotEmpty && _blockOf(i) == _currentBlock),
            ),
          ),
        ),
      ],
    );
  }

  /// 「>>」:把 [block] 这段改动恢复成左侧 HEAD 的内容,并写回磁盘(与 IntelliJ 的自动保存一致,
  /// Commit 窗的改动列表随之更新;全部恢复后文件就从列表里消失)。
  /// 文件已在编辑器里打开时同时改编辑器缓冲区,可 ⌘Z 撤销。
  Future<void> _revertBlock(int block) async {
    final start = _blocks[block];
    var end = start;
    while (end < _rows.length && _rows[end].kind != DiffRowKind.equal) {
      end++;
    }
    final rows = _rows.sublist(start, end);
    final leftLines = [for (final r in rows) if (r.left != null) _left[r.left!]];
    final rightIdx = [for (final r in rows) if (r.right != null) r.right!];
    // 纯删除的块右侧没有行:插入点是这块之后第一个右侧行(没有就是末尾)。
    var insertAt = rightIdx.isNotEmpty ? rightIdx.first : _right.length;
    if (rightIdx.isEmpty) {
      for (var r = end; r < _rows.length; r++) {
        if (_rows[r].right != null) {
          insertAt = _rows[r].right!;
          break;
        }
      }
    }
    final newRight = [
      ..._right.sublist(0, insertAt),
      ...leftLines,
      ..._right.sublist(insertAt + rightIdx.length),
    ];
    final text = newRight.isEmpty ? '' : '${newRight.join('\n')}${_rightTrailingNewline ? '\n' : ''}';

    final live = _live;
    live?.replaceAllText(text); // 文本监听会触发重算
    final res = await widget.client.saveFile(_sourcePath, text);
    if (!mounted) return;
    if (res['status'] != 'ok') {
      showNotice(context, tr('恢复失败: ${res['error']}', 'Revert failed: ${res['error']}'), error: true);
      return;
    }
    if (live != null) {
      // 保存期间若又有编辑,缓冲区仍算未保存。
      if (live.text == text) live.markSaved();
    } else {
      _recompute(text);
    }
  }

  int _blockOf(int row) {
    var b = -1;
    for (var k = 0; k < _blocks.length && _blocks[k] <= row; k++) {
      b = k;
    }
    return b;
  }

  Widget _buildRow(int i, {required bool isCurrent}) {
    final r = _rows[i];
    // 每段改动的第一行放「>>」。
    final blockStart = _blocks.indexOf(i);
    final leftText = r.left == null ? null : _left[r.left!];
    final rightText = r.right == null ? null : _right[r.right!];
    final span = r.kind == DiffRowKind.modify ? changedSpan(leftText!, rightText!) : null;

    final (leftBg, rightBg) = diffRowColors(r.kind);
    Widget number(int? n) => diffLineNumber(n);

    return Row(
      children: [
        Expanded(child: _cell(leftText, leftBg, span == null ? null : (span.start, span.oldEnd))),
        Container(
          width: _gutterWidth,
          color: isCurrent && r.kind != DiffRowKind.equal ? IntelliJTheme.hoverBg : null,
          child: Row(
            children: [
              number(r.left),
              SizedBox(
                width: 20,
                child: blockStart < 0
                    ? null
                    : Tooltip(
                        message: tr('恢复为 HEAD 版本', 'Revert to HEAD version'),
                        waitDuration: const Duration(milliseconds: 400),
                        child: InkWell(
                          onTap: () => _revertBlock(blockStart),
                          borderRadius: BorderRadius.circular(3),
                          child: const Icon(Icons.keyboard_double_arrow_right, size: 15, color: IntelliJTheme.textSecondary),
                        ),
                      ),
              ),
              const SizedBox(width: 4),
              number(r.right),
            ],
          ),
        ),
        Expanded(
          child: GestureDetector(
            onDoubleTap: () => _openAtRow(i),
            child: _cell(rightText, rightBg, span == null ? null : (span.start, span.newEnd)),
          ),
        ),
      ],
    );
  }

  Widget _cell(String? text, Color? bg, (int, int)? highlight) => diffCell(text, bg, highlight);
}

