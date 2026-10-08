// 构建工具窗的数据:模块树(由读取器从构建文件里读出)与运行命令的拼装。
//
// 构建工具本身由插件清单声明(contributes.buildTools,见 plugin_manifest.dart);
// Flutter 发布版不能运行时加载 Dart 代码,所以「怎么读模块树」是 IDE 内置的读取器,
// 清单用 `model` 字段按名字选一个。

import '../plugins/plugin_manifest.dart';
import 'maven_reader.dart';

/// 一个模块(Maven 的 module / 根项目)。
class BuildModule {
  const BuildModule({
    required this.name,
    required this.buildFile,
    this.artifactId,
    this.groupId,
    this.packaging,
    this.modules = const [],
    this.error,
  });

  /// 显示名(Maven:`<name>`,没有就用 artifactId)。
  final String name;

  /// 构建文件相对项目根的路径(根模块是 `pom.xml`)。也用作模块的唯一标识。
  final String buildFile;
  final String? artifactId;
  final String? groupId;
  final String? packaging;
  final List<BuildModule> modules;

  /// 读不出来时的原因(文件不存在、XML 写坏了……);模块仍然显示,可以运行任务。
  final String? error;

  /// 模块所在目录相对项目根的路径(根模块为空串)。
  String get dir {
    final slash = buildFile.lastIndexOf('/');
    return slash < 0 ? '' : buildFile.substring(0, slash);
  }

  /// 自己和所有子孙模块(先序)。
  Iterable<BuildModule> get all sync* {
    yield this;
    for (final m in modules) {
      yield* m.all;
    }
  }
}

/// 读项目里的文件:相对项目根的路径 → 内容;不存在或读不了时 null。
typedef BuildFileReader = Future<String?> Function(String relativePath);

/// 从根构建文件读出模块树。
typedef BuildModelReader = Future<BuildModule> Function(String buildFile, BuildFileReader read);

/// IDE 内置的模块树读取器,插件清单的 `model` 字段按名字引用。
const Map<String, BuildModelReader> buildModelReaders = {
  'maven': readMavenProject,
};

/// 读 [tool] 声明的项目模型;没有 / 不认识的读取器只给出根模块。
Future<BuildModule> readBuildModel(BuildToolContribution tool, String buildFile, String projectName, BuildFileReader read) async {
  final reader = buildModelReaders[tool.model];
  if (reader != null) return reader(buildFile, read);
  return BuildModule(name: projectName, buildFile: buildFile);
}

/// 在 [module] 上运行 [tasks] 的命令行(在项目根目录的 shell 里执行)。
///
/// [wrapper] 为真时用项目自带的包装脚本(`./mvnw`);子模块按清单的 fileArgs 指定构建文件;
/// [options] 是工具栏上打开的开关 id。
String buildCommandLine(
  BuildToolContribution tool,
  BuildModule module,
  List<String> tasks, {
  required String rootBuildFile,
  bool wrapper = false,
  Set<String> options = const {},
  bool windows = false,
}) {
  final w = tool.wrapper;
  final exe = wrapper && w != null ? (windows ? '$w.cmd' : './$w') : tool.command;
  final args = <String>[
    ...tasks,
    if (module.buildFile != rootBuildFile)
      for (final a in tool.fileArgs) a.replaceAll(r'${buildFile}', module.buildFile),
    for (final o in tool.options)
      if (options.contains(o.id)) ...o.args,
  ];
  return [exe, ...args.map((a) => shellQuote(a, windows: windows))].join(' ');
}

final RegExp _plainArg = RegExp(r'^[A-Za-z0-9_./:=@%+,-]+$');

/// 必要时给参数加引号(POSIX shell 用单引号;Windows 用双引号)。
String shellQuote(String arg, {bool windows = false}) {
  if (arg.isNotEmpty && _plainArg.hasMatch(arg)) return arg;
  if (windows) return '"${arg.replaceAll('"', r'\"')}"';
  return "'${arg.replaceAll("'", r"'\''")}'";
}

/// 把 [base] 目录下的相对路径 [rel] 拼起来并规整(处理 `.`、`..`、重复的 `/`)。
/// 超出项目根的部分保留为前导 `..`。
String joinRelative(String base, String rel) {
  final out = <String>[];
  for (final part in [...base.split('/'), ...rel.replaceAll('\\', '/').split('/')]) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..' && out.isNotEmpty && out.last != '..') {
      out.removeLast();
    } else {
      out.add(part);
    }
  }
  return out.join('/');
}
