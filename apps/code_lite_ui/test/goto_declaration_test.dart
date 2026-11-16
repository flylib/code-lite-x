import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/keymap/keymap.dart';
import 'package:code_lite_ui/core/lsp/lsp.dart' show LspLocation;
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/goto_declaration.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// ⌘B / ⌘+单击(IntelliJ 的 Go to Declaration)跳到函数 / 变量的声明,⌘[ / ⌘] 后退 / 前进。
void main() {
  test('defaults: Cmd+B, Cmd+[ / Cmd+] (Ctrl+B, Ctrl+Alt+Left / Right elsewhere)', () {
    expect(keymapActionById(KeymapIds.gotoDeclaration)!.mac, ['meta B']);
    expect(keymapActionById(KeymapIds.gotoDeclaration)!.other, ['ctrl B']);
    expect(keymapActionById(KeymapIds.back)!.mac.first, 'meta OPEN_BRACKET');
    expect(keymapActionById(KeymapIds.forward)!.other, ['ctrl alt RIGHT']);
  });

  const java = '''
public class Prize {
    private long total = 0;

    public long reward(Info mtt, int extra) {
        long mttId = mtt.getId();
        total += mttId + extra;
        return helper(mttId);
    }

    private long helper(long id) { return id; }
}
''';
  ({int line, int col}) at(String src, String needle, [int nth = 0]) {
    var i = -1;
    for (var k = 0; k <= nth; k++) {
      i = src.indexOf(needle, i + 1);
    }
    final before = src.substring(0, i);
    return (line: '\n'.allMatches(before).length, col: i - (before.lastIndexOf('\n') + 1));
  }

  Future<DeclarationTarget?> lookup(String src, String needle, {int nth = 0, LspLocation? def, String path = 'Prize.java',
      List<Map<String, dynamic>> outline = const [], Map<String, String> files = const {}}) {
    final p = at(src, needle, nth);
    return findDeclaration(
      path: path,
      text: src,
      line: p.line,
      col: p.col + 1,
      definition: () async => def,
      outline: () async => outline,
      filesNamed: (name) => [for (final f in files.keys) if (f.split('/').last.split('.').first == name) f],
      readText: (f) async => files[f],
    );
  }

  test('the language server answer wins', () async {
    final t = await lookup(java, 'helper(mttId)', def: const LspLocation('src/Other.java', 3, 4));
    expect((t!.path, t.line, t.col), ('src/Other.java', 3, 4));
  });

  test('without a language server: methods and fields from the outline, locals and parameters from the text', () async {
    final outline = [
      {'name': 'Prize', 'line_start': 0, 'col_start': 13, 'children': [
        {'name': 'total', 'line_start': 1, 'col_start': 17, 'children': []},
        {'name': 'reward(Info, int)', 'line_start': 3, 'col_start': 16, 'children': []},
        {'name': 'helper(long)', 'line_start': 9, 'col_start': 17, 'children': []},
      ]},
    ];
    final helper = await lookup(java, 'helper(mttId)', outline: outline);
    expect((helper!.line, helper.col), (9, 17));
    final total = await lookup(java, 'total +=', outline: outline);
    expect((total!.line, total.col), (1, 17));
    final local = await lookup(java, 'mttId + extra');
    expect((local!.line, local.col), (at(java, 'mttId =').line, at(java, 'mttId =').col), reason: '局部变量');
    final param = await lookup(java, 'extra;');
    expect((param!.line, param.col), (at(java, 'extra)').line, at(java, 'extra)').col), reason: '参数');
  });

  test('other languages: var / let / def; capitalised names find the class in a file of the same name', () async {
    const js = 'function load(url) {\n  const data = fetch(url);\n  return data;\n}\n';
    final data = await lookup(js, 'data;', path: 'a.js');
    expect((data!.line, data.col), (1, 8));
    final load = await lookup('load(1)\n$js', 'load(1)', path: 'b.js');
    expect(load!.line, 1, reason: 'function load');

    final info = await lookup(java, 'Info mtt', files: {'src/main/java/com/x/Info.java': 'package com.x;\n\npublic class Info {}\n'});
    expect((info!.path, info.line, info.col), ('src/main/java/com/x/Info.java', 2, 13));
    expect(await lookup(java, 'getId'), isNull, reason: '别的类的方法,没有语言服务器找不到');
  });

  group('history', () {
    late Directory dir;
    late ApiClient client;
    late EditorSessionManager sessions;
    setUp(() {
      dir = Directory.systemTemp.createTempSync('clx_nav_');
      File('${dir.path}/a.txt').writeAsStringSync('a\nb\nc\n');
      File('${dir.path}/b.txt').writeAsStringSync('x\ny\n');
      client = ApiClient(initialRoot: dir.path);
      sessions = EditorSessionManager(client: client)..autosave = false;
    });
    tearDown(() async {
      sessions.dispose();
      await client.dispose();
      dir.deleteSync(recursive: true);
    });

    test('a jump is recorded; Back returns to it and Forward goes again; a new jump clears Forward', () async {
      final a = await sessions.openFile('a.txt');
      a.controller.setCursor(const EditorPosition(2, 0));
      sessions.recordJump();
      final b = await sessions.openFile('b.txt');
      b.controller.setCursor(const EditorPosition(1, 0));
      expect(sessions.canGoBack, isTrue);
      final back = sessions.takeBack()!;
      expect((back.$1, back.$2), ('a.txt', const EditorPosition(2, 0)));
      expect(sessions.canGoForward, isTrue);
      sessions.selectTab('a.txt');
      final fwd = sessions.takeForward()!;
      expect((fwd.$1, fwd.$2), ('b.txt', const EditorPosition(1, 0)));
      sessions.recordJump();
      expect(sessions.canGoForward, isFalse);
    });
  });

  testWidgets('Cmd+B and Cmd+click in the editor ask for the declaration at the caret', (tester) async {
    final ctrl = CodeEditorController(initialText: 'foo bar\n');
    final asked = <EditorPosition>[];
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorViewWidget(
          openTabs: const ['a.txt'],
          activeFile: 'a.txt',
          codeContent: ctrl.text,
          controller: ctrl,
          onSelectTab: (_) {},
          onCloseTab: (_) {},
          onCodeChanged: (_) {},
          keymap: KeymapStore(mac: true),
          onGotoDeclaration: (_, c) => asked.add(c.cursorPosition),
        ),
      ),
    ));
    final line = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'foo bar');
    await tester.tap(line);
    await tester.pump();
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyB);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    await tester.pump();
    expect(asked, hasLength(1));

    await tester.pump(const Duration(seconds: 1));
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS; // ⌘+单击是 macOS 的说法
    await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
    await tester.tapAt(tester.getTopLeft(line) + const Offset(2, 6));
    await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
    debugDefaultTargetPlatformOverride = null;
    await tester.pump();
    expect(asked, hasLength(2));
    expect(asked.last.col, 0, reason: '⌘+单击先把光标放到点的地方');

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}
