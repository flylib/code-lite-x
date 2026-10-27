import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/theme/intellij_theme.dart';
import 'package:code_lite_ui/features/git/git_log_store.dart';
import 'package:code_lite_ui/features/git/git_log_window.dart' show gitChangeColor, gitFileIconColor;
import 'package:flutter/painting.dart' show Color;
import 'package:flutter_test/flutter_test.dart';

/// 端到端:真实 git 仓库 → Dart GitService → GitLogStore。
void main() {
  final client = ApiClient();
  late Directory repo;

  Future<void> git(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: repo.path);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
  }

  Future<void> commitFile(String name, String content, String message) async {
    File('${repo.path}/$name').writeAsStringSync(content);
    await git(['add', name]);
    await git(['commit', '-q', '-m', message]);
  }

  setUp(() async {
    repo = Directory.systemTemp.createTempSync('clx_gitlog_');
    await git(['init', '-q', '-b', 'main']);
    await git(['config', 'user.name', 'Tester']);
    await git(['config', 'user.email', 't@example.com']);
    await commitFile('a.txt', 'a\n', 'feat: 初始提交');
    await git(['switch', '-q', '-c', 'feat/x']);
    await commitFile('x.txt', 'x\n', 'feat: 分支上的提交');
    await git(['switch', '-q', 'main']);
    await commitFile('b.txt', 'b\n', 'fix: 主干修复');
    await git(['merge', '-q', '--no-ff', 'feat/x', '-m', 'merge feat/x']);
    client.openWorkspace(repo.path);
  });

  tearDown(() {
    client.openWorkspace('.');
    repo.deleteSync(recursive: true);
  });

  test('loads branches, commits with graph, and details', () async {
    final store = GitLogStore(client);
    await store.refresh();

    expect(store.currentBranch, 'main');
    expect(store.localBranches.map((b) => b.name), containsAll(['main', 'feat/x']));
    expect(store.commits, hasLength(4));
    expect(store.commits.first.subject, 'merge feat/x');
    expect(store.commits.first.refs.map((r) => r.name), containsAll(['HEAD', 'main']));
    // 合并提交向下分出第二条轨道。
    expect(store.graph.first.width, 2);

    // 默认选中第一条,并带出详情。
    expect(store.selected, store.commits.first.hash);
    final initial = store.commits.last;
    await store.selectCommit(initial.hash);
    expect(store.details!.message, 'feat: 初始提交');
    expect(store.details!.files.single.path, 'a.txt');
    expect(store.details!.files.single.status, 'A');
    store.dispose();
  });

  test('the branch filter starts at HEAD; opening the window with none selected goes back to HEAD', () async {
    // 一个没合进当前分支的提交:只在「所有分支」里看得到
    await git(['switch', '-q', '-c', 'side']);
    await commitFile('s.txt', 's\n', 'wip: 旁支');
    await git(['switch', '-q', 'main']);

    final store = GitLogStore(client);
    expect(store.branch, 'HEAD');
    await store.refresh();
    expect(store.commits.map((c) => c.subject), isNot(contains('wip: 旁支')));

    store.setBranch(null); // 点 × 清掉:所有分支
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(store.commits.map((c) => c.subject), contains('wip: 旁支'));

    store.defaultToHead(); // 再打开 Git 窗口
    expect(store.branch, 'HEAD');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(store.commits.map((c) => c.subject), isNot(contains('wip: 旁支')));

    store.setBranch('side');
    store.defaultToHead(); // 选了别的分支就不动
    expect(store.branch, 'side');
    store.dispose();
  });

  test('filters by text, branch and paths', () async {
    final store = GitLogStore(client);
    await store.refresh();

    store.setBranch('feat/x');
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(store.commits.map((c) => c.subject), ['feat: 分支上的提交', 'feat: 初始提交']);

    store.setBranch(null);
    store.setPaths(['b.txt']);
    await Future<void>.delayed(const Duration(milliseconds: 300));
    expect(store.commits.map((c) => c.subject), ['fix: 主干修复']);

    store.setPaths(const []);
    store.setText('主干');
    await Future<void>.delayed(const Duration(milliseconds: 700)); // 300ms 防抖 + 加载
    expect(store.commits.map((c) => c.subject), ['fix: 主干修复']);
    store.dispose();
  });

  test('write operations go through the store and refresh the log', () async {
    final store = GitLogStore(client);
    await store.refresh();
    final head = store.commits.first;

    expect(await store.run('New Tag', 'git.new_tag', {'name': 'v1', 'hash': head.hash}), isNull);
    expect(store.commits.first.refs.map((r) => r.name), contains('v1'));

    expect(await store.run('Edit Message', 'git.reword', {'hash': head.hash, 'message': 'merge: 改过的信息'}), isNull);
    // 旧的合并提交还挂着 v1 标签,所以在 --all 视图里仍然可见;看 HEAD 指向谁。
    expect(store.commit(store.headHash)!.subject, 'merge: 改过的信息');

    expect(await store.run('Undo', 'git.undo_commit'), isNull);
    expect(store.commit(store.headHash)!.subject, 'fix: 主干修复');

    // 失败要以错误返回,而不是抛异常。
    expect(await store.run('Reset', 'git.reset', {'hash': head.hash, 'mode': 'bogus'}), isNotNull);
    store.dispose();
  });

  test('corrupt history still shows the readable commits with a warning', () async {
    // setUp 的仓库:merge ← fix ← 初始;弄坏最老的那个提交对象。
    final initial = (await Process.run('git', ['rev-list', '--max-parents=0', 'HEAD'], workingDirectory: repo.path))
        .stdout
        .toString()
        .trim();
    final obj = File('${repo.path}/.git/objects/${initial.substring(0, 2)}/${initial.substring(2)}');
    await Process.run('chmod', ['u+w', obj.path]);
    obj.writeAsStringSync('not zlib at all');

    final store = GitLogStore(client);
    await store.refresh();
    // 对用户的保证:不报错、给出警告、读得到的提交照常显示。
    // 走到哪一级回退(流式 --all 还是只看 HEAD)取决于几个提交的时间戳是否同一秒 ——
    // git 按时间出队,先碰到坏根提交就一条也输出不了。所以这里不断言具体是哪一级。
    expect(store.error, isNull);
    expect(store.warning, isNotNull);
    expect(store.commits.map((c) => c.subject), contains('merge feat/x'));
    expect(store.commits.map((c) => c.subject), isNot(contains('feat: 初始提交')));
    store.dispose();
  });

  test('the {} icon of data files is purple whatever the change, other icons follow the status colour', () {
    const purple = Color(0xFFB589EC);
    for (final status in ['A', 'M', 'D', 'R']) {
      expect(gitFileIconColor('CDC任务存活巡检.json', status), purple, reason: status);
    }
    expect(gitFileIconColor('config.YAML', 'M'), purple);
    expect(gitFileIconColor('Cargo.toml', 'A'), purple);
    expect(gitFileIconColor('main.dart', 'M'), gitChangeColor('M'));
    expect(gitFileIconColor('README', 'A'), gitChangeColor('A'));
    expect(gitFileIconColor('old.rs', 'D'), gitChangeColor('D'));
  });

  test('changed files in the log details: added green, deleted grey, the rest the IntelliJ blue', () {
    expect(gitChangeColor('A'), IntelliJTheme.gitGreen);
    expect(gitChangeColor('D'), IntelliJTheme.textMuted);
    for (final status in ['M', 'R', 'C', 'T']) {
      expect(gitChangeColor(status), const Color(0xFF70AEFF), reason: status);
    }
  });
}
