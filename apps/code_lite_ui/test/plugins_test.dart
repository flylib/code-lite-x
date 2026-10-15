import 'dart:convert';
import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/plugins/builtin_catalog.dart';
import 'package:code_lite_ui/core/plugins/plugin_host.dart';
import 'package:code_lite_ui/core/plugins/plugin_manager.dart';
import 'package:code_lite_ui/features/editor/syntax/language.dart';
import 'package:code_lite_ui/features/editor/syntax/languages.dart';
import 'package:code_lite_ui/features/editor/syntax/tokenizer.dart';
import 'package:code_lite_ui/features/plugins/plugin_banner.dart';
import 'package:code_lite_ui/features/plugins/plugins_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _Client extends ApiClient {
  _Client(String root) : super(initialRoot: root);
  final List<String> reloaded = [];

  @override
  Future<void> lspReloadServer(String group) async => reloaded.add(group);
}

void main() {
  group('catalog', () {
    test('built-in catalog parses; ids unique; every server plugin can be installed and launched', () {
      final plugins = [for (final p in (jsonDecode(builtinPluginCatalog)['plugins'] as List)) PluginManifest.fromJson(Map<String, dynamic>.from(p as Map))];
      expect(plugins.map((p) => p.id).toSet(), hasLength(plugins.length));
      expect(plugins.map((p) => p.id), containsAll(['codelitex.java', 'codelitex.go', 'codelitex.typescript', 'codelitex.python', 'codelitex.rust', 'codelitex.cpp', 'codelitex.lua']));
      for (final p in plugins.where((p) => p.languageServers.isNotEmpty)) {
        expect(p.install, isNotEmpty, reason: p.id);
        for (final s in p.languageServers) {
          expect(s.command, isNotEmpty, reason: p.id);
          expect(s.languages, isNotEmpty, reason: p.id);
        }
      }
      final java = plugins.firstWhere((p) => p.id == 'codelitex.java');
      expect(java.requires.single.java, 21);
      expect(java.install.single.downloads!['*'], startsWith('https://download.eclipse.org/jdtls/'));
    });

    test('syntax-only plugins carry working highlighting for languages no longer built in', () {
      final lua = PluginManifest.fromJson(Map<String, dynamic>.from(
        (jsonDecode(builtinPluginCatalog)['plugins'] as List).firstWhere((p) => p['id'] == 'codelitex.lua') as Map,
      ));
      expect(lua.isDeclarativeOnly, isTrue);
      expect(languages.detect('init.lua').id, 'plaintext', reason: 'Lua 不再内置');
      final spec = lua.languages.single.syntax!;
      final kinds = {
        for (final t in tokenizeLine(spec, 'local x = nil -- note', 0).tokens) 'local x = nil -- note'.substring(t.start, t.end): t.kind,
      };
      expect(kinds['local'], TokenKind.keyword);
      expect(kinds['nil'], TokenKind.constant);
      expect(kinds['-- note'], TokenKind.comment);
    });
  });

  group('PluginHost', () {
    late Directory tmp;
    late HttpServer server;
    late String base;
    late PluginHost host;

    setUp(() async {
      // flutter_test 把 HttpClient 换成了一律返回 400 的假实现:这组要真的走本机 HTTP
      HttpOverrides.global = null;
      tmp = Directory.systemTemp.createTempSync('clx_plugins_');
      // 打一个 tar.gz:server/fake-1.2/run.sh
      final pkg = Directory('${tmp.path}/pkg/fake-1.2')..createSync(recursive: true);
      File('${pkg.path}/run.sh').writeAsStringSync('#!/bin/sh\necho hi\n');
      await Process.run('tar', ['-czf', '${tmp.path}/pkg.tar.gz', '-C', '${tmp.path}/pkg', 'fake-1.2']);
      File('${tmp.path}/tool').writeAsBytesSync(gzip.encode(utf8.encode('#!/bin/sh\necho tool\n')));
      server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
      server.listen((req) async {
        final name = req.uri.path.substring(1);
        final f = File('${tmp.path}/$name');
        if (!f.existsSync()) {
          req.response.statusCode = 404;
        } else {
          req.response.contentLength = f.lengthSync();
          await req.response.addStream(f.openRead());
        }
        await req.response.close();
      });
      base = 'http://127.0.0.1:${server.port}';
      host = PluginHost(root: '${tmp.path}/plugins');
    });

    tearDown(() async {
      await server.close(force: true);
      tmp.deleteSync(recursive: true);
    });

    PluginManifest manifest(List<Map<String, Object?>> install, {List<Map<String, Object?>> requires = const []}) => PluginManifest.fromJson({
          'id': 'test.fake',
          'name': 'Fake',
          'version': '1.2',
          'requires': requires,
          'contributes': {
            'languageServers': [
              {
                'group': 'fake',
                'languages': ['fake'],
                'command': [r'${glob:server/fake-*/run.sh}', '--data', r'${dataDir}'],
                'detect': ['definitely-not-installed-xyz'],
              },
            ],
          },
          'install': install,
        });

    test('download + tar.gz extract + gz single file + run step; installed state persists', () async {
      final m = manifest([
        {'download': '$base/pkg.tar.gz', 'extract': 'tar.gz', 'to': 'server'},
        {'download': {'*': '$base/tool'}, 'extract': 'gz', 'to': r'bin/tool${exe}', 'executable': true},
        {'run': [r'${tool:sh}', '-c', r'echo built > "$OUT"'], 'env': {'OUT': r'${pluginDir}/ran.txt'}},
        {'guide': '只是说明,不执行'},
      ]);
      final progress = <String>[];
      await host.install(m, onProgress: (p) => progress.add(p.message));
      final dir = host.pluginDir('test.fake');
      expect(File('$dir/server/fake-1.2/run.sh').existsSync(), isTrue);
      expect(File('$dir/bin/tool').readAsStringSync(), contains('echo tool'));
      expect((await Process.run('test', ['-x', '$dir/bin/tool'])).exitCode, 0, reason: '加了可执行权限');
      expect(File('$dir/ran.txt').readAsStringSync().trim(), 'built');
      expect(progress.any((p) => p.startsWith('正在下载')), isTrue);
      final installed = host.loadInstalled().single;
      expect(installed.manifest.id, 'test.fake');
      expect(installed.enabled, isTrue);
      host.setEnabled('test.fake', false);
      expect(host.loadInstalled().single.enabled, isFalse);

      final cmd = host.resolve(m.languageServers.single.command.first, pluginId: 'test.fake');
      expect(cmd, '$dir/server/fake-1.2/run.sh');
      final data = host.resolve(r'${dataDir}', pluginId: 'test.fake', projectRoot: '/work/my app');
      expect(data, startsWith('${host.root}/.data/test.fake/my_app-'));
      expect(Directory(data).existsSync(), isTrue);

      await host.uninstall('test.fake');
      expect(host.loadInstalled(), isEmpty);
    });

    test('failures clean up and carry the command output', () async {
      await expectLater(
        host.install(manifest([
          {'run': [r'${tool:sh}', '-c', 'echo something went wrong >&2; exit 3']},
        ])),
        throwsA(isA<PluginInstallException>()
            .having((e) => e.message, 'message', contains('退出码 3'))
            .having((e) => e.log, 'log', contains('something went wrong'))),
      );
      expect(Directory(host.pluginDir('test.fake')).existsSync(), isFalse, reason: '失败的安装不留半成品');
      await expectLater(
        host.install(manifest([
          {'download': '$base/missing.tar.gz', 'extract': 'tar.gz'},
        ])),
        throwsA(isA<PluginInstallException>().having((e) => e.message, 'message', contains('404'))),
      );
      await expectLater(
        host.install(manifest([
          {'download': {'plan9-mips': '$base/pkg.tar.gz'}},
        ])),
        throwsA(isA<PluginInstallException>().having((e) => e.message, 'message', contains('平台'))),
      );
    });

    test('proxy: loopback is direct; system / environment proxies are used for downloads', () {
      expect(PluginHost.findProxy(Uri.parse('http://127.0.0.1:1234/x')), 'DIRECT');
      final p = PluginHost.findProxy(Uri.parse('https://download.eclipse.org/jdtls/x.tar.gz'));
      expect(p == 'DIRECT' || p.startsWith('PROXY '), isTrue, reason: p);
    });

    test('requirements: missing tools and JDK versions are reported before downloading', () {
      final m = manifest(const [], requires: [
        {'tool': 'definitely-missing-tool-xyz', 'hint': '去装它'},
        {'java': 999},
        {'tool': 'sh'},
      ]);
      final unmet = host.unmetRequirements(m);
      expect(unmet.map((r) => r.label), ['definitely-missing-tool-xyz', 'JDK 999+']);
    });
  });

  group('PluginManager', () {
    late Directory tmp;
    late _Client client;
    late LanguageRegistry registry;
    late PluginManager plugins;

    final catalog = jsonEncode({
      'plugins': [
        {
          'id': 'test.lua',
          'name': 'Lua',
          'version': '1.0.0',
          'contributes': {
            'languages': [
              {
                'id': 'lua',
                'name': 'Lua',
                'extensions': ['lua'],
                'syntax': {'keywords': ['local'], 'lineComments': ['--']},
              },
            ],
          },
          'install': [],
        },
        {
          'id': 'test.server',
          'name': 'Fake Lang',
          'version': '1.0.0',
          'sizeMB': 12,
          'contributes': {
            'languages': [
              {'id': 'java', 'name': 'Java', 'extensions': ['java']},
            ],
            'languageServers': [
              {
                'group': 'java',
                'languages': ['java'],
                'command': [r'${pluginDir}/bin/server', '--x'],
                'env': {'HOME_DIR': r'${pluginDir}'},
                'initializeTimeoutSeconds': 99,
                'requestTimeoutSeconds': 7,
                'detect': ['definitely-not-installed-xyz'],
              },
            ],
          },
          'install': [
            {'run': [r'${tool:sh}', '-c', r'mkdir -p "$D/bin" && printf "#!/bin/sh\n" > "$D/bin/server"'], 'env': {'D': r'${pluginDir}'}},
          ],
        },
        {
          'id': 'test.needs',
          'name': 'Needs Tool',
          'version': '1.0.0',
          'requires': [
            {'tool': 'definitely-missing-tool-xyz', 'hint': '先装 xyz'},
          ],
          'contributes': {
            'languages': [
              {'id': 'zz', 'name': 'ZZ', 'extensions': ['zz']},
            ],
            'languageServers': [
              {'group': 'zz', 'languages': ['zz'], 'command': ['zz-server']},
            ],
          },
          'install': [
            {'run': [r'${tool:definitely-missing-tool-xyz}']},
          ],
        },
      ],
    });

    setUp(() {
      tmp = Directory.systemTemp.createTempSync('clx_pm_');
      client = _Client(tmp.path);
      registry = LanguageRegistry(builtinLanguages);
      plugins = PluginManager(client: client, host: PluginHost(root: '${tmp.path}/plugins'), catalogJson: catalog, registry: registry)..load();
    });

    tearDown(() async {
      plugins.dispose();
      await client.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('suggests a plugin for a file type it supports; snooze / dismiss / install silence it', () async {
      expect(plugins.suggestionFor('src/a.lua')?.id, 'test.lua');
      expect(plugins.suggestionFor('src/A.java')?.id, 'test.server');
      expect(plugins.suggestionFor('README.md'), isNull);
      expect(plugins.suggestionFor('Makefile'), isNull);

      plugins.snooze('test.lua');
      expect(plugins.suggestionFor('a.lua'), isNull);

      plugins.dismiss('test.server');
      expect(plugins.suggestionFor('A.java'), isNull);
      // 「不再提示」持久化:重新载入后仍然生效
      final again = PluginManager(client: client, host: PluginHost(root: '${tmp.path}/plugins'), catalogJson: catalog, registry: registry)..load();
      expect(again.suggestionFor('A.java'), isNull);
      expect(again.suggestionFor('a.lua')?.id, 'test.lua', reason: '「以后再说」只在本次运行有效');
      again.dispose();
    });

    test('declarative plugin: install registers the language; disable / uninstall removes it', () async {
      expect(registry.detect('a.lua').id, 'plaintext');
      expect(await plugins.install('test.lua'), isTrue);
      expect(registry.detect('a.lua').id, 'lua');
      expect(plugins.statusOf('test.lua'), PluginStatus.enabled);
      expect(plugins.suggestionFor('a.lua'), isNull);
      await plugins.setEnabled('test.lua', false);
      expect(registry.detect('a.lua').id, 'plaintext');
      await plugins.setEnabled('test.lua', true);
      expect(registry.detect('a.lua').id, 'lua');
      await plugins.uninstall('test.lua');
      expect(registry.detect('a.lua').id, 'plaintext');
      expect(plugins.statusOf('test.lua'), PluginStatus.available);
    });

    test('server plugin: install restarts the server group; launch command is resolved from the plugin', () async {
      expect(plugins.launchFor('java'), isNull);
      expect(await plugins.install('test.server'), isTrue);
      expect(client.reloaded, ['java']);
      final launch = plugins.launchFor('java')!;
      expect(launch.argv, ['${tmp.path}/plugins/test.server/bin/server', '--x']);
      expect(launch.env['HOME_DIR'], '${tmp.path}/plugins/test.server');
      expect(launch.initializeTimeout, const Duration(seconds: 99));
      expect(launch.requestTimeout, const Duration(seconds: 7));
      expect(launch.source, 'test.server');
      expect(client.lspLaunchResolver!('java')!.source, 'test.server', reason: 'LspService 经 ApiClient 拿到它');

      await plugins.setEnabled('test.server', false);
      expect(plugins.launchFor('java'), isNull);
      expect(client.reloaded, ['java', 'java']);
      await plugins.uninstall('test.server');
      expect(Directory('${tmp.path}/plugins/test.server').existsSync(), isFalse);
    });

    test('unmet requirements stop the install with the hint', () async {
      expect(await plugins.install('test.needs'), isFalse);
      final task = plugins.taskOf('test.needs')!;
      expect(task.running, isFalse);
      expect(task.error, contains('definitely-missing-tool-xyz'));
      expect(task.error, contains('先装 xyz'));
      plugins.clearTask('test.needs');
      expect(plugins.taskOf('test.needs'), isNull);
    });

    testWidgets('banner: suggest → install → gone; failures show retry', (tester) async {
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Column(children: [PluginBanner(plugins: plugins, filePath: 'scripts/init.lua'), const Expanded(child: SizedBox())]),
        ),
      ));
      expect(find.textContaining('「Lua」插件可以为 .lua 文件提供语法高亮', findRichText: true), findsOneWidget);
      await tester.runAsync(() async {
        await tester.tap(find.text('安装'));
        for (var i = 0; i < 20 && plugins.statusOf('test.lua') != PluginStatus.enabled; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 20));
        }
      });
      await tester.pump();
      expect(find.byKey(const ValueKey('plugin-banner')), findsNothing, reason: '装好后提示条消失');

      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PluginBanner(plugins: plugins, filePath: 'x.zz')),
      ));
      await tester.runAsync(() async {
        await tester.tap(find.text('安装'));
        await Future<void>.delayed(const Duration(milliseconds: 20));
      });
      await tester.pump();
      expect(find.textContaining('安装失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);
      await tester.tap(find.text('关闭'));
      await tester.pump();
      expect(find.textContaining('安装失败'), findsNothing);
    });

    testWidgets('plugins page lists the catalog with status and filters', (tester) async {
      await tester.binding.setSurfaceSize(const Size(900, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() => plugins.install('test.lua'));
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: SingleChildScrollView(child: PluginsPage(plugins: plugins)))));
      expect(find.text('Lua'), findsOneWidget);
      expect(find.text('Fake Lang'), findsOneWidget);
      expect(find.text('已安装'), findsOneWidget);
      expect(find.text('停用'), findsOneWidget);
      expect(find.textContaining('需要 definitely-missing-tool-xyz'), findsOneWidget);
      // 操作按钮在卡片右下角、靠右:在说明文字下面,右边贴着卡片右侧
      final card = find.byKey(const ValueKey('plugin-test.lua'));
      // 已安装的有「停用」「卸载」两个,最右的是「卸载」
      final button = find.descendant(of: card, matching: find.widgetWithText(OutlinedButton, '卸载'));
      final cardBox = tester.getRect(card), buttonBox = tester.getRect(button);
      expect(tester.getRect(find.descendant(of: card, matching: find.widgetWithText(OutlinedButton, '停用'))).right, lessThan(buttonBox.left));
      expect(buttonBox.top, greaterThan(tester.getRect(find.descendant(of: card, matching: find.text('Lua'))).bottom + 10));
      expect(cardBox.right - buttonBox.right, lessThan(20));
      expect(cardBox.bottom - buttonBox.bottom, lessThan(20));
      await tester.tap(find.text('只看已安装'));
      await tester.pump();
      expect(find.text('Fake Lang'), findsNothing);
      expect(find.text('Lua'), findsOneWidget);
    });
  });
}
