// 标题栏分支菜单用到的 Git 操作:切换 / 更新 / 推送 / 合并 / 变基 / 重命名 / 删除 / 最近分支。
// 真实 git CLI + 临时仓库;远程用本地 bare 仓库模拟。

import 'dart:convert';
import 'dart:io';

import 'package:code_lite_ui/core/git/git_parsing.dart';
import 'package:code_lite_ui/core/git/git_service.dart';
import 'package:flutter_test/flutter_test.dart';

Directory tempDir(String tag) {
  final d = Directory.systemTemp.createTempSync('clx_branch_${tag}_');
  addTearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  return d;
}

String git(Directory dir, List<String> args) {
  final r = Process.runSync('git', ['-C', dir.path, ...args], stdoutEncoding: utf8, stderrEncoding: utf8);
  if (r.exitCode != 0) fail('git $args failed: ${r.stderr}');
  return (r.stdout as String).trim();
}

void configure(Directory dir) {
  for (final kv in const [
    ['user.name', 'Tester'],
    ['user.email', 't@example.com'],
    ['commit.gpgsign', 'false'],
    ['core.autocrlf', 'false'],
  ]) {
    git(dir, ['config', kv[0], kv[1]]);
  }
}

void commitFile(Directory dir, String name, String content, String message) {
  File('${dir.path}/$name').writeAsStringSync(content);
  git(dir, ['add', name]);
  git(dir, ['commit', '-q', '-m', message]);
}

Directory initRepo([String tag = 'repo']) {
  final d = tempDir(tag);
  git(d, ['init', '-q', '-b', 'main']);
  configure(d);
  commitFile(d, 'a.txt', 'a\n', 'first');
  return d;
}

/// 一个 bare 远程,加上克隆自它的工作仓库;远程里已有 main。
(Directory remote, Directory work) withRemote() {
  final remote = tempDir('remote');
  git(remote, ['init', '-q', '--bare', '-b', 'main']);
  final work = tempDir('work');
  git(work, ['init', '-q', '-b', 'main']);
  configure(work);
  git(work, ['remote', 'add', 'origin', remote.path]);
  commitFile(work, 'a.txt', 'a\n', 'first');
  git(work, ['push', '-q', '-u', 'origin', 'main']);
  return (remote, work);
}

void main() {
  group('recentBranches', () {
    test('newest first, only existing local branches, no current, no duplicates', () {
      final log = [
        'checkout: moving from main to feat/x', // 最新
        'commit: something',
        'checkout: moving from old to main',
        'checkout: moving from feat/x to gone',
        'checkout: moving from main to feat/x',
      ];
      final out = recentBranches(log, {'main', 'feat/x', 'old'}, 'main', 5);
      expect(out, ['feat/x', 'old']);
    });

    test('a limit, and lines that are not checkouts are ignored', () {
      final log = [for (var i = 0; i < 10; i++) 'checkout: moving from b$i to b${i + 1}', 'reset: moving to HEAD~1'];
      final existing = {for (var i = 0; i <= 10; i++) 'b$i'};
      expect(recentBranches(log, existing, null, 3), ['b1', 'b0', 'b2']);
      expect(recentBranches(const [], existing, null, 3), isEmpty);
    });
  });

  group('checkout', () {
    test('switches to a local branch; unknown names are reported', () async {
      final d = initRepo();
      git(d, ['branch', 'dev']);
      final svc = GitService(d.path);
      final res = await svc.call('git.checkout', {'name': 'dev'});
      expect(res['status'], 'ok');
      expect(git(d, ['branch', '--show-current']), 'dev');
      final bad = await svc.call('git.checkout', {'name': 'nope'});
      expect(bad['status'], 'error');
      expect(bad['error'], contains('找不到分支'));
      expect((await svc.call('git.checkout', {'name': '--detach'}))['status'], 'error');
    });

    test('a remote branch becomes a local branch that tracks it', () async {
      final (remote, work) = withRemote();
      git(work, ['switch', '-q', '-c', 'feat/y']);
      commitFile(work, 'y.txt', 'y\n', 'on feat/y');
      git(work, ['push', '-q', 'origin', 'feat/y']);
      git(work, ['switch', '-q', 'main']);
      git(work, ['branch', '-q', '-D', 'feat/y']);
      git(work, ['fetch', '-q']);
      expect(git(work, ['branch', '--list', 'feat/y']), isEmpty);

      final res = await GitService(work.path).call('git.checkout', {'name': 'origin/feat/y'});
      expect(res['status'], 'ok');
      expect(res['branch'], 'feat/y');
      expect(git(work, ['branch', '--show-current']), 'feat/y');
      expect(git(work, ['config', 'branch.feat/y.remote']), 'origin');
      expect(File('${work.path}/y.txt').existsSync(), isTrue);
      expect(remote.existsSync(), isTrue);

      // 同名本地分支已经有了:直接切过去,不重复创建
      git(work, ['switch', '-q', 'main']);
      final again = await GitService(work.path).call('git.checkout', {'name': 'origin/feat/y'});
      expect(again['status'], 'ok');
      expect(git(work, ['branch', '--show-current']), 'feat/y');
    });

    test('uncommitted changes that would be overwritten stop the switch', () async {
      final d = initRepo();
      git(d, ['switch', '-q', '-c', 'dev']);
      commitFile(d, 'a.txt', 'dev\n', 'dev change');
      git(d, ['switch', '-q', 'main']);
      File('${d.path}/a.txt').writeAsStringSync('local edit\n');
      final res = await GitService(d.path).call('git.checkout', {'name': 'dev'});
      expect(res['status'], 'error');
      expect(git(d, ['branch', '--show-current']), 'main');
      expect(File('${d.path}/a.txt').readAsStringSync(), 'local edit\n');
    });
  });

  group('recent_branches', () {
    test('lists branches visited, newest first, without the current one', () async {
      final d = initRepo();
      git(d, ['branch', 'one']);
      git(d, ['branch', 'two']);
      git(d, ['switch', '-q', 'one']);
      git(d, ['switch', '-q', 'two']);
      git(d, ['switch', '-q', 'main']);
      final res = await GitService(d.path).call('git.recent_branches', {'limit': 5});
      expect(res['branches'], ['two', 'one']);
    });
  });

  group('update and push', () {
    test('update brings in what someone else pushed', () async {
      final (remote, work) = withRemote();
      final other = tempDir('other');
      git(other, ['clone', '-q', remote.path, '.']);
      configure(other);
      commitFile(other, 'b.txt', 'b\n', 'from other');
      git(other, ['push', '-q']);

      final res = await GitService(work.path).call('git.update');
      expect(res['status'], 'ok', reason: '$res');
      expect(File('${work.path}/b.txt').existsSync(), isTrue);
    });

    test('update without an upstream says so', () async {
      final d = initRepo();
      final res = await GitService(d.path).call('git.update');
      expect(res['status'], 'error');
      expect(res['error'], contains('没有上游'));
    });

    test('push sends the branch to its upstream', () async {
      final (remote, work) = withRemote();
      commitFile(work, 'c.txt', 'c\n', 'to push');
      final res = await GitService(work.path).call('git.push');
      expect(res['status'], 'ok', reason: '$res');
      expect(res['set_upstream'], false);
      expect(git(remote, ['log', '--format=%s', '-1', 'main']), 'to push');
    });

    test('push of a branch without upstream sets one', () async {
      final (remote, work) = withRemote();
      git(work, ['switch', '-q', '-c', 'feat/new']);
      commitFile(work, 'n.txt', 'n\n', 'new branch commit');
      final res = await GitService(work.path).call('git.push');
      expect(res['status'], 'ok', reason: '$res');
      expect(res['set_upstream'], true);
      expect(res['remote'], 'origin');
      expect(git(work, ['config', 'branch.feat/new.remote']), 'origin');
      expect(git(remote, ['log', '--format=%s', '-1', 'feat/new']), 'new branch commit');
    });

    test('outgoing lists the commits after the upstream, newest first', () async {
      final (_, work) = withRemote();
      commitFile(work, 'c.txt', 'c\n', 'first local');
      commitFile(work, 'd.txt', 'd\n', 'second local');
      final res = await GitService(work.path).call('git.outgoing');
      expect(res['status'], 'ok', reason: '$res');
      expect(res['set_upstream'], false);
      expect((res['remote'], res['target_branch'], res['branch']), ('origin', 'main', 'main'));
      expect([for (final c in res['commits'] as List) c['subject']], ['second local', 'first local']);
      final c = (res['commits'] as List).first as Map;
      expect((c['hash'] as String).length, 40);
      expect(c['time'], greaterThan(0));

      await GitService(work.path).call('git.push');
      final after = await GitService(work.path).call('git.outgoing');
      expect(after['commits'], isEmpty, reason: '推完就没有了');
    });

    test('outgoing for a branch never pushed: only commits not on any remote, and it will set the upstream', () async {
      final (_, work) = withRemote();
      git(work, ['switch', '-q', '-c', 'feat/new']);
      commitFile(work, 'n.txt', 'n\n', 'only on feat');
      final res = await GitService(work.path).call('git.outgoing');
      expect(res['set_upstream'], true);
      expect(res['target_branch'], 'feat/new');
      expect([for (final c in res['commits'] as List) c['subject']], ['only on feat']);
    });

    test('update with stash keeps local edits and brings in the remote ones', () async {
      final (remote, work) = withRemote();
      final other = tempDir('other');
      git(other, ['clone', '-q', remote.path, '.']);
      configure(other);
      commitFile(other, 'b.txt', 'b\n', 'from other');
      git(other, ['push', '-q']);
      File('${work.path}/local.txt').writeAsStringSync('mine\n');
      final changes = await GitService(work.path).call('git.local_changes');
      expect([for (final c in changes['changes'] as List) c['path']], contains('local.txt'));

      final res = await GitService(work.path).call('git.update', {'stash': true});
      expect(res['status'], 'ok', reason: '$res');
      expect(res['stash_conflict'], isNull);
      expect(File('${work.path}/b.txt').existsSync(), isTrue);
      expect(File('${work.path}/local.txt').readAsStringSync(), 'mine\n', reason: '本地改动恢复了');
      expect(git(work, ['stash', 'list']), isEmpty, reason: '没留下 stash');
    });

    test('push without any remote is reported', () async {
      final d = initRepo();
      final res = await GitService(d.path).call('git.push');
      expect(res['status'], 'error');
      expect(res['error'], contains('没有配置远程仓库'));
    });
  });

  group('merge and rebase', () {
    Directory diverged() {
      final d = initRepo();
      git(d, ['switch', '-q', '-c', 'feat']);
      commitFile(d, 'f.txt', 'f\n', 'feature work');
      git(d, ['switch', '-q', 'main']);
      commitFile(d, 'm.txt', 'm\n', 'main work');
      return d;
    }

    test('merge brings a branch into the current one', () async {
      final d = diverged();
      final res = await GitService(d.path).call('git.merge', {'name': 'feat'});
      expect(res['status'], 'ok', reason: '$res');
      expect(File('${d.path}/f.txt').existsSync(), isTrue);
      expect(git(d, ['log', '--format=%p', '-1']).split(' '), hasLength(2), reason: 'a merge commit');
    });

    test('a conflicting merge is reported and leaves the repository busy', () async {
      final d = initRepo();
      git(d, ['switch', '-q', '-c', 'feat']);
      commitFile(d, 'a.txt', 'feat side\n', 'feat edit');
      git(d, ['switch', '-q', 'main']);
      commitFile(d, 'a.txt', 'main side\n', 'main edit');
      final svc = GitService(d.path);
      final res = await svc.call('git.merge', {'name': 'feat'});
      expect(res['status'], 'error');
      // 停在合并中:再动手前要先解决或中止
      final next = await svc.call('git.checkout', {'name': 'feat'});
      expect(next['status'], 'error');
      expect(next['error'], contains('进行中'));
    });

    test('rebase puts the current branch on top of another', () async {
      final d = diverged();
      git(d, ['switch', '-q', 'feat']);
      final res = await GitService(d.path).call('git.rebase_onto', {'name': 'main'});
      expect(res['status'], 'ok', reason: '$res');
      expect(git(d, ['log', '--format=%s', '-3']).split('\n'), ['feature work', 'main work', 'first']);
    });

    test('rebase on a detached HEAD is refused', () async {
      final d = diverged();
      git(d, ['switch', '-q', '--detach']);
      final res = await GitService(d.path).call('git.rebase_onto', {'name': 'main'});
      expect(res['status'], 'error');
    });
  });

  group('rename and delete', () {
    test('rename validates the new name', () async {
      final d = initRepo();
      git(d, ['branch', 'old']);
      final svc = GitService(d.path);
      expect((await svc.call('git.rename_branch', {'name': 'old', 'new_name': 'new/name'}))['status'], 'ok');
      expect(git(d, ['branch', '--list', 'new/name']), contains('new/name'));
      expect(git(d, ['branch', '--list', 'old']), isEmpty);
      for (final bad in ['', ' ', '-x', 'a..b', 'with space']) {
        expect((await svc.call('git.rename_branch', {'name': 'new/name', 'new_name': bad}))['status'], 'error', reason: bad);
      }
    });

    test('delete refuses the current branch and unmerged work unless forced', () async {
      final d = initRepo();
      git(d, ['switch', '-q', '-c', 'wip']);
      commitFile(d, 'w.txt', 'w\n', 'unmerged');
      git(d, ['switch', '-q', 'main']);
      final svc = GitService(d.path);

      expect((await svc.call('git.delete_branch', {'name': 'main'}))['error'], contains('当前所在'));
      final soft = await svc.call('git.delete_branch', {'name': 'wip'});
      expect(soft['status'], 'error');
      expect(git(d, ['branch', '--list', 'wip']), isNotEmpty);
      final forced = await svc.call('git.delete_branch', {'name': 'wip', 'force': true});
      expect(forced['status'], 'ok');
      expect(git(d, ['branch', '--list', 'wip']), isEmpty);
      expect((await svc.call('git.delete_branch', {'name': '-D'}))['status'], 'error');
    });
  });
}
