import 'package:flutter/foundation.dart';

import '../../features/editor/editor_session_manager.dart';
import '../../features/editor/lsp_overlay.dart';
import '../client/api_client.dart';

/// 工作区级状态:文件树、当前文件、打开的标签、结构大纲、诊断。
///
/// 缓冲区内容与光标不在这里 —— 那些归 EditorSessionManager 的
/// CodeEditorController 管,每次按键只通知订阅了该 controller 的子树。
/// 这个划分是为了让"敲字"和"换文件"走两条不同的通知路径。
class WorkspaceStore extends ChangeNotifier {
  WorkspaceStore({required ApiClient client, required EditorSessionManager sessions})
      : _client = client,
        _sessions = sessions;

  final ApiClient _client;
  final EditorSessionManager _sessions;

  Map<String, dynamic> _tree = const {};
  List<dynamic> _outline = const [];
  String? _activeSymbol;
  List<EditorDiagnostic> _diagnostics = const [];
  bool _isLoading = true;

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

  Future<void> load() async {
    _tree = await _client.fetchWorkspaceTree();
    _isLoading = false;
    notifyListeners();
  }

  Future<void> openFile(String path) async {
    final tab = await _sessions.openFile(path);
    final outline = await _client.queryOutline(path);

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
