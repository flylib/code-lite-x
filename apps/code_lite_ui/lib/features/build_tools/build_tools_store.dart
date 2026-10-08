import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/build_tools/build_model.dart';
import '../../core/plugins/plugin_manager.dart';

/// 项目里检测到的一种构建工具(比如根目录有 pom.xml → Maven)及其模块树。
class BuildProject {
  const BuildProject({required this.tool, required this.buildFile, required this.root, this.wrapper = false});

  final BuildToolContribution tool;

  /// 根构建文件(相对项目根)。
  final String buildFile;
  final BuildModule root;

  /// 项目自带包装脚本(mvnw),运行时用它。
  final bool wrapper;
}

/// 构建工具窗的状态:检测项目里有哪些构建工具(由已启用插件的 contributes.buildTools 声明),
/// 读模块树,记住展开 / 选中 / 工具栏开关,拼命令交给终端运行。
///
/// 放在面板之外:左侧工具窗切走时面板被卸载,展开状态和开关不该丢。
class BuildToolsStore extends ChangeNotifier {
  BuildToolsStore({
    required this.plugins,
    required this.projectRoot,
    required this.read,
    required this.runner,
    Stream<String>? fileSaved,
    this.windows = false,
  }) {
    _toolsSignature = _signature();
    plugins.addListener(_onPluginsChanged);
    _savedSub = fileSaved?.listen(_onFileSaved);
  }

  final PluginManager plugins;

  /// 当前项目根目录;没有打开项目时 null。
  final String? Function() projectRoot;
  final BuildFileReader read;

  /// 在终端里运行:标签标题、命令行。
  final void Function(String title, String command) runner;
  final bool windows;

  StreamSubscription<String>? _savedSub;
  String _toolsSignature = '';
  int _generation = 0;
  String? _loadedRoot;

  List<BuildProject> _projects = const [];
  bool _loading = false;
  final Set<String> _expanded = {};
  final Map<String, Set<String>> _options = {};
  String? _selectedModule;
  final List<String> _selectedTasks = [];

  List<BuildProject> get projects => _projects;
  bool get loading => _loading;

  /// 检测到了构建工具(活动条据此显示按钮)。
  bool get hasProjects => _projects.isNotEmpty;

  /// 活动条按钮的提示文字。
  String get title => _projects.isEmpty ? '构建' : _projects.map((p) => p.tool.name).toSet().join(' / ');

  // ---------------------------------------------------------------------------
  // 加载
  // ---------------------------------------------------------------------------

  /// 重新检测并读取模块树(打开 / 切换项目、点刷新、构建文件保存后)。
  Future<void> reload() async {
    final gen = ++_generation;
    final root = projectRoot();
    if (root == null) {
      final had = _projects.isNotEmpty || _loading;
      _projects = const [];
      _loading = false;
      _expanded.clear();
      _clearSelection();
      _loadedRoot = null;
      if (had) notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    final name = root.split(RegExp(r'[/\\]')).lastWhere((s) => s.isNotEmpty, orElse: () => root);
    final found = <BuildProject>[];
    for (final tool in plugins.buildTools) {
      for (final marker in tool.markers) {
        if (await read(marker) == null) continue;
        final w = tool.wrapper;
        final wrapper = w != null && await read(windows ? '$w.cmd' : w) != null;
        BuildModule model;
        try {
          model = await readBuildModel(tool, marker, name, read);
        } catch (e) {
          model = BuildModule(name: name, buildFile: marker, error: '$e');
        }
        found.add(BuildProject(tool: tool, buildFile: marker, root: model, wrapper: wrapper));
        break;
      }
    }
    if (gen != _generation) return; // 期间又换了项目 / 又刷新了一次
    // 换了项目(或之前没检测到):展开状态从头来
    final first = root != _loadedRoot || _projects.isEmpty;
    if (root != _loadedRoot) {
      _expanded.clear();
      _clearSelection();
    }
    _loadedRoot = root;
    _projects = found;
    _loading = false;
    if (first) {
      // 第一次加载:展开根模块和它的第一组任务(IntelliJ 打开 Maven 窗口时就能看到 Lifecycle)
      for (final p in found) {
        _expanded.add(moduleKey(p, p.root));
        if (p.tool.taskGroups.isNotEmpty) _expanded.add(groupKey(p, p.root, p.tool.taskGroups.first.name));
      }
    }
    final all = {for (final p in found) for (final m in p.root.all) moduleKey(p, m)};
    if (_selectedModule != null && !all.contains(_selectedModule)) _clearSelection();
    notifyListeners();
  }

  /// 构建工具来自插件:启用 / 停用 / 安装了声明构建工具的插件时重新检测。
  void _onPluginsChanged() {
    final s = _signature();
    if (s == _toolsSignature) return;
    _toolsSignature = s;
    reload();
  }

  String _signature() => [for (final t in plugins.buildTools) t.id].join(',');

  /// 编辑器保存了某个模块的构建文件:模块可能增删了,重新读。
  void _onFileSaved(String path) {
    final norm = path.replaceAll('\\', '/');
    for (final p in _projects) {
      if (p.root.all.any((m) => m.buildFile == norm)) {
        reload();
        return;
      }
    }
    // 还没检测到项目时,新建的根构建文件也算
    if (_projects.isEmpty && plugins.buildTools.any((t) => t.markers.contains(norm))) reload();
  }

  // ---------------------------------------------------------------------------
  // 树的展开与选中
  // ---------------------------------------------------------------------------

  static String moduleKey(BuildProject p, BuildModule m) => '${p.tool.id}:${m.buildFile}';
  static String groupKey(BuildProject p, BuildModule m, String group) => '${moduleKey(p, m)}#$group';

  bool isExpanded(String key) => _expanded.contains(key);

  void toggleExpanded(String key) {
    _expanded.contains(key) ? _expanded.remove(key) : _expanded.add(key);
    notifyListeners();
  }

  void collapseAll() {
    if (_expanded.isEmpty) return;
    _expanded.clear();
    notifyListeners();
  }

  /// 选中的模块(模块行或它下面的任务行被点中)。
  String? get selectedModule => _selectedModule;
  List<String> get selectedTasks => List.unmodifiable(_selectedTasks);

  bool isTaskSelected(String moduleKey, String task) => _selectedModule == moduleKey && _selectedTasks.contains(task);

  void selectModule(String moduleKey) {
    _selectedModule = moduleKey;
    _selectedTasks.clear();
    notifyListeners();
  }

  /// 点任务;[toggle](⌘ / Ctrl 点击)时在同一模块里多选,运行时按生命周期顺序一起执行。
  void selectTask(String moduleKey, String task, {bool toggle = false}) {
    if (!toggle || _selectedModule != moduleKey) {
      _selectedModule = moduleKey;
      _selectedTasks
        ..clear()
        ..add(task);
    } else if (!_selectedTasks.remove(task)) {
      _selectedTasks.add(task);
    }
    notifyListeners();
  }

  void _clearSelection() {
    _selectedModule = null;
    _selectedTasks.clear();
  }

  // ---------------------------------------------------------------------------
  // 工具栏开关与运行
  // ---------------------------------------------------------------------------

  bool isOptionOn(BuildToolContribution tool, String option) => _options[tool.id]?.contains(option) ?? false;

  void toggleOption(BuildToolContribution tool, String option) {
    final set = _options.putIfAbsent(tool.id, () => {});
    set.contains(option) ? set.remove(option) : set.add(option);
    notifyListeners();
  }

  /// 在 [module] 上运行 [tasks] 的命令行。
  String commandFor(BuildProject project, BuildModule module, List<String> tasks) => buildCommandLine(
        project.tool,
        module,
        tasks,
        rootBuildFile: project.buildFile,
        wrapper: project.wrapper,
        options: _options[project.tool.id] ?? const {},
        windows: windows,
      );

  void run(BuildProject project, BuildModule module, List<String> tasks) {
    if (tasks.isEmpty) return;
    runner('${module.name} [${tasks.join(',')}]', commandFor(project, module, tasks));
  }

  /// 运行选中的任务(工具栏 ▶);多选时按清单里的顺序。返回是否有可运行的选中项。
  bool runSelected() {
    final sel = _selection();
    if (sel == null) return false;
    final (project, module) = sel;
    final order = [for (final g in project.tool.taskGroups) ...g.tasks];
    final tasks = [..._selectedTasks]..sort((a, b) => order.indexOf(a).compareTo(order.indexOf(b)));
    if (tasks.isEmpty) return false;
    run(project, module, tasks);
    return true;
  }

  bool get canRunSelected => _selection() != null && _selectedTasks.isNotEmpty;

  (BuildProject, BuildModule)? _selection() {
    final key = _selectedModule;
    if (key == null) return null;
    for (final p in _projects) {
      for (final m in p.root.all) {
        if (moduleKey(p, m) == key) return (p, m);
      }
    }
    return null;
  }

  /// 工具栏开关属于哪个构建工具:选中项所在的,否则第一个。
  BuildProject? get toolbarProject => _selection()?.$1 ?? (_projects.isEmpty ? null : _projects.first);

  @override
  void dispose() {
    plugins.removeListener(_onPluginsChanged);
    _savedSub?.cancel();
    super.dispose();
  }
}
