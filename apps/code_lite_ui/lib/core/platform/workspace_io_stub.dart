// web 没有 dart:io:文件夹选择与最近项目都不可用,调用方按"不支持"处理。

Future<String?> pickDirectory() async => null;

Future<String?> createEmptyFile(String root, String relPath) async => 'web 预览不支持创建文件';

Future<bool> directoryExists(String path) async => false;

Future<List<String>> loadRecentProjects() async => const [];

Future<void> saveRecentProjects(List<String> paths) async {}

String noProjectRoot() => '.';

Future<String?> pickSavePath(String suggestedName) async => null;

Future<String?> writeTextFile(String path, String content) async => 'web 预览不支持写文件';
