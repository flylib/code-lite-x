import 'dart:io';

import 'keymap.dart';

/// 读本机 IntelliJ 当前用的快捷键配置,算出我们这些操作的快捷键。没装过 IntelliJ 返回 null。
///
/// - 配置目录:最新版本的 `IntelliJIdea*` / `IdeaIC*`(macOS 在 ~/Library/Application Support/JetBrains);
/// - 当前配置名:`options/[mac/]keymap.xml` 的 `active_keymap`,没有就是 IntelliJ 的默认键位;
/// - 用户自己的配置在 `keymaps/*.xml`(只记改过的),父配置是 IntelliJ 自带的,在安装包的 `lib/app.jar` 里。
///   找不到安装包时只导入用户改过的那部分,其余保持默认(本来就和 IntelliJ 一样)。
Future<({String name, Map<String, List<String>> shortcuts, String source})?> readIntelliJKeymap({String? home, List<String>? appDirs}) async {
  final h = home ?? Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'];
  if (h == null) return null;
  final base = Platform.isMacOS
      ? '$h/Library/Application Support/JetBrains'
      : Platform.isWindows
          ? '${Platform.environment['APPDATA'] ?? '$h/AppData/Roaming'}/JetBrains'
          : '$h/.config/JetBrains';
  final config = _newestConfigDir(base);
  if (config == null) return null;

  final active = _activeKeymap(config) ?? (Platform.isMacOS ? 'Mac OS X 10.5+' : r'$default');
  final files = <String, IntelliJKeymapFile>{};
  final userDir = Directory('$config/keymaps');
  if (userDir.existsSync()) {
    for (final f in userDir.listSync().whereType<File>().where((f) => f.path.endsWith('.xml'))) {
      final k = IntelliJKeymapFile.parse(f.readAsStringSync());
      if (k != null) files[k.name] = k;
    }
  }
  // 链上的自带配置从安装包里取
  final jar = _appJar(appDirs ?? ['/Applications', '$h/Applications']);
  var name = active;
  final seen = <String>{};
  while (seen.add(name)) {
    var f = files[name];
    if (f == null && jar != null) {
      final r = await Process.run('unzip', ['-p', jar, 'keymaps/$name.xml']);
      if (r.exitCode == 0) f = IntelliJKeymapFile.parse('${r.stdout}');
      if (f != null) files[name] = f;
    }
    final parent = f?.parent;
    if (parent == null) break;
    name = parent;
  }
  return (name: active, shortcuts: resolveIntelliJKeymap(active, files), source: config.split('/').last);
}

/// 版本最新的 IntelliJ 配置目录(IntelliJIdea2025.3 比 IntelliJIdea2023.3 新;旗舰版优先于社区版)。
String? _newestConfigDir(String base) {
  final dir = Directory(base);
  if (!dir.existsSync()) return null;
  (int, int, int)? versionOf(String name) {
    for (final (prefix, rank) in [('IntelliJIdea', 1), ('IdeaIC', 0)]) {
      if (!name.startsWith(prefix)) continue;
      final m = RegExp(r'^(\d{4})\.(\d+)$').firstMatch(name.substring(prefix.length));
      if (m != null) return (int.parse(m.group(1)!), int.parse(m.group(2)!), rank);
    }
    return null;
  }

  String? best;
  (int, int, int)? bestV;
  for (final d in dir.listSync().whereType<Directory>()) {
    final name = d.path.split(Platform.pathSeparator).last;
    final v = versionOf(name);
    if (v == null) continue;
    if (bestV == null || v.$1 > bestV.$1 || (v.$1 == bestV.$1 && (v.$2 > bestV.$2 || (v.$2 == bestV.$2 && v.$3 > bestV.$3)))) {
      best = d.path;
      bestV = v;
    }
  }
  return best;
}

String? _activeKeymap(String config) {
  for (final rel in ['options/mac/keymap.xml', 'options/linux/keymap.xml', 'options/windows/keymap.xml', 'options/keymap.xml']) {
    final f = File('$config/$rel');
    if (!f.existsSync()) continue;
    final m = RegExp(r'''<active_keymap\s+name\s*=\s*["']([^"']+)["']''').firstMatch(f.readAsStringSync());
    if (m != null) return m.group(1);
  }
  return null;
}

/// IntelliJ 安装包里放自带键位的 jar(在 [appDirs] 里找 macOS 的 .app;找不到返回 null)。
String? _appJar(List<String> appDirs) {
  for (final apps in appDirs) {
    final dir = Directory(apps);
    if (!dir.existsSync()) continue;
    final candidates = dir.listSync().whereType<Directory>().where((d) => RegExp(r'IntelliJ IDEA.*\.app$').hasMatch(d.path)).toList()
      ..sort((a, b) => a.path.compareTo(b.path));
    for (final app in candidates) {
      final jar = File('${app.path}/Contents/lib/app.jar');
      if (jar.existsSync()) return jar.path;
    }
  }
  return null;
}
