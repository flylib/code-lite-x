// gh 进程的原生实现(web 用 gh_runner_stub.dart)。

import 'dart:convert';
import 'dart:io';

import '../l10n/l10n.dart';
import 'github_models.dart';

String? _ghPath;

/// 在系统浏览器里打开链接。
Future<void> openUrl(String url) async {
  if (url.isEmpty) return;
  final cmd = Platform.isMacOS ? 'open' : (Platform.isWindows ? 'explorer' : 'xdg-open');
  try {
    await Process.run(cmd, [url]);
  } catch (_) {}
}

Future<List<int>> runGh(String root, List<String> args, {String? stdin}) async {
  final exe = _ghPath ??= _findGh();
  if (exe == null) {
    throw GhException(
      tr('没有找到 GitHub CLI(gh)。请先安装:brew install gh,然后运行 gh auth login。',
          'GitHub CLI (gh) not found. Install it first (brew install gh), then run gh auth login.'),
      notInstalled: true,
    );
  }
  final Process proc;
  try {
    proc = await Process.start(
      exe,
      args,
      workingDirectory: root,
      environment: {'PATH': _searchDirs().join(Platform.isWindows ? ';' : ':'), 'GH_PROMPT_DISABLED': '1', 'NO_COLOR': '1'},
    );
  } on ProcessException catch (e) {
    throw GhException(tr('无法启动 gh: ${e.message}', 'Cannot start gh: ${e.message}'));
  }
  if (stdin != null) {
    proc.stdin.add(utf8.encode(stdin));
  }
  await proc.stdin.close();
  final outFuture = proc.stdout.fold<List<int>>(<int>[], (a, b) => a..addAll(b));
  final errFuture = proc.stderr.transform(utf8.decoder).join();
  final code = await proc.exitCode;
  final out = await outFuture;
  final err = await errFuture;
  if (code != 0) {
    final msg = err.trim().isNotEmpty ? err.trim() : utf8.decode(out, allowMalformed: true).trim();
    final notLoggedIn = msg.contains('gh auth login') || msg.contains('not logged');
    throw GhException(
      notLoggedIn ? tr('gh 尚未登录 GitHub。请在终端运行 gh auth login。', 'gh is not logged in to GitHub. Run gh auth login in a terminal.') : _friendly(msg),
      notLoggedIn: notLoggedIn,
    );
  }
  return out;
}

/// gh api 报错时 stdout 是 GitHub 的 JSON 错误体:取其中的 message。
String _friendly(String msg) {
  final i = msg.indexOf('{');
  if (i >= 0) {
    try {
      final j = jsonDecode(msg.substring(i)) as Map;
      final errors = (j['errors'] as List?)?.map((e) => e is Map ? (e['message'] ?? e['code'] ?? '') : e).where((e) => '$e'.isNotEmpty).join('; ');
      final m = j['message'] as String? ?? msg;
      return errors == null || errors.isEmpty ? m : '$m: $errors';
    } catch (_) {}
  }
  return msg.isEmpty ? tr('gh 执行失败', 'gh failed') : msg;
}

String? _findGh() {
  final name = Platform.isWindows ? 'gh.exe' : 'gh';
  for (final dir in _searchDirs()) {
    final f = File('$dir/$name');
    if (f.existsSync()) return f.path;
  }
  return null;
}

/// Finder 启动的 app 的 PATH 只有系统目录:补上 Homebrew 等常见位置(gh 自己还要调用 git)。
List<String> _searchDirs() {
  final env = Platform.environment;
  final home = env['HOME'] ?? env['USERPROFILE'] ?? '';
  final sep = Platform.isWindows ? ';' : ':';
  final dirs = <String>[
    ...(env['PATH'] ?? '').split(sep).where((d) => d.isNotEmpty),
    '/opt/homebrew/bin',
    '/usr/local/bin',
    if (home.isNotEmpty) '$home/.local/bin',
    if (Platform.isWindows) r'C:\Program Files\GitHub CLI',
    '/usr/bin',
    '/bin',
  ];
  final seen = <String>{};
  return dirs.where(seen.add).toList();
}
