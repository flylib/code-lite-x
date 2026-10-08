// 插件清单(plugin.json)的数据模型。
//
// CodeLiteX 的插件是「声明式 + 独立进程」:清单声明插件提供什么(语言、着色规则、语言服务器……),
// 需要运行逻辑的部分(语言服务器)是单独的进程,经 JSON-RPC 通信。Flutter 发布版不能在运行时
// 加载新的 Dart 代码,这种方式不受限制,插件也可以用任何语言实现,崩溃不会拖垮 IDE。
//
// 格式(与插件市场的索引一致,目前随 IDE 打包在 builtin_catalog.dart):
// {
//   "id": "codelitex.java", "name": "Java", "version": "1.61.0", "publisher": "CodeLiteX",
//   "description": "...", "categories": ["Programming Languages"], "sizeMB": 50,
//   "requires": [{"java": 21, "hint": "..."}, {"tool": "go"}],
//   "contributes": {
//     "languages": [{"id": "lua", "name": "Lua", "extensions": ["lua"], "syntax": {...LanguageSpec...}}],
//     "languageServers": [{
//       "group": "java", "languages": ["java"], "name": "Eclipse JDT Language Server",
//       "command": ["${javaHome:21}/bin/java", "-jar", "${glob:server/plugins/org.eclipse.equinox.launcher_*.jar}", ...],
//       "env": {"JAVA_HOME": "${javaHome:21}"}, "initializeTimeoutSeconds": 180,
//       "detect": ["jdtls"]
//     }],
//     "buildTools": [{
//       "id": "maven", "name": "Maven", "markers": ["pom.xml"], "model": "maven",
//       "command": "mvn", "wrapper": "mvnw", "fileArgs": ["-f", "${buildFile}"],
//       "taskGroups": [{"name": "Lifecycle", "tasks": ["clean", "compile", "test", "package", "install"]}],
//       "options": [{"id": "offline", "label": "Offline 模式", "args": ["-o"], "icon": "cloud_off"}]
//     }]
//   },
//   "bundled": true,   // 随 IDE 自带:不用安装,默认启用(可在设置里停用,不能卸载)
//   "install": [
//     {"download": {"darwin-arm64": "https://...", "*": "https://..."}, "extract": "tar.gz", "to": "server"},
//     {"run": ["${tool:go}", "install", "golang.org/x/tools/gopls@latest"], "env": {"GOBIN": "${pluginDir}/bin"}},
//     {"guide": "说明文字(需要用户自己装的东西)"}
//   ]
// }
//
// 变量:${pluginDir} 插件安装目录,${dataDir} 插件在当前项目的缓存目录,${javaHome:N} 版本 ≥ N 的 JDK,
// ${tool:name} 搜索路径里的可执行文件,${glob:相对路径模式} 插件目录下匹配的第一个文件,
// ${eclipseConfig} Eclipse 启动器的平台配置目录名(config_mac_arm 等),${exe} Windows 下为 .exe。

import '../../features/editor/syntax/language.dart';

class PluginRequirement {
  const PluginRequirement({this.java, this.tool, this.hint});

  factory PluginRequirement.fromJson(Map<String, dynamic> j) => PluginRequirement(
        java: (j['java'] as num?)?.toInt(),
        tool: j['tool'] as String?,
        hint: j['hint'] as String?,
      );

  /// 需要版本 ≥ [java] 的 JDK。
  final int? java;

  /// 需要搜索路径里有这个命令(go、npm……)。
  final String? tool;

  /// 不满足时给用户的说明。
  final String? hint;

  String get label => java != null ? 'JDK $java+' : (tool ?? '');
}

class LanguageContribution {
  const LanguageContribution({required this.id, required this.name, required this.extensions, this.fileNames = const [], this.syntax});

  factory LanguageContribution.fromJson(Map<String, dynamic> j) {
    final id = j['id'] as String;
    final name = j['name'] as String? ?? id;
    final exts = _strings(j['extensions']);
    final files = _strings(j['fileNames']);
    final syntax = j['syntax'] is Map
        ? languageSpecFromJson({'id': id, 'name': name, 'extensions': exts, 'fileNames': files, ...Map<String, dynamic>.from(j['syntax'] as Map)})
        : null;
    return LanguageContribution(id: id, name: name, extensions: exts, fileNames: files, syntax: syntax);
  }

  final String id;
  final String name;
  final List<String> extensions;
  final List<String> fileNames;

  /// 着色规则;null 表示只声明语言(着色用内置的)。
  final LanguageSpec? syntax;
}

class LanguageServerContribution {
  const LanguageServerContribution({
    required this.group,
    required this.languages,
    required this.name,
    required this.command,
    this.env = const {},
    this.initializeTimeoutSeconds,
    this.requestTimeoutSeconds,
    this.detect = const [],
  });

  factory LanguageServerContribution.fromJson(Map<String, dynamic> j) => LanguageServerContribution(
        group: j['group'] as String,
        languages: _strings(j['languages']),
        name: j['name'] as String? ?? j['group'] as String,
        command: _strings(j['command']),
        env: {for (final e in ((j['env'] as Map?) ?? const {}).entries) e.key as String: e.value as String},
        initializeTimeoutSeconds: (j['initializeTimeoutSeconds'] as num?)?.toInt(),
        requestTimeoutSeconds: (j['requestTimeoutSeconds'] as num?)?.toInt(),
        detect: _strings(j['detect']),
      );

  /// 服务端分组(同一分组只起一个进程,见 lspServerGroupFor)。
  final String group;

  /// 服务的 languageId。
  final List<String> languages;
  final String name;

  /// 启动命令(含变量)。
  final List<String> command;
  final Map<String, String> env;
  final int? initializeTimeoutSeconds;
  final int? requestTimeoutSeconds;

  /// 系统里已装有这些命令之一时,不需要安装插件也能用(提示里不再推荐)。
  final List<String> detect;
}

/// 构建工具(Maven、Gradle……):项目根目录有 [markers] 之一时,左侧活动条出现它的工具窗,
/// 按 [model] 读出模块树,每个模块下列出 [taskGroups],双击任务在终端里运行。
class BuildToolContribution {
  const BuildToolContribution({
    required this.id,
    required this.name,
    required this.markers,
    required this.command,
    this.model,
    this.wrapper,
    this.fileArgs = const [],
    this.taskGroups = const [],
    this.options = const [],
  });

  factory BuildToolContribution.fromJson(Map<String, dynamic> j) => BuildToolContribution(
        id: j['id'] as String,
        name: j['name'] as String? ?? j['id'] as String,
        markers: _strings(j['markers']),
        command: j['command'] as String? ?? j['id'] as String,
        model: j['model'] as String?,
        wrapper: j['wrapper'] as String?,
        fileArgs: _strings(j['fileArgs']),
        taskGroups: [
          for (final g in (j['taskGroups'] as List? ?? const []))
            if (g is Map) BuildTaskGroup(name: '${g['name'] ?? ''}', tasks: _strings(g['tasks'])),
        ],
        options: [
          for (final o in (j['options'] as List? ?? const []))
            if (o is Map)
              BuildToolOption(id: '${o['id']}', label: '${o['label'] ?? o['id']}', args: _strings(o['args']), icon: o['icon'] as String?),
        ],
      );

  final String id;
  final String name;

  /// 项目根目录里的这些文件之一存在,就认为是这种项目;第一个也是根模块的构建文件。
  final List<String> markers;

  /// 命令名(在用户的登录 shell 里运行,走 shell 的 PATH)。
  final String command;

  /// 读模块树的方式(IDE 内置的读取器,如 `maven`);没有或不认识时只显示根模块。
  final String? model;

  /// 项目自带的包装脚本(`mvnw`):根目录有它就用 `./mvnw`(Windows 为 `mvnw.cmd`)代替 [command]。
  final String? wrapper;

  /// 对子模块运行时追加的参数,`${buildFile}` 换成该模块构建文件相对项目根的路径。
  final List<String> fileArgs;
  final List<BuildTaskGroup> taskGroups;

  /// 工具栏上的开关(离线、跳过测试……),打开时给命令追加 [BuildToolOption.args]。
  final List<BuildToolOption> options;
}

class BuildTaskGroup {
  const BuildTaskGroup({required this.name, required this.tasks});

  final String name;
  final List<String> tasks;
}

class BuildToolOption {
  const BuildToolOption({required this.id, required this.label, required this.args, this.icon});

  final String id;
  final String label;
  final List<String> args;

  /// 图标名(界面认识的几个:`cloud_off`、`skip`;不认识时用通用图标)。
  final String? icon;
}

/// 一个安装步骤:下载并解压 / 运行命令 / 给用户的说明。
class InstallStep {
  const InstallStep({this.downloads, this.extract, this.to, this.run, this.env = const {}, this.guide, this.executable = false});

  factory InstallStep.fromJson(Map<String, dynamic> j) => InstallStep(
        downloads: j['download'] is String
            ? {'*': j['download'] as String}
            : j['download'] is Map
                ? {for (final e in (j['download'] as Map).entries) e.key as String: e.value as String}
                : null,
        extract: j['extract'] as String?,
        to: j['to'] as String?,
        run: j['run'] == null ? null : _strings(j['run']),
        env: {for (final e in ((j['env'] as Map?) ?? const {}).entries) e.key as String: e.value as String},
        guide: j['guide'] as String?,
        executable: j['executable'] == true,
      );

  /// 平台(`darwin-arm64`、`linux-x64`、`win32-x64`……,`*` 为通用)→ 下载地址。
  final Map<String, String>? downloads;

  /// `tar.gz` / `zip` / `gz`(单个文件)/ null(原样保存)。
  final String? extract;

  /// 解压或保存到插件目录下的这个相对路径。
  final String? to;

  /// 运行一条命令。
  final List<String>? run;
  final Map<String, String> env;

  /// 需要用户自己处理的说明(不执行任何操作)。
  final String? guide;

  /// 下载的单个文件要加可执行权限。
  final bool executable;

  bool get isDownload => downloads != null;
}

class PluginManifest {
  const PluginManifest({
    required this.id,
    required this.name,
    required this.version,
    this.publisher = '',
    this.description = '',
    this.categories = const [],
    this.sizeMB,
    this.requires = const [],
    this.languages = const [],
    this.languageServers = const [],
    this.buildTools = const [],
    this.install = const [],
    this.bundled = false,
    this.raw = const {},
  });

  factory PluginManifest.fromJson(Map<String, dynamic> j) {
    final contributes = (j['contributes'] as Map?)?.cast<String, dynamic>() ?? const {};
    return PluginManifest(
      id: j['id'] as String,
      name: j['name'] as String? ?? j['id'] as String,
      version: j['version'] as String? ?? '0.0.0',
      publisher: j['publisher'] as String? ?? '',
      description: j['description'] as String? ?? '',
      categories: _strings(j['categories']),
      sizeMB: (j['sizeMB'] as num?)?.toDouble(),
      requires: [for (final r in (j['requires'] as List? ?? const [])) PluginRequirement.fromJson(Map<String, dynamic>.from(r as Map))],
      languages: [
        for (final l in (contributes['languages'] as List? ?? const [])) LanguageContribution.fromJson(Map<String, dynamic>.from(l as Map)),
      ],
      languageServers: [
        for (final s in (contributes['languageServers'] as List? ?? const []))
          LanguageServerContribution.fromJson(Map<String, dynamic>.from(s as Map)),
      ],
      buildTools: [
        for (final b in (contributes['buildTools'] as List? ?? const [])) BuildToolContribution.fromJson(Map<String, dynamic>.from(b as Map)),
      ],
      install: [for (final s in (j['install'] as List? ?? const [])) InstallStep.fromJson(Map<String, dynamic>.from(s as Map))],
      bundled: j['bundled'] == true,
      raw: j,
    );
  }

  final String id;
  final String name;
  final String version;
  final String publisher;
  final String description;
  final List<String> categories;
  final double? sizeMB;
  final List<PluginRequirement> requires;
  final List<LanguageContribution> languages;
  final List<LanguageServerContribution> languageServers;
  final List<BuildToolContribution> buildTools;
  final List<InstallStep> install;

  /// 随 IDE 自带:不用安装,默认启用,不能卸载(只能停用)。
  final bool bundled;

  /// 原始 JSON(安装时原样写进插件目录的 plugin.json)。
  final Map<String, dynamic> raw;

  /// 没有任何需要下载 / 运行的步骤(纯着色规则插件):安装即启用,不占网络。
  bool get isDeclarativeOnly => install.every((s) => s.guide != null);

  /// 插件覆盖的扩展名(打开这些文件时可能推荐它)。
  Set<String> get extensions => {
        for (final l in languages) ...l.extensions.map((e) => e.toLowerCase()),
      };

  /// 插件的语言服务器服务的 languageId。
  Set<String> get serverLanguages => {for (final s in languageServers) ...s.languages};
}

/// JSON → [LanguageSpec](插件贡献的着色规则)。字段名与 LanguageSpec 一致。
LanguageSpec languageSpecFromJson(Map<String, dynamic> j) {
  Set<String> set(String k) => _strings(j[k]).toSet();
  return LanguageSpec(
    id: j['id'] as String,
    name: j['name'] as String? ?? j['id'] as String,
    mode: SyntaxMode.values.firstWhere((m) => m.name == j['mode'], orElse: () => SyntaxMode.code),
    extensions: _strings(j['extensions']).map((e) => e.toLowerCase()).toList(),
    fileNames: _strings(j['fileNames']),
    shebangs: _strings(j['shebangs']),
    keywords: set('keywords'),
    types: set('types'),
    constants: set('constants'),
    builtins: set('builtins'),
    lineComments: _strings(j['lineComments']),
    blockComments: [
      for (final b in (j['blockComments'] as List? ?? const []))
        if (b is List && b.length == 2) (b[0] as String, b[1] as String),
    ],
    docComment: j['docComment'] as String?,
    strings: [
      for (final s in (j['strings'] as List? ?? const []))
        if (s is String)
          StringRule(s)
        else if (s is Map)
          StringRule(
            s['open'] as String,
            s['close'] as String?,
            s['multiline'] == true,
            s['escapes'] != false,
            (s['maxLength'] as num?)?.toInt(),
          ),
    ],
    annotation: j['annotation'] as String?,
    caseInsensitive: j['caseInsensitive'] == true,
    identifierExtra: j['identifierExtra'] as String? ?? '',
    upperCaseIsType: j['upperCaseIsType'] == true,
    preprocessor: j['preprocessor'] == true,
    variableSigil: j['variableSigil'] as String?,
  );
}

List<String> _strings(Object? v) => v is List ? [for (final e in v) '$e'] : const [];
