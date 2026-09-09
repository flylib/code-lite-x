import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';
import '../editor/code_editor_controller.dart';
import '../editor/lsp_overlay.dart';

/// 底部状态栏。左侧是当前文件在工作区里的位置,右侧是光标位置与文件属性。
///
/// 之前这里显示的是 "Flutter Engine: Impeller (120 FPS)" / "Rust Core: Online" /
/// "SQLite WAL: Active" —— 那些是实现细节,不是使用者能操作或需要判断的东西。
/// 现在只留能据此做决定的信息:改到第几行、有几个错误、换行符和缩进是什么。
class StatusBarWidget extends StatelessWidget {
  const StatusBarWidget({
    super.key,
    required this.activeFile,
    required this.diagnostics,
    required this.branch,
    this.controller,
    this.isSaving = false,
  });

  final String activeFile;
  final List<EditorDiagnostic> diagnostics;
  final String branch;
  final CodeEditorController? controller;
  final bool isSaving;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: IntelliJMetrics.statusBar,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: IntelliJTheme.headerBg,
        border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(child: _buildBreadcrumb()),
          const SizedBox(width: 12),
          _buildDiagnostics(),
          _buildCaretPosition(),
          const _StatusText('LF'),
          const _StatusText('UTF-8'),
          const _StatusText('4 spaces'),
          const SizedBox(width: 4),
          const Icon(Icons.call_split, size: 12, color: IntelliJTheme.gitGreen),
          const SizedBox(width: 4),
          Text(
            branch,
            style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  Widget _buildBreadcrumb() {
    if (activeFile.isEmpty) {
      return const Text(
        '打开一个文件开始编辑',
        style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10),
      );
    }

    final segments = activeFile.split('/');
    final fileName = segments.removeLast();
    final dir = segments.join('/');

    return Row(
      children: [
        const Icon(Icons.description_outlined, size: 12, color: IntelliJTheme.textMuted),
        const SizedBox(width: 5),
        if (dir.isNotEmpty) ...[
          Flexible(
            child: Text(
              dir,
              style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 3),
            child: Icon(Icons.chevron_right, size: 12, color: IntelliJTheme.textGutter),
          ),
        ],
        Text(
          fileName,
          style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 10),
        ),
        if (isSaving) ...[
          const SizedBox(width: 8),
          const Text('保存中…', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
        ],
      ],
    );
  }

  Widget _buildDiagnostics() {
    final errors = diagnostics.where((d) => d.isError).length;
    final warnings = diagnostics.where((d) => d.isWarning).length;

    if (errors > 0) {
      return _StatusChip(
        icon: Icons.error_outline,
        color: IntelliJTheme.diagError,
        label: '$errors 个错误',
        emphasize: true,
      );
    }
    if (warnings > 0) {
      return _StatusChip(
        icon: Icons.warning_amber_rounded,
        color: IntelliJTheme.diagWarning,
        label: '$warnings 个警告',
      );
    }
    return const _StatusChip(
      icon: Icons.check_circle_outline,
      color: IntelliJTheme.gitGreen,
      label: 'rust-analyzer',
    );
  }

  Widget _buildCaretPosition() {
    final c = controller;
    if (c == null) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final pos = c.cursorPosition;
        return _StatusText('${pos.line + 1}:${pos.col + 1}');
      },
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        label,
        style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10, fontFamily: 'monospace'),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.color,
    required this.label,
    this.emphasize = false,
  });

  final IconData icon;
  final Color color;
  final String label;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: emphasize ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}
