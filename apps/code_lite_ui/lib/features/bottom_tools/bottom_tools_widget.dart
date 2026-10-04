import 'package:flutter/material.dart';

import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';
import '../git/git_log_store.dart';
import '../git/git_log_window.dart';
import '../terminal/terminal_store.dart';
import '../terminal/terminal_view.dart';

enum BottomToolTab { git, terminal }

/// 底部工具窗:Git(Log)与终端。两者都有 IntelliJ 式的独立标题栏,
/// 所以这里只负责按选中项切换、给出高度和顶部分隔线。
class BottomToolsWidget extends StatelessWidget {
  const BottomToolsWidget({
    super.key,
    required this.activeTab,
    required this.onSelectTab,
    required this.client,
    required this.terminals,
    required this.gitLog,
    this.repoName = '',
    this.height = 300,
  });

  final BottomToolTab activeTab;

  /// 再次选中当前标签即收起底栏(标题栏的"隐藏"按钮走这里)。
  final ValueChanged<BottomToolTab> onSelectTab;
  final ApiClient client;

  /// 终端会话活在面板之外,面板收起时 shell 不会被杀。
  final TerminalStore terminals;

  /// Git Log 的筛选、选中项同样活在面板之外。
  final GitLogStore gitLog;

  /// 项目目录名:Git 详情面板文件树的根节点。
  final String repoName;

  /// 由布局 store 管理,拖动分隔条可调。
  final double height;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: height,
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: switch (activeTab) {
        BottomToolTab.git => GitLogWindow(
            store: gitLog,
            repoName: repoName,
            onHide: () => onSelectTab(BottomToolTab.git),
          ),
        BottomToolTab.terminal => TerminalPanel(
            store: terminals,
            client: client,
            onHide: () => onSelectTab(BottomToolTab.terminal),
          ),
      },
    );
  }
}
