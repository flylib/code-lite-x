// Maven 模块树:读根 pom.xml,沿 <modules>(Maven 4 为 <subprojects>)递归。
//
// 只读声明本身,不做继承 / profile 合并(那要跑 Maven 才算得准),插值只展开本模块属性与 project.*:
// 名字取 <name>,含 ${...} 或没有时用 artifactId;<parent> 里的 artifactId 不算本模块的。
// profile 里声明的模块不列出(要激活 profile 才有)。
//
// 每个模块还读出三组节点(对应 IntelliJ Maven 窗口):
// - Plugins:按打包方式默认绑定的插件 + <build><plugins> 里声明的;目标取常用插件的已知目标
//   加上 <executions> 里写的(真正的目标列表在插件 jar 的描述文件里,要下载解析,这里不做);
// - Repositories:<repositories> / <pluginRepositories> 里声明的,加上 Maven 中央仓库;
// - Dependencies:<dependencies> 里直接声明的(不含 dependencyManagement,也不展开传递依赖)。

import 'build_model.dart';
import 'xml_lite.dart';

Future<BuildModule> readMavenProject(String buildFile, BuildFileReader read) => _read(buildFile, read, <String>{});

Future<BuildModule> _read(String buildFile, BuildFileReader read, Set<String> seen) async {
  seen.add(buildFile);
  final dir = buildFile.contains('/') ? buildFile.substring(0, buildFile.lastIndexOf('/')) : '';
  final fallbackName = dir.isEmpty ? buildFile : dir.split('/').last;

  final source = await read(buildFile);
  if (source == null) return BuildModule(name: fallbackName, buildFile: buildFile, error: '找不到 $buildFile');

  final XmlElement project;
  try {
    project = parseXml(source);
  } on FormatException catch (e) {
    return BuildModule(name: fallbackName, buildFile: buildFile, error: '$buildFile 解析失败:${e.message}');
  }
  if (project.name != 'project') {
    return BuildModule(name: fallbackName, buildFile: buildFile, error: '$buildFile 不是 Maven 项目文件(根元素是 <${project.name}>)');
  }

  final artifactId = project.childText('artifactId');
  final declaredName = project.childText('name');
  final name = declaredName != null && !declaredName.contains(r'${') ? declaredName : (artifactId ?? fallbackName);
  final packaging = project.childText('packaging') ?? 'jar';

  final paths = [
    for (final m in project.child('modules')?.childrenNamed('module') ?? const <XmlElement>[]) m.text,
    for (final m in project.child('subprojects')?.childrenNamed('subproject') ?? const <XmlElement>[]) m.text,
  ];
  final childFiles = <String>[];
  for (final p in paths) {
    if (p.isEmpty) continue;
    final target = joinRelative(dir, p);
    final file = target.toLowerCase().endsWith('.xml') ? target : joinRelative(target, 'pom.xml');
    // 循环引用或重复声明:只列一次
    if (seen.contains(file) || childFiles.contains(file)) continue;
    childFiles.add(file);
    seen.add(file);
  }
  final modules = await Future.wait([for (final f in childFiles) _read(f, read, seen)]);

  final dependencies = _dependencies(project, _interpolator(project));
  return BuildModule(
    name: name,
    buildFile: buildFile,
    artifactId: artifactId,
    groupId: project.childText('groupId') ?? project.child('parent')?.childText('groupId'),
    packaging: packaging,
    modules: modules,
    groups: [
      BuildGroup(name: 'Plugins', kind: 'plugins', items: _plugins(project, packaging)),
      BuildGroup(name: 'Repositories', kind: 'repositories', items: _repositories(project)),
      if (dependencies.isNotEmpty) BuildGroup(name: 'Dependencies', kind: 'dependencies', items: dependencies),
    ],
  );
}

// -----------------------------------------------------------------------------
// Plugins
// -----------------------------------------------------------------------------

const String _apacheGroup = 'org.apache.maven.plugins';

/// 打包方式默认绑定到生命周期的插件(不写也会用到,IntelliJ 同样列出)。
const Map<String, List<String>> _defaultPlugins = {
  'pom': ['clean', 'install', 'deploy', 'site'],
  'jar': ['clean', 'resources', 'compiler', 'surefire', 'jar', 'install', 'deploy', 'site'],
  'war': ['clean', 'resources', 'compiler', 'surefire', 'war', 'install', 'deploy', 'site'],
  'maven-plugin': ['clean', 'resources', 'compiler', 'surefire', 'jar', 'plugin', 'install', 'deploy', 'site'],
};

/// 常用插件的目标(前缀 → 目标)。
const Map<String, List<String>> _knownGoals = {
  'antrun': ['help', 'run'],
  'assembly': ['help', 'single'],
  'clean': ['clean', 'help'],
  'compiler': ['compile', 'help', 'testCompile'],
  'dependency': ['analyze', 'copy', 'copy-dependencies', 'help', 'list', 'purge-local-repository', 'resolve', 'sources', 'tree', 'unpack'],
  'deploy': ['deploy', 'deploy-file', 'help'],
  'exec': ['exec', 'help', 'java'],
  'failsafe': ['help', 'integration-test', 'verify'],
  'flyway': ['baseline', 'clean', 'info', 'migrate', 'repair', 'validate'],
  'help': ['active-profiles', 'describe', 'effective-pom', 'effective-settings', 'evaluate', 'help'],
  'install': ['help', 'install', 'install-file'],
  'jacoco': ['check', 'help', 'prepare-agent', 'report'],
  'jar': ['help', 'jar', 'test-jar'],
  'javadoc': ['help', 'jar', 'javadoc', 'test-jar'],
  'jib': ['build', 'buildTar', 'dockerBuild'],
  'mybatis-generator': ['generate'],
  'plugin': ['addPluginArtifactMetadata', 'descriptor', 'helpmojo', 'report'],
  'resources': ['copy-resources', 'help', 'resources', 'testResources'],
  'shade': ['help', 'shade'],
  'site': ['attach-descriptor', 'deploy', 'effective-site', 'help', 'jar', 'run', 'site', 'stage', 'stage-deploy'],
  'source': ['aggregate', 'help', 'jar', 'jar-no-fork', 'test-jar', 'test-jar-no-fork'],
  'spring-boot': ['build-image', 'build-info', 'help', 'process-aot', 'process-test-aot', 'repackage', 'run', 'start', 'stop', 'test-run'],
  'surefire': ['help', 'test'],
  'versions': ['display-dependency-updates', 'display-plugin-updates', 'display-property-updates', 'set', 'use-latest-versions'],
  'war': ['exploded', 'help', 'inplace', 'war'],
};

/// 插件前缀:maven-xxx-plugin / xxx-maven-plugin → xxx(Maven 自己也这样推导)。
String mavenPluginPrefix(String artifactId) {
  final a = RegExp(r'^maven-(.+)-plugin$').firstMatch(artifactId);
  if (a != null) return a.group(1)!;
  final b = RegExp(r'^(.+)-maven-plugin$').firstMatch(artifactId);
  if (b != null) return b.group(1)!;
  return artifactId;
}

List<BuildItem> _plugins(XmlElement project, String packaging) {
  // 前缀 → (坐标, 声明的执行目标)
  final byPrefix = <String, (String, Set<String>)>{};
  for (final prefix in _defaultPlugins[packaging] ?? _defaultPlugins['jar']!) {
    byPrefix[prefix] = ('$_apacheGroup:maven-$prefix-plugin', {});
  }
  for (final p in project.child('build')?.child('plugins')?.childrenNamed('plugin') ?? const <XmlElement>[]) {
    final artifactId = p.childText('artifactId');
    if (artifactId == null) continue;
    final version = p.childText('version');
    final coords = [p.childText('groupId') ?? _apacheGroup, artifactId, if (version != null) version].join(':');
    final goals = <String>{
      for (final e in p.child('executions')?.childrenNamed('execution') ?? const <XmlElement>[])
        for (final g in e.child('goals')?.childrenNamed('goal') ?? const <XmlElement>[])
          if (g.text.isNotEmpty) g.text,
    };
    byPrefix[mavenPluginPrefix(artifactId)] = (coords, goals);
  }
  final prefixes = byPrefix.keys.toList()..sort();
  return [
    for (final prefix in prefixes)
      BuildItem(
        label: prefix,
        detail: '(${byPrefix[prefix]!.$1})',
        children: [
          for (final goal in ({...?_knownGoals[prefix], ...byPrefix[prefix]!.$2}.toList()..sort()))
            BuildItem(label: '$prefix:$goal', task: '$prefix:$goal'),
        ],
      ),
  ];
}

// -----------------------------------------------------------------------------
// Repositories / Dependencies
// -----------------------------------------------------------------------------

const BuildItem _central = BuildItem(label: 'central', detail: 'https://repo.maven.apache.org/maven2');

List<BuildItem> _repositories(XmlElement project) {
  final items = <BuildItem>[];
  final seen = <String>{};
  for (final (list, entry) in [('repositories', 'repository'), ('pluginRepositories', 'pluginRepository')]) {
    for (final r in project.child(list)?.childrenNamed(entry) ?? const <XmlElement>[]) {
      final id = r.childText('id') ?? r.childText('url');
      if (id == null || !seen.add(id)) continue;
      items.add(BuildItem(label: id, detail: r.childText('url')));
    }
  }
  if (!seen.contains('central')) items.add(_central);
  return items;
}

/// 显示用的简单插值:本模块 <properties> 里的属性与 project.version / project.groupId(没写时取 parent 的)。
/// 父 pom 里定义的属性不展开(要跑 Maven 才算得准),原样保留。
String Function(String) _interpolator(XmlElement project) {
  final parent = project.child('parent');
  final vars = <String, String>{
    for (final p in project.child('properties')?.children ?? const <XmlElement>[])
      if (p.text.isNotEmpty) p.name: p.text,
    if ((project.childText('version') ?? parent?.childText('version')) case final v?) ...{'project.version': v, 'version': v},
    if ((project.childText('groupId') ?? parent?.childText('groupId')) case final g?) 'project.groupId': g,
    if (project.childText('artifactId') case final a?) 'project.artifactId': a,
  };
  return (s) => s.replaceAllMapped(RegExp(r'\$\{([^}]+)\}'), (m) => vars[m.group(1)] ?? m.group(0)!);
}

List<BuildItem> _dependencies(XmlElement project, String Function(String) interpolate) => [
      for (final d in project.child('dependencies')?.childrenNamed('dependency') ?? const <XmlElement>[])
        if (d.childText('artifactId') != null)
          BuildItem(
            label: interpolate([d.childText('groupId') ?? '?', d.childText('artifactId')!, if (d.childText('version') != null) d.childText('version')!].join(':')),
            detail: switch (d.childText('scope')) {
              null || 'compile' => null,
              final scope => scope,
            },
          ),
    ];
