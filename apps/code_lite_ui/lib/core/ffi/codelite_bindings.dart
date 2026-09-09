import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

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

typedef _AgentPromptC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId, Pointer<Char> prompt);
typedef _AgentPromptDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId, Pointer<Char> prompt);

typedef _AgentRollbackC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId, Int64 targetStepId);
typedef _AgentRollbackDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId, int targetStepId);

typedef _AgentRestoreC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId);
typedef _AgentRestoreDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId);

typedef _AgentPlanTaskC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId, Pointer<Char> paramsJson);
typedef _AgentPlanTaskDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId, Pointer<Char> paramsJson);

typedef _AgentExecStepC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> planId);
typedef _AgentExecStepDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> planId);

typedef _AgentApproveC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> requestId, Bool approved);
typedef _AgentApproveDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> requestId, bool approved);

typedef _AgentPendingApprovalsC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId);
typedef _AgentPendingApprovalsDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId);

typedef _AgentDiffReviewC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId);
typedef _AgentDiffReviewDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId);

typedef _AgentFimCompleteC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, Pointer<Char> prefix, Pointer<Char> suffix, Pointer<Char> language);
typedef _AgentFimCompleteDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, Pointer<Char> prefix, Pointer<Char> suffix, Pointer<Char> language);

typedef _StorageEventsC = Pointer<Char> Function(Pointer<Void> ctx);
typedef _StorageEventsDart = Pointer<Char> Function(Pointer<Void> ctx);

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

typedef _AgentPromptStreamC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId, Pointer<Char> prompt);
typedef _AgentPromptStreamDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId, Pointer<Char> prompt);

typedef _AgentPollStreamC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId);
typedef _AgentPollStreamDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId);

typedef _SessionMessagesC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId);
typedef _SessionMessagesDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> sessionId);

typedef _GitStatusC = Pointer<Char> Function(Pointer<Void> ctx);
typedef _GitStatusDart = Pointer<Char> Function(Pointer<Void> ctx);

typedef _GitDiffC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, Bool staged);
typedef _GitDiffDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath, bool staged);

typedef _GitStageC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath);
typedef _GitStageDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> filePath);

typedef _GitCommitC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> message);
typedef _GitCommitDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> message);

typedef _JsonRpcCallC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> requestJson);
typedef _JsonRpcCallDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> requestJson);

/// Dart FFI bindings to Rust Core dynamic library (`libcodelite.dylib`).
class CodeLiteBindings {
  static final CodeLiteBindings instance = CodeLiteBindings._();
  CodeLiteBindings._();

  DynamicLibrary? _dylib;
  Pointer<Void>? _ctx;
  bool _initialized = false;

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
  late final _AgentPromptDart _agentPrompt;
  late final _AgentRollbackDart _agentRollback;
  late final _AgentRestoreDart _agentRestore;
  late final _AgentPlanTaskDart _agentPlanTask;
  late final _AgentExecStepDart _agentExecStep;
  late final _AgentApproveDart _agentApprove;
  late final _AgentPendingApprovalsDart _agentPendingApprovals;
  late final _AgentDiffReviewDart _agentDiffReview;
  late final _AgentFimCompleteDart _agentFimComplete;
  late final _StorageEventsDart _storageEvents;
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
  late final _AgentPromptStreamDart _agentPromptStream;
  late final _AgentPollStreamDart _agentPollStream;
  late final _SessionMessagesDart _sessionListMessages;
  late final _SessionMessagesDart _sessionClearMessages;
  late final _GitStatusDart _gitStatus;
  late final _GitDiffDart _gitDiff;
  late final _GitStageDart _gitStage;
  late final _GitStageDart _gitUnstage;
  late final _GitCommitDart _gitCommit;
  late final _JsonRpcCallDart _jsonRpcCall;

  Pointer<Void>? get contextPointer => _ctx;

  /// Loads the dynamic library and initializes Rust Core.
  bool initialize([String workspacePath = '.']) {
    if (_initialized) return isAvailable;

    try {
      _dylib = _loadLibrary();
      if (_dylib == null) return false;

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
      _agentPrompt = _dylib!.lookupFunction<_AgentPromptC, _AgentPromptDart>('codelite_agent_send_prompt');
      _agentRollback = _dylib!.lookupFunction<_AgentRollbackC, _AgentRollbackDart>('codelite_agent_rollback');
      _agentRestore = _dylib!.lookupFunction<_AgentRestoreC, _AgentRestoreDart>('codelite_agent_restore_start');
      _agentPlanTask = _dylib!.lookupFunction<_AgentPlanTaskC, _AgentPlanTaskDart>('codelite_agent_plan_task');
      _agentExecStep = _dylib!.lookupFunction<_AgentExecStepC, _AgentExecStepDart>('codelite_agent_execute_next_step');
      _agentApprove = _dylib!.lookupFunction<_AgentApproveC, _AgentApproveDart>('codelite_agent_approve_step');
      _agentPendingApprovals = _dylib!.lookupFunction<_AgentPendingApprovalsC, _AgentPendingApprovalsDart>('codelite_agent_get_pending_approvals');
      _agentDiffReview = _dylib!.lookupFunction<_AgentDiffReviewC, _AgentDiffReviewDart>('codelite_agent_get_diff_review');
      _agentFimComplete = _dylib!.lookupFunction<_AgentFimCompleteC, _AgentFimCompleteDart>('codelite_agent_fim_complete');
      _storageEvents = _dylib!.lookupFunction<_StorageEventsC, _StorageEventsDart>('codelite_storage_events');
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
      _agentPromptStream = _dylib!.lookupFunction<_AgentPromptStreamC, _AgentPromptStreamDart>('codelite_agent_send_prompt_stream');
      _agentPollStream = _dylib!.lookupFunction<_AgentPollStreamC, _AgentPollStreamDart>('codelite_agent_poll_stream_events');
      _sessionListMessages = _dylib!.lookupFunction<_SessionMessagesC, _SessionMessagesDart>('codelite_session_list_messages');
      _sessionClearMessages = _dylib!.lookupFunction<_SessionMessagesC, _SessionMessagesDart>('codelite_session_clear_messages');
      _gitStatus = _dylib!.lookupFunction<_GitStatusC, _GitStatusDart>('codelite_git_status');
      _gitDiff = _dylib!.lookupFunction<_GitDiffC, _GitDiffDart>('codelite_git_diff');
      _gitStage = _dylib!.lookupFunction<_GitStageC, _GitStageDart>('codelite_git_stage');
      _gitUnstage = _dylib!.lookupFunction<_GitStageC, _GitStageDart>('codelite_git_unstage');
      _gitCommit = _dylib!.lookupFunction<_GitCommitC, _GitCommitDart>('codelite_git_commit');
      _jsonRpcCall = _dylib!.lookupFunction<_JsonRpcCallC, _JsonRpcCallDart>('codelite_jsonrpc_call');

      final pathPtr = _toCString(workspacePath);
      _ctx = _init(pathPtr.pointer);
      _freeAllocatedString(pathPtr);

      _initialized = _ctx != null && _ctx!.address != 0;
      return _initialized;
    } catch (e) {
      _dylib = null;
      _ctx = null;
      _initialized = false;
      return false;
    }
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

  Map<String, dynamic> sendAgentPrompt(String sessionId, String prompt) {
    if (!isAvailable) return {};
    final sessPtr = _toCString(sessionId);
    final promptPtr = _toCString(prompt);
    final ptr = _agentPrompt(_ctx!, sessPtr.pointer, promptPtr.pointer);
    _freeAllocatedString(sessPtr);
    _freeAllocatedString(promptPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> rollbackAgent(String sessionId, int targetStepId) {
    if (!isAvailable) return {};
    final sessPtr = _toCString(sessionId);
    final ptr = _agentRollback(_ctx!, sessPtr.pointer, targetStepId);
    _freeAllocatedString(sessPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> restoreAgent(String sessionId) {
    if (!isAvailable) return {};
    final sessPtr = _toCString(sessionId);
    final ptr = _agentRestore(_ctx!, sessPtr.pointer);
    _freeAllocatedString(sessPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  /// Generates Fill-In-The-Middle (FIM) inline code completion (Phase 8.2).
  Map<String, dynamic> agentFimComplete(String filePath, String prefix, String suffix, String language) {
    if (!isAvailable) {
      return {'status': 'ok', 'suggestion': '// [Mock FIM] completion unavailable'};
    }
    final filePtr = _toCString(filePath);
    final prefixPtr = _toCString(prefix);
    final suffixPtr = _toCString(suffix);
    final langPtr = _toCString(language);
    final ptr = _agentFimComplete(_ctx!, filePtr.pointer, prefixPtr.pointer, suffixPtr.pointer, langPtr.pointer);
    _freeAllocatedString(filePtr);
    _freeAllocatedString(prefixPtr);
    _freeAllocatedString(suffixPtr);
    _freeAllocatedString(langPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> agentPlanTask(String sessionId, Map<String, dynamic> params) {
    if (!isAvailable) return {};
    final sessPtr = _toCString(sessionId);
    final paramsPtr = _toCString(jsonEncode(params));
    final ptr = _agentPlanTask(_ctx!, sessPtr.pointer, paramsPtr.pointer);
    _freeAllocatedString(sessPtr);
    _freeAllocatedString(paramsPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> agentExecuteNextStep(String planId) {
    if (!isAvailable) return {};
    final planPtr = _toCString(planId);
    final ptr = _agentExecStep(_ctx!, planPtr.pointer);
    _freeAllocatedString(planPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> agentApproveStep(String requestId, bool approved) {
    if (!isAvailable) return {};
    final reqPtr = _toCString(requestId);
    final ptr = _agentApprove(_ctx!, reqPtr.pointer, approved);
    _freeAllocatedString(reqPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> agentGetPendingApprovals([String? sessionId]) {
    if (!isAvailable) return {};
    final sessPtr = sessionId != null ? _toCString(sessionId) : null;
    final ptr = _agentPendingApprovals(_ctx!, sessPtr?.pointer ?? nullptr);
    if (sessPtr != null) _freeAllocatedString(sessPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> agentGetDiffReview(String sessionId) {
    if (!isAvailable) return {};
    final sessPtr = _toCString(sessionId);
    final ptr = _agentDiffReview(_ctx!, sessPtr.pointer);
    _freeAllocatedString(sessPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  List<dynamic> fetchEvents() {
    if (!isAvailable) return [];
    final ptr = _storageEvents(_ctx!);
    return _parseJsonList(_fromCString(ptr));
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

  // ---------------------------------------------------------------------------
  // Phase 5: Streaming AI Chat, Message Persistence & Git Operations
  // ---------------------------------------------------------------------------

  Map<String, dynamic> sendPromptStream(String sessionId, String prompt) {
    if (!isAvailable) return {'status': 'error', 'error': 'FFI unavailable'};
    final sessPtr = _toCString(sessionId);
    final promptPtr = _toCString(prompt);
    final ptr = _agentPromptStream(_ctx!, sessPtr.pointer, promptPtr.pointer);
    _freeAllocatedString(sessPtr);
    _freeAllocatedString(promptPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  List<dynamic> pollStreamEvents([String sessionId = '']) {
    if (!isAvailable) return [];
    final sessPtr = _toCString(sessionId);
    final ptr = _agentPollStream(_ctx!, sessPtr.pointer);
    _freeAllocatedString(sessPtr);
    return _parseJsonList(_fromCString(ptr));
  }

  List<dynamic> listMessages(String sessionId) {
    if (!isAvailable) return [];
    final sessPtr = _toCString(sessionId);
    final ptr = _sessionListMessages(_ctx!, sessPtr.pointer);
    _freeAllocatedString(sessPtr);
    return _parseJsonList(_fromCString(ptr));
  }

  Map<String, dynamic> clearMessages(String sessionId) {
    if (!isAvailable) return {'status': 'error'};
    final sessPtr = _toCString(sessionId);
    final ptr = _sessionClearMessages(_ctx!, sessPtr.pointer);
    _freeAllocatedString(sessPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

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
    final candidates = [
      'target/debug/libcodelite.dylib',
      '../../target/debug/libcodelite.dylib',
      'libcodelite.dylib',
      '/Users/dev/rust/code-lite-x/target/debug/libcodelite.dylib',
      'target/debug/libcodelite.so',
      '../../target/debug/libcodelite.so',
      'codelite.dll',
    ];

    for (final path in candidates) {
      if (File(path).existsSync()) {
        try {
          return DynamicLibrary.open(path);
        } catch (_) {}
      }
    }

    try {
      return Platform.isMacOS
          ? DynamicLibrary.open('libcodelite.dylib')
          : DynamicLibrary.process();
    } catch (_) {
      return null;
    }
  }
}

class _AllocatedString {
  final Pointer<Char> pointer;
  final int length;

  _AllocatedString(this.pointer, this.length);
}
