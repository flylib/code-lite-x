import 'package:code_lite_ui/features/project_explorer/project_explorer_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> _dir(String path, List<Map<String, dynamic>> children) =>
    {'name': path.split('/').last, 'path': path, 'is_dir': true, 'children': children};
Map<String, dynamic> _file(String path) => {'name': path.split('/').last, 'path': path, 'is_dir': false};

final _tree = _dir('/p/bcpoker_admin', [
  _dir('/p/bcpoker_admin/.claude', [_file('/p/bcpoker_admin/.claude/settings.json')]),
  _dir('/p/bcpoker_admin/admin-api', [_file('/p/bcpoker_admin/admin-api/pom.xml')]),
  _dir('/p/bcpoker_admin/admin-service', [_file('/p/bcpoker_admin/admin-service/Service.java')]),
  _dir('/p/bcpoker_admin/db', []),
  _file('/p/bcpoker_admin/.bcp-claude.yml'),
  _file('/p/bcpoker_admin/.editorconfig'),
  _file('/p/bcpoker_admin/pom.xml'),
]);

/// 文件树的快速搜索(IntelliJ 的 speed search):文件树有焦点时直接打字就在展开着的节点里找。
void main() {
  test('matching: case-insensitive, contiguous first, else segments that start at word starts (like IntelliJ)', () {
    expect(speedSearchMatch('admin-service', 'SERV'), [6, 7, 8, 9]);
    expect(speedSearchMatch('admin-service', 'admser'), [0, 1, 2, 6, 7, 8]);
    expect(speedSearchMatch('SeaTunnelMigrationGroupController.java', 'stmgc'), [0, 3, 9, 18, 23]);
    expect(speedSearchMatch('SeaTunnelMigrationGroupController.java', 'migcon'), [9, 10, 11, 23, 24, 25]);
    expect(speedSearchMatch('.bcp-claude.yml', 'adm'), isNull, reason: '跳着匹配的每一段都要从词首开始');
    expect(speedSearchMatch('admin-service', 'xyz'), isNull);
    expect(speedSearchMatch('pom.xml', ''), isNull);
  });

  group('tree', () {
    late List<String> opened;

    Future<void> pump(WidgetTester tester) async {
      opened = [];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            SizedBox(
              width: 260,
              height: 500,
              child: ProjectExplorerWidget(treeData: _tree, activeFilePath: '', onSelectFile: opened.add),
            ),
            const Expanded(child: Focus(autofocus: true, child: SizedBox.expand())), // 别处(编辑区)的焦点
          ]),
        ),
      ));
      await tester.pump();
    }

    Future<void> type(WidgetTester tester, String text) async {
      for (final ch in text.split('')) {
        await tester.sendKeyEvent(_keyFor(ch), character: ch);
      }
      await tester.pump();
    }

    final search = find.byKey(const ValueKey('tree-speed-search'));

    testWidgets('typing does nothing until the tree has focus', (tester) async {
      await pump(tester);
      await type(tester, 'pom');
      expect(search, findsNothing, reason: '焦点在别处(编辑区),不是快速搜索');
    });

    testWidgets('click the tree, type: the first match is selected and highlighted; Enter opens it', (tester) async {
      await pump(tester);
      await tester.tap(find.text('db')); // 点一下文件树:获得焦点(db 是空目录,展开没影响)
      await tester.pump();
      await type(tester, 'pom');
      expect(search, findsOneWidget);
      expect(find.descendant(of: search, matching: find.text('pom')), findsOneWidget);
      expect(find.byKey(const ValueKey('match:pom.xml')), findsOneWidget, reason: '匹配的字符高亮');
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(opened, ['/p/bcpoker_admin/pom.xml']);
      expect(search, findsNothing, reason: '回车后退出搜索');
    });

    testWidgets('↓ / ↑ jump between matches; Enter on a folder expands it; only expanded nodes are searched', (tester) async {
      await pump(tester);
      await tester.tap(find.text('db'));
      await tester.pump();
      await type(tester, 'adm'); // 从选中的 db 往下找,没有就回到顶上:根目录 bcpoker_admin
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // → admin-api
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // → admin-service
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp); // ← admin-api
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // → admin-service
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(find.text('Service.java'), findsOneWidget, reason: '展开了 admin-service');
      expect(find.text('pom.xml'), findsOneWidget, reason: 'admin-api 没展开,它下面的 pom.xml 看不到');

      await type(tester, 'settings');
      expect(tester.widget<Text>(find.descendant(of: search, matching: find.text('settings'))).style?.color, isNot(Colors.white));
      final red = tester.widget<Text>(find.descendant(of: search, matching: find.text('settings'))).style?.color;
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.pump();
      expect(find.descendant(of: search, matching: find.text('setting')), findsOneWidget);
      await type(tester, 'zzz');
      final stillRed = tester.widget<Text>(find.descendant(of: search, matching: find.text('settingzzz'))).style?.color;
      expect(stillRed, red, reason: '.claude 没展开,settings.json 不在搜索范围:没匹配就是红字');
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pump();
      expect(search, findsNothing);
    });

    testWidgets('a match turns the text normal; no match turns it red', (tester) async {
      await pump(tester);
      await tester.tap(find.text('db'));
      await tester.pump();
      await type(tester, 'edit');
      final ok = tester.widget<Text>(find.descendant(of: search, matching: find.text('edit'))).style?.color;
      await type(tester, 'q');
      final bad = tester.widget<Text>(find.descendant(of: search, matching: find.text('editq'))).style?.color;
      expect(ok, isNot(bad));
    });

    testWidgets('without a search: arrows move the selection, → expands, Enter opens', (tester) async {
      await pump(tester);
      await tester.tap(find.text('.claude')); // 选中并展开 .claude
      await tester.pump();
      expect(find.text('settings.json'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // settings.json
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(opened, ['/p/bcpoker_admin/.claude/settings.json']);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown); // admin-api
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowRight); // 展开
      await tester.pump();
      expect(find.text('pom.xml'), findsNWidgets(2), reason: 'admin-api/pom.xml 和根目录的 pom.xml');
    });
  });
}

LogicalKeyboardKey _keyFor(String ch) {
  final c = ch.toLowerCase().codeUnitAt(0);
  if (c >= 0x61 && c <= 0x7a) return LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + c - 0x61);
  if (c >= 0x30 && c <= 0x39) return LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + c - 0x30);
  return switch (ch) { '.' => LogicalKeyboardKey.period, '-' => LogicalKeyboardKey.minus, _ => LogicalKeyboardKey.space };
}
