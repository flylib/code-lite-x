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

  Map<String, dynamic> editFile(String relPath, Map<String, dynamic> editPayload) => {};

  List<dynamic> fetchSymbols([String query = '']) => [];

  List<dynamic> findCallees(String query) => [];

  List<dynamic> findCallers(String query) => [];

  List<dynamic> findDefinition(String query) => [];

  List<dynamic> findReferences(String query) => [];

  Map<String, dynamic> getCodeContext(String query) => {};

  Map<String, dynamic> getViewportTokens(String filePath, int startLine, int endLine) => {'status': 'error', 'lines': []};

  Map<String, dynamic> indexFile(String relPath) => {};

  bool initialize([String workspacePath = '.']) => false;

  bool reinitialize(String workspacePath) => false;

  List<dynamic> lspCompletion(String filePath, int line, int col) => [];

  List<dynamic> lspDidChange(String filePath, int version, String content) => [];

  List<dynamic> lspDidOpen(String filePath, String language, String content) => [];

  List<dynamic> lspFindReferences(String filePath, int line, int col, {bool includeDecl = true}) => [];

  List<dynamic> lspGetDiagnostics(String filePath) => [];

  List<dynamic> lspGotoDefinition(String filePath, int line, int col) => [];

  Map<String, dynamic>? lspHover(String filePath, int line, int col) => null;

  Map<String, dynamic>? lspRename(String filePath, int line, int col, String newName) => null;

  Map<String, dynamic> openFile(String relPath) => {};

  List<dynamic> queryOutline(String relPath) => [];

  Map<String, dynamic> redo(String relPath) => {};

  Map<String, dynamic> saveFile(String relPath) => {};

  Map<String, dynamic> setFileCursor(String relPath, int line, int col, {bool select = false}) => {};

  Map<String, dynamic> terminalExec(String cmd, List<String> args) => {'status': 'error', 'error': 'Bindings unavailable'};

  Map<String, dynamic> ptyOpen(int rows, int cols) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> ptyWrite(String id, String data) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> ptyResize(String id, int rows, int cols) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> ptySnapshot(String id, {int sinceSeq = -1, int scrollback = 0}) =>
      {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> ptyClose(String id) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> undo(String relPath) => {};

  Map<String, dynamic> updaterApply(String stagingDir, String targetDir, List<String> files, {String? platform}) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> updaterCheck(String currentVersion, String manifestJson, {String? platform}) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> updaterStage(String stagingDir, String fileName, String content, String expectedSha256) => {'status': 'error', 'error': 'FFI not available'};

}
