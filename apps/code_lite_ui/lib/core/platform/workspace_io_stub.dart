import 'dart:typed_data';

import '../l10n/l10n.dart';

// web 没有 dart:io:文件夹选择与最近项目都不可用,调用方按"不支持"处理。

Future<String?> pickDirectory() async => null;

Future<String?> createEmptyFile(String root, String relPath) async => tr('web 预览不支持创建文件', 'Creating files is not supported in the web preview');

Future<String?> pickProject() async => null;

Future<String?> renamePath(String from, String to) async => tr('web 预览不支持改名', 'Renaming is not supported in the web preview');

Future<bool> directoryExists(String path) async => false;

Future<bool> fileExists(String path) async => false;

Stream<String> watchFiles(String root) => const Stream.empty();

Future<Map<String, dynamic>> loadOpenProjects() async => const {};

Future<void> saveOpenProjects(Map<String, dynamic> state) async {}

/// 读文件的原始字节(预览里的本地图片);读不了返回 null。
Future<Uint8List?> readFileBytes(String path, {int maxBytes = 20 * 1024 * 1024}) async => null;

Future<Map<String, dynamic>> loadSessions() async => const {};

Future<void> saveSessions(Map<String, dynamic> sessions) async {}

Future<List<String>> loadRecentProjects() async => const [];

Future<void> saveRecentProjects(List<String> paths) async {}

String noProjectRoot() => '.';

Future<String?> pickSavePath(String suggestedName) async => null;

Future<String?> pickFile({String? message, String? directory}) async => null;

Future<(String?, String?)> detectMake(String path) async => (null, tr('浏览器里不能运行 make', 'make cannot run in the browser'));

Future<String?> writeTextFile(String path, String content) async => tr('web 预览不支持写文件', 'Writing files is not supported in the web preview');

Future<Map<String, dynamic>> loadSettings() async => const {};

Future<void> saveSettings(Map<String, dynamic> settings) async {}

String? homeDirectory() => null;

String repositoryNameFromUrl(String url) => '';

Future<(String?, String?)> cloneRepository(String url, String parentDir, {String? name}) async =>
    (null, tr('web 预览不支持克隆', 'Cloning is not supported in the web preview'));

Future<(String?, String?)> createProject(String parentDir, String name) async => (null, tr('web 预览不支持新建项目', 'Creating projects is not supported in the web preview'));
