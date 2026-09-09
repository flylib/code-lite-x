import 'package:flutter/material.dart';
import '../../core/theme/intellij_theme.dart';

enum StripeTool { project, structure, git, codegraph, sqlite, terminal }

class ActivityStripeWidget extends StatelessWidget {
  final StripeTool activeTool;
  final ValueChanged<StripeTool> onSelectTool;

  const ActivityStripeWidget({
    super.key,
    required this.activeTool,
    required this.onSelectTool,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 44,
      decoration: const BoxDecoration(
        color: IntelliJTheme.stripeBg,
        border: Border(right: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Top tools
          Column(
            children: [
              _buildStripeIcon(
                icon: Icons.folder_outlined,
                tool: StripeTool.project,
                tooltip: 'Project (Alt+1)',
              ),
              const SizedBox(height: 6),
              _buildStripeIcon(
                icon: Icons.account_tree_outlined,
                tool: StripeTool.structure,
                tooltip: 'Structure (Alt+7)',
                badgeColor: IntelliJTheme.accentYellow,
              ),
              const SizedBox(height: 6),
              _buildStripeIcon(
                icon: Icons.commit,
                tool: StripeTool.git,
                tooltip: 'Git Log & Commit',
              ),
              const SizedBox(height: 6),
              _buildStripeIcon(
                icon: Icons.hub_outlined,
                tool: StripeTool.codegraph,
                tooltip: 'CodeGraph Topology',
                badgeColor: IntelliJTheme.syntaxType,
              ),
              const SizedBox(height: 6),
              _buildStripeIcon(
                icon: Icons.storage_outlined,
                tool: StripeTool.sqlite,
                tooltip: 'SQLite State & Rollback',
                badgeColor: IntelliJTheme.gitYellow,
              ),
            ],
          ),

          // Bottom tools
          Column(
            children: [
              _buildStripeIcon(
                icon: Icons.terminal_outlined,
                tool: StripeTool.terminal,
                tooltip: 'Terminal (Alt+F12)',
              ),
              const SizedBox(height: 6),
              IconButton(
                icon: const Icon(Icons.tune, size: 18, color: IntelliJTheme.textMuted),
                tooltip: 'Settings',
                onPressed: () {},
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildStripeIcon({
    required IconData icon,
    required StripeTool tool,
    required String tooltip,
    Color? badgeColor,
  }) {
    final isActive = activeTool == tool;

    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: () => onSelectTool(tool),
        borderRadius: BorderRadius.circular(6),
        child: Container(
          width: 32,
          height: 32,
          decoration: BoxDecoration(
            color: isActive ? IntelliJTheme.accentBlue : Colors.transparent,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Stack(
            alignment: Alignment.center,
            children: [
              Icon(
                icon,
                size: 18,
                color: isActive ? Colors.white : (badgeColor ?? IntelliJTheme.textPrimary),
              ),
              if (badgeColor != null && !isActive)
                Positioned(
                  top: 5,
                  right: 5,
                  child: Container(
                    width: 4,
                    height: 4,
                    decoration: BoxDecoration(color: badgeColor, shape: BoxShape.circle),
                  ),
                ),
            ],
          ),
        ),
      ),
    );
  }
}
