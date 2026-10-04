import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/client/api_client.dart';
import 'core/state/layout_store.dart';
import 'core/state/scopes.dart';
import 'core/platform/workspace_io.dart' as io;
import 'core/state/workspace_store.dart';
import 'core/theme/intellij_theme.dart';
import 'features/activity_stripe/activity_stripe_widget.dart';
import 'features/activity_stripe/right_activity_stripe.dart';
import 'features/bottom_tools/bottom_tools_widget.dart';
import 'features/cargo/cargo_panel.dart';
import 'features/commit/commit_panel.dart';
import 'features/editor/editor_session_manager.dart';
import 'features/editor/editor_view_widget.dart';
import 'features/git/git_log_store.dart';
import 'features/project_explorer/project_explorer_widget.dart';
import 'features/project_explorer/structure_widget.dart';
import 'features/search/global_search_modal.dart';
import 'features/status_bar/status_bar_widget.dart';
import 'features/terminal/terminal_store.dart';
import 'features/title_bar/title_bar_widget.dart';
import 'features/update/update_modal.dart';

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
  final ApiClient _client = ApiClient(initialRoot: io.noProjectRoot());
  late final EditorSessionManager _sessions;
  late final WorkspaceStore _workspace;
  final LayoutStore _layout = LayoutStore();
  late final TerminalStore _terminals = TerminalStore(_client);
  late final GitLogStore _gitLog = GitLogStore(_client);
  String? _lastRoot;

  @override
  void initState() {
    super.initState();
    _sessions = EditorSessionManager(client: _client);
    _workspace = WorkspaceStore(client: _client, sessions: _sessions);
    _workspace.addListener(_onWorkspaceChanged);
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    await _workspace.bootstrap();
  }

  /// 换了项目:Git Log 里还是旧仓库的数据,作废后在下次显示时重新加载。
  void _onWorkspaceChanged() {
    final root = _workspace.rootPath;
    if (root == _lastRoot) return;
    _lastRoot = root;
    _gitLog.invalidate();
  }

  @override
  void dispose() {
    _workspace.removeListener(_onWorkspaceChanged);
    _gitLog.dispose();
    _terminals.dispose();
    _client.dispose(); // 关掉语言服务器进程
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
            child: _Workbench(client: _client, terminals: _terminals, gitLog: _gitLog),
          ),
        ),
      ),
    );
  }
}

class _Workbench extends StatelessWidget {
  const _Workbench({required this.client, required this.terminals, required this.gitLog});

  final ApiClient client;
  final TerminalStore terminals;
  final GitLogStore gitLog;

  @override
  Widget build(BuildContext context) {
    final workspace = context.workspaceRead;
    final layout = context.layoutRead;
    final sessions = context.sessionRead;

    return _AppMenuBar(
      child: CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true): () => _openSearch(context),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true): () => _openSearch(context),
        const SingleActivator(LogicalKeyboardKey.keyU, meta: true): () => _openUpdates(context),
        const SingleActivator(LogicalKeyboardKey.keyU, control: true): () => _openUpdates(context),
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
                  onUndo: workspace.undo,
                  onRedo: workspace.redo,
                  onSearch: () => _openSearch(context),
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
                            LeftTool.commit => CommitPanel(
                                key: ValueKey(workspace.rootPath),
                                client: client,
                                onOpenFile: workspace.openFile,
                                onCommitted: gitLog.refresh,
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
                              return Column(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                    _BottomResizeHandle(layout: layout),
                                    BottomToolsWidget(
                                      activeTab: layout.bottomTab,
                                      onSelectTab: layout.selectBottomTab,
                                      client: client,
                                      terminals: terminals,
                                      gitLog: gitLog,
                                      repoName: workspace.projectName,
                                      height: layout.bottomHeight,
                                    ),
                                ],
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
          projectName: workspace.projectName,
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

/// 原生菜单栏(macOS)。只订阅 workspace 的最近项目 / 是否有项目,
/// 工作台子树作为 `child` 传入,菜单变化时不会重建它。
class _AppMenuBar extends StatelessWidget {
  const _AppMenuBar({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    // PlatformProvidedMenuItem 在非 macOS 平台会直接抛异常,web / 测试环境不能建。
    if (defaultTargetPlatform != TargetPlatform.macOS) return child;
    final workspace = context.workspaceRead;
    return ListenableBuilder(
      listenable: workspace,
      child: child,
      builder: (context, child) => PlatformMenuBar(
        menus: <PlatformMenuItem>[
          const PlatformMenu(
            label: 'CodeLiteX',
            menus: <PlatformMenuItem>[
              PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.about),
              PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.servicesSubmenu),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
              PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.hideOtherApplications),
              PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.showAllApplications),
              PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
            ],
          ),
          _fileMenu(context, workspace),
          const PlatformMenu(
            label: 'Window',
            menus: <PlatformMenuItem>[
              PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.minimizeWindow),
              PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.zoomWindow),
              PlatformProvidedMenuItem(
                  type: PlatformProvidedMenuItemType.toggleFullScreen),
            ],
          ),
        ],
        child: child!,
      ),
    );
  }

  PlatformMenu _fileMenu(BuildContext context, WorkspaceStore workspace) {
    final recent = workspace.recentProjects;
    return PlatformMenu(
      label: 'File',
      menus: <PlatformMenuItem>[
        PlatformMenuItemGroup(members: <PlatformMenuItem>[
          PlatformMenu(
            label: 'New',
            menus: <PlatformMenuItem>[
              PlatformMenuItem(
                label: 'File…',
                shortcut:
                    const SingleActivator(LogicalKeyboardKey.keyN, meta: true),
                onSelected: workspace.hasProject
                    ? () => _newFile(context, workspace)
                    : null,
              ),
            ],
          ),
          PlatformMenuItem(
            label: 'Open…',
            shortcut:
                const SingleActivator(LogicalKeyboardKey.keyO, meta: true),
            onSelected: () => _openFolder(context, workspace),
          ),
          PlatformMenu(
            label: 'Recent Projects',
            menus: <PlatformMenuItem>[
              PlatformMenuItemGroup(members: <PlatformMenuItem>[
                if (recent.isEmpty)
                  const PlatformMenuItem(label: 'No Recent Projects')
                else
                  for (final path in recent)
                    PlatformMenuItem(
                      label: _recentLabel(path),
                      onSelected: () => _openRecent(context, workspace, path),
                    ),
              ]),
              if (recent.isNotEmpty)
                PlatformMenuItemGroup(members: <PlatformMenuItem>[
                  PlatformMenuItem(
                      label: 'Clear Recent Projects',
                      onSelected: workspace.clearRecentProjects),
                ]),
            ],
          ),
          PlatformMenuItem(
            label: 'Close Project',
            onSelected: workspace.hasProject
                ? () => _closeProject(context, workspace)
                : null,
          ),
        ]),
        PlatformMenuItemGroup(members: <PlatformMenuItem>[
          // ⌘S 已由编辑器自己处理,这里不再绑定快捷键以免触发两次。
          PlatformMenuItem(
              label: 'Save',
              onSelected: workspace.hasProject ? workspace.save : null),
        ]),
      ],
    );
  }

  /// "name — ~/path":同名目录靠路径区分,与 IntelliJ 的 Recent Projects 一致。
  static String _recentLabel(String path) {
    final name = path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;
    return '$name — $path';
  }

  /// 切换项目会丢弃未保存的标签,有脏标签时先确认。
  Future<bool> _confirmDiscard(
      BuildContext context, WorkspaceStore workspace) async {
    if (!workspace.sessions.hasDirtyTabs) return true;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('有未保存的修改'),
        content: const Text('继续将丢弃这些修改。'),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, true),
              child: const Text('丢弃并继续')),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<void> _openFolder(
      BuildContext context, WorkspaceStore workspace) async {
    final path = await io.pickDirectory();
    if (path == null || !context.mounted) return;
    if (!await _confirmDiscard(context, workspace) || !context.mounted) return;
    await _open(context, workspace, path);
  }

  Future<void> _openRecent(
      BuildContext context, WorkspaceStore workspace, String path) async {
    if (!await _confirmDiscard(context, workspace) || !context.mounted) return;
    await _open(context, workspace, path);
  }

  Future<void> _open(
      BuildContext context, WorkspaceStore workspace, String path) async {
    final ok = await workspace.openFolder(path);
    if (!ok && context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('无法打开项目: $path')));
    }
  }

  Future<void> _closeProject(
      BuildContext context, WorkspaceStore workspace) async {
    if (!await _confirmDiscard(context, workspace)) return;
    workspace.closeProject();
  }

  Future<void> _newFile(BuildContext context, WorkspaceStore workspace) async {
    final controller = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('New File'),
        content: SizedBox(
          width: 380,
          child: TextField(
            controller: controller,
            autofocus: true,
            decoration:
                const InputDecoration(hintText: 'path/to/file.rs(相对项目根目录)'),
            onSubmitted: (v) => Navigator.pop(ctx, v),
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx), child: const Text('取消')),
          TextButton(
              onPressed: () => Navigator.pop(ctx, controller.text),
              child: const Text('创建')),
        ],
      ),
    );
    controller.dispose();
    if (name == null || !context.mounted) return;
    final err = await workspace.createFile(name);
    if (err != null && context.mounted) {
      ScaffoldMessenger.maybeOf(context)
          ?.showSnackBar(SnackBar(content: Text('创建失败: $err')));
    }
  }
}

/// 编辑区与底部工具窗之间的分隔条,上下拖动调整底部高度(与 IntelliJ 一致)。
class _BottomResizeHandle extends StatelessWidget {
  const _BottomResizeHandle({required this.layout});

  final LayoutStore layout;

  @override
  Widget build(BuildContext context) {
    return MouseRegion(
      cursor: SystemMouseCursors.resizeRow,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onVerticalDragUpdate: (d) {
          // 编辑区至少留 160px。
          final max = MediaQuery.sizeOf(context).height - 160 - IntelliJMetrics.titleBar;
          layout.resizeBottom(layout.bottomHeight - d.delta.dy, maxHeight: max);
        },
        child: const SizedBox(height: 4, width: double.infinity),
      ),
    );
  }
}
