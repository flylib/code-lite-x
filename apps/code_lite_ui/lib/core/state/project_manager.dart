import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/workspace_io.dart' as io;
import '../plugins/plugin_manager.dart';
import '../client/api_client.dart';
import 'layout_store.dart';
import 'project_context.dart';
import 'session_snapshot.dart';
import 'settings_store.dart';

/// 打开项目列表里的一项。[context] 为 null 表示还没加载进内存
/// (启动时只加载正在看的那个,别的等第一次切过去才加载,免得一启动就拉起一堆语言服务器)。
class OpenProject {
  OpenProject(this.path);

  final String path;
  ProjectContext? context;

  /// 正在加载(读文件树、恢复标签)。
  bool loading = false;

  /// 上一次加载失败的原因(目录没了……)。
  String? error;

  String get name => path.split('/').where((s) => s.isNotEmpty).lastOrNull ?? path;
  bool get isLoaded => context != null;
}

/// 打开项目列表的存储:`~/.codelitex/open_projects.json`。读写可替换(测试)。
class OpenProjectsStore {
  OpenProjectsStore({Future<Map<String, dynamic>> Function()? load, Future<void> Function(Map<String, dynamic>)? save})
      : _load = load ?? io.loadOpenProjects,
        _save = save ?? io.saveOpenProjects;

  final Future<Map<String, dynamic>> Function() _load;
  final Future<void> Function(Map<String, dynamic>) _save;

  Future<({List<String> open, String? active})> read() async {
    final j = await _load();
    final open = [for (final p in (j['open'] as List? ?? const [])) if (p is String && p.isNotEmpty) p];
    final active = j['active'];
    return (open: open, active: active is String ? active : null);
  }

  Future<void> write(List<String> open, String? active) => _save({'open': open, if (active != null) 'active': active});
}

/// 同时打开多个项目:一个进程、多个项目都留在内存里(IntelliJ 的做法)。
///
/// 每个打开的项目有自己的 [ProjectContext](语言服务器、终端、标签、Git……),切换只是换 [active],
/// 别的项目照常运行;[close] 才真正关掉一个项目、释放它的全部资源。
/// 列表和当前项目存在磁盘上,下次启动恢复(只立刻加载当前项目,别的第一次切到时才加载)。
class ProjectManager extends ChangeNotifier {
  ProjectManager({
    required LayoutStore layout,
    required PluginManager plugins,
    required SettingsStore settings,
    OpenProjectsStore? store,
    SessionStore? sessionStore,
    Future<List<String>> Function()? loadRecent,
    Future<void> Function(List<String>)? saveRecent,
    Future<bool> Function(String path)? directoryExists,
    ApiClient Function()? newClient,
  })  : _store = store ?? OpenProjectsStore(),
        _loadRecentStore = loadRecent ?? io.loadRecentProjects,
        _saveRecentStore = saveRecent ?? io.saveRecentProjects,
        _directoryExists = directoryExists ?? io.directoryExists {
    services = ProjectServices(
      layout: layout,
      plugins: plugins,
      settings: settings,
      sessionStore: sessionStore ?? SessionStore(),
      loadRecent: () async => _recent,
      saveRecent: _setRecent,
      newClient: newClient,
    );
  }

  late final ProjectServices services;
  final OpenProjectsStore _store;
  final Future<List<String>> Function() _loadRecentStore;
  final Future<void> Function(List<String>) _saveRecentStore;
  final Future<bool> Function(String path) _directoryExists;

  final List<OpenProject> _projects = [];
  OpenProject? _active;
  ProjectContext? _empty;
  List<String> _recent = const [];
  bool _disposed = false;

  /// 打开的项目,按打开的先后(列表里的顺序)。
  List<OpenProject> get projects => List.unmodifiable(_projects);

  /// 正在看的项目;一个都没打开时为 null。
  OpenProject? get activeProject => _active;

  /// 最近打开过的项目路径,最新的在前(包含当前打开的)。
  List<String> get recent => _recent;

  /// 界面现在该显示的那一份状态。没有项目时是一份空状态(没有项目根)。
  ProjectContext get active => _active?.context ?? (_empty ??= _newContext());

  OpenProject? find(String path) {
    final p = normalize(path);
    for (final e in _projects) {
      if (e.path == p) return e;
    }
    return null;
  }

  static String normalize(String path) {
    final p = path.trim();
    return p.length > 1 && p.endsWith('/') ? p.replaceFirst(RegExp(r'/+$'), '') : p;
  }

  ProjectContext _newContext() {
    late final ProjectContext ctx;
    ctx = ProjectContext.create(services, isActive: () => identical(active, ctx));
    return ctx;
  }

  Future<void> _setRecent(List<String> list) async {
    _recent = list;
    await _saveRecentStore(list);
    _notify();
  }

  Future<void> clearRecent() => _setRecent(const []);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 启动恢复
  // ---------------------------------------------------------------------------

  /// 启动时:读最近项目和上次打开的项目列表,加载当前项目。
  /// 没有记录(老版本升级上来)就退回最近项目里的第一个。
  Future<void> restore() async {
    final recent = await _loadRecentStore();
    _recent = [for (final p in recent) if (await _directoryExists(p)) p];
    final saved = await _store.read();
    var paths = <String>[
      for (final p in saved.open)
        if (await _directoryExists(p)) normalize(p),
    ];
    if (paths.isEmpty && _recent.isNotEmpty) paths = [_recent.first];
    _projects
      ..clear()
      ..addAll([for (final p in paths.toSet()) OpenProject(p)]);
    if (_projects.isEmpty) {
      _notify();
      return;
    }
    final target = find(saved.active ?? '') ?? _projects.first;
    await _load(target);
    if (target.context != null) _active = target;
    _notify();
    await _persist();
  }

  // ---------------------------------------------------------------------------
  // 打开 / 切换 / 关闭
  // ---------------------------------------------------------------------------

  /// 打开 [rawPath] 并切过去。已经打开的只是切换,不会再开一份。
  /// 目录不存在或打开失败返回 false(列表不变)。
  Future<bool> open(String rawPath) async {
    final path = normalize(rawPath);
    final existing = find(path);
    if (existing != null) return activate(existing);
    if (!await _directoryExists(path)) return false;
    final entry = OpenProject(path);
    _projects.add(entry);
    final ok = await _load(entry);
    if (!ok) {
      _projects.remove(entry);
      _notify();
      return false;
    }
    _active = entry;
    _notify();
    await _persist();
    return true;
  }

  /// 切换到 [entry]:还没加载的先加载。加载失败返回 false,当前项目不变。
  Future<bool> activate(OpenProject entry) async {
    if (!_projects.contains(entry)) return false;
    if (entry.loading) return false;
    if (entry.context == null && !await _load(entry)) return false;
    if (identical(_active, entry)) return true;
    _active = entry;
    // 窗口布局是共享的:新项目里没有的工具窗(构建工具)要换回项目视图
    entry.context!.syncLayoutToProject();
    // 文件监视一直开着;切过去时再和磁盘对一遍,兜住监视漏掉的
    unawaited(entry.context!.sessions.syncWithDisk());
    _notify();
    await _persist();
    return true;
  }

  /// 把 [entry] 加载进内存(建它的状态、读文件树、恢复标签)。失败时 [OpenProject.error] 记着原因。
  Future<bool> _load(OpenProject entry) async {
    if (entry.context != null) return true;
    entry
      ..loading = true
      ..error = null;
    _notify();
    final ctx = _newContext();
    final ok = await ctx.open(entry.path);
    entry.loading = false;
    if (!ok) {
      entry.error = '无法打开 ${entry.path}';
      _notify();
      await ctx.dispose();
      return false;
    }
    entry.context = ctx;
    _notify();
    return true;
  }

  /// 关掉 [entry]:记下它的标签、释放它的语言服务器 / 终端 / 状态,从列表里移除。
  /// 关的是正在看的就切到相邻的那个(没有了就回到空状态)。调用方负责先处理未保存的改动。
  Future<void> close(OpenProject entry) async {
    final index = _projects.indexOf(entry);
    if (index < 0) return;
    final ctx = entry.context;
    if (ctx != null) await ctx.saveState();

    OpenProject? next = _active;
    if (identical(_active, entry)) {
      final others = [..._projects]..removeAt(index);
      // 优先接着它后面的,没有就用前面的
      next = others.isEmpty ? null : others[index.clamp(0, others.length - 1)];
      // 相邻的还没加载:先加载好再切,免得中间闪一下空状态
      if (next != null && next.context == null && !await _load(next)) next = null;
    }
    _projects.remove(entry);
    _active = next;
    next?.context?.syncLayoutToProject();
    _notify();
    await _persist();
    await ctx?.dispose();
  }

  /// 除了 [keep] 其余都关掉。
  Future<void> closeOthers(OpenProject keep) async {
    for (final e in [..._projects]) {
      if (!identical(e, keep)) await close(e);
    }
  }

  /// 离开前台 / 退出前:所有已加载项目的改动写盘、标签位置落盘。
  Future<void> saveAll() async {
    for (final e in _projects) {
      await e.context?.saveState();
    }
  }

  Future<void> _persist() => _store.write([for (final e in _projects) e.path], _active?.path);

  @override
  void dispose() {
    _disposed = true;
    for (final e in _projects) {
      e.context?.dispose();
    }
    _empty?.dispose();
    super.dispose();
  }
}
