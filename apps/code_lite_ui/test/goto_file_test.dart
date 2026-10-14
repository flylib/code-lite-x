import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/search/goto_file_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Go to File(⇧⌘O):文件清单常驻 Rust,按文件名模糊查找;`Foo.java:120` 跳到那一行。
void main() {
  test('query text: name, optional :line and :column', () {
    expect(parseGotoQuery('Main.java'), ('Main.java', null, null));
    expect(parseGotoQuery('Main.java:120'), ('Main.java', 120, null));
    expect(parseGotoQuery('Main.java:120:5'), ('Main.java', 120, 5));
    expect(parseGotoQuery('  src/Foo  '), ('src/Foo', null, null));
  });

  test('the Rust index: builds in the background, then fuzzy-matches file names', () async {
    final root = Directory.systemTemp.createTempSync('clx_goto_');
    addTearDown(() => root.deleteSync(recursive: true));
    for (final f in ['admin-service/src/SeaTunnelMigrationGroupController.java', 'admin-api/pom.xml', 'pom.xml', 'target/Junk.class']) {
      File('${root.path}/$f')
        ..parent.createSync(recursive: true)
        ..writeAsStringSync('x');
    }
    final client = ApiClient(initialRoot: root.path);
    addTearDown(client.dispose);
    var r = client.fileIndexQuery('stmgc');
    if (r['status'] != 'ok') return; // 没编出 Rust 库
    for (var i = 0; i < 100 && r['ready'] != true; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
      r = client.fileIndexQuery('stmgc');
    }
    expect(r['ready'], isTrue);
    expect(r['files'], 3, reason: 'target/ 不收');
    expect((r['results'] as List).first['path'], 'admin-service/src/SeaTunnelMigrationGroupController.java');
    expect([for (final h in client.fileIndexQuery('pom')['results'] as List) h['path']], ['pom.xml', 'admin-api/pom.xml']);

    // 新建的文件:重扫后出现
    File('${root.path}/NewThing.dart').writeAsStringSync('x');
    client.fileIndexRefresh();
    for (var i = 0; i < 100 && (client.fileIndexQuery('newthing')['results'] as List).isEmpty; i++) {
      await Future<void>.delayed(const Duration(milliseconds: 20));
    }
    expect((client.fileIndexQuery('newthing')['results'] as List).single['path'], 'NewThing.dart');
  });

  group('dialog', () {
    late List<String> queries;
    var ready = true;

    Map<String, dynamic> fake(String q, int limit) {
      queries.add(q);
      const files = ['src/main/java/com/acme/OrderService.java', 'src/main/java/com/acme/OrderController.java', 'README.md'];
      final hits = [
        for (final f in files)
          if (q != '\u0000' && f.split('/').last.toLowerCase().contains(q.toLowerCase()))
            {'path': f, 'score': 1, 'indices': [for (var i = 0; i < q.length; i++) f.lastIndexOf('/') + 1 + f.split('/').last.toLowerCase().indexOf(q.toLowerCase()) + i]},
      ];
      return {'status': 'ok', 'ready': ready, 'building': false, 'files': files.length, 'generation': ready ? 1 : 0, 'results': ready ? hits : []};
    }

    Future<GotoFileTarget?> open(WidgetTester tester, {List<String> recent = const []}) async {
      GotoFileTarget? result;
      var closed = false;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async {
              result = await showGotoFileDialog(context, query: fake, recent: recent);
              closed = true;
            },
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      return closed ? result : null;
    }

    setUp(() {
      queries = [];
      ready = true;
    });

    testWidgets('empty: the open tabs; typing filters with highlights; arrows + Enter open with the :line', (tester) async {
      GotoFileTarget? picked;
      await tester.pumpWidget(MaterialApp(
        home: Builder(
          builder: (context) => TextButton(
            onPressed: () async => picked = await showGotoFileDialog(context, query: fake, recent: const ['README.md']),
            child: const Text('go'),
          ),
        ),
      ));
      await tester.tap(find.text('go'));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('goto-file-row-README.md')), findsOneWidget, reason: '没输入时列出打开着的文件');

      await tester.enterText(find.byKey(const ValueKey('goto-file-input')), 'order:42');
      await tester.pump();
      expect(queries.last, 'order', reason: ':行号 不参与匹配');
      expect(find.byKey(const ValueKey('goto-file-row-src/main/java/com/acme/OrderService.java')), findsOneWidget);
      expect(find.byKey(const ValueKey('goto-file-row-src/main/java/com/acme/OrderController.java')), findsOneWidget);
      expect(find.byKey(const ValueKey('goto-file-row-README.md')), findsNothing);
      expect(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'OrderService.java'), findsOneWidget, reason: '匹配字符高亮');

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(picked?.path, 'src/main/java/com/acme/OrderController.java');
      expect(picked?.line, 42);
    });

    testWidgets('index still building: a hint, then results appear on their own', (tester) async {
      ready = false;
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('goto-file-input')), 'order');
      await tester.pump();
      expect(find.text('正在建立文件索引…'), findsOneWidget);
      ready = true;
      await tester.pump(const Duration(milliseconds: 150));
      expect(find.byKey(const ValueKey('goto-file-row-src/main/java/com/acme/OrderService.java')), findsOneWidget);
    });

    testWidgets('no match says so; Esc closes without opening anything', (tester) async {
      await open(tester);
      await tester.enterText(find.byKey(const ValueKey('goto-file-input')), 'zzz');
      await tester.pump();
      expect(find.textContaining('没有匹配的文件'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('goto-file-input')), findsNothing);
    });
  });
}
