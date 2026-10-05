import 'dart:convert';

import 'package:code_lite_ui/core/github/github_service.dart';
import 'package:code_lite_ui/features/pull_requests/pr_diff_tab.dart';
import 'package:code_lite_ui/features/pull_requests/pr_panel.dart';
import 'package:code_lite_ui/features/pull_requests/pr_store.dart';
import 'package:code_lite_ui/features/pull_requests/pr_timeline_tab.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假的 gh:按参数返回固定数据,并记录每次调用(含 stdin),不碰网络。
class FakeGh {
  final List<(List<String>, String?)> calls = [];
  bool installed = true;

  final String head = 'h' * 40;
  final String base = 'b' * 40;
  final String mergeBase = 'm' * 40;
  static const xml = 'admin-service/src/main/resources/mapper/mtt/MttV2CompensationMapper.xml';
  static const test = 'admin-service/src/test/java/com/x/MttV2CompensationMapperTest.java';

  late final Map<String, String> files = {
    '$mergeBase:$xml': 'a\nb\nc\nd\ne\n',
    '$head:$xml': 'a\nb\nC\nd\ne\nf\n',
    '$head:$test': 'class T {}\n',
    '$mergeBase:long.txt': [for (var i = 1; i <= 20; i++) 'line $i'].join('\n'),
    '$head:long.txt': [for (var i = 1; i <= 20; i++) i == 2 ? 'LINE 2' : 'line $i'].join('\n'),
  };

  List<Map<String, dynamic>> comments = [
    {
      'id': 1, 'path': xml, 'line': 3, 'original_line': 3, 'side': 'RIGHT', 'in_reply_to_id': null, //
      'user': {'login': 'alice'}, 'body': 'why C?', 'created_at': '2026-10-01T10:00:00Z',
    },
    {
      'id': 2, 'path': xml, 'line': 3, 'original_line': 3, 'side': 'RIGHT', 'in_reply_to_id': 1, //
      'user': {'login': 'bob'}, 'body': 'upper case is intended', 'created_at': '2026-10-01T11:00:00Z',
    },
  ];

  String? stdinOf(bool Function(List<String>) where) {
    for (final c in calls.reversed) {
      if (where(c.$1)) return c.$2;
    }
    return null;
  }

  Future<List<int>> call(List<String> args, {String? stdin}) async {
    calls.add((args, stdin));
    if (!installed) throw GhException('没有找到 gh', notInstalled: true);
    String out(Object o) => o is String ? o : jsonEncode(o);
    final a = args.join(' ');
    List<int> ok(Object o) => utf8.encode(out(o));

    if (a.startsWith('repo view')) return ok('acme/poker\n');
    if (a.startsWith('api user')) return ok('me\n');
    if (a.startsWith('pr list')) {
      return ok([
        {
          'number': 1392, 'title': 'fix(mtt): 取消赛导表的实际总奖池', 'author': {'login': 'Mystical2261'}, //
          'createdAt': '2026-09-30T08:00:00Z', 'isDraft': false, 'comments': [{}, {}], 'state': 'OPEN',
          'statusCheckRollup': [{'__typename': 'CheckRun', 'status': 'COMPLETED', 'conclusion': 'FAILURE'}],
          'reviewDecision': 'REVIEW_REQUIRED', 'labels': [{'name': 'bug', 'color': 'ff0000'}], 'assignees': [],
        },
        {
          'number': 1366, 'title': 'feat(trace): 自建线程池', 'author': {'login': 'jacksonwu101'}, //
          'createdAt': '2026-09-28T08:00:00Z', 'isDraft': true, 'comments': [], 'state': 'OPEN',
          'statusCheckRollup': [], 'reviewDecision': '', 'labels': [], 'assignees': [{'login': 'me'}],
        },
      ]);
    }
    if (a.startsWith('pr view 1392')) {
      return ok({
        'id': 'PR_node', 'number': 1392, 'title': 'fix(mtt): 取消赛导表的实际总奖池', 'body': '修复补贴', //
        'state': 'OPEN', 'isDraft': false, 'author': {'login': 'Mystical2261'}, 'url': 'https://github.com/acme/poker/pull/1392',
        'createdAt': '2026-09-30T08:00:00Z', 'headRefName': 'feat/cancel-subsidy-report', 'baseRefName': 'main',
        'headRefOid': head, 'baseRefOid': base, 'reviewRequests': [], 'reviews': [], 'reviewDecision': '',
        'statusCheckRollup': [{'__typename': 'CheckRun', 'name': 'ci', 'status': 'COMPLETED', 'conclusion': 'SUCCESS'}],
        'commits': [{'oid': head, 'messageHeadline': 'fix(mtt): 取消赛导表', 'committedDate': '2026-09-30T08:00:00Z', 'authors': [{'login': 'Mystical2261'}]}],
        'labels': [],
      });
    }
    if (a.contains('pulls/1392/files')) {
      return ok([
        jsonEncode({'filename': xml, 'status': 'modified', 'additions': 2, 'deletions': 1}),
        jsonEncode({'filename': test, 'status': 'added', 'additions': 1, 'deletions': 0}),
        jsonEncode({'filename': 'long.txt', 'status': 'modified', 'additions': 1, 'deletions': 1}),
      ].join('\n'));
    }
    if (a.contains('/compare/')) return ok('$mergeBase\n');
    if (a.contains('/contents/')) {
      final m = RegExp(r'contents/(.+)\?ref=(\w+)').firstMatch(args.last)!;
      final content = files['${m.group(2)}:${Uri.decodeComponent(m.group(1)!)}'];
      if (content == null) throw GhException('HTTP 404: Not Found');
      return ok(content);
    }
    if (a.contains('pulls/1392/comments') && a.contains('POST')) {
      final body = jsonDecode(stdin!) as Map<String, dynamic>;
      final c = {
        'id': 100 + comments.length, 'path': body['path'] ?? xml, 'line': body['line'] ?? 3, 'side': body['side'] ?? 'RIGHT',
        'in_reply_to_id': a.contains('/replies') ? 1 : null, 'user': {'login': 'me'}, 'body': body['body'], //
        'created_at': '2026-10-05T10:00:00Z',
      };
      comments.add(c);
      return ok(c);
    }
    if (a.contains('pulls/1392/comments')) return ok(comments.map(jsonEncode).join('\n'));
    if (a.contains('pulls/1392/reviews') || a.contains('requested_reviewers') || a.contains('issues/1392/comments')) return ok('{}');
    if (a.contains('issues/1392/timeline')) {
      return ok([
        {'event': 'committed', 'sha': head, 'message': 'fix(mtt): 取消赛导表', 'author': {'name': 'Mystical2261', 'date': '2026-09-30T08:00:00Z'}},
        {'event': 'commented', 'actor': {'login': 'carol'}, 'body': 'LGTM 但请补测试', 'created_at': '2026-09-30T09:00:00Z'},
        {'event': 'reviewed', 'user': {'login': 'dave'}, 'state': 'approved', 'body': '', 'submitted_at': '2026-09-30T10:00:00Z'},
        {'event': 'labeled', 'actor': {'login': 'bot'}, 'label': {'name': 'bug'}, 'created_at': '2026-09-30T10:30:00Z'},
      ].map(jsonEncode).join('\n'));
    }
    if (a.startsWith('api graphql') && a.contains('viewerViewedState')) {
      return ok([
        {'path': xml, 'viewerViewedState': 'UNVIEWED'},
        {'path': test, 'viewerViewedState': 'VIEWED'},
      ]);
    }
    if (a.startsWith('api graphql') && a.contains('FileAsViewed')) return ok('{}');
    if (a.startsWith('api graphql') && a.contains('blame')) {
      return ok([
        {'startingLine': 1, 'endingLine': 6, 'commit': {'abbreviatedOid': 'abc1234', 'committedDate': '2026-09-01T00:00:00Z', 'messageHeadline': 'x', 'author': {'name': 'Zed', 'user': {'login': 'zed'}}}},
      ]);
    }
    throw GhException('unexpected gh call: $a');
  }
}

void main() {
  group('GitHubService', () {
    test('parses list, detail, files, contents and comments', () async {
      final fake = FakeGh();
      final gh = GitHubService('/tmp', runner: fake.call);
      final list = await gh.list(state: 'merged', author: '@me', label: 'bug');
      expect(list.map((p) => p.number), [1392, 1366]);
      expect(list.first.checks, ChecksState.failure);
      expect(list.first.commentCount, 2);
      expect(list.last.isDraft, isTrue);
      final listArgs = fake.calls.firstWhere((c) => c.$1.first == 'pr').$1;
      expect(listArgs, containsAllInOrder(['--state', 'merged']));
      expect(listArgs, containsAllInOrder(['--author', '@me']));
      expect(listArgs, containsAllInOrder(['--label', 'bug']));

      final d = await gh.detail(1392);
      expect(d.headRef, 'feat/cancel-subsidy-report');
      expect(d.checksState, ChecksState.success);
      final files = await gh.files(1392);
      expect(files.map((f) => f.status), ['modified', 'added', 'modified']);
      expect(await gh.mergeBase(d.baseSha, d.headSha), fake.mergeBase);
      expect(await gh.fileAt(fake.head, FakeGh.xml), 'a\nb\nC\nd\ne\nf\n');
      expect(await gh.fileAt(fake.mergeBase, FakeGh.test), isNull, reason: '404 = 这一侧没有这个文件');
      final comments = await gh.reviewComments(1392);
      expect(comments.last.inReplyTo, 1);
      expect(await gh.viewedStates(1392), {FakeGh.xml: false, FakeGh.test: true});
    });

    test('review comment / review / reviewer requests send JSON bodies over stdin', () async {
      final fake = FakeGh();
      final gh = GitHubService('/tmp', runner: fake.call);
      await gh.addReviewComment(1392, commitId: fake.head, path: FakeGh.xml, line: 4, startLine: 3, side: 'RIGHT', body: '多行\n"引号"');
      final body = jsonDecode(fake.stdinOf((a) => a.contains('POST'))!) as Map;
      expect(body, {
        'body': '多行\n"引号"', 'commit_id': fake.head, 'path': FakeGh.xml, 'line': 4, 'side': 'RIGHT', //
        'start_line': 3, 'start_side': 'RIGHT',
      });
      await gh.submitReview(1392, 'APPROVE', '');
      expect(jsonDecode(fake.stdinOf((a) => a.any((x) => x.endsWith('/reviews')))!), {'event': 'APPROVE'});
      await gh.requestReviewer(1392, 'me');
      expect(jsonDecode(fake.stdinOf((a) => a.any((x) => x.endsWith('/requested_reviewers')))!), {
        'reviewers': ['me'],
      });
    });

    test('store reports a missing gh as unavailable', () async {
      final fake = FakeGh()..installed = false;
      final store = PullRequestsStore.withService(() => GitHubService('/tmp', runner: fake.call));
      await store.refresh();
      expect(store.ghUnavailable, isTrue);
      expect(store.items, isEmpty);
      store.dispose();
    });
  });

  group('UI', () {
    Future<(FakeGh, PullRequestsStore)> setup(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 900));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      final fake = FakeGh();
      final store = PullRequestsStore.withService(() => GitHubService('/tmp', runner: fake.call));
      addTearDown(store.dispose);
      return (fake, store);
    }

    testWidgets('panel: list with filters, open a PR, file tree, open a diff', (tester) async {
      final (fake, store) = await setup(tester);
      final opened = <(int, String)>[];
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 420,
            child: PullRequestsPanel(
              store: store,
              onOpenDiff: (n, p) => opened.add((n, p)),
              onOpenTimeline: (_) {},
            ),
          ),
        ),
      ));
      await tester.pumpAndSettle();
      expect(find.text('fix(mtt): 取消赛导表的实际总奖池'), findsOneWidget);
      expect(find.text('#1392 · created 2026/9/30, by Mystical2261'), findsOneWidget);
      expect(find.text('DRAFT'), findsOneWidget);
      expect(find.byIcon(Icons.cancel), findsOneWidget, reason: '检查失败的红叉');

      // Author 筛选:选 Me → gh pr list --author @me
      await tester.tap(find.text('Author'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Me (me)'));
      await tester.pumpAndSettle();
      expect(fake.calls.last.$1, containsAllInOrder(['--author', '@me']));

      await tester.tap(find.text('fix(mtt): 取消赛导表的实际总奖池'));
      await tester.pumpAndSettle();
      expect(find.text('#1392'), findsOneWidget, reason: '标题栏多了一个 PR 标签');
      expect(find.text('View Timeline'), findsOneWidget);
      expect(find.text('feat/cancel-subsidy-report → main'), findsOneWidget);
      expect(find.text('admin-service'), findsOneWidget);
      expect(find.text('src'), findsOneWidget);
      expect(find.text('main/resources/mapper/mtt'), findsOneWidget, reason: '单子目录链压成一行');
      expect(find.text('Missing reviewer'), findsOneWidget);
      expect(find.text('Set Myself as Reviewer'), findsOneWidget);

      await tester.tap(find.text('MttV2CompensationMapper.xml'));
      await tester.pumpAndSettle();
      expect(opened.single, (1392, FakeGh.xml));

      await tester.tap(find.text('Set Myself as Reviewer'));
      await tester.pumpAndSettle();
      expect(fake.calls.any((c) => c.$1.any((a) => a.endsWith('/requested_reviewers'))), isTrue);
    });

    testWidgets('diff tab: threads inline, right-click menu, add comment, mark viewed, clipboard', (tester) async {
      final (fake, store) = await setup(tester);
      final session = store.session(1392)..showFile(FakeGh.xml);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PrDiffTab(session: session, onOpenLocal: (_, __) {})),
      ));
      await tester.pumpAndSettle();

      expect(find.text('2 differences'), findsOneWidget);
      expect(find.text('why C?'), findsOneWidget);
      expect(find.text('upper case is intended'), findsOneWidget, reason: '回复在同一会话里');
      expect(find.text('Viewed'), findsOneWidget);

      // 选中右侧第 6 行(新增的 f)并右键
      final f = find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'f');
      await tester.tap(f, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      for (final item in ['Compare with Clipboard', 'Annotate with Git Blame', 'Add Review Comment', 'Mark File as Viewed']) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
      await tester.tap(find.text('Add Review Comment'));
      await tester.pumpAndSettle();
      expect(find.text('评论 新版本 第 6 行'), findsOneWidget);
      await tester.enterText(find.byType(TextField), 'f 是新加的?');
      await tester.tap(find.text('Add Comment'));
      await tester.pumpAndSettle();
      final sent = jsonDecode(fake.stdinOf((a) => a.contains('POST') && a.any((x) => x.endsWith('/comments')))!) as Map;
      expect(sent['line'], 6);
      expect(sent['side'], 'RIGHT');
      expect(sent['commit_id'], fake.head);
      expect(find.text('f 是新加的?'), findsOneWidget, reason: '发表后显示在行下');

      // ⇧⌘S:标记已查看
      await tester.tap(f);
      await tester.pump();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pumpAndSettle();
      expect(fake.calls.any((c) => c.$1.join(' ').contains('markFileAsViewed')), isTrue);
      expect(session.viewed[FakeGh.xml], isTrue);

      // 选中 f 与剪贴板比较
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.getData') return {'text': 'F'};
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.tap(f, buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Compare with Clipboard'));
      await tester.pumpAndSettle();
      expect(find.text('Selection ↔ Clipboard'), findsOneWidget);
      expect(find.text('1 differences'), findsOneWidget);
    });

    testWidgets('diff tab: blame column and switching files', (tester) async {
      final (_, store) = await setup(tester);
      final session = store.session(1392)..showFile(FakeGh.xml);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PrDiffTab(session: session, onOpenLocal: (_, __) {})),
      ));
      await tester.pumpAndSettle();
      await tester.tap(find.byTooltip('Annotate with Git Blame'));
      await tester.pumpAndSettle();
      expect(find.text('2026/9/1  zed'), findsWidgets);

      await tester.tap(find.byTooltip('下一个文件'));
      await tester.pumpAndSettle();
      expect(find.text('class T {}', findRichText: true), findsOneWidget);
      expect(find.textContaining('(新文件)'), findsOneWidget);
    });

    testWidgets('diff tab: lines far from any change cannot be commented', (tester) async {
      final (_, store) = await setup(tester);
      final session = store.session(1392)..showFile('long.txt');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(body: PrDiffTab(session: session, onOpenLocal: (_, __) {})),
      ));
      await tester.pumpAndSettle();
      Finder right(String text) => find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == text).last;

      await tester.tap(right('line 12'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      final item = tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, 'Add Review Comment'));
      expect(item.onPressed, isNull, reason: '第 12 行离改动(第 2 行)超过 3 行,GitHub 不接受');
      await tester.tapAt(const Offset(5, 5));
      await tester.pumpAndSettle();

      await tester.tap(right('line 5'), buttons: kSecondaryButton);
      await tester.pumpAndSettle();
      final ok = tester.widget<MenuItemButton>(find.widgetWithText(MenuItemButton, 'Add Review Comment'));
      expect(ok.onPressed, isNotNull);
    });

    testWidgets('timeline: description, comments, reviews, commits; post a comment', (tester) async {
      final (fake, store) = await setup(tester);
      await tester.pumpWidget(MaterialApp(home: Scaffold(body: PrTimelineTab(session: store.session(1392)))));
      await tester.pumpAndSettle();
      expect(find.text('修复补贴'), findsOneWidget);
      expect(find.text('LGTM 但请补测试'), findsOneWidget);
      expect(find.text('dave approved'), findsOneWidget);
      expect(find.text('Mystical2261 添加了 1 个提交'), findsOneWidget);
      expect(find.text('bot 添加了标签 bug'), findsOneWidget);

      await tester.enterText(find.byType(TextField), '已补测试');
      await tester.tap(find.text('Comment'));
      await tester.pumpAndSettle();
      expect(jsonDecode(fake.stdinOf((a) => a.any((x) => x.endsWith('issues/1392/comments')))!), {'body': '已补测试'});
    });
  });
}
