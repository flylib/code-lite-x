// Maven 模块树:读根 pom.xml,沿 <modules>(Maven 4 为 <subprojects>)递归。
//
// 只读声明本身,不做继承 / 插值 / profile 合并(那要跑 Maven 才算得准):
// 名字取 <name>,含 ${...} 或没有时用 artifactId;<parent> 里的 artifactId 不算本模块的。
// profile 里声明的模块不列出(要激活 profile 才有)。

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

  return BuildModule(
    name: name,
    buildFile: buildFile,
    artifactId: artifactId,
    groupId: project.childText('groupId') ?? project.child('parent')?.childText('groupId'),
    packaging: project.childText('packaging') ?? 'jar',
    modules: modules,
  );
}
