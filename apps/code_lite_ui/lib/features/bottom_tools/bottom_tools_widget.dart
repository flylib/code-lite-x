import 'package:flutter/material.dart';
import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';
import '../git/git_log_store.dart';
import '../git/git_log_window.dart';
import '../terminal/terminal_store.dart';
import '../terminal/terminal_view.dart';

enum BottomToolTab { git, codegraph, terminal }

class BottomToolsWidget extends StatefulWidget {
  final BottomToolTab activeTab;
  final ValueChanged<BottomToolTab> onSelectTab;
  final ApiClient? client;

  /// 终端会话活在面板之外,面板收起时 shell 不会被杀。
  final TerminalStore? terminals;

  /// Git Log 的筛选、选中项同样活在面板之外。
  final GitLogStore? gitLog;

  /// 项目目录名:Git 详情面板文件树的根节点。
  final String repoName;

  /// 由布局 store 管理,拖动分隔条可调。
  final double height;

  const BottomToolsWidget({
    super.key,
    required this.activeTab,
    required this.onSelectTab,
    this.client,
    this.terminals,
    this.gitLog,
    this.repoName = '',
    this.height = 300,
  });

  @override
  State<BottomToolsWidget> createState() => _BottomToolsWidgetState();
}

class _BottomToolsWidgetState extends State<BottomToolsWidget> {
  late final ApiClient _client;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? ApiClient();
  }

  @override
  Widget build(BuildContext context) {
    final gitLog = widget.gitLog;
    if (widget.activeTab == BottomToolTab.git && gitLog != null) {
      // Git 工具窗同样用 IntelliJ 式独立标题栏(Git | Log)。
      return Container(
        height: widget.height,
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle)),
        ),
        child: GitLogWindow(
          store: gitLog,
          repoName: widget.repoName,
          onHide: () => widget.onSelectTab(BottomToolTab.git),
        ),
      );
    }
    final terminals = widget.terminals;
    if (widget.activeTab == BottomToolTab.terminal && terminals != null) {
      // 终端用 IntelliJ 式的独立标题栏(Terminal | Local × | +),不显示共享标签条。
      return Container(
        height: widget.height,
        decoration: const BoxDecoration(
          border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle)),
        ),
        child: TerminalPanel(
          store: terminals,
          client: _client,
          onHide: () => widget.onSelectTab(BottomToolTab.terminal),
        ),
      );
    }
    return Container(
      height: widget.height,
      decoration: const BoxDecoration(
        color: IntelliJTheme.panelBg,
        border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Column(
        children: [
          // Tab Header
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: const BoxDecoration(
              color: IntelliJTheme.subHeaderBg,
              border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildTab('Git', BottomToolTab.git),
                  _buildTab('CodeGraph Explorer', BottomToolTab.codegraph),
                  _buildTab('Terminal', BottomToolTab.terminal),
                ],
              ),
            ),
          ),

          // Content Panels
          Expanded(
            child: switch (widget.activeTab) {
              BottomToolTab.git => const SizedBox.shrink(),
              BottomToolTab.codegraph => _buildCodeGraphPanel(),
              BottomToolTab.terminal => const SizedBox.shrink(),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTab(String label, BottomToolTab tab) {
    final isActive = widget.activeTab == tab;

    return InkWell(
      onTap: () => widget.onSelectTab(tab),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isActive ? IntelliJTheme.panelBg : Colors.transparent,
          border: Border(
            top: BorderSide(
              color: isActive ? IntelliJTheme.accentBlue : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? IntelliJTheme.textHigh : IntelliJTheme.textMuted,
            fontSize: 11,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  // CodeGraph Explorer Panel
  Widget _buildCodeGraphPanel() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('CodeGraph Dependency & Call Topology', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildGraphNode('CALLER', 'revert_task()', 'op_store.rs:188', IntelliJTheme.gitGreen),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('─────▶', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 14)),
              ),
              _buildGraphNode('TARGET', 'revert()', 'op_store.rs:136', IntelliJTheme.accentBlue),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('─────▶', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 14)),
              ),
              _buildGraphNode('CALLEE', 'fs::write()', 'std::fs', IntelliJTheme.syntaxType),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGraphNode(String role, String symbol, String loc, Color color) {
    return Container(
      width: 140,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: IntelliJTheme.cardBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.7)),
      ),
      child: Column(
        children: [
          Text(role, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(symbol, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
          const SizedBox(height: 2),
          Text(loc, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
        ],
      ),
    );
  }
}
