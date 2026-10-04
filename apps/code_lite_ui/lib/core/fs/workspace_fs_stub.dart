// web 没有 dart:io:文件树由 ApiClient 的演示数据兜底,搜索 / 替换不可用。

Future<Map<String, dynamic>> scanTree(String root, {int maxDepth = 4}) async => const {};

Future<Map<String, dynamic>> searchWorkspace(String root, String query, [Map<String, dynamic>? options]) async =>
    const {'status': 'error', 'error': 'web 预览不支持全局搜索'};

Future<Map<String, dynamic>> replaceWorkspace(
  String root,
  String query,
  String replacement, [
  Map<String, dynamic>? options,
]) async =>
    const {'status': 'error', 'error': 'web 预览不支持全局替换'};
