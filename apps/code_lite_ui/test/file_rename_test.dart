import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/state/session_snapshot.dart';
import 'package:code_lite_ui/core/state/workspace_store.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:code_lite_ui/features/project_explorer/project_explorer_widget.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 文件树右键 ▸ Rename(⇧F6):改磁盘上的名字,打开着的标签跟过去。
void main() {
  group('tree context menu', () {
    Map<String, dynamic> node(String path, {List<Map<String, dynamic>>? children}) => {
          'path': path,
          'name': path.split('/').last,
          'is_dir': children != null,
          'loaded': true,
          'children': children,
        };

    final tree = node('/p', children: [
      node('/p/src', children: [node('/p/src/Main.java'), node('/p/src/util', children: [node('/p/src/util/A.java')])]),
      node('/p/README.md'),
    ]);

    late List<(String, String)> calls;
    String? failWith;

    Future<void> pump(WidgetTester tester, {bool canRename = true}) async {
      calls = [];
      failWith = null;
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 500,
            child: ProjectExplorerWidget(
              treeData: tree,
              activeFilePath: '',
              onSelectFile: (_) {},
              onRename: canRename
                  ? (path, name) async {
                      calls.add((path, name));
                      return failWith;
                    }
                  : null,
            ),
          ),
        ),
      ));
    }

    testWidgets('right-click a file ▸ Rename... asks for the new name with the part before the extension selected', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('dir:/p/src')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('file:/p/src/Main.java')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(find.textContaining('F6'), findsOneWidget, reason: '菜单项后面显示快捷键(macOS 上是 ⇧F6)');
      await tester.tap(find.byKey(const ValueKey('tree-menu-rename')));
      await tester.pumpAndSettle();

      expect(find.text("Rename file 'Main.java' to:"), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const ValueKey('rename-field')));
      expect(field.controller!.selection, const TextSelection(baseOffset: 0, extentOffset: 4), reason: '选中 Main,不选 .java');

      await tester.enterText(find.byKey(const ValueKey('rename-field')), 'App.java');
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(calls, [('/p/src/Main.java', 'App.java')]);
      expect(find.byKey(const ValueKey('rename-field')), findsNothing, reason: '改成功就关');
    });

    testWidgets('Shift+F6 renames the selected directory and keeps it (and what is open under it) expanded', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('dir:/p/src')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('dir:/p/src/util')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('dir:/p/src')));
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('dir:/p/src')));
      await tester.pump();
      expect(find.byKey(const ValueKey('file:/p/src/util/A.java')), findsOneWidget);

      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.f6);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.pumpAndSettle();
      expect(find.text("Rename directory 'src' to:"), findsOneWidget);
      final field = tester.widget<TextField>(find.byKey(const ValueKey('rename-field')));
      expect(field.controller!.selection, const TextSelection(baseOffset: 0, extentOffset: 3), reason: '目录选中整个名字');

      await tester.enterText(find.byKey(const ValueKey('rename-field')), 'main');
      await tester.tap(find.byKey(const ValueKey('rename-confirm')));
      await tester.pumpAndSettle();
      expect(calls, [('/p/src', 'main')]);

      // 外面重读了文件树(这里换一份新路径的树),改了名的目录和它下面展开的照旧展开
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 320,
            height: 500,
            child: ProjectExplorerWidget(
              treeData: node('/p', children: [
                node('/p/main', children: [node('/p/main/Main.java'), node('/p/main/util', children: [node('/p/main/util/A.java')])]),
              ]),
              activeFilePath: '',
              onSelectFile: (_) {},
              onRename: (_, __) async => null,
            ),
          ),
        ),
      ));
      expect(find.byKey(const ValueKey('file:/p/main/util/A.java')), findsOneWidget);
    });

    testWidgets('a failed rename keeps the dialog open with the reason; bad names are refused before trying', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('file:/p/README.md')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('tree-menu-rename')));
      await tester.pumpAndSettle();

      await tester.enterText(find.byKey(const ValueKey('rename-field')), 'a/b.md');
      await tester.tap(find.byKey(const ValueKey('rename-confirm')));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rename-error')), findsOneWidget);
      expect(calls, isEmpty);

      failWith = '已存在: NOTES.md';
      await tester.enterText(find.byKey(const ValueKey('rename-field')), 'NOTES.md');
      await tester.tap(find.byKey(const ValueKey('rename-confirm')));
      await tester.pumpAndSettle();
      expect(calls, [('/p/README.md', 'NOTES.md')]);
      expect(find.text('已存在: NOTES.md'), findsOneWidget);
      expect(find.byKey(const ValueKey('rename-field')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('rename-field')), findsNothing);
    });

    testWidgets('the project root and a single opened file cannot be renamed here', (tester) async {
      await pump(tester);
      await tester.tap(find.byKey(const ValueKey('dir:/p')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(tester.widget<MenuItemButton>(find.byKey(const ValueKey('tree-menu-rename'))).onPressed, isNull);
      await tester.tapAt(const Offset(5, 495));
      await tester.pumpAndSettle();

      await pump(tester, canRename: false);
      await tester.tap(find.byKey(const ValueKey('file:/p/README.md')), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      expect(tester.widget<MenuItemButton>(find.byKey(const ValueKey('tree-menu-rename'))).onPressed, isNull);
    });
  });

  group('WorkspaceStore.renamePath', () {
    late Directory tmp;
    late String root;
    late ApiClient client;
    late EditorSessionManager sessions;
    late WorkspaceStore w;

    setUp(() async {
      tmp = Directory.systemTemp.createTempSync('clx_rename_');
      root = '${tmp.path}/proj';
      Directory('$root/pkg/inner').createSync(recursive: true);
      File('$root/one.txt').writeAsStringSync('one\n');
      File('$root/two.txt').writeAsStringSync('two\n');
      File('$root/pkg/a.txt').writeAsStringSync('a\n');
      File('$root/pkg/inner/b.txt').writeAsStringSync('b\n');
      client = ApiClient(initialRoot: root);
      sessions = EditorSessionManager(client: client);
      w = WorkspaceStore(
        client: client,
        sessions: sessions,
        sessionStore: SessionStore(load: () async => {}, save: (_) async {}),
        loadRecent: () async => [],
        saveRecent: (_) async {},
      );
      expect(await w.openFolder(root), isTrue);
    });

    tearDown(() async {
      w.dispose();
      sessions.dispose();
      await client.dispose();
      tmp.deleteSync(recursive: true);
    });

    test('renames the file, saves unsaved edits first, and the open tab follows with its text, caret and undo', () async {
      await w.openFile('one.txt');
      final tab = sessions.tabs['one.txt']!;
      tab.controller.setCursor(const EditorPosition(0, 3));
      tab.controller.insertText('!');
      expect(tab.isDirty, isTrue);

      expect(await w.renamePath('$root/one.txt', 'uno.txt'), isNull);
      expect(File('$root/one.txt').existsSync(), isFalse);
      expect(File('$root/uno.txt').readAsStringSync(), 'one!\n', reason: '没保存的修改先写进去再改名');
      expect(sessions.tabs.containsKey('one.txt'), isFalse);
      expect(identical(sessions.tabs['uno.txt'], tab), isTrue, reason: '还是那个标签,相对路径照旧用相对路径');
      expect(sessions.activePath, 'uno.txt');
      expect(sessions.openPaths, ['uno.txt']);
      expect(tab.fileName, 'uno.txt');
      expect(tab.controller.cursorPosition, const EditorPosition(0, 4));
      expect(tab.controller.undo(), isTrue, reason: '撤销历史还在');

      // 之后的修改保存到新文件
      expect(await sessions.saveFile('uno.txt'), isTrue);
      expect(File('$root/uno.txt').readAsStringSync(), 'one\n');
      final names = [for (final c in w.tree['children'] as List) c['name']];
      expect(names, containsAll(['uno.txt', 'two.txt']));
      expect(names, isNot(contains('one.txt')), reason: '文件树重读了');
    });

    test('renaming a directory moves every open tab under it (absolute paths from the tree stay absolute)', () async {
      await w.openFile('$root/pkg/a.txt');
      await w.openFile('pkg/inner/b.txt');
      await w.openFile('two.txt');

      expect(await w.renamePath('$root/pkg', 'lib'), isNull);
      expect(Directory('$root/lib/inner').existsSync(), isTrue);
      expect(sessions.openPaths, ['$root/lib/a.txt', 'lib/inner/b.txt', 'two.txt']);
      expect(sessions.activePath, 'two.txt');
      expect(sessions.tabs['$root/lib/a.txt']!.controller.text, 'a\n');
    });

    test('refuses to overwrite an existing file and rejects names with a slash', () async {
      expect(await w.renamePath('$root/one.txt', 'two.txt'), contains('已存在'));
      expect(File('$root/one.txt').readAsStringSync(), 'one\n');
      expect(File('$root/two.txt').readAsStringSync(), 'two\n');
      expect(await w.renamePath('$root/one.txt', 'x/y.txt'), isNotNull);
      expect(await w.renamePath('$root/one.txt', '  '), isNotNull);
      expect(await w.renamePath('$root/one.txt', 'one.txt'), isNull, reason: '没改就什么也不做');
    });

    test('changing only the case works (macOS disks ignore case)', () async {
      expect(await w.renamePath('$root/one.txt', 'ONE.txt'), isNull);
      expect(Directory(root).listSync().map((e) => e.path.split('/').last), contains('ONE.txt'));
    });
  });
}
