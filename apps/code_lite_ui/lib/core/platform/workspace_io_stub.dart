// web 没有 dart:io:文件夹选择与最近项目都不可用,调用方按"不支持"处理。

Future<String?> pickDirectory() async => null;

Future<String?> createEmptyFile(String root, String relPath) async => 'web 预览不支持创建文件';

Future<bool> directoryExists(String path) async => false;

Future<bool> fileExists(String path) async => false;

Future<Map<String, dynamic>> loadSessions() async => const {};

Future<void> saveSessions(Map<String, dynamic> sessions) async {}

Future<List<String>> loadRecentProjects() async => const [];

Future<void> saveRecentProjects(List<String> paths) async {}

String noProjectRoot() => '.';

Future<String?> pickSavePath(String suggestedName) async => null;

Future<String?> writeTextFile(String path, String content) async => 'web 预览不支持写文件';

Future<Map<String, dynamic>> loadSettings() async => const {};

Future<void> saveSettings(Map<String, dynamic> settings) async {}

String? homeDirectory() => null;

String repositoryNameFromUrl(String url) => '';

Future<(String?, String?)> cloneRepository(String url, String parentDir, {String? name}) async =>
    (null, 'web 预览不支持克隆');

Future<(String?, String?)> createProject(String parentDir, String name) async => (null, 'web 预览不支持新建项目');
