import 'package:flutter/material.dart';
import '../../core/theme/intellij_theme.dart';

class ProjectExplorerWidget extends StatefulWidget {
  final Map<String, dynamic> treeData;
  final String activeFilePath;
  final ValueChanged<String> onSelectFile;

  const ProjectExplorerWidget({
    super.key,
    required this.treeData,
    required this.activeFilePath,
    required this.onSelectFile,
  });

  @override
  State<ProjectExplorerWidget> createState() => _ProjectExplorerWidgetState();
}

class _ProjectExplorerWidgetState extends State<ProjectExplorerWidget> {
  final Set<String> _expandedDirs = {'code-lite-x', 'crates', 'code-lite-core', 'code-lite-storage'};

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 250,
      decoration: const BoxDecoration(
        color: IntelliJTheme.panelBg,
        border: Border(right: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Column(
        children: [
          // Tool window header
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Text('Project', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 4),
                    const Icon(Icons.arrow_drop_down, size: 16, color: IntelliJTheme.textMuted),
                  ],
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.unfold_less, size: 14, color: IntelliJTheme.textMuted),
                      tooltip: 'Collapse All',
                      onPressed: () => setState(() => _expandedDirs.clear()),
                      splashRadius: 12,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Tree contents
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              child: _buildTreeNode(widget.treeData, 0),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildTreeNode(Map<String, dynamic> node, int depth) {
    final name = node['name'] as String? ?? '';
    final isDir = node['is_dir'] as bool? ?? false;
    final path = node['path'] as String? ?? name;
    final children = (node['children'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? [];
    final isExpanded = _expandedDirs.contains(name);
    final isSelected = widget.activeFilePath == path;

    if (isDir) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          InkWell(
            onTap: () {
              setState(() {
                if (isExpanded) {
                  _expandedDirs.remove(name);
                } else {
                  _expandedDirs.add(name);
                }
              });
            },
            child: Container(
              padding: EdgeInsets.only(left: 8.0 + (depth * 12.0), top: 3, bottom: 3, right: 8),
              child: Row(
                children: [
                  Icon(
                    isExpanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
                    size: 14,
                    color: IntelliJTheme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  const Icon(Icons.folder, size: 14, color: IntelliJTheme.gitYellow),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      name,
                      style: const TextStyle(
                        color: IntelliJTheme.textHigh,
                        fontSize: 12,
                        fontWeight: FontWeight.w500,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
          ),
          if (isExpanded)
            ...children.map((child) => _buildTreeNode(child, depth + 1)),
        ],
      );
    } else {
      final isRust = name.endsWith('.rs');
      final isToml = name.endsWith('.toml');
      final isMd = name.endsWith('.md');

      Color iconColor = IntelliJTheme.textMuted;
      String iconLabel = '📄';
      if (isRust) {
        iconColor = const Color(0xFFD87642);
        iconLabel = '⚙';
      } else if (isToml) {
        iconColor = IntelliJTheme.gitYellow;
        iconLabel = '📄';
      } else if (isMd) {
        iconColor = IntelliJTheme.syntaxFunction;
        iconLabel = '📘';
      }

      return InkWell(
        onTap: () => widget.onSelectFile(path),
        child: Container(
          decoration: BoxDecoration(
            color: isSelected ? IntelliJTheme.selectionBg : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
          ),
          padding: EdgeInsets.only(left: 20.0 + (depth * 12.0), top: 3, bottom: 3, right: 8),
          child: Row(
            children: [
              Text(iconLabel, style: TextStyle(color: iconColor, fontSize: 11)),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  name,
                  style: TextStyle(
                    color: isSelected ? const Color(0xFF6CB4F8) : IntelliJTheme.textPrimary,
                    fontSize: 12,
                    fontFamily: 'monospace',
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isSelected)
                Container(
                  width: 4,
                  height: 4,
                  decoration: const BoxDecoration(
                    color: IntelliJTheme.gitGreen,
                    shape: BoxShape.circle,
                  ),
                ),
            ],
          ),
        ),
      );
    }
  }
}
