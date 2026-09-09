import 'package:flutter/material.dart';
import '../../core/theme/intellij_theme.dart';

class TitleBarWidget extends StatelessWidget {
  final String activeFile;
  final VoidCallback onToggleAi;
  final VoidCallback onUndo;
  final VoidCallback onRedo;
  final VoidCallback? onSearch;
  final VoidCallback? onCheckUpdate;
  final String version;

  const TitleBarWidget({
    super.key,
    required this.activeFile,
    required this.onToggleAi,
    required this.onUndo,
    required this.onRedo,
    this.onSearch,
    this.onCheckUpdate,
    this.version = 'v0.1.0',
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 40,
      decoration: const BoxDecoration(
        color: IntelliJTheme.headerBg,
        border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Left: macOS Traffic Lights & Project / Branch Badges
          Flexible(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildTrafficLights(),
                  const SizedBox(width: 12),
                  _buildProjectBadge(),
                  const SizedBox(width: 8),
                  _buildVersionBadge(),
                  const SizedBox(width: 8),
                  _buildBranchBadge(),
                  const SizedBox(width: 12),
                  _buildBreadcrumb(),
                ],
              ),
            ),
          ),

          const SizedBox(width: 8),

          // Center: Search Everywhere Input
          _buildSearchEverywhere(),

          const SizedBox(width: 8),

          // Right: Controls & Run/Debug
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildIconBtn(Icons.undo, onUndo, 'Undo (Cmd+Z)'),
              _buildIconBtn(Icons.redo, onRedo, 'Redo (Cmd+Shift+Z)'),
              const SizedBox(width: 8),
              Container(width: 1, height: 16, color: IntelliJTheme.border),
              const SizedBox(width: 8),
              _buildRunTarget(),
              const SizedBox(width: 4),
              _buildActionBtn(Icons.play_arrow, IntelliJTheme.gitGreen, 'Run (Shift+F10)'),
              _buildActionBtn(Icons.bug_report, IntelliJTheme.syntaxFunction, 'Debug (Shift+F9)'),
              const SizedBox(width: 8),
              _buildAiAgentButton(),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildTrafficLights() {
    return Row(
      children: [
        _circle(const Color(0xFFEC6A5E), const Color(0xFFD15246)),
        const SizedBox(width: 6),
        _circle(const Color(0xFFF4BF4F), const Color(0xFFD7A13C)),
        const SizedBox(width: 6),
        _circle(const Color(0xFF62C554), const Color(0xFF48A93C)),
      ],
    );
  }

  Widget _circle(Color fill, Color border) {
    return Container(
      width: 12,
      height: 12,
      decoration: BoxDecoration(
        color: fill,
        shape: BoxShape.circle,
        border: Border.all(color: border, width: 0.8),
      ),
    );
  }

  Widget _buildProjectBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: IntelliJTheme.panelBg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: IntelliJTheme.border),
      ),
      child: Row(
        children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 1),
            decoration: BoxDecoration(
              color: IntelliJTheme.accentBlue,
              borderRadius: BorderRadius.circular(2),
            ),
            child: const Text('CL', style: TextStyle(color: Colors.white, fontSize: 9, fontWeight: FontWeight.bold)),
          ),
          const SizedBox(width: 6),
          const Text('code-lite-x', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.w600)),
          const SizedBox(width: 4),
          const Text('[Flutter + Rust]', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
        ],
      ),
    );
  }

  Widget _buildVersionBadge() {
    return InkWell(
      onTap: onCheckUpdate,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
        decoration: BoxDecoration(
          color: IntelliJTheme.panelBg,
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: IntelliJTheme.border),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.system_update_alt, size: 12, color: IntelliJTheme.accentBlue),
            const SizedBox(width: 4),
            Text(
              version,
              style: const TextStyle(
                color: IntelliJTheme.textSecondary,
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildBranchBadge() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
      child: const Row(
        children: [
          Icon(Icons.fork_right, size: 14, color: IntelliJTheme.gitGreen),
          SizedBox(width: 4),
          Text('main', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 11, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  Widget _buildBreadcrumb() {
    return Text(
      activeFile,
      style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
      overflow: TextOverflow.ellipsis,
    );
  }

  Widget _buildSearchEverywhere() {
    return InkWell(
      onTap: onSearch,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 180,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: IntelliJTheme.panelBg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: IntelliJTheme.border),
        ),
        child: const Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.search, size: 14, color: IntelliJTheme.textMuted),
                SizedBox(width: 4),
                Text('Search...', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11)),
              ],
            ),
            Text('⇧ ⇧', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 9)),
          ],
        ),
      ),
    );
  }

  Widget _buildRunTarget() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: IntelliJTheme.panelBg,
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: IntelliJTheme.border),
      ),
      child: const Row(
        children: [
          Icon(Icons.circle, size: 6, color: IntelliJTheme.gitGreen),
          SizedBox(width: 4),
          Text('code-lite-desktop', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 11)),
        ],
      ),
    );
  }

  Widget _buildActionBtn(IconData icon, Color color, String tooltip) {
    return IconButton(
      icon: Icon(icon, size: 16, color: color),
      tooltip: tooltip,
      onPressed: () {},
      splashRadius: 14,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }

  Widget _buildIconBtn(IconData icon, VoidCallback onPressed, String tooltip) {
    return IconButton(
      icon: Icon(icon, size: 16, color: IntelliJTheme.textPrimary),
      tooltip: tooltip,
      onPressed: onPressed,
      splashRadius: 14,
      constraints: const BoxConstraints(minWidth: 28, minHeight: 28),
    );
  }

  Widget _buildAiAgentButton() {
    return InkWell(
      onTap: onToggleAi,
      borderRadius: BorderRadius.circular(4),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        decoration: BoxDecoration(
          color: IntelliJTheme.accentBlue.withOpacity(0.15),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(color: IntelliJTheme.accentBlue.withOpacity(0.4)),
        ),
        child: const Row(
          children: [
            Icon(Icons.auto_awesome, size: 13, color: Color(0xFF6CB4F8)),
            SizedBox(width: 4),
            Text('AI Agent', style: TextStyle(color: Color(0xFF6CB4F8), fontSize: 11, fontWeight: FontWeight.bold)),
          ],
        ),
      ),
    );
  }
}
