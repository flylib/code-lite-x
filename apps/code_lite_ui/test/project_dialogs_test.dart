import 'dart:async';

import 'package:code_lite_ui/features/title_bar/project_dialogs.dart';
import 'package:code_lite_ui/features/title_bar/project_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 一个按钮,点了弹对话框,把结果存下来。
Widget host(Future<String?> Function(BuildContext) open, void Function(String?) done) => MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => done(await open(context)),
            child: const Text('open'),
          ),
        ),
      ),
    );

void main() {
  test('~ is expanded to the home folder, other paths are left alone', () {
    expect(expandHome('~/code', '/Users/dev'), '/Users/dev/code');
    expect(expandHome('~', '/Users/dev'), '/Users/dev');
    expect(expandHome('  /opt/x ', '/Users/dev'), '/opt/x');
    expect(expandHome('~other/x', '/Users/dev'), '~other/x');
    expect(expandHome('~/x', null), '~/x');
  });

  testWidgets('New Project asks for a name and a location and returns the created folder', (tester) async {
    String? result = 'unset';
    final calls = <(String, String)>[];
    await tester.pumpWidget(host(
      (c) => showNewProjectDialog(
        c,
        initialLocation: '/Users/dev/Worker',
        home: '/Users/dev',
        create: (parent, name) async {
          calls.add((parent, name));
          return ('$parent/$name', null);
        },
      ),
      (r) => result = r,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('New Project'), findsOneWidget);
    expect(find.widgetWithText(TextField, '~/Worker'), findsOneWidget, reason: '位置缩写成 ~');

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pump();
    expect(find.text('请填写 Name'), findsOneWidget);
    expect(calls, isEmpty);

    await tester.enterText(find.widgetWithText(TextField, '').first, ' my-app ');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(calls, [('/Users/dev/Worker', 'my-app')], reason: '~ 展开后传给创建函数,名字去掉空白');
    expect(result, '/Users/dev/Worker/my-app');
    expect(find.text('New Project'), findsNothing);
  });

  testWidgets('a failure stays in the dialog with the reason, and the form can be fixed and retried', (tester) async {
    var attempts = 0;
    String? result = 'unset';
    await tester.pumpWidget(host(
      (c) => showNewProjectDialog(c, initialLocation: '/p', create: (parent, name) async {
        attempts++;
        return attempts == 1 ? (null, '目录已存在且不为空: $parent/$name') : ('$parent/$name', null);
      }),
      (r) => result = r,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'x');
    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(find.textContaining('目录已存在且不为空: /p/x'), findsOneWidget);
    expect(result, 'unset');

    await tester.tap(find.widgetWithText(FilledButton, 'Create'));
    await tester.pumpAndSettle();
    expect(result, '/p/x');
  });

  testWidgets('while it works the form is locked and shows progress', (tester) async {
    final gate = Completer<ProjectResult>();
    String? result = 'unset';
    await tester.pumpWidget(host(
      (c) => showCloneDialog(c, initialLocation: '/p', clone: (url, parent, {name}) => gate.future),
      (r) => result = r,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).first, 'git@host:o/repo.git');
    await tester.tap(find.widgetWithText(FilledButton, 'Clone'));
    await tester.pump();
    expect(find.text('正在克隆…'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Clone')).onPressed, isNull);
    expect(tester.widget<TextButton>(find.widgetWithText(TextButton, 'Cancel')).onPressed, isNull);

    gate.complete(('/p/repo', null));
    await tester.pumpAndSettle();
    expect(result, '/p/repo');
  });

  testWidgets('Clone passes the address, location and the optional folder name; the name box hints the default', (tester) async {
    final calls = <(String, String, String?)>[];
    await tester.pumpWidget(host(
      (c) => showCloneDialog(c, initialLocation: '/p', clone: (url, parent, {name}) async {
        calls.add((url, parent, name));
        return ('$parent/${name ?? 'repo'}', null);
      }),
      (_) {},
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField).at(0), 'git@github.com:flylib/code-lite-x.git');
    await tester.pump();
    expect(find.text('code-lite-x'), findsOneWidget, reason: '名字框里提示默认目录名');

    await tester.tap(find.widgetWithText(FilledButton, 'Clone'));
    await tester.pumpAndSettle();
    expect(calls, [('git@github.com:flylib/code-lite-x.git', '/p', null)]);
  });

  testWidgets('Choose… puts the picked folder into Location, Cancel returns nothing', (tester) async {
    String? result = 'unset';
    await tester.pumpWidget(host(
      (c) => showNewProjectDialog(c, initialLocation: '/p', home: '/Users/dev', pickDirectory: () async => '/Users/dev/elsewhere'),
      (r) => result = r,
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Choose…'));
    await tester.pumpAndSettle();
    expect(find.widgetWithText(TextField, '~/elsewhere'), findsOneWidget);
    await tester.tap(find.widgetWithText(TextButton, 'Cancel'));
    await tester.pumpAndSettle();
    expect(result, isNull);
  });
}
