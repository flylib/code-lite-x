// 插件的本机部分:安装目录、下载解压、运行安装命令、展开清单里的变量。
//
// 插件装在 ~/.codelitex/plugins/<id>/(plugin.json + state.json + 下载的内容),
// 插件在各项目的缓存放在 ~/.codelitex/plugins/.data/<id>/<项目>/,都不写进项目目录。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import '../l10n/l10n.dart';
import '../lsp/lsp_service.dart' show LspService;
import 'plugin_manifest.dart';

class InstallProgress {
  const InstallProgress(this.message, {this.fraction});

  final String message;

  /// 0..1;未知时为 null(界面显示不确定进度)。
  final double? fraction;
}

class PluginInstallException implements Exception {
  PluginInstallException(this.message, {this.log = ''});

  final String message;

  /// 安装命令的输出末尾(「详情」里展示)。
  final String log;

  @override
  String toString() => message;
}

/// 已安装的插件。
class InstalledPlugin {
  const InstalledPlugin({required this.manifest, required this.enabled, required this.dir});

  final PluginManifest manifest;
  final bool enabled;
  final String dir;
}

class PluginHost {
  PluginHost({String? root, HttpClient Function()? httpClient})
      : root = root ?? defaultRoot(),
        _http = httpClient ?? HttpClient.new;

  /// 插件根目录。
  final String root;
  final HttpClient Function() _http;

  final Set<String> _cancelled = {};
  final Map<String, Process> _running = {};

  static String defaultRoot() {
    final home = Platform.environment['HOME'] ?? Platform.environment['USERPROFILE'] ?? Directory.systemTemp.path;
    return '$home/.codelitex/plugins';
  }

  static bool get supported => true;

  String pluginDir(String id) => '$root/$id';

  /// 插件在某个项目里的缓存目录(jdtls 的索引等)。
  String dataDir(String id, String projectRoot) {
    final name = projectRoot.split(RegExp(r'[/\\]')).lastWhere((s) => s.isNotEmpty, orElse: () => 'workspace');
    final safe = name.replaceAll(RegExp(r'[^A-Za-z0-9._-]'), '_');
    final hash = projectRoot.codeUnits.fold<int>(17, (h, c) => (h * 31 + c) & 0x7fffffff).toRadixString(16);
    return '$root/.data/$id/$safe-$hash';
  }

  /// `darwin-arm64` / `darwin-x64` / `linux-x64` / `linux-arm64` / `win32-x64`。
  static String platformKey() {
    final os = Platform.isMacOS ? 'darwin' : (Platform.isWindows ? 'win32' : 'linux');
    final v = Platform.version.toLowerCase();
    final arm = v.contains('arm64') || v.contains('aarch64');
    return '$os-${arm ? 'arm64' : 'x64'}';
  }

  // -------------------------------------------------------------------------
  // 已安装的插件
  // -------------------------------------------------------------------------

  List<InstalledPlugin> loadInstalled() {
    final out = <InstalledPlugin>[];
    final dir = Directory(root);
    if (!dir.existsSync()) return out;
    for (final d in dir.listSync().whereType<Directory>()) {
      final name = d.path.split(Platform.pathSeparator).last;
      if (name.startsWith('.')) continue;
      try {
        final manifest = PluginManifest.fromJson(
          Map<String, dynamic>.from(jsonDecode(File('${d.path}/plugin.json').readAsStringSync()) as Map),
        );
        var enabled = true;
        final state = File('${d.path}/state.json');
        if (state.existsSync()) {
          enabled = (jsonDecode(state.readAsStringSync()) as Map)['enabled'] != false;
        }
        out.add(InstalledPlugin(manifest: manifest, enabled: enabled, dir: d.path));
      } catch (_) {
        // 半途而废的安装(没有 plugin.json):跳过
      }
    }
    return out;
  }

  void setEnabled(String id, bool enabled) {
    final f = File('${pluginDir(id)}/state.json');
    Map<String, dynamic> state = {};
    try {
      if (f.existsSync()) state = Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
    } catch (_) {}
    state['enabled'] = enabled;
    f.writeAsStringSync(jsonEncode(state));
  }

  Map<String, dynamic> loadPrefs() {
    try {
      final f = File('$root/.prefs.json');
      if (f.existsSync()) return Map<String, dynamic>.from(jsonDecode(f.readAsStringSync()) as Map);
    } catch (_) {}
    return {};
  }

  void savePrefs(Map<String, dynamic> prefs) {
    try {
      Directory(root).createSync(recursive: true);
      File('$root/.prefs.json').writeAsStringSync(jsonEncode(prefs));
    } catch (_) {}
  }

  // -------------------------------------------------------------------------
  // 依赖与变量
  // -------------------------------------------------------------------------

  /// 本机不满足的依赖(JDK 版本、命令)。
  List<PluginRequirement> unmetRequirements(PluginManifest m) => [
        for (final r in m.requires)
          if ((r.java != null && LspService.findJavaHome(minVersion: r.java!) == null) ||
              (r.tool != null && LspService.findExecutable(r.tool!) == null))
            r,
      ];

  /// 系统里已经有这个语言服务器(不在插件目录里的)。
  String? systemProvides(LanguageServerContribution s) {
    for (final name in s.detect) {
      final exe = LspService.findExecutable(name);
      if (exe != null && !exe.startsWith(root)) return exe;
    }
    return null;
  }

  static final RegExp _var = RegExp(r'\$\{([^}]+)\}');

  /// 展开清单里的变量;展开不了(没有合适的 JDK、找不到命令 / 文件)时抛 [PluginInstallException]。
  String resolve(String template, {required String pluginId, String? projectRoot}) {
    final dir = pluginDir(pluginId);
    return template.replaceAllMapped(_var, (m) {
      final v = m.group(1)!;
      if (v == 'pluginDir') return dir;
      if (v == 'dataDir') {
        final d = dataDir(pluginId, projectRoot ?? Directory.current.path);
        Directory(d).createSync(recursive: true);
        return d;
      }
      if (v == 'exe') return Platform.isWindows ? '.exe' : '';
      if (v == 'eclipseConfig') {
        final arm = platformKey().endsWith('arm64');
        return Platform.isMacOS ? (arm ? 'config_mac_arm' : 'config_mac') : (Platform.isWindows ? 'config_win' : (arm ? 'config_linux_arm' : 'config_linux'));
      }
      if (v.startsWith('javaHome:')) {
        final min = int.tryParse(v.substring(9)) ?? 21;
        final home = LspService.findJavaHome(minVersion: min);
        if (home == null) throw PluginInstallException(tr('没有找到 JDK $min 或更新版本', 'No JDK $min or later found'));
        return home;
      }
      if (v.startsWith('tool:')) {
        final exe = LspService.findExecutable(v.substring(5));
        if (exe == null) throw PluginInstallException(tr('没有找到命令 ${v.substring(5)}', 'Command not found: ${v.substring(5)}'));
        return exe;
      }
      if (v.startsWith('glob:')) {
        final hit = _glob(dir, resolve(v.substring(5), pluginId: pluginId, projectRoot: projectRoot));
        if (hit == null) throw PluginInstallException(tr('插件文件缺失:${v.substring(5)}', 'Plugin file missing: ${v.substring(5)}'));
        return hit;
      }
      return m.group(0)!;
    });
  }

  /// [pattern] 是相对 [base] 的路径,各段可含 `*`;返回第一个存在的匹配(按名字倒序,版本新的在前)。
  static String? _glob(String base, String pattern) {
    var candidates = <String>[base];
    for (final seg in pattern.split('/').where((s) => s.isNotEmpty)) {
      final next = <String>[];
      for (final c in candidates) {
        if (!seg.contains('*')) {
          final p = '$c/$seg';
          if (FileSystemEntity.typeSync(p) != FileSystemEntityType.notFound) next.add(p);
          continue;
        }
        final re = RegExp('^${seg.split('*').map(RegExp.escape).join('.*')}\$');
        try {
          final names = Directory(c).listSync().map((e) => e.path.split(Platform.pathSeparator).last).where(re.hasMatch).toList()
            ..sort((a, b) => b.compareTo(a));
          next.addAll(names.map((n) => '$c/$n'));
        } catch (_) {}
      }
      candidates = next;
      if (candidates.isEmpty) return null;
    }
    return candidates.first;
  }

  // -------------------------------------------------------------------------
  // 安装 / 卸载
  // -------------------------------------------------------------------------

  void cancel(String id) {
    _cancelled.add(id);
    _running.remove(id)?.kill();
  }

  Future<void> install(PluginManifest m, {void Function(InstallProgress p)? onProgress}) async {
    final id = m.id;
    _cancelled.remove(id);
    final dir = Directory(pluginDir(id));
    final logTail = <String>[];
    void progress(String message, [double? fraction]) {
      try {
        onProgress?.call(InstallProgress(message, fraction: fraction));
      } catch (_) {
        // 进度回调出错不能中断安装
      }
    }
    try {
      if (dir.existsSync()) dir.deleteSync(recursive: true);
      dir.createSync(recursive: true);
      final steps = m.install.where((s) => s.guide == null).toList();
      for (var i = 0; i < steps.length; i++) {
        final step = steps[i];
        if (_cancelled.contains(id)) throw PluginInstallException(tr('已取消', 'Cancelled'));
        if (step.isDownload) {
          final url = step.downloads![platformKey()] ?? step.downloads!['*'];
          if (url == null) throw PluginInstallException(tr('这个插件没有提供 ${platformKey()} 平台的版本', 'This plugin has no build for ${platformKey()}'));
          final tmp = File('${dir.path}/.download-$i');
          await _download(id, url, tmp, (got, total) {
            final mb = (got / 1048576).toStringAsFixed(1);
            final of = total > 0 ? ' / ${(total / 1048576).toStringAsFixed(1)} MB' : ' MB';
            progress(tr('正在下载 $mb$of', 'Downloading $mb$of'), total > 0 ? got / total : null);
          });
          progress(tr('正在解压…', 'Extracting…'));
          await _extract(tmp, step, id, dir.path);
          if (tmp.existsSync()) tmp.deleteSync();
        } else if (step.run != null) {
          final argv = [for (final a in step.run!) resolve(a, pluginId: id)];
          progress(tr('正在运行 ${argv.first.split(Platform.pathSeparator).last} ${argv.skip(1).take(2).join(' ')}…', 'Running ${argv.first.split(Platform.pathSeparator).last} ${argv.skip(1).take(2).join(' ')}…'));
          final env = <String, String>{
            'PATH': LspService.searchDirs().join(Platform.isWindows ? ';' : ':'),
            for (final e in step.env.entries) e.key: resolve(e.value, pluginId: id),
          };
          final proc = await Process.start(argv.first, argv.sublist(1), workingDirectory: dir.path, environment: env);
          _running[id] = proc;
          void onLine(String line) {
            if (line.trim().isEmpty) return;
            logTail.add(line);
            if (logTail.length > 60) logTail.removeAt(0);
            progress(line.length > 80 ? '${line.substring(0, 80)}…' : line);
          }

          final out = proc.stdout.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
          final err = proc.stderr.transform(utf8.decoder).transform(const LineSplitter()).listen(onLine);
          final code = await proc.exitCode;
          await out.cancel();
          await err.cancel();
          _running.remove(id);
          if (_cancelled.contains(id)) throw PluginInstallException(tr('已取消', 'Cancelled'));
          if (code != 0) throw PluginInstallException(tr('安装命令失败(退出码 $code)', 'Install command failed (exit code $code)'), log: logTail.join('\n'));
        }
      }
      File('${dir.path}/plugin.json').writeAsStringSync(const JsonEncoder.withIndent('  ').convert(m.raw));
      File('${dir.path}/state.json').writeAsStringSync(jsonEncode({
        'enabled': true,
        'version': m.version,
        'installedAt': DateTime.now().toIso8601String(),
      }));
    } catch (e) {
      try {
        if (dir.existsSync()) dir.deleteSync(recursive: true);
      } catch (_) {}
      if (e is PluginInstallException) {
        if (e.log.isEmpty && logTail.isNotEmpty) throw PluginInstallException(e.message, log: logTail.join('\n'));
        rethrow;
      }
      throw PluginInstallException('$e', log: logTail.join('\n'));
    } finally {
      _cancelled.remove(id);
    }
  }

  Future<void> uninstall(String id) async {
    final dir = Directory(pluginDir(id));
    if (dir.existsSync()) await dir.delete(recursive: true);
  }

  /// 代理:先看 HTTPS_PROXY / HTTP_PROXY / NO_PROXY 环境变量(终端里启动时有),
  /// 没有就用 macOS 系统代理设置(从程序坞启动的 app 拿不到终端的环境变量)。
  /// Dart 的 HttpClient 默认不走任何代理,需要代理才能上网的环境里下载会直接失败。
  static String findProxy(Uri uri) {
    final host = uri.host;
    if (host == 'localhost' || host == '127.0.0.1' || host == '::1') return 'DIRECT';
    final env = Platform.environment;
    if (['HTTPS_PROXY', 'https_proxy', 'HTTP_PROXY', 'http_proxy', 'ALL_PROXY', 'all_proxy'].any(env.containsKey)) {
      return HttpClient.findProxyFromEnvironment(uri, environment: {
        for (final k in ['http_proxy', 'https_proxy', 'no_proxy'])
          if ((env[k.toUpperCase()] ?? env[k]) != null) k: (env[k.toUpperCase()] ?? env[k])!,
      });
    }
    final sys = _systemProxy ??= _readSystemProxy();
    if (sys.exceptions.any((e) => _matchesException(host, e))) return 'DIRECT';
    final proxy = uri.scheme == 'https' ? sys.https : sys.http;
    return proxy == null ? 'DIRECT' : 'PROXY $proxy; DIRECT';
  }

  static ({String? http, String? https, List<String> exceptions})? _systemProxy;

  static ({String? http, String? https, List<String> exceptions}) _readSystemProxy() {
    if (!Platform.isMacOS) return (http: null, https: null, exceptions: const <String>[]);
    try {
      final out = Process.runSync('scutil', ['--proxy']).stdout as String;
      String? value(String key) => RegExp('$key : (\\S+)').firstMatch(out)?.group(1);
      String? pick(String p) => value('${p}Enable') == '1' && value('${p}Proxy') != null ? '${value('${p}Proxy')}:${value('${p}Port') ?? '80'}' : null;
      final exceptions = <String>[];
      final list = RegExp(r'ExceptionsList : <array> \{([^}]*)\}').firstMatch(out)?.group(1) ?? '';
      for (final m in RegExp(r'\d+ : (\S+)').allMatches(list)) {
        exceptions.add(m.group(1)!);
      }
      return (http: pick('HTTP'), https: pick('HTTPS'), exceptions: exceptions);
    } catch (_) {
      return (http: null, https: null, exceptions: const <String>[]);
    }
  }

  static bool _matchesException(String host, String pattern) {
    if (pattern.startsWith('*.')) return host.endsWith(pattern.substring(1));
    if (pattern.contains('/')) return false; // CIDR(169.254/16 等)只用于局域网地址,下载源不涉及
    return host == pattern;
  }

  Future<void> _download(String id, String url, File to, void Function(int got, int total) onProgress) async {
    final client = _http()..findProxy = findProxy;
    try {
      final req = await client.getUrl(Uri.parse(url));
      req.headers.set(HttpHeaders.userAgentHeader, 'CodeLiteX');
      final res = await req.close();
      if (res.statusCode != 200) throw PluginInstallException(tr('下载失败:HTTP ${res.statusCode}($url)', 'Download failed: HTTP ${res.statusCode} ($url)'));
      final sink = to.openWrite();
      var got = 0;
      var lastReport = 0;
      try {
        await for (final chunk in res) {
          if (_cancelled.contains(id)) throw PluginInstallException(tr('已取消', 'Cancelled'));
          sink.add(chunk);
          got += chunk.length;
          if (got - lastReport > 256 * 1024 || got == res.contentLength) {
            lastReport = got;
            onProgress(got, res.contentLength);
          }
        }
      } finally {
        await sink.close();
      }
      onProgress(got, res.contentLength);
    } on SocketException catch (e) {
      throw PluginInstallException(tr('网络错误:${e.message}', 'Network error: ${e.message}'));
    } on HandshakeException catch (e) {
      throw PluginInstallException(tr('网络错误:${e.message}', 'Network error: ${e.message}'));
    } finally {
      client.close(force: true);
    }
  }

  Future<void> _extract(File archive, InstallStep step, String id, String pluginDir) async {
    final target = step.to == null || step.to!.isEmpty ? pluginDir : '$pluginDir/${resolve(step.to!, pluginId: id)}';
    Future<void> run(String exe, List<String> args) async {
      final r = await Process.run(exe, args);
      if (r.exitCode != 0) throw PluginInstallException(tr('解压失败', 'Extraction failed'), log: '${r.stdout}\n${r.stderr}');
    }

    switch (step.extract) {
      case 'tar.gz' || 'tgz':
        Directory(target).createSync(recursive: true);
        await run('tar', ['-xzf', archive.path, '-C', target]);
      case 'zip':
        Directory(target).createSync(recursive: true);
        Platform.isWindows ? await run('tar', ['-xf', archive.path, '-C', target]) : await run('unzip', ['-q', '-o', archive.path, '-d', target]);
      case 'gz':
        File(target).parent.createSync(recursive: true);
        await archive.openRead().transform(gzip.decoder).pipe(File(target).openWrite());
      default:
        File(target).parent.createSync(recursive: true);
        archive.renameSync(target);
    }
    if (step.executable && !Platform.isWindows) await run('chmod', ['+x', target]);
  }
}
