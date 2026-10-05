// web 预览用的桩:与 lsp_service.dart 同名同签名。web 起不了语言服务端进程,
// 只提供降级能力:括号诊断 + 正则大纲;status 不报告任何服务端。

import 'dart:async';

import 'lsp_common.dart';

export 'lsp_common.dart' show LspDiagnosticsEvent, LspTextChange;

class LspService {
  LspService(
    this.root, {
    Map<String, List<String>>? serverOverrides,
    this.requestTimeout = const Duration(seconds: 10),
    this.initializeTimeout = const Duration(seconds: 30),
  });

  final String root;
  final Duration requestTimeout;
  final Duration initializeTimeout;

  static const int maxRestarts = 3;

  final StreamController<LspDiagnosticsEvent> _events = StreamController<LspDiagnosticsEvent>.broadcast();
  final Set<String> _open = {};
  bool _disposed = false;

  Stream<LspDiagnosticsEvent> get diagnostics => _events.stream;

  static String? languageIdFor(String path) => lspLanguageIdFor(path);

  Future<void> didOpen(String relPath, String text) async {
    _open.add(relPath);
    _check(relPath, text);
  }

  Future<void> didChange(String relPath, String text) async {
    _open.add(relPath);
    _check(relPath, text);
  }

  /// web 没有语言服务器:返回 false,调用方改用整篇 [didChange]。
  Future<bool> didChangeIncremental(String relPath, List<LspTextChange> changes) async => false;

  Future<void> didClose(String relPath) async {
    if (_open.remove(relPath)) _emit(relPath, const []);
  }

  Future<List<Map<String, dynamic>>> documentSymbols(String relPath, String text) async {
    try {
      return lspRegexOutline(text, lspFallbackLanguageFor(relPath));
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  Future<Map<String, dynamic>> status() async => {'servers': <Map<String, dynamic>>[]};

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _events.close();
  }

  void _check(String relPath, String text) {
    final lang = lspFallbackLanguageFor(relPath);
    if (lang == null) return;
    try {
      _emit(relPath, lspBracketDiagnostics(text, lang));
    } catch (_) {}
  }

  void _emit(String relPath, List<Map<String, dynamic>> diagnostics) {
    if (_disposed || _events.isClosed) return;
    _events.add(LspDiagnosticsEvent(relPath, diagnostics));
  }
}
