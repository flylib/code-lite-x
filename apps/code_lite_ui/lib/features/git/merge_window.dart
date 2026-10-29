import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';
import '../commit/diff_cells.dart';
import '../editor/blame.dart';
import '../editor/context_menu_region.dart';
import '../editor/editor_appearance.dart';
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
  Future<BlameData?> Function(MergeSide side)? loadBlame,
}) {
  return showDialog<MergeOutcome>(
    context: context,
    barrierDismissible: false,
    builder: (_) => MergeWindow(
      path: path,
      model: MergeModel(base: base, left: yours, right: theirs),
      yoursTitle: yoursTitle,
      theirsTitle: theirsTitle,
      loadBlame: loadBlame,
    ),
  );
}

class MergeWindow extends StatefulWidget {
  const MergeWindow({super.key, required this.path, required this.model, required this.yoursTitle, required this.theirsTitle, this.loadBlame});

  final String path;
  final MergeModel model;
  final String yoursTitle;
  final String theirsTitle;

  /// 一侧的逐行修改记录(右键行号 ▸ Annotate);null 时菜单里没有这一项。
  final Future<BlameData?> Function(MergeSide side)? loadBlame;

  @override
  State<MergeWindow> createState() => _MergeWindowState();
}

class _MergeWindowState extends State<MergeWindow> {
  final ScrollController _scroll = ScrollController();
  MergeModel get m => widget.model;

  // --- 两侧的修改记录(右键行号 ▸ Annotate:每行显示「时间 作者」,同 IntelliJ) ---------------------

  /// 已经打开注释的一侧 → 它的 blame;值为 null 表示正在读。
  final Map<MergeSide, BlameData?> _blame = {};
  final Map<MergeSide, String> _blameError = {};

  /// 注释显示「日期 作者」(默认外观:不显示提交号)。
  final EditorAppearance _blameLook = EditorAppearance();

  Future<void> _annotate(MergeSide side) async {
    final load = widget.loadBlame;
    if (load == null || _blame.containsKey(side)) return;
    setState(() {
      _blame[side] = null;
      _blameError.remove(side);
    });
    final data = await load(side);
    if (!mounted || !_blame.containsKey(side)) return;
    setState(() {
      if (data == null) {
        _blame.remove(side);
        _blameError[side] = tr('读取修改记录失败', 'Failed to load annotations');
      } else {
        _blame[side] = data;
      }
    });
  }

  void _closeAnnotations(MergeSide side) => setState(() {
        _blame.remove(side);
        _blameError.remove(side);
      });

  /// 注释栏宽度:按最宽的一条(和编辑器的注释栏一样),读取中给个固定宽度。
  double _blameWidth(MergeSide side) {
    final d = _blame[side];
    if (d == null) return 80;
    var widest = 0.0;
    for (final label in {for (final c in d.commits.values) blameLabel(c, _blameLook)}) {
      final tp = TextPainter(text: TextSpan(text: label, style: _blameStyle), textDirection: TextDirection.ltr)..layout();
      if (tp.width > widest) widest = tp.width;
    }
    return (widest + 16).ceilToDouble().clamp(60.0, 320.0);
  }

  static const TextStyle _blameStyle = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 11.5);

  /// 一侧这一行的注释格子;这一侧没打开注释时为 null。
  Widget? _blameCell(MergeSide side, int? line, double width) {
    if (!_blame.containsKey(side)) return null;
    final d = _blame[side];
    final c = line == null ? null : d?.at(line);
    final label = d == null ? (line == 0 ? 'blame…' : '') : blameLabel(c, _blameLook);
    Widget cell = Container(
      key: ValueKey('blame-${side.name}-$line'),
      width: width,
      height: _row,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      color: c == null || d == null ? null : blameBackground(c, d, _blameLook),
      child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis, style: d == null ? _blameStyle.copyWith(color: IntelliJTheme.textMuted) : _blameStyle),
    );
    if (c != null && !c.isUncommitted) {
      cell = Tooltip(
        message: blameTooltip(c),
        waitDuration: const Duration(milliseconds: 400),
        child: cell,
      );
    }
    return cell;
  }

  /// 行号(和注释)上的右键菜单:Annotate with Git Blame / Close Annotations。
  Widget _withBlameMenu(MergeSide side, Widget child) {
    if (widget.loadBlame == null) return child;
    return ContextMenuRegion(
      menuBuilder: (_) => [
        if (_blame.containsKey(side))
          MenuItemButton(onPressed: () => _closeAnnotations(side), child: Text(tr('关闭注解', 'Close Annotations')))
        else
          MenuItemButton(onPressed: () => _annotate(side), child: Text(tr('使用 Git Blame 注解', 'Annotate with Git Blame'))),
      ],
      child: child,
    );
  }

  /// 当前所在的改动块(上一处 / 下一处跳转的起点,行号栏旁高亮)。
  MergeChunk? _current;

  /// 结果栏里要把光标放到哪一行哪一列(拆行 / 合并 / 上下移动之后);放好就清掉。
  (int, int)? _caretTarget;

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
    _blameLook.dispose();
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
        tr('应用', 'Apply'),
        tr('还有 $left 处改动没处理(其中 ${m.unresolvedConflicts} 处冲突)。没处理的地方保留共同祖先的版本。\n\n仍然保存结果并标记为已解决?',
            '$left change${left == 1 ? ' is' : 's are'} still unresolved (${m.unresolvedConflicts} of them conflicts). Unresolved places keep the common ancestor version.\n\nSave the result and mark the file as resolved anyway?'),
        action: tr('应用', 'Apply'),
      );
      if (!ok || !mounted) return;
    }
    Navigator.pop(context, MergeOutcome(MergeOutcomeKind.apply, m.resultText));
  }

  Future<void> _cancel() async {
    if (m.canUndo) {
      final ok = await _confirm(tr('取消', 'Cancel'),
          tr('放弃这次合并里做的修改?文件保持冲突状态。', 'Discard the changes made in this merge? The file stays in conflict.'),
          action: tr('放弃', 'Discard'));
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
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('返回', 'Back'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok ?? false;
  }

  // ---------------------------------------------------------------------------
  // 结果栏的编辑:每一行是一个输入框,这里处理跨行的操作
  // ---------------------------------------------------------------------------

  /// 把光标移到结果的第 [line] 行第 [col] 列;那一行不在屏幕上时先滚过去。
  void _moveCaret(int line, int col) {
    final rows = m.rows();
    final i = rows.indexWhere((r) => r.result == line);
    if (i < 0) return;
    setState(() => _caretTarget = (line, col));
    if (!_scroll.hasClients) return;
    final top = i * _row, viewport = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _row > _scroll.offset + viewport) {
      _scroll.jumpTo((top + _row - viewport).clamp(0.0, _scroll.position.maxScrollExtent));
    }
  }

  /// 在第 [line] 行用 [lines] 替换这一行(拆行、粘贴多行),光标放到最后一段的 [col] 处。
  void _replaceLine(int line, List<String> lines, int col) {
    m.editResult(line, line + 1, lines);
    _moveCaret(line + lines.length - 1, col);
  }

  /// 第 [line] 行和下一行合成一行(行首退格 / 行尾 Delete),光标放在接缝处。
  void _joinWithNext(int line) {
    final res = m.resultLines;
    if (line < 0 || line + 1 >= res.length) return;
    final at = res[line].length;
    m.editResult(line, line + 2, [res[line] + res[line + 1]]);
    _moveCaret(line, at);
  }

  void _onCaretPlaced() => _caretTarget = null;

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
                      child: Text(tr('合并 ${widget.path} 的修订', 'Merge Revisions for ${widget.path}'), style: _title, overflow: TextOverflow.ellipsis),
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
        ? tr('所有改动都处理完了', 'All changes have been processed')
        : tr('$pending 处改动。${m.unresolvedConflicts} 处冲突。',
            '$pending ${pending == 1 ? 'change' : 'changes'}. ${m.unresolvedConflicts} ${m.unresolvedConflicts == 1 ? 'conflict' : 'conflicts'}.');
    return Container(
      height: 34,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: Row(
        children: [
          DiffToolIcon(icon: Icons.arrow_upward, tooltip: tr('上一处改动', 'Previous Change'), onTap: pending == 0 ? null : () => _go(-1)),
          DiffToolIcon(icon: Icons.arrow_downward, tooltip: tr('下一处改动', 'Next Change'), onTap: pending == 0 ? null : () => _go(1)),
          const SizedBox(width: 8),
          Text(tr('应用不冲突的更改:', 'Apply non-conflicting changes:'), style: _muted),
          const SizedBox(width: 4),
          DiffToolIcon(icon: Icons.keyboard_double_arrow_right, tooltip: tr('采用左侧所有不冲突的改动', 'Apply non-conflicting changes from the left side'), onTap: () => m.applyNonConflicting(MergeSide.left)),
          DiffToolIcon(icon: Icons.compare_arrows, tooltip: tr('采用两侧所有不冲突的改动', 'Apply all non-conflicting changes'), onTap: m.applyNonConflicting),
          DiffToolIcon(icon: Icons.keyboard_double_arrow_left, tooltip: tr('采用右侧所有不冲突的改动', 'Apply non-conflicting changes from the right side'), onTap: () => m.applyNonConflicting(MergeSide.right)),
          const SizedBox(width: 8),
          DiffToolIcon(icon: Icons.undo, tooltip: tr('撤销 (⌘Z)', 'Undo (⌘Z)'), onTap: m.canUndo ? m.undo : null),
          const SizedBox(width: 12),
          Flexible(child: Text(tr('结果栏可以直接编辑', 'The result pane can be edited directly'), style: _muted, overflow: TextOverflow.ellipsis)),
          const Spacer(),
          Text(status, key: const ValueKey('merge-status'), style: _title),
        ],
      ),
    );
  }

  Widget _headers() {
    Widget head(Widget child) => Container(height: 26, alignment: Alignment.centerLeft, padding: const EdgeInsets.symmetric(horizontal: 8), child: child);
    Widget side(String title, MergeSide s) => Row(children: [
          const Icon(Icons.lock_outline, size: 13, color: IntelliJTheme.textMuted),
          const SizedBox(width: 4),
          Flexible(child: Text(tr('来自 $title 的更改', 'Changes from $title'), style: _title, overflow: TextOverflow.ellipsis)),
          if (_blameError[s] case final e?) ...[
            const SizedBox(width: 8),
            Text(e, style: const TextStyle(color: IntelliJTheme.diagError, fontSize: 12)),
          ],
        ]);
    final leftBlame = _blame.containsKey(MergeSide.left) ? _blameWidth(MergeSide.left) : 0.0;
    final rightBlame = _blame.containsKey(MergeSide.right) ? _blameWidth(MergeSide.right) : 0.0;
    return Row(
      children: [
        Expanded(child: head(side(widget.yoursTitle, MergeSide.left))),
        SizedBox(width: leftBlame + _numWidth + _gutterWidth + _numWidth),
        Expanded(
          child: head(Row(children: [
            Text(tr('结果', 'Result'), style: _title),
            const SizedBox(width: 8),
            Flexible(child: Text(widget.path, style: _muted, overflow: TextOverflow.ellipsis)),
          ])),
        ),
        SizedBox(width: _gutterWidth + _numWidth + rightBlame),
        Expanded(child: head(side(widget.theirsTitle, MergeSide.right))),
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
          outlined(tr('接受左侧', 'Accept Left'), () => Navigator.pop(context, const MergeOutcome(MergeOutcomeKind.acceptLeft))),
          const SizedBox(width: 8),
          outlined(tr('接受右侧', 'Accept Right'), () => Navigator.pop(context, const MergeOutcome(MergeOutcomeKind.acceptRight))),
          const Spacer(),
          outlined(tr('取消', 'Cancel'), _cancel),
          const SizedBox(width: 8),
          FilledButton(onPressed: _apply, child: Text(tr('应用', 'Apply'))),
        ],
      ),
    );
  }

  /// 某一栏这一行的底色。[side] 为 null 表示结果栏。
  Color? _bg(MergeRow r, MergeSide? side, bool hasText) {
    final c = r.chunk;
    if (c == null) return side == null && r.edited ? _resolvedBg : (hasText ? null : diffGapBg);
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
    final leftBlame = _blameCell(MergeSide.left, r.left, _blame.containsKey(MergeSide.left) ? _blameWidth(MergeSide.left) : 0);
    final rightBlame = _blameCell(MergeSide.right, r.right, _blame.containsKey(MergeSide.right) ? _blameWidth(MergeSide.right) : 0);
    return Row(
      children: [
        Expanded(child: diffCell(r.leftText, _bg(r, MergeSide.left, r.leftText != null), null)),
        // 左栏的注释和行号挨着(在文字和行号之间),右键行号打开 / 关掉
        _withBlameMenu(
          MergeSide.left,
          Row(key: ValueKey('nums-left-${r.left}'), mainAxisSize: MainAxisSize.min, children: [if (leftBlame != null) leftBlame, diffLineNumber(r.left, width: _numWidth)]),
        ),
        gutter([
          if (showButtons && c.pending(MergeSide.left)) ...[
            _ChunkButton(key: ValueKey('ignore-left-${m.chunks.indexOf(c)}'), icon: Icons.close, tooltip: tr('忽略左侧的这处改动', 'Ignore this change from the left side'), onTap: () => m.ignore(c, MergeSide.left)),
            _ChunkButton(
              key: ValueKey('apply-left-${m.chunks.indexOf(c)}'),
              icon: Icons.keyboard_double_arrow_right,
              tooltip: c.applied.isEmpty ? tr('采用左侧的这处改动', 'Accept this change from the left side') : tr('把左侧的改动追加到结果', 'Append the left change to the result'),
              onTap: () => m.apply(c, MergeSide.left),
            ),
          ],
        ]),
        diffLineNumber(r.result, width: _numWidth),
        Expanded(
          child: r.result == null
              ? diffCell(null, _bg(r, null, false), null)
              : _ResultLine(
                  key: ValueKey('result-line-${r.result}'),
                  line: r.result!,
                  text: r.resultText ?? '',
                  background: _bg(r, null, true),
                  caretCol: _caretTarget?.$1 == r.result ? _caretTarget!.$2 : null,
                  onCaretPlaced: _onCaretPlaced,
                  onChanged: (text) => m.setResultLine(r.result!, text),
                  onReplace: (lines, col) => _replaceLine(r.result!, lines, col),
                  onJoinNext: () => _joinWithNext(r.result!),
                  onJoinPrevious: () => _joinWithNext(r.result! - 1),
                  onMove: (delta, col) => _moveCaret(r.result! + delta, col),
                  onUndo: m.undo,
                  lastLine: r.result! == m.resultLines.length - 1,
                ),
        ),
        gutter([
          if (showButtons && c.pending(MergeSide.right)) ...[
            _ChunkButton(
              key: ValueKey('apply-right-${m.chunks.indexOf(c)}'),
              icon: Icons.keyboard_double_arrow_left,
              tooltip: c.applied.isEmpty ? tr('采用右侧的这处改动', 'Accept this change from the right side') : tr('把右侧的改动追加到结果', 'Append the right change to the result'),
              onTap: () => m.apply(c, MergeSide.right),
            ),
            _ChunkButton(key: ValueKey('ignore-right-${m.chunks.indexOf(c)}'), icon: Icons.close, tooltip: tr('忽略右侧的这处改动', 'Ignore this change from the right side'), onTap: () => m.ignore(c, MergeSide.right)),
          ],
        ]),
        _withBlameMenu(
          MergeSide.right,
          Row(key: ValueKey('nums-right-${r.right}'), mainAxisSize: MainAxisSize.min, children: [diffLineNumber(r.right, width: _numWidth), if (rightBlame != null) rightBlame]),
        ),
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

/// 结果栏的一行:可以直接打字。跨行的操作交给窗口:
/// 回车拆行、行首退格并到上一行、行尾 Delete 并上下一行、↑ ↓ 换行、粘贴多行拆成多行、⌘Z 撤销整个合并的上一步。
class _ResultLine extends StatefulWidget {
  const _ResultLine({
    super.key,
    required this.line,
    required this.text,
    required this.background,
    required this.caretCol,
    required this.onCaretPlaced,
    required this.onChanged,
    required this.onReplace,
    required this.onJoinNext,
    required this.onJoinPrevious,
    required this.onMove,
    required this.onUndo,
    required this.lastLine,
  });

  final int line;
  final String text;
  final Color? background;

  /// 非 null:窗口要把光标放到这一行的这一列。
  final int? caretCol;
  final VoidCallback onCaretPlaced;
  final ValueChanged<String> onChanged;
  final void Function(List<String> lines, int col) onReplace;
  final VoidCallback onJoinNext;
  final VoidCallback onJoinPrevious;
  final void Function(int delta, int col) onMove;
  final VoidCallback onUndo;
  final bool lastLine;

  @override
  State<_ResultLine> createState() => _ResultLineState();
}

class _ResultLineState extends State<_ResultLine> {
  late final TextEditingController _text = TextEditingController(text: widget.text);
  final FocusNode _focus = FocusNode();

  @override
  void initState() {
    super.initState();
    _placeCaret();
  }

  @override
  void didUpdateWidget(_ResultLine old) {
    super.didUpdateWidget(old);
    // 别处改了这一行(采用了一侧、撤销、拆行后这个位置换成了另一行):跟上
    if (_text.text != widget.text) {
      final col = _text.selection.baseOffset.clamp(0, widget.text.length);
      _text.value = TextEditingValue(text: widget.text, selection: TextSelection.collapsed(offset: col));
    }
    _placeCaret();
  }

  void _placeCaret() {
    final col = widget.caretCol;
    if (col == null) return;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _focus.requestFocus();
      _text.selection = TextSelection.collapsed(offset: col.clamp(0, _text.text.length));
      widget.onCaretPlaced();
    });
  }

  @override
  void dispose() {
    _text.dispose();
    _focus.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent && e is! KeyRepeatEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final cmd = keys.isMetaPressed || keys.isControlPressed;
    final sel = _text.selection;
    final value = _text.text;
    final start = sel.isValid ? sel.start : value.length;
    final end = sel.isValid ? sel.end : value.length;
    final k = e.logicalKey;

    if (cmd && k == LogicalKeyboardKey.keyZ) {
      widget.onUndo();
      return KeyEventResult.handled;
    }
    if (cmd && k == LogicalKeyboardKey.keyV) {
      _paste(start, end);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.enter || k == LogicalKeyboardKey.numpadEnter) {
      widget.onReplace([value.substring(0, start), value.substring(end)], 0);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.backspace && sel.isCollapsed && start == 0 && widget.line > 0) {
      widget.onJoinPrevious();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.delete && sel.isCollapsed && start == value.length && !widget.lastLine) {
      widget.onJoinNext();
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowUp && !keys.isShiftPressed) {
      widget.onMove(-1, start);
      return KeyEventResult.handled;
    }
    if (k == LogicalKeyboardKey.arrowDown && !keys.isShiftPressed) {
      widget.onMove(1, start);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  /// 单行输入框会把粘贴进来的换行吃掉:自己处理,多行的拆成多行。
  Future<void> _paste(int start, int end) async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final pasted = data?.text?.replaceAll('\r\n', '\n');
    if (pasted == null || !mounted) return;
    final value = _text.text;
    final merged = value.substring(0, start) + pasted + value.substring(end);
    final lines = merged.split('\n');
    if (lines.length == 1) {
      _text.value = TextEditingValue(text: merged, selection: TextSelection.collapsed(offset: start + pasted.length));
      widget.onChanged(merged);
      return;
    }
    widget.onReplace(lines, lines.last.length - value.substring(end).length);
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: widget.background,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      alignment: Alignment.centerLeft,
      child: Focus(
        onKeyEvent: _onKey,
        child: TextField(
          controller: _text,
          focusNode: _focus,
          style: diffCodeStyle,
          maxLines: 1,
          cursorColor: IntelliJTheme.caret,
          cursorHeight: 14,
          decoration: const InputDecoration.collapsed(hintText: null),
          onChanged: widget.onChanged,
        ),
      ),
    );
  }
}
