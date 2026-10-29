import 'dart:io';
import 'dart:typed_data';

import '../l10n/l10n.dart';
import 'browsers_stub.dart' show BrowserApp;

export 'browsers_stub.dart' show BrowserApp;

// 认识的浏览器,顺序就是工具条上的顺序。(id, macOS 应用名, Linux 命令, Windows 相对 Program Files 的路径)
const List<(String, String, List<String>, String)> _known = [
  ('chrome', 'Google Chrome', ['google-chrome', 'google-chrome-stable'], r'Google\Chrome\Application\chrome.exe'),
  ('firefox', 'Firefox', ['firefox'], r'Mozilla Firefox\firefox.exe'),
  ('safari', 'Safari', [], ''),
  ('edge', 'Microsoft Edge', ['microsoft-edge', 'microsoft-edge-stable'], r'Microsoft\Edge\Application\msedge.exe'),
  ('brave', 'Brave Browser', ['brave-browser', 'brave'], r'BraveSoftware\Brave-Browser\Application\brave.exe'),
  ('arc', 'Arc', [], ''),
  ('opera', 'Opera', ['opera'], r'Opera\launcher.exe'),
  ('vivaldi', 'Vivaldi', ['vivaldi', 'vivaldi-stable'], r'Vivaldi\Application\vivaldi.exe'),
  ('chromium', 'Chromium', ['chromium', 'chromium-browser'], ''),
  ('orion', 'Orion', [], ''),
];

/// 本机装了哪些浏览器(按 [_known] 的顺序)。macOS 看应用目录,Linux 在 PATH 里找命令,Windows 看 Program Files。
Future<List<BrowserApp>> detectBrowsers() async {
  try {
    if (Platform.isMacOS) return await _detectMac();
    if (Platform.isWindows) return _detectWindows();
    if (Platform.isLinux) return await _detectLinux();
  } catch (_) {}
  return const [];
}

Future<List<BrowserApp>> _detectMac() async {
  final home = Platform.environment['HOME'];
  final dirs = [
    '/Applications',
    if (home != null) '$home/Applications',
    '/System/Applications',
    // macOS 13+ 的 Safari 放在这里(/Applications/Safari.app 只是它的链接,有的系统上没有)
    '/System/Volumes/Preboot/Cryptexes/App/System/Applications',
    '/System/Cryptexes/App/System/Applications',
  ];
  final out = <BrowserApp>[];
  for (final (id, name, _, _) in _known) {
    for (final d in dirs) {
      final app = '$d/$name.app';
      if (await Directory(app).exists()) {
        out.add(BrowserApp(id: id, name: name, path: app));
        break;
      }
    }
  }
  return out;
}

List<BrowserApp> _detectWindows() {
  final roots = [
    Platform.environment['ProgramFiles'],
    Platform.environment['ProgramFiles(x86)'],
    Platform.environment['LOCALAPPDATA'] == null ? null : '${Platform.environment['LOCALAPPDATA']}\\Programs',
  ].whereType<String>();
  final out = <BrowserApp>[];
  for (final (id, name, _, rel) in _known) {
    if (rel.isEmpty) continue;
    for (final r in roots) {
      final exe = '$r\\$rel';
      if (File(exe).existsSync()) {
        out.add(BrowserApp(id: id, name: name, path: exe));
        break;
      }
    }
  }
  return out;
}

Future<List<BrowserApp>> _detectLinux() async {
  final out = <BrowserApp>[];
  final path = (Platform.environment['PATH'] ?? '').split(':').where((s) => s.isNotEmpty);
  for (final (id, name, commands, _) in _known) {
    var found = false;
    for (final c in commands) {
      for (final d in path) {
        if (await File('$d/$c').exists()) {
          out.add(BrowserApp(id: id, name: name, path: '$d/$c'));
          found = true;
          break;
        }
      }
      if (found) break;
    }
  }
  return out;
}

/// 用 [browser] 打开 [file](绝对路径)。成功返回 null,失败返回原因。
Future<String?> openInBrowser(BrowserApp browser, String file) async {
  try {
    if (Platform.isMacOS) {
      final r = await Process.run('open', ['-a', browser.path, file]);
      return r.exitCode == 0 ? null : '${r.stderr}'.trim();
    }
    await Process.start(browser.path, [file], mode: ProcessStartMode.detached);
    return null;
  } catch (e) {
    return '$e';
  }
}

/// 浏览器图标的 PNG 数据(没有就返回 null,界面用字母徽标代替)。
/// 目前只有 macOS:从应用包里的 .icns 用系统自带的 sips 转成 PNG,缓存在 ~/.codelitex/cache/browser-icons/。
Future<Uint8List?> browserIcon(BrowserApp browser) async {
  if (!Platform.isMacOS) return null;
  try {
    final home = Platform.environment['HOME'];
    if (home == null) return null;
    final plist = '${browser.path}/Contents/Info.plist';
    final r = await Process.run('plutil', ['-extract', 'CFBundleIconFile', 'raw', '-o', '-', plist]);
    if (r.exitCode != 0) return null;
    var icon = '${r.stdout}'.trim();
    if (icon.isEmpty) return null;
    if (!icon.toLowerCase().endsWith('.icns')) icon = '$icon.icns';
    final icns = File('${browser.path}/Contents/Resources/$icon');
    if (!await icns.exists()) return null;

    final out = File('$home/.codelitex/cache/browser-icons/${browser.id}.png');
    // 应用更新后图标可能变:缓存比 icns 旧就重做
    if (await out.exists() && (await out.lastModified()).isAfter(await icns.lastModified())) return await out.readAsBytes();
    await out.parent.create(recursive: true);
    final c = await Process.run('sips', ['-s', 'format', 'png', '-Z', '64', icns.path, '--out', out.path]);
    return c.exitCode == 0 && await out.exists() ? await out.readAsBytes() : null;
  } catch (_) {
    return null;
  }
}

/// 用系统默认的程序打开网址 / 邮件链接(macOS `open`、Linux `xdg-open`、Windows `start`)。
/// 成功返回 null,失败返回原因。只放行 http / https / mailto,别的协议不交给系统。
Future<String?> openExternalUrl(String url) async {
  final uri = Uri.tryParse(url);
  if (uri == null || !const {'http', 'https', 'mailto'}.contains(uri.scheme)) return tr('不支持的链接: $url', 'Unsupported link: $url');
  try {
    final r = Platform.isMacOS
        ? await Process.run('open', [url])
        : Platform.isWindows
            ? await Process.run('cmd', ['/c', 'start', '', url])
            : await Process.run('xdg-open', [url]);
    return r.exitCode == 0 ? null : '${r.stderr}'.trim();
  } catch (e) {
    return '$e';
  }
}
