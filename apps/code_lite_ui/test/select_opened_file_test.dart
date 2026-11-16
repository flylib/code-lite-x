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
  // 一个模块里有很多文件(把目标挤到视口外),目标在还没扫描的深层包里
  final tree = dir('/p', [
    dir('/p/pay-service', [
      dir('/p/pay-service/src', [
        dir('/p/pay-service/src/main', [
          dir('/p/pay-service/src/main/java', [
            dir('/p/pay-service/src/main/java/com', [
              dir('/p/pay-service/src/main/java/com/bcpoker', [
                dir('/p/pay-service/src/main/java/com/bcpoker/pay', [
                  dir('/p/pay-service/src/main/java/com/bcpoker/pay/mq', [file('/p/pay-service/src/main/java/com/bcpoker/pay/mq/Mq.java')]),
                  dir('/p/pay-service/src/main/java/com/bcpoker/pay/scheduler', null), // 还没扫描
                ]),
              ]),
            ]),
          ]),
        ]),
      ]),
    ]),
    for (var i = 0; i < 60; i++) file('/p/z$i.txt'),
  ]);
  const scheduler = '/p/pay-service/src/main/java/com/bcpoker/pay/scheduler';
  const target = '$scheduler/MerchantRetryRecovery.java';

  Future<List<String>> pump(WidgetTester tester, {String active = target}) async {
    final loads = <String>[];
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          height: 300,
          child: ProjectExplorerWidget(
            treeData: tree,
            activeFilePath: active,
            onSelectFile: (_) {},
            onLoadChildren: (path) async {
              loads.add(path);
              return dir(path, [
                file('$path/CasinoPointExpireScheduler.java'),
                file('$path/MerchantRetryRecovery.java'),
                file('$path/RefreshScheduler.java'),
              ]);
            },
          ),
        ),
      ),
    ));
    return loads;
  }

  testWidgets('the target button expands the folders down to the open file, selects it and scrolls to it', (tester) async {
    final loads = await pump(tester);
    expect(find.text('MerchantRetryRecovery.java'), findsNothing);
    expect(find.text('pay-service'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('tree-select-opened')));
    await tester.pumpAndSettle();

    expect(loads, [scheduler], reason: '没扫描过的目录先读出来');
    expect(find.text('com.bcpoker.pay'), findsOneWidget, reason: '包链照样压成一行');
    expect(find.text('scheduler'), findsOneWidget);
    expect(find.text('Mq.java'), findsNothing, reason: '只展开目标所在的那一路');
    final row = find.text('MerchantRetryRecovery.java');
    expect(row, findsOneWidget);
    expect(find.text('RefreshScheduler.java'), findsOneWidget, reason: '同目录的兄弟也列出来');
    // 选中:那一行有选中底色
    final box = tester.widget<Container>(find.descendant(of: find.byKey(const ValueKey('file:$target')), matching: find.byType(Container)).first);
    expect((box.decoration as BoxDecoration?)?.color, isNotNull);
    // 在视口里
    final y = tester.getTopLeft(row).dy;
    expect(y, greaterThan(0));
    expect(y, lessThan(300));
  });

  testWidgets('the button is disabled when the open file is not in this tree', (tester) async {
    await pump(tester, active: '/elsewhere/Foo.java');
    final ink = tester.widget<InkWell>(find.byKey(const ValueKey('tree-select-opened')));
    expect(ink.onTap, isNull);
    await pump(tester, active: '');
    expect(tester.widget<InkWell>(find.byKey(const ValueKey('tree-select-opened'))).onTap, isNull);
  });
}
