import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/client/api_client.dart';
import 'core/state/layout_store.dart';
import 'core/state/scopes.dart';
import 'core/state/workspace_store.dart';
import 'core/theme/intellij_theme.dart';
import 'features/activity_stripe/activity_stripe_widget.dart';
import 'features/activity_stripe/right_activity_stripe.dart';
import 'features/ai_assistant/ai_assistant_panel.dart';
import 'features/bottom_tools/bottom_tools_widget.dart';
import 'features/cargo/cargo_panel.dart';
import 'features/editor/editor_session_manager.dart';
import 'features/editor/editor_view_widget.dart';
import 'features/project_explorer/project_explorer_widget.dart';
import 'features/project_explorer/structure_widget.dart';
import 'features/search/global_search_modal.dart';
import 'features/status_bar/status_bar_widget.dart';
import 'features/title_bar/title_bar_widget.dart';
import 'features/update/update_modal.dart';
import 'features/plugins/plugins_modal.dart';

/// 应用根:建 store,挂 scope,之后不再持有可变 UI 状态。
///
/// 此前这里用 `_sessionManager.addListener(() => setState(...))`,
/// 每次按键重建整棵树(项目树、底部日志、右侧面板全都重建)。
/// 现在各区域各自订阅需要的 store,按键只重建编辑区。
class CodeLiteApp extends StatefulWidget {
  const CodeLiteApp({super.key});

  @override
  State<CodeLiteApp> createState() => _CodeLiteAppState();
}

class _CodeLiteAppState extends State<CodeLiteApp> {
  final ApiClient _client = ApiClient();
  late final EditorSessionManager _sessions;
  late final WorkspaceStore _workspace;
  final LayoutStore _layout = LayoutStore();

  @override
  void initState() {
    super.initState();
    _sessions = EditorSessionManager(client: _client);
    _workspace = WorkspaceStore(client: _client, sessions: _sessions);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _workspace.load();
    const seed = 'crates/code-lite-agent/src/planner.rs';
    await _workspace.openFile(seed);
  }

  @override
  void dispose() {
    _layout.dispose();
    _workspace.dispose();
    _sessions.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CodeLiteX',
      debugShowCheckedModeBanner: false,
      theme: IntelliJTheme.darkTheme,
      home: LayoutScope(
        notifier: _layout,
        child: WorkspaceScope(
          notifier: _workspace,
          child: SessionScope(
            notifier: _sessions,
            child: _Workbench(client: _client),
          ),
        ),
      ),
    );
  }
}

class _Workbench extends StatelessWidget {
  const _Workbench({required this.client});

  final ApiClient client;

  @override
  Widget build(BuildContext context) {
    final workspace = context.workspaceRead;
    final layout = context.layoutRead;
    final sessions = context.sessionRead;

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true): () => _openSearch(context),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true): () => _openSearch(context),
        const SingleActivator(LogicalKeyboardKey.keyU, meta: true): () => _openUpdates(context),
        const SingleActivator(LogicalKeyboardKey.keyU, control: true): () => _openUpdates(context),
        const SingleActivator(LogicalKeyboardKey.keyX, meta: true, shift: true): () => _openPlugins(context),
        const SingleActivator(LogicalKeyboardKey.keyX, control: true, shift: true): () => _openPlugins(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: IntelliJTheme.editorBg,
          body: Column(
            children: [
              // 标题栏只关心当前文件名,订阅 workspace 即可。
              ListenableBuilder(
                listenable: workspace,
                builder: (context, _) => TitleBarWidget(
                  activeFile: workspace.activeFile,
                  onToggleAi: () => layout.selectRightTool(RightTool.assistant),
                  onUndo: workspace.undo,
                  onRedo: workspace.redo,
                  onSearch: () => _openSearch(context),
                  onCheckUpdate: () => _openUpdates(context),
                ),
              ),

              Expanded(
                child: Row(
                  children: [
                    // 左活动条:只订阅 layout。
                    ListenableBuilder(
                      listenable: layout,
                      builder: (context, _) => ActivityStripeWidget(
                        leftTool: layout.leftTool,
                        isLeftOpen: layout.isLeftOpen,
                        bottomTab: layout.bottomTab,
                        isBottomOpen: layout.isBottomOpen,
                        onSelectLeftTool: layout.selectLeftTool,
                        onSelectBottomTab: layout.selectBottomTab,
                        onOpenPlugins: () => _openPlugins(context),
                      ),
                    ),

                    // 左工具窗:layout 决定显示哪个,workspace 提供数据。
                    ListenableBuilder(
                      listenable: layout,
                      builder: (context, _) {
                        if (!layout.isLeftOpen) return const SizedBox.shrink();
                        return ListenableBuilder(
                          listenable: workspace,
                          builder: (context, _) => switch (layout.leftTool) {
                            LeftTool.project => ProjectExplorerWidget(
                                treeData: workspace.tree,
                                activeFilePath: workspace.activeFile,
                                onSelectFile: workspace.openFile,
                              ),
                            LeftTool.structure => SizedBox(
                                width: IntelliJMetrics.sidePanel,
                                child: StructureWidget(
                                  activeFile: workspace.activeFile,
                                  outline: workspace.outline,
                                  onSelectSymbol: (sym) => workspace.selectSymbol(sym['name'] as String?),
                                ),
                              ),
                          },
                        );
                      },
                    ),

                    // 中间:编辑区 + 底部工具窗。
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(child: _EditorRegion(client: client)),
                          ListenableBuilder(
                            listenable: layout,
                            builder: (context, _) {
                              if (!layout.isBottomOpen) return const SizedBox.shrink();
                              return BottomToolsWidget(
                                activeTab: layout.bottomTab,
                                onSelectTab: layout.selectBottomTab,
                                onRevertTask: () => _revertTask(context),
                                client: client,
                              );
                            },
                          ),
                        ],
                      ),
                    ),

                    // 右工具窗 + 右活动条。
                    ListenableBuilder(
                      listenable: layout,
                      builder: (context, _) => Row(
                        children: [
                          switch (layout.rightTool) {
                            RightTool.none => const SizedBox.shrink(),
                            RightTool.cargo => ListenableBuilder(
                                listenable: workspace,
                                builder: (context, _) => CargoPanel(
                                  client: client,
                                  tree: workspace.tree,
                                  onClose: layout.closeRight,
                                ),
                              ),
                            RightTool.assistant => ListenableBuilder(
                                listenable: workspace,
                                builder: (context, _) => AiAssistantPanel(
                                  activeFile: workspace.activeFile,
                                  onClose: layout.closeRight,
                                ),
                              ),
                          },
                          RightActivityStripe(
                            rightTool: layout.rightTool,
                            onSelectRightTool: layout.selectRightTool,
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),

              // 状态栏:文件与诊断来自 workspace,行列号在内部订阅 controller。
              ListenableBuilder(
                listenable: workspace,
                builder: (context, _) => StatusBarWidget(
                  activeFile: workspace.activeFile,
                  diagnostics: workspace.diagnostics,
                  branch: 'main',
                  controller: sessions.activeTab?.controller,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  void _openSearch(BuildContext context) {
    final workspace = context.workspaceRead;
    GlobalSearchModal.show(
      context,
      client: client,
      onNavigate: (path, line) => workspace.openFile(path),
    );
  }

  void _openUpdates(BuildContext context) {
    UpdateModal.show(context, client: client, currentVersion: '0.1.0');
  }

  void _openPlugins(BuildContext context) {
    PluginsModal.show(context, client: client);
  }

  Future<void> _revertTask(BuildContext context) async {
    final workspace = context.workspaceRead;
    await client.revertTask('task-104');
    await workspace.openFile(workspace.activeFile);
  }
}

/// 编辑区。只订阅会话层 —— 换标签、分屏会重建这里,
/// 但项目树、底部日志、右侧面板不动。
class _EditorRegion extends StatelessWidget {
  const _EditorRegion({required this.client});

  final ApiClient client;

  @override
  Widget build(BuildContext context) {
    final sessions = context.sessionRead;
    final workspace = context.workspaceRead;

    return ListenableBuilder(
      listenable: sessions,
      builder: (context, _) {
        final active = sessions.activeTab;

        return EditorViewWidget(
          openTabs: sessions.openPaths,
          activeFile: sessions.activePath ?? '',
          codeContent: active?.controller.text ?? '',
          activeSymbol: workspace.activeSymbol,
          diagnostics: active?.diagnostics ?? const [],
          controller: active?.controller,
          verticalScroll: active?.verticalScroll,
          horizontalScroll: active?.horizontalScroll,
          onSelectTab: workspace.openFile,
          onCloseTab: (path) => _closeTab(context, path),
          onCodeChanged: (_) {},
          onSave: workspace.save,
          onUndo: workspace.undo,
          onRedo: workspace.redo,
          isTabDirty: workspace.isDirty,
          apiClient: client,
          splitDirection: sessions.splitDirection,
          secondaryTab: sessions.secondaryTab,
          onSplitChange: (dir) => sessions.splitPane(dir),
          onCloseSplit: sessions.closeSplit,
          onReorderTabs: workspace.reorderTabs,
          onCloseActiveTab: () => _closeTab(context, sessions.activePath ?? ''),
          onSelectSecondaryTab: sessions.selectSecondaryTab,
          onRevertFile: workspace.openFile,
        );
      },
    );
  }

  void _closeTab(BuildContext context, String path) {
    if (path.isEmpty) return;
    final workspace = context.workspaceRead;

    if (!workspace.isDirty(path)) {
      workspace.closeTab(path);
      return;
    }

    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: const Text('保存改动？', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 14)),
        content: Text(
          '${path.split('/').last} 有未保存的改动。',
          style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12),
        ),
        actions: [
          TextButton(
            onPressed: () {
              Navigator.of(ctx).pop();
              workspace.closeTab(path, force: true);
            },
            child: const Text('不保存', style: TextStyle(color: IntelliJTheme.gitRed)),
          ),
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消', style: TextStyle(color: IntelliJTheme.textMuted)),
          ),
          ElevatedButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              await workspace.save();
              workspace.closeTab(path, force: true);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
