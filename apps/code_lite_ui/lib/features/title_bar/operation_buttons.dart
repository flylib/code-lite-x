import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';
import '../git/branch_actions.dart';
import '../git/branch_store.dart';

const Color _green = Color(0xFF4C8B50);
const Color _red = Color(0xFFB9504E);

/// 合并 / 变基有冲突时,标题栏分支名旁边的两个按钮(IntelliJ 的做法):
/// 绿色 » 列出有冲突的文件(冲突都解决了就是完成它),红色 × 放弃这次合并 / 变基。
/// 没有进行中的操作时什么也不显示。
class OperationButtons extends StatelessWidget {
  const OperationButtons({super.key, required this.store, required this.actions});

  final BranchStore store;
  final BranchActions actions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final op = store.operation;
        if (op == null) return const SizedBox.shrink();
        final n = op.conflicts.length;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(width: 6),
            _Button(
              key: const ValueKey('operation-conflicts'),
              color: _green,
              icon: Icons.keyboard_double_arrow_right,
              tooltip: op.hasConflicts ? '$n 个文件有冲突,点击查看并解决' : '冲突都解决了,点击完成${op.noun}',
              onTap: () => actions.showConflicts(context),
            ),
            if (op.canAbort) ...[
              const SizedBox(width: 4),
              _Button(
                key: const ValueKey('operation-abort'),
                color: _red,
                icon: Icons.close,
                tooltip: '放弃这次${_zh(op.kind)}(Abort ${op.noun})',
                onTap: () => actions.abortOperation(context),
              ),
            ],
          ],
        );
      },
    );
  }

  static String _zh(String? kind) => switch (kind) {
        'merge' => '合并',
        'rebase' => '变基',
        _ => '操作',
      };
}

class _Button extends StatelessWidget {
  const _Button({super.key, required this.color, required this.icon, required this.tooltip, required this.onTap});

  final Color color;
  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        hoverColor: Colors.white.withValues(alpha: 0.12),
        child: Container(
          width: 34,
          height: 26,
          decoration: BoxDecoration(
            color: color,
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: Colors.white.withValues(alpha: 0.25)),
          ),
          child: Icon(icon, size: 18, color: IntelliJTheme.textHigh),
        ),
      ),
    );
  }
}
