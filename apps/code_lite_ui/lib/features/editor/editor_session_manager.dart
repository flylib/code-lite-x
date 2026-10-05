import 'dart:async';

import 'package:flutter/material.dart';
import '../../core/client/api_client.dart';
import '../../core/lsp/lsp.dart';
import 'code_editor_controller.dart';
import 'editor_appearance.dart';
import 'editor_view_widget.dart' show diffTabPrefix, isSpecialTabId;
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

  /// 防抖期间累积的改动(发给语言服务器时一次发出)。
  final Map<String, List<LspTextChange>> _pendingChanges = {};

  /// 这些文件下次要发全文:整篇重新载入过,或改动太多(多过全文就不划算了)。
  final Set<String> _needFullSync = {};
  static const int _maxIncrementalChanges = 200;

  /// 自动保存(IntelliJ 风格):停止输入 [autosaveDelay] 后写回磁盘,无需 ⌘S;
  /// 切换标签、关闭标签、应用失去焦点时立即写。写盘后 Commit 窗的改动列表随之刷新。
  bool autosave = true;
  Duration autosaveDelay = defaultAutosaveDelay;
  static const Duration defaultAutosaveDelay = Duration(milliseconds: 600);
  final Map<String, Timer> _saveTimers = {};

  /// 诊断来得比标签页早(打开文件后服务器很快推送)时先存在这里,建标签时取用。
  final Map<String, List<EditorDiagnostic>> _pendingDiagnostics = {};

  /// 编辑器外观(行号 / 缩进参考线 / 面包屑 / blame 显示项),所有标签与分屏共用。
  final EditorAppearance appearance = EditorAppearance();

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

  /// 编辑停顿 300ms 再同步给语言服务器,避免每个按键都触发一次分析。
  /// 平时只发这段时间的改动(增量);整篇重新载入过、改动太多或服务端还没有这份文档时才发全文。
  void _scheduleDidChange(String path) {
    _didChangeTimers[path]?.cancel();
    _didChangeTimers[path] = Timer(const Duration(milliseconds: 300), () async {
      _didChangeTimers.remove(path);
      final tab = _tabs[path];
      final changes = _pendingChanges.remove(path) ?? const <LspTextChange>[];
      final full = _needFullSync.remove(path);
      if (tab == null) return;
      if (!full && await client.lspDidChangeIncremental(path, changes)) return;
      client.lspDidChange(path, tab.controller.text);
    });
  }

  void _queueChange(String path, EditorTextChange c) {
    if (c.reset) {
      _pendingChanges.remove(path);
      _needFullSync.add(path);
      return;
    }
    if (_needFullSync.contains(path)) return;
    final list = _pendingChanges.putIfAbsent(path, () => []);
    list.add(LspTextChange(c.start.line, c.start.col, c.end.line, c.end.col, c.text));
    if (list.length > _maxIncrementalChanges) {
      _pendingChanges.remove(path);
      _needFullSync.add(path);
    }
  }

  void _scheduleSave(String path) {
    _saveTimers[path]?.cancel();
    _saveTimers[path] = Timer(autosaveDelay, () {
      _saveTimers.remove(path);
      saveFile(path);
    });
  }

  /// 立即保存所有有改动的标签(切换标签 / 应用失去焦点 / 切换项目前调用)。
  Future<void> saveAll() async {
    for (final path in _tabs.keys.toList()) {
      if (_tabs[path]?.isDirty ?? false) await saveFile(path);
    }
  }

  void _closeDocument(String path) {
    _saveTimers.remove(path)?.cancel();
    _didChangeTimers.remove(path)?.cancel();
    _pendingChanges.remove(path);
    _needFullSync.remove(path);
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
    if (autosave && _activePath != path) unawaited(saveAll());
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
    // 按键不通知会话层的监听者(否则整个编辑区每敲一个字都重建一遍):
    // 编辑面板自己订阅 controller;标签上的「已修改」圆点靠下面的 onDirtyChanged。
    tab.controller.addChangeListener((c) {
      if (tab.loadError == null) _queueChange(path, c);
    });
    tab.controller.onTextChanged = () {
      if (tab.loadError == null) {
        _scheduleDidChange(path);
        if (autosave) _scheduleSave(path);
      }
    };

    tab.controller.onDirtyChanged = (_) {
      notifyListeners();
    };

    _tabs[path] = tab;
    _activePath = path;
    notifyListeners();
    return tab;
  }

  /// Rollback 等在磁盘上改了文件之后:已打开的这些标签按磁盘内容重新载入(撤销历史一并清空)。
  Future<void> reloadFromDisk(List<String> paths) async {
    for (final path in paths) {
      final tab = _tabs[path];
      if (tab == null) continue;
      final res = await client.fetchFile(path);
      if (res['status'] == 'error') continue; // 文件已被删除:保留编辑器内容,交给用户处理
      tab.controller.setText(res['content'] as String? ?? '');
      // 直接整篇同步,不必再等防抖
      _pendingChanges.remove(path);
      _needFullSync.remove(path);
      client.lspDidChange(path, tab.controller.text);
    }
    notifyListeners();
  }

  /// 打开(或切到)一个「Commit: 文件名」差异标签。它没有文本缓冲,只占标签栏的一个位置,
  /// 内容由差异视图自己从 Git 读取。[repoPath] 相对仓库根。
  void openDiff(String repoPath) {
    final id = '$diffTabPrefix$repoPath';
    if (!_tabOrder.contains(id)) _tabOrder.add(id);
    _activePath = id;
    notifyListeners();
  }

  bool isDiffTab(String? id) => id != null && id.startsWith(diffTabPrefix);

  /// 不对应文件的标签(Commit 差异、PR 差异、PR Timeline)。
  bool isSpecialTab(String? id) => id != null && isSpecialTabId(id);

  /// 打开(或切到)一个特殊标签,见 [isSpecialTab]。
  void openSpecial(String id) {
    if (!_tabOrder.contains(id)) _tabOrder.add(id);
    _activePath = id;
    notifyListeners();
  }

  /// Selects an already open tab.
  void selectTab(String path) {
    if (autosave && _activePath != path) unawaited(saveAll());
    if (isSpecialTab(path) && _tabOrder.contains(path) && _activePath != path) {
      _activePath = path;
      notifyListeners();
      return;
    }
    if (_tabs.containsKey(path) && _activePath != path) {
      _activePath = path;
      notifyListeners();
    }
  }

  /// Closes an open tab and activates a fallback if any remain.
  /// Returns false if the tab is dirty and force is false.
  bool closeTab(String path, {bool force = true}) {
    if (isSpecialTab(path)) {
      _tabOrder.remove(path);
      if (_activePath == path) _activePath = _tabOrder.isNotEmpty ? _tabOrder.last : null;
      notifyListeners();
      return true;
    }
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
    for (final t in _saveTimers.values) {
      t.cancel();
    }
    _saveTimers.clear();
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

  /// 把当前标签的文本写回磁盘。
  Future<bool> saveActiveFile() async {
    final path = _activePath;
    if (path == null) return false;
    return saveFile(path);
  }

  /// 把 [path] 标签的文本写回磁盘。打开失败的标签拒绝保存(见 [EditorTabState.loadError])。
  Future<bool> saveFile(String path) async {
    _saveTimers.remove(path)?.cancel();
    final tab = _tabs[path];
    if (tab == null || tab.loadError != null) return false;
    if (!tab.isDirty) return true;

    final text = tab.controller.text;
    final res = await client.saveFile(tab.filePath, text);
    if (res['status'] == 'ok') {
      // 保存期间可能又敲了字:只有磁盘内容仍等于当前文本时才算"未修改"。
      if (_tabs[path] == tab && tab.controller.text == text) tab.controller.markSaved();
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
    for (final t in [..._didChangeTimers.values, ..._saveTimers.values]) {
      t.cancel();
    }
    diagnosticsRevision.dispose();
    appearance.dispose();
    for (final tab in _tabs.values) {
      tab.dispose();
    }
    _tabs.clear();
    _tabOrder.clear();
    super.dispose();
  }
}
