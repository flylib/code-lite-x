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

  bool initialize([String workspacePath = '.']) => false;

  bool reinitialize(String workspacePath) => false;

  Map<String, dynamic> terminalExec(String cmd, List<String> args) => {'status': 'error', 'error': 'Bindings unavailable'};

  Map<String, dynamic> ptyOpen(int rows, int cols) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> ptyWrite(String id, String data) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> ptyResize(String id, int rows, int cols) => {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> ptySnapshot(String id, {int sinceSeq = -1, int scrollback = 0}) =>
      {'status': 'error', 'error': 'FFI not available'};

  Map<String, dynamic> ptyClose(String id) => {'status': 'error', 'error': 'FFI not available'};

}
