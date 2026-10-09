import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/intellij_theme.dart';
import '../commit/diff_cells.dart';
import 'merge_model.dart';

const double _row = diffRowHeight;
const double _numWidth = 36;
const double _gutterWidth = 44;

// IntelliJ Darcula 的合并配色:冲突红、新增绿、修改蓝、删除灰;补位的空行淡一些。
const Color _conflictBg = Color(0xFF5A3838);
const Color _resolvedBg = Color(0xFF2C3530);

const TextStyle _title = TextStyle(color: IntelliJTheme.textHigh, fontSize: 13);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

/// 合并窗口怎么结束的。
enum MergeOutcomeKind {
  /// Apply:把结果写回文件。
  apply,

  /// Accept Left:整个文件用 Yours。
  acceptLeft,

  /// Accept Right:整个文件用 Theirs。
  acceptRight,
}

class MergeOutcome {
  const MergeOutcome(this.kind, [this.content]);

  final MergeOutcomeKind kind;

  /// [MergeOutcomeKind.apply] 时的合并结果。
  final String? content;
}

/// 打开三方合并窗口(IntelliJ 的 Merge Revisions):左边 Yours、中间结果、右边 Theirs。
/// 取消时返回 null。
Future<MergeOutcome?> showMergeWindow(
  BuildContext context, {
  required String path,
  required String base,
  required String yours,
  required String theirs,
  required String yoursTitle,
  required String theirsTitle,
}) {
  return showDialog<MergeOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => MergeWindow(
      path: path,
      model: MergeModel(base: base, left: yours, right: theirs),
      yoursTitle: yoursTitle,
      theirsTitle: theirsTitle,
    ),
  );
}

class MergeWindow extends StatefulWidget {
  const MergeWindow({super.key, required this.path, required this.model, required this.yoursTitle, required this.theirsTitle});

  final String path;
  final MergeModel model;
  final String yoursTitle;
  final String theirsTitle;

  @override
  State<MergeWindow> createState() => _MergeWindowState();
}

class _MergeWindowState extends State<MergeWindow> {
  final ScrollController _scroll = ScrollController();
  MergeModel get m => widget.model;

  /// 当前所在的改动块(上一处 / 下一处跳转的起点,行号栏旁高亮)。
  MergeChunk? _current;

  @override
  void initState() {
    super.initState();
    // 打开时跳到第一处冲突(没有冲突就第一处改动)
    final first = m.chunks.where((c) => c.isConflict).firstOrNull ?? m.chunks.firstOrNull;
    if (first != null) WidgetsBinding.instance.addPostFrameCallback((_) => _reveal(first));
  }

  @override
  void dispose() {
    _scroll.dispose();
    m.dispose();
    super.dispose();
  }

  int _rowOf(List<MergeRow> rows, MergeChunk c) => rows.indexWhere((r) => r.chunk == c && r.firstOfChunk);

  void _reveal(MergeChunk c) {
    setState(() => _current = c);
    final i = _rowOf(m.rows(), c);
    if (i < 0 || !_scroll.hasClients) return;
    final target = (i * _row - _scroll.position.viewportDimension / 3).clamp(0.0, _scroll.position.maxScrollExtent);
    _scroll.jumpTo(target);
  }

  /// 跳到上一处 / 下一处还没处理的改动。
  void _go(int dir) {
    final pending = [for (final c in m.chunks) if (!c.resolved) c];
    if (pending.isEmpty) return;
    final cur = _current;
    final at = cur == null ? -1 : m.chunks.indexOf(cur);
    MergeChunk? next;
    if (dir > 0) {
      next = pending.where((c) => m.chunks.indexOf(c) > at).firstOrNull ?? pending.first;
    } else {
      next = pending.where((c) => at < 0 || m.chunks.indexOf(c) < at).lastOrNull ?? pending.last;
    }
    _reveal(next);
  }

  Future<void> _apply() async {
    final left = m.unresolvedChanges;
    if (left > 0) {
      final ok = await _confirm(
        'Apply',
        '还有 $left 处改动没处理(其中 ${m.unresolvedConflicts} 处冲突)。没处理的地方保留共同祖先的版本。\n\n仍然保存结果并标记为已解决?',
        action: 'Apply',
      );
      if (!ok || !mounted) return;
    }
    Navigator.pop(context, MergeOutcome(MergeOutcomeKind.apply, m.resultText));
  }

  Future<void> _cancel() async {
    if (m.canUndo) {
      final ok = await _confirm('Cancel', '放弃这次合并里做的修改?文件保持冲突状态。', action: 'Discard');
      if (!ok || !mounted) return;
    }
    Navigator.pop(context);
  }

  Future<bool> _confirm(String title, String message, {required String action}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: Text(title, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
        content: SizedBox(width: 420, child: Text(message, style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 13))),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Back')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _edit(MergeChunk c) async {
    final lines = await showDialog<List<String>>(context: context, builder: (_) => _EditChunkDialog(initial: c.result));
    if (lines != null) m.edit(c, lines);
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: IntelliJTheme.editorBg,
      insetPadding: const EdgeInsets.all(20),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: IntelliJTheme.border)),
      clipBehavior: Clip.antiAlias,
      child: CallbackShortcuts(
        bindings: {
          const SingleActivator(LogicalKeyboardKey.keyZ, meta: true): m.undo,
          const SingleActivator(LogicalKeyboardKey.keyZ, control: true): m.undo,
          const SingleActivator(LogicalKeyboardKey.escape): _cancel,
        },
        child: Focus(
          autofocus: true,
          child: ListenableBuilder(
            listenable: m,
            builder: (context, _) {
              final rows = m.rows();
              return SizedBox.expand(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      height: 30,
                      alignment: Alignment.center,
                      color: IntelliJTheme.headerBg,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      child: Text('Merge Revisions for ${widget.path}', style: _title, overflow: TextOverflow.ellipsis),
                    ),
                    _toolbar(),
                    _headers(),
                    const Divider(height: 1, color: IntelliJTheme.borderSubtle),
                    Expanded(
                      child: ListView.builder(
                        controller: _scroll,
                        itemExtent: _row,
                        itemCount: rows.length,
                        itemBuilder: (context, i) => _buildRow(rows[i]),
                      ),
                    ),
                    const Divider(height: 1, color: IntelliJTheme.borderSubtle),
                    _bottom(),
                  ],
                ),
              );
            },
          ),
        ),
      ),
    );
  }

  Widget _toolbar() {
    final pending = m.unresolvedChanges;
    final status = pending == 0
        ? '所有改动都处理完了'
        : '$pending ${pending == 1 ? 'change' : 'changes'}. ${m.unresolvedConflicts} ${m.unresolvedConflicts == 1 ? 'conflict' : 'conflicts'}.';
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          DiffToolIcon(icon: Icons.arrow_upward, tooltip: '上一处改动', onTap: pending == 0 ? null : () => _go(-1)),
          DiffToolIcon(icon: Icons.arrow_downward, tooltip: '下一处改动', onTap: pending == 0 ? null : () => _go(1)),
          const SizedBox(width: 8),
          const Text('Apply non-conflicting changes:', style: _muted),
          const SizedBox(width: 4),
          DiffToolIcon(icon: Icons.keyboard_double_arrow_right, tooltip: '采用左侧所有不冲突的改动', onTap: () => m.applyNonConflicting(MergeSide.left)),
          DiffToolIcon(icon: Icons.compare_arrows, tooltip: '采用两侧所有不冲突的改动', onTap: m.applyNonConflicting),
          DiffToolIcon(icon: Icons.keyboard_double_arrow_left, tooltip: '采用右侧所有不冲突的改动', onTap: () => m.applyNonConflicting(MergeSide.right)),
          const SizedBox(width: 8),
          DiffToolIcon(icon: Icons.undo, tooltip: '撤销 (⌘Z)', onTap: m.canUndo ? m.undo : null),
          const SizedBox(width: 12),
          const Flexible(child: Text('双击结果里的改动块可以手动修改', style: _muted, overflow: TextOverflow.ellipsis)),
          const Spacer(),
          Text(status, key: const ValueKey('merge-status'), style: _title),
        ],
      ),
    );
  }

  Widget _headers() {
    Widget head(Widget child) => Container(height: 26, alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 8), child: child);
    Widget side(String title) => Row(children: [
          const Icon(Icons.lock_outline, size: 13, color: IntelliJTheme.textMuted),
          const SizedBox(width: 4),
          Flexible(child: Text('Changes from $title', style: _title, overflow: TextOverflow.ellipsis)),
        ]);
    return Row(
      children: [
        Expanded(child: head(side(widget.yoursTitle))),
        const SizedBox(width: _numWidth + _gutterWidth + _numWidth),
        Expanded(
          child: head(Row(children: [
            const Text('Result', style: _title),
            const SizedBox(width: 8),
            Flexible(child: Text(widget.path, style: _muted, overflow: TextOverflow.ellipsis)),
          ])),
        ),
        const SizedBox(width: _gutterWidth + _numWidth),
        Expanded(child: head(side(widget.theirsTitle))),
      ],
    );
  }

  Widget _bottom() {
    Widget outlined(String label, VoidCallback onTap) => OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(foregroundColor: IntelliJTheme.textHigh, side: const BorderSide(color: IntelliJTheme.border)),
          child: Text(label),
        );
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Row(
        children: [
          outlined('Accept Left', () => Navigator.pop(context, const MergeOutcome(MergeOutcomeKind.acceptLeft))),
          const SizedBox(width: 8),
          outlined('Accept Right', () => Navigator.pop(context, const MergeOutcome(MergeOutcomeKind.acceptRight))),
          const Spacer(),
          outlined('Cancel', _cancel),
          const SizedBox(width: 8),
          FilledButton(onPressed: _apply, child: const Text('Apply')),
        ],
      ),
    );
  }

  /// 某一栏这一行的底色。[side] 为 null 表示结果栏。
  Color? _bg(MergeRow r, MergeSide? side, bool hasText) {
    final c = r.chunk;
    if (c == null) return null;
    Color? color;
    if (side == null) {
      color = c.resolved ? _resolvedBg : (c.isConflict ? _conflictBg : _kindColor(c, c.kind == ChunkKind.right ? MergeSide.right : MergeSide.left));
    } else if (c.pending(side)) {
      color = c.isConflict ? _conflictBg : _kindColor(c, side);
    }
    if (color == null) return hasText ? null : diffGapBg;
    return hasText ? color : Color.alphaBlend(diffGapBg.withValues(alpha: 0.6), color);
  }

  static Color _kindColor(MergeChunk c, MergeSide side) {
    final lines = c.linesOf(side);
    if (c.base.isEmpty) return diffInsBg;
    if (lines.isEmpty) return diffDelBg;
    return diffModBg;
  }

  Widget _buildRow(MergeRow r) {
    final c = r.chunk;
    final current = c != null && c == _current;
    Widget gutter(List<Widget> buttons) => Container(
          width: _gutterWidth,
          color: current ? IntelliJTheme.hoverBg : null,
          child: Row(mainAxisAlignment: MainAxisAlignment.center, children: buttons),
        );
    final showButtons = c != null && r.firstOfChunk;
    return Row(
      children: [
        Expanded(child: diffCell(r.leftText, _bg(r, MergeSide.left, r.leftText != null), null)),
        diffLineNumber(r.left, width: _numWidth),
        gutter([
          if (showButtons && c.pending(MergeSide.left)) ...[
            _ChunkButton(key: ValueKey('ignore-left-${m.chunks.indexOf(c)}'), icon: Icons.close, tooltip: '忽略左侧的这处改动', onTap: () => m.ignore(c, MergeSide.left)),
            _ChunkButton(
              key: ValueKey('apply-left-${m.chunks.indexOf(c)}'),
              icon: Icons.keyboard_double_arrow_right,
              tooltip: c.applied.isEmpty ? '采用左侧的这处改动' : '把左侧的改动追加到结果',
              onTap: () => m.apply(c, MergeSide.left),
            ),
          ],
        ]),
        diffLineNumber(r.result, width: _numWidth),
        Expanded(
          child: GestureDetector(
            onDoubleTap: c == null ? null : () => _edit(c),
            child: diffCell(r.resultText, _bg(r, null, r.resultText != null), null),
          ),
        ),
        gutter([
          if (showButtons && c.pending(MergeSide.right)) ...[
            _ChunkButton(
              key: ValueKey('apply-right-${m.chunks.indexOf(c)}'),
              icon: Icons.keyboard_double_arrow_left,
              tooltip: c.applied.isEmpty ? '采用右侧的这处改动' : '把右侧的改动追加到结果',
              onTap: () => m.apply(c, MergeSide.right),
            ),
            _ChunkButton(key: ValueKey('ignore-right-${m.chunks.indexOf(c)}'), icon: Icons.close, tooltip: '忽略右侧的这处改动', onTap: () => m.ignore(c, MergeSide.right)),
          ],
        ]),
        diffLineNumber(r.right, width: _numWidth),
        Expanded(child: diffCell(r.rightText, _bg(r, MergeSide.right, r.rightText != null), null)),
      ],
    );
  }
}

class _ChunkButton extends StatelessWidget {
  const _ChunkButton({super.key, required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(3),
          child: Padding(padding: const EdgeInsets.all(1), child: Icon(icon, size: 15, color: IntelliJTheme.textSecondary)),
        ),
      );
}

/// 手改结果里的一块。控制器由对话框自己持有,关闭动画播完才释放。
class _EditChunkDialog extends StatefulWidget {
  const _EditChunkDialog({required this.initial});

  final List<String> initial;

  @override
  State<_EditChunkDialog> createState() => _EditChunkDialogState();
}

class _EditChunkDialogState extends State<_EditChunkDialog> {
  late final TextEditingController _text = TextEditingController(text: widget.initial.join('\n'));

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _done() => Navigator.pop(context, _text.text.isEmpty ? <String>[] : _text.text.split('\n'));

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: const Text('编辑这一块的合并结果', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 640,
        child: TextField(
          controller: _text,
          autofocus: true,
          maxLines: 16,
          minLines: 6,
          style: diffCodeStyle.copyWith(color: IntelliJTheme.textHigh),
          decoration: const InputDecoration(
            border: OutlineInputBorder(borderSide: BorderSide(color: IntelliJTheme.border)),
            enabledBorder: OutlineInputBorder(borderSide: BorderSide(color: IntelliJTheme.border)),
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _done, child: const Text('OK')),
      ],
    );
  }
}
