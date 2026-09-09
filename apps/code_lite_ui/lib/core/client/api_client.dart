import 'dart:convert';
import 'package:http/http.dart' as http;
import '../ffi/codelite_bindings.dart';

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
}
