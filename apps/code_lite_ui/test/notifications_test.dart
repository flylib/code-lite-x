import 'package:code_lite_ui/features/notifications/notifications.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 提示 / 错误:右下角弹卡片;错误、提示各记最近 10 条,在 Problems 工具窗(全部 / Errors / Notify)里看。
void main() {
  test('a message splits into a short title and the reason', () {
    expect(splitNotice('Update 失败: 分支 feat/x 没有上游分支'), ('Update 失败', '分支 feat/x 没有上游分支'));
    expect(splitNotice('恢复失败：权限不够'), ('恢复失败', '权限不够'));
    expect(splitNotice('已推送 main 到 origin'), ('已推送 main 到 origin', ''));
    final long = '${'很长的一句话' * 10}: 后面';
    expect(splitNotice(long).$2, '', reason: '冒号前面太长就不当标题');
  });

  test('keeps the latest 10 errors and the latest 10 notices (newest first); 全部 merges them by time', () {
    final c = NotificationCenter();
    for (var i = 1; i <= 12; i++) {
      c.post('第 $i 次失败: 原因 $i', error: true);
    }
    c.post('已提交 abc');
    expect(c.errors, hasLength(NotificationCenter.maxErrors));
    expect(c.errors.first.title, '第 12 次失败');
    expect(c.errors.last.title, '第 3 次失败');
    expect(c.errors.any((n) => n.title == '已提交 abc'), isFalse);
    expect(c.notifies.single.title, '已提交 abc', reason: '普通提示记在 Notify');
    expect([for (final n in c.all.take(3)) n.title], ['已提交 abc', '第 12 次失败', '第 11 次失败'], reason: '全部按时间,新的在前');
    expect(c.listFor(ProblemsFilter.notify), c.notifies);
    for (var i = 1; i <= 12; i++) {
      c.post('提示 $i');
    }
    expect(c.notifies, hasLength(NotificationCenter.maxErrors));
    expect(c.unread, isTrue);
    expect(c.balloons, hasLength(NotificationCenter.maxBalloons), reason: '弹着的卡片最多 3 张');
    expect(c.balloons.last.title, '提示 12');

    c.setViewing(true);
    expect(c.unread, isFalse, reason: 'Problems 开着就算看过');
    c.post('又失败: x', error: true);
    expect(c.unread, isFalse);
    c.setViewing(false);
    c.clear(ProblemsFilter.notify);
    expect(c.notifies, isEmpty);
    expect(c.errors, isNotEmpty, reason: '只清当前标签');
    c.clear();
    expect(c.errors, isEmpty);
    c.dispose();
  });

  Future<NotificationCenter> pumpApp(WidgetTester tester, {bool problems = false}) async {
    final center = NotificationCenter();
    await tester.binding.setSurfaceSize(const Size(1200, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(NotificationScope(
      center: center,
      child: MaterialApp(
        home: Scaffold(
          body: Stack(
            children: [
              Column(
                children: [
                  Builder(
                    builder: (context) => Row(children: [
                      TextButton(key: const ValueKey('fail'), onPressed: () => showNotice(context, 'Update 失败: 分支没有上游分支,先推送它', error: true), child: const Text('fail')),
                      TextButton(key: const ValueKey('ok'), onPressed: () => showNotice(context, '已推送 main 到 origin'), child: const Text('ok')),
                    ]),
                  ),
                  if (problems) Expanded(child: ProblemsPanel(center: center, onHide: () {})),
                ],
              ),
              Positioned(right: 48, bottom: 32, child: NotificationOverlay(center: center)),
            ],
          ),
        ),
      ),
    ));
    return center;
  }

  testWidgets('an error pops a card in the bottom-right (title + reason), closes with × or after a while', (tester) async {
    final center = await pumpApp(tester);
    await tester.tap(find.byKey(const ValueKey('fail')));
    await tester.pump();
    expect(find.byType(SnackBar), findsNothing, reason: '不再是底部整条的红色提示');
    expect(find.text('Update 失败'), findsOneWidget);
    expect(find.text('分支没有上游分支,先推送它'), findsOneWidget);
    final card = tester.getRect(find.byKey(ValueKey('notice-${center.errors.first.id}')));
    expect(card.right, closeTo(1200 - 48, 1), reason: '贴着右边');
    expect(card.bottom, closeTo(700 - 32, 1), reason: '贴着下边');
    expect(card.width, 380);

    await tester.tap(find.byKey(const ValueKey('notice-close')));
    await tester.pump();
    expect(find.text('Update 失败'), findsNothing);
    expect(center.errors, hasLength(1), reason: '关掉卡片,日志里还在');

    await tester.tap(find.byKey(const ValueKey('ok')));
    await tester.pump();
    expect(find.text('已推送 main 到 origin'), findsOneWidget);
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('已推送 main 到 origin'), findsNothing, reason: '普通提示 4 秒后收起');
    await tester.tap(find.byKey(const ValueKey('fail')));
    await tester.pump();
    await tester.pump(const Duration(seconds: 5));
    expect(find.text('Update 失败'), findsOneWidget, reason: '错误停得久一些');
    await tester.pump(const Duration(seconds: 6));
    expect(find.text('Update 失败'), findsNothing);
  });

  testWidgets('Problems has 全部 / Errors / Notify tabs with counts; empty state; clear', (tester) async {
    final center = await pumpApp(tester, problems: true);
    await tester.pump();
    expect(find.byKey(const ValueKey('problems-empty')), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('fail')));
    await tester.pump();
    center.post('Push 失败: 远程拒绝', error: true);
    await tester.pump();
    await tester.tap(find.byKey(const ValueKey('ok')));
    await tester.pump();
    expect(find.text('全部  3', findRichText: true), findsOneWidget);
    expect(find.text('错误  2', findRichText: true), findsOneWidget);
    expect(find.text('通知  1', findRichText: true), findsOneWidget);
    expect(find.byKey(ValueKey('problem-${center.notifies.first.id}')), findsOneWidget, reason: '全部里有通知');
    await tester.tap(find.byKey(const ValueKey('problems-tab-errors')));
    await tester.pump();
    expect(find.byKey(ValueKey('problem-${center.notifies.first.id}')), findsNothing, reason: 'Errors 里只有错误');
    expect(find.byKey(ValueKey('problem-${center.errors.first.id}')), findsOneWidget);
    expect(find.textContaining('远程拒绝', findRichText: true), findsWidgets);
    expect(center.unread, isFalse, reason: '开着 Problems 时来的错误算看过了');

    await tester.tap(find.byKey(const ValueKey('problems-clear')));
    await tester.pump();
    expect(find.byKey(const ValueKey('problems-empty')), findsOneWidget);
    expect(center.notifies, hasLength(1), reason: '在 Errors 标签清空只清错误');
    await tester.pump(const Duration(seconds: 11)); // 等卡片收起
  });

  testWidgets('without a NotificationScope it falls back to a SnackBar', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(builder: (context) => TextButton(onPressed: () => showNotice(context, '失败: x', error: true), child: const Text('go'))),
      ),
    ));
    await tester.tap(find.text('go'));
    await tester.pump();
    expect(find.byType(SnackBar), findsOneWidget);
  });
}
