import 'dart:async';
import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

/// 自动保存:编辑停顿后写盘(无需 ⌘S),切换标签时立即写,写盘广播给 Commit 窗。
void main() {
  late Directory dir;
  late ApiClient client;
  late EditorSessionManager sessions;

  setUp(() {
    dir = Directory.systemTemp.createTempSync('clx_autosave_');
    File('${dir.path}/a.txt').writeAsStringSync('hello\n');
    File('${dir.path}/b.txt').writeAsStringSync('bee\n');
    client = ApiClient(initialRoot: dir.path);
    sessions = EditorSessionManager(client: client);
  });

  tearDown(() async {
    sessions.dispose();
    await client.dispose();
    dir.deleteSync(recursive: true);
  });

  String disk(String name) => File('${dir.path}/$name').readAsStringSync();

  test('typing is written to disk after a short pause, without ⌘S', () async {
    final saved = <String>[];
    final sub = client.onFileSaved.listen(saved.add);
    final tab = await sessions.openFile('a.txt');
    tab.controller.setCursor(const EditorPosition(0, 5));
    tab.controller.insertText(' world');
    expect(tab.isDirty, isTrue);
    expect(disk('a.txt'), 'hello\n', reason: '停顿前还没写');

    await Future<void>.delayed(EditorSessionManager.autosaveDelay + const Duration(milliseconds: 400));
    expect(disk('a.txt'), 'hello world\n');
    expect(tab.isDirty, isFalse);
    expect(saved, ['a.txt'], reason: 'Commit 窗据此刷新');
    await sub.cancel();
  });

  test('keeps typing → saves once after the last keystroke', () async {
    var saves = 0;
    final sub = client.onFileSaved.listen((_) => saves++);
    final tab = await sessions.openFile('a.txt');
    tab.controller.setCursor(const EditorPosition(0, 5));
    for (final ch in '12345'.split('')) {
      tab.controller.insertText(ch);
      await Future<void>.delayed(const Duration(milliseconds: 100));
    }
    await Future<void>.delayed(EditorSessionManager.autosaveDelay + const Duration(milliseconds: 400));
    expect(disk('a.txt'), 'hello12345\n');
    expect(saves, 1);
    await sub.cancel();
  });

  test('switching tabs saves right away', () async {
    final a = await sessions.openFile('a.txt');
    a.controller.setCursor(const EditorPosition(0, 0));
    a.controller.insertText('>');
    await sessions.openFile('b.txt');
    // 不等自动保存的计时器:切走时就写了
    await Future<void>.delayed(const Duration(milliseconds: 150));
    expect(disk('a.txt'), '>hello\n');
    expect(a.isDirty, isFalse);
  });

  test('autosave off keeps the old ⌘S behaviour', () async {
    sessions.autosave = false;
    final tab = await sessions.openFile('a.txt');
    tab.controller.insertText('x');
    await Future<void>.delayed(EditorSessionManager.autosaveDelay + const Duration(milliseconds: 300));
    expect(disk('a.txt'), 'hello\n');
    expect(await sessions.saveActiveFile(), isTrue);
    expect(disk('a.txt'), 'xhello\n');
  });

  test('a tab that failed to load is never written', () async {
    final tab = await sessions.openFile('missing/none.txt', defaultContent: '');
    expect(tab.loadError, isNotNull);
    tab.controller.insertText('oops');
    await Future<void>.delayed(EditorSessionManager.autosaveDelay + const Duration(milliseconds: 300));
    expect(File('${dir.path}/missing/none.txt').existsSync(), isFalse);
  });
}
