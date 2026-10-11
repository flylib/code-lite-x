import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';
import 'editor_session_manager.dart';

/// 编辑区上方的提示条:别处改了这个文件,而这里还有没保存的修改(IntelliJ 的 File Cache Conflict)。
/// 选之前这个标签不自动保存。没有冲突时不占地方。
class DiskConflictBanner extends StatelessWidget {
  const DiskConflictBanner({super.key, required this.sessions, required this.path});

  final EditorSessionManager sessions;
  final String path;

  @override
  Widget build(BuildContext context) {
    if (sessions.tabs[path]?.diskConflict == null) return const SizedBox.shrink();
    return Container(
      key: const ValueKey('disk-conflict-banner'),
      decoration: const BoxDecoration(
        color: Color(0xFF3D3424),
        border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Row(
        children: [
          const Icon(Icons.warning_amber_rounded, size: 16, color: IntelliJTheme.accentYellow),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              '这个文件在磁盘上被改了,而这里还有没保存的修改。选好之前不会自动保存。',
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5),
            ),
          ),
          _Action('载入磁盘版本', () => sessions.loadDiskVersion(path), primary: true),
          _Action('保留我的修改', () => sessions.keepMyChanges(path)),
        ],
      ),
    );
  }
}

class _Action extends StatelessWidget {
  const _Action(this.label, this.onTap, {this.primary = false});

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              label,
              style: TextStyle(color: primary ? IntelliJTheme.accentBlue : IntelliJTheme.textSecondary, fontSize: 12.5, fontWeight: primary ? FontWeight.w600 : FontWeight.normal),
            ),
          ),
        ),
      );
}
