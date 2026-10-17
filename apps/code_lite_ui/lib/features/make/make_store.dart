import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/build_tools/makefile.dart';
import '../../core/state/dispose_safe.dart';

/// 项目里的一个 Makefile 和它的目标。
class MakeFile {
  const MakeFile(this.path, this.targets);

  /// 相对项目根的路径。
  final String path;
  final List<MakeTarget> targets;
}

/// make 工具窗(IntelliJ 的 make 插件):项目里的 Makefile → 目标,双击运行。
///
/// 每个项目一份。Makefile 从项目文件清单里找([listMakefiles]),目标自己读(不跑 make);
/// 编辑器保存了 / 别处改了 Makefile 时重新读。运行就是在新的终端标签里敲 `make <目标>`,
/// make 的路径取自设置([makePath],空的话用 PATH 里的 make)。
class MakeStore extends ChangeNotifier with DisposeSafeNotifier {
  MakeStore({
    required this.projectRoot,
    required this.read,
    required this.listMakefiles,
    required this.runner,
    required this.makePath,
    Stream<String>? fileSaved,
  }) {
    _savedSub = fileSaved?.listen(onFilesChanged);
  }

  final String? Function() projectRoot;

  /// 读项目里的文件(相对路径);不存在返回 null。
  final Future<String?> Function(String path) read;

  /// 项目里所有的 Makefile(相对路径);文件清单还没建好时返回 null(过一会儿再问)。
  final Future<List<String>?> Function() listMakefiles;

  /// 新开终端标签运行命令。
  final void Function(String title, String command) runner;

  /// 设置里的 make 路径。
  final String Function() makePath;

  StreamSubscription<String>? _savedSub;
  List<MakeFile> _files = const [];
  bool _loading = false;
  String? _loadedRoot;
  Timer? _retry;
  int _retries = 0;

  final Set<String> _expanded = {};
  String? _selectedFile;
  String? _selectedTarget;

  /// 工具栏开关:按名字排序(默认按文件里的顺序)、显示 `.PHONY` 这类特殊目标。
  bool sortByName = false;
  bool showSpecial = false;

  List<MakeFile> get files => _files;
  bool get loading => _loading;

  /// 项目里有 Makefile(活动条据此显示按钮)。
  bool get hasMakefiles => _files.isNotEmpty;

  /// [file] 要显示的目标(按工具栏的开关过滤、排序)。
  List<MakeTarget> visibleTargets(MakeFile file) {
    final list = [for (final t in file.targets) if (showSpecial || !t.special) t];
    if (sortByName) list.sort((a, b) => a.name.compareTo(b.name));
    return list;
  }

  // ---------------------------------------------------------------------------
  // 加载
  // ---------------------------------------------------------------------------

  Future<void> reload() async {
    final root = projectRoot();
    _retry?.cancel();
    if (root == null) {
      final had = _files.isNotEmpty;
      _files = const [];
      _expanded.clear();
      _loadedRoot = null;
      if (had) notifyListeners();
      return;
    }
    _loading = true;
    notifyListeners();
    var paths = await listMakefiles();
    if (paths == null) {
      // 文件清单还在建:先看根目录,过一会儿再找子目录里的
      paths = [
        for (final n in const ['GNUmakefile', 'makefile', 'Makefile'])
          if (await read(n) != null) n,
      ];
      if (_retries++ < 20) _retry = Timer(const Duration(seconds: 1), reload);
    } else {
      _retries = 0;
    }
    final found = <MakeFile>[];
    for (final p in {...paths}.toList()..sort(_byDepth)) {
      final text = await read(p);
      if (text != null) found.add(MakeFile(p, parseMakeTargets(text)));
    }
    if (projectRoot() != root) return; // 加载期间换了项目
    if (root != _loadedRoot) {
      _expanded.clear();
      _selectedFile = _selectedTarget = null;
      // 第一次:展开第一个 Makefile(IntelliJ 也是)
      if (found.isNotEmpty) _expanded.add(found.first.path);
    }
    _loadedRoot = root;
    _files = found;
    _loading = false;
    notifyListeners();
  }

  /// 根目录的排前面,同层按路径。
  static int _byDepth(String a, String b) {
    final da = '/'.allMatches(a).length, db = '/'.allMatches(b).length;
    return da != db ? da - db : a.compareTo(b);
  }

  /// 文件改了(编辑器保存 / 文件监视):是 Makefile 就重新读。
  void onFilesChanged(String path) {
    if (isMakefileName(path)) unawaited(reload());
  }

  // ---------------------------------------------------------------------------
  // 树
  // ---------------------------------------------------------------------------

  bool isExpanded(String file) => _expanded.contains(file);

  void toggleExpanded(String file) {
    _expanded.contains(file) ? _expanded.remove(file) : _expanded.add(file);
    notifyListeners();
  }

  void expandAll() {
    _expanded.addAll(_files.map((f) => f.path));
    notifyListeners();
  }

  void collapseAll() {
    _expanded.clear();
    notifyListeners();
  }

  void toggleSortByName() {
    sortByName = !sortByName;
    notifyListeners();
  }

  void toggleShowSpecial() {
    showSpecial = !showSpecial;
    notifyListeners();
  }

  String? get selectedFile => _selectedFile;
  String? get selectedTarget => _selectedTarget;

  void select(String file, [String? target]) {
    _selectedFile = file;
    _selectedTarget = target;
    notifyListeners();
  }

  bool get canRunSelected => _selectedFile != null && _selectedTarget != null;

  // ---------------------------------------------------------------------------
  // 运行
  // ---------------------------------------------------------------------------

  /// 运行 [makefile](相对项目根)里的 [target] 的命令行。
  String commandFor(String makefile, String target) => makeCommandLine(makePath(), makefile, target);

  void run(String makefile, String target) => runner('make $target', commandFor(makefile, target));

  /// 工具栏 ▶:运行选中的目标。返回有没有可运行的。
  bool runSelected() {
    final f = _selectedFile, t = _selectedTarget;
    if (f == null || t == null) return false;
    run(f, t);
    return true;
  }

  /// 编辑器行号栏的 ▶:[filePath] 可以是相对项目根的路径,也可以是绝对路径(从文件树打开的标签)。
  void runTarget(String filePath, String target) {
    final root = projectRoot();
    var rel = filePath.replaceAll('\\', '/');
    if (root != null) {
      final prefix = root.endsWith('/') ? root : '$root/';
      if (rel.startsWith(prefix)) rel = rel.substring(prefix.length);
    }
    run(rel, target);
  }

  @override
  void dispose() {
    _retry?.cancel();
    _savedSub?.cancel();
    super.dispose();
  }
}
