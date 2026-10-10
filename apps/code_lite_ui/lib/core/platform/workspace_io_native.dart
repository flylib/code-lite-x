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

Future<bool> fileExists(String path) => File(path).exists();

/// 读文件的原始字节(预览里的本地图片);超过 [maxBytes] 或读不了返回 null。
Future<Uint8List?> readFileBytes(String path, {int maxBytes = 20 * 1024 * 1024}) async {
  try {
    final f = File(path);
    if (await f.length() > maxBytes) return null;
    return await f.readAsBytes();
  } catch (_) {
    return null;
  }
}

File? get _sessionsFile {
  final home = Platform.environment['HOME'];
  return home == null ? null : File('$home/.codelitex/sessions.json');
}

/// 各项目上次的打开状态(标签、光标、滚动),`~/.codelitex/sessions.json`。读不出来就当没有。
Future<Map<String, dynamic>> loadSessions() async {
  try {
    final f = _sessionsFile;
    if (f == null || !await f.exists()) return const {};
    final decoded = jsonDecode(await f.readAsString());
    return decoded is Map ? Map<String, dynamic>.from(decoded) : const {};
  } catch (_) {
    return const {};
  }
}

Future<void> saveSessions(Map<String, dynamic> sessions) async {
  try {
    final f = _sessionsFile;
    if (f == null) return;
    await f.parent.create(recursive: true);
    // 先写临时文件再改名:写到一半被杀掉也不会留下半个 JSON
    final tmp = File('${f.path}.tmp');
    await tmp.writeAsString(jsonEncode(sessions));
    await tmp.rename(f.path);
  } catch (_) {
    // 记不住上次的状态只是少个便利,不打断用户
  }
}

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

/// 当前用户的主目录;弹窗里的路径用它缩写成 `~`。
String? homeDirectory() => Platform.environment['HOME'];

/// 仓库地址最后一段去掉 `.git`:`git@github.com:a/b.git`、`https://x/y/z/` → `b`、`z`。
String repositoryNameFromUrl(String url) {
  var u = url.trim();
  while (u.endsWith('/')) {
    u = u.substring(0, u.length - 1);
  }
  final last = u.split(RegExp(r'[/:\\]')).where((s) => s.isNotEmpty).lastOrNull ?? '';
  return last.endsWith('.git') ? last.substring(0, last.length - 4) : last;
}

/// 目录不存在,或者是空目录。
bool _isFreeDirectory(String path) {
  final t = FileSystemEntity.typeSync(path);
  if (t == FileSystemEntityType.notFound) return true;
  return t == FileSystemEntityType.directory && Directory(path).listSync().isEmpty;
}

/// 把 [url] 克隆到 [parentDir]/[name](name 缺省取地址的最后一段)。
/// 返回 (项目目录, 错误);不会弹出凭据输入,没有权限就直接失败。
Future<(String?, String?)> cloneRepository(String url, String parentDir, {String? name}) async {
  final address = url.trim();
  if (address.isEmpty) return (null, '请输入仓库地址');
  if (address.startsWith('-')) return (null, '仓库地址无效');
  final folder = (name ?? '').trim().isNotEmpty ? name!.trim() : repositoryNameFromUrl(address);
  if (folder.isEmpty || folder == '.' || folder == '..' || folder.contains('/')) return (null, '无法确定目录名');
  if (!Directory(parentDir).existsSync()) return (null, '目录不存在: $parentDir');
  final target = '$parentDir/$folder';
  if (!_isFreeDirectory(target)) return (null, '目录已存在且不为空: $target');
  try {
    final r = await Process.run(
      'git',
      ['clone', '--quiet', '--', address, target],
      environment: {'GIT_TERMINAL_PROMPT': '0'},
    );
    if (r.exitCode != 0) {
      final msg = (r.stderr as String).trim();
      return (null, msg.isEmpty ? 'git clone 失败(退出码 ${r.exitCode})' : msg);
    }
    return (target, null);
  } on ProcessException catch (e) {
    return (null, '无法运行 git: ${e.message}');
  }
}

/// 在 [parentDir] 下新建项目目录 [name] 并 `git init`。返回 (项目目录, 错误)。
Future<(String?, String?)> createProject(String parentDir, String name) async {
  final folder = name.trim();
  if (folder.isEmpty) return (null, '请输入项目名');
  if (folder == '.' || folder == '..' || folder.contains('/') || folder.contains('\\')) return (null, '项目名不能包含路径分隔符');
  if (!Directory(parentDir).existsSync()) return (null, '目录不存在: $parentDir');
  final target = '$parentDir/$folder';
  if (!_isFreeDirectory(target)) return (null, '目录已存在且不为空: $target');
  try {
    await Directory(target).create(recursive: true);
    final r = await Process.run('git', ['init', '-q'], workingDirectory: target);
    if (r.exitCode != 0) return (target, null); // 没能 init 也照样能打开,只是不是仓库
    return (target, null);
  } on FileSystemException catch (e) {
    return (null, '无法创建目录: ${e.message}');
  } on ProcessException {
    return (target, null);
  }
}
