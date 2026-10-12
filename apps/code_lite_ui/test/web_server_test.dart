import 'dart:convert';
import 'dart:io';

import 'package:code_lite_ui/core/platform/browsers.dart';
import 'package:code_lite_ui/core/platform/web_server.dart';
import 'package:code_lite_ui/core/plugins/plugin_host.dart';
import 'package:code_lite_ui/core/plugins/plugin_manager.dart';
import 'package:code_lite_ui/core/state/layout_store.dart';
import 'package:code_lite_ui/core/state/project_manager.dart';
import 'package:code_lite_ui/core/state/session_snapshot.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/open_in_browser.dart';
import 'package:flutter_test/flutter_test.dart';

/// 浏览器里打开 HTML 走项目自己的服务器:http://localhost:63342/<项目名>/<相对路径>(同 IntelliJ),项目关闭时服务器随之关闭。
void main() {
  late Directory tmp;
  late String root;
  late BuiltInWebServer server;

  /// 测试不用真的 63342(开发机上可能开着 IntelliJ 或 CodeLiteX):找一个空端口当首选。
  Future<int> freePort() async {
    final s = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final p = s.port;
    await s.close();
    return p;
  }

  Future<(int, String, String?)> get(String url, {String? host, String method = 'GET'}) async {
    final client = HttpClient();
    try {
      final uri = Uri.parse(url);
      final req = await client.openUrl(method, uri.replace(host: '127.0.0.1'));
      req.followRedirects = false;
      req.headers.set(HttpHeaders.hostHeader, host ?? '${uri.host}:${uri.port}');
      final res = await req.close();
      final body = await res.transform(utf8.decoder).join();
      return (res.statusCode, body, res.headers.contentType?.mimeType);
    } finally {
      client.close(force: true);
    }
  }

  setUp(() async {
    tmp = Directory.systemTemp.createTempSync('clx_web_');
    root = '${tmp.path}/bcpoker_admin';
    Directory('$root/admin/css').createSync(recursive: true);
    File('$root/admin/index.html').writeAsStringSync('<link rel="stylesheet" href="css/a.css"><h1>admin</h1>');
    File('$root/admin/css/a.css').writeAsStringSync('h1{color:red}');
    File('$root/admin/页面 一.html').writeAsStringSync('<p>中文</p>');
    File('${tmp.path}/secret.txt').writeAsStringSync('outside the project');
    server = BuiltInWebServer(root: root, preferredPort: await freePort());
  });

  tearDown(() async {
    await server.close();
    tmp.deleteSync(recursive: true);
  });

  test('address is http://localhost:<port>/<project>/<path>; pages and their relative assets load with the right types', () async {
    final url = await server.urlFor('$root/admin/index.html');
    expect(url, 'http://localhost:${server.port}/bcpoker_admin/admin/index.html');
    expect(await server.urlFor('admin/index.html'), url, reason: '相对项目的路径也行');

    final (status, body, type) = await get(url!);
    expect((status, type), (200, 'text/html'));
    expect(body, contains('<h1>admin</h1>'));
    final css = await get(url.replaceFirst('index.html', 'css/a.css'));
    expect((css.$1, css.$3), (200, 'text/css'));

    // 改了文件刷新就是新的(不缓存)
    File('$root/admin/index.html').writeAsStringSync('<h1>changed</h1>');
    expect((await get(url)).$2, '<h1>changed</h1>');
  });

  test('names with spaces / Chinese are encoded in the address and served', () async {
    final url = await server.urlFor('$root/admin/页面 一.html');
    expect(url, contains('%E9%A1%B5%E9%9D%A2%20%E4%B8%80.html'));
    final (status, body, _) = await get(url!);
    expect(status, 200);
    expect(body, '<p>中文</p>');
  });

  test('a folder redirects to its trailing-slash form and serves index.html', () async {
    await server.urlFor('$root/admin/index.html');
    final base = 'http://localhost:${server.port}/bcpoker_admin/admin';
    final (status, _, _) = await get(base);
    expect(status, HttpStatus.movedPermanently);
    expect((await get('$base/')).$2, contains('<h1>admin</h1>'));
  });

  test('cannot leave the project folder, other hosts are refused (DNS rebinding), only GET / HEAD', () async {
    final url = (await server.urlFor('$root/admin/index.html'))!;
    final base = 'http://localhost:${server.port}/bcpoker_admin';
    expect((await get('$base/%2E%2E/secret.txt')).$1, HttpStatus.notFound);
    expect((await get('$base/admin%2F..%2F..%2Fsecret.txt')).$1, HttpStatus.notFound);
    expect((await get('http://localhost:${server.port}/nope/index.html')).$1, HttpStatus.notFound);
    expect(await server.urlFor('${tmp.path}/secret.txt'), isNull, reason: '项目外的文件按文件打开');

    expect((await get(url, host: 'evil.example.com')).$1, HttpStatus.forbidden);
    expect((await get(url, host: '127.0.0.1:${server.port}')).$1, 200);
    expect((await get(url, method: 'POST')).$1, HttpStatus.methodNotAllowed);
    final head = await get(url, method: 'HEAD');
    expect((head.$1, head.$2), (200, ''));
  });

  test('the preferred port is taken (IntelliJ running): the next free one is used', () async {
    final busy = await ServerSocket.bind(InternetAddress.loopbackIPv4, 0);
    final s = BuiltInWebServer(root: root, preferredPort: busy.port);
    try {
      final url = await s.urlFor('$root/admin/index.html');
      expect(s.port, isNot(busy.port));
      expect(url, startsWith('http://localhost:${s.port}/'));
      expect((await get(url!)).$1, 200);
    } finally {
      await s.close();
      await busy.close();
    }
  });

  test('closing the server frees its port and it gives no more addresses', () async {
    final url = (await server.urlFor('$root/admin/index.html'))!;
    final port = server.port!;
    expect((await get(url)).$1, 200);
    await server.close();
    expect(server.port, isNull);
    expect(await server.urlFor('$root/admin/index.html'), isNull);
    await expectLater(get(url), throwsA(isA<SocketException>()), reason: '端口上已经没有服务');
    final again = await ServerSocket.bind(InternetAddress.loopbackIPv4, port);
    await again.close();
  });

  test('each open project has its own server; closing the project closes it, the other keeps serving', () async {
    final other = '${tmp.path}/other_site';
    Directory(other).createSync();
    File('$other/index.html').writeAsStringSync('other');
    final layout = LayoutStore();
    final settings = SettingsStore(appearance: EditorAppearance(), layout: layout, load: () async => {}, save: (_) async {});
    final plugins = PluginManager(host: PluginHost(root: '${tmp.path}/.plugins'));
    final manager = ProjectManager(
      layout: layout,
      plugins: plugins,
      settings: settings,
      store: OpenProjectsStore(load: () async => {}, save: (_) async {}),
      sessionStore: SessionStore(load: () async => {}, save: (_) async {}),
      loadRecent: () async => [],
      saveRecent: (_) async {},
    );
    try {
      expect(await manager.open(root), isTrue);
      final adminUrl = (await manager.active.browserUrlFor('$root/admin/index.html'))!;
      expect(adminUrl, matches(RegExp(r'^http://localhost:\d+/bcpoker_admin/admin/index\.html$')));
      expect(await manager.open(other), isTrue);
      final otherUrl = (await manager.active.browserUrlFor('$other/index.html'))!;
      expect(Uri.parse(otherUrl).port, isNot(Uri.parse(adminUrl).port), reason: '两个项目两个服务器');
      expect((await get(adminUrl)).$1, 200);

      await manager.close(manager.find(root)!);
      await expectLater(get(adminUrl), throwsA(isA<SocketException>()), reason: '项目关了,它的服务器也关了');
      expect((await get(otherUrl)).$2, 'other', reason: '别的项目照常');
    } finally {
      manager.dispose();
      settings.dispose();
      plugins.dispose();
      layout.dispose();
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
  });

  test('the browser bar opens the http address; without one (outside the project) it falls back to the file', () async {
    final opened = <String>[];
    final service = BrowserService(
      detect: () async => const [],
      open: (b, target) async {
        opened.add(target);
        return null;
      },
      urlFor: (projectRoot, file) => server.urlFor(file),
    );
    const chrome = BrowserApp(id: 'chrome', name: 'Google Chrome', path: '/Applications/Google Chrome.app');
    await service.open(chrome, '$root/admin/index.html', projectRoot: root);
    await service.open(chrome, '${tmp.path}/secret.txt', projectRoot: root);
    await service.open(chrome, '$root/admin/index.html');
    expect(opened, [
      'http://localhost:${server.port}/bcpoker_admin/admin/index.html',
      '${tmp.path}/secret.txt',
      '$root/admin/index.html',
    ]);
  });

  test('content types', () {
    expect(contentTypeOf('a.js'), startsWith('text/javascript'));
    expect(contentTypeOf('a.SVG'), 'image/svg+xml');
    expect(contentTypeOf('font.woff2'), 'font/woff2');
    expect(contentTypeOf('blob'), 'application/octet-stream');
  });
}
