import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'core/client/api_client.dart';
import 'core/theme/intellij_theme.dart';
import 'features/activity_stripe/activity_stripe_widget.dart';
import 'features/ai_assistant/ai_assistant_panel.dart';
import 'features/bottom_tools/bottom_tools_widget.dart';
import 'features/editor/editor_session_manager.dart';
import 'features/editor/editor_view_widget.dart';
import 'features/editor/lsp_overlay.dart';
import 'features/project_explorer/project_explorer_widget.dart';
import 'features/project_explorer/structure_widget.dart';
import 'features/search/global_search_modal.dart';
import 'features/title_bar/title_bar_widget.dart';

class CodeLiteApp extends StatefulWidget {
  const CodeLiteApp({super.key});

  @override
  State<CodeLiteApp> createState() => _CodeLiteAppState();
}

class _CodeLiteAppState extends State<CodeLiteApp> {
  final ApiClient _client = ApiClient();
  late final EditorSessionManager _sessionManager;

  StripeTool _activeTool = StripeTool.project;
  BottomToolTab _bottomTab = BottomToolTab.git;
  bool _isAiOpen = true;

  String _activeFile = 'crates/code-lite-storage/src/op_store.rs';
  final List<String> _openTabs = [
    'crates/code-lite-core/src/buffer.rs',
    'crates/code-lite-storage/src/op_store.rs',
    'crates/code-lite-storage/src/graph_store.rs',
  ];

  Map<String, dynamic> _treeData = {};
  List<dynamic> _outlineData = [];
  String? _activeSymbol;
  List<EditorDiagnostic> _diagnostics = [];
  String _codeContent = '''/// Reverts a previously applied operation, restoring the target file on disk to before_content.
pub fn revert(&self, op_id: i64) -> Result<(), StorageError> {
    let op = self.get(op_id)?;
    if op.status == OpStatus::Reverted {
        return Ok(());
    }
    let path = Path::new(&op.file_path);
    match op.op_type {
        OpType::Modify => {
            if let Some(before) = &op.before_content {
                fs::write(path, before)?;
            }
        }
        OpType::Create => {
            if path.exists() {
                fs::remove_file(path)?;
            }
        }
        OpType::Delete => {
            if let Some(before) = &op.before_content {
                fs::write(path, before)?;
            }
        }
    }
    self.db.with_conn(|conn| {
        conn.execute("UPDATE operations SET status = ?1 WHERE id = ?2", params![OpStatus::Reverted.as_str(), op_id])?;
        Ok(())
    })
}''';

  @override
  void initState() {
    super.initState();
    _sessionManager = EditorSessionManager(client: _client);
    _sessionManager.addListener(() {
      if (mounted) setState(() {});
    });
    _loadInitialData();
  }

  @override
  void dispose() {
    _sessionManager.dispose();
    super.dispose();
  }

  Future<void> _loadInitialData() async {
    final tree = await _client.fetchWorkspaceTree();
    setState(() => _treeData = tree);
    _openFile(_activeFile);
  }

  Future<void> _openFile(String path) async {
    final tab = await _sessionManager.openFile(path, defaultContent: _codeContent);
    final outline = await _client.queryOutline(path);

    setState(() {
      _activeFile = path;
      _codeContent = tab.controller.text;
      if (!_openTabs.contains(path)) {
        _openTabs.add(path);
      }
      _outlineData = outline;
      _activeSymbol = outline.isNotEmpty ? (outline.first['name'] as String?) : null;
      _diagnostics = tab.diagnostics;
    });
  }

  Future<void> _handleUndo() async {
    await _sessionManager.undoActive();
    if (_sessionManager.activeTab != null) {
      setState(() => _codeContent = _sessionManager.activeTab!.controller.text);
    }
  }

  Future<void> _handleRedo() async {
    await _sessionManager.redoActive();
    if (_sessionManager.activeTab != null) {
      setState(() => _codeContent = _sessionManager.activeTab!.controller.text);
    }
  }

  Future<void> _handleRevertTask() async {
    await _client.revertTask('task-104');
    _openFile(_activeFile);
  }

  void _openGlobalSearch(BuildContext context) {
    GlobalSearchModal.show(
      context,
      client: _client,
      onNavigate: (path, line) {
        _openFile(path);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'CodeLiteX',
      debugShowCheckedModeBanner: false,
      theme: IntelliJTheme.darkTheme,
      home: Builder(
        builder: (context) => CallbackShortcuts(
          bindings: <ShortcutActivator, VoidCallback>{
            const SingleActivator(LogicalKeyboardKey.keyF, meta: true, shift: true): () => _openGlobalSearch(context),
            const SingleActivator(LogicalKeyboardKey.keyF, control: true, shift: true): () => _openGlobalSearch(context),
          },
          child: Focus(
            autofocus: true,
            child: Scaffold(
              backgroundColor: IntelliJTheme.editorBg,
              body: Column(
                children: [
                  // 1. Top Title Bar
                  TitleBarWidget(
                    activeFile: _activeFile,
                    onToggleAi: () => setState(() => _isAiOpen = !_isAiOpen),
                    onUndo: _handleUndo,
                    onRedo: _handleRedo,
                    onSearch: () => _openGlobalSearch(context),
                  ),

                  // 2. Main IDE Workspace Body
                  Expanded(
                    child: Row(
                      children: [
                        // Left Activity Stripe (Icons)
                        ActivityStripeWidget(
                          activeTool: _activeTool,
                          onSelectTool: (tool) {
                            setState(() {
                              if (tool == StripeTool.sqlite) {
                                _bottomTab = BottomToolTab.sqlite;
                              } else if (tool == StripeTool.git) {
                                _bottomTab = BottomToolTab.git;
                              } else if (tool == StripeTool.codegraph) {
                                _bottomTab = BottomToolTab.codegraph;
                              } else if (tool == StripeTool.terminal) {
                                _bottomTab = BottomToolTab.terminal;
                              } else {
                                _activeTool = tool;
                              }
                            });
                          },
                        ),

                        // Left Tool Window (Project Tree or Structure)
                        if (_activeTool == StripeTool.project)
                          ProjectExplorerWidget(
                            treeData: _treeData,
                            activeFilePath: _activeFile,
                            onSelectFile: _openFile,
                          ),

                        if (_activeTool == StripeTool.structure)
                          SizedBox(
                            width: 250,
                            child: StructureWidget(
                              activeFile: _activeFile,
                              outline: _outlineData,
                              onSelectSymbol: (sym) {
                                setState(() {
                                  _activeSymbol = sym['name'] as String?;
                                });
                              },
                            ),
                          ),

                        // Center Area (Editor + Bottom Tool Windows)
                        Expanded(
                          child: Column(
                            children: [
                              // Editor View
                              Expanded(
                                child: EditorViewWidget(
                                  openTabs: _openTabs,
                                  activeFile: _activeFile,
                                  codeContent: _sessionManager.activeTab?.controller.text ?? _codeContent,
                                  activeSymbol: _activeSymbol,
                                  diagnostics: _sessionManager.activeTab?.diagnostics ?? _diagnostics,
                                  controller: _sessionManager.activeTab?.controller,
                                  verticalScroll: _sessionManager.activeTab?.verticalScroll,
                                  horizontalScroll: _sessionManager.activeTab?.horizontalScroll,
                                  onSelectTab: _openFile,
                                  onCloseTab: (path) {
                                    _sessionManager.closeTab(path);
                                    setState(() {
                                      _openTabs.remove(path);
                                      if (_openTabs.isNotEmpty) {
                                        _activeFile = _openTabs.last;
                                        _openFile(_activeFile);
                                      }
                                    });
                                  },
                                  onCodeChanged: (newCode) => _codeContent = newCode,
                                  onSave: () => _sessionManager.saveActiveFile(),
                                  onUndo: _handleUndo,
                                  onRedo: _handleRedo,
                                  isTabDirty: (p) => _sessionManager.tabs[p]?.isDirty ?? false,
                                ),
                              ),

                              // Bottom Tool Window
                              BottomToolsWidget(
                                activeTab: _bottomTab,
                                onSelectTab: (tab) => setState(() => _bottomTab = tab),
                                onRevertTask: _handleRevertTask,
                                client: _client,
                              ),
                            ],
                          ),
                        ),

                        // Right Docked AI Assistant
                        if (_isAiOpen)
                          AiAssistantPanel(
                            activeFile: _activeFile,
                            onClose: () => setState(() => _isAiOpen = false),
                          ),
                      ],
                    ),
                  ),

                  // 3. Status Bar
                  _buildStatusBar(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    final errorCount = _diagnostics.where((d) => d.isError).length;
    final warningCount = _diagnostics.where((d) => d.isWarning).length;

    return Container(
      height: 22,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: const BoxDecoration(
        color: IntelliJTheme.headerBg,
        border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              const Icon(Icons.circle, size: 6, color: IntelliJTheme.gitGreen),
              const SizedBox(width: 4),
              const Text('Flutter Engine: Impeller (120 FPS)', style: TextStyle(color: IntelliJTheme.gitGreen, fontSize: 10)),
              const SizedBox(width: 8),
              const Text('•', style: TextStyle(color: IntelliJTheme.textMuted)),
              const SizedBox(width: 8),
              const Text('Rust Core: Online', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
              const SizedBox(width: 8),
              const Text('•', style: TextStyle(color: IntelliJTheme.textMuted)),
              const SizedBox(width: 8),
              if (errorCount > 0) ...[
                const Icon(Icons.error, size: 12, color: Color(0xFFF97A7A)),
                const SizedBox(width: 3),
                Text('$errorCount errors', style: const TextStyle(color: Color(0xFFF97A7A), fontSize: 10, fontWeight: FontWeight.bold)),
                const SizedBox(width: 6),
              ] else if (warningCount > 0) ...[
                const Icon(Icons.warning_amber_rounded, size: 12, color: Color(0xFFE5C07B)),
                const SizedBox(width: 3),
                Text('$warningCount warnings', style: const TextStyle(color: Color(0xFFE5C07B), fontSize: 10)),
                const SizedBox(width: 6),
              ] else ...[
                const Icon(Icons.check_circle_outline, size: 11, color: IntelliJTheme.gitGreen),
                const SizedBox(width: 3),
                const Text('LSP: Ready', style: TextStyle(color: IntelliJTheme.gitGreen, fontSize: 10)),
                const SizedBox(width: 6),
              ],
              const Text('•', style: TextStyle(color: IntelliJTheme.textMuted)),
              const SizedBox(width: 8),
              const Text('SQLite WAL: Active', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
            ],
          ),
          const Row(
            children: [
              Text('UTF-8', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
              SizedBox(width: 8),
              Text('•', style: TextStyle(color: IntelliJTheme.textMuted)),
              SizedBox(width: 8),
              Text('4 spaces', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
            ],
          ),
        ],
      ),
    );
  }
}
