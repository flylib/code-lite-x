// 合并 / 变基冲突的界面:标题栏的「⚠ Merging kdev」、» 和 × 按钮、冲突窗口。
// 假客户端模拟 git 的效果(采用一侧 → 该文件不再冲突;放弃 → 操作消失);真实 git 由 git_conflicts_test 覆盖。

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/git/branch_actions.dart';
import 'package:code_lite_ui/features/git/branch_store.dart';
import 'package:code_lite_ui/features/git/repo_operation.dart';
import 'package:code_lite_ui/features/title_bar/branch_menu.dart';
import 'package:code_lite_ui/features/title_bar/operation_buttons.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

class FakeRepo extends ApiClient {
  FakeRepo() : super(initialRoot: '.');

  String current = 'kdev';
  String? kind;
  String? branch = 'kdev';
  String? incoming = 'feat/retention';
  String? onto;
  List<Map<String, dynamic>> conflicts = [];
  String repoPrefix = '';
  final Map<String, Map<String, dynamic>> failures = {};
  final List<(String, Map<String, dynamic>)> calls = [];

  void startMerge(List<Map<String, dynamic>> files) {
    kind = 'merge';
    branch = current;
    conflicts = files;
  }

  @override
  Future<String> gitHeadFingerprint() async => kind == null && conflicts.isEmpty ? 'ref: refs/heads/$current' : 'ref: refs/heads/$current|MERGE_HEAD';

  @override
  Future<Map<String, dynamic>> gitCall(String method, [Map<String, dynamic> params = const {}]) async {
    calls.add((method, params));
    if (failures.containsKey(method)) return failures[method]!;
    switch (method) {
      case 'git.branches':
        return {
          'status': 'ok',
          'current': current,
          'head': 'abc',
          'detached': false,
          'local': [
            {'name': current, 'hash': 'h', 'upstream': null, 'current': true},
          ],
          'remote': const [],
        };
      case 'git.recent_branches':
        return {'status': 'ok', 'branches': const []};
      case 'git.operation_state':
        return {'status': 'ok', 'operation': kind, 'branch': branch, 'incoming': incoming, 'onto': onto, 'conflicts': conflicts};
      case 'git.accept_side':
        conflicts = [for (final c in conflicts) if (c['path'] != params['path']) c];
        return {'status': 'ok'};
      case 'git.abort_operation':
        kind = null;
        conflicts = [];
        return {'status': 'ok'};
      case 'git.continue_operation':
        kind = null;
        return {'status': 'ok'};
      case 'git.repo_info':
        return {'status': 'ok', 'prefix': repoPrefix};
    }
    return {'status': 'ok'};
  }

  List<Map<String, dynamic>> callsTo(String method) => [for (final c in calls) if (c.$1 == method) c.$2];
}

Map<String, dynamic> file(String path, [String yours = 'Modified', String theirs = 'Modified']) => {'path': path, 'yours': yours, 'theirs': theirs};

void main() {
  test('RepoOperation: labels, abortability, and nothing when there is neither an operation nor a conflict', () {
    expect(RepoOperation.fromJson({'operation': null, 'conflicts': []}), isNull);
    final merge = RepoOperation.fromJson({'operation': 'merge', 'branch': 'kdev', 'incoming': 'feat/x', 'conflicts': []})!;
    expect(merge.verb, 'Merging');
    expect(merge.noun, 'Merge');
    expect(merge.canAbort, isTrue);
    expect(merge.hasConflicts, isFalse);
    expect(merge.describe(null).map((s) => s.$1).join(), 'Merging branch feat/x into branch kdev');
    expect(merge.describe(null).where((s) => s.$2).map((s) => s.$1), ['feat/x', 'kdev']);
    final rebase = RepoOperation.fromJson({'operation': 'rebase', 'branch': 'feat', 'onto': 'main', 'conflicts': []})!;
    expect(rebase.describe(null).map((s) => s.$1).join(), 'Rebasing branch feat onto main');
    final loose = RepoOperation.fromJson({
      'operation': null,
      'conflicts': [file('a/b/c.txt')],
    })!;
    expect(loose.canAbort, isFalse);
    expect(loose.verb, 'Conflicts');
    expect(loose.conflicts.single.name, 'c.txt');
    expect(loose.conflicts.single.dir, 'a/b');
    expect(ConflictFile.fromJson(file('top.txt')).dir, '');
  });

  group('title bar', () {
    late FakeRepo repo;
    late BranchStore store;
    late BranchActions actions;
    late List<String> opened;

    setUp(() {
      repo = FakeRepo();
      store = BranchStore(repo);
      opened = [];
      actions = BranchActions(store, showCommitWindow: () {}, openFile: opened.add);
    });
    tearDown(() => store.dispose());

    Future<void> show(WidgetTester tester) async {
      await tester.binding.setSurfaceSize(const Size(1000, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await store.load();
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              BranchChip(store: store, actions: actions),
              OperationButtons(store: store, actions: actions),
            ]),
          ),
        ),
      ));
    }

    testWidgets('normal state: branch name only, no buttons', (tester) async {
      await show(tester);
      expect(find.text('kdev'), findsOneWidget);
      expect(find.byKey(const ValueKey('operation-conflicts')), findsNothing);
      expect(find.byKey(const ValueKey('operation-abort')), findsNothing);
      expect(repo.callsTo('git.operation_state'), isEmpty, reason: '平时不读冲突状态(要起好几个 git 进程)');
    });

    testWidgets('merging: the chip says Merging <branch> with a warning icon and both buttons appear', (tester) async {
      repo.startMerge([file('a.txt'), file('sub/b.txt', 'Deleted', 'Modified')]);
      await show(tester);
      expect(find.text('Merging kdev'), findsOneWidget);
      expect(find.byIcon(Icons.warning_amber_rounded), findsOneWidget);
      expect(find.byKey(const ValueKey('operation-conflicts')), findsOneWidget);
      expect(find.byKey(const ValueKey('operation-abort')), findsOneWidget);
      expect(find.byTooltip('2 个文件有冲突,点击查看并解决'), findsOneWidget);
      expect(find.byTooltip('放弃这次合并(Abort Merge)'), findsOneWidget);
    });

    testWidgets('a merge started in the terminal shows up on the next poll, and disappears when it is finished there', (tester) async {
      await show(tester);
      expect(find.byKey(const ValueKey('operation-conflicts')), findsNothing);
      repo.startMerge([file('a.txt')]);
      await store.load(); // 轮询发现指纹变了就会这样重新加载
      await tester.pump();
      expect(find.text('Merging kdev'), findsOneWidget);
      repo.kind = null;
      repo.conflicts = [];
      await store.load();
      await tester.pump();
      expect(find.text('kdev'), findsOneWidget);
      expect(find.byKey(const ValueKey('operation-conflicts')), findsNothing);
    });

    testWidgets('rebase shows the rebased branch (HEAD is detached then); conflicts without an operation get no abort button', (tester) async {
      repo
        ..kind = 'rebase'
        ..branch = 'feat/login'
        ..onto = 'main'
        ..conflicts = [file('a.txt')];
      await show(tester);
      expect(find.text('Rebasing feat/login'), findsOneWidget);
      expect(find.byTooltip('放弃这次变基(Abort Rebase)'), findsOneWidget);

      repo
        ..kind = null
        ..conflicts = [file('a.txt')];
      await store.load();
      await tester.pump();
      expect(find.text('Conflicts'), findsOneWidget, reason: '不是合并 / 变基造成的冲突(比如 stash apply):只说有冲突'); 
      expect(find.byKey(const ValueKey('operation-conflicts')), findsOneWidget);
      expect(find.byKey(const ValueKey('operation-abort')), findsNothing);
    });

    testWidgets('the × asks first; cancel keeps the merge, confirm aborts it and the chip returns to the branch name', (tester) async {
      repo.startMerge([file('a.txt')]);
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('operation-abort')));
      await tester.pumpAndSettle();
      expect(find.text('Abort Merge'), findsWidgets);
      expect(find.textContaining('git merge --abort'), findsOneWidget);
      await tester.tap(find.text('Cancel'));
      await tester.pumpAndSettle();
      expect(repo.callsTo('git.abort_operation'), isEmpty);
      expect(find.text('Merging kdev'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('operation-abort')));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Abort Merge'));
      await tester.pumpAndSettle();
      expect(repo.callsTo('git.abort_operation'), hasLength(1));
      expect(find.text('kdev'), findsOneWidget);
      expect(find.byKey(const ValueKey('operation-conflicts')), findsNothing);
    });

    testWidgets('» opens the conflicts window: the sentence, Yours / Theirs columns, one row per file', (tester) async {
      repo.startMerge([file('data-archiving-service/src/MigrationHoconBuilder.java'), file('README.md', 'Added', 'Added')]);
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('operation-conflicts')));
      await tester.pumpAndSettle();
      expect(find.text('Conflicts'), findsOneWidget);
      expect(find.textContaining('Merging branch feat/retention into branch kdev'), findsOneWidget);
      expect(find.text('Yours (kdev)'), findsOneWidget);
      expect(find.text('Theirs (feat/retention)'), findsOneWidget);
      expect(find.text('MigrationHoconBuilder.java'), findsOneWidget);
      expect(find.text('data-archiving-service/src'), findsOneWidget);
      expect(find.text('README.md'), findsOneWidget);
      expect(find.text('Added'), findsNWidgets(2));
      expect(find.text('Accept Yours'), findsOneWidget);
      expect(find.text('Accept Theirs'), findsOneWidget);
      expect(find.text('Open File'), findsOneWidget);
      // 两个文件、都没选:按钮不可用
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Accept Yours')).onPressed, isNull);

      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();
      expect(find.text('Conflicts'), findsNothing);
    });

    testWidgets('accepting a side resolves that file; when none are left the window offers to commit the merge', (tester) async {
      repo.startMerge([file('a.txt'), file('b.txt')]);
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('operation-conflicts')));
      await tester.pumpAndSettle();

      await tester.tap(find.byKey(const ValueKey('conflict-a.txt')));
      await tester.pump();
      await tester.tap(find.text('Accept Theirs'));
      await tester.pumpAndSettle();
      expect(repo.callsTo('git.accept_side'), [
        {'path': 'a.txt', 'side': 'theirs'},
      ]);
      expect(find.byKey(const ValueKey('conflict-a.txt')), findsNothing, reason: '解决了就从列表里消失');
      expect(find.byKey(const ValueKey('conflict-b.txt')), findsOneWidget);
      expect(find.byTooltip('1 个文件有冲突,点击查看并解决'), findsOneWidget);

      await tester.tap(find.byKey(const ValueKey('conflict-b.txt')));
      await tester.pump();
      await tester.tap(find.text('Accept Yours'));
      await tester.pumpAndSettle();
      expect(repo.callsTo('git.accept_side').last, {'path': 'b.txt', 'side': 'yours'});
      expect(find.text('所有冲突都已解决。'), findsOneWidget);
      expect(find.text('Commit Merge'), findsOneWidget);
      expect(find.byTooltip('冲突都解决了,点击完成Merge'), findsOneWidget);

      await tester.tap(find.text('Commit Merge'));
      await tester.pumpAndSettle();
      expect(repo.callsTo('git.continue_operation'), hasLength(1));
      expect(find.text('Conflicts'), findsNothing, reason: '完成后窗口自己关掉');
      expect(find.text('kdev'), findsOneWidget);
    });

    testWidgets('a single conflicted file is pre-selected; Cmd-click selects several and Accept applies to each', (tester) async {
      repo.startMerge([file('only.txt')]);
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('operation-conflicts')));
      await tester.pumpAndSettle();
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Accept Yours')).onPressed, isNotNull, reason: '只有一个文件:默认选中');
      await tester.tap(find.text('Close'));
      await tester.pumpAndSettle();

      repo.startMerge([file('a.txt'), file('b.txt'), file('c.txt')]);
      await store.load();
      await tester.tap(find.byKey(const ValueKey('operation-conflicts')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('conflict-a.txt')));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.tap(find.byKey(const ValueKey('conflict-c.txt')));
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(tester.widget<OutlinedButton>(find.widgetWithText(OutlinedButton, 'Accept Yours')).onPressed, isNotNull);
      expect(tester.widget<FilledButton>(find.widgetWithText(FilledButton, 'Open File')).onPressed, isNull, reason: '选了两个:不能同时打开');
      await tester.tap(find.text('Accept Yours'));
      await tester.pumpAndSettle();
      expect([for (final c in repo.callsTo('git.accept_side')) c['path']], ['a.txt', 'c.txt']);
      expect(find.byKey(const ValueKey('conflict-b.txt')), findsOneWidget);
    });

    testWidgets('Open File opens the file in the editor (path made relative to the project) and closes the window', (tester) async {
      repo
        ..repoPrefix = 'service/'
        ..startMerge([file('service/src/A.java')]);
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('operation-conflicts')));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Open File'));
      await tester.pumpAndSettle();
      expect(opened, ['src/A.java']);
      expect(find.text('Conflicts'), findsNothing);
    });

    testWidgets('a failure is reported and the file stays listed; the window has its own Abort; rebase columns', (tester) async {
      repo.startMerge([file('a.txt')]);
      await show(tester);
      await tester.tap(find.byKey(const ValueKey('operation-conflicts')));
      await tester.pumpAndSettle();
      repo.failures['git.accept_side'] = {'status': 'error', 'error': 'disk full'};
      await tester.tap(find.text('Accept Yours'));
      await tester.pumpAndSettle();
      expect(find.textContaining('disk full'), findsOneWidget);
      expect(find.byKey(const ValueKey('conflict-a.txt')), findsOneWidget);
      repo.failures.clear();

      await tester.tap(find.widgetWithText(TextButton, 'Abort Merge'));
      await tester.pumpAndSettle();
      await tester.tap(find.widgetWithText(FilledButton, 'Abort Merge'));
      await tester.pumpAndSettle();
      expect(repo.callsTo('git.abort_operation'), hasLength(1));
      expect(find.text('Conflicts'), findsNothing, reason: '操作没了,窗口跟着关');

      repo
        ..kind = 'rebase'
        ..branch = 'feat'
        ..onto = 'main'
        ..conflicts = [file('x.txt')];
      await store.load();
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('operation-conflicts')));
      await tester.pumpAndSettle();
      expect(find.textContaining('Rebasing branch feat onto main'), findsOneWidget);
      expect(find.text('Yours (feat)'), findsOneWidget);
      expect(find.text('Theirs (main)'), findsOneWidget);
    });
  });
}
