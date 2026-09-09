import 'package:flutter/material.dart';
import '../../core/client/api_client.dart';
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

  EditorTabState({
    required this.filePath,
    required String initialContent,
    this.diagnostics = const [],
    this.activeSymbol,
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

  EditorSessionManager({required this.client});

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

    // Fetch file from Rust Core or fallback
    final fileRes = await client.fetchFile(path);
    final rawContent = fileRes['content'] as String?;
    final isFallback = rawContent == null || rawContent.startsWith('// CodeLiteX:');
    final content = (!isFallback ? rawContent : (defaultContent ?? rawContent ?? ''));
    final lang = path.endsWith('.dart') ? 'dart' : 'rust';
    final rawDiags = await client.lspDidOpen(path, lang, content);
    final diags = rawDiags.map((d) => EditorDiagnostic.fromJson(d as Map<String, dynamic>)).toList();

    final tab = EditorTabState(
      filePath: path,
      initialContent: content,
      diagnostics: diags,
    );

    // Wire controller callbacks to client & UI
    tab.controller.onTextChanged = (newText) {
      client.editFile(path, {
        'type': 'replace_all',
        'text': newText,
      });
      notifyListeners();
    };

    tab.controller.onDirtyChanged = (_) {
      notifyListeners();
    };

    tab.controller.onCursorChanged = (pos) {
      client.setFileCursor(path, pos.line, pos.col);
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

  /// Saves the active file to disk via Rust Core FFI.
  Future<bool> saveActiveFile() async {
    final active = activeTab;
    if (active == null) return false;

    final res = await client.saveFile(active.filePath);
    if (res['status'] == 'ok') {
      active.controller.markSaved();
      notifyListeners();
      return true;
    }
    return false;
  }

  /// Performs undo on the active tab via Rust Core.
  Future<void> undoActive() async {
    final active = activeTab;
    if (active == null) return;

    final res = await client.undo(active.filePath);
    if (res.isNotEmpty && res['status'] == 'ok') {
      final newContent = res['content'] as String?;
      if (newContent != null) {
        active.controller.setText(newContent, markDirty: (res['is_dirty'] as bool?) ?? false);
      }
      active.controller.setHistoryStatus(
        canUndo: (res['can_undo'] as bool?) ?? false,
        canRedo: (res['can_redo'] as bool?) ?? false,
        isDirty: res['is_dirty'] as bool?,
      );
      notifyListeners();
    }
  }

  /// Performs redo on the active tab via Rust Core.
  Future<void> redoActive() async {
    final active = activeTab;
    if (active == null) return;

    final res = await client.redo(active.filePath);
    if (res.isNotEmpty && res['status'] == 'ok') {
      final newContent = res['content'] as String?;
      if (newContent != null) {
        active.controller.setText(newContent, markDirty: (res['is_dirty'] as bool?) ?? true);
      }
      active.controller.setHistoryStatus(
        canUndo: (res['can_undo'] as bool?) ?? false,
        canRedo: (res['can_redo'] as bool?) ?? false,
        isDirty: res['is_dirty'] as bool?,
      );
      notifyListeners();
    }
  }

  @override
  void dispose() {
    for (final tab in _tabs.values) {
      tab.dispose();
    }
    _tabs.clear();
    _tabOrder.clear();
    super.dispose();
  }
}
