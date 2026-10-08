import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/client/api_client.dart';
import 'core/state/layout_store.dart';
import 'core/state/scopes.dart';
import 'core/plugins/plugin_manager.dart';
import 'core/state/settings_store.dart';
import 'core/platform/workspace_io.dart' as io;
import 'core/state/workspace_store.dart';
import 'core/theme/intellij_theme.dart';
import 'features/activity_stripe/activity_stripe_widget.dart';
import 'features/bottom_tools/bottom_tools_widget.dart';
import 'features/build_tools/build_tools_panel.dart';
import 'features/build_tools/build_tools_store.dart';
import 'features/commit/commit_panel.dart';
import 'features/commit/diff_tab.dart';
import 'features/editor/code_editor_controller.dart' show EditorPosition;
import 'features/editor/editor_session_manager.dart';
import 'features/editor/editor_view_widget.dart';
import 'features/git/branch_actions.dart';
import 'features/git/branch_store.dart';
import 'features/git/git_log_store.dart';
import 'features/plugins/plugin_banner.dart';
import 'features/project_explorer/project_explorer_widget.dart';
import 'features/pull_requests/pr_diff_tab.dart';
import 'features/pull_requests/pr_panel.dart';
import 'features/pull_requests/pr_store.dart';
import 'features/pull_requests/pr_timeline_tab.dart';
import 'features/project_explorer/structure_widget.dart';
import 'features/search/global_search_modal.dart';
import 'features/settings/settings_dialog.dart';
import 'features/status_bar/status_bar_widget.dart';
import 'features/terminal/terminal_store.dart';
import 'features/title_bar/branch_menu.dart';
import 'features/title_bar/project_dialogs.dart';
import 'features/title_bar/project_menu.dart';
import 'features/title_bar/title_bar_widget.dart';

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
  late final BranchStore _branches = BranchStore(_client);
  late final BranchActions _branchActions = BranchActions(_branches, showCommitWindow: () => _layout.showLeftTool(LeftTool.commit));
  late final PullRequestsStore _prs = PullRequestsStore(_client);
  late final SettingsStore _settings = SettingsStore(sessions: _sessions);
  late final PluginManager _plugins = PluginManager(client: _client);
  late final BuildToolsStore _build = BuildToolsStore(
    plugins: _plugins,
    projectRoot: () => _workspace.rootPath,
    read: (path) async {
      final res = await _client.fetchFile(path);
      return res['status'] == 'ok' ? res['content'] as String? : null;
    },
    runner: (title, command) {
      _terminals.run(title, command);
      _layout.showBottomTab(BottomToolTab.terminal);
    },
    fileSaved: _client.onFileSaved,
    windows: defaultTargetPlatform == TargetPlatform.windows,
  );
  String? _lastRoot;

  @override
  void initState() {
    super.initState();
    _sessions = EditorSessionManager(client: _client);
    _workspace = WorkspaceStore(client: _client, sessions: _sessions);
    _workspace.addListener(_onWorkspaceChanged);
    _branches.onChanged = _onRepoChanged;
    _build.addListener(_onBuildToolsChanged);
    // 自动保存:应用失去焦点(切到终端 / 浏览器)时立刻把改动写盘,外部工具看到的就是最新内容。
    _lifecycle = AppLifecycleListener(onInactive: _sessions.saveAll, onHide: _sessions.saveAll);
    _bootstrap();
  }

  late final AppLifecycleListener _lifecycle;

  Future<void> _bootstrap() async {
    // 先接入已装插件(着色规则、语言服务器启动方式),再打开上次的项目
    _plugins.load();
    await _settings.load();
    await _workspace.bootstrap();
  }

  /// 换了项目:Git Log 里还是旧仓库的数据,作废后在下次显示时重新加载。
  void _onWorkspaceChanged() {
    final root = _workspace.rootPath;
    if (root == _lastRoot) return;
    _lastRoot = root;
    _gitLog.invalidate();
    _prs.invalidate();
    // 只在有项目时关注分支;没有项目(启动时、关闭项目后)不起任何 git 进程和定时器
    _branches.reset();
    _build.reload();
    if (root != null) {
      _branches.start();
    } else {
      _branches.stop();
    }
  }

  /// 新项目里没有构建工具了:构建工具窗的按钮会消失,开着的窗口换回项目视图。
  void _onBuildToolsChanged() {
    if (_build.hasProjects || _build.loading) return;
    if (_layout.isLeftOpen && _layout.leftTool == LeftTool.build) _layout.showLeftTool(LeftTool.project);
  }

  /// git 动了仓库(切分支 / 更新 / 合并 / 变基 ……,或者别处在终端里切了分支):
  /// 日志窗要跟上;文件内容变了的话,文件树和没有未保存修改的标签也要。
  void _onRepoChanged(bool worktreeChanged) {
    if (_layout.isBottomOpen && _layout.bottomTab == BottomToolTab.git) {
      _gitLog.refresh();
    } else {
      _gitLog.invalidate();
    }
    if (!worktreeChanged) return;
    _workspace.load();
    // 有未保存修改的标签不动:那是用户正在写的东西,不能被磁盘上的内容盖掉
    _sessions.reloadFromDisk([
      for (final path in _sessions.tabs.keys)
        if (!_sessions.isTabDirty(path)) path,
    ]);
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _workspace.removeListener(_onWorkspaceChanged);
    _branches.dispose();
    _gitLog.dispose();
    _prs.dispose();
    _settings.dispose(); // 先于 _sessions:它监听 sessions.appearance
    _build.removeListener(_onBuildToolsChanged);
    _build.dispose(); // 先于 _plugins:它监听插件的启用 / 停用
    _plugins.dispose();
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
            child: _Workbench(client: _client, terminals: _terminals, gitLog: _gitLog, branches: _branches, branchActions: _branchActions, prs: _prs, settings: _settings, plugins: _plugins, buildTools: _build),
          ),
        ),
      ),
    );
  }
}

class _Workbench extends StatelessWidget {
  const _Workbench({
    required this.client,
    required this.terminals,
    required this.gitLog,
    required this.branches,
    required this.branchActions,
    required this.prs,
    required this.settings,
    required this.plugins,
    required this.buildTools,
  });

  final ApiClient client;
  final TerminalStore terminals;
  final GitLogStore gitLog;
  final BranchStore branches;
  final BranchActions branchActions;
  final PullRequestsStore prs;
  final SettingsStore settings;
  final PluginManager plugins;
  final BuildToolsStore buildTools;

  @override
  Widget build(BuildContext context) {
    final workspace = context.workspaceRead;
    final layout = context.layoutRead;
    final sessions = context.sessionRead;

    return _AppMenuBar(
      settings: settings,
      plugins: plugins,
      branches: branches,
      branchActions: branchActions,
      child: CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        // macOS 由系统菜单的 ⌘, 处理;其它平台没有菜单栏,用 IntelliJ 的 Ctrl+Alt+S。
        if (defaultTargetPlatform != TargetPlatform.macOS) ...{
          const SingleActivator(LogicalKeyboardKey.keyS, control: true, alt: true): () => showSettingsDialog(context, settings, plugins: plugins),
          const SingleActivator(LogicalKeyboardKey.comma, control: true): () => showSettingsDialog(context, settings, plugins: plugins),
        },
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true): () => _openSearch(context),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true): () => _openSearch(context),
      },
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: IntelliJTheme.editorBg,
          body: Column(
            children: [
              // 标题栏订阅 workspace(当前文件、项目);分支那一块自己订阅 BranchStore。
              ListenableBuilder(
                listenable: workspace,
                builder: (context, _) => TitleBarWidget(
                  activeFile: workspace.activeFile,
                  onUndo: workspace.undo,
                  onRedo: workspace.redo,
                  onSearch: () => _openSearch(context),
                  projectChip: ProjectChip(
                    projectPath: workspace.rootPath,
                    recent: workspace.recentProjects,
                    home: io.homeDirectory(),
                    onSwitch: (path) => _openRecent(context, workspace, path),
                    onNewProject: () => _newProject(context, workspace),
                    onOpen: () => _openFolder(context, workspace),
                    onClone: () => _cloneRepository(context, workspace),
                  ),
                  branchChip: BranchChip(store: branches, actions: branchActions),
                ),
              ),

              Expanded(
                child: Row(
                  children: [
                    // 左活动条:订阅 layout,以及构建工具(检测到 Maven 等才出现它的按钮)。
                    ListenableBuilder(
                      listenable: Listenable.merge([layout, buildTools]),
                      builder: (context, _) => ActivityStripeWidget(
                        buildToolTitle: buildTools.hasProjects ? buildTools.title : null,
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
                        final panel = ListenableBuilder(
                          listenable: workspace,
                          builder: (context, _) => switch (layout.leftTool) {
                            LeftTool.project => ProjectExplorerWidget(
                                treeData: workspace.tree,
                                activeFilePath: workspace.activeFile,
                                onSelectFile: workspace.openFile,
                                onLoadChildren: client.listDirectory,
                              ),
                            LeftTool.commit => CommitPanel(
                                key: ValueKey(workspace.rootPath),
                                client: client,
                                onOpenDiff: workspace.openDiff,
                                onOpenFile: workspace.openFile,
                                onCommitted: gitLog.refresh,
                                onFilesReverted: sessions.reloadFromDisk,
                              ),
                            LeftTool.pullRequests => PullRequestsPanel(
                                store: prs,
                                onOpenDiff: (number, path) {
                                  prs.session(number).showFile(path);
                                  workspace.openSpecial('$prDiffTabPrefix$number');
                                },
                                onOpenTimeline: (number) => workspace.openSpecial('$prTimelineTabPrefix$number'),
                              ),
                            LeftTool.structure => StructureWidget(
                                activeFile: workspace.activeFile,
                                outline: workspace.outline,
                                onSelectSymbol: (sym) => workspace.selectSymbol(sym['name'] as String?),
                              ),
                            LeftTool.build => BuildToolsPanel(store: buildTools, onOpenFile: workspace.openFile),
                          },
                        );
                        return Row(
                          children: [
                            SizedBox(width: layout.leftWidth, child: panel),
                            _SideResizeHandle(layout: layout),
                          ],
                        );
                      },
                    ),

                    // 中间:编辑区 + 底部工具窗。
                    Expanded(
                      child: Column(
                        children: [
                          Expanded(child: _EditorRegion(client: client, gitLog: gitLog, prs: prs, plugins: plugins)),
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
                  ],
                ),
              ),

              // 状态栏:文件与诊断来自 workspace,行列号在内部订阅 controller。
              ListenableBuilder(
                listenable: workspace,
                builder: (context, _) => StatusBarWidget(
                  activeFile: workspace.activeFile,
                  diagnostics: workspace.diagnostics,
                  controller: sessions.activeTab?.controller,
                  client: client,
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

}

/// 编辑区。只订阅会话层 —— 换标签、分屏会重建这里,
/// 但项目树、底部日志、右侧面板不动。
class _EditorRegion extends StatelessWidget {
  const _EditorRegion({required this.client, required this.gitLog, required this.prs, required this.plugins});

  final ApiClient client;
  final GitLogStore gitLog;
  final PullRequestsStore prs;
  final PluginManager plugins;

  /// PR 差异里「打开本地文件」:[repoPath] 相对仓库根,换算成相对项目的路径(项目可能是仓库的子目录)。
  Future<void> _openPrLocal(BuildContext context, String repoPath, int line) async {
    final workspace = context.workspaceRead;
    final sessions = context.sessionRead;
    final info = await client.gitCall('git.repo_info');
    final prefix = info['status'] == 'ok' ? info['prefix'] as String? ?? '' : '';
    final top = info['toplevel'] as String?;
    final path = prefix.isEmpty
        ? repoPath
        : repoPath.startsWith(prefix)
            ? repoPath.substring(prefix.length)
            : (top == null ? repoPath : '$top/$repoPath');
    await _openSourceAt(workspace, sessions, path, line);
  }

  Widget? _specialTab(BuildContext context, String id, WorkspaceStore workspace, EditorSessionManager sessions) {
    if (sessions.isDiffTab(id)) {
      return DiffTab(
        key: ValueKey(id),
        client: client,
        repoPath: id.substring(diffTabPrefix.length),
        findOpenController: (path) => sessions.tabs[path]?.controller,
        onOpenSource: (path, line) => _openSourceAt(workspace, sessions, path, line),
      );
    }
    final number = prNumberOfTab(id);
    if (number == null) return null;
    if (id.startsWith(prDiffTabPrefix)) {
      return PrDiffTab(
        key: ValueKey(id),
        session: prs.session(number),
        onOpenLocal: (path, line) => _openPrLocal(context, path, line),
      );
    }
    return PrTimelineTab(key: ValueKey(id), session: prs.session(number));
  }

  String? _specialTitle(String id) {
    if (!id.startsWith(prTimelineTabPrefix)) return null;
    final number = prNumberOfTab(id);
    if (number == null) return null;
    final title = prs.session(number).detail?.title ?? prs.summaryOf(number)?.title;
    return title == null ? null : '$title #$number';
  }

  /// 差异视图的「跳到源文件」:打开文件,光标放到 [line] 并滚动到可见处。
  Future<void> _openSourceAt(WorkspaceStore workspace, EditorSessionManager sessions, String path, int line) async {
    await workspace.openFile(path);
    final tab = sessions.tabs[path];
    if (tab == null) return;
    tab.controller.setCursor(EditorPosition(line, 0));
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final scroll = tab.verticalScroll;
      if (!scroll.hasClients) return;
      final target = (line * sessions.appearance.lineHeight - scroll.position.viewportDimension / 3).clamp(0.0, scroll.position.maxScrollExtent);
      scroll.jumpTo(target);
    });
  }

  /// Blame 菜单的 Show in File History:打开底部 Git 窗口,按该文件筛选并选中这个提交。
  Future<void> _showInHistory(BuildContext context, String hash, String path) async {
    final layout = context.layoutRead;
    if (!layout.isBottomOpen || layout.bottomTab != BottomToolTab.git) {
      layout.selectBottomTab(BottomToolTab.git);
    }
    gitLog.ensureLoaded();
    gitLog.setPaths([path]);
    // setPaths 会异步重载,等新列表出来再定位(最多等 10 秒)。
    for (var i = 0; i < 200 && gitLog.loading; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    await gitLog.reveal(hash);
  }

  @override
  Widget build(BuildContext context) {
    final sessions = context.sessionRead;
    final workspace = context.workspaceRead;

    // 插件变化(装好 / 卸载)要重新着色、显示 / 收起提示条:一并订阅(很少触发)。
    return ListenableBuilder(
      listenable: Listenable.merge([sessions, plugins]),
      builder: (context, _) {
        final active = sessions.activeTab;

        return EditorViewWidget(
          projectName: workspace.projectName,
          appearance: sessions.appearance,
          onShowInHistory: (hash, path) => _showInHistory(context, hash, path),
          specialTabBuilder: (id) => _specialTab(context, id, workspace, sessions),
          specialTabTitle: _specialTitle,
          bannerBuilder: (path) => PluginBanner(plugins: plugins, filePath: path),
          openTabs: sessions.openPaths,
          activeFile: sessions.activePath ?? '',
          // 有 controller 时编辑器直接读它;这里不传全文,免得每次按键都拼一次。
          codeContent: '',
          activeSymbol: workspace.activeSymbol,
          diagnostics: active?.diagnostics ?? const [],
          controller: active?.controller,
          verticalScroll: active?.verticalScroll,
          horizontalScroll: active?.horizontalScroll,
          onSelectTab: workspace.openFile,
          onCloseTab: (path) => _closeTab(context, path),
          onSave: workspace.save,
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

  Future<void> _closeTab(BuildContext context, String path) async {
    if (path.isEmpty) return;
    final workspace = context.workspaceRead;

    // 自动保存:关之前先把还没落盘的改动写掉;只有写不了(文件打开失败等)才询问。
    if (workspace.isDirty(path) && workspace.sessions.autosave) await workspace.saveFile(path);
    if (!context.mounted) return;
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
              await workspace.saveFile(path);
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
  const _AppMenuBar({
    required this.child,
    required this.settings,
    required this.plugins,
    required this.branches,
    required this.branchActions,
  });

  final Widget child;
  final SettingsStore settings;
  final PluginManager plugins;
  final BranchStore branches;
  final BranchActions branchActions;

  @override
  Widget build(BuildContext context) {
    // PlatformProvidedMenuItem 在非 macOS 平台会直接抛异常,web / 测试环境不能建。
    if (defaultTargetPlatform != TargetPlatform.macOS) return child;
    final workspace = context.workspaceRead;
    return ListenableBuilder(
      listenable: Listenable.merge([workspace, branches]),
      child: child,
      builder: (context, child) => PlatformMenuBar(
        menus: <PlatformMenuItem>[
          PlatformMenu(
            label: 'CodeLiteX',
            menus: <PlatformMenuItem>[
              const PlatformMenuItemGroup(members: <PlatformMenuItem>[
                PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.about),
              ]),
              PlatformMenuItemGroup(members: <PlatformMenuItem>[
                PlatformMenuItem(
                  label: 'Settings…',
                  shortcut: const SingleActivator(LogicalKeyboardKey.comma, meta: true),
                  onSelected: () => showSettingsDialog(context, settings, plugins: plugins),
                ),
                PlatformMenuItem(
                  label: 'Plugins…',
                  onSelected: () => showSettingsDialog(context, settings, plugins: plugins, openPlugins: true),
                ),
              ]),
              const PlatformMenuItemGroup(members: <PlatformMenuItem>[
                PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.servicesSubmenu),
              ]),
              const PlatformMenuItemGroup(members: <PlatformMenuItem>[
                PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hide),
                PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.hideOtherApplications),
                PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.showAllApplications),
              ]),
              const PlatformMenuItemGroup(members: <PlatformMenuItem>[
                PlatformProvidedMenuItem(type: PlatformProvidedMenuItemType.quit),
              ]),
            ],
          ),
          _fileMenu(context, workspace),
          _gitMenu(context),
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

  /// Git 菜单:标题栏分支弹窗里那几个操作,带上同样的快捷键。不是 Git 仓库时置灰。
  PlatformMenu _gitMenu(BuildContext context) {
    final enabled = branches.isRepo && branches.busy == null;
    VoidCallback? when(void Function() run) => enabled ? run : null;
    return PlatformMenu(
      label: 'Git',
      menus: <PlatformMenuItem>[
        PlatformMenuItemGroup(members: <PlatformMenuItem>[
          PlatformMenuItem(
            label: 'Update Project…',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyT, meta: true),
            onSelected: when(() => branchActions.update(context)),
          ),
          PlatformMenuItem(
            label: 'Commit…',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyK, meta: true),
            onSelected: when(branchActions.showCommitWindow),
          ),
          PlatformMenuItem(
            label: 'Push…',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyP, meta: true, shift: true),
            onSelected: when(() => branchActions.push(context)),
          ),
        ]),
        PlatformMenuItemGroup(members: <PlatformMenuItem>[
          PlatformMenuItem(
            label: 'New Branch…',
            shortcut: const SingleActivator(LogicalKeyboardKey.keyN, meta: true, alt: true),
            onSelected: when(() => branchActions.newBranch(context)),
          ),
          PlatformMenuItem(
            label: 'Checkout Tag or Revision…',
            onSelected: when(() => branchActions.checkoutRevision(context)),
          ),
        ]),
      ],
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

/// 左侧工具窗与编辑区之间的分隔线:1px 线条,左右拖动调整工具窗宽度(与 IntelliJ 一致)。
/// 命中区比线条宽,方便抓取;悬停 / 拖动时高亮。
class _SideResizeHandle extends StatefulWidget {
  const _SideResizeHandle({required this.layout});

  final LayoutStore layout;

  @override
  State<_SideResizeHandle> createState() => _SideResizeHandleState();
}

class _SideResizeHandleState extends State<_SideResizeHandle> {
  bool _hot = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final active = _hot || _dragging;
    return MouseRegion(
      cursor: SystemMouseCursors.resizeColumn,
      onEnter: (_) => setState(() => _hot = true),
      onExit: (_) => setState(() => _hot = false),
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onHorizontalDragStart: (_) => setState(() => _dragging = true),
        onHorizontalDragEnd: (_) => setState(() => _dragging = false),
        onHorizontalDragCancel: () => setState(() => _dragging = false),
        onHorizontalDragUpdate: (d) {
          // 编辑区至少留 300px(再扣掉左活动条)。
          final max = MediaQuery.sizeOf(context).width - 300 - IntelliJMetrics.activityStripe;
          widget.layout.resizeLeft(widget.layout.leftWidth + d.delta.dx, maxWidth: max);
        },
        child: Container(
          width: 5,
          color: IntelliJTheme.editorBg,
          alignment: Alignment.centerLeft,
          child: Container(
            width: active ? 2 : 1,
            color: active ? IntelliJTheme.accentBlue : IntelliJTheme.borderSubtle,
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 项目的打开 / 切换 / 新建 / 克隆:标题栏的项目弹窗和 File 菜单共用。
// ---------------------------------------------------------------------------

/// 切换项目会丢弃未保存的标签,有脏标签时先确认。
Future<bool> _confirmDiscard(
    BuildContext context, WorkspaceStore workspace) async {
  if (workspace.sessions.autosave) await workspace.sessions.saveAll();
  if (!workspace.sessions.hasDirtyTabs) return true;
  if (!context.mounted) return false;
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

/// 新建 / 克隆默认放在当前项目的上一级;没有项目就放用户主目录。
String _defaultProjectLocation(WorkspaceStore workspace) {
  final root = workspace.rootPath;
  if (root != null) {
    final i = root.lastIndexOf('/');
    if (i > 0) return root.substring(0, i);
  }
  return io.homeDirectory() ?? '';
}

Future<void> _newProject(BuildContext context, WorkspaceStore workspace) async {
  final path = await showNewProjectDialog(context, initialLocation: _defaultProjectLocation(workspace), home: io.homeDirectory());
  if (path == null || !context.mounted) return;
  if (!await _confirmDiscard(context, workspace) || !context.mounted) return;
  await _open(context, workspace, path);
}

Future<void> _cloneRepository(BuildContext context, WorkspaceStore workspace) async {
  final path = await showCloneDialog(context, initialLocation: _defaultProjectLocation(workspace), home: io.homeDirectory());
  if (path == null || !context.mounted) return;
  if (!await _confirmDiscard(context, workspace) || !context.mounted) return;
  await _open(context, workspace, path);
}
