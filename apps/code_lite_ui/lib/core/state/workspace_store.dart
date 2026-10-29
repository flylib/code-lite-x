import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../features/editor/code_editor_controller.dart' show EditorPosition;
import '../../features/editor/editor_session_manager.dart';
import '../../features/editor/lsp_overlay.dart';
import '../client/api_client.dart';
import '../l10n/l10n.dart';
import '../platform/paths.dart';
import '../platform/workspace_io.dart' as io;
import 'session_snapshot.dart';
import 'dispose_safe.dart';

/// 工作区级状态:文件树、当前文件、打开的标签、结构大纲、诊断。
///
/// 缓冲区内容与光标不在这里 —— 那些归 EditorSessionManager 的
/// CodeEditorController 管,每次按键只通知订阅了该 controller 的子树。
/// 这个划分是为了让"敲字"和"换文件"走两条不同的通知路径。
class WorkspaceStore extends ChangeNotifier with DisposeSafeNotifier {
  WorkspaceStore({
    required ApiClient client,
    required EditorSessionManager sessions,
    SessionStore? sessionStore,
    Future<bool> Function(String path)? fileExists,
    Future<List<String>> Function()? loadRecent,
    Future<void> Function(List<String>)? saveRecent,
  })  : _client = client,
        _sessions = sessions,
        _sessionStore = sessionStore ?? SessionStore(),
        _fileExists = fileExists ?? io.fileExists,
        _loadRecent = loadRecent ?? io.loadRecentProjects,
        _saveRecent = saveRecent ?? io.saveRecentProjects {
    _sessions.diagnosticsRevision.addListener(_onDiagnosticsChanged);
    _sessions.addListener(_onSessionsChanged);
  }

  final SessionStore _sessionStore;
  final Future<bool> Function(String path) _fileExists;

  /// 最近项目列表的读写;测试里换成内存实现,不碰用户的 ~/.codelitex。
  final Future<List<String>> Function() _loadRecent;
  final Future<void> Function(List<String>) _saveRecent;

  /// 正在切换项目 / 恢复上次状态:这期间标签是半开的,不能把它当成用户的状态存下来。
  bool _restoring = false;
  Timer? _sessionSaveTimer;
  String _savedSignature = '';

  /// 标签开了 / 关了 / 切了:稍等一下再存(连续操作合并成一次)。
  /// 光标和滚动不通知这里,由应用定时调用 [saveSession] 补上。
  void _onSessionsChanged() {
    if (_rootPath == null || _restoring) return;
    _sessionSaveTimer?.cancel();
    _sessionSaveTimer = Timer(const Duration(milliseconds: 500), saveSession);
  }

  /// 把当前项目的标签 / 光标 / 滚动位置存下来(没变就不写)。应用失去焦点、定时、切换 / 关闭项目时调用。
  Future<void> saveSession() async {
    final root = _sessionKey;
    if (root == null || _restoring) return;
    final snap = _sessions.snapshot(); // 同步取,之后项目怎么变都不影响这次存的内容
    final sig = snap.signature;
    if (sig == _savedSignature) return;
    _savedSignature = sig;
    await _sessionStore.write(root, snap);
  }

  /// 打开 [root] 后按上次的状态重新打开标签:跳过已经不存在的文件,光标和滚动位置放回去,
  /// 最后切到上次的当前标签。
  Future<void> _restoreSession(String root, {String? key}) async {
    final snap = await _sessionStore.read(key ?? root);
    final opened = <String>[];
    for (final t in snap.tabs) {
      // 标签路径可能是绝对的(文件树给的),也可能是相对项目根的:不能一律拼上项目根
      if (!await _fileExists(absoluteFilePath(root, t.path))) continue;
      final tab = await _sessions.openFile(t.path, scroll: t.scroll);
      if (tab.loadError != null) {
        _sessions.closeTab(t.path);
        continue;
      }
      tab.controller.setCursor(EditorPosition(t.line, t.col));
      opened.add(t.path);
    }
    final target = snap.active != null && opened.contains(snap.active) ? snap.active : opened.lastOrNull;
    if (target != null) await openFile(target); // 顺带取大纲
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
    _sessionSaveTimer?.cancel();
    _sessions.removeListener(_onSessionsChanged);
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

  /// 当前项目根目录;没打开项目时为 null。单独打开一个文件时是它所在的目录。
  String? get rootPath => _rootPath;
  bool get hasProject => _rootPath != null;

  /// 单独打开的那个文件(File → Open 选的是文件);打开的是目录时为 null。
  String? _singleFile;
  String? get singleFile => _singleFile;
  bool get isSingleFile => _singleFile != null;

  /// 项目名:目录名;单独打开的文件就是文件名。
  String get projectName => (_singleFile ?? _rootPath)?.split('/').where((s) => s.isNotEmpty).lastOrNull ?? '';

  /// 会话(标签、光标)按什么存:目录;单独打开的文件按它自己的路径(不和它所在目录的项目混在一起)。
  String? get _sessionKey => _singleFile ?? _rootPath;

  /// 最近打开的项目,最新的在前,已剔除磁盘上不存在的。
  List<String> get recentProjects => _recentProjects;

  /// 启动时调用:恢复最近项目列表,并重新打开上次的项目。
  /// 没有可恢复的项目时:原生保持"无项目"空态;没有 FFI(web 预览)沿用 mock 树。
  Future<void> bootstrap() async {
    await _refreshRecent();
    final last = _recentProjects.firstOrNull;
    if (last != null && (await openFolder(last) || await openSingleFile(last))) return;
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
    await saveSession(); // 离开的项目:记住它的标签
    final previous = _rootPath;
    final hadCore = _client.isFfiAvailable;
    if (!_client.openWorkspace(path) && hadCore) {
      if (previous != null) _client.openWorkspace(previous);
      return false;
    }
    _sessionSaveTimer?.cancel();
    _restoring = true;
    try {
      _sessions.closeAll();
      _outline = const [];
      _activeSymbol = null;
      _diagnostics = const [];
      _rootPath = path;
      _singleFile = null;
      await _remember(path);
      await load();
      await _restoreSession(path);
    } finally {
      _restoring = false;
      _savedSignature = _sessions.snapshot().signature;
    }
    return true;
  }

  /// 单独打开一个文件(File → Open 选的是文件):工作目录是它所在的目录,文件树里只有它,打开后直接显示它。
  /// 不起语言服务器、不监视 / 不索引那个目录(见 [ApiClient.openSingleFile])。
  Future<bool> openSingleFile(String filePath) async {
    if (!await _fileExists(filePath)) return false;
    await saveSession();
    final previous = _rootPath;
    final previousFile = _singleFile;
    final hadCore = _client.isFfiAvailable;
    if (!_client.openSingleFile(filePath) && hadCore) {
      if (previous != null) {
        previousFile != null ? _client.openSingleFile(previousFile) : _client.openWorkspace(previous);
      }
      return false;
    }
    _sessionSaveTimer?.cancel();
    _restoring = true;
    try {
      _sessions.closeAll();
      _outline = const [];
      _activeSymbol = null;
      _diagnostics = const [];
      _rootPath = _client.rootPath;
      _singleFile = filePath;
      await _remember(filePath);
      await load();
      await _restoreSession(_rootPath!, key: filePath);
      if (!_sessions.tabs.containsKey(filePath)) await openFile(filePath);
    } finally {
      _restoring = false;
      _savedSignature = _sessions.snapshot().signature;
    }
    return true;
  }

  /// File → Close Project:回到空态。Rust Core 仍挂在旧根上,但 UI 不再展示它。
  void closeProject() {
    unawaited(saveSession()); // 先取快照,再关标签
    _sessionSaveTimer?.cancel();
    _rootPath = null;
    _singleFile = null;
    _sessions.closeAll();
    _tree = const {};
    _outline = const [];
    _activeSymbol = null;
    _diagnostics = const [];
    notifyListeners();
  }

  /// File → New → File:在项目内创建空文件并打开。成功返回 null,失败返回原因。
  Future<String?> createFile(String relPath) async {
    final root = _rootPath;
    if (root == null) return tr('请先打开一个项目', 'Open a project first');
    final clean = relPath.trim().replaceAll(RegExp(r'^/+'), '');
    if (clean.isEmpty || clean.endsWith('/')) return tr('文件名不能为空', 'The file name cannot be empty');
    if (clean.split('/').contains('..')) return tr('路径不能包含 ..', 'The path cannot contain ..');
    final err = await io.createEmptyFile(root, clean);
    if (err != null) return err;
    await load();
    await openFile(clean);
    return null;
  }

  /// 文件树右键 ▸ Rename(⇧F6):把 [path](文件或目录,绝对或相对项目)改名为 [newName](同一目录下)。
  /// 先保存没保存的修改,改名后打开着的标签跟到新路径,文件树重读。成功返回 null,失败返回原因。
  /// 只改文件名,不改代码里对它的引用。
  Future<String?> renamePath(String path, String newName) async {
    final root = _rootPath;
    if (root == null) return tr('请先打开一个项目', 'Open a project first');
    final err = renameNameError(newName);
    if (err != null) return err;
    final from = absoluteFilePath(root, path);
    final slash = from.lastIndexOf('/');
    if (slash <= 0) return tr('不能改这个名字', 'This item cannot be renamed');
    final to = '${from.substring(0, slash)}/${newName.trim()}';
    if (to == from) return null;
    await _sessions.saveAll();
    final failed = await io.renamePath(from, to);
    if (failed != null) return failed;
    _sessions.retargetPaths(root, from, to);
    await load();
    return null;
  }

  Future<void> _refreshRecent() async {
    final saved = await _loadRecent();
    final alive = <String>[];
    for (final p in saved) {
      // 最近打开的可能是目录,也可能是单独打开的文件
      if (await io.directoryExists(p) || await _fileExists(p)) alive.add(p);
    }
    _recentProjects = alive;
  }

  Future<void> _remember(String path) async {
    // 同时打开多个项目时,别的项目的 WorkspaceStore 也在更新这份列表:以存储里最新的为准,不用本地可能过期的副本
    _recentProjects = [path, ...(await _loadRecent()).where((p) => p != path)].take(_maxRecent).toList();
    await _saveRecent(_recentProjects);
  }

  Future<void> clearRecentProjects() async {
    _recentProjects = const [];
    await _saveRecent(const []);
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

  /// 保存指定标签(关闭标签前用)。
  Future<bool> saveFile(String path) => _sessions.saveFile(path);
  Future<void> undo() => _sessions.undoActive();
  Future<void> redo() => _sessions.redoActive();
}
