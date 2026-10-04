import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:isolate';

// Native function typedefs
typedef _InitC = Pointer<Void> Function(Pointer<Char> path);
typedef _InitDart = Pointer<Void> Function(Pointer<Char> path);

typedef _DestroyC = Void Function(Pointer<Void> ctx);
typedef _DestroyDart = void Function(Pointer<Void> ctx);

typedef _VersionC = Pointer<Char> Function();
typedef _VersionDart = Pointer<Char> Function();

typedef _StringAllocC = Pointer<Char> Function(Size len);
typedef _StringAllocDart = Pointer<Char> Function(int len);

typedef _StringFreeC = Void Function(Pointer<Char> ptr);
typedef _StringFreeDart = void Function(Pointer<Char> ptr);

typedef _BufferFreeC = Void Function(Pointer<Char> ptr, Size len);
typedef _BufferFreeDart = void Function(Pointer<Char> ptr, int len);

typedef _WorkspaceScanC = Pointer<Char> Function(Pointer<Void> ctx, Size maxDepth);
typedef _WorkspaceScanDart = Pointer<Char> Function(Pointer<Void> ctx, int maxDepth);

typedef _FileOpenC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> path);
typedef _FileOpenDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> path);

typedef _FileEditC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> path, Pointer<Char> json);
typedef _FileEditDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> path, Pointer<Char> json);

typedef _UndoRedoC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> path);
typedef _UndoRedoDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> path);

typedef _FileSaveC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> path);
typedef _FileSaveDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> path);

typedef _FileCursorSetC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> path, Uint32 line, Uint32 col, Bool select);
typedef _FileCursorSetDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> path, int line, int col, bool select);













typedef _GraphSymbolsC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> query);
typedef _GraphSymbolsDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> query);

typedef _GraphFileC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> relPath);
typedef _GraphFileDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> relPath);

typedef _GraphQueryC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> query);
typedef _GraphQueryDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> query);

typedef _LspInitServerC = Bool Function(Pointer<Void> ctx, Pointer<Char> cmd, Pointer<Char> argsJson);
typedef _LspInitServerDart = bool Function(Pointer<Void> ctx, Pointer<Char> cmd, Pointer<Char> argsJson);

typedef _LspDidOpenC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, Pointer<Char> language, Pointer<Char> content);
typedef _LspDidOpenDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, Pointer<Char> language, Pointer<Char> content);

typedef _LspDidChangeC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, Int32 version, Pointer<Char> content);
typedef _LspDidChangeDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, int version, Pointer<Char> content);

typedef _LspGetDiagsC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath);
typedef _LspGetDiagsDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath);

typedef _LspPosQueryC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, Uint32 line, Uint32 col);
typedef _LspPosQueryDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, int line, int col);

typedef _LspFindRefsC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, Uint32 line, Uint32 col, Bool includeDecl);
typedef _LspFindRefsDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, int line, int col, bool includeDecl);

typedef _LspRenameC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, Uint32 line, Uint32 col, Pointer<Char> newName);
typedef _LspRenameDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, int line, int col, Pointer<Char> newName);

typedef _GetViewportTokensC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, Uint32 startLine, Uint32 endLine);
typedef _GetViewportTokensDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, int startLine, int endLine);

typedef _SearchWorkspaceC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> query, Pointer<Char> optionsJson);
typedef _SearchWorkspaceDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> query, Pointer<Char> optionsJson);

typedef _ReplaceWorkspaceC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> query, Pointer<Char> replacement, Pointer<Char> optionsJson);
typedef _ReplaceWorkspaceDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> query, Pointer<Char> replacement, Pointer<Char> optionsJson);

typedef _TerminalExecC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> cmd, Pointer<Char> argsJson);
typedef _TerminalExecDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> cmd, Pointer<Char> argsJson);
typedef _PtyOpenC = Pointer<Char> Function(Pointer<Void> ctx, Uint16 rows, Uint16 cols);
typedef _PtyOpenDart = Pointer<Char> Function(Pointer<Void> ctx, int rows, int cols);
typedef _PtyWriteC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, Pointer<Char> data);
typedef _PtyWriteDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, Pointer<Char> data);
typedef _PtyResizeC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, Uint16 rows, Uint16 cols);
typedef _PtyResizeDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, int rows, int cols);
typedef _PtySnapshotC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, Int64 sinceSeq, Uint32 scrollback);
typedef _PtySnapshotDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, int sinceSeq, int scrollback);
typedef _PtyCloseC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id);
typedef _PtyCloseDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id);
typedef _GitCallC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> method, Pointer<Char> paramsJson);
typedef _GitCallDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> method, Pointer<Char> paramsJson);




typedef _GitStatusC = Pointer<Char> Function(Pointer<Void> ctx);
typedef _GitStatusDart = Pointer<Char> Function(Pointer<Void> ctx);

typedef _GitDiffC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, Bool staged);
typedef _GitDiffDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, bool staged);

typedef _GitStageC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath);
typedef _GitStageDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath);

typedef _GitCommitC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> message);
typedef _GitCommitDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> message);

typedef _GitFileHunksC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath);
typedef _GitFileHunksDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath);

typedef _GitRevertFileC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath);
typedef _GitRevertFileDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath);

typedef _JsonRpcCallC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> requestJson);
typedef _JsonRpcCallDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> requestJson);







typedef _UpdaterCheckC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> currentVersion, Pointer<Char> manifestJson, Pointer<Char> platform);
typedef _UpdaterCheckDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> currentVersion, Pointer<Char> manifestJson, Pointer<Char> platform);

typedef _UpdaterStageC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> stagingDir, Pointer<Char> fileName, Pointer<Char> content, Pointer<Char> expectedSha256);
typedef _UpdaterStageDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> stagingDir, Pointer<Char> fileName, Pointer<Char> content, Pointer<Char> expectedSha256);

typedef _UpdaterApplyC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> stagingDir, Pointer<Char> targetDir, Pointer<Char> filesJson, Pointer<Char> platform);
typedef _UpdaterApplyDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> stagingDir, Pointer<Char> targetDir, Pointer<Char> filesJson, Pointer<Char> platform);






/// Dart FFI bindings to Rust Core dynamic library (`libcodelite.dylib`).
class CodeLiteBindings {
  static final CodeLiteBindings instance = CodeLiteBindings._();
  CodeLiteBindings._();

  DynamicLibrary? _dylib;
  Pointer<Void>? _ctx;
  bool _initialized = false;
  bool _symbolsBound = false;

  /// 打开动态库时用的路径;后台 isolate 要按同一路径再打开一次。
  String? _libraryPath;

  /// 正在后台 isolate 里执行、还持有 `_ctx` 的调用数。
  int _inFlight = 0;
  Completer<void>? _idle;

  bool get isAvailable => _dylib != null && _ctx != null && _ctx!.address != 0;

  // Function pointers
  late final _InitDart _init;
  late final _DestroyDart _destroy;
  late final _VersionDart _version;
  late final _StringAllocDart _stringAlloc;
  late final _StringFreeDart _stringFree;
  late final _BufferFreeDart _bufferFree;
  late final _WorkspaceScanDart _workspaceScan;
  late final _FileOpenDart _fileOpen;
  late final _FileEditDart _fileEdit;
  late final _UndoRedoDart _undo;
  late final _UndoRedoDart _redo;
  late final _FileSaveDart _fileSave;
  late final _FileCursorSetDart _fileCursorSet;
  late final _GraphSymbolsDart _graphSymbols;
  late final _GraphFileDart _graphIndexFile;
  late final _GraphFileDart _graphQueryOutline;
  late final _GraphQueryDart _graphFindDefinition;
  late final _GraphQueryDart _graphFindReferences;
  late final _GraphQueryDart _graphGetContext;
  late final _GraphQueryDart _graphFindCallers;
  late final _GraphQueryDart _graphFindCallees;
  late final _LspInitServerDart _lspInitServer;
  late final _LspDidOpenDart _lspDidOpen;
  late final _LspDidChangeDart _lspDidChange;
  late final _LspGetDiagsDart _lspGetDiagnostics;
  late final _LspPosQueryDart _lspGotoDefinition;
  late final _LspFindRefsDart _lspFindReferences;
  late final _LspPosQueryDart _lspHover;
  late final _LspPosQueryDart _lspCompletion;
  late final _LspRenameDart _lspRename;
  late final _GetViewportTokensDart _getViewportTokens;
  late final _SearchWorkspaceDart _searchWorkspace;
  late final _ReplaceWorkspaceDart _replaceWorkspace;
  late final _TerminalExecDart _terminalExec;
  late final _PtyOpenDart _ptyOpen;
  late final _PtyWriteDart _ptyWrite;
  late final _PtyResizeDart _ptyResize;
  late final _PtySnapshotDart _ptySnapshot;
  late final _PtyCloseDart _ptyClose;
  late final _GitCallDart _gitCall;
  late final _GitStatusDart _gitStatus;
  late final _GitDiffDart _gitDiff;
  late final _GitStageDart _gitStage;
  late final _GitStageDart _gitUnstage;
  late final _GitCommitDart _gitCommit;
  late final _GitFileHunksDart _gitFileHunks;
  late final _GitRevertFileDart _gitRevertFile;
  late final _JsonRpcCallDart _jsonRpcCall;
  late final _UpdaterCheckDart _updaterCheck;
  late final _UpdaterStageDart _updaterStage;
  late final _UpdaterApplyDart _updaterApply;

  Pointer<Void>? get contextPointer => _ctx;

  /// Loads the dynamic library and initializes Rust Core.
  bool initialize([String workspacePath = '.']) {
    if (_initialized) return isAvailable;

    try {
      // 库与符号只绑定一次:这些是 late final,二次赋值会抛 LateInitializationError。
      // reinitialize 走到这里时直接复用,只重建下面的 Rust 上下文。
      if (!_symbolsBound) {
        _dylib = _loadLibrary();
        if (_dylib == null) return false;
        _bindSymbols();
        _symbolsBound = true;
      }

      final pathPtr = _toCString(workspacePath);
      _ctx = _init(pathPtr.pointer);
      _freeAllocatedString(pathPtr);

      _initialized = _ctx != null && _ctx!.address != 0;
      return _initialized;
    } catch (e) {
      if (!_symbolsBound) _dylib = null;
      _ctx = null;
      _initialized = false;
      return false;
    }
  }

  void _bindSymbols() {
    _init = _dylib!.lookupFunction<_InitC, _InitDart>('codelite_init');
    _destroy = _dylib!.lookupFunction<_DestroyC, _DestroyDart>('codelite_destroy');
    _version = _dylib!.lookupFunction<_VersionC, _VersionDart>('codelite_version');
    _stringAlloc = _dylib!.lookupFunction<_StringAllocC, _StringAllocDart>('codelite_string_alloc');
    _stringFree = _dylib!.lookupFunction<_StringFreeC, _StringFreeDart>('codelite_string_free');
    _bufferFree = _dylib!.lookupFunction<_BufferFreeC, _BufferFreeDart>('codelite_buffer_free');
    _workspaceScan = _dylib!.lookupFunction<_WorkspaceScanC, _WorkspaceScanDart>('codelite_workspace_scan');
    _fileOpen = _dylib!.lookupFunction<_FileOpenC, _FileOpenDart>('codelite_file_open');
    _fileEdit = _dylib!.lookupFunction<_FileEditC, _FileEditDart>('codelite_file_edit');
    _undo = _dylib!.lookupFunction<_UndoRedoC, _UndoRedoDart>('codelite_undo');
    _redo = _dylib!.lookupFunction<_UndoRedoC, _UndoRedoDart>('codelite_redo');
    _fileSave = _dylib!.lookupFunction<_FileSaveC, _FileSaveDart>('codelite_file_save');
    _fileCursorSet = _dylib!.lookupFunction<_FileCursorSetC, _FileCursorSetDart>('codelite_file_cursor_set');
    _graphSymbols = _dylib!.lookupFunction<_GraphSymbolsC, _GraphSymbolsDart>('codelite_graph_symbols');
    _graphIndexFile = _dylib!.lookupFunction<_GraphFileC, _GraphFileDart>('codelite_graph_index_file');
    _graphQueryOutline = _dylib!.lookupFunction<_GraphFileC, _GraphFileDart>('codelite_graph_query_outline');
    _graphFindDefinition = _dylib!.lookupFunction<_GraphQueryC, _GraphQueryDart>('codelite_graph_find_definition');
    _graphFindReferences = _dylib!.lookupFunction<_GraphQueryC, _GraphQueryDart>('codelite_graph_find_references');
    _graphGetContext = _dylib!.lookupFunction<_GraphQueryC, _GraphQueryDart>('codelite_graph_get_context');
    _graphFindCallers = _dylib!.lookupFunction<_GraphQueryC, _GraphQueryDart>('codelite_graph_find_callers');
    _graphFindCallees = _dylib!.lookupFunction<_GraphQueryC, _GraphQueryDart>('codelite_graph_find_callees');
    _lspInitServer = _dylib!.lookupFunction<_LspInitServerC, _LspInitServerDart>('codelite_lsp_init_server');
    _lspDidOpen = _dylib!.lookupFunction<_LspDidOpenC, _LspDidOpenDart>('codelite_lsp_did_open');
    _lspDidChange = _dylib!.lookupFunction<_LspDidChangeC, _LspDidChangeDart>('codelite_lsp_did_change');
    _lspGetDiagnostics = _dylib!.lookupFunction<_LspGetDiagsC, _LspGetDiagsDart>('codelite_lsp_get_diagnostics');
    _lspGotoDefinition = _dylib!.lookupFunction<_LspPosQueryC, _LspPosQueryDart>('codelite_lsp_goto_definition');
    _lspFindReferences = _dylib!.lookupFunction<_LspFindRefsC, _LspFindRefsDart>('codelite_lsp_find_references');
    _lspHover = _dylib!.lookupFunction<_LspPosQueryC, _LspPosQueryDart>('codelite_lsp_hover');
    _lspCompletion = _dylib!.lookupFunction<_LspPosQueryC, _LspPosQueryDart>('codelite_lsp_completion');
    _lspRename = _dylib!.lookupFunction<_LspRenameC, _LspRenameDart>('codelite_lsp_rename');
    _getViewportTokens = _dylib!.lookupFunction<_GetViewportTokensC, _GetViewportTokensDart>('codelite_get_viewport_tokens');
    _searchWorkspace = _dylib!.lookupFunction<_SearchWorkspaceC, _SearchWorkspaceDart>('codelite_search_workspace');
    _replaceWorkspace = _dylib!.lookupFunction<_ReplaceWorkspaceC, _ReplaceWorkspaceDart>('codelite_replace_workspace');
    _terminalExec = _dylib!.lookupFunction<_TerminalExecC, _TerminalExecDart>('codelite_terminal_exec');
    _ptyOpen = _dylib!.lookupFunction<_PtyOpenC, _PtyOpenDart>('codelite_pty_open');
    _ptyWrite = _dylib!.lookupFunction<_PtyWriteC, _PtyWriteDart>('codelite_pty_write');
    _ptyResize = _dylib!.lookupFunction<_PtyResizeC, _PtyResizeDart>('codelite_pty_resize');
    _ptySnapshot = _dylib!.lookupFunction<_PtySnapshotC, _PtySnapshotDart>('codelite_pty_snapshot');
    _ptyClose = _dylib!.lookupFunction<_PtyCloseC, _PtyCloseDart>('codelite_pty_close');
    _gitCall = _dylib!.lookupFunction<_GitCallC, _GitCallDart>('codelite_git_call');
    _gitStatus = _dylib!.lookupFunction<_GitStatusC, _GitStatusDart>('codelite_git_status');
    _gitDiff = _dylib!.lookupFunction<_GitDiffC, _GitDiffDart>('codelite_git_diff');
    _gitStage = _dylib!.lookupFunction<_GitStageC, _GitStageDart>('codelite_git_stage');
    _gitUnstage = _dylib!.lookupFunction<_GitStageC, _GitStageDart>('codelite_git_unstage');
    _gitCommit = _dylib!.lookupFunction<_GitCommitC, _GitCommitDart>('codelite_git_commit');
    _gitFileHunks = _dylib!.lookupFunction<_GitFileHunksC, _GitFileHunksDart>('codelite_git_file_diff_hunks');
    _gitRevertFile = _dylib!.lookupFunction<_GitRevertFileC, _GitRevertFileDart>('codelite_git_revert_file');
    _jsonRpcCall = _dylib!.lookupFunction<_JsonRpcCallC, _JsonRpcCallDart>('codelite_jsonrpc_call');
    _updaterCheck = _dylib!.lookupFunction<_UpdaterCheckC, _UpdaterCheckDart>('codelite_updater_check');
    _updaterStage = _dylib!.lookupFunction<_UpdaterStageC, _UpdaterStageDart>('codelite_updater_stage');
    _updaterApply = _dylib!.lookupFunction<_UpdaterApplyC, _UpdaterApplyDart>('codelite_updater_apply');
  }

  /// 销毁当前上下文并以新的工作区根重新初始化(File → Open)。
  /// 动态库与函数指针沿用,只重建 Rust 侧的 CodeLiteContext。
  bool reinitialize(String workspacePath) {
    dispose();
    return initialize(workspacePath);
  }

  void dispose() {
    if (_ctx != null && _ctx!.address != 0) {
      _destroy(_ctx!);
      _ctx = null;
      _initialized = false;
    }
  }

  String getVersion() {
    if (!isAvailable) return 'offline';
    final ptr = _version();
    return _fromCString(ptr);
  }

  /// Dispatches a JSON-RPC 2.0 request via Rust C-ABI `codelite_jsonrpc_call`.
  String? jsonRpcCall(Pointer<Void> ctx, String requestJson) {
    if (!isAvailable && ctx.address == 0) return null;
    final reqPtr = _toCString(requestJson);
    try {
      final ptr = _jsonRpcCall(ctx, reqPtr.pointer);
      return _fromCString(ptr);
    } finally {
      _freeAllocatedString(reqPtr);
    }
  }

  Map<String, dynamic> scanWorkspace({int maxDepth = 4}) {
    if (!isAvailable) return {};
    final ptr = _workspaceScan(_ctx!, maxDepth);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> openFile(String relPath) {
    if (!isAvailable) return {};
    final pathPtr = _toCString(relPath);
    final ptr = _fileOpen(_ctx!, pathPtr.pointer);
    _freeAllocatedString(pathPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> editFile(String relPath, Map<String, dynamic> editPayload) {
    if (!isAvailable) return {};
    final pathPtr = _toCString(relPath);
    final jsonPtr = _toCString(jsonEncode(editPayload));
    final ptr = _fileEdit(_ctx!, pathPtr.pointer, jsonPtr.pointer);
    _freeAllocatedString(pathPtr);
    _freeAllocatedString(jsonPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> undo(String relPath) {
    if (!isAvailable) return {};
    final pathPtr = _toCString(relPath);
    final ptr = _undo(_ctx!, pathPtr.pointer);
    _freeAllocatedString(pathPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> redo(String relPath) {
    if (!isAvailable) return {};
    final pathPtr = _toCString(relPath);
    final ptr = _redo(_ctx!, pathPtr.pointer);
    _freeAllocatedString(pathPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  /// Saves an open editor buffer to disk atomically, resetting is_dirty to false.
  Map<String, dynamic> saveFile(String relPath) {
    if (!isAvailable) return {};
    final pathPtr = _toCString(relPath);
    final ptr = _fileSave(_ctx!, pathPtr.pointer);
    _freeAllocatedString(pathPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  /// Sets cursor position and selection state in the Rust Editor.
  Map<String, dynamic> setFileCursor(String relPath, int line, int col, {bool select = false}) {
    if (!isAvailable) return {};
    final pathPtr = _toCString(relPath);
    final ptr = _fileCursorSet(_ctx!, pathPtr.pointer, line, col, select);
    _freeAllocatedString(pathPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  List<dynamic> fetchSymbols([String query = '']) {
    if (!isAvailable) return [];
    final queryPtr = _toCString(query);
    final ptr = _graphSymbols(_ctx!, queryPtr.pointer);
    _freeAllocatedString(queryPtr);
    return _parseJsonList(_fromCString(ptr));
  }

  Map<String, dynamic> indexFile(String relPath) {
    if (!isAvailable) return {};
    final pathPtr = _toCString(relPath);
    final ptr = _graphIndexFile(_ctx!, pathPtr.pointer);
    _freeAllocatedString(pathPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  List<dynamic> queryOutline(String relPath) {
    if (!isAvailable) return [];
    final pathPtr = _toCString(relPath);
    final ptr = _graphQueryOutline(_ctx!, pathPtr.pointer);
    _freeAllocatedString(pathPtr);
    return _parseJsonList(_fromCString(ptr));
  }

  List<dynamic> findDefinition(String query) {
    if (!isAvailable) return [];
    final queryPtr = _toCString(query);
    final ptr = _graphFindDefinition(_ctx!, queryPtr.pointer);
    _freeAllocatedString(queryPtr);
    return _parseJsonList(_fromCString(ptr));
  }

  List<dynamic> findReferences(String query) {
    if (!isAvailable) return [];
    final queryPtr = _toCString(query);
    final ptr = _graphFindReferences(_ctx!, queryPtr.pointer);
    _freeAllocatedString(queryPtr);
    return _parseJsonList(_fromCString(ptr));
  }

  Map<String, dynamic> getCodeContext(String query) {
    if (!isAvailable) return {};
    final queryPtr = _toCString(query);
    final ptr = _graphGetContext(_ctx!, queryPtr.pointer);
    _freeAllocatedString(queryPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  List<dynamic> findCallers(String query) {
    if (!isAvailable) return [];
    final queryPtr = _toCString(query);
    final ptr = _graphFindCallers(_ctx!, queryPtr.pointer);
    _freeAllocatedString(queryPtr);
    return _parseJsonList(_fromCString(ptr));
  }

  List<dynamic> findCallees(String query) {
    if (!isAvailable) return [];
    final queryPtr = _toCString(query);
    final ptr = _graphFindCallees(_ctx!, queryPtr.pointer);
    _freeAllocatedString(queryPtr);
    return _parseJsonList(_fromCString(ptr));
  }

  // ---------------------------------------------------------------------------
  // LSP (Language Server Protocol) Cognitive Capabilities (P2.1 - P2.6)
  // ---------------------------------------------------------------------------

  bool lspInitServer([String? cmd, List<String>? args]) {
    if (!isAvailable) return false;
    final cmdPtr = _toCString(cmd ?? '');
    final argsPtr = _toCString(args != null ? jsonEncode(args) : '[]');
    final ok = _lspInitServer(_ctx!, cmdPtr.pointer, argsPtr.pointer);
    _freeAllocatedString(cmdPtr);
    _freeAllocatedString(argsPtr);
    return ok;
  }

  List<dynamic> lspDidOpen(String filePath, String language, String content) {
    if (!isAvailable) return [];
    final filePtr = _toCString(filePath);
    final langPtr = _toCString(language);
    final textPtr = _toCString(content);
    final ptr = _lspDidOpen(_ctx!, filePtr.pointer, langPtr.pointer, textPtr.pointer);
    _freeAllocatedString(filePtr);
    _freeAllocatedString(langPtr);
    _freeAllocatedString(textPtr);
    return _parseJsonList(_fromCString(ptr));
  }

  List<dynamic> lspDidChange(String filePath, int version, String content) {
    if (!isAvailable) return [];
    final filePtr = _toCString(filePath);
    final textPtr = _toCString(content);
    final ptr = _lspDidChange(_ctx!, filePtr.pointer, version, textPtr.pointer);
    _freeAllocatedString(filePtr);
    _freeAllocatedString(textPtr);
    return _parseJsonList(_fromCString(ptr));
  }

  List<dynamic> lspGetDiagnostics(String filePath) {
    if (!isAvailable) return [];
    final filePtr = _toCString(filePath);
    final ptr = _lspGetDiagnostics(_ctx!, filePtr.pointer);
    _freeAllocatedString(filePtr);
    return _parseJsonList(_fromCString(ptr));
  }

  List<dynamic> lspGotoDefinition(String filePath, int line, int col) {
    if (!isAvailable) return [];
    final filePtr = _toCString(filePath);
    final ptr = _lspGotoDefinition(_ctx!, filePtr.pointer, line, col);
    _freeAllocatedString(filePtr);
    return _parseJsonList(_fromCString(ptr));
  }

  List<dynamic> lspFindReferences(String filePath, int line, int col, {bool includeDecl = true}) {
    if (!isAvailable) return [];
    final filePtr = _toCString(filePath);
    final ptr = _lspFindReferences(_ctx!, filePtr.pointer, line, col, includeDecl);
    _freeAllocatedString(filePtr);
    return _parseJsonList(_fromCString(ptr));
  }

  Map<String, dynamic>? lspHover(String filePath, int line, int col) {
    if (!isAvailable) return null;
    final filePtr = _toCString(filePath);
    final ptr = _lspHover(_ctx!, filePtr.pointer, line, col);
    _freeAllocatedString(filePtr);
    final res = _parseJsonMap(_fromCString(ptr));
    return res.isEmpty ? null : res;
  }

  List<dynamic> lspCompletion(String filePath, int line, int col) {
    if (!isAvailable) return [];
    final filePtr = _toCString(filePath);
    final ptr = _lspCompletion(_ctx!, filePtr.pointer, line, col);
    _freeAllocatedString(filePtr);
    return _parseJsonList(_fromCString(ptr));
  }

  Map<String, dynamic>? lspRename(String filePath, int line, int col, String newName) {
    if (!isAvailable) return null;
    final filePtr = _toCString(filePath);
    final namePtr = _toCString(newName);
    final ptr = _lspRename(_ctx!, filePtr.pointer, line, col, namePtr.pointer);
    _freeAllocatedString(filePtr);
    _freeAllocatedString(namePtr);
    final res = _parseJsonMap(_fromCString(ptr));
    return res.isEmpty ? null : res;
  }

  // ---------------------------------------------------------------------------
  // Phase 4: Viewport Tokens, Workspace Search & Terminal Execution
  // ---------------------------------------------------------------------------

  Map<String, dynamic> getViewportTokens(String filePath, int startLine, int endLine) {
    if (!isAvailable) return {'status': 'error', 'lines': []};
    final filePtr = _toCString(filePath);
    final ptr = _getViewportTokens(_ctx!, filePtr.pointer, startLine, endLine);
    _freeAllocatedString(filePtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> searchWorkspace(String query, [Map<String, dynamic>? options]) {
    if (!isAvailable) return {'status': 'error', 'matches': []};
    final qPtr = _toCString(query);
    final optPtr = _toCString(jsonEncode(options ?? {}));
    final ptr = _searchWorkspace(_ctx!, qPtr.pointer, optPtr.pointer);
    _freeAllocatedString(qPtr);
    _freeAllocatedString(optPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> replaceWorkspace(String query, String replacement, [Map<String, dynamic>? options]) {
    if (!isAvailable) return {'status': 'error', 'replaced_count': 0};
    final qPtr = _toCString(query);
    final replPtr = _toCString(replacement);
    final optPtr = _toCString(jsonEncode(options ?? {}));
    final ptr = _replaceWorkspace(_ctx!, qPtr.pointer, replPtr.pointer, optPtr.pointer);
    _freeAllocatedString(qPtr);
    _freeAllocatedString(replPtr);
    _freeAllocatedString(optPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> terminalExec(String cmd, List<String> args) {
    if (!isAvailable) return {'status': 'error', 'error': 'Bindings unavailable'};
    final cmdPtr = _toCString(cmd);
    final argsPtr = _toCString(jsonEncode(args));
    final ptr = _terminalExec(_ctx!, cmdPtr.pointer, argsPtr.pointer);
    _freeAllocatedString(cmdPtr);
    _freeAllocatedString(argsPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  // --- 交互式终端(PTY)。屏幕由 Rust 侧 vt100 排好版,这里只搬 JSON。

  Map<String, dynamic> ptyOpen(int rows, int cols) {
    if (!isAvailable) return {'status': 'error', 'error': 'FFI not available'};
    return _parseJsonMap(_fromCString(_ptyOpen(_ctx!, rows, cols)));
  }

  Map<String, dynamic> ptyWrite(String id, String data) {
    if (!isAvailable) return {'status': 'error', 'error': 'FFI not available'};
    final idPtr = _toCString(id);
    final dataPtr = _toCString(data);
    final ptr = _ptyWrite(_ctx!, idPtr.pointer, dataPtr.pointer);
    _freeAllocatedString(idPtr);
    _freeAllocatedString(dataPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> ptyResize(String id, int rows, int cols) {
    if (!isAvailable) return {'status': 'error', 'error': 'FFI not available'};
    final idPtr = _toCString(id);
    final ptr = _ptyResize(_ctx!, idPtr.pointer, rows, cols);
    _freeAllocatedString(idPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> ptySnapshot(String id, {int sinceSeq = -1, int scrollback = 0}) {
    if (!isAvailable) return {'status': 'error', 'error': 'FFI not available'};
    final idPtr = _toCString(id);
    final ptr = _ptySnapshot(_ctx!, idPtr.pointer, sinceSeq, scrollback);
    _freeAllocatedString(idPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> ptyClose(String id) {
    if (!isAvailable) return {'status': 'error', 'error': 'FFI not available'};
    final idPtr = _toCString(id);
    final ptr = _ptyClose(_ctx!, idPtr.pointer);
    _freeAllocatedString(idPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  /// [gitCall] 的后台版本:在独立 isolate 里调用,push / rebase 这类慢操作不卡界面。
  /// 上下文指针按地址传过去 —— 调用期间不能销毁上下文,切换项目前要先 await [whenIdle]。
  Future<Map<String, dynamic>> gitCallAsync(String method, Map<String, dynamic> params) async {
    final path = _libraryPath;
    if (!isAvailable || path == null) return {'status': 'error', 'error': 'FFI not available'};
    final ctxAddress = _ctx!.address;
    final paramsJson = jsonEncode(params);
    _inFlight++;
    try {
      final raw = await Isolate.run(() => _gitCallInIsolate(path, ctxAddress, method, paramsJson));
      return _parseJsonMap(raw);
    } catch (e) {
      return {'status': 'error', 'error': '$e'};
    } finally {
      _inFlight--;
      if (_inFlight == 0) {
        _idle?.complete();
        _idle = null;
      }
    }
  }

  /// 所有后台调用都结束后完成。
  Future<void> whenIdle() {
    if (_inFlight == 0) return Future.value();
    return (_idle ??= Completer<void>()).future;
  }

  /// Git Log 工具窗的统一入口:按 method 名分发到 Rust 的 GitEngine(git.log / git.reset …)。
  Map<String, dynamic> gitCall(String method, Map<String, dynamic> params) {
    if (!isAvailable) return {'status': 'error', 'error': 'FFI not available'};
    final methodPtr = _toCString(method);
    final paramsPtr = _toCString(jsonEncode(params));
    final ptr = _gitCall(_ctx!, methodPtr.pointer, paramsPtr.pointer);
    _freeAllocatedString(methodPtr);
    _freeAllocatedString(paramsPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  // ---------------------------------------------------------------------------
  // Phase 5: Streaming AI Chat, Message Persistence & Git Operations
  // ---------------------------------------------------------------------------

  Map<String, dynamic> getGitStatus() {
    if (!isAvailable) return {'branch': 'HEAD', 'changes': []};
    final ptr = _gitStatus(_ctx!);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> getGitDiff({String? filePath, bool staged = false}) {
    if (!isAvailable) return {'status': 'error', 'diff': ''};
    final pathPtr = _toCString(filePath ?? '');
    final ptr = _gitDiff(_ctx!, pathPtr.pointer, staged);
    _freeAllocatedString(pathPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> gitStage(String filePath) {
    if (!isAvailable) return {'status': 'error'};
    final pathPtr = _toCString(filePath);
    final ptr = _gitStage(_ctx!, pathPtr.pointer);
    _freeAllocatedString(pathPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> gitUnstage(String filePath) {
    if (!isAvailable) return {'status': 'error'};
    final pathPtr = _toCString(filePath);
    final ptr = _gitUnstage(_ctx!, pathPtr.pointer);
    _freeAllocatedString(pathPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> gitCommit(String message) {
    if (!isAvailable) return {'status': 'error'};
    final msgPtr = _toCString(message);
    final ptr = _gitCommit(_ctx!, msgPtr.pointer);
    _freeAllocatedString(msgPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> gitFileDiffHunks(String filePath) {
    if (!isAvailable) return {'status': 'error', 'hunks': []};
    final pathPtr = _toCString(filePath);
    final ptr = _gitFileHunks(_ctx!, pathPtr.pointer);
    _freeAllocatedString(pathPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> gitRevertFile(String filePath) {
    if (!isAvailable) return {'status': 'error'};
    final pathPtr = _toCString(filePath);
    final ptr = _gitRevertFile(_ctx!, pathPtr.pointer);
    _freeAllocatedString(pathPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  // ---------------------------------------------------------------------------
  // Context Engine & Memory (Phase 10)
  // ---------------------------------------------------------------------------

  Map<String, dynamic> updaterCheck(String currentVersion, String manifestJson, {String? platform}) {
    if (!isAvailable) return {'status': 'error', 'error': 'FFI not available'};
    final pVer = _toCString(currentVersion);
    final pMan = _toCString(manifestJson);
    final pPlat = _toCString(platform ?? (Platform.isMacOS ? 'macos' : (Platform.isLinux ? 'linux' : 'windows')));
    try {
      final ptr = _updaterCheck(_ctx!, pVer.pointer, pMan.pointer, pPlat.pointer);
      return _parseJsonMap(_fromCString(ptr));
    } finally {
      _freeAllocatedString(pVer);
      _freeAllocatedString(pMan);
      _freeAllocatedString(pPlat);
    }
  }

  Map<String, dynamic> updaterStage(String stagingDir, String fileName, String content, String expectedSha256) {
    if (!isAvailable) return {'status': 'error', 'error': 'FFI not available'};
    final pStage = _toCString(stagingDir);
    final pFile = _toCString(fileName);
    final pContent = _toCString(content);
    final pSha = _toCString(expectedSha256);
    try {
      final ptr = _updaterStage(_ctx!, pStage.pointer, pFile.pointer, pContent.pointer, pSha.pointer);
      return _parseJsonMap(_fromCString(ptr));
    } finally {
      _freeAllocatedString(pStage);
      _freeAllocatedString(pFile);
      _freeAllocatedString(pContent);
      _freeAllocatedString(pSha);
    }
  }

  Map<String, dynamic> updaterApply(String stagingDir, String targetDir, List<String> files, {String? platform}) {
    if (!isAvailable) return {'status': 'error', 'error': 'FFI not available'};
    final pStage = _toCString(stagingDir);
    final pTarget = _toCString(targetDir);
    final pFiles = _toCString(jsonEncode(files));
    final pPlat = _toCString(platform ?? (Platform.isMacOS ? 'macos' : (Platform.isLinux ? 'linux' : 'windows')));
    try {
      final ptr = _updaterApply(_ctx!, pStage.pointer, pTarget.pointer, pFiles.pointer, pPlat.pointer);
      return _parseJsonMap(_fromCString(ptr));
    } finally {
      _freeAllocatedString(pStage);
      _freeAllocatedString(pTarget);
      _freeAllocatedString(pFiles);
      _freeAllocatedString(pPlat);
    }
  }

  // ---------------------------------------------------------------------------
  // Memory and Conversion Helpers
  // ---------------------------------------------------------------------------

  _AllocatedString _toCString(String str) {
    final bytes = utf8.encode(str);
    final ptr = _stringAlloc(bytes.length);
    final bytePtr = ptr.cast<Uint8>();
    for (int i = 0; i < bytes.length; i++) {
      bytePtr[i] = bytes[i];
    }
    bytePtr[bytes.length] = 0;
    return _AllocatedString(ptr, bytes.length);
  }

  void _freeAllocatedString(_AllocatedString str) {
    _bufferFree(str.pointer, str.length);
  }

  String _fromCString(Pointer<Char> ptr) {
    if (ptr.address == 0) return '';
    final units = <int>[];
    int i = 0;
    final bytePtr = ptr.cast<Uint8>();
    while (true) {
      final b = bytePtr[i];
      if (b == 0) break;
      units.add(b);
      i++;
    }
    _stringFree(ptr);
    return utf8.decode(units, allowMalformed: true);
  }

  Map<String, dynamic> _parseJsonMap(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  List<dynamic> _parseJsonList(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is List) return decoded;
    } catch (_) {}
    return [];
  }

  DynamicLibrary? _loadLibrary() {
    // 打包后的 .app:库在 Contents/Frameworks,可执行文件在 Contents/MacOS。
    final bundled = Platform.isMacOS
        ? '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks/libcodelite.dylib'
        : null;
    final candidates = [
      if (bundled != null) bundled,
      'target/debug/libcodelite.dylib',
      'target/release/libcodelite.dylib',
      '../../target/debug/libcodelite.dylib',
      '../../target/release/libcodelite.dylib',
      'libcodelite.dylib',
      '/Users/dev/rust/code-lite-x/target/debug/libcodelite.dylib',
      '/Users/dev/rust/code-lite-x/target/release/libcodelite.dylib',
      'target/debug/libcodelite.so',
      '../../target/debug/libcodelite.so',
      'codelite.dll',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        try {
          final lib = DynamicLibrary.open(path);
          _libraryPath = path;
          return lib;
        } catch (_) {}
      }
    }

    try {
      if (Platform.isMacOS) _libraryPath = 'libcodelite.dylib';
      return Platform.isMacOS
          ? DynamicLibrary.open('libcodelite.dylib')
          : DynamicLibrary.process();
    } catch (_) {
      return null;
    }
  }
}

/// 在后台 isolate 里执行 `codelite_git_call`。isolate 不共享 [CodeLiteBindings] 单例,
/// 所以重新打开同一个库(进程内是同一份映像,`_ctx` 地址依然有效)并只查这几个符号。
String _gitCallInIsolate(String libraryPath, int ctxAddress, String method, String paramsJson) {
  final lib = DynamicLibrary.open(libraryPath);
  final call = lib.lookupFunction<_GitCallC, _GitCallDart>('codelite_git_call');
  final alloc = lib.lookupFunction<_StringAllocC, _StringAllocDart>('codelite_string_alloc');
  final bufferFree = lib.lookupFunction<_BufferFreeC, _BufferFreeDart>('codelite_buffer_free');
  final stringFree = lib.lookupFunction<_StringFreeC, _StringFreeDart>('codelite_string_free');

  Pointer<Char> toC(List<int> bytes) {
    final ptr = alloc(bytes.length);
    final b = ptr.cast<Uint8>();
    for (var i = 0; i < bytes.length; i++) {
      b[i] = bytes[i];
    }
    b[bytes.length] = 0;
    return ptr;
  }

  final methodBytes = utf8.encode(method);
  final paramsBytes = utf8.encode(paramsJson);
  final m = toC(methodBytes);
  final p = toC(paramsBytes);
  final res = call(Pointer<Void>.fromAddress(ctxAddress), m, p);
  bufferFree(m, methodBytes.length);
  bufferFree(p, paramsBytes.length);
  if (res.address == 0) return '';
  final out = <int>[];
  final bytes = res.cast<Uint8>();
  for (var i = 0; bytes[i] != 0; i++) {
    out.add(bytes[i]);
  }
  stringFree(res);
  return utf8.decode(out, allowMalformed: true);
}

class _AllocatedString {
  final Pointer<Char> pointer;
  final int length;

  _AllocatedString(this.pointer, this.length);
}
