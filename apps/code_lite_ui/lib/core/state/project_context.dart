import '../build_tools/makefile.dart' show isMakefileName;
import '../../features/make/make_store.dart';
import 'dart:async';

import 'package:flutter/foundation.dart' show defaultTargetPlatform, TargetPlatform;

import '../../features/bottom_tools/bottom_tools_widget.dart' show BottomToolTab;
import '../../features/build_tools/build_tools_store.dart';
import '../../features/editor/editor_session_manager.dart';
import '../../features/git/branch_actions.dart';
import '../../features/git/branch_store.dart';
import '../../features/git/git_log_store.dart';
import '../../features/pull_requests/pr_store.dart';
import '../../features/terminal/terminal_store.dart';
import '../client/api_client.dart';
import '../ffi/codelite_bindings_stub.dart' if (dart.library.ffi) '../ffi/codelite_bindings.dart';
import '../platform/paths.dart';
import '../platform/web_server.dart';
import '../platform/workspace_io.dart' as io;
import '../plugins/plugin_manager.dart';
import 'layout_store.dart';
import 'session_snapshot.dart';
import 'settings_store.dart';
import 'workspace_store.dart';

/// 所有打开的项目共用的东西:窗口布局、设置、插件,以及项目之外的存储。
class ProjectServices {
  ProjectServices({
    required this.layout,
    required this.plugins,
    required this.settings,
    required this.sessionStore,
    required this.loadRecent,
    required this.saveRecent,
    ApiClient Function()? newClient,
  }) : newClient = newClient ?? _defaultClient;

  final LayoutStore layout;
  final PluginManager plugins;
  final SettingsStore settings;

  /// 各项目的标签 / 光标记录。只能有一个:几个实例同时读改写同一个文件会互相覆盖。
  final SessionStore sessionStore;
  final Future<List<String>> Function() loadRecent;
  final Future<void> Function(List<String>) saveRecent;

  /// 给一个项目建它自己的客户端。缺省每个客户端有自己的 Rust 上下文(终端会话活在里面),
  /// 关闭项目时一并销毁;测试里可以换成假的。
  final ApiClient Function() newClient;

  static ApiClient _defaultClient() => ApiClient(initialRoot: io.noProjectRoot(), ffi: CodeLiteBindings.create(), ownsFfi: true);
}

/// 一个项目的全部状态:客户端(语言服务器、Git、终端的 Rust 上下文)、编辑会话、工作区、
/// 终端、Git 日志、分支、PR、构建工具窗。每个打开的项目各有一份,切换只是换显示哪一份,
/// 别的项目留在内存里照常运行(语言服务器不重启、终端里的进程不断)。
///
/// 没有打开任何项目时界面也要有一份(空状态),它的 [path] 是 null。
class ProjectContext {
  ProjectContext._({
    required this.services,
    required this.isActive,
    required this.client,
    required this.sessions,
    required this.workspace,
    required this.terminals,
    required this.gitLog,
    required this.branches,
    required this.branchActions,
    required this.prs,
    required this.build,
    required this.make,
  }) {
    workspace.addListener(_onWorkspaceChanged);
    branches.onChanged = _onRepoChanged;
    build.addListener(_onBuildToolsChanged);
    make.addListener(_onBuildToolsChanged);
  }

  /// [isActive]:这个项目现在是不是正在显示的那个(影响要不要去动共享的窗口布局)。
  factory ProjectContext.create(ProjectServices services, {required bool Function() isActive}) {
    final client = services.newClient();
    services.plugins.attach(client);
    final sessions = EditorSessionManager(client: client, appearance: services.settings.appearance);
    services.settings.bind(sessions);
    final workspace = WorkspaceStore(
      client: client,
      sessions: sessions,
      sessionStore: services.sessionStore,
      loadRecent: services.loadRecent,
      saveRecent: services.saveRecent,
    );
    final terminals = TerminalStore(client);
    final branches = BranchStore(client);
    final layout = services.layout;
    return ProjectContext._(
      services: services,
      isActive: isActive,
      client: client,
      sessions: sessions,
      workspace: workspace,
      terminals: terminals,
      gitLog: GitLogStore(client),
      branches: branches,
      branchActions: BranchActions(branches, showCommitWindow: () => layout.showTool(SideTool.commit)),
      prs: PullRequestsStore(client),
      build: BuildToolsStore(
        plugins: services.plugins,
        // 单独打开的文件不探测构建工具(不把它所在的目录当工程)
        projectRoot: () => workspace.isSingleFile ? null : workspace.rootPath,
        read: (path) async {
          final res = await client.fetchFile(path);
          return res['status'] == 'ok' ? res['content'] as String? : null;
        },
        runner: (title, command) {
          terminals.run(title, command);
          if (isActive()) layout.showBottomTab(BottomToolTab.terminal);
        },
        fileSaved: client.onFileSaved,
        windows: defaultTargetPlatform == TargetPlatform.windows,
      ),
      make: MakeStore(
        // 单独打开的文件不探测构建工具(不把它所在的目录当工程)
        projectRoot: () => workspace.isSingleFile ? null : workspace.rootPath,
        read: (path) async {
          final res = await client.fetchFile(path);
          return res['status'] == 'ok' ? res['content'] as String? : null;
        },
        // 项目里的 Makefile:从 Rust 常驻的文件清单里找(子目录里的也算);清单还在建时返回 null
        listMakefiles: () async {
          final found = <String>{};
          for (final q in const ['makefile', '.mk', '.mak']) {
            final r = client.fileIndexQuery(q, limit: 500);
            if (r['status'] != 'ok' || r['ready'] != true) return null;
            for (final hit in (r['results'] as List? ?? const [])) {
              final p = (hit as Map)['path'] as String?;
              if (p != null && isMakefileName(p)) found.add(p);
            }
          }
          return found.toList();
        },
        runner: (title, command) {
          terminals.run(title, command);
          if (isActive()) layout.showBottomTab(BottomToolTab.terminal);
        },
        makePath: () => services.settings.makePath,
        fileSaved: client.onFileSaved,
      ),
    );
  }

  final ProjectServices services;
  final bool Function() isActive;
  final ApiClient client;
  final EditorSessionManager sessions;
  final WorkspaceStore workspace;
  final TerminalStore terminals;
  final GitLogStore gitLog;
  final BranchStore branches;
  final BranchActions branchActions;
  final PullRequestsStore prs;
  final BuildToolsStore build;

  /// make 工具窗:项目里的 Makefile 和它们的目标。
  final MakeStore make;

  LayoutStore get _layout => services.layout;

  /// 项目根目录;空状态为 null。
  String? get path => workspace.rootPath;
  bool get isEmpty => path == null;
  bool get hasDirtyTabs => sessions.hasDirtyTabs;

  String? _lastRoot;
  Timer? _sessionTimer;
  bool _disposed = false;

  /// 这个项目的静态文件服务器(浏览器里打开 HTML 用):第一次用时才启动,项目关闭时随之关闭。
  BuiltInWebServer? _webServer;

  /// [file] 在浏览器里的地址 `http://localhost:63342/<项目名>/<路径>`;没有项目、文件不在项目里或服务器起不来时为 null。
  Future<String?> browserUrlFor(String file) async {
    final root = path;
    if (root == null || _disposed) return null;
    return (_webServer ??= BuiltInWebServer(root: root)).urlFor(file);
  }

  /// 项目目录的文件监视:别处改了已打开的文件,标签跟着更新(不在前台的项目也照常)。
  StreamSubscription<String>? _watch;
  final Set<String> _changedFiles = {};
  Timer? _watchDebounce;

  /// Rust 文件监视:隔 300 ms 取一批变化。
  Timer? _watchTimer;
  bool _treeLoading = false;
  bool _treeDirty = false;

  /// 打开 [projectPath]:读文件树、恢复上次的标签。失败(目录不存在 / 初始化失败)返回 false。
  /// 打开项目目录;[projectPath] 是文件时单独打开这个文件(见 [WorkspaceStore.openSingleFile])。
  Future<bool> open(String projectPath) async =>
      await io.directoryExists(projectPath) ? workspace.openFolder(projectPath) : workspace.openSingleFile(projectPath);

  /// 换了项目根:Git Log / PR 里还是旧数据,作废后在下次显示时重新加载;
  /// 只在有项目时关注分支和记录会话(没有项目时不起任何 git 进程和定时器)。
  void _onWorkspaceChanged() {
    final root = workspace.rootPath;
    if (root == _lastRoot) return;
    _lastRoot = root;
    gitLog.invalidate();
    prs.invalidate();
    branches.reset();
    build.reload();
    make.reload();
    _sessionTimer?.cancel();
    _watch?.cancel();
    _watch = null;
    _watchTimer?.cancel();
    _watchTimer = null;
    if (root != null) {
      branches.start();
      // 文件监视交给 Rust(构建产物的事件在那边就丢掉);不行再用 Dart 自己的。
      // 单独打开的文件不监视它所在的目录:切回窗口 / 保存前照样和磁盘对一遍
      if (workspace.isSingleFile) {
        // 不监视
      } else if (client.startWatching()) {
        _watchTimer = Timer.periodic(const Duration(milliseconds: 300), (_) => _pollWatch());
      } else {
        _watch = io.watchFiles(root).listen(_onFileChanged);
      }
      // 光标和滚动位置不会通知任何人,定时看一眼(没变就不写盘),这样被强杀 / 崩溃也只丢几秒
      _sessionTimer = Timer.periodic(const Duration(seconds: 5), (_) => workspace.saveSession());
    } else {
      branches.stop();
      _sessionTimer = null;
    }
  }

  /// Rust 攒下的一批变化:改了 / 新建的文件里有打开着的标签就和磁盘对一下;有文件新建或删掉就刷新文件树。
  void _pollWatch() {
    final root = workspace.rootPath;
    if (root == null || _disposed) return;
    final r = client.pollWatch();
    if (r == null) return;
    if (r['overflow'] == true) {
      // 一下子变了太多(切大分支、解压):整体重来
      sessions.syncWithDisk();
      _reloadTree();
      return;
    }
    final touched = <String>{
      for (final p in (r['changed'] as List? ?? const [])) p as String,
      for (final p in (r['created'] as List? ?? const [])) p as String,
    };
    if (touched.isNotEmpty) {
      final prefix = '$root/';
      final paths = [
        for (final p in sessions.tabs.keys)
          if (touched.contains(p.startsWith(prefix) ? p.substring(prefix.length) : p)) p,
      ];
      if (paths.isNotEmpty) sessions.syncWithDisk(paths);
    }
    if (r['structure'] == true) _reloadTree();
    // 别处改了 / 新建 / 删掉了 Makefile(git 切分支、别的编辑器):make 工具窗跟着重读
    final makefiles = [...touched, for (final p in (r['removed'] as List? ?? const [])) p as String].where(isMakefileName);
    if (makefiles.isNotEmpty) make.onFilesChanged(makefiles.first);
  }

  /// 刷新文件树;正在刷的话等它完了再刷一次(中间来的多次合成一次)。
  Future<void> _reloadTree() async {
    if (_treeLoading) {
      _treeDirty = true;
      return;
    }
    _treeLoading = true;
    try {
      await workspace.load();
    } finally {
      _treeLoading = false;
    }
    if (_treeDirty && !_disposed) {
      _treeDirty = false;
      await _reloadTree();
    }
  }

  /// 文件监视的事件很密(保存一次可能来好几个,构建时成片地来):攒 150ms,只挑已打开的文件去和磁盘对一下。
  void _onFileChanged(String absolutePath) {
    _changedFiles.add(absolutePath);
    _watchDebounce?.cancel();
    _watchDebounce = Timer(const Duration(milliseconds: 150), () {
      final root = workspace.rootPath;
      final changed = {..._changedFiles};
      _changedFiles.clear();
      if (root == null || _disposed) return;
      // FSEvents 给的可能是解析过符号链接的路径(/private/var/… 对 /var/…),按结尾比
      bool hit(String abs) => changed.any((c) => c == abs || c.endsWith(abs));
      final paths = [
        for (final path in sessions.tabs.keys)
          if (hit(absoluteFilePath(root, path))) path,
      ];
      if (paths.isNotEmpty) sessions.syncWithDisk(paths);
    });
  }

  /// 项目里没有构建工具了:构建工具窗的按钮会消失,开着的窗口收起;它占着左上方的话换回项目视图。
  /// 只在它是正在显示的项目时才动共享的窗口布局。
  void _onBuildToolsChanged() {
    if (!isActive()) return;
    syncLayoutToProject();
  }

  /// 窗口布局是共享的:切到别的项目后,开着的构建工具窗在新项目里没有对应内容,换回项目视图。
  void syncLayoutToProject() {
    void hide(SideTool tool) {
      if (!_layout.isToolVisible(tool)) return;
      final wasLeftTop = _layout.visibleTool(ToolSide.left, ToolSlot.top) == tool;
      _layout.hideTool(tool);
      if (wasLeftTop) _layout.showTool(SideTool.project);
    }

    if (!build.hasProjects && !build.loading) hide(SideTool.build);
    if (!make.hasMakefiles && !make.loading) hide(SideTool.make);
  }

  /// git 动了仓库(切分支 / 更新 / 合并 / 变基 ……,或者别处在终端里切了分支):
  /// 日志窗要跟上;文件内容变了的话,文件树和没有未保存修改的标签也要。
  void _onRepoChanged(bool worktreeChanged) {
    // 不是正在显示的项目:日志只作废,等它被切回来再加载
    if (isActive() && _layout.isBottomOpen && _layout.bottomTab == BottomToolTab.git) {
      gitLog.refresh();
    } else {
      gitLog.invalidate();
    }
    if (!worktreeChanged) return;
    workspace.load();
    // 有未保存修改的标签不动、记成冲突:那是用户正在写的东西,不能被磁盘上的内容盖掉
    sessions.syncWithDisk();
  }

  /// 把没落盘的改动写掉,并记下标签、光标和滚动位置(离开前台、关闭项目前)。
  Future<void> saveState() async {
    await sessions.saveAll();
    await workspace.saveSession();
  }

  /// 释放这个项目的一切:语言服务器进程、终端会话、定时器、各个 store。调用前先 [saveState]。
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _sessionTimer?.cancel();
    _watchDebounce?.cancel();
    _watchTimer?.cancel();
    await _watch?.cancel();
    await _webServer?.close(); // 端口随项目一起释放
    workspace.removeListener(_onWorkspaceChanged);
    build.removeListener(_onBuildToolsChanged);
    make.removeListener(_onBuildToolsChanged);
    make.dispose();
    branches.dispose();
    gitLog.dispose();
    prs.dispose();
    build.dispose(); // 先于插件:它监听插件的启用 / 停用
    services.plugins.detach(client);
    services.settings.unbind(sessions);
    terminals.dispose(); // 先于客户端:要经它关掉 shell
    workspace.dispose();
    sessions.dispose();
    await client.dispose(); // 关掉语言服务器进程,销毁这个项目的 Rust 上下文
  }
}
