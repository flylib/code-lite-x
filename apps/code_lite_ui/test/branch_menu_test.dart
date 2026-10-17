// 标题栏分支弹窗的界面测试。用假客户端:脚本化 `git.branches`,记录收到的 git 调用,
// 测的是「点了什么就发出对应的调用、界面随结果更新」。真实 git 的效果由
// git_branch_ops_test(服务)和 branch_store_test(store + 真实仓库)覆盖。

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/git/branch_actions.dart';
import 'package:code_lite_ui/features/git/branch_store.dart';
import 'package:code_lite_ui/features/title_bar/branch_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeGitClient extends ApiClient {
  FakeGitClient();

  /// 仓库状态:`git.branches` 的返回;操作之后测试可以改它来模拟 git 的效果。
  String current = 'main';
  bool isRepo = true;
  List<String> localNames = ['main', 'feat/login', 'dev'];
  final Map<String, String> upstreams = {'main': 'origin/main', 'dev': 'origin/dev'};
  List<String> remoteNames = ['origin/main', 'origin/dev'];
  List<String> recent = ['dev'];

  /// 每个方法的返回,没设的算成功。
  final Map<String, Map<String, dynamic>> responses = {};
  final List<(String, Map<String, dynamic>)> calls = [];

  @override
  Future<String> gitHeadFingerprint() async => 'ref: refs/heads/$current';

  @override
  Future<Map<String, dynamic>> gitCall(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    if (method == 'git.branches') {
      if (!isRepo) return {'status': 'error', 'error': 'not a git repository'};
      return {
        'status': 'ok',
        'current': current,
        'head': 'abcdef0123456789',
        'detached': false,
        'local': [
          for (final n in localNames) {'name': n, 'hash': 'h', 'upstream': upstreams[n], 'current': n == current},
        ],
        'remote': [
          for (final n in remoteNames) {'name': n, 'remote': n.split('/').first, 'short': n.substring(n.indexOf('/') + 1), 'hash': 'h'},
        ],
        'tags': const [],
      };
    }
    if (method == 'git.recent_branches') return {'status': 'ok', 'branches': recent};
    return responses[method] ?? {'status': 'ok'};
  }

  List<Map<String, dynamic>> callsTo(String method) => [for (final c in calls) if (c.$1 == method) c.$2];
}

void main() {
  late FakeGitClient client;
  late BranchStore store;
  late int commitWindowOpened;

  setUp(() {
    client = FakeGitClient();
    store = BranchStore(client);
    commitWindowOpened = 0;
  });

  tearDown(() => store.dispose());

  Future<void> show(WidgetTester tester) async {
    await store.load();
    final actions = BranchActions(store, showCommitWindow: () => commitWindowOpened++);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: Align(alignment: Alignment.topLeft, child: BranchChip(store: store, actions: actions))),
    ));
  }

  Future<void> openPopup(WidgetTester tester) async {
    await tester.tap(find.text(store.current ?? '').first);
    await tester.pumpAndSettle();
  }

  testWidgets('the chip shows the current branch; a plain folder shows nothing', (tester) async {
    await show(tester);
    expect(find.text('main'), findsOneWidget);
    expect(find.byTooltip('Git Branch: main'), findsOneWidget);

    client.isRepo = false;
    await store.load();
    await tester.pump();
    expect(find.text('main'), findsNothing);
  });

  testWidgets('the popup has the search box, the actions with their shortcuts, and the three branch sections', (tester) async {
    await show(tester);
    await openPopup(tester);

    expect(find.text('Search for branches and actions'), findsOneWidget);
    for (final (label, shortcut) in [
      ('Update Project…', '⌘T'),
      ('Commit…', '⌘K'),
      ('Push…', '⇧⌘P'),
      ('New Branch…', '⌥⌘N'),
      ('Checkout Tag or Revision…', null),
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
      if (shortcut != null) expect(find.text(shortcut), findsOneWidget, reason: label);
    }
    expect(find.text('Recent'), findsOneWidget);
    expect(find.text('Local'), findsOneWidget);
    expect(find.text('Remote'), findsOneWidget);
    expect(find.text('feat'), findsOneWidget, reason: 'feat/login 折成文件夹');
    expect(find.text('login'), findsOneWidget);
    expect(find.text('origin'), findsOneWidget);
    expect(find.text('origin/main'), findsOneWidget, reason: '本地 main 右边写着它的上游');
  });

  testWidgets('every branch row has its arrow at the right edge, whatever the name / upstream length', (tester) async {
    client.localNames = ['main', 'feat/login', 'dev', 'feat/retention-archive-before-cleanup-with-a-very-long-name', 'kdev'];
    client.upstreams['feat/retention-archive-before-cleanup-with-a-very-long-name'] = 'origin/feat/retention-archive-before-cleanup-with-a-very-long-name';
    client.upstreams['kdev'] = 'origin/kdev';
    await show(tester);
    await openPopup(tester);
    final chevrons = find.byKey(const ValueKey('branch-row-chevron'));
    expect(chevrons.evaluate().length, greaterThan(4));
    double rightOf(Element e) {
      final box = e.renderObject! as RenderBox;
      return box.localToGlobal(Offset(box.size.width, 0)).dx;
    }

    final rights = {for (final e in chevrons.evaluate()) rightOf(e).round()};
    expect(rights, hasLength(1), reason: '箭头全部右对齐(有没有上游、名字长短都一样)');
    expect(tester.takeException(), isNull, reason: '长名字不溢出');
  });

  testWidgets('opening the popup refreshes the branch list', (tester) async {
    await show(tester);
    final before = client.callsTo('git.branches').length;
    client.localNames = [...client.localNames, 'created-elsewhere'];
    await openPopup(tester);
    expect(client.callsTo('git.branches').length, greaterThan(before));
    expect(find.text('created-elsewhere'), findsOneWidget);
  });

  testWidgets('searching narrows both the actions and the branches', (tester) async {
    await show(tester);
    await openPopup(tester);

    await tester.enterText(find.byType(TextField), 'LOGIN');
    await tester.pumpAndSettle();
    expect(find.text('login'), findsOneWidget);
    expect(find.text('Update Project…'), findsNothing);
    expect(find.text('dev'), findsNothing);

    await tester.enterText(find.byType(TextField), 'push');
    await tester.pumpAndSettle();
    expect(find.text('Push…'), findsOneWidget);
    expect(find.text('New Branch…'), findsNothing);

    await tester.enterText(find.byType(TextField), 'zzzz');
    await tester.pumpAndSettle();
    expect(find.text('没有匹配的分支或操作'), findsOneWidget);
  });

  testWidgets('a section can be folded', (tester) async {
    await show(tester);
    await openPopup(tester);
    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    expect(find.text('feat'), findsNothing);
    expect(find.text('Remote'), findsOneWidget);
    await tester.tap(find.text('Local'));
    await tester.pumpAndSettle();
    expect(find.text('feat'), findsOneWidget);
  });

  testWidgets('Commit… opens the commit window and closes the popup', (tester) async {
    await show(tester);
    await openPopup(tester);
    await tester.tap(find.text('Commit…'));
    await tester.pumpAndSettle();
    expect(commitWindowOpened, 1);
    expect(find.text('Search for branches and actions'), findsNothing);
  });

  Map<String, dynamic> outgoing({bool setUpstream = false, int count = 2}) => {
        'status': 'ok',
        'branch': 'main',
        'remote': 'origin',
        'target_branch': 'main',
        'set_upstream': setUpstream,
        'commits': [
          for (var i = 0; i < count; i++) {'hash': 'h$i${'0' * 38}', 'short': 'h$i', 'author': 'dev', 'time': 1700000000 + i, 'subject': 'commit number $i'},
        ],
      };

  testWidgets('Update Project… and Push… call git and report', (tester) async {
    client.responses['git.update'] = {'status': 'ok', 'output': 'Updating a..b\nFast-forward\n 1 file changed'};
    client.responses['git.push'] = {'status': 'ok', 'remote': 'origin', 'branch': 'main', 'set_upstream': true};
    client.responses['git.outgoing'] = outgoing(setUpstream: true);
    await show(tester);

    await openPopup(tester);
    await tester.tap(find.text('Update Project…'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.update'), [{'stash': false}], reason: '没有本地改动:不问,直接更新');
    expect(find.textContaining('已更新: 1 file changed'), findsOneWidget);

    await openPopup(tester);
    await tester.tap(find.text('Push…'));
    await tester.pumpAndSettle();
    // 先弹确认框,列出要推的提交
    expect(find.text('Push Commits'), findsOneWidget);
    expect(find.text('commit number 0'), findsOneWidget);
    expect(find.text('commit number 1'), findsOneWidget);
    expect(find.byKey(const ValueKey('push-new-branch')), findsOneWidget);
    expect(client.callsTo('git.push'), isEmpty);
    await tester.tap(find.byKey(const ValueKey('push-confirm')));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.push'), hasLength(1));
    expect(find.textContaining('已推送 main 到 origin(并设为上游)'), findsOneWidget);
  });

  testWidgets('Push: cancel does not push; nothing to push disables the button', (tester) async {
    client.responses['git.outgoing'] = outgoing();
    await show(tester);
    await openPopup(tester);
    await tester.tap(find.text('Push…'));
    await tester.pumpAndSettle();
    expect(tester.widget<Text>(find.byKey(const ValueKey('push-count'))).data, '2 个提交');
    expect(tester.widget<Text>(find.byKey(const ValueKey('push-target'))).data, 'origin : main');
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.push'), isEmpty);

    client.responses['git.outgoing'] = outgoing(count: 0);
    await openPopup(tester);
    await tester.tap(find.text('Push…'));
    await tester.pumpAndSettle();
    expect(find.text('没有要推送的提交,已经和远程一致'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byKey(const ValueKey('push-confirm'))).onPressed, isNull);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
  });

  testWidgets('Update with uncommitted changes asks first: cancel / stash & update / update anyway', (tester) async {
    client.responses['git.local_changes'] = {
      'status': 'ok',
      'changes': [
        {'path': 'src/A.java', 'status': 'modified', 'is_staged': false},
        {'path': 'notes.txt', 'status': 'untracked', 'is_staged': false},
      ],
    };
    client.responses['git.update'] = {'status': 'ok', 'output': 'Already up to date.'};
    await show(tester);

    Future<void> update() async {
      await openPopup(tester);
      await tester.tap(find.text('Update Project…'));
      await tester.pumpAndSettle();
    }

    await update();
    expect(find.text('本地有未提交的改动'), findsOneWidget);
    expect(find.text('src/A.java'), findsOneWidget);
    expect(find.text('notes.txt'), findsOneWidget);
    await tester.tap(find.text('取消'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.update'), isEmpty);

    await update();
    await tester.tap(find.byKey(const ValueKey('update-stash')));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.update'), [{'stash': true}]);

    await update();
    await tester.tap(find.text('直接更新'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.update').last, {'stash': false});

    // 恢复时有冲突:提示改动还在 stash 里
    client.responses['git.update'] = {'status': 'ok', 'output': 'x', 'stash_conflict': true};
    await update();
    await tester.tap(find.byKey(const ValueKey('update-stash')));
    await tester.pumpAndSettle();
    expect(find.textContaining('改动还在 stash 里'), findsOneWidget);
  });

  testWidgets('only operations that touch the files ask for a reload of them', (tester) async {
    client.responses['git.outgoing'] = outgoing();
    await show(tester);
    final flags = <bool>[];
    store.onChanged = flags.add;
    await openPopup(tester);
    await tester.tap(find.text('Update Project…'));
    await tester.pumpAndSettle();
    await openPopup(tester);
    await tester.tap(find.text('Push…'));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('push-confirm')));
    await tester.pumpAndSettle();
    expect(flags, [true, false], reason: '更新会改文件,推送不会');
  });

  testWidgets('a failing operation shows git\'s reason and the branch list is reloaded', (tester) async {
    client.responses['git.update'] = {'status': 'error', 'error': '分支 main 没有上游分支'};
    await show(tester);
    await openPopup(tester);
    final loads = client.callsTo('git.branches').length;
    await tester.tap(find.text('Update Project…'));
    await tester.pumpAndSettle();
    expect(find.textContaining('Update 失败: 分支 main 没有上游分支'), findsOneWidget);
    expect(client.callsTo('git.branches').length, greaterThan(loads), reason: '失败后也以磁盘为准重新加载');
  });

  testWidgets('a branch opens its actions; Checkout sends git.checkout and the chip follows', (tester) async {
    await show(tester);
    await openPopup(tester);
    await tester.tap(find.text('login'));
    await tester.pumpAndSettle();
    for (final label in ['Checkout', "New Branch from 'feat/login'…", "Merge 'feat/login' into 'main'", "Rebase 'main' onto 'feat/login'", 'Rename…', 'Delete']) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    client.current = 'feat/login'; // git 的效果
    await tester.tap(find.text('Checkout'));
    await tester.pumpAndSettle();

    expect(client.callsTo('git.checkout'), [
      {'name': 'feat/login'}
    ]);
    expect(store.current, 'feat/login');
    expect(find.text('feat/login'), findsOneWidget, reason: '标题栏跟着变');
    expect(find.text('已切换到 feat/login'), findsOneWidget);
  });

  testWidgets('the current branch cannot be checked out, merged, rebased or deleted', (tester) async {
    await show(tester);
    await openPopup(tester);
    // 第一个 main 在标题栏,第二个是 Local 里的(当前分支),最后一个是 Remote 里 origin 下的
    await tester.tap(find.text('main').at(1));
    await tester.pumpAndSettle();
    for (final label in ['Checkout', "Merge 'main' into 'main'", "Rebase 'main' onto 'main'", 'Delete']) {
      final item = tester.widget<PopupMenuItem<String>>(find.widgetWithText(PopupMenuItem<String>, label));
      expect(item.enabled, isFalse, reason: label);
    }
    expect(tester.widget<PopupMenuItem<String>>(find.widgetWithText(PopupMenuItem<String>, 'Rename…')).enabled, isTrue);
  });

  testWidgets('a remote branch offers Checkout but not Rename or Delete, and checks it out by its remote name', (tester) async {
    await show(tester);
    await openPopup(tester);
    // 本地 dev(Recent 和 Local 各一个)和远程 dev 同名,Remote 段在最后,取最后一个
    await tester.tap(find.text('dev').last);
    await tester.pumpAndSettle();
    expect(find.widgetWithText(PopupMenuItem<String>, 'Rename…'), findsNothing);
    expect(find.widgetWithText(PopupMenuItem<String>, 'Delete'), findsNothing);
    await tester.tap(find.text('Checkout'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.checkout'), [
      {'name': 'origin/dev'}
    ]);
  });

  testWidgets('New Branch… asks for a name and creates it from HEAD', (tester) async {
    await show(tester);
    await openPopup(tester);
    await tester.tap(find.text('New Branch…'));
    await tester.pumpAndSettle();
    expect(find.text('Checkout branch'), findsOneWidget);
    await tester.enterText(find.byType(TextField), 'feat/brand-new');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.new_branch'), [
      {'name': 'feat/brand-new', 'hash': 'HEAD', 'checkout': true}
    ]);
  });

  testWidgets('New Branch from a branch starts at that branch and can skip the checkout', (tester) async {
    await show(tester);
    await openPopup(tester);
    await tester.tap(find.text('login'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("New Branch from 'feat/login'…"));
    await tester.pumpAndSettle();
    expect(find.text("从 'feat/login' 创建"), findsOneWidget);
    await tester.tap(find.byType(CheckboxListTile));
    await tester.enterText(find.byType(TextField), 'side');
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.new_branch'), [
      {'name': 'side', 'hash': 'feat/login', 'checkout': false}
    ]);
  });

  testWidgets('an empty name creates nothing; Cancel does nothing', (tester) async {
    await show(tester);
    await openPopup(tester);
    await tester.tap(find.text('New Branch…'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Create'));
    await tester.pumpAndSettle();
    expect(find.text('Checkout branch'), findsOneWidget, reason: '名字为空,对话框还在');
    await tester.tap(find.text('Cancel'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.new_branch'), isEmpty);
  });

  testWidgets('Merge and Rebase ask first and then call git', (tester) async {
    await show(tester);
    await openPopup(tester);
    await tester.tap(find.text('login'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Merge 'feat/login' into 'main'"));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.merge'), isEmpty, reason: '先确认');
    await tester.tap(find.widgetWithText(FilledButton, 'Merge'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.merge'), [
      {'name': 'feat/login'}
    ]);

    await openPopup(tester);
    await tester.tap(find.text('login'));
    await tester.pumpAndSettle();
    await tester.tap(find.text("Rebase 'main' onto 'feat/login'"));
    await tester.pumpAndSettle();
    expect(find.textContaining('这会改写'), findsOneWidget);
    await tester.tap(find.widgetWithText(FilledButton, 'Rebase'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.rebase_onto'), [
      {'name': 'feat/login'}
    ]);
  });

  testWidgets('Rename asks for the new name; an unchanged name is ignored', (tester) async {
    await show(tester);
    await openPopup(tester);
    await tester.tap(find.text('login'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.rename_branch'), isEmpty, reason: '没改名字');

    await openPopup(tester);
    await tester.tap(find.text('login'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Rename…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), 'feat/signin');
    await tester.tap(find.widgetWithText(FilledButton, 'Rename'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.rename_branch'), [
      {'name': 'feat/login', 'new_name': 'feat/signin'}
    ]);
  });

  testWidgets('Delete asks first; the force box decides -d or -D', (tester) async {
    await show(tester);
    for (final force in [false, true]) {
      await openPopup(tester);
      await tester.tap(find.text('login'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Delete'));
      await tester.pumpAndSettle();
      expect(find.text("Delete Branch 'feat/login'"), findsOneWidget);
      if (force) await tester.tap(find.byType(CheckboxListTile));
      await tester.pump();
      await tester.tap(find.widgetWithText(FilledButton, 'Delete'));
      await tester.pumpAndSettle();
    }
    expect(client.callsTo('git.delete_branch'), [
      {'name': 'feat/login', 'force': false},
      {'name': 'feat/login', 'force': true},
    ]);
  });

  testWidgets('Checkout Tag or Revision… passes what was typed', (tester) async {
    await show(tester);
    await openPopup(tester);
    await tester.tap(find.text('Checkout Tag or Revision…'));
    await tester.pumpAndSettle();
    await tester.enterText(find.byType(TextField), '  v1.2.0 ');
    await tester.tap(find.widgetWithText(FilledButton, 'Checkout'));
    await tester.pumpAndSettle();
    expect(client.callsTo('git.checkout_revision'), [
      {'hash': 'v1.2.0'}
    ]);
  });

  testWidgets('while an operation runs the chip shows progress', (tester) async {
    await show(tester);
    store.busy = 'Update'; // run() 在等 git 返回时的状态
    store.notifyListeners();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    expect(find.byTooltip('Update…'), findsOneWidget);
    store.busy = null;
    store.notifyListeners();
    await tester.pump();
    expect(find.byType(CircularProgressIndicator), findsNothing);
  });
}
