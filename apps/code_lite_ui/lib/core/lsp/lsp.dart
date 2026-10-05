// web 没有 dart:io(起不了语言服务端进程):拿只做降级的桩,原生拿真实现。两者类名与签名一致。
export 'lsp_common.dart' show LspDiagnosticsEvent, LspTextChange, LspLaunch, LspLaunchResolver;
export 'lsp_service_stub.dart' if (dart.library.io) 'lsp_service.dart';
