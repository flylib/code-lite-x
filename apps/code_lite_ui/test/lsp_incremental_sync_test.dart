import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/lsp/lsp_common.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 记录发给语言服务器的同步消息,不启动任何服务端进程。
class _RecordingClient extends ApiClient {
  _RecordingClient(String root) : super(initialRoot: root);

  final List<String> full = [];
  final List<List<LspTextChange>> incremental = [];
  bool serverHasDoc = true;

  @override
  Future<void> lspDidOpen(String path, String text) async {}

  @override
  Future<void> lspDidChange(String path, String text) async => full.add(text);

  @override
  Future<bool> lspDidChangeIncremental(String path, List<LspTextChange> changes) async {
    if (!serverHasDoc) return false;
    incremental.add(changes);
    return true;
  }

  @override
  Future<void> lspDidClose(String path) async {}
}

void main() {
  late Directory dir;
  late _RecordingClient client;
  late EditorSessionManager sessions;
  const original = 'class A {\n  int x = 1;\n}\n';

  setUp(() {
    dir = Directory.systemTemp.createTempSync('clx_lspsync_');
    File('${dir.path}/A.java').writeAsStringSync(original);
    client = _RecordingClient(dir.path);
    sessions = EditorSessionManager(client: client)..autosave = false;
  });

  tearDown(() async {
    sessions.dispose();
    await client.dispose();
    dir.deleteSync(recursive: true);
  });

  Future<void> debounce() => Future<void>.delayed(const Duration(milliseconds: 450));

  test('typing sends one batch of ranges after the pause; applying them reproduces the editor text', () async {
    final tab = await sessions.openFile('A.java');
    final c = tab.controller;
    c.setCursor(const EditorPosition(1, 11));
    for (final ch in ' + 2'.split('')) {
      c.insertText(ch);
    }
    c.insertNewline();
    c.insertText('int y;');
    c.deleteBackward();
    c.setSelection(const EditorPosition(0, 6), const EditorPosition(0, 7));
    c.insertText('Big');
    await debounce();
    expect(client.full, isEmpty, reason: '没有发全文');
    expect(client.incremental, hasLength(1), reason: '防抖期间的改动合成一次发送');
    expect(lspApplyChanges(original, client.incremental.single), c.text);

    // 撤销也是增量
    c.undo();
    await debounce();
    expect(client.incremental, hasLength(2));
    expect(lspApplyChanges(lspApplyChanges(original, client.incremental[0]), client.incremental[1]), c.text);
  });

  test('reload from disk and unknown documents fall back to full text', () async {
    final tab = await sessions.openFile('A.java');
    File('${dir.path}/A.java').writeAsStringSync('class B {}\n');
    await sessions.reloadFromDisk(['A.java']);
    expect(client.full.last, 'class B {}\n');
    tab.controller.insertText('// ');
    await debounce();
    expect(client.incremental.single.single.text, '// ', reason: '重新载入后照常增量');

    client.serverHasDoc = false;
    tab.controller.insertText('x');
    await debounce();
    expect(client.full.last, tab.controller.text, reason: '服务端还没有这份文档:改发全文');
  });

  test('a flood of edits within one pause is sent as full text instead', () async {
    final tab = await sessions.openFile('A.java');
    for (var i = 0; i < 250; i++) {
      tab.controller.insertText('z');
    }
    await debounce();
    expect(client.incremental, isEmpty);
    expect(client.full.single, tab.controller.text);
  });

  test('typing does not notify session listeners except for the dirty-state change', () async {
    final tab = await sessions.openFile('A.java');
    var notified = 0;
    sessions.addListener(() => notified++);
    for (final ch in 'hello'.split('')) {
      tab.controller.insertText(ch);
    }
    expect(notified, 1, reason: '只有「未修改 → 已修改」通知一次,标签上的圆点据此刷新');
  });

  testWidgets('typing rebuilds the editor pane but not the tab bar', (tester) async {
    final c = CodeEditorController(initialText: 'abc');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorViewWidget(
          openTabs: const ['a.txt', 'b.txt'],
          activeFile: 'a.txt',
          codeContent: '',
          controller: c,
          isTabDirty: (_) => false,
          onSelectTab: (_) {},
          onCloseTab: (_) {},
        ),
      ),
    ));
    final before = EditorViewWidget.debugTabBarBuilds;
    c.setCursor(const EditorPosition(0, 3));
    for (final ch in 'xyz'.split('')) {
      c.insertText(ch);
      await tester.pump();
    }
    expect(find.text('abcxyz', findRichText: true), findsOneWidget, reason: '编辑区照常刷新');
    expect(EditorViewWidget.debugTabBarBuilds, before, reason: '标签栏没有重建');
    await tester.pumpWidget(const SizedBox());
    c.dispose();
  });
}
