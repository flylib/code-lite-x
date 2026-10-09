import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/intellij_theme.dart';
import 'branch_store.dart';
import 'repo_operation.dart';

const TextStyle _text = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 13);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);
const TextStyle _head = TextStyle(color: IntelliJTheme.textSecondary, fontSize: 12);

/// 冲突窗口(IntelliJ 的 Conflicts):列出有冲突的文件和两侧各自做了什么,
/// 选中后可以整个采用我方 / 对方,或者在编辑器里打开手动解决。冲突都解决了就变成「完成合并」。
/// 订阅 [BranchStore]:每次操作完文件列表自己更新。
class ConflictsDialog extends StatefulWidget {
  const ConflictsDialog({
    super.key,
    required this.store,
    required this.accept,
    required this.openFile,
    required this.finish,
    required this.abort,
  });

  final BranchStore store;
  final Future<void> Function(BuildContext context, List<ConflictFile> files, String side) accept;
  final Future<void> Function(String path) openFile;
  final Future<bool> Function(BuildContext context) finish;
  final Future<bool> Function(BuildContext context) abort;

  @override
  State<ConflictsDialog> createState() => _ConflictsDialogState();
}

class _ConflictsDialogState extends State<ConflictsDialog> {
  final Set<String> _selected = {};
  bool _working = false;

  RepoOperation? get _op => widget.store.operation;

  List<ConflictFile> _selectedFiles(RepoOperation op) => [for (final f in op.conflicts) if (_selected.contains(f.path)) f];

  Future<void> _guarded(Future<void> Function() body) async {
    setState(() => _working = true);
    try {
      await body();
    } finally {
      if (mounted) setState(() => _working = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.store,
      builder: (context, _) {
        final op = _op;
        // 操作没了(在别处完成 / 放弃了):窗口没有意义,关掉
        if (op == null) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && Navigator.canPop(context)) Navigator.pop(context);
          });
          return const SizedBox.shrink();
        }
        _selected.removeWhere((p) => !op.conflicts.any((f) => f.path == p));
        // 只有一个冲突文件时默认选中它(IntelliJ 也是),免得还要先点一下才能按按钮
        if (_selected.isEmpty && op.conflicts.length == 1) _selected.add(op.conflicts.first.path);
        final files = _selectedFiles(op);
        final busy = _working || widget.store.busy != null;
        // Yours 永远是自己的分支(变基时 git 的左右是反的,后端已经换过来);Theirs 是合进来的分支,变基时是变基的目标
        final yoursLabel = _sideLabel('Yours', op.branch ?? widget.store.current);
        final theirsLabel = _sideLabel('Theirs', op.kind == 'rebase' ? op.onto : op.incoming);

        return Dialog(
          backgroundColor: IntelliJTheme.panelBg,
          insetPadding: const EdgeInsets.all(24),
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10), side: const BorderSide(color: IntelliJTheme.border)),
          child: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 780, maxHeight: 520),
            child: Padding(
              padding: const EdgeInsets.all(16),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  const Center(child: Text('Conflicts', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 14, fontWeight: FontWeight.w600))),
                  const SizedBox(height: 14),
                  Text.rich(TextSpan(style: _text, children: [
                    for (final (t, bold) in op.describe(widget.store.current)) TextSpan(text: t, style: bold ? const TextStyle(fontWeight: FontWeight.w700) : null),
                  ])),
                  const SizedBox(height: 12),
                  Flexible(
                    child: op.hasConflicts
                        ? Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              Expanded(child: _table(op, yoursLabel, theirsLabel)),
                              const SizedBox(width: 12),
                              SizedBox(
                                width: 150,
                                child: Column(
                                  crossAxisAlignment: CrossAxisAlignment.stretch,
                                  children: [
                                    _button('Accept Yours', files.isEmpty || busy ? null : () => _guarded(() => widget.accept(context, files, 'yours'))),
                                    const SizedBox(height: 8),
                                    _button('Accept Theirs', files.isEmpty || busy ? null : () => _guarded(() => widget.accept(context, files, 'theirs'))),
                                    const SizedBox(height: 8),
                                    // 三栏合并工具还没有:先在编辑器里打开带冲突标记的文件手动改
                                    _button(
                                      'Open File',
                                      files.length != 1 || busy
                                          ? null
                                          : () async {
                                              final path = files.single.path;
                                              Navigator.pop(context);
                                              await widget.openFile(path);
                                            },
                                      primary: true,
                                    ),
                                  ],
                                ),
                              ),
                            ],
                          )
                        : _resolved(op, busy),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    mainAxisAlignment: MainAxisAlignment.spaceBetween,
                    children: [
                      if (op.canAbort)
                        TextButton(
                          onPressed: busy ? null : () => _guarded(() async => await widget.abort(context)),
                          style: TextButton.styleFrom(foregroundColor: const Color(0xFFE5534B)),
                          child: Text('Abort ${op.noun}'),
                        )
                      else
                        const SizedBox.shrink(),
                      OutlinedButton(onPressed: () => Navigator.pop(context), child: const Text('Close')),
                    ],
                  ),
                ],
              ),
            ),
          ),
        );
      },
    );
  }

  static String _sideLabel(String side, String? name) => name == null ? side : '$side ($name)';

  Widget _button(String label, VoidCallback? onTap, {bool primary = false}) {
    final style = primary
        ? FilledButton.styleFrom(backgroundColor: IntelliJTheme.accentBlue, foregroundColor: Colors.white)
        : OutlinedButton.styleFrom(foregroundColor: IntelliJTheme.textHigh, side: const BorderSide(color: IntelliJTheme.border));
    final child = Text(label, overflow: TextOverflow.ellipsis);
    return primary ? FilledButton(onPressed: onTap, style: style, child: child) : OutlinedButton(onPressed: onTap, style: style, child: child);
  }

  Widget _table(RepoOperation op, String yoursLabel, String theirsLabel) {
    return Container(
      decoration: BoxDecoration(border: Border.all(color: IntelliJTheme.border), borderRadius: BorderRadius.circular(4)),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle))),
            child: Row(children: [
              const Expanded(child: Text('Name', style: _head)),
              SizedBox(width: 130, child: Text(yoursLabel, style: _head, overflow: TextOverflow.ellipsis)),
              SizedBox(width: 130, child: Text(theirsLabel, style: _head, overflow: TextOverflow.ellipsis)),
            ]),
          ),
          Flexible(
            child: ListView(
              shrinkWrap: true,
              children: [for (final f in op.conflicts) _row(f)],
            ),
          ),
        ],
      ),
    );
  }

  Widget _row(ConflictFile f) {
    final selected = _selected.contains(f.path);
    return InkWell(
      key: ValueKey('conflict-${f.path}'),
      hoverColor: IntelliJTheme.hoverBg,
      onTap: () => setState(() {
        // ⌘ / Ctrl 点击多选,普通点击只选这一个
        final keys = HardwareKeyboard.instance;
        final multi = keys.isMetaPressed || keys.isControlPressed;
        if (!multi) _selected.clear();
        if (multi && selected) {
          _selected.remove(f.path);
        } else {
          _selected.add(f.path);
        }
      }),
      child: Container(
        height: 28,
        color: selected ? IntelliJTheme.selectionBg : null,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(children: [
          Expanded(
            child: Row(children: [
              Flexible(child: Text(f.name, style: _text, overflow: TextOverflow.ellipsis)),
              if (f.dir.isNotEmpty) ...[
                const SizedBox(width: 8),
                Flexible(flex: 2, child: Text(f.dir, style: _muted, overflow: TextOverflow.ellipsis)),
              ],
            ]),
          ),
          SizedBox(width: 130, child: Text(f.yours, style: _text)),
          SizedBox(width: 130, child: Text(f.theirs, style: _text)),
        ]),
      ),
    );
  }

  /// 冲突都解决了:提示可以完成了。
  Widget _resolved(RepoOperation op, bool busy) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          const Icon(Icons.check_circle_outline, size: 36, color: Color(0xFF5FB865)),
          const SizedBox(height: 10),
          Text(op.canAbort ? '所有冲突都已解决。' : '没有冲突了。', style: _text),
          if (op.canAbort) ...[
            const SizedBox(height: 4),
            Text(op.kind == 'merge' ? '提交合并结果就完成了。' : '继续${op.noun}即可完成。', style: _muted),
            const SizedBox(height: 14),
            FilledButton(
              onPressed: busy
                  ? null
                  : () => _guarded(() async {
                        final ok = await widget.finish(context);
                        if (ok && mounted && Navigator.canPop(context)) Navigator.pop(context);
                      }),
              child: Text(op.kind == 'merge' ? 'Commit Merge' : 'Continue ${op.noun}'),
            ),
          ],
        ],
      ),
    );
  }
}
