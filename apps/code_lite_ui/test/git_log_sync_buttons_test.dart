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
    // 工具按钮靠右、紧挨着 Pull / Push(刷新 … 跳转、Pull、Push),Push 是最右的一个;六个一样大
    final tools = [for (final t in ['刷新', 'Cherry-Pick', '显示详情', '跳转到哈希 / 分支 / 标签']) tester.getRect(find.byTooltip(t).last)];
    final rects = [...tools, tester.getRect(pull), tester.getRect(push)];
    for (var i = 1; i < rects.length; i++) {
      expect(rects[i].left - rects[i - 1].right, inInclusiveRange(-0.5, 2), reason: '第 $i 个紧挨着前一个');
      expect(rects[i].size, rects[0].size, reason: '大小一致');
    }
    expect(tools.first.left, greaterThan(tester.getRect(find.text('Paths')).right + 40), reason: '离开了左边的筛选,靠到右边');
    final bar = tester.getRect(find.ancestor(of: push, matching: find.byType(Container)).first);
    expect(bar.right - tester.getRect(push).right, lessThan(12));

    // 默认和左边的工具按钮同色;按住时 Pull 变蓝、Push 变绿并带底色,松开恢复
    Color iconColor(Finder f) => ((tester.widget<CustomPaint>(find.descendant(of: f, matching: find.byType(CustomPaint)).last).painter!) as dynamic).color as Color;
    BoxDecoration? bg(Finder f) => tester.widget<Container>(find.descendant(of: f, matching: find.byType(Container)).first).decoration as BoxDecoration?;
    final grey = tester.widget<Icon>(find.descendant(of: find.byTooltip('跳转到哈希 / 分支 / 标签'), matching: find.byType(Icon))).color;
    expect(iconColor(pull), grey);
    expect(iconColor(push), grey);
    expect(bg(pull), isNull);
    final g = await tester.startGesture(tester.getCenter(pull));
    await tester.pump();
    expect(iconColor(pull), const Color(0xFF4A86F7));
    expect(bg(pull)?.color, const Color(0xFF4A86F7).withValues(alpha: 0.18));
    await g.up();
    await tester.pump();
    expect(iconColor(pull), grey);
    final g2 = await tester.startGesture(tester.getCenter(push));
    await tester.pump();
    expect(iconColor(push), const Color(0xFF3DD68C));
    await g2.up();
    await tester.pump(const Duration(milliseconds: 600));
    expect(events, ['pull', 'push'], reason: '按下松开就是一次点击');
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
