import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/git/branch_store.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final client = ApiClient();
  late Directory repo;

  Future<void> git(List<String> args, {Directory? dir}) async {
    final r = await Process.run('git', args, workingDirectory: (dir ?? repo).path);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }

  setUp(() async {
    repo = Directory.systemTemp.createTempSync('clx_branchstore_');
    await git(['init', '-q', '-b', 'main']);
    await git(['config', 'user.name', 'Tester']);
    await git(['config', 'user.email', 't@example.com']);
    File('${repo.path}/a.txt').writeAsStringSync('a\n');
    await git(['add', '.']);
    await git(['commit', '-q', '-m', 'first']);
    await git(['branch', 'dev']);
    client.openWorkspace(repo.path);
  });

  tearDown(() {
    client.openWorkspace('.');
    repo.deleteSync(recursive: true);
  });

  test('loads the current branch, the branch lists and the recent ones', () async {
    final store = BranchStore(client);
    addTearDown(store.dispose);
    await git(['switch', '-q', 'dev']);
    await git(['switch', '-q', 'main']);
    await store.load();
    expect(store.isRepo, isTrue);
    expect(store.current, 'main');
    expect(store.label, 'main');
    expect(store.local.map((b) => b.name), containsAll(['main', 'dev']));
    expect(store.recent, ['dev']);
  });

  test('a detached HEAD is labelled with the short hash', () async {
    final store = BranchStore(client);
    addTearDown(store.dispose);
    await git(['switch', '-q', '--detach']);
    await store.load();
    expect(store.detached, isTrue);
    expect(store.current, isNull);
    expect(store.label, matches(RegExp(r'^[0-9a-f]{7}$')));
  });

  test('a folder that is not a repository has no branch', () async {
    final plain = Directory.systemTemp.createTempSync('clx_plain_');
    addTearDown(() => plain.deleteSync(recursive: true));
    client.openWorkspace(plain.path);
    final store = BranchStore(client);
    addTearDown(store.dispose);
    await store.load();
    expect(store.isRepo, isFalse);
    expect(store.label, '');
    expect(store.local, isEmpty);
  });

  test('switching branches elsewhere (a terminal) is noticed and reported once', () async {
    final store = BranchStore(client, pollInterval: const Duration(milliseconds: 40));
    addTearDown(store.dispose);
    var changes = 0;
    final worktree = <bool>[];
    store.onChanged = (w) {
      changes++;
      worktree.add(w);
    };
    store.start();
    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(store.current, 'main');
    expect(changes, 0, reason: '没变就不通知');

    await git(['switch', '-q', 'dev']);
    await Future<void>.delayed(const Duration(milliseconds: 400));
    expect(store.current, 'dev');
    expect(changes, 1);
    expect(worktree, [true], reason: '外面切分支,工作区文件多半变了');

    await Future<void>.delayed(const Duration(milliseconds: 200));
    expect(changes, 1, reason: '稳定后不再重复通知');
  });

  test('run: shows progress, reloads, notifies, and reports errors', () async {
    final store = BranchStore(client);
    addTearDown(store.dispose);
    await store.load();
    var changes = 0;
    final worktree = <bool>[];
    store.onChanged = (w) {
      changes++;
      worktree.add(w);
    };
    final seenBusy = <String?>[];
    store.addListener(() => seenBusy.add(store.busy));

    expect(await store.run('Checkout', 'git.checkout', {'name': 'dev'}), isNull);
    expect(store.current, 'dev');
    expect(store.busy, isNull);
    expect(seenBusy, contains('Checkout'));
    expect(changes, 1);

    final err = await store.run('Checkout', 'git.checkout', {'name': 'nope'});
    expect(err, contains('找不到分支'));
    expect(store.current, 'dev');
    expect(changes, 2, reason: '失败也重新加载并通知,状态以磁盘为准');
    expect(await store.run('Push', 'git.checkout', {'name': 'dev'}, false), isNull);
    expect(worktree, [true, true, false], reason: '调用方说明工作区没动,就不要求重载文件');
  });

  test('reset clears the old project and a late load is dropped', () async {
    final store = BranchStore(client);
    addTearDown(store.dispose);
    await store.load();
    final pending = store.load();
    store.reset();
    await pending;
    expect(store.isRepo, isFalse, reason: 'reset 之后到达的旧结果被丢弃');
    expect(store.current, isNull);
  });
}
