// web 没有本机文件系统与进程:插件只能声明式启用(着色规则),不能安装语言服务器。

import '../l10n/l10n.dart';
import 'plugin_manifest.dart';

class InstallProgress {
  const InstallProgress(this.message, {this.fraction});
  final String message;
  final double? fraction;
}

class PluginInstallException implements Exception {
  PluginInstallException(this.message, {this.log = ''});
  final String message;
  final String log;

  @override
  String toString() => message;
}

class InstalledPlugin {
  const InstalledPlugin({required this.manifest, required this.enabled, required this.dir});
  final PluginManifest manifest;
  final bool enabled;
  final String dir;
}

class PluginHost {
  PluginHost({String? root}) : root = root ?? '';

  final String root;

  static bool get supported => false;

  static String platformKey() => 'web';

  static String findProxy(Uri uri) => 'DIRECT';

  String pluginDir(String id) => '$root/$id';

  List<InstalledPlugin> loadInstalled() => const [];

  void setEnabled(String id, bool enabled) {}

  Map<String, dynamic> loadPrefs() => {};

  void savePrefs(Map<String, dynamic> prefs) {}

  List<PluginRequirement> unmetRequirements(PluginManifest m) => const [];

  String? systemProvides(LanguageServerContribution s) => null;

  String resolve(String template, {required String pluginId, String? projectRoot}) =>
      throw PluginInstallException(tr('web 版不支持', 'Not supported in the web version'));

  void cancel(String id) {}

  Future<void> install(PluginManifest m, {void Function(InstallProgress p)? onProgress}) async =>
      throw PluginInstallException(tr('web 版不支持安装插件', 'Installing plugins is not supported in the web version'));

  Future<void> uninstall(String id) async {}
}
