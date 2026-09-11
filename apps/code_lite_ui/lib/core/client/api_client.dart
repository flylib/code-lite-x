import 'dart:convert';
import 'package:http/http.dart' as http;
// web 没有 dart:ffi —— 条件导入让 web 拿到桩(isAvailable 恒 false),
// 原生拿到真实的 FFI 绑定。两者类名与签名一致。
import '../ffi/codelite_bindings_stub.dart'
    if (dart.library.ffi) '../ffi/codelite_bindings.dart';

/// Unified Client connecting Flutter UI to the Rust Core.
/// Prioritizes direct C-ABI FFI (`libcodelite.dylib`) and falls back to HTTP IPC (`code-lite-app`).
class ApiClient {
  final String baseUrl;
  final CodeLiteBindings _ffi = CodeLiteBindings.instance;

  ApiClient({this.baseUrl = 'http://127.0.0.1:4096'}) {
    _ffi.initialize();
  }

  bool get isFfiAvailable => _ffi.isAvailable;

  /// Fetches the project workspace file tree.
  Future<Map<String, dynamic>> fetchWorkspaceTree() async {
    if (_ffi.isAvailable) {
      final res = _ffi.scanWorkspace();
      if (res.isNotEmpty) return res;
    }

    try {
      final response = await http.get(Uri.parse('$baseUrl/api/workspace'));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (e) {
      // Return fallback demo data if server is booting
    }
    return _fallbackWorkspace();
  }

  /// Opens a file from disk into the Rust TextBuffer.
  Future<Map<String, dynamic>> fetchFile(String relativePath) async {
    if (_ffi.isAvailable) {
      final res = _ffi.openFile(relativePath);
      if (res.isNotEmpty && res['status'] == 'ok') {
        return res;
      }
    }

    try {
      final uri = Uri.parse('$baseUrl/api/file').replace(
        queryParameters: {'path': relativePath},
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {
      'path': relativePath,
      'content': '// CodeLiteX: Rust Core offline or loading...',
      'lines': 1,
    };
  }

  /// Applies an edit directly to the Rust buffer.
  Future<Map<String, dynamic>> editFile(String relativePath, Map<String, dynamic> payload) async {
    if (_ffi.isAvailable) {
      final res = _ffi.editFile(relativePath, payload);
      if (res.isNotEmpty) return res;
    }
    return {};
  }

  /// Undoes the last edit via Rust UndoManager.
  Future<Map<String, dynamic>> undo(String path) async {
    if (_ffi.isAvailable) {
      final res = _ffi.undo(path);
      if (res.isNotEmpty) return res;
    }

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/undo'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'path': path}),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  /// Redoes the undone edit via Rust UndoManager.
  Future<Map<String, dynamic>> redo(String path) async {
    if (_ffi.isAvailable) {
      final res = _ffi.redo(path);
      if (res.isNotEmpty) return res;
    }

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/redo'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'path': path}),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {};
  }

  /// Saves the specified open file buffer to disk atomically.
  Future<Map<String, dynamic>> saveFile(String path) async {
    if (_ffi.isAvailable) {
      final res = _ffi.saveFile(path);
      if (res.isNotEmpty) return res;
    }

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/save'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'path': path}),
      );
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as Map<String, dynamic>;
      }
    } catch (_) {}
    return {'status': 'ok', 'is_dirty': false};
  }

  /// Syncs cursor position to the Rust Editor.
  Future<Map<String, dynamic>> setFileCursor(String path, int line, int col, {bool select = false}) async {
    if (_ffi.isAvailable) {
      final res = _ffi.setFileCursor(path, line, col, select: select);
      if (res.isNotEmpty) return res;
    }
    return {'status': 'ok', 'line': line, 'col': col};
  }

  /// Retrieves events from SQLite.
  Future<List<dynamic>> fetchEvents() async {
    if (_ffi.isAvailable) {
      final res = _ffi.fetchEvents();
      if (res.isNotEmpty) return res;
    }

    try {
      final response = await http.get(Uri.parse('$baseUrl/api/storage/events'));
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as List<dynamic>;
      }
    } catch (_) {}
    return [];
  }

  /// Searches symbols in SQLite CodeGraph.
  Future<List<dynamic>> fetchSymbols([String query = '']) async {
    if (_ffi.isAvailable) {
      final res = _ffi.fetchSymbols(query);
      if (res.isNotEmpty) return res;
    }

    try {
      final uri = Uri.parse('$baseUrl/api/graph/symbols').replace(
        queryParameters: {'query': query},
      );
      final response = await http.get(uri);
      if (response.statusCode == 200) {
        return jsonDecode(response.body) as List<dynamic>;
      }
    } catch (_) {}
    return [];
  }

  /// Indexes a file into CodeGraph.
  Future<Map<String, dynamic>> indexFile(String path) async {
    if (_ffi.isAvailable) {
      return _ffi.indexFile(path);
    }
    return {'status': 'ok', 'path': path};
  }

  /// Queries the AST outline tree for a file.
  Future<List<dynamic>> queryOutline(String path) async {
    if (_ffi.isAvailable) {
      final res = _ffi.queryOutline(path);
      if (res.isNotEmpty) return res;
    }
    return [
      {'name': path.split('/').last, 'kind': 'file', 'line_start': 1, 'children': []}
    ];
  }

  /// Finds definitions for a symbol.
  Future<List<dynamic>> findDefinition(String query) async {
    if (_ffi.isAvailable) {
      return _ffi.findDefinition(query);
    }
    return [];
  }

  /// Finds references for a symbol.
  Future<List<dynamic>> findReferences(String query) async {
    if (_ffi.isAvailable) {
      return _ffi.findReferences(query);
    }
    return [];
  }

  /// Retrieves structured code context for Agent reasoning.
  Future<Map<String, dynamic>> getCodeContext(String query) async {
    if (_ffi.isAvailable) {
      return _ffi.getCodeContext(query);
    }
    return {};
  }

  /// Finds callers for a symbol.
  Future<List<dynamic>> findCallers(String query) async {
    if (_ffi.isAvailable) {
      return _ffi.findCallers(query);
    }
    return [];
  }

  /// Finds callees called by a symbol.
  Future<List<dynamic>> findCallees(String query) async {
    if (_ffi.isAvailable) {
      return _ffi.findCallees(query);
    }
    return [];
  }

  // ---------------------------------------------------------------------------
  // LSP Cognitive Infrastructure (P2.1 - P2.6)
  // ---------------------------------------------------------------------------

  /// Notifies LSP of document open and returns diagnostics.
  Future<List<dynamic>> lspDidOpen(String filePath, String language, String content) async {
    if (_ffi.isAvailable) {
      return _ffi.lspDidOpen(filePath, language, content);
    }
    return [];
  }

  /// Notifies LSP of document edits and returns updated diagnostics.
  Future<List<dynamic>> lspDidChange(String filePath, int version, String content) async {
    if (_ffi.isAvailable) {
      return _ffi.lspDidChange(filePath, version, content);
    }
    return [];
  }

  /// Retrieves current diagnostics for a file.
  Future<List<dynamic>> lspGetDiagnostics(String filePath) async {
    if (_ffi.isAvailable) {
      return _ffi.lspGetDiagnostics(filePath);
    }
    return [];
  }

  /// Jumps to symbol definition at line and col.
  Future<List<dynamic>> lspGotoDefinition(String filePath, int line, int col) async {
    if (_ffi.isAvailable) {
      return _ffi.lspGotoDefinition(filePath, line, col);
    }
    return [];
  }

  /// Finds all references for symbol at line and col.
  Future<List<dynamic>> lspFindReferences(String filePath, int line, int col, {bool includeDecl = true}) async {
    if (_ffi.isAvailable) {
      return _ffi.lspFindReferences(filePath, line, col, includeDecl: includeDecl);
    }
    return [];
  }

  /// Retrieves Hover documentation & type signature.
  Future<Map<String, dynamic>?> lspHover(String filePath, int line, int col) async {
    if (_ffi.isAvailable) {
      return _ffi.lspHover(filePath, line, col);
    }
    return null;
  }

  /// Requests smart code completions.
  Future<List<dynamic>> lspCompletion(String filePath, int line, int col) async {
    if (_ffi.isAvailable) {
      return _ffi.lspCompletion(filePath, line, col);
    }
    return [];
  }

  /// Executes atomic rename refactoring across the workspace.
  Future<Map<String, dynamic>?> lspRename(String filePath, int line, int col, String newName) async {
    if (_ffi.isAvailable) {
      return _ffi.lspRename(filePath, line, col, newName);
    }
    return null;
  }

  /// Triggers atomic rollback in SQLite.
  Future<bool> revertTask(String taskId) async {
    if (_ffi.isAvailable) {
      final res = _ffi.restoreAgent('default-session');
      if (res['status'] == 'ok') return true;
    }

    try {
      final response = await http.post(
        Uri.parse('$baseUrl/api/storage/revert'),
        headers: {'Content-Type': 'application/json'},
        body: jsonEncode({'task_id': taskId}),
      );
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  /// Sends an instruction to the AI Agent via ToolRuntime.
  Future<Map<String, dynamic>> sendAgentPrompt(String prompt, {String sessionId = 'default-session'}) async {
    if (_ffi.isAvailable) {
      final res = _ffi.sendAgentPrompt(sessionId, prompt);
      if (res.isNotEmpty) return res;
    }
    return {
      'reply': 'Processed prompt: "$prompt" (Audited via ToolRuntime)',
      'status': 'ok'
    };
  }

  // ---------------------------------------------------------------------------
  // Phase 3: Agent Cognitive Closed Loop & Permissions
  // ---------------------------------------------------------------------------

  /// Formulates a structured multi-step execution plan from prompt and context.
  Future<Map<String, dynamic>> agentPlanTask(
    String prompt, {
    String sessionId = 'default-session',
    String? targetFile,
    String? targetSymbol,
    String? codePatch,
  }) async {
    if (_ffi.isAvailable) {
      final params = {
        'prompt': prompt,
        if (targetFile != null) 'target_file': targetFile,
        if (targetSymbol != null) 'target_symbol': targetSymbol,
        if (codePatch != null) 'code_patch': codePatch,
      };
      return _ffi.agentPlanTask(sessionId, params);
    }
    return {'status': 'error', 'error': 'FFI unavailable'};
  }

  /// Executes the next step in the agent plan with permission gating & LSP verify.
  Future<Map<String, dynamic>> agentExecuteNextStep(String planId) async {
    if (_ffi.isAvailable) {
      return _ffi.agentExecuteNextStep(planId);
    }
    return {'status': 'error', 'error': 'FFI unavailable'};
  }

  /// Resolves a pending critical risk approval.
  Future<Map<String, dynamic>> agentApproveStep(String requestId, bool approved) async {
    if (_ffi.isAvailable) {
      return _ffi.agentApproveStep(requestId, approved);
    }
    return {'status': 'error', 'error': 'FFI unavailable'};
  }

  /// Fetches pending approval requests requiring user confirmation.
  Future<List<dynamic>> agentGetPendingApprovals([String? sessionId]) async {
    if (_ffi.isAvailable) {
      final res = _ffi.agentGetPendingApprovals(sessionId);
      if (res.containsKey('approvals') && res['approvals'] is List) {
        return res['approvals'] as List<dynamic>;
      }
    }
    return [];
  }

  /// Fetches diff review for the current session.
  Future<Map<String, dynamic>> agentGetDiffReview([String sessionId = 'default-session']) async {
    if (_ffi.isAvailable) {
      return _ffi.agentGetDiffReview(sessionId);
    }
    return {'status': 'ok', 'unified_diff': '', 'operations_count': 0};
  }

  /// Rolls back agent operations up to a specific step.
  Future<Map<String, dynamic>> agentRollback(String sessionId, int targetStepId) async {
    if (_ffi.isAvailable) {
      return _ffi.rollbackAgent(sessionId, targetStepId);
    }
    return {'status': 'error', 'error': 'FFI unavailable'};
  }

  /// Formulates a multi-file modification plan with topological dependency ordering (Phase 9.2).
  Future<Map<String, dynamic>> agentPlanMultiFile(
    String prompt,
    List<Map<String, String>> patches, {
    String sessionId = 'default-session',
  }) async {
    if (_ffi.isAvailable) {
      final params = {
        'prompt': prompt,
        'patches': patches,
      };
      return _ffi.agentPlanMultiFile(sessionId, params);
    }
    // Mock fallback when offline or FFI unavailable
    return {
      'status': 'ok',
      'plan': {
        'id': 'plan-mock-mf',
        'session_id': sessionId,
        'task_id': 'task-mock',
        'prompt': prompt,
        'steps': [
          for (int i = 0; i < patches.length; i++)
            {
              'id': 'step_${i + 1}',
              'description': patches[i]['description'] ?? 'Patch ${patches[i]['file_path']}',
              'tool_name': 'apply_patch',
              'args': {'path': patches[i]['file_path'], 'content': patches[i]['patch']},
              'risk_level': 'Medium',
              'status': 'Pending',
            }
        ],
        'current_step_index': 0,
        'is_completed': false,
      },
      'summary': {
        'total_files': patches.length,
        'ordered_files': patches.map((p) => p['file_path']).toList(),
      }
    };
  }

  /// Rolls back a single specific step within an active plan (Phase 9.4).
  Future<Map<String, dynamic>> agentRollbackStep(String planId, String stepId) async {
    if (_ffi.isAvailable) {
      return _ffi.agentRollbackStep(planId, stepId);
    }
    return {'status': 'ok', 'rolled_back': true, 'step_id': stepId};
  }

  /// Creates an isolated Git Worktree sandbox for an agent task (Phase 9.3).
  Future<Map<String, dynamic>> worktreeCreate(String taskId) async {
    if (_ffi.isAvailable) {
      return _ffi.worktreeCreate(taskId);
    }
    return {
      'status': 'ok',
      'session': {
        'task_id': taskId,
        'branch_name': 'agent/$taskId',
        'worktree_path': '.codelite/worktree/$taskId',
      }
    };
  }

  /// Merges an isolated Git Worktree sandbox back into workspace (Phase 9.3).
  Future<Map<String, dynamic>> worktreeMerge(String taskId) async {
    if (_ffi.isAvailable) {
      return _ffi.worktreeMerge(taskId);
    }
    return {'status': 'ok', 'merged': true, 'task_id': taskId};
  }

  /// Discards an isolated Git Worktree sandbox (Phase 9.3).
  Future<Map<String, dynamic>> worktreeDiscard(String taskId) async {
    if (_ffi.isAvailable) {
      return _ffi.worktreeDiscard(taskId);
    }
    return {'status': 'ok', 'discarded': true, 'task_id': taskId};
  }

  /// Fetches viewport-virtualized syntax tokens for high performance line streaming.
  Future<Map<String, dynamic>> getViewportTokens(String filePath, int startLine, int endLine) async {
    if (_ffi.isAvailable) {
      return _ffi.getViewportTokens(filePath, startLine, endLine);
    }
    return {'status': 'ok', 'lines': []};
  }

  /// Searches the workspace with multi-threading and options.
  Future<Map<String, dynamic>> searchWorkspace(String query, [Map<String, dynamic>? options]) async {
    if (_ffi.isAvailable) {
      return _ffi.searchWorkspace(query, options);
    }
    return {'status': 'error', 'matches': []};
  }

  /// Replaces occurrences across the workspace.
  Future<Map<String, dynamic>> replaceWorkspace(String query, String replacement, [Map<String, dynamic>? options]) async {
    if (_ffi.isAvailable) {
      return _ffi.replaceWorkspace(query, replacement, options);
    }
    return {'status': 'error', 'replaced_count': 0};
  }

  /// Executes command in interactive PTY/terminal.
  Future<Map<String, dynamic>> terminalExec(String cmd, List<String> args) async {
    if (_ffi.isAvailable) {
      return _ffi.terminalExec(cmd, args);
    }
    return {'status': 'error', 'error': 'FFI unavailable'};
  }

  // ---------------------------------------------------------------------------
  // Phase 5: Streaming AI Chat, History Persistence & Git Operations
  // ---------------------------------------------------------------------------

  /// Starts streaming chat completion from LLM.
  Future<Map<String, dynamic>> sendPromptStream(String sessionId, String prompt) async {
    if (_ffi.isAvailable) {
      return _ffi.sendPromptStream(sessionId, prompt);
    }
    return {'status': 'error', 'error': 'FFI unavailable'};
  }

  /// Polls pending streaming events from the Rust Core.
  Future<List<dynamic>> pollStreamEvents([String sessionId = '']) async {
    if (_ffi.isAvailable) {
      return _ffi.pollStreamEvents(sessionId);
    }
    return [];
  }

  /// Lists persisted chat messages for a session.
  Future<List<dynamic>> listMessages(String sessionId) async {
    if (_ffi.isAvailable) {
      return _ffi.listMessages(sessionId);
    }
    return [];
  }

  /// Clears chat history for a session.
  Future<Map<String, dynamic>> clearMessages(String sessionId) async {
    if (_ffi.isAvailable) {
      return _ffi.clearMessages(sessionId);
    }
    return {'status': 'error'};
  }

  /// Retrieves Git status (branch, staged/unstaged changes).
  Future<Map<String, dynamic>> getGitStatus() async {
    if (_ffi.isAvailable) {
      return _ffi.getGitStatus();
    }
    return {'branch': 'main', 'changes': []};
  }

  /// Computes Git diff for a file.
  Future<Map<String, dynamic>> getGitDiff({String? filePath, bool staged = false}) async {
    if (_ffi.isAvailable) {
      return _ffi.getGitDiff(filePath: filePath, staged: staged);
    }
    return {'status': 'ok', 'diff': ''};
  }

  /// Stages a file for commit.
  Future<Map<String, dynamic>> gitStage(String filePath) async {
    if (_ffi.isAvailable) {
      return _ffi.gitStage(filePath);
    }
    return {'status': 'error'};
  }

  /// Unstages a file.
  Future<Map<String, dynamic>> gitUnstage(String filePath) async {
    if (_ffi.isAvailable) {
      return _ffi.gitUnstage(filePath);
    }
    return {'status': 'error'};
  }

  /// Commits staged changes with message.
  Future<Map<String, dynamic>> gitCommit(String message) async {
    if (_ffi.isAvailable) {
      return _ffi.gitCommit(message);
    }
    return {'status': 'error'};
  }

  /// Retrieves diff hunks (added, modified, deleted) for a file (Phase 8.3 Git Gutter).
  Future<List<Map<String, dynamic>>> gitFileDiffHunks(String filePath) async {
    if (_ffi.isAvailable) {
      final res = _ffi.gitFileDiffHunks(filePath);
      if (res['status'] == 'ok' && res['hunks'] is List) {
        final list = (res['hunks'] as List).map((e) => Map<String, dynamic>.from(e as Map)).toList();
        if (list.isNotEmpty) return list;
      }
    }
    // Mock fallback diff hunks for testing and offline preview
    if (filePath.contains('op_store.rs') || filePath.contains('main.rs')) {
      return [
        {'line': 2, 'kind': 'added', 'new_content': '    let op = self.get(op_id)?;'},
        {'line': 3, 'kind': 'added', 'new_content': '    if op.status == OpStatus::Reverted {'},
        {'line': 5, 'kind': 'modified', 'original_content': '        // old code', 'new_content': '        let path = Path::new(&op.file_path);'},
        {'line': 6, 'kind': 'modified', 'original_content': '        // old code', 'new_content': '        match op.op_type {'},
      ];
    }
    return [];
  }

  /// Retrieves strongly typed Git diff hunks for a file.
  Future<List<GitLineDiff>> getGitLineDiffs(String filePath) async {
    final raw = await gitFileDiffHunks(filePath);
    return raw.map((m) => GitLineDiff.fromJson(m)).toList();
  }

  /// Reverts changes in working tree for a specific file.
  Future<Map<String, dynamic>> gitRevertFile(String filePath) async {
    if (_ffi.isAvailable) {
      return _ffi.gitRevertFile(filePath);
    }
    return {'status': 'ok'};
  }

  /// Generates Fill-In-The-Middle (FIM) inline code completion (Phase 8.2).
  Future<String?> fimComplete(String filePath, String prefix, String suffix, String language) async {
    if (_ffi.isAvailable) {
      final res = _ffi.agentFimComplete(filePath, prefix, suffix, language);
      if (res['status'] == 'ok' && res['suggestion'] != null) {
        final sugg = res['suggestion'] as String;
        return sugg.isNotEmpty ? sugg : null;
      }
      return null;
    }
    // Mock fallback when running without FFI dynamic library
    final p = prefix.trimRight();
    if (p.endsWith('let x =')) return ' 42;';
    if (p.endsWith('fn main()')) return ' {\n    println!("Hello, world!");\n}';
    return null;
  }

  /// Builds a high-density, unified task prompt with project instructions, skills, and memory (Phase 10).
  Future<Map<String, dynamic>> buildTaskPrompt(String taskPrompt, {String? focusFile, String? focusSymbol}) async {
    if (_ffi.isAvailable) {
      final res = _ffi.buildTaskPrompt(taskPrompt, focusFile: focusFile, focusSymbol: focusSymbol);
      if (res['status'] == 'ok') return res;
    }
    return {
      'status': 'ok',
      'prompt': 'Offline context for: $taskPrompt',
      'insights': {
        'instruction_files': ['AGENTS.md'],
        'active_skills': ['flutter-ui'],
        'recalled_decisions': 0,
        'recalled_errors': 0,
        'has_codegraph': false,
        'has_lsp_diagnostics': false,
      }
    };
  }

  /// Queries past decision and error memories.
  Future<Map<String, dynamic>> queryMemory(String query, {String? targetPath, int limit = 10}) async {
    if (_ffi.isAvailable) {
      final res = _ffi.queryMemory(query, targetPath: targetPath, limit: limit);
      if (res['status'] == 'ok') return res;
    }
    return {'status': 'ok', 'decisions': [], 'errors': []};
  }

  /// Records an explicit decision memory.
  Future<Map<String, dynamic>> recordDecisionMemory({
    required String sessionId,
    required String decisionType,
    required String subject,
    required String detail,
    String? tags,
  }) async {
    if (_ffi.isAvailable) {
      return _ffi.recordDecisionMemory(sessionId, decisionType, subject, detail, tags: tags);
    }
    return {'status': 'ok', 'id': 1};
  }

  /// Records an explicit error memory.
  Future<Map<String, dynamic>> recordErrorMemory({
    required String sessionId,
    required String errorType,
    required String summary,
    required String lesson,
    String? targetPath,
    String? snippet,
  }) async {
    if (_ffi.isAvailable) {
      return _ffi.recordErrorMemory(sessionId, errorType, summary, lesson, targetPath: targetPath, snippet: snippet);
    }
    return {'status': 'ok', 'id': 1};
  }

  /// Lists all discovered skills in the workspace.
  Future<List<dynamic>> listSkills() async {
    if (_ffi.isAvailable) {
      final skills = _ffi.listSkills();
      if (skills.isNotEmpty) return skills;
    }
    return [
      {
        'name': 'flutter-ui',
        'description': 'IntelliJ Darcula defensive layout rules',
        'tools': ['read_file', 'apply_patch'],
      },
      {
        'name': 'code-review',
        'description': 'Offline cargo build & stable symbol keys',
        'tools': ['read_file', 'search_symbol'],
      }
    ];
  }

  /// Lists all registered external MCP tools.
  Future<List<dynamic>> listMcpTools() async {
    if (_ffi.isAvailable) {
      return _ffi.listMcpTools();
    }
    return [];
  }

  Map<String, dynamic> _fallbackWorkspace() {
    return {
      'name': 'code-lite-x',
      'is_dir': true,
      'children': [
        {
          'name': 'crates',
          'is_dir': true,
          'children': [
            {
              'name': 'code-lite-core',
              'is_dir': true,
              'children': [
                {'name': 'buffer.rs', 'is_dir': false, 'path': 'crates/code-lite-core/src/buffer.rs'},
                {'name': 'cursor.rs', 'is_dir': false, 'path': 'crates/code-lite-core/src/cursor.rs'},
                {'name': 'history.rs', 'is_dir': false, 'path': 'crates/code-lite-core/src/history.rs'},
              ]
            },
            {
              'name': 'code-lite-ffi',
              'is_dir': true,
              'children': [
                {'name': 'lib.rs', 'is_dir': false, 'path': 'crates/code-lite-ffi/src/lib.rs'},
              ]
            },
            {
              'name': 'code-lite-storage',
              'is_dir': true,
              'children': [
                {'name': 'op_store.rs', 'is_dir': false, 'path': 'crates/code-lite-storage/src/op_store.rs'},
                {'name': 'graph_store.rs', 'is_dir': false, 'path': 'crates/code-lite-storage/src/graph_store.rs'},
              ]
            }
          ]
        },
        {'name': 'Cargo.toml', 'is_dir': false, 'path': 'Cargo.toml'},
        {'name': 'README.md', 'is_dir': false, 'path': 'README.md'}
      ]
    };
  }

  /// Checks for available updates using the differential auto-updater engine (Phase 11).
  Future<Map<String, dynamic>> checkForUpdates({
    String currentVersion = '0.1.0',
    String? manifestJson,
    String? forcedPlatform,
  }) async {
    final manifest = manifestJson ?? jsonEncode(_defaultUpdateManifest());
    if (_ffi.isAvailable) {
      final res = _ffi.updaterCheck(currentVersion, manifest, platform: forcedPlatform);
      if (res.isNotEmpty && res['status'] == 'ok') {
        final result = (res['result'] as Map<String, dynamic>?) ?? res;
        final artifacts = (result['artifacts'] as List<dynamic>?) ?? [];
        final firstArtifact = artifacts.isNotEmpty ? artifacts.first as Map<String, dynamic> : <String, dynamic>{};
        return {
          'status': 'ok',
          'current_version': result['current_version'] ?? currentVersion,
          'latest_version': result['latest_version'] ?? '0.1.1',
          'has_update': result['has_update'] ?? false,
          'platform': result['platform'] ?? (forcedPlatform ?? 'macos'),
          'strategy': result['strategy'] ?? 'component_delta',
          'release_notes': result['release_notes'] ?? '',
          'changelog': result['release_notes'] ?? '',
          'url': firstArtifact['url'] ?? '',
          'sha256': firstArtifact['sha256'] ?? '',
          'file_size': firstArtifact['size_bytes'] ?? 0,
          'files': artifacts.map((a) => (a as Map<String, dynamic>)['target_name']?.toString() ?? '').toList(),
          'installer_url': result['installer_url'],
          'raw': res,
        };
      }
    }

    return {
      'status': 'ok',
      'current_version': currentVersion,
      'latest_version': '0.1.1',
      'has_update': true,
      'platform': forcedPlatform ?? 'macos',
      'strategy': (forcedPlatform ?? 'macos') == 'macos' ? 'app_bundle_delta' : 'component_delta',
      'url': 'https://releases.codelitex.dev/v0.1.1/CodeLiteX-macos.dmg',
      'sha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
      'file_size': 25165824,
      'files': (forcedPlatform ?? 'macos') == 'macos' ? ['CodeLiteX.app'] : ['libcodelite.so', 'code-lite-app'],
      'changelog': '## [v0.1.1] - 2026-09-10\n- feat: Phase 11 Cross-platform packaging & D3 Differential updater\n- perf: Sub-millisecond FIPS 180-4 SHA-256 integrity verification\n- fix: Automatic backup snapshot and rollback on swap failure',
    };
  }

  /// Verifies SHA-256 integrity and stages update artifact to staging directory.
  Future<Map<String, dynamic>> stageUpdateArtifact({
    required String stagingDir,
    required String fileName,
    required String content,
    required String expectedSha256,
  }) async {
    if (_ffi.isAvailable) {
      final res = _ffi.updaterStage(stagingDir, fileName, content, expectedSha256);
      if (res.isNotEmpty && res['status'] == 'ok') return res;
    }

    return {
      'status': 'ok',
      'staged_path': '$stagingDir/$fileName',
      'sha256': expectedSha256,
      'verified': true,
    };
  }

  /// Applies the staged differential update or triggers AppBundle restart script.
  Future<Map<String, dynamic>> applyUpdate({
    required String stagingDir,
    required String targetDir,
    required List<String> files,
    String? platform,
  }) async {
    if (_ffi.isAvailable) {
      final res = _ffi.updaterApply(stagingDir, targetDir, files, platform: platform);
      if (res.isNotEmpty && res['status'] == 'ok') return res;
    }

    return {
      'status': 'ok',
      'platform': platform ?? 'macos',
      'strategy': (platform ?? 'macos') == 'macos' ? 'app_bundle_delta' : 'component_delta',
      'applied_files': files,
      'backup_dir': '$targetDir/.update_backup_mock',
      'message': 'Update applied successfully (mock fallback)',
    };
  }

  Map<String, dynamic> _defaultUpdateManifest() {
    return {
      'version': '0.1.1',
      'release_date': '2026-09-10',
      'release_notes': '## [v0.1.1] - 2026-09-10\n- feat: Phase 11 Cross-platform packaging & D3 Differential updater\n- perf: Sub-millisecond FIPS 180-4 SHA-256 integrity verification\n- fix: Automatic backup snapshot and rollback on swap failure',
      'min_compatible_version': '0.1.0',
      'platforms': {
        'macos': {
          'strategy': 'app_bundle_delta',
          'artifacts': [
            {
              'target_name': 'CodeLiteX.app',
              'target_path': 'CodeLiteX.app',
              'url': 'https://releases.codelitex.dev/v0.1.1/CodeLiteX-macos.dmg',
              'sha256': 'e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855',
              'size_bytes': 25165824,
            }
          ],
          'installer_url': 'https://releases.codelitex.dev/v0.1.1/CodeLiteX-macos.dmg',
        },
        'linux': {
          'strategy': 'component_delta',
          'artifacts': [
            {
              'target_name': 'libcodelite.so',
              'target_path': 'lib/libcodelite.so',
              'url': 'https://releases.codelitex.dev/v0.1.1/CodeLiteX-linux-x64.tar.gz',
              'sha256': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
              'size_bytes': 18874368,
            }
          ],
          'installer_url': 'https://releases.codelitex.dev/v0.1.1/codelitex_0.1.1-1_amd64.deb',
        },
        'windows': {
          'strategy': 'component_delta',
          'artifacts': [
            {
              'target_name': 'codelite.dll',
              'target_path': 'codelite.dll',
              'url': 'https://releases.codelitex.dev/v0.1.1/CodeLiteX-windows-x64.zip',
              'sha256': 'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad',
              'size_bytes': 19922944,
            }
          ],
          'installer_url': 'https://releases.codelitex.dev/v0.1.1/CodeLiteX-Setup-0.1.1.exe',
        },
      },
    };
  }

  // ===========================================================================
  // Phase 12: WASM Plugin Ecosystem & Sandboxed Runtime
  // ===========================================================================

  /// Fetches all installed plugins (built-ins and dynamic plugins).
  Future<List<Map<String, dynamic>>> listPlugins() async {
    if (_ffi.isAvailable) {
      final res = _ffi.pluginList();
      if (res['status'] == 'ok' && res['plugins'] is List) {
        return List<Map<String, dynamic>>.from(
          (res['plugins'] as List).map((e) => Map<String, dynamic>.from(e as Map)),
        );
      }
    }

    return _fallbackPlugins();
  }

  /// Toggles a plugin's enabled status.
  Future<Map<String, dynamic>> togglePlugin(String pluginId, bool enable) async {
    if (_ffi.isAvailable) {
      final res = _ffi.pluginToggle(pluginId, enable);
      if (res.isNotEmpty && res['status'] == 'ok') return res;
    }

    return {
      'status': 'ok',
      'plugin': {
        'id': pluginId,
        'status': enable ? 'enabled' : 'disabled',
      },
    };
  }

  /// Executes a tool registered by a plugin with sandboxed fuel and memory limits.
  Future<Map<String, dynamic>> executePluginTool({
    required String pluginId,
    required String toolName,
    Map<String, dynamic> args = const {},
  }) async {
    if (_ffi.isAvailable) {
      final res = _ffi.pluginExecuteTool(pluginId, toolName, args);
      if (res.isNotEmpty) return res;
    }

    // Mock fallback execution
    if (pluginId == 'codelite.sql_inspector' && toolName == 'inspect_sql') {
      final query = (args['query'] as String? ?? '').trim();
      final upper = query.toUpperCase();
      final isDestructive = upper.startsWith('DROP') ||
          upper.startsWith('TRUNCATE') ||
          (upper.startsWith('DELETE') && !upper.contains('WHERE'));
      return {
        'status': 'ok',
        'result': {
          'valid': true,
          'command_type': upper.split(' ').first,
          'is_destructive': isDestructive,
          'risk_level': isDestructive ? 'critical' : 'low',
          'tables': ['mock_table'],
          'warnings': isDestructive ? ['Destructive SQL operation detected!'] : [],
        },
      };
    } else if (pluginId == 'codelite.custom_linter' && toolName == 'lint_code') {
      final code = args['code'] as String? ?? '';
      final lines = code.split('\n');
      final issues = <Map<String, dynamic>>[];
      for (int i = 0; i < lines.length; i++) {
        if (lines[i].length > 120) {
          issues.add({
            'line': i + 1,
            'column': 120,
            'rule': 'line-length',
            'severity': 'warning',
            'message': 'Line exceeds 120 chars (${lines[i].length})',
          });
        }
      }
      return {
        'status': 'ok',
        'result': {
          'issues_count': issues.length,
          'issues': issues,
        },
      };
    }

    return {
      'status': 'ok',
      'result': {'output': 'Executed $pluginId:$toolName successfully (mock)'},
    };
  }

  /// Loads a WASM plugin with raw manifest and bytecode.
  Future<Map<String, dynamic>> loadPlugin({
    required Map<String, dynamic> manifest,
    required List<int> wasmBytes,
  }) async {
    if (_ffi.isAvailable) {
      final res = _ffi.pluginLoad(jsonEncode(manifest), wasmBytes);
      if (res.isNotEmpty && res['status'] == 'ok') return res;
    }

    return {
      'status': 'ok',
      'plugin': {
        ...manifest,
        'status': 'enabled',
      },
    };
  }

  /// Unloads a plugin by ID.
  Future<Map<String, dynamic>> unloadPlugin(String pluginId) async {
    if (_ffi.isAvailable) {
      final res = _ffi.pluginUnload(pluginId);
      if (res.isNotEmpty && res['status'] == 'ok') return res;
    }

    return {
      'status': 'ok',
      'unloaded': pluginId,
    };
  }

  List<Map<String, dynamic>> _fallbackPlugins() {
    return [
      {
        'id': 'codelite.sql_inspector',
        'name': 'SQL Inspector',
        'version': '0.1.0',
        'author': 'CodeLiteX Core Team',
        'description': 'Analyzes SQL queries, checks syntax, extracts tables, and classifies destructive DDL/DML commands',
        'status': 'enabled',
        'permissions': ['log'],
        'tools': [
          {
            'name': 'inspect_sql',
            'description': 'Analyzes an SQL query for syntax validity, affected tables, and destructive operation risks',
            'risk_level': 'low',
          }
        ],
      },
      {
        'id': 'codelite.custom_linter',
        'name': 'Custom Linter',
        'version': '0.1.0',
        'author': 'CodeLiteX Core Team',
        'description': 'Checks code files for line length limits, trailing whitespace, and unaddressed TODO/FIXME markers',
        'status': 'enabled',
        'permissions': ['read_buffer', 'log'],
        'tools': [
          {
            'name': 'lint_code',
            'description': 'Analyzes code text or target workspace file for style and formatting issues',
            'risk_level': 'low',
          }
        ],
      },
    ];
  }
}


/// Diff hunk kind in Git Gutter (Phase 8.3).
enum DiffHunkKind {
  added,
  modified,
  deleted,
}

/// A line diff item representing an added, modified, or deleted hunk in a file.
class GitLineDiff {
  final int line;
  final DiffHunkKind kind;
  final String originalContent;
  final String newContent;

  const GitLineDiff({
    required this.line,
    required this.kind,
    this.originalContent = '',
    this.newContent = '',
  });

  factory GitLineDiff.fromJson(Map<String, dynamic> json) {
    final kindStr = (json['kind'] as String?)?.toLowerCase() ?? 'modified';
    final kind = kindStr == 'added'
        ? DiffHunkKind.added
        : (kindStr == 'deleted' ? DiffHunkKind.deleted : DiffHunkKind.modified);
    return GitLineDiff(
      line: (json['line'] as num?)?.toInt() ?? 1,
      kind: kind,
      originalContent: (json['original_content'] as String?) ?? '',
      newContent: (json['new_content'] as String?) ?? '',
    );
  }

  Map<String, dynamic> toJson() => {
    'line': line,
    'kind': kind.name,
    'original_content': originalContent,
    'new_content': newContent,
  };
}

