// 由 tool/gen_bindings_stub.dart 的等价脚本生成 —— 请勿手改。
//
// web 目标没有 dart:ffi / dart:io,所以 codelite_bindings.dart 编不过。
// 这个桩提供同名同签名的 CodeLiteBindings,isAvailable 恒为 false,
// 每个方法返回真实实现里 `if (!isAvailable) return ...` 那个值。
//
// api_client.dart 通过条件导入选择二者之一:web 拿桩,原生拿真实现。
// 结果是 web 版一路走 api_client 自己的 mock 兜底,不发任何 FFI 或 HTTP。
//
// 只覆盖 api_client 实际调用的成员;jsonRpcCall 带 Pointer<Void>,
// 而它唯一的调用方 core_api_client.dart 不在 web 构建的导入链里,故不包含。

class CodeLiteBindings {
  CodeLiteBindings._();

  static final CodeLiteBindings instance = CodeLiteBindings._();

  /// web 上永远没有原生库。
  bool get isAvailable => false;

  Map<String, dynamic> agentApproveStep(String requestId, bool approved) => {};

  Map<String, dynamic> agentExecuteNextStep(String planId) => {};

  Map<String, dynamic> agentFimComplete(String filePath, String prefix, String suffix, String language) => {};

  Map<String, dynamic> agentGetDiffReview(String sessionId) => {};

  Map<String, dynamic> agentGetPendingApprovals([String? sessionId]) => {};

  Map<String, dynamic> agentPlanMultiFile(String sessionId, Map<String, dynamic> params) => {};

  Map<String, dynamic> agentPlanTask(String sessionId, Map<String, dynamic> params) => {};

  Map<String, dynamic> agentRollbackStep(String planId, String stepId) => {};

  Map<String, dynamic> buildTaskPrompt(String taskPrompt, {String? focusFile, String? focusSymbol}) => {};

  Map<String, dynamic> clearMessages(String sessionId) => {'status': 'error'};

  Map<String, dynamic> editFile(String relPath, Map<String, dynamic> editPayload) => {};

  List<dynamic> fetchEvents() => [];

  List<dynamic> fetchSymbols([String query = '']) => [];

  List<dynamic> findCallees(String query) => [];

  List<dynamic> findCallers(String query) => [];

  List<dynamic> findDefinition(String query) => [];

  List<dynamic> findReferences(String query) => [];

  Map<String, dynamic> getCodeContext(String query) => {};

  Map<String, dynamic> getGitDiff({String? filePath, bool staged = false}) => {'status': 'error', 'diff': ''};

  Map<String, dynamic> getGitStatus() => {'branch': 'HEAD', 'changes': []};

  Map<String, dynamic> getViewportTokens(String filePath, int startLine, int endLine) => {'status': 'error', 'lines': []};

  Map<String, dynamic> gitCommit(String message) => {'status': 'error'};

  Map<String, dynamic> gitFileDiffHunks(String filePath) => {'status': 'error', 'hunks': []};

  Map<String, dynamic> gitRevertFile(String filePath) => {'status': 'error'};

  Map<String, dynamic> gitStage(String filePath) => {'status': 'error'};

  Map<String, dynamic> gitUnstage(String filePath) => {'status': 'error'};

  Map<String, dynamic> indexFile(String relPath) => {};

  bool initialize([String workspacePath = '.']) => false;

  List<dynamic> listMcpTools() => [];

  List<dynamic> listMessages(String sessionId) => [];

  List<dynamic> listSkills() => [];

  List<dynamic> lspCompletion(String filePath, int line, int col) => [];

  List<dynamic> lspDidChange(String filePath, int version, String content) => [];

  List<dynamic> lspDidOpen(String filePath, String language, String content) => [];

  List<dynamic> lspFindReferences(String filePath, int line, int col, {bool includeDecl = true}) => [];

  List<dynamic> lspGetDiagnostics(String filePath) => [];

  List<dynamic> lspGotoDefinition(String filePath, int line, int col) => [];

  Map<String, dynamic>? lspHover(String filePath, int line, int col) => null;

  Map<String, dynamic>? lspRename(String filePath, int line, int col, String newName) => null;

  Map<String, dynamic> openFile(String relPath) => {};

  List<dynamic> pollStreamEvents([String sessionId = '']) => [];

  Map<String, dynamic> queryMemory(String query, {String? targetPath, int limit = 10}) => {'status': 'error', 'decisions': [], 'errors': []};

  List<dynamic> queryOutline(String relPath) => [];

  Map<String, dynamic> recordDecisionMemory(String sessionId, String decisionType, String subject, String detail, {String? tags}) => {'status': 'error'};

  Map<String, dynamic> recordErrorMemory(String sessionId, String errorType, String summary, String lesson, {String? targetPath, String? snippet}) => {'status': 'error'};

  Map<String, dynamic> redo(String relPath) => {};

  Map<String, dynamic> replaceWorkspace(String query, String replacement, [Map<String, dynamic>? options]) => {'status': 'error', 'replaced_count': 0};

  Map<String, dynamic> restoreAgent(String sessionId) => {};

  Map<String, dynamic> rollbackAgent(String sessionId, int targetStepId) => {};

  Map<String, dynamic> saveFile(String relPath) => {};

  Map<String, dynamic> scanWorkspace({int maxDepth = 4}) => {};

  Map<String, dynamic> searchWorkspace(String query, [Map<String, dynamic>? options]) => {'status': 'error', 'matches': []};

  Map<String, dynamic> sendAgentPrompt(String sessionId, String prompt) => {};

  Map<String, dynamic> sendPromptStream(String sessionId, String prompt) => {'status': 'error', 'error': 'FFI unavailable'};

  Map<String, dynamic> setFileCursor(String relPath, int line, int col, {bool select = false}) => {};

  Map<String, dynamic> terminalExec(String cmd, List<String> args) => {'status': 'error', 'error': 'Bindings unavailable'};

  Map<String, dynamic> undo(String relPath) => {};

  Map<String, dynamic> updaterApply(String stagingDir, String targetDir, List<String> files, {String? platform}) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> updaterCheck(String currentVersion, String manifestJson, {String? platform}) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> updaterStage(String stagingDir, String fileName, String content, String expectedSha256) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> worktreeCreate(String taskId) => {};

  Map<String, dynamic> worktreeDiscard(String taskId) => {};

  Map<String, dynamic> worktreeMerge(String taskId) => {};
}
