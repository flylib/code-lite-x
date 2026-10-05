import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';

const _dialogs = MethodChannel('codelitex/dialogs');

/// 弹出系统"选择文件夹"面板(macOS 为 NSOpenPanel)。取消返回 null。
Future<String?> pickDirectory() async {
  try {
    return await _dialogs.invokeMethod<String>('pickDirectory');
  } on MissingPluginException {
    return null;
  }
}

/// 弹出系统"存储为"面板。取消返回 null。
Future<String?> pickSavePath(String suggestedName) async {
  try {
    return await _dialogs.invokeMethod<String>('pickSavePath', {'name': suggestedName});
  } on MissingPluginException {
    return null;
  }
}

/// 写文本文件。成功返回 null,失败返回原因。
Future<String?> writeTextFile(String path, String content) async {
  try {
    await File(path).writeAsString(content);
    return null;
  } on FileSystemException catch (e) {
    return e.osError?.message ?? e.message;
  }
}

/// 在 [root] 下创建空文件 [relPath](自动补父目录)。成功返回 null,失败返回原因。
Future<String?> createEmptyFile(String root, String relPath) async {
  final file = File('$root/$relPath');
  if (await file.exists() || await Directory(file.path).exists()) {
    return '已存在: $relPath';
  }
  try {
    await file.create(recursive: true);
    return null;
  } on FileSystemException catch (e) {
    return e.osError?.message ?? e.message;
  }
}

Future<bool> directoryExists(String path) => Directory(path).exists();

File? get _recentFile {
  final home = Platform.environment['HOME'];
  return home == null ? null : File('$home/.codelitex/recent_projects.json');
}

Future<List<String>> loadRecentProjects() async {
  try {
    final f = _recentFile;
    if (f == null || !await f.exists()) return const [];
    final decoded = jsonDecode(await f.readAsString());
    return decoded is List ? decoded.whereType<String>().toList() : const [];
  } catch (_) {
    return const [];
  }
}

Future<void> saveRecentProjects(List<String> paths) async {
  try {
    final f = _recentFile;
    if (f == null) return;
    await f.parent.create(recursive: true);
    await f.writeAsString(jsonEncode(paths));
  } catch (_) {
    // 最近项目只是便利功能,写失败不应打断用户。
  }
}

File? get _settingsFile {
  final home = Platform.environment['HOME'];
  return home == null ? null : File('$home/.codelitex/settings.json');
}

/// 应用设置(自动保存、编辑器外观);读不到时为空表,按默认值处理。
Future<Map<String, dynamic>> loadSettings() async {
  try {
    final f = _settingsFile;
    if (f == null || !await f.exists()) return const {};
    final decoded = jsonDecode(await f.readAsString());
    return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
  } catch (_) {
    return const {};
  }
}

Future<void> saveSettings(Map<String, dynamic> settings) async {
  try {
    final f = _settingsFile;
    if (f == null) return;
    await f.parent.create(recursive: true);
    await f.writeAsString(const JsonEncoder.withIndent('  ').convert(settings));
  } catch (_) {
    // 写不了设置不应打断用户;下次启动用默认值。
  }
}

/// 没打开任何项目时 Rust Core 挂靠的中性目录。
/// 不能用 '.':从 Finder 启动时 cwd 是 "/",Rust 侧初始化会去扫描整个磁盘。
String noProjectRoot() {
  final home = Platform.environment['HOME'];
  if (home == null) return Directory.systemTemp.path;
  final dir = Directory('$home/.codelitex/no-project');
  dir.createSync(recursive: true);
  return dir.path;
}
