import 'dart:async';

import 'package:flutter/foundation.dart';

import '../platform/workspace_io.dart' as io;
import '../plugins/plugin_manager.dart';
import '../client/api_client.dart';
import '../l10n/l10n.dart';
import '../lsp/lsp.dart' show LspService;
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

/// 项目组(IntelliJ 的 Project Group):把几个项目归到一个名字下,比如 bcpoker 下的各个服务。
/// 组记住成员的路径,项目关掉了也还在组里(显示成灰色,点一下重新打开)。一个项目只属于一个组。
class ProjectGroup {
  ProjectGroup(this.name, {String? id, List<String>? members, this.collapsed = false})
      : id = id ?? 'g${DateTime.now().microsecondsSinceEpoch.toRadixString(36)}',
        members = members ?? [];

  /// 不随改名变的标识:组里的 Java 项目共用一个 jdtls,它的索引缓存按这个放(改名不用重建索引)。
  final String id;

  String name;
  final List<String> members;
  bool collapsed;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'members': members, if (collapsed) 'collapsed': true};

  static ProjectGroup? fromJson(Object? j) {
    if (j is! Map) return null;
    final name = j['name'];
    if (name is! String || name.trim().isEmpty) return null;
    final id = j['id'];
    return ProjectGroup(
      name,
      id: id is String && id.isNotEmpty ? id : null,
      members: [for (final m in (j['members'] as List? ?? const [])) if (m is String && m.isNotEmpty) m],
      collapsed: j['collapsed'] == true,
    );
  }
}

/// 打开项目列表的存储:`~/.codelitex/open_projects.json`。读写可替换(测试)。
class OpenProjectsStore {
  OpenProjectsStore({Future<Map<String, dynamic>> Function()? load, Future<void> Function(Map<String, dynamic>)? save})
      : _load = load ?? io.loadOpenProjects,
        _save = save ?? io.saveOpenProjects;

  final Future<Map<String, dynamic>> Function() _load;
  final Future<void> Function(Map<String, dynamic>) _save;

  Future<({List<String> open, String? active, List<ProjectGroup> groups})> read() async {
    final j = await _load();
    final open = [for (final p in (j['open'] as List? ?? const [])) if (p is String && p.isNotEmpty) p];
    final active = j['active'];
    final groups = [for (final g in (j['groups'] as List? ?? const [])) ProjectGroup.fromJson(g)].nonNulls.toList();
    return (open: open, active: active is String ? active : null, groups: groups);
  }

  Future<void> write(List<String> open, String? active, [List<ProjectGroup> groups = const []]) => _save({
        'open': open,
        if (active != null) 'active': active,
        if (groups.isNotEmpty) 'groups': [for (final g in groups) g.toJson()],
      });
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
    Future<bool> Function(String path)? fileExists,
    ApiClient Function()? newClient,
  })  : _store = store ?? OpenProjectsStore(),
        _loadRecentStore = loadRecent ?? io.loadRecentProjects,
        _saveRecentStore = saveRecent ?? io.saveRecentProjects,
        _directoryExists = directoryExists ?? io.directoryExists,
        _fileExists = fileExists ?? io.fileExists {
    // 项目组里的 Java 项目共用一个语言服务器(按组的 id)
    LspService.shareKeyFor = _shareKeyFor;
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

  /// 项目根目录 → 它所在项目组的 id(语言服务器的共用键)。
  String? _shareKeyFor(String root) => groupOf(root)?.id;
  final OpenProjectsStore _store;
  final Future<List<String>> Function() _loadRecentStore;
  final Future<void> Function(List<String>) _saveRecentStore;
  final Future<bool> Function(String path) _directoryExists;
  final Future<bool> Function(String path) _fileExists;

  /// 打开的可以是目录(项目),也可以是单独一个文件。
  Future<bool> _exists(String path) async => await _directoryExists(path) || await _fileExists(path);

  final List<OpenProject> _projects = [];
  final List<ProjectGroup> _groups = [];
  OpenProject? _active;
  ProjectContext? _empty;
  List<String> _recent = const [];
  bool _disposed = false;

  /// 打开的项目,按打开的先后(列表里的顺序)。
  List<OpenProject> get projects => List.unmodifiable(_projects);

  /// 项目组(按建的先后)。
  List<ProjectGroup> get groups => List.unmodifiable(_groups);

  /// [path] 所在的项目组。
  ProjectGroup? groupOf(String path) {
    final p = normalize(path);
    for (final g in _groups) {
      if (g.members.contains(p)) return g;
    }
    return null;
  }

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
    if (_disposed) return;
    // 告诉各项目自己是不是在前台:后台久了的项目,语言服务器会被停掉(切回来再起)
    for (final e in _projects) {
      e.context?.client.lspSetActive(identical(e, _active));
    }
    notifyListeners();
  }

  /// [paths] 这些项目换了项目组:各自的 Java 语言服务器离开原来的组、接入新的。
  void _regroup(Iterable<String> paths) {
    for (final p in paths) {
      unawaited(find(p)?.context?.client.lspReattachServer('java'));
    }
  }

  // ---------------------------------------------------------------------------
  // 启动恢复
  // ---------------------------------------------------------------------------

  /// 启动时:读最近项目和上次打开的项目列表,加载当前项目。
  /// 没有记录(老版本升级上来)就退回最近项目里的第一个。
  Future<void> restore() async {
    final recent = await _loadRecentStore();
    _recent = [for (final p in recent) if (await _exists(p)) p];
    final saved = await _store.read();
    _groups
      ..clear()
      ..addAll(saved.groups);
    for (final g in _groups) {
      final kept = [for (final m in g.members) if (await _exists(m)) normalize(m)];
      g.members
        ..clear()
        ..addAll(kept.toSet());
    }
    var paths = <String>[
      for (final p in saved.open)
        if (await _exists(p)) normalize(p),
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
    if (!await _exists(path)) return false;
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
      entry.error = tr('无法打开 ${entry.path}', 'Cannot open ${entry.path}');
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

  Future<void> _persist() => _store.write([for (final e in _projects) e.path], _active?.path, _groups);

  // ---------------------------------------------------------------------------
  // 项目组
  // ---------------------------------------------------------------------------

  /// 名字是否可用(非空、不和已有的组重名,不分大小写)。[except] 是正在改名的那个组。
  bool groupNameAvailable(String name, {ProjectGroup? except}) {
    final n = name.trim().toLowerCase();
    return n.isNotEmpty && !_groups.any((g) => !identical(g, except) && g.name.toLowerCase() == n);
  }

  /// 新建项目组;名字不可用时返回 null。
  Future<ProjectGroup?> createGroup(String name) async {
    if (!groupNameAvailable(name)) return null;
    final g = ProjectGroup(name.trim());
    _groups.add(g);
    _notify();
    await _persist();
    return g;
  }

  Future<bool> renameGroup(ProjectGroup group, String name) async {
    if (!_groups.contains(group) || !groupNameAvailable(name, except: group)) return false;
    group.name = name.trim();
    _notify();
    await _persist();
    return true;
  }

  /// 删掉项目组:里面的项目不关,只是不再归组。
  Future<void> deleteGroup(ProjectGroup group) async {
    if (!_groups.remove(group)) return;
    _regroup(group.members);
    _notify();
    await _persist();
  }

  /// 把 [path] 归到 [group](从原来的组里移出);[group] 为 null 就是移出项目组。
  Future<void> moveToGroup(String path, ProjectGroup? group) async {
    final p = normalize(path);
    final from = groupOf(p);
    if (identical(from, group)) return;
    from?.members.remove(p);
    if (group != null && _groups.contains(group)) group.members.add(p);
    _regroup([p]);
    _notify();
    await _persist();
  }

  Future<void> setGroupCollapsed(ProjectGroup group, bool collapsed) async {
    if (group.collapsed == collapsed) return;
    group.collapsed = collapsed;
    _notify();
    await _persist();
  }

  /// 打开组里还没打开的项目(先放进列表、第一次切过去才加载,同启动恢复),并切到组里第一个。
  Future<void> openGroup(ProjectGroup group) async {
    for (final m in group.members) {
      if (find(m) == null && await _exists(m)) _projects.add(OpenProject(m));
    }
    _notify();
    final first = group.members.map(find).nonNulls.firstOrNull;
    if (first != null && !await activate(first)) await _persist();
  }

  @override
  void dispose() {
    _disposed = true;
    if (LspService.shareKeyFor == _shareKeyFor) LspService.shareKeyFor = null; // 方法引用按 == 比较
    for (final e in _projects) {
      e.context?.dispose();
    }
    _empty?.dispose();
    super.dispose();
  }
}
