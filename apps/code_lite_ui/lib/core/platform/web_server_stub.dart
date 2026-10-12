export 'web_content_types.dart';

/// web 预览没有 dart:io:没有内置服务器,HTML 按文件打开。
class BuiltInWebServer {
  BuiltInWebServer({required this.root, this.preferredPort = 63342});

  final String root;
  final int preferredPort;

  int? get port => null;

  Future<String?> urlFor(String filePath) async => null;

  Future<void> close() async {}
}
