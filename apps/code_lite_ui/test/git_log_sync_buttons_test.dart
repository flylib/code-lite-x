import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/git/git_log_store.dart';
import 'package:code_lite_ui/features/git/git_log_window.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// Git 工具窗筛选栏最右边的 Pull / Push。
void main() {
  final client = ApiClient();
  late Directory repo;

  setUp(() {
    repo = Directory.systemTemp.createTempSync('clx_gitsync_');
    for (final args in [
      ['init', '-q', '-b', 'main'],
      ['config', 'user.name', 'Tester'],
      ['config', 'user.email', 't@example.com'],
      ['commit', '-q', '--allow-empty', '-m', 'first'],
    ]) {
      Process.runSync('git', args, workingDirectory: repo.path);
    }
    client.openWorkspace(repo.path);
  });

  tearDown(() {
    client.openWorkspace('.');
    repo.deleteSync(recursive: true);
  });

  Future<GitLogStore> show(WidgetTester tester, {void Function(BuildContext)? onPull, void Function(BuildContext)? onPush}) async {
    await tester.binding.setSurfaceSize(const Size(1400, 500));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final store = GitLogStore(client);
    await tester.runAsync(store.refresh);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: GitLogWindow(store: store, repoName: 'r', onHide: () {}, onPull: onPull, onPush: onPush)),
    ));
    // 面板打开时会再刷新一次(跑真的 git,进程是在测试的假时钟里起的):真实时间和假时钟交替推进,等它跑完
    for (var i = 0; i < 40; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 15)));
      await tester.pump(const Duration(milliseconds: 1));
    }
    return store;
  }

  testWidgets('Pull and Push sit at the right end of the filter bar and call their actions', (tester) async {
    final events = <String>[];
    final store = await show(tester, onPull: (_) => events.add('pull'), onPush: (_) => events.add('push'));
    final pull = find.byKey(const ValueKey('git-pull'));
    final push = find.byKey(const ValueKey('git-push'));
    expect(pull, findsOneWidget);
    expect(push, findsOneWidget);
    // 在其它工具按钮的右边,Push 是最右的一个
    expect(tester.getRect(pull).left, greaterThanOrEqualTo(tester.getRect(find.byTooltip('跳转到哈希 / 分支 / 标签')).right));
    expect(tester.getRect(push).left, greaterThanOrEqualTo(tester.getRect(pull).right));
    final bar = tester.getRect(find.ancestor(of: push, matching: find.byType(Container)).first);
    expect(bar.right - tester.getRect(push).right, lessThan(12));

    await tester.tap(pull);
    await tester.tap(push);
    expect(events, ['pull', 'push']);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });

  testWidgets('without actions the buttons are not shown', (tester) async {
    final store = await show(tester);
    expect(find.byKey(const ValueKey('git-pull')), findsNothing);
    expect(find.byKey(const ValueKey('git-push')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    store.dispose();
  });
}
