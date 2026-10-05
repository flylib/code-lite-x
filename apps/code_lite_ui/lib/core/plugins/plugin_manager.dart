import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../features/editor/syntax/language.dart';
import '../../features/editor/syntax/languages.dart' as syntax;
import '../client/api_client.dart';
import '../lsp/lsp.dart';
import 'builtin_catalog.dart';
import 'plugin_host.dart';
import 'plugin_manifest.dart';

export 'plugin_host.dart' show InstallProgress, PluginInstallException;
export 'plugin_manifest.dart';

enum PluginStatus {
  /// 可安装。
  available,

  /// 正在安装。
  installing,

  /// 已安装并启用。
  enabled,

  /// 已安装但停用。
  disabled,

  /// 不用装:系统里已经有对应的语言服务器。
  system,
}

/// 一次安装的进度 / 结果(界面据此显示进度条、错误与日志)。
class PluginTask {
  PluginTask(this.pluginId);

  final String pluginId;
  String message = '准备安装…';
  double? fraction;
  bool running = true;
  String? error;
  String log = '';
}

/// 插件管理:目录(插件市场索引,目前随 IDE 打包)、已装插件、安装进度、新语言提示,
/// 以及把插件贡献的内容接入 IDE —— 着色规则注册进 [LanguageRegistry],
/// 语言服务器经 [ApiClient.lspLaunchResolver] 交给 LspService 启动。
class PluginManager extends ChangeNotifier {
  PluginManager({
    required this.client,
    PluginHost? host,
    String catalogJson = builtinPluginCatalog,
    LanguageRegistry? registry,
  })  : host = host ?? PluginHost(),
        registry = registry ?? syntax.languages,
        catalog = _parseCatalog(catalogJson) {
    client.lspLaunchResolver = launchFor;
  }

  final ApiClient client;
  final PluginHost host;
  final LanguageRegistry registry;

  /// 可安装的插件(插件市场索引)。
  final List<PluginManifest> catalog;

  final Map<String, InstalledPlugin> _installed = {};
  final Map<String, PluginTask> _tasks = {};

  /// 「不再提示」的插件(持久化)。
  final Set<String> _dismissed = {};

  /// 「以后再说」:本次运行内不再提示。
  final Set<String> _snoozed = {};

  static List<PluginManifest> _parseCatalog(String json) {
    try {
      final j = jsonDecode(json) as Map;
      return [for (final p in (j['plugins'] as List)) PluginManifest.fromJson(Map<String, dynamic>.from(p as Map))];
    } catch (_) {
      return const [];
    }
  }

  /// 读取已装插件与偏好,并把已启用插件的贡献接入。
  void load() {
    _installed
      ..clear()
      ..addEntries(host.loadInstalled().map((p) => MapEntry(p.manifest.id, p)));
    final prefs = host.loadPrefs();
    _dismissed
      ..clear()
      ..addAll([for (final d in (prefs['dismissed'] as List? ?? const [])) '$d']);
    for (final p in _installed.values) {
      if (p.enabled) _activate(p.manifest);
    }
    notifyListeners();
  }

  // -------------------------------------------------------------------------
  // 查询
  // -------------------------------------------------------------------------

  PluginManifest? manifestOf(String id) {
    final installed = _installed[id];
    if (installed != null) return installed.manifest;
    for (final m in catalog) {
      if (m.id == id) return m;
    }
    return null;
  }

  /// 目录里的插件 + 只在本地安装(不在目录里)的插件。
  List<PluginManifest> get all => [
        ...catalog,
        for (final p in _installed.values)
          if (!catalog.any((m) => m.id == p.manifest.id)) p.manifest,
      ];

  PluginTask? taskOf(String id) => _tasks[id];

  PluginStatus statusOf(String id) {
    if (_tasks[id]?.running == true) return PluginStatus.installing;
    final installed = _installed[id];
    if (installed != null) return installed.enabled ? PluginStatus.enabled : PluginStatus.disabled;
    final m = manifestOf(id);
    if (m != null && m.languageServers.isNotEmpty && m.languageServers.every((s) => host.systemProvides(s) != null)) {
      return PluginStatus.system;
    }
    return PluginStatus.available;
  }

  /// 系统里已有的语言服务器路径(状态为 system 时展示)。
  String? systemPathOf(String id) {
    final m = manifestOf(id);
    if (m == null) return null;
    for (final s in m.languageServers) {
      final p = host.systemProvides(s);
      if (p != null) return p;
    }
    return null;
  }

  List<PluginRequirement> unmetRequirements(String id) {
    final m = manifestOf(id);
    return m == null ? const [] : host.unmetRequirements(m);
  }

  /// 打开 [path] 时要推荐的插件(没有则 null):扩展名被某个插件声明,
  /// 它还没装 / 没被停用,系统里也没有对应的语言服务器;着色插件只在内置没有这种语言时推荐。
  PluginManifest? suggestionFor(String path) {
    final name = path.split('/').last.toLowerCase();
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return null;
    final ext = name.substring(dot + 1);
    for (final m in catalog) {
      if (!m.extensions.contains(ext)) continue;
      if (_dismissed.contains(m.id) || _snoozed.contains(m.id)) continue;
      final status = statusOf(m.id);
      if (status == PluginStatus.installing) return m; // 安装进度条继续显示
      if (status != PluginStatus.available) continue;
      final langId = m.languages.firstWhere((l) => l.extensions.contains(ext)).id;
      final givesServer = m.languageServers.isNotEmpty;
      final givesSyntax = m.languages.any((l) => l.syntax != null) && !registry.isBuiltin(langId);
      if (givesServer || givesSyntax) return m;
    }
    return null;
  }

  // -------------------------------------------------------------------------
  // 操作
  // -------------------------------------------------------------------------

  /// 「以后再说」:本次运行内不再提示。
  void snooze(String id) {
    _snoozed.add(id);
    notifyListeners();
  }

  /// 「不再提示」(持久化)。
  void dismiss(String id) {
    _dismissed.add(id);
    _savePrefs();
    notifyListeners();
  }

  void _savePrefs() => host.savePrefs({'dismissed': _dismissed.toList()..sort()});

  Future<bool> install(String id) async {
    final m = manifestOf(id);
    if (m == null || _tasks[id]?.running == true) return false;
    final task = _tasks[id] = PluginTask(id);
    notifyListeners();
    final unmet = host.unmetRequirements(m);
    if (unmet.isNotEmpty) {
      task
        ..running = false
        ..error = '缺少 ${unmet.map((r) => r.label).join('、')}:${unmet.map((r) => r.hint ?? '').where((h) => h.isNotEmpty).join(' ')}';
      notifyListeners();
      return false;
    }
    try {
      await host.install(m, onProgress: (p) {
        task
          ..message = p.message
          ..fraction = p.fraction;
        notifyListeners();
      });
      _installed[id] = InstalledPlugin(manifest: m, enabled: true, dir: host.pluginDir(id));
      _tasks.remove(id);
      _activate(m);
      notifyListeners();
      await _reloadServers(m);
      return true;
    } on PluginInstallException catch (e) {
      task
        ..running = false
        ..error = e.message
        ..log = e.log;
      notifyListeners();
      return false;
    }
  }

  void cancelInstall(String id) => host.cancel(id);

  /// 关掉安装失败的提示条。
  void clearTask(String id) {
    if (_tasks[id]?.running == true) return;
    _tasks.remove(id);
    notifyListeners();
  }

  Future<void> uninstall(String id) async {
    final p = _installed.remove(id);
    if (p == null) return;
    _deactivate(p.manifest);
    notifyListeners();
    await host.uninstall(id);
    await _reloadServers(p.manifest);
  }

  Future<void> setEnabled(String id, bool enabled) async {
    final p = _installed[id];
    if (p == null || p.enabled == enabled) return;
    host.setEnabled(id, enabled);
    _installed[id] = InstalledPlugin(manifest: p.manifest, enabled: enabled, dir: p.dir);
    enabled ? _activate(p.manifest) : _deactivate(p.manifest);
    notifyListeners();
    await _reloadServers(p.manifest);
  }

  void _activate(PluginManifest m) {
    for (final l in m.languages) {
      if (l.syntax != null) registry.register(l.syntax!);
    }
  }

  void _deactivate(PluginManifest m) {
    for (final l in m.languages) {
      if (l.syntax != null) registry.unregister(l.id);
    }
  }

  Future<void> _reloadServers(PluginManifest m) async {
    for (final s in m.languageServers) {
      await client.lspReloadServer(s.group);
    }
  }

  /// LspService 启动某分组的语言服务器时来问:有已启用的插件提供它,就按插件的方式启动。
  LspLaunch? launchFor(String group) {
    for (final p in _installed.values) {
      if (!p.enabled) continue;
      for (final s in p.manifest.languageServers) {
        if (s.group != group) continue;
        try {
          String r(String t) => host.resolve(t, pluginId: p.manifest.id, projectRoot: client.rootPath);
          return LspLaunch(
            [for (final a in s.command) r(a)],
            env: {for (final e in s.env.entries) e.key: r(e.value)},
            initializeTimeout: s.initializeTimeoutSeconds == null ? null : Duration(seconds: s.initializeTimeoutSeconds!),
            requestTimeout: s.requestTimeoutSeconds == null ? null : Duration(seconds: s.requestTimeoutSeconds!),
            source: p.manifest.id,
          );
        } on PluginInstallException {
          return null; // 比如 JDK 被卸掉了:退回系统里找到的命令
        }
      }
    }
    return null;
  }
}
