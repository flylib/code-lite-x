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

/// Manages multiple tabs, independent viewports, and bidirectional synchronization with Rust Core.
class EditorSessionManager extends ChangeNotifier {
  final ApiClient client;
  final Map<String, EditorTabState> _tabs = {};
  String? _activePath;

  EditorSessionManager({required this.client});

  Map<String, EditorTabState> get tabs => Map.unmodifiable(_tabs);
  List<String> get openPaths => _tabs.keys.toList();
  String? get activePath => _activePath;
  EditorTabState? get activeTab => _activePath != null ? _tabs[_activePath] : null;

  /// Opens a tab or switches to it if already open.
  Future<EditorTabState> openFile(String path, {String? defaultContent}) async {
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
  void closeTab(String path) {
    if (!_tabs.containsKey(path)) return;

    final tab = _tabs.remove(path);
    tab?.dispose();

    if (_activePath == path) {
      _activePath = _tabs.isNotEmpty ? _tabs.keys.last : null;
    }
    notifyListeners();
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
    super.dispose();
  }
}
