import 'package:flutter/foundation.dart';

import '../../features/editor/editor_session_manager.dart';
import '../../features/editor/lsp_overlay.dart';
import '../client/api_client.dart';
import '../platform/workspace_io.dart' as io;

/// 工作区级状态:文件树、当前文件、打开的标签、结构大纲、诊断。
///
/// 缓冲区内容与光标不在这里 —— 那些归 EditorSessionManager 的
/// CodeEditorController 管,每次按键只通知订阅了该 controller 的子树。
/// 这个划分是为了让"敲字"和"换文件"走两条不同的通知路径。
class WorkspaceStore extends ChangeNotifier {
  WorkspaceStore({required ApiClient client, required EditorSessionManager sessions})
      : _client = client,
        _sessions = sessions {
    _sessions.diagnosticsRevision.addListener(_onDiagnosticsChanged);
  }

  /// 诊断更新说明语言服务器重新分析过当前文件:状态栏的错误数要变,大纲也顺带刷新。
  void _onDiagnosticsChanged() {
    final active = _sessions.activePath;
    if (active != null && _sessions.lastDiagnosticsPath == active) {
      _refreshOutline(active);
    }
    notifyListeners();
  }

  Future<void> _refreshOutline(String path) async {
    final tab = _sessions.tabs[path];
    if (tab == null) return;
    final outline = await _client.documentSymbols(path, tab.controller.text);
    if (_sessions.activePath != path) return; // 期间切了标签,丢弃
    _outline = outline;
    if (_activeSymbol != null && !outline.any((o) => o['name'] == _activeSymbol)) {
      _activeSymbol = outline.isEmpty ? null : outline.first['name'] as String?;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    _sessions.diagnosticsRevision.removeListener(_onDiagnosticsChanged);
    super.dispose();
  }

  final ApiClient _client;
  final EditorSessionManager _sessions;

  Map<String, dynamic> _tree = const {};
  List<dynamic> _outline = const [];
  String? _activeSymbol;
  List<EditorDiagnostic> _diagnostics = const [];
  bool _isLoading = true;
  String? _rootPath;
  List<String> _recentProjects = const [];

  static const _maxRecent = 10;

  EditorSessionManager get sessions => _sessions;
  Map<String, dynamic> get tree => _tree;
  List<dynamic> get outline => _outline;
  String? get activeSymbol => _activeSymbol;
  List<EditorDiagnostic> get diagnostics =>
      _sessions.activeTab?.diagnostics ?? _diagnostics;
  bool get isLoading => _isLoading;

  String get activeFile => _sessions.activePath ?? '';
  List<String> get openTabs => _sessions.openPaths;

  int get errorCount => diagnostics.where((d) => d.isError).length;
  int get warningCount => diagnostics.where((d) => d.isWarning).length;

  /// 当前项目根目录;没打开项目时为 null。
  String? get rootPath => _rootPath;
  bool get hasProject => _rootPath != null;
  String get projectName => _rootPath?.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';

  /// 最近打开的项目,最新的在前,已剔除磁盘上不存在的。
  List<String> get recentProjects => _recentProjects;

  /// 启动时调用:恢复最近项目列表,并重新打开上次的项目。
  /// 没有可恢复的项目时:原生保持"无项目"空态;没有 FFI(web 预览)沿用 mock 树。
  Future<void> bootstrap() async {
    await _refreshRecent();
    final last = _recentProjects.firstOrNull;
    if (last != null && await openFolder(last)) return;
    if (!_client.isFfiAvailable) {
      await load();
      return;
    }
    _isLoading = false;
    notifyListeners();
  }

  /// 切换到另一个项目目录。失败(目录不存在 / Rust Core 初始化失败)返回 false,
  /// 此时仍停留在原项目。
  Future<bool> openFolder(String path) async {
    if (!await io.directoryExists(path)) return false;
    final previous = _rootPath;
    final hadCore = _client.isFfiAvailable;
    if (!_client.openWorkspace(path) && hadCore) {
      if (previous != null) _client.openWorkspace(previous);
      return false;
    }
    _sessions.closeAll();
    _outline = const [];
    _activeSymbol = null;
    _diagnostics = const [];
    _rootPath = path;
    await _remember(path);
    await load();
    return true;
  }

  /// File → Close Project:回到空态。Rust Core 仍挂在旧根上,但 UI 不再展示它。
  void closeProject() {
    _sessions.closeAll();
    _rootPath = null;
    _tree = const {};
    _outline = const [];
    _activeSymbol = null;
    _diagnostics = const [];
    notifyListeners();
  }

  /// File → New → File:在项目内创建空文件并打开。成功返回 null,失败返回原因。
  Future<String?> createFile(String relPath) async {
    final root = _rootPath;
    if (root == null) return '请先打开一个项目';
    final clean = relPath.trim().replaceAll(RegExp(r'^/+'), '');
    if (clean.isEmpty || clean.endsWith('/')) return '文件名不能为空';
    if (clean.split('/').contains('..')) return '路径不能包含 ..';
    final err = await io.createEmptyFile(root, clean);
    if (err != null) return err;
    await load();
    await openFile(clean);
    return null;
  }

  Future<void> _refreshRecent() async {
    final saved = await io.loadRecentProjects();
    final alive = <String>[];
    for (final p in saved) {
      if (await io.directoryExists(p)) alive.add(p);
    }
    _recentProjects = alive;
  }

  Future<void> _remember(String path) async {
    _recentProjects = [path, ..._recentProjects.where((p) => p != path)].take(_maxRecent).toList();
    await io.saveRecentProjects(_recentProjects);
  }

  Future<void> clearRecentProjects() async {
    _recentProjects = const [];
    await io.saveRecentProjects(const []);
    notifyListeners();
  }

  Future<void> load() async {
    _tree = await _client.fetchWorkspaceTree();
    _isLoading = false;
    notifyListeners();
  }

  /// Commit 窗点文件:在编辑区打开该文件的差异标签。[repoPath] 相对仓库根。
  void openDiff(String repoPath) {
    _sessions.openDiff(repoPath);
    _outline = const [];
    _activeSymbol = null;
    notifyListeners();
  }

  /// 打开 PR 差异 / Timeline 等特殊标签(没有大纲)。
  void openSpecial(String id) {
    _sessions.openSpecial(id);
    _outline = const [];
    _activeSymbol = null;
    notifyListeners();
  }

  Future<void> openFile(String path) async {
    // 差异标签(「Commit: 文件名」)不是文件:只切换,没有大纲。
    if (_sessions.isSpecialTab(path)) {
      _sessions.selectTab(path);
      _outline = const [];
      _activeSymbol = null;
      notifyListeners();
      return;
    }
    final tab = await _sessions.openFile(path);
    final outline = await _client.documentSymbols(path, tab.controller.text);

    _outline = outline;
    _activeSymbol = outline.isEmpty ? null : outline.first['name'] as String?;
    _diagnostics = tab.diagnostics;
    notifyListeners();
  }

  void selectSymbol(String? name) {
    if (_activeSymbol == name) return;
    _activeSymbol = name;
    notifyListeners();
  }

  /// 关闭标签。调用方负责先处理未保存提示 —— store 不弹 UI。
  void closeTab(String path, {bool force = false}) {
    _sessions.closeTab(path, force: force);
    final next = _sessions.activePath;
    if (next != null) {
      openFile(next);
    } else {
      _outline = const [];
      _activeSymbol = null;
      notifyListeners();
    }
  }

  void reorderTabs(int oldIndex, int newIndex) {
    _sessions.reorderTabs(oldIndex, newIndex);
    notifyListeners();
  }

  bool isDirty(String path) => _sessions.tabs[path]?.isDirty ?? false;

  Future<void> save() => _sessions.saveActiveFile();
  Future<void> undo() => _sessions.undoActive();
  Future<void> redo() => _sessions.redoActive();
}
