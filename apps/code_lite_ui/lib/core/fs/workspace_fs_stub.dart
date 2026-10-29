// web 没有 dart:io:文件树由 ApiClient 的演示数据兜底,搜索 / 替换不可用。

import '../l10n/l10n.dart';

Future<Map<String, dynamic>> scanTree(String root, {int maxDepth = 4}) async => const {};

Future<Map<String, dynamic>> listDirectory(String path, {int depth = 2}) async => const {};

Future<Map<String, dynamic>> searchWorkspace(String root, String query, [Map<String, dynamic>? options]) async =>
    {'status': 'error', 'error': tr('web 预览不支持全局搜索', 'Find in Files is not supported in the web preview')};

Future<Map<String, dynamic>> replaceWorkspace(
  String root,
  String query,
  String replacement, [
  Map<String, dynamic>? options,
]) async =>
    {'status': 'error', 'error': tr('web 预览不支持全局替换', 'Replace in Files is not supported in the web preview')};

Future<Map<String, dynamic>> readTextFile(String root, String relPath) async =>
    {'status': 'error', 'error': tr('web 预览不支持读取文件', 'Reading files is not supported in the web preview')};

Future<Map<String, dynamic>> writeTextFile(String root, String relPath, String content) async =>
    {'status': 'error', 'error': tr('web 预览不支持保存文件', 'Saving files is not supported in the web preview')};

Future<Map<String, dynamic>> searchWorkspaceInDart(String root, String query, [Map<String, dynamic>? options]) =>
    searchWorkspace(root, query, options);

Future<Map<String, dynamic>> replaceWorkspaceInDart(String root, String query, String replacement, [Map<String, dynamic>? options]) =>
    replaceWorkspace(root, query, replacement, options);
