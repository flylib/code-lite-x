import 'dart:io';

import 'package:code_lite_ui/core/fs/workspace_fs.dart' as fs;
import 'package:code_lite_ui/features/project_explorer/project_explorer_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> dir(String path, List<Map<String, dynamic>>? children) => {
      'path': path,
      'name': path.split('/').last,
      'is_dir': true,
      'children': children,
      'loaded': children != null,
    };
Map<String, dynamic> file(String path) => {'path': path, 'name': path.split('/').last, 'is_dir': false, 'children': null};

void main() {
  group('scanTree', () {
    late Directory root;
    setUp(() {
      root = Directory.systemTemp.createTempSync('clx_tree_');
      for (final p in [
        'game-api/src/main/java/com/bcpoker/game/App.java',
        'game-api/src/main/java/com/bcpoker/game/web/a/x/A.java',
        'game-api/src/main/java/com/bcpoker/game/web/a/y/Y.java',
        'game-api/src/main/java/com/bcpoker/game/web/b/B.java',
        'game-api/src/main/java/com/bcpoker/game/svc/Svc.java',
        'game-api/pom.xml',
      ]) {
        File('${root.path}/$p')
          ..parent.createSync(recursive: true)
          ..writeAsStringSync('x');
      }
    });
    tearDown(() => root.deleteSync(recursive: true));

    Map<String, dynamic> child(Map<String, dynamic> n, String name) =>
        (n['children'] as List).cast<Map<String, dynamic>>().firstWhere((c) => c['name'] == name);

    test('deep single-child package chains are scanned past the depth limit; the rest load lazily', () async {
      final tree = await fs.scanTree(root.path, maxDepth: 4);
      // depth: game-api(1) src(2) main(3) java(4) —— java 以下按限制本不扫
      final java = child(child(child(child(tree, 'game-api'), 'src'), 'main'), 'java');
      expect(java['loaded'], isTrue, reason: 'src/main/java 是单子目录链,沿链扫描不占层数');
      final game = child(child(child(java, 'com'), 'bcpoker'), 'game');
      expect(game['loaded'], isTrue);
      final web = child(game, 'web');
      expect(web['loaded'], isTrue);
      // 计入层数的只有分叉:game-api→src、game→web、web→a、a→x,第 4 层之后不再预扫
      final x = child(child(web, 'a'), 'x');
      expect(x['loaded'], isFalse, reason: '超过深度的目录不预扫,展开时再读');
      expect(x['children'], isNull);

      final loaded = await fs.listDirectory(x['path'] as String);
      expect((loaded['children'] as List).map((c) => c['name']), ['A.java']);
    });
  });

  group('ProjectExplorerWidget', () {
    final tree = dir('/p', [
      dir('/p/game-api', [
        dir('/p/game-api/src', [
          dir('/p/game-api/src/main', [
            dir('/p/game-api/src/main/java', [
              dir('/p/game-api/src/main/java/com', [
                dir('/p/game-api/src/main/java/com/bcpoker', [
                  dir('/p/game-api/src/main/java/com/bcpoker/game', null), // 还没扫描
                ]),
              ]),
            ]),
          ]),
        ]),
        file('/p/game-api/pom.xml'),
      ]),
      dir('/p/game-service', [
        dir('/p/game-service/src', [file('/p/game-service/src/Main.java')]),
      ]),
    ]);

    testWidgets('expands by path, compacts Java packages and lazy-loads deep folders', (tester) async {
      final loads = <String>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: ProjectExplorerWidget(
            treeData: tree,
            activeFilePath: '',
            onSelectFile: (_) {},
            onLoadChildren: (path) async {
              loads.add(path);
              return dir(path, [file('$path/GameServer.java'), dir('$path/web', null)]);
            },
          ),
        ),
      ));
      expect(find.text('game-api'), findsOneWidget, reason: '根节点默认展开');
      await tester.tap(find.text('game-api'));
      await tester.pump();
      await tester.tap(find.text('src'));
      await tester.pump();
      expect(find.text('main'), findsOneWidget);
      expect(find.text('Main.java'), findsNothing, reason: '另一个模块的 src 不跟着展开');

      await tester.tap(find.text('main'));
      await tester.pump();
      await tester.tap(find.text('java'));
      await tester.pump();
      expect(find.text('com.bcpoker.game'), findsOneWidget, reason: '包链压成一行');

      await tester.tap(find.text('com.bcpoker.game'));
      await tester.pump();
      expect(loads, ['/p/game-api/src/main/java/com/bcpoker/game']);
      await tester.pump();
      expect(find.text('GameServer.java'), findsOneWidget);
      expect(find.text('web'), findsOneWidget);
    });
  });
}
