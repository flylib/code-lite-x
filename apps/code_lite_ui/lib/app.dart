import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'core/client/api_client.dart';
import 'core/state/layout_store.dart';
import 'core/state/project_context.dart';
import 'core/state/project_manager.dart';
import 'core/state/scopes.dart';
import 'core/plugins/plugin_manager.dart';
import 'core/state/settings_store.dart';
import 'core/keymap/keymap.dart';
import 'core/platform/workspace_io.dart' as io;
import 'core/state/workspace_store.dart';
import 'core/theme/intellij_theme.dart';
import 'core/theme/island.dart';
import 'features/activity_stripe/activity_stripe_widget.dart';
import 'features/bottom_tools/bottom_tools_widget.dart';
import 'features/build_tools/build_tools_panel.dart';
import 'features/build_tools/build_tools_store.dart';
import 'features/commit/commit_panel.dart';
import 'features/commit/diff_tab.dart';
import 'features/editor/code_editor_controller.dart' show EditorPosition;
import 'features/editor/editor_appearance.dart';
import 'features/editor/disk_conflict_banner.dart';
import 'features/editor/editor_session_manager.dart';
import 'features/editor/editor_view_widget.dart';
import 'features/editor/open_in_browser.dart';
import 'features/git/branch_actions.dart';
import 'features/git/branch_store.dart';
import 'features/git/git_log_store.dart';
import 'features/plugins/plugin_banner.dart';
import 'features/projects/open_projects_panel.dart';
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
import 'features/title_bar/operation_buttons.dart';
import 'features/title_bar/project_dialogs.dart';
import 'features/title_bar/project_menu.dart';
import 'features/title_bar/title_bar_widget.dart';
import 'features/tool_window/side_split_view.dart';
import 'features/tool_window/tool_window_actions.dart';

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
  // 全局共享的:窗口布局、设置、插件、编辑器外观。每个打开的项目自己的状态在 ProjectContext 里。
  final LayoutStore _layout = LayoutStore();
  final EditorAppearance _appearance = EditorAppearance();
  /// 快捷键(默认键位同 IntelliJ,可在设置里改、可从 IntelliJ 导入),随设置文件保存。
  final KeymapStore _keymap = KeymapStore();
  late final SettingsStore _settings = SettingsStore(appearance: _appearance, layout: _layout, keymap: _keymap);
  late final PluginManager _plugins = PluginManager();
  /// HTML 在浏览器里按 http://localhost:63342/<项目名>/<路径> 打开(同 IntelliJ):
  /// 地址由文件所在项目自己的服务器给出,那个服务器随项目关闭而关闭。
  late final BrowserService _browsers = BrowserService(
    urlFor: (root, file) async => _projects.find(root)?.context?.browserUrlFor(file),
  );

  /// 打开的项目:一个进程、多个项目同时留在内存里;切换只是换显示哪一份。
  late final ProjectManager _projects = ProjectManager(layout: _layout, plugins: _plugins, settings: _settings);

  @override
  void initState() {
    super.initState();
    // 自动保存:应用失去焦点(切到终端 / 浏览器)时立刻把改动写盘,外部工具看到的就是最新内容。
    _lifecycle = AppLifecycleListener(
      onInactive: _onLeaveForeground,
      onHide: _onLeaveForeground,
      onDetach: _onLeaveForeground,
      // 切回来时和磁盘对一遍(IntelliJ 的「激活窗口时同步文件」):在别处改过的文件,已打开的标签跟上
      onResume: () => _projects.active.sessions.syncWithDisk(),
    );
    _bootstrap();
  }

  late final AppLifecycleListener _lifecycle;

  /// 离开前台(切走 / 隐藏 / 退出):所有项目的改动写盘,同时记下标签、光标和滚动位置,下次打开项目时恢复。
  void _onLeaveForeground() => _projects.saveAll();

  Future<void> _bootstrap() async {
    // 先接入已装插件(着色规则、语言服务器启动方式),再恢复上次打开的项目
    _plugins.load();
    await _settings.load();
    await _projects.restore();
  }

  @override
  void dispose() {
    _lifecycle.dispose();
    _projects.dispose(); // 先于设置 / 插件:各项目的状态要从它们那里摘掉自己
    _settings.dispose();
    _plugins.dispose();
    _layout.dispose();
    _appearance.dispose();
    _keymap.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CodeLiteX',
      debugShowCheckedModeBanner: false,
      theme: IntelliJTheme.darkTheme,
      home: ListenableBuilder(
        listenable: _projects,
        builder: (context, _) {
          final project = _projects.active;
          // 换项目时整棵工作台重建:各面板的内部状态(文件树的滚动位置等)不会串到别的项目里
          return KeyedSubtree(
            key: ObjectKey(project),
            child: LayoutScope(
              notifier: _layout,
              child: WorkspaceScope(
                notifier: project.workspace,
                child: SessionScope(
                  notifier: project.sessions,
                  child: _Workbench(project: project, manager: _projects, settings: _settings, plugins: _plugins, browsers: _browsers),
                ),
              ),
            ),
          );
        },
      ),
    );
  }
}

class _Workbench extends StatelessWidget {
  const _Workbench({
    required this.project,
    required this.manager,
    required this.settings,
    required this.plugins,
    required this.browsers,
  });

  /// 正在显示的项目的全部状态。
  final ProjectContext project;
  final ProjectManager manager;
  final SettingsStore settings;
  final PluginManager plugins;
  final BrowserService browsers;

  ApiClient get client => project.client;
  TerminalStore get terminals => project.terminals;
  GitLogStore get gitLog => project.gitLog;
  BranchStore get branches => project.branches;
  BranchActions get branchActions => project.branchActions;
  PullRequestsStore get prs => project.prs;
  BuildToolsStore get buildTools => project.build;

  @override
  Widget build(BuildContext context) {
    final workspace = context.workspaceRead;
    final layout = context.layoutRead;
    final sessions = context.sessionRead;

    return _AppMenuBar(
      settings: settings,
      plugins: plugins,
      manager: manager,
      branches: branches,
      branchActions: branchActions,
      // 快捷键改了(设置里改、从 IntelliJ 导入)立刻生效
      child: ListenableBuilder(
      listenable: settings.keymap ?? layout,
      builder: (context, child) => CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        // macOS 由系统菜单的 ⌘, 处理;其它平台没有菜单栏,用 IntelliJ 的 Ctrl+Alt+S。
        if (defaultTargetPlatform != TargetPlatform.macOS) ...{
          const SingleActivator(LogicalKeyboardKey.keyS, control: true, alt: true): () => showSettingsDialog(context, settings, plugins: plugins),
          const SingleActivator(LogicalKeyboardKey.comma, control: true): () => showSettingsDialog(context, settings, plugins: plugins),
        },
        const SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true): () => _openSearch(context),
        const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true): () => _openSearch(context),
        ..._keymapBindings(layout),
      },
      child: child!,
      ),
      child: Focus(
        autofocus: true,
        child: Scaffold(
          backgroundColor: IntelliJTheme.frameBg,
          body: Column(
            children: [
              // 标题栏订阅 workspace(当前文件、项目)和项目列表;分支那一块自己订阅 BranchStore。
              ListenableBuilder(
                listenable: Listenable.merge([workspace, manager]),
                builder: (context, _) => TitleBarWidget(
                  accent: workspace.rootPath == null ? null : projectColor(workspace.projectName),
                  onSearch: () => _openSearch(context),
                  onSettings: () => showSettingsDialog(context, settings, plugins: plugins),
                  projectChip: ProjectChip(
                    projectPath: workspace.rootPath,
                    openProjects: [for (final p in manager.projects) p.path],
                    recent: manager.recent,
                    home: io.homeDirectory(),
                    onSwitch: (path) => _openProject(context, manager, path),
                    onNewProject: () => _newProject(context, manager),
                    onOpen: () => _openFolder(context, manager),
                    onClone: () => _cloneRepository(context, manager),
                  ),
                  branchChip: BranchChip(store: branches, actions: branchActions),
                  operationButtons: OperationButtons(store: branches, actions: branchActions),
                ),
              ),

              Expanded(
                child: Row(
                  children: [
                    // 左活动条:订阅 layout,以及构建工具(检测到 Maven 等才出现它的按钮)。
                    ListenableBuilder(
                      listenable: Listenable.merge([layout, buildTools, settings.keymap]),
                      builder: (context, _) => ActivityStripeWidget(
                        buildToolTitle: buildTools.hasProjects ? buildTools.title : null,
                        leftTool: layout.leftTool,
                        isLeftOpen: layout.isLeftOpen,
                        visibleTools: layout.visibleTools,
                        slotOf: layout.slotOf,
                        sideOf: layout.sideOf,
                        bottomTab: layout.bottomTab,
                        isBottomOpen: layout.isBottomOpen,
                        onSelectTool: layout.selectTool,
                        onSelectBottomTab: layout.selectBottomTab,
                        keymap: settings.keymap,
                      ),
                    ),

                    // 两条活动条之间:一块块圆角的「岛」(IntelliJ 的 Islands 布局),岛之间的缝可以拖动调整大小。
                    // 上面是 左工具窗 | 编辑区 | 右工具窗,下面是横跨整个宽度的底部工具窗。
                    Expanded(
                      child: Padding(
                        padding: const EdgeInsets.only(top: 2, right: 2),
                        child: Column(
                          children: [
                            Expanded(
                              child: Row(
                                children: [
                                  // 侧边工具窗:layout 决定显示哪个(上下两块各一个时拆分显示),workspace 提供数据。
                                  _sideDock(ToolSide.left, layout, workspace, sessions),
                                  Expanded(child: Island(child: _EditorRegion(client: client, gitLog: gitLog, prs: prs, plugins: plugins, browsers: browsers))),
                                  _sideDock(ToolSide.right, layout, workspace, sessions),
                                ],
                              ),
                            ),
                            ListenableBuilder(
                              listenable: layout,
                              builder: (context, _) {
                                if (!layout.isBottomOpen) return const SizedBox.shrink();
                                return Column(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    _BottomResizeHandle(layout: layout),
                                    Island(
                                      child: BottomToolsWidget(
                                        activeTab: layout.bottomTab,
                                        onSelectTab: layout.selectBottomTab,
                                        client: client,
                                        terminals: terminals,
                                        gitLog: gitLog,
                                        repoName: workspace.projectName,
                                        height: layout.bottomHeight,
                                      ),
                                    ),
                                  ],
                                );
                              },
                            ),
                          ],
                        ),
                      ),
                    ),

                    // 右活动条:始终显示(顶上是通知),停靠在右侧的工具窗按钮在下面。
                    ListenableBuilder(
                      listenable: Listenable.merge([layout, buildTools, settings.keymap]),
                      builder: (context, _) => RightStripeWidget(
                        buildToolTitle: buildTools.hasProjects ? buildTools.title : null,
                        visibleTools: layout.visibleTools,
                        sideOf: layout.sideOf,
                        slotOf: layout.slotOf,
                        onSelectTool: layout.selectTool,
                        keymap: settings.keymap,
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

  /// [side] 一侧的工具窗区域:上下两块各开一个时拆分显示;没有开着的就不占地方。
  /// layout 决定显示哪个,workspace 提供数据。
  Widget _sideDock(ToolSide side, LayoutStore layout, WorkspaceStore workspace, EditorSessionManager sessions) {
    return ListenableBuilder(
      listenable: layout,
      builder: (context, _) {
        final top = layout.visibleTool(side, ToolSlot.top);
        final bottom = layout.visibleTool(side, ToolSlot.bottom);
        if (top == null && bottom == null) return const SizedBox.shrink();
        Widget panelFor(SideTool tool) => ToolWindowScope(
              key: ValueKey(tool),
              tool: tool,
              layout: layout,
              child: Island(
                child: ListenableBuilder(
                listenable: workspace,
                builder: (context, _) => switch (tool) {
                          SideTool.project => ProjectExplorerWidget(
                              treeData: workspace.tree,
                              activeFilePath: workspace.activeFile,
                              onSelectFile: workspace.openFile,
                              onLoadChildren: client.listDirectory,
                            ),
                          SideTool.commit => CommitPanel(
                              key: ValueKey(workspace.rootPath),
                              client: client,
                              onOpenDiff: workspace.openDiff,
                              onOpenFile: workspace.openFile,
                              onCommitted: gitLog.refresh,
                              onFilesReverted: sessions.reloadFromDisk,
                            ),
                          SideTool.pullRequests => PullRequestsPanel(
                              store: prs,
                              onOpenDiff: (number, path) {
                                prs.session(number).showFile(path);
                                workspace.openSpecial('$prDiffTabPrefix$number');
                              },
                              onOpenTimeline: (number) => workspace.openSpecial('$prTimelineTabPrefix$number'),
                            ),
                          SideTool.structure => StructureWidget(
                              activeFile: workspace.activeFile,
                              outline: workspace.outline,
                              onSelectSymbol: (sym) => workspace.selectSymbol(sym['name'] as String?),
                            ),
                          SideTool.openProjects => OpenProjectsPanel(
                              manager: manager,
                              home: io.homeDirectory(),
                              onSwitch: (p) => manager.activate(p),
                              onClose: (p) => _closeProject(context, manager, p),
                              onCloseOthers: (p) => _closeOtherProjects(context, manager, p),
                              onOpenFolder: () => _openFolder(context, manager),
                            ),
                          SideTool.build => BuildToolsPanel(store: buildTools, onOpenFile: workspace.openFile),
                },
              ),
              ),
            );
        final panel = top != null && bottom != null
            ? SideSplitView(layout: layout, side: side, top: panelFor(top), bottom: panelFor(bottom))
            : panelFor(top ?? bottom!);
        final handle = _SideResizeHandle(layout: layout, side: side);
        final sized = SizedBox(width: layout.widthOf(side), child: panel);
        return Row(children: side == ToolSide.left ? [sized, handle] : [handle, sized]);
      },
    );
  }

  /// 可配置的快捷键 → 操作(打开 / 收起工具窗,同 IntelliJ 的 Activate…ToolWindow、Hide All Windows)。
  Map<ShortcutActivator, VoidCallback> _keymapBindings(LayoutStore layout) {
    final keymap = settings.keymap;
    if (keymap == null) return const {};
    void side(SideTool tool) {
      if (tool == SideTool.build && !buildTools.hasProjects) return; // 项目里没有构建工具时没有这个窗
      layout.selectTool(tool);
    }

    final actions = <String, VoidCallback>{
      for (final tool in SideTool.values) keymapIdOf(tool): () => side(tool),
      KeymapIds.terminal: () => layout.selectBottomTab(BottomToolTab.terminal),
      KeymapIds.git: () => layout.selectBottomTab(BottomToolTab.git),
      KeymapIds.hideAll: layout.toggleHideAll,
    };
    return {
      for (final e in actions.entries)
        for (final k in keymap.shortcutsOf(e.key)) k.activator: e.value,
    };
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
  const _EditorRegion({required this.client, required this.gitLog, required this.prs, required this.plugins, required this.browsers});

  final ApiClient client;
  final GitLogStore gitLog;
  final PullRequestsStore prs;
  final PluginManager plugins;
  final BrowserService browsers;

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
          bannerBuilder: (path) => Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              DiskConflictBanner(sessions: sessions, path: path),
              PluginBanner(plugins: plugins, filePath: path),
            ],
          ),
          onOpenFile: workspace.openFile,
          paneActionsBuilder: (path) => isHtmlFile(path) && !sessions.isSpecialTab(path)
              ? OpenInBrowserBar(
                  service: browsers,
                  file: absoluteFilePath(client.rootPath, path),
                  projectRoot: workspace.rootPath,
                  // 浏览器读的是磁盘:没落盘的改动先存下来
                  beforeOpen: () => workspace.saveFile(path),
                )
              : null,
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
    required this.manager,
    required this.branches,
    required this.branchActions,
  });

  final Widget child;
  final SettingsStore settings;
  final PluginManager plugins;
  final ProjectManager manager;
  final BranchStore branches;
  final BranchActions branchActions;

  @override
  Widget build(BuildContext context) {
    // PlatformProvidedMenuItem 在非 macOS 平台会直接抛异常,web / 测试环境不能建。
    if (defaultTargetPlatform != TargetPlatform.macOS) return child;
    final workspace = context.workspaceRead;
    return ListenableBuilder(
      listenable: Listenable.merge([workspace, manager, branches]),
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
    final recent = manager.recent;
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
            onSelected: () => _openFolder(context, manager),
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
                      onSelected: () => _openProject(context, manager, path),
                    ),
              ]),
              if (recent.isNotEmpty)
                PlatformMenuItemGroup(members: <PlatformMenuItem>[
                  PlatformMenuItem(
                      label: 'Clear Recent Projects',
                      onSelected: manager.clearRecent),
                ]),
            ],
          ),
          PlatformMenuItem(
            label: 'Close Project',
            onSelected: manager.activeProject != null
                ? () => _closeProject(context, manager, manager.activeProject!)
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
        child: const SizedBox(height: IntelliJMetrics.islandGap, width: double.infinity),
      ),
    );
  }
}

/// 侧边工具窗与编辑区之间的缝(岛与岛之间),左右拖动调整工具窗宽度。
/// 平时就是一条窗口底色的缝;悬停 / 拖动时中间亮一条蓝线。右侧的工具窗在编辑区右边,拖动方向相反。
class _SideResizeHandle extends StatefulWidget {
  const _SideResizeHandle({required this.layout, required this.side});

  final LayoutStore layout;
  final ToolSide side;

  @override
  State<_SideResizeHandle> createState() => _SideResizeHandleState();
}

class _SideResizeHandleState extends State<_SideResizeHandle> {
  bool _hot = false;
  bool _dragging = false;

  @override
  Widget build(BuildContext context) {
    final active = _hot || _dragging;
    final left = widget.side == ToolSide.left;
    final layout = widget.layout;
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
          // 编辑区至少留 300px(再扣掉左右两条活动条;另一侧开着的话也扣掉它的宽度)。
          final other = left ? ToolSide.right : ToolSide.left;
          const stripes = IntelliJMetrics.activityStripe * 2;
          final otherWidth = layout.isSideOpen(other) ? layout.widthOf(other) + IntelliJMetrics.islandGap : 0;
          final max = MediaQuery.sizeOf(context).width - 300 - stripes - otherWidth;
          layout.resizeSide(widget.side, layout.widthOf(widget.side) + (left ? d.delta.dx : -d.delta.dx), maxWidth: max);
        },
        child: Container(
          width: IntelliJMetrics.islandGap,
          alignment: Alignment.center,
          child: active ? Container(width: 2, color: IntelliJTheme.accentBlue) : null,
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 项目的打开 / 切换 / 关闭 / 新建 / 克隆:标题栏的项目弹窗、Opening Projects 面板和 File 菜单共用。
// 打开新项目不再关掉当前的 —— 它们都留在内存里,切换只是换显示哪一个;要关用 _closeProject。
// ---------------------------------------------------------------------------

/// 关闭项目会丢掉它没保存的标签,有脏标签时先问:保存 / 不保存 / 取消。
Future<bool> _confirmClose(BuildContext context, OpenProject entry) async {
  final ctx = entry.context;
  if (ctx == null) return true; // 还没加载过:没有改动
  if (ctx.sessions.autosave) await ctx.sessions.saveAll();
  if (!ctx.hasDirtyTabs) return true;
  if (!context.mounted) return false;
  final choice = await showDialog<String>(
    context: context,
    builder: (dialog) => AlertDialog(
      title: Text('关闭 ${entry.name}'),
      content: const Text('这个项目有未保存的修改。'),
      actions: [
        TextButton(onPressed: () => Navigator.pop(dialog, 'cancel'), child: const Text('取消')),
        TextButton(onPressed: () => Navigator.pop(dialog, 'discard'), child: const Text('不保存')),
        TextButton(onPressed: () => Navigator.pop(dialog, 'save'), child: const Text('保存并关闭')),
      ],
    ),
  );
  if (choice == 'save') await ctx.sessions.saveAll();
  return choice == 'save' || choice == 'discard';
}

Future<void> _closeProject(BuildContext context, ProjectManager manager, OpenProject entry) async {
  if (!await _confirmClose(context, entry)) return;
  await manager.close(entry);
}

Future<void> _closeOtherProjects(BuildContext context, ProjectManager manager, OpenProject keep) async {
  for (final e in manager.projects) {
    if (identical(e, keep)) continue;
    if (!context.mounted || !await _confirmClose(context, e)) return; // 取消就停在这里,已经关掉的不管
    await manager.close(e);
  }
}

Future<void> _openFolder(BuildContext context, ProjectManager manager) async {
  final path = await io.pickDirectory();
  if (path == null || !context.mounted) return;
  await _openProject(context, manager, path);
}

/// 打开 [path] 并切过去;已经打开的只是切换。
Future<void> _openProject(BuildContext context, ProjectManager manager, String path) async {
  final ok = await manager.open(path);
  if (!ok && context.mounted) {
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(content: Text('无法打开项目: $path')));
  }
}

/// 新建 / 克隆默认放在当前项目的上一级;没有项目就放用户主目录。
String _defaultProjectLocation(ProjectManager manager) {
  final root = manager.active.path;
  if (root != null) {
    final i = root.lastIndexOf('/');
    if (i > 0) return root.substring(0, i);
  }
  return io.homeDirectory() ?? '';
}

Future<void> _newProject(BuildContext context, ProjectManager manager) async {
  final path = await showNewProjectDialog(context, initialLocation: _defaultProjectLocation(manager), home: io.homeDirectory());
  if (path == null || !context.mounted) return;
  await _openProject(context, manager, path);
}

Future<void> _cloneRepository(BuildContext context, ProjectManager manager) async {
  final path = await showCloneDialog(context, initialLocation: _defaultProjectLocation(manager), home: io.homeDirectory());
  if (path == null || !context.mounted) return;
  await _openProject(context, manager, path);
}
