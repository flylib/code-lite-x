import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:code_lite_ui/core/build_tools/build_model.dart';
import 'package:code_lite_ui/core/build_tools/maven_reader.dart';
import 'package:code_lite_ui/core/build_tools/xml_lite.dart';
import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/plugins/builtin_catalog.dart';
import 'package:code_lite_ui/core/plugins/plugin_host.dart';
import 'package:code_lite_ui/core/plugins/plugin_manager.dart';
import 'package:code_lite_ui/features/activity_stripe/activity_stripe_widget.dart';
import 'package:code_lite_ui/features/bottom_tools/bottom_tools_widget.dart';
import 'package:code_lite_ui/features/build_tools/build_tools_panel.dart';
import 'package:code_lite_ui/features/build_tools/build_tools_store.dart';
import 'package:code_lite_ui/features/plugins/plugins_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Maven 插件:清单里的 buildTools 贡献、自带插件、pom 模块树、命令拼装、构建工具窗。

const _rootPom = '''<?xml version="1.0" encoding="UTF-8"?>
<!-- 根项目 <modules><module>commented-out</module></modules> -->
<project xmlns="http://maven.apache.org/POM/4.0.0" xmlns:xsi="http://www.w3.org/2001/XMLSchema-instance">
  <modelVersion>4.0.0</modelVersion>
  <parent>
    <groupId>org.springframework.boot</groupId>
    <artifactId>spring-boot-starter-parent</artifactId>
    <version>3.3.0</version>
  </parent>
  <artifactId>shop</artifactId>
  <name>Shop &amp; Co</name>
  <packaging>pom</packaging>
  <modules>
    <module>core</module>
    <module>./web/</module>
    <module>tools/custom-pom.xml</module>
    <module>missing</module>
    <module>core</module>
  </modules>
  <profiles>
    <profile><id>extra</id><modules><module>extra</module></modules></profile>
  </profiles>
  <build><plugins><plugin><artifactId>maven-compiler-plugin</artifactId></plugin></plugins></build>
</project>
''';

const _corePom = '''<project>
  <parent><artifactId>shop</artifactId><groupId>com.acme</groupId></parent>
  <artifactId>shop-core</artifactId>
  <name>\${project.artifactId}</name>
  <modules><module>api</module><module>..</module></modules>
</project>''';

const _apiPom = '<project><artifactId>shop-core-api</artifactId></project>';
const _webPom = '''<project><parent><groupId>com.acme</groupId><version>2.0</version></parent><artifactId>shop-web</artifactId>
  <properties><junit.version>4.13</junit.version></properties><name>Web Front</name><packaging>war</packaging>
  <dependencies>
    <dependency><groupId>org.springframework.boot</groupId><artifactId>spring-boot-starter-web</artifactId></dependency>
    <dependency><groupId>junit</groupId><artifactId>junit</artifactId><version>\${junit.version}</version><scope>test</scope></dependency>
    <dependency><groupId>\${project.groupId}</groupId><artifactId>shop-core</artifactId><version>\${project.version}</version></dependency>
  </dependencies>
  <dependencyManagement><dependencies><dependency><groupId>x</groupId><artifactId>managed-only</artifactId></dependency></dependencies></dependencyManagement>
  <repositories><repository><id>nexus</id><url>https://nexus.example/repo</url></repository></repositories>
  <build>
    <pluginManagement><plugins><plugin><artifactId>maven-only-managed-plugin</artifactId></plugin></plugins></pluginManagement>
    <plugins>
      <plugin>
        <groupId>org.springframework.boot</groupId><artifactId>spring-boot-maven-plugin</artifactId><version>2.5.9</version>
        <executions><execution><goals><goal>repackage</goal><goal>custom-goal</goal></goals></execution></executions>
      </plugin>
      <plugin><artifactId>maven-compiler-plugin</artifactId><version>3.11.0</version></plugin>
      <plugin><groupId>com.acme</groupId><artifactId>weird</artifactId><executions><execution><goals><goal>go</goal></goals></execution></executions></plugin>
    </plugins>
  </build>
</project>''';
const _toolsPom = '<project><artifactId>shop-tools</artifactId></project>';

Map<String, String> _files() => {
      'pom.xml': _rootPom,
      'core/pom.xml': _corePom,
      'core/api/pom.xml': _apiPom,
      'web/pom.xml': _webPom,
      'tools/custom-pom.xml': _toolsPom,
    };

BuildFileReader _reader(Map<String, String> files) => (path) async => files[path];

BuildToolContribution _maven() {
  final catalog = jsonDecode(builtinPluginCatalog)['plugins'] as List;
  final m = PluginManifest.fromJson(Map<String, dynamic>.from(catalog.firstWhere((p) => p['id'] == 'codelitex.maven') as Map));
  return m.buildTools.single;
}

void main() {
  group('xml', () {
    test('elements, text, entities, CDATA, comments, attributes containing >', () {
      final e = parseXml('''<?xml version="1.0"?>
<!DOCTYPE project>
<project a="x>y">
  <!-- <artifactId>nope</artifactId> -->
  <artifactId>a&lt;b&#x41;</artifactId>
  <empty/>
  <desc><![CDATA[<raw> & stuff]]></desc>
</project>''');
      expect(e.name, 'project');
      expect(e.childText('artifactId'), 'a<bA');
      expect(e.child('empty'), isNotNull);
      expect(e.childText('empty'), isNull);
      expect(e.childText('desc'), '<raw> & stuff');
      expect(e.children.map((c) => c.name), ['artifactId', 'empty', 'desc']);
    });

    test('tolerates stray end tags and unclosed elements; rejects garbage', () {
      final e = parseXml('<project><a>1</b></a><c>2');
      expect(e.childText('a'), '1');
      expect(e.childText('c'), '2');
      expect(() => parseXml('no tags at all'), throwsFormatException);
      expect(() => parseXml('<project><!-- never closed'), throwsFormatException);
    });
  });

  group('maven reader', () {
    test('reads the module tree: names, nested modules, pom paths, errors, no cycles', () async {
      final root = await readMavenProject('pom.xml', _reader(_files()));
      expect(root.name, 'Shop & Co');
      expect(root.artifactId, 'shop', reason: '<parent> 里的 artifactId 不算');
      expect(root.groupId, 'org.springframework.boot', reason: '没写 groupId 时继承 parent 的');
      expect(root.packaging, 'pom');
      expect(root.error, isNull);
      expect(root.modules.map((m) => m.buildFile), ['core/pom.xml', 'web/pom.xml', 'tools/custom-pom.xml', 'missing/pom.xml'],
          reason: '重复声明只列一次;profile 里的模块不列;注释里的不算');

      final core = root.modules[0];
      expect(core.name, 'shop-core', reason: r'名字含 ${...} 时用 artifactId');
      expect(core.groupId, 'com.acme');
      expect(core.dir, 'core');
      expect(core.modules.map((m) => m.buildFile), ['core/api/pom.xml'], reason: '指回父项目的 .. 是循环,忽略');
      expect(core.modules.single.name, 'shop-core-api');

      expect(root.modules[1].name, 'Web Front');
      expect(root.modules[1].packaging, 'war');
      expect(root.modules[2].name, 'shop-tools');
      expect(root.modules[2].dir, 'tools');

      final missing = root.modules[3];
      expect(missing.name, 'missing');
      expect(missing.error, contains('找不到 missing/pom.xml'));
      expect(root.all.length, 6);
    });

    test('plugins (defaults by packaging + declared), repositories, direct dependencies', () async {
      final root = await readMavenProject('pom.xml', _reader(_files()));
      List<String> labels(BuildModule m, String group) => m.groups.firstWhere((g) => g.name == group).items.map((i) => i.label).toList();

      expect(root.groups.map((g) => g.name), ['Plugins', 'Repositories'], reason: '根 pom 没有直接依赖,不显示 Dependencies');
      expect(labels(root, 'Plugins'), ['clean', 'compiler', 'deploy', 'install', 'site'], reason: 'pom 打包默认绑定的插件 + <build> 里声明的');
      expect(labels(root, 'Repositories'), ['central']);

      final web = root.modules[1];
      expect(web.groups.map((g) => g.name), ['Plugins', 'Repositories', 'Dependencies']);
      expect(labels(web, 'Plugins'), ['clean', 'compiler', 'deploy', 'install', 'resources', 'site', 'spring-boot', 'surefire', 'war', 'weird']);
      final plugins = web.groups.first.items;
      final boot = plugins.firstWhere((i) => i.label == 'spring-boot');
      expect(boot.detail, '(org.springframework.boot:spring-boot-maven-plugin:2.5.9)');
      expect(boot.children.map((c) => c.task), containsAll(['spring-boot:run', 'spring-boot:repackage', 'spring-boot:custom-goal']));
      expect(plugins.firstWhere((i) => i.label == 'compiler').detail, '(org.apache.maven.plugins:maven-compiler-plugin:3.11.0)');
      expect(plugins.firstWhere((i) => i.label == 'weird').children.map((c) => c.task), ['weird:go'], reason: '不认识的插件只列声明的执行目标');
      expect(labels(web, 'Repositories'), ['nexus', 'central']);
      expect(labels(web, 'Dependencies'), ['org.springframework.boot:spring-boot-starter-web', 'junit:junit:4.13', 'com.acme:shop-core:2.0'],
          reason: '本模块属性与 project.* 展开(没写的取 parent)');
      expect(web.groups.last.items.map((i) => i.detail), [null, 'test', null]);

      expect(mavenPluginPrefix('maven-surefire-plugin'), 'surefire');
      expect(mavenPluginPrefix('spring-boot-maven-plugin'), 'spring-boot');
      expect(mavenPluginPrefix('weird'), 'weird');
    });

    test('broken or non-maven pom is reported on the module, not thrown', () async {
      final bad = await readMavenProject('pom.xml', _reader({'pom.xml': 'garbage'}));
      expect(bad.error, contains('解析失败'));
      final other = await readMavenProject('pom.xml', _reader({'pom.xml': '<settings/>'}));
      expect(other.error, contains('<settings>'));
    });

    test('joinRelative normalizes . and .. and keeps escaping parents', () {
      expect(joinRelative('', './web/'), 'web');
      expect(joinRelative('core', '../web'), 'web');
      expect(joinRelative('', '../sibling'), '../sibling');
      expect(joinRelative('a/b', r'..\c'), 'a/c');
    });
  });

  group('command line', () {
    final tool = _maven();
    const root = BuildModule(name: 'shop', buildFile: 'pom.xml');
    const core = BuildModule(name: 'core', buildFile: 'core/pom.xml');
    const spaced = BuildModule(name: 'x', buildFile: "my mod/it's/pom.xml");

    test('maven catalog entry declares the lifecycle and toggles', () {
      expect(tool.markers, ['pom.xml']);
      expect(tool.taskGroups.single.name, 'Lifecycle');
      expect(tool.taskGroups.single.tasks, ['clean', 'validate', 'compile', 'test', 'package', 'verify', 'install', 'site', 'deploy']);
      expect(tool.options.map((o) => o.id), ['offline', 'skipTests']);
    });

    test('root uses mvn; submodules pass -f; wrapper and options; quoting', () {
      expect(buildCommandLine(tool, root, ['clean', 'install'], rootBuildFile: 'pom.xml'), 'mvn clean install');
      expect(buildCommandLine(tool, core, ['package'], rootBuildFile: 'pom.xml', wrapper: true, options: {'offline', 'skipTests'}),
          './mvnw package -f core/pom.xml -o -DskipTests');
      expect(buildCommandLine(tool, spaced, ['test'], rootBuildFile: 'pom.xml'), "mvn test -f 'my mod/it'\\''s/pom.xml'");
      expect(buildCommandLine(tool, core, ['test'], rootBuildFile: 'pom.xml', wrapper: true, windows: true), 'mvnw.cmd test -f core/pom.xml');
      expect(buildCommandLine(tool, core, const [], rootBuildFile: 'pom.xml', options: {'offline'}, raw: ' dependency:tree -Dverbose '),
          'mvn dependency:tree -Dverbose -f core/pom.xml -o');
    });
  });

  group('bundled plugin + store', () {
    late Directory tmp;
    late ApiClient client;
    late PluginManager plugins;

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('clx_build_');
      client = ApiClient(initialRoot: tmp.path);
      plugins = PluginManager(client: client, host: PluginHost(root: '${tmp.path}/plugins'))..load();
    });

    tearDown(() async {
      plugins.dispose();
      await client.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('maven ships enabled; can be disabled (persisted) but not uninstalled', () async {
      expect(plugins.statusOf('codelitex.maven'), PluginStatus.enabled);
      expect(plugins.isBundled('codelitex.maven'), isTrue);
      expect(plugins.isBundled('codelitex.java'), isFalse);
      expect(plugins.buildTools.map((t) => t.id), ['maven']);

      await plugins.uninstall('codelitex.maven');
      expect(plugins.statusOf('codelitex.maven'), PluginStatus.enabled, reason: '自带插件不能卸载');

      await plugins.setEnabled('codelitex.maven', false);
      expect(plugins.statusOf('codelitex.maven'), PluginStatus.disabled);
      expect(plugins.buildTools, isEmpty);
      final again = PluginManager(client: client, host: PluginHost(root: '${tmp.path}/plugins'))..load();
      expect(again.statusOf('codelitex.maven'), PluginStatus.disabled, reason: '停用写进了偏好');
      await again.setEnabled('codelitex.maven', true);
      again.dispose();
      final third = PluginManager(client: client, host: PluginHost(root: '${tmp.path}/plugins'))..load();
      expect(third.statusOf('codelitex.maven'), PluginStatus.enabled);
      third.dispose();
    });

    test('store: detects pom.xml + mvnw, expands the root, runs tasks in lifecycle order, follows plugin and pom changes', () async {
      final files = _files()..['mvnw'] = '#!/bin/sh';
      final saved = StreamController<String>.broadcast();
      final runs = <(String, String)>[];
      String? root = tmp.path;
      final store = BuildToolsStore(
        plugins: plugins,
        projectRoot: () => root,
        read: _reader(files),
        runner: (title, command) => runs.add((title, command)),
        fileSaved: saved.stream,
      );
      await store.reload();
      expect(store.hasProjects, isTrue);
      expect(store.title, 'Maven');
      final p = store.projects.single;
      expect(p.wrapper, isTrue);
      expect(p.root.all.length, 6);
      expect(store.isExpanded(BuildToolsStore.moduleKey(p, p.root)), isTrue);
      expect(store.isExpanded(BuildToolsStore.groupKey(p, p.root, 'Lifecycle')), isTrue);

      final coreKey = BuildToolsStore.moduleKey(p, p.root.modules.first);
      expect(store.canRunSelected, isFalse);
      store.selectTask(coreKey, 'install');
      store.selectTask(coreKey, 'dependency:tree', toggle: true);
      store.selectTask(coreKey, 'clean', toggle: true);
      store.toggleOption(p.tool, 'skipTests');
      expect(store.runSelected(), isTrue);
      expect(runs.single, ('shop-core [clean,install,dependency:tree]', './mvnw clean install dependency:tree -f core/pom.xml -DskipTests'),
          reason: '生命周期阶段按顺序在前,插件目标跟在后面');
      store.runRaw(p, p.root, 'help:effective-pom');
      expect(runs.last, ('Shop & Co [help:effective-pom]', './mvnw help:effective-pom -DskipTests'));
      expect(store.targetModule!.$2.name, 'shop-core');
      store.selectNode(coreKey, 'x');
      expect(store.isModuleSelected(coreKey), isFalse);
      expect(store.canRunSelected, isFalse);
      store.collapseAll();
      store.expandAll();
      expect(store.isExpanded(BuildToolsStore.groupKey(p, p.root.modules[1], 'Dependencies')), isTrue);

      // 保存了模块的 pom:重新读,新加的模块出现
      files['core/pom.xml'] = _corePom.replaceFirst('<module>api</module>', '<module>api</module><module>impl</module>');
      files['core/impl/pom.xml'] = '<project><artifactId>shop-core-impl</artifactId></project>';
      saved.add('core/pom.xml');
      await pumpEventQueue();
      expect(store.projects.single.root.modules.first.modules.map((m) => m.name), ['shop-core-api', 'shop-core-impl']);
      expect(store.selectedModule, coreKey, reason: '模块还在,选中保留');

      // 停用插件:构建工具窗没了
      await plugins.setEnabled('codelitex.maven', false);
      await pumpEventQueue();
      expect(store.hasProjects, isFalse);
      await plugins.setEnabled('codelitex.maven', true);
      await pumpEventQueue();
      expect(store.hasProjects, isTrue);

      // 关掉项目
      root = null;
      await store.reload();
      expect(store.hasProjects, isFalse);
      expect(store.selectedModule, isNull);

      // 没有 pom.xml 的项目
      root = tmp.path;
      files.remove('pom.xml');
      await store.reload();
      expect(store.hasProjects, isFalse);

      store.dispose();
      await saved.close();
    });

    testWidgets('panel: module tree with Lifecycle; double-click runs; toggles show on the toolbar', (tester) async {
      await tester.binding.setSurfaceSize(const Size(400, 1600));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final runs = <String>[];
      final opened = <String>[];
      final store = BuildToolsStore(
        plugins: plugins,
        projectRoot: () => tmp.path,
        read: _reader(_files()),
        runner: (title, command) => runs.add(command),
      );
      await store.reload();
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SizedBox(width: 260, child: BuildToolsPanel(store: store, onOpenFile: opened.add)))));

      expect(find.text('Maven'), findsOneWidget);
      expect(find.text('Shop & Co'), findsOneWidget);
      expect(find.text('(根)'), findsOneWidget);
      expect(find.text('生命周期'), findsOneWidget, reason: '只展开了根模块的 Lifecycle');
      expect(find.text('插件'), findsOneWidget);
      expect(find.text('存储库'), findsOneWidget);
      expect(find.text('shop-core-api'), findsOneWidget, reason: '所有模块平铺在顶层');
      expect(find.text('shop-core'), findsOneWidget);
      expect(find.text('missing'), findsOneWidget);
      expect(find.textContaining('找不到 missing/pom.xml'), findsOneWidget);
      for (final t in ['clean', 'compile', 'test', 'package', 'install', 'deploy']) {
        expect(find.text(t), findsOneWidget);
      }

      await tester.tap(find.text('package'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('package'));
      await tester.pump();
      expect(runs, ['mvn package']);

      // 展开子模块,也有自己的 Lifecycle,运行时带 -f
      await tester.tap(find.byKey(ValueKey('build-module-${BuildToolsStore.moduleKey(store.projects.single, store.projects.single.root.modules[1])}')).first);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('Web Front'));
      await tester.pump();
      expect(find.text('生命周期'), findsNWidgets(2));
      await tester.tap(find.text('生命周期').last);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('生命周期').last);
      await tester.pump();
      await tester.tap(find.text('verify').last);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byTooltip('Offline 模式(-o)'));
      await tester.pump();
      await tester.tap(find.byTooltip('运行选中的任务'));
      await tester.pump();
      expect(runs.last, 'mvn verify -f web/pom.xml -o');

      // 插件目标:展开 Plugins → spring-boot,双击 spring-boot:run
      final webPlugins = find.byKey(const ValueKey('build-group-maven:web/pom.xml#Plugins'));
      await tester.tap(webPlugins);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(webPlugins);
      await tester.pump();
      await tester.tap(find.text('spring-boot'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('spring-boot'));
      await tester.pump();
      await tester.tap(find.text('spring-boot:run'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.text('spring-boot:run'));
      await tester.pump();
      expect(runs.last, 'mvn spring-boot:run -f web/pom.xml -o');

      // 执行 Maven 目标:在选中的模块(Web Front)上运行输入的参数
      await tester.tap(find.byTooltip('执行 Maven 目标'));
      await tester.pumpAndSettle();
      expect(find.text('在 Web Front 上运行'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'dependency:tree');
      await tester.tap(find.text('执行'));
      await tester.pumpAndSettle();
      expect(runs.last, 'mvn dependency:tree -f web/pom.xml -o');

      // 全部折叠:模块还在(平铺),组都收起
      await tester.tap(find.byTooltip('全部折叠'));
      await tester.pump();
      expect(find.text('生命周期'), findsNothing);
      expect(find.text('shop-core'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      store.dispose();
    });

    testWidgets('activity stripe shows the build tool button only when a build tool is detected', (tester) async {
      Widget stripe(String? title) => MaterialApp(
            home: Scaffold(
              body: ActivityStripeWidget(
                leftTool: SideTool.project,
                isLeftOpen: true,
                bottomTab: BottomToolTab.git,
                isBottomOpen: false,
                onSelectTool: (_) {},
                onSelectBottomTab: (_) {},
                buildToolTitle: title,
              ),
            ),
          );
      await tester.pumpWidget(stripe(null));
      expect(find.byTooltip('Maven'), findsNothing);
      await tester.pumpWidget(stripe('Maven'));
      expect(find.byTooltip('Maven'), findsOneWidget);
    });

    testWidgets('plugins page: bundled maven offers disable only', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 3000));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: PluginsPage(plugins: plugins)))));
      final tile = find.byKey(const ValueKey('plugin-codelitex.maven'));
      expect(find.descendant(of: tile, matching: find.text('内置')), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.textContaining('构建工具')), findsOneWidget);
      expect(find.descendant(of: tile, matching: find.text('卸载')), findsNothing);
      await tester.tap(find.descendant(of: tile, matching: find.text('停用')));
      await tester.pump();
      expect(plugins.statusOf('codelitex.maven'), PluginStatus.disabled);
      expect(find.descendant(of: tile, matching: find.text('启用')), findsOneWidget);
    });
  });
}
