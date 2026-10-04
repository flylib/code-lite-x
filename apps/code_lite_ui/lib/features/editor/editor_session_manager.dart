import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/client/api_client.dart';
import '../../core/lsp/lsp.dart';
import 'code_editor_controller.dart';
import 'lsp_overlay.dart';

/// Holds independent buffer, viewport, cursor, and diagnostic state for an open editor tab.
class EditorTabState {
  final String filePath;
  final String fileName;
  final CodeEditorController controller;
  final ScrollController verticalScroll;
  final ScrollController horizontalScroll;
  List<EditorDiagnostic> diagnostics;
  String? activeSymbol;

  /// 打开失败的原因;非空时这个标签只读,不允许保存。
  final String? loadError;

  EditorTabState({
    required this.filePath,
    required String initialContent,
    this.diagnostics = const [],
    this.activeSymbol,
    this.loadError,
  })  : fileName = filePath.split('/').last,
        controller = CodeEditorController(initialText: initialContent),
        verticalScroll = ScrollController(),
        horizontalScroll = ScrollController();

  bool get isDirty => controller.isDirty;

  void dispose() {
    controller.dispose();
    verticalScroll.dispose();
    horizontalScroll.dispose();
  }
}

/// Split direction for multi-pane editor workspace (Phase 8.3).
enum SplitDirection {
  none,
  horizontal, // Left & Right columns
  vertical,   // Top & Bottom rows
}

/// Manages multiple tabs, independent viewports, split panes, and synchronization with Rust Core.
class EditorSessionManager extends ChangeNotifier {
  final ApiClient client;
  final Map<String, EditorTabState> _tabs = {};
  final List<String> _tabOrder = [];
  String? _activePath;
  String? _secondaryActivePath;
  SplitDirection _splitDirection = SplitDirection.none;

  EditorSessionManager({required this.client}) {
    _diagSub = client.lspDiagnostics.listen(_onDiagnostics);
  }

  StreamSubscription<LspDiagnosticsEvent>? _diagSub;
  final Map<String, Timer> _didChangeTimers = {};

  /// 诊断来得比标签页早(打开文件后服务器很快推送)时先存在这里,建标签时取用。
  final Map<String, List<EditorDiagnostic>> _pendingDiagnostics = {};

  /// 诊断变了就加一:状态栏和大纲只订阅这个,不随每次按键的会话通知重建。
  final ValueNotifier<int> diagnosticsRevision = ValueNotifier(0);

  /// 最近一次收到诊断的文件(大纲据此决定要不要刷新)。
  String? lastDiagnosticsPath;

  void _onDiagnostics(LspDiagnosticsEvent event) {
    final diags = [for (final d in event.diagnostics) EditorDiagnostic.fromJson(d)];
    final tab = _tabs[event.path];
    if (tab == null) {
      _pendingDiagnostics[event.path] = diags;
      return;
    }
    tab.diagnostics = diags;
    lastDiagnosticsPath = event.path;
    diagnosticsRevision.value++;
    notifyListeners();
  }

  /// 编辑停顿 300ms 再把全文发给语言服务器,避免每个按键都触发一次分析。
  void _scheduleDidChange(String path, String text) {
    _didChangeTimers[path]?.cancel();
    _didChangeTimers[path] = Timer(const Duration(milliseconds: 300), () {
      _didChangeTimers.remove(path);
      client.lspDidChange(path, text);
    });
  }

  void _closeDocument(String path) {
    _didChangeTimers.remove(path)?.cancel();
    _pendingDiagnostics.remove(path);
    client.lspDidClose(path);
  }

  Map<String, EditorTabState> get tabs => Map.unmodifiable(_tabs);
  List<String> get openPaths => List.unmodifiable(_tabOrder);
  String? get activePath => _activePath;
  EditorTabState? get activeTab => _activePath != null ? _tabs[_activePath] : null;

  SplitDirection get splitDirection => _splitDirection;
  String? get secondaryActivePath => _secondaryActivePath;
  EditorTabState? get secondaryTab => _secondaryActivePath != null ? _tabs[_secondaryActivePath] : null;

  bool isTabDirty(String path) => _tabs[path]?.isDirty ?? false;

  /// Reorders tabs in the tab strip (Phase 8.3).
  void reorderTabs(int oldIndex, int newIndex) {
    if (oldIndex < 0 || oldIndex >= _tabOrder.length) return;
    if (oldIndex < newIndex) {
      newIndex -= 1;
    }
    if (newIndex < 0) newIndex = 0;
    if (newIndex >= _tabOrder.length) newIndex = _tabOrder.length - 1;
    final item = _tabOrder.removeAt(oldIndex);
    _tabOrder.insert(newIndex, item);
    notifyListeners();
  }

  /// Activates or toggles split pane mode (horizontal or vertical).
  void splitPane(SplitDirection direction, [String? path]) {
    _splitDirection = direction;
    if (direction == SplitDirection.none) {
      _secondaryActivePath = null;
    } else {
      if (path != null && _tabs.containsKey(path)) {
        _secondaryActivePath = path;
      } else {
        final other = _tabOrder.firstWhere((p) => p != _activePath, orElse: () => _activePath ?? '');
        _secondaryActivePath = other.isNotEmpty ? other : null;
      }
    }
    notifyListeners();
  }

  /// Selects an open tab for the secondary split pane.
  void selectSecondaryTab(String path) {
    if (_tabs.containsKey(path) && _secondaryActivePath != path) {
      _secondaryActivePath = path;
      notifyListeners();
    }
  }

  /// Closes split mode, returning to single-pane layout.
  void closeSplit() {
    _splitDirection = SplitDirection.none;
    _secondaryActivePath = null;
    notifyListeners();
  }

  /// Opens a tab or switches to it if already open.
  Future<EditorTabState> openFile(String path, {String? defaultContent}) async {
    if (!_tabOrder.contains(path)) {
      _tabOrder.add(path);
    }

    if (_tabs.containsKey(path)) {
      _activePath = path;
      notifyListeners();
      return _tabs[path]!;
    }

    final fileRes = await client.fetchFile(path);
    final loaded = fileRes['status'] != 'error';
    final rawContent = fileRes['content'] as String? ?? '';
    final content = loaded ? rawContent : (defaultContent ?? rawContent);
    // 诊断由语言服务器异步推送(见 _onDiagnostics),这里不等。
    final tab = EditorTabState(
      filePath: path,
      initialContent: content,
      diagnostics: _pendingDiagnostics.remove(path) ?? const [],
      // 没读到真实内容(二进制 / 无权限 / web 预览)时记下原因:保存会被拒绝,
      // 否则 ⌘S 会用占位文字覆盖掉磁盘上的真文件。
      loadError: loaded ? null : (fileRes['error'] as String? ?? 'unable to open file'),
    );
    if (loaded) client.lspDidOpen(path, content);

    // 文本就在 controller 里(Dart 是唯一的数据源),这里只需通知 LSP 和界面。
    tab.controller.onTextChanged = (newText) {
      if (tab.loadError == null) _scheduleDidChange(path, newText);
      notifyListeners();
    };

    tab.controller.onDirtyChanged = (_) {
      notifyListeners();
    };

    _tabs[path] = tab;
    _activePath = path;
    notifyListeners();
    return tab;
  }

  /// Selects an already open tab.
  void selectTab(String path) {
    if (_tabs.containsKey(path) && _activePath != path) {
      _activePath = path;
      notifyListeners();
    }
  }

  /// Closes an open tab and activates a fallback if any remain.
  /// Returns false if the tab is dirty and force is false.
  bool closeTab(String path, {bool force = true}) {
    if (!_tabs.containsKey(path)) return true;
    if (!force && isTabDirty(path)) {
      return false;
    }

    final tab = _tabs.remove(path);
    _tabOrder.remove(path);
    _closeDocument(path);
    tab?.dispose();

    if (_activePath == path) {
      _activePath = _tabOrder.isNotEmpty ? _tabOrder.last : null;
    }
    if (_secondaryActivePath == path) {
      _secondaryActivePath = _tabOrder.isNotEmpty
          ? _tabOrder.firstWhere((p) => p != _activePath, orElse: () => _activePath ?? '')
          : null;
      if (_secondaryActivePath == null || _secondaryActivePath!.isEmpty) {
        _secondaryActivePath = null;
        _splitDirection = SplitDirection.none;
      }
    }
    notifyListeners();
    return true;
  }

  /// 丢弃全部标签(切换/关闭项目)。未保存的修改一并丢弃,调用方先确认。
  void closeAll() {
    for (final path in _tabs.keys) {
      _closeDocument(path);
    }
    for (final tab in _tabs.values) {
      tab.dispose();
    }
    _tabs.clear();
    _tabOrder.clear();
    _activePath = null;
    _secondaryActivePath = null;
    _splitDirection = SplitDirection.none;
    notifyListeners();
  }

  bool get hasDirtyTabs => _tabs.values.any((t) => t.isDirty);

  /// 把当前标签的文本写回磁盘。打开失败的标签拒绝保存(见 [EditorTabState.loadError])。
  Future<bool> saveActiveFile() async {
    final active = activeTab;
    if (active == null || active.loadError != null) return false;

    final text = active.controller.text;
    final res = await client.saveFile(active.filePath, text);
    if (res['status'] == 'ok') {
      // 保存期间可能又敲了字:只有磁盘内容仍等于当前文本时才算"未修改"。
      if (active.controller.text == text) active.controller.markSaved();
      notifyListeners();
      return true;
    }
    return false;
  }

  /// 撤销 / 重做都在 controller 里完成(Dart 撤销历史)。
  Future<void> undoActive() async {
    if (activeTab?.controller.undo() ?? false) notifyListeners();
  }

  Future<void> redoActive() async {
    if (activeTab?.controller.redo() ?? false) notifyListeners();
  }

  @override
  void dispose() {
    _diagSub?.cancel();
    for (final t in _didChangeTimers.values) {
      t.cancel();
    }
    diagnosticsRevision.dispose();
    for (final tab in _tabs.values) {
      tab.dispose();
    }
    _tabs.clear();
    _tabOrder.clear();
    super.dispose();
  }
}
