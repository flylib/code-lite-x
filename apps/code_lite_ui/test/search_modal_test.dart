import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/search/global_search_modal.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Find in Files(⇧⌘F,同 IntelliJ):边打字边搜(停 300 ms),同一行的几处合成一行,右边文件名 + 行号,底部预览。
void main() {
  const controller = 'game-service/src/main/java/game/modules/mtt/controller/RecMttRewardsController.java';
  const impl = 'game-service/src/main/java/game/modules/mtt/service/impl/RecMttRewardsServiceImpl.java';
  final calls = <(String, Map<String, dynamic>)>[];

  Future<Map<String, dynamic>> fakeSearch(String q, Map<String, dynamic> options) async {
    calls.add((q, options));
    return {
      'status': 'ok',
      'matches': [
        {'file_path': controller, 'line_number': 231, 'col_start': 18, 'col_end': 36, 'line_snippet': '@PostMapping("/rewardBcdMttPrize")'},
        {'file_path': controller, 'line_number': 232, 'col_start': 33, 'col_end': 51, 'line_snippet': 'public CommonResponse<Void> rewardBcdMttPrize(long mttId) {'},
        {'file_path': impl, 'line_number': 349, 'col_start': 16, 'col_end': 34, 'line_snippet': 'public void rewardBcdMttPrize(long mttId) { rewardBcdMttPrize(mttId); }'},
        {'file_path': impl, 'line_number': 349, 'col_start': 48, 'col_end': 66, 'line_snippet': 'public void rewardBcdMttPrize(long mttId) { rewardBcdMttPrize(mttId); }'},
        {'file_path': 'docs/notes.md', 'line_number': 3, 'col_start': 0, 'col_end': 18, 'line_snippet': 'rewardBcdMttPrize notes'},
      ],
    };
  }

  setUp(calls.clear);

  Future<List<(String, int, int)>> open(WidgetTester tester, {bool replaceMode = false, List<String>? replaced}) async {
    final navigated = <(String, int, int)>[];
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () => GlobalSearchModal.show(
              context,
              search: fakeSearch,
              replace: (q, r, o) async {
                replaced?.add('$q→$r');
                return {'status': 'ok', 'replaced_count': 4};
              },
              readFile: (path) async => [for (var i = 1; i <= 400; i++) 'line $i rewardBcdMttPrize'].join('\n'),
              replaceMode: replaceMode,
              currentDirectory: 'game-service/src',
              onNavigate: (p, l, c) => navigated.add((p, l, c)),
            ),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    return navigated;
  }

  testWidgets('searches as you type after a short pause (one search for a burst of keys); rows are per line with file:line', (tester) async {
    final navigated = await open(tester);
    expect(find.text('在文件中查找'), findsOneWidget);
    for (final q in ['r', 're', 'rewardBcd', 'rewardBcdMttPrize']) {
      await tester.enterText(find.byKey(const ValueKey('find-query')), q);
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(calls, isEmpty, reason: '还在打字');
    await tester.pump(const Duration(milliseconds: 300));
    await tester.pump();
    expect(calls.map((c) => c.$1), ['rewardBcdMttPrize'], reason: '停下来只搜一次');

    expect(tester.widget<Text>(find.byKey(const ValueKey('find-summary'))).data, '5 处匹配,共 3 个文件');
    expect(find.text('RecMttRewardsController.java 231'), findsOneWidget);
    expect(find.text('RecMttRewardsServiceImpl.java 349'), findsOneWidget, reason: '同一行两处 → 一行');
    expect(find.byKey(const ValueKey('find-hit-$impl:349')), findsOneWidget);
    expect(tester.widget<Text>(find.byKey(const ValueKey('find-location'))).data, 'game-service/src/main/java/game/modules/mtt/controller');
    expect(find.byKey(const ValueKey('find-preview')), findsOneWidget);
    expect(find.text('line 231 rewardBcdMttPrize', findRichText: true), findsOneWidget, reason: '预览滚到匹配那一行');

    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
    await tester.pump();
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);
    await tester.pumpAndSettle();
    expect(navigated, [(impl, 348, 16)], reason: '行列从 0 起');
  });

  testWidgets('Cc / W / .* and the scope search again right away; a single mask goes to the search, several are filtered here', (tester) async {
    await open(tester);
    await tester.enterText(find.byKey(const ValueKey('find-query')), 'rewardBcdMttPrize');
    await tester.pump(const Duration(milliseconds: 350));
    calls.clear();

    await tester.tap(find.byKey(const ValueKey('find-toggle-Cc')));
    await tester.pump();
    expect(calls.single.$2['case_sensitive'], isTrue);

    await tester.tap(find.byKey(const ValueKey('find-mask-toggle')));
    await tester.pump();
    expect(calls.last.$2['file_extension'], 'java');

    await tester.enterText(find.byKey(const ValueKey('find-mask')), '*.java, *.md');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(calls.last.$2.containsKey('file_extension'), isFalse);
    expect(find.text('notes.md 3'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('find-mask')), '*.md, !notes.md');
    await tester.pump(const Duration(milliseconds: 350));
    await tester.pump();
    expect(find.byKey(const ValueKey('find-empty')), findsOneWidget, reason: '!notes.md 排除');

    await tester.tap(find.byKey(const ValueKey('find-mask-toggle')));
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('find-scope-directory')));
    await tester.pump();
    expect(calls.last.$2['directory'], 'game-service/src', reason: '默认当前文件所在目录');
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  testWidgets('remembers the last query; Replace All replaces and searches again', (tester) async {
    final replaced = <String>[];
    await open(tester, replaceMode: true, replaced: replaced);
    expect(find.text('在文件中替换'), findsOneWidget);
    await tester.pump(const Duration(milliseconds: 350));
    expect(tester.widget<TextField>(find.byKey(const ValueKey('find-query'))).controller!.text, 'rewardBcdMttPrize', reason: '上次搜的');
    await tester.enterText(find.byKey(const ValueKey('find-replace')), 'rewardPrize');
    await tester.tap(find.byKey(const ValueKey('find-replace-all')));
    await tester.pump();
    await tester.pump();
    expect(replaced, ['rewardBcdMttPrize→rewardPrize']);
    expect(find.text('已替换 4 处'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
  });

  test('the Directory scope searches only that folder; paths stay relative to the project', () async {
    final dir = Directory.systemTemp.createTempSync('clx_find_dir_');
    addTearDown(() => dir.deleteSync(recursive: true));
    Directory('${dir.path}/a/b').createSync(recursive: true);
    Directory('${dir.path}/c').createSync();
    File('${dir.path}/a/b/x.txt').writeAsStringSync('needle here\n');
    File('${dir.path}/c/y.txt').writeAsStringSync('needle there\n');
    final client = ApiClient(initialRoot: dir.path);
    addTearDown(client.dispose);
    final all = await client.searchWorkspace('needle', {});
    expect((all['matches'] as List).map((m) => m['file_path']).toSet(), {'a/b/x.txt', 'c/y.txt'});
    final scoped = await client.searchWorkspace('needle', {'directory': 'a/'});
    expect((scoped['matches'] as List).map((m) => m['file_path']).toList(), ['a/b/x.txt']);
  });
}
