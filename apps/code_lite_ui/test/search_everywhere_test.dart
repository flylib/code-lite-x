import 'package:code_lite_ui/core/keymap/keymap.dart';
import 'package:code_lite_ui/core/lsp/java_reference.dart';
import 'package:code_lite_ui/core/lsp/lsp.dart' show LspLocation, LspWorkspaceSymbol;
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/copy_reference.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/search/double_shift.dart';
import 'package:code_lite_ui/features/search/search_everywhere_dialog.dart';
import 'package:code_lite_ui/features/search/search_everywhere_sources.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 复制引用(⌥⇧⌘C)+ Search Everywhere(连按两下 Shift):复制出来的 `com.foo.Bar#baz(com.foo.Dto)` 粘进去能定位回去。
void main() {
  const root = '/w';
  const service = '''
package com.bcpoker.game.modules.mtt.service.impl;

import com.bcpoker.game.api.dto.mtt.InfoMttDTO;

public class RecMttRewardsServiceImpl {
    public long rewardMttPrize(InfoMttDTO mtt, int extra) { return 1; }

    public long rewardMttPrize(InfoMttDTO mtt) {
        return helper(mtt);
    }

    private long helper(InfoMttDTO mtt) { return 0; }
}
''';
  const servicePath = 'game-service/src/main/java/com/bcpoker/game/modules/mtt/service/impl/RecMttRewardsServiceImpl.java';
  const otherPath = 'other/src/main/java/org/other/RecMttRewardsServiceImpl.java';
  final files = {'$root/$servicePath': service, '$root/$otherPath': 'package org.other;\npublic class RecMttRewardsServiceImpl {}\n'};

  Map<String, dynamic> fileQuery(String q, int limit) => {
        'status': 'ok',
        'results': [
          for (final p in [servicePath, otherPath, 'game-service/README.md'])
            if (p.toLowerCase().contains(q.toLowerCase().split('.').first)) {'path': p, 'indices': <int>[]},
        ],
      };

  SearchSources sources({List<String>? ran}) => buildSearchSources(
        root: root,
        fileQuery: fileQuery,
        workspaceSymbols: (_) async => const [],
        actions: {KeymapIds.gotoFile: () => ran?.add('goto'), KeymapIds.project: () => ran?.add('project')},
        readText: (abs) async => files[abs],
      );

  group('sources', () {
    test('a copied reference (even without the leading package) finds the class and the right overload', () async {
      const ref = 'game.modules.mtt.service.impl.RecMttRewardsServiceImpl#rewardMttPrize(com.bcpoker.game.api.dto.mtt.InfoMttDTO)';
      final hits = await sources().reference(parseCodeReference(ref)!);
      expect(hits.map((h) => h.kind), [SearchHitKind.method, SearchHitKind.classType], reason: '方法在前,回车就到方法');
      expect(hits.first.title, 'rewardMttPrize(InfoMttDTO)');
      expect(hits.first.path, '$root/$servicePath');
      expect(hits.first.line, 7, reason: '单参数的那个重载,不是第 5 行的两参数版');
      expect(hits.first.location, 'game-service');
      expect(hits.last.detail, '位于 com.bcpoker.game.modules.mtt.service.impl');
      expect(hits.where((h) => h.path!.contains('org/other')), isEmpty, reason: '包路径对不上的同名类不要');
    });

    test('files support Foo.java:12; actions match either language; classes fall back to file names', () async {
      final s = sources();
      final f = s.files('RecMtt:12', 10);
      expect(f.first.path, '$root/$servicePath');
      expect(f.first.line, 11);
      expect(s.actions('转到').map((h) => h.actionId), [KeymapIds.gotoFile]);
      expect(s.actions('go to file').map((h) => h.actionId), [KeymapIds.gotoFile]);
      final classes = await s.classes('RecMtt');
      expect(classes.map((h) => h.title), everyElement('RecMttRewardsServiceImpl'));
      expect(classes.first.detail, '位于 com.bcpoker.game.modules.mtt.service.impl');
    });

    test('language server symbols become class / method hits with the module on the right', () async {
      final s = buildSearchSources(
        root: root,
        fileQuery: (q, l) => {'status': 'ok', 'results': const []},
        workspaceSymbols: (_) async => const [
          LspWorkspaceSymbol(name: 'helper', kind: 6, container: 'RecMttRewardsServiceImpl', location: LspLocation(servicePath, 11, 17)),
        ],
        actions: const {},
        readText: (_) async => null,
      );
      final hits = await s.symbols('helper');
      expect(hits.single.kind, SearchHitKind.method);
      expect(hits.single.line, 11);
      expect(hits.single.location, 'game-service');
    });
  });

  group('copy reference', () {
    test('declaration → reference; call site → via the definition; otherwise path:line', () async {
      Future<String> at(int line, int col, {LspLocation? def, String path = servicePath}) => computeCopyReference(
            root: root,
            path: path,
            text: service,
            line: line,
            col: col,
            definition: () async => def,
            readText: (p) async => files['$root/$p'],
          );
      const cls = 'com.bcpoker.game.modules.mtt.service.impl.RecMttRewardsServiceImpl';
      expect(await at(7, 18), '$cls#rewardMttPrize(com.bcpoker.game.api.dto.mtt.InfoMttDTO)');
      expect(await at(8, 17, def: const LspLocation(servicePath, 11, 17)), '$cls#helper(com.bcpoker.game.api.dto.mtt.InfoMttDTO)', reason: '调用处 helper(...)');
      expect(await at(8, 17), '$servicePath:9', reason: '没有语言服务器:路径:行号');
      expect(await at(0, 0, path: 'docs/notes.md'), 'docs/notes.md:1');
    });
  });

  group('popup', () {
    Future<SearchHit? Function()> open(WidgetTester tester, SearchSources s) async {
      SearchHit? chosen;
      await tester.binding.setSurfaceSize(const Size(1200, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => TextButton(
              onPressed: () async => chosen = await showSearchEverywhere(context, sources: s),
              child: const Text('open'),
            ),
          ),
        ),
      ));
      await tester.tap(find.text('open'));
      await tester.pumpAndSettle();
      return () => chosen;
    }

    testWidgets('pasting a copied reference: the method is first, Enter opens it', (tester) async {
      final chosen = await open(tester, sources());
      expect(find.byKey(const ValueKey('search-tab-all')), findsOneWidget);
      await tester.runAsync(() async {
        await tester.enterText(find.byKey(const ValueKey('search-everywhere-input')),
            'game.modules.mtt.service.impl.RecMttRewardsServiceImpl#rewardMttPrize(com.bcpoker.game.api.dto.mtt.InfoMttDTO)');
        await Future<void>.delayed(const Duration(milliseconds: 400));
      });
      await tester.pump(const Duration(milliseconds: 200));
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
      await tester.pump();
      expect(find.text('rewardMttPrize(InfoMttDTO)'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(chosen()?.line, 7);
      expect(chosen()?.path, '$root/$servicePath');
    });

    testWidgets('Tab switches tabs; the Actions tab runs an action', (tester) async {
      final chosen = await open(tester, sources());
      await tester.enterText(find.byKey(const ValueKey('search-everywhere-input')), 'go to');
      await tester.pump(const Duration(milliseconds: 300));
      for (var i = 0; i < 4; i++) {
        await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      }
      await tester.pump();
      expect(find.text('转到文件'), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pumpAndSettle();
      expect(chosen()?.actionId, KeymapIds.gotoFile);
    });
  });

  testWidgets('double Shift fires; Shift used for typing (Shift+A) or a slow second Shift does not', (tester) async {
    var fired = 0;
    await tester.pumpWidget(MaterialApp(home: DoubleShiftDetector(onDoubleShift: () => fired++, child: const Focus(autofocus: true, child: SizedBox()))));

    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(fired, 1);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(fired, 1, reason: '打大写字母');

    await tester.sendKeyEvent(LogicalKeyboardKey.keyB); // 别的键:之前那一下 Shift 作废
    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 500)));
    await tester.sendKeyEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(fired, 1, reason: '两下隔太久');
  });

  testWidgets('right-click in the code: Copy / Paste Special ▸ Copy Reference', (tester) async {
    final ctrl = CodeEditorController(initialText: 'class A {}\n');
    final copied = <String>[];
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorViewWidget(
          openTabs: const ['A.java'],
          activeFile: 'A.java',
          codeContent: ctrl.text,
          controller: ctrl,
          onSelectTab: (_) {},
          onCloseTab: (_) {},
          onCodeChanged: (_) {},
          onCopyReference: (path, _) => copied.add(path),
        ),
      ),
    ));
    final code = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'class A {}');
    await tester.tap(code, buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    expect(find.text('剪切'), findsOneWidget);
    await tester.tap(find.text('复制/粘贴特殊'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('editor-copy-reference')));
    await tester.pumpAndSettle();
    expect(copied, ['A.java']);
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}
