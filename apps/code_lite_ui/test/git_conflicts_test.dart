// 合并 / 变基 / cherry-pick 冲突:检测进行中的操作、列出冲突文件、选一侧解决、继续、放弃。
// 真实 git CLI + 临时仓库。

import 'dart:convert';
import 'dart:io';

import 'package:code_lite_ui/core/git/git_parsing.dart';
import 'package:code_lite_ui/core/git/git_service.dart';
import 'package:flutter_test/flutter_test.dart';

String git(Directory dir, List<String> args, {bool allowFail = false}) {
  final r = Process.runSync('git', ['-C', dir.path, ...args], stdoutEncoding: utf8, stderrEncoding: utf8);
  if (r.exitCode != 0 && !allowFail) fail('git $args failed: ${r.stderr}');
  return (r.stdout as String).trim();
}

Directory initRepo() {
  final d = Directory.systemTemp.createTempSync('clx_conflict_');
  addTearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  git(d, ['init', '-q', '-b', 'main']);
  for (final kv in const [
    ['user.name', 'Tester'],
    ['user.email', 't@example.com'],
    ['commit.gpgsign', 'false'],
    ['core.autocrlf', 'false'],
  ]) {
    git(d, ['config', kv[0], kv[1]]);
  }
  return d;
}

void write(Directory d, String name, String content) {
  File('${d.path}/$name')
    ..parent.createSync(recursive: true)
    ..writeAsStringSync(content);
}

void commit(Directory d, String message, {List<String> add = const ['-A']}) {
  git(d, ['add', ...add]);
  git(d, ['commit', '-q', '-m', message]);
}

String read(Directory d, String name) => File('${d.path}/$name').readAsStringSync();

/// main 和 feat 都改了 a.txt 的同一行(合并 feat 进 main 会冲突)。
Directory conflictingRepo() {
  final d = initRepo();
  write(d, 'a.txt', 'base\n');
  write(d, 'dir/b.txt', 'b base\n');
  commit(d, 'base');
  git(d, ['switch', '-q', '-c', 'feat']);
  write(d, 'a.txt', 'feat change\n');
  commit(d, 'feat edits a');
  git(d, ['switch', '-q', 'main']);
  write(d, 'a.txt', 'main change\n');
  commit(d, 'main edits a');
  return d;
}

Future<Map<String, dynamic>> stateOf(GitService s) async {
  final r = await s.call('git.operation_state');
  expect(r['status'], 'ok');
  return r;
}

List<String> pathsOf(Map<String, dynamic> state) => [for (final c in state['conflicts'] as List) c['path'] as String];

void main() {
  group('parsing', () {
    test('unmerged codes map to what each side did; rebase swaps the sides', () {
      final raw = ['UU a.txt', 'AA new.txt', 'DU gone-here.txt', 'UD gone-there.txt', 'AU only-ours.txt', 'UA only-theirs.txt', 'DD both.txt', 'M  clean.txt', '?? x', ''].join('\u0000');
      final merge = parseConflictsZ(raw);
      expect(merge.map((c) => '${c['path']}:${c['yours']}/${c['theirs']}').toList(), [
        'a.txt:Modified/Modified',
        'new.txt:Added/Added',
        'gone-here.txt:Deleted/Modified',
        'gone-there.txt:Modified/Deleted',
        'only-ours.txt:Added/—',
        'only-theirs.txt:—/Added',
        'both.txt:Deleted/Deleted',
      ]);
      final rebase = parseConflictsZ(raw, rebase: true);
      expect(rebase[2]['yours'], 'Modified');
      expect(rebase[2]['theirs'], 'Deleted');
    });

    test('rename entries carry an extra path that must not be read as a status line; paths with spaces survive', () {
      final raw = ['R  new name.txt', 'old name.txt', 'UU with space.txt', ''].join('\u0000');
      expect(parseConflictsZ(raw).map((c) => c['path']).toList(), ['with space.txt']);
      expect(parseConflictsZ(''), isEmpty);
    });

    test('merge message names the incoming branch', () {
      expect(parseMergeIncoming("Merge branch 'feat/retention' into kdev\n\n# Conflicts:\n#\ta.txt"), 'feat/retention');
      expect(parseMergeIncoming("Merge remote-tracking branch 'origin/dev'"), 'origin/dev');
      expect(parseMergeIncoming("Merge tag 'v1'"), 'v1');
      expect(parseMergeIncoming('Merge commit abc123'), isNull);
      expect(parseMergeIncoming(''), isNull);
    });
  });

  group('merge', () {
    test('a conflicted merge is detected, listed, resolved side by side, then continued', () async {
      final d = conflictingRepo();
      final s = GitService(d.path);
      final clean = await stateOf(s);
      expect(clean['operation'], isNull);
      expect(clean['conflicts'], isEmpty);
      final plainFingerprint = await s.headFingerprint();
      expect(plainFingerprint, isNot(contains('|')));

      final merged = await s.call('git.merge', {'name': 'feat'});
      expect(merged['status'], 'error', reason: '冲突:合并停在进行中');

      final state = await stateOf(s);
      expect(state['operation'], 'merge');
      expect(state['branch'], 'main');
      expect(state['incoming'], 'feat');
      expect(pathsOf(state), ['a.txt']);
      expect((state['conflicts'] as List).single['yours'], 'Modified');
      expect(await s.headFingerprint(), isNot(plainFingerprint), reason: '进行中的合并让指纹变化:标题栏轮询能发现终端里出的冲突');
      expect(read(d, 'a.txt'), contains('<<<<<<<'));

      // 还有冲突:不能继续
      final early = await s.call('git.continue_operation');
      expect(early['status'], 'error');
      expect(early['error'], contains('1 个文件有冲突'));

      expect((await s.call('git.accept_side', {'path': 'a.txt', 'side': 'theirs'}))['status'], 'ok');
      expect(read(d, 'a.txt'), 'feat change\n');
      final after = await stateOf(s);
      expect(after['operation'], 'merge', reason: '冲突解决了,合并还没提交');
      expect(after['conflicts'], isEmpty);

      expect((await s.call('git.continue_operation'))['status'], 'ok');
      expect((await stateOf(s))['operation'], isNull);
      expect(git(d, ['rev-list', '--parents', '-n', '1', 'HEAD']).split(' ').length, 3, reason: '生成了合并提交(两个父提交)');
      expect(await s.headFingerprint(), isNot(contains('|')));
    });

    test('merge commit messages read like git\'s own (branch name, not a hash), also when the merge conflicts', () async {
      final d = conflictingRepo();
      git(d, ['switch', '-q', '-c', 'kdev']);
      final s = GitService(d.path);
      await s.call('git.merge', {'name': 'feat'});
      expect(File('${d.path}/.git/MERGE_MSG').readAsStringSync(), startsWith("Merge branch 'feat' into kdev"));
      expect((await stateOf(s))['incoming'], 'feat');
      await s.call('git.accept_side', {'path': 'a.txt', 'side': 'yours'});
      await s.call('git.continue_operation');
      expect(git(d, ['log', '-1', '--format=%s']), "Merge branch 'feat' into kdev");

      // main / master 上 git 自己也不写 into
      final m = conflictingRepo();
      final ms = GitService(m.path);
      await ms.call('git.merge', {'name': 'feat'});
      expect(File('${m.path}/.git/MERGE_MSG').readAsStringSync(), startsWith("Merge branch 'feat'\n"));
    });

    test('accepting yours keeps the current branch side', () async {
      final d = conflictingRepo();
      final s = GitService(d.path);
      await s.call('git.merge', {'name': 'feat'});
      expect((await s.call('git.accept_side', {'path': 'a.txt', 'side': 'yours'}))['status'], 'ok');
      expect(read(d, 'a.txt'), 'main change\n');
      expect(git(d, ['diff', '--name-only', '--diff-filter=U']), isEmpty, reason: '已标记为已解决');
      expect(pathsOf(await stateOf(s)), isEmpty);
    });

    test('abort restores the tree and clears the operation', () async {
      final d = conflictingRepo();
      final s = GitService(d.path);
      await s.call('git.merge', {'name': 'feat'});
      expect((await s.call('git.abort_operation'))['status'], 'ok');
      expect((await stateOf(s))['operation'], isNull);
      expect(read(d, 'a.txt'), 'main change\n');
      expect(git(d, ['status', '--porcelain']), isEmpty);
      expect((await s.call('git.abort_operation'))['status'], 'error', reason: '没有进行中的操作');
    });

    test('delete / modify and add / add conflicts: accepting a deletion removes the file', () async {
      final d = initRepo();
      write(d, 'keep.txt', 'k\n');
      write(d, 'deleted-here.txt', 'x\n');
      write(d, 'deleted-there.txt', 'y\n');
      commit(d, 'base');
      git(d, ['switch', '-q', '-c', 'feat']);
      write(d, 'deleted-here.txt', 'x changed by feat\n');
      File('${d.path}/deleted-there.txt').deleteSync();
      write(d, 'both-new.txt', 'feat version\n');
      commit(d, 'feat');
      git(d, ['switch', '-q', 'main']);
      File('${d.path}/deleted-here.txt').deleteSync();
      write(d, 'deleted-there.txt', 'y changed by main\n');
      write(d, 'both-new.txt', 'main version\n');
      commit(d, 'main');

      final s = GitService(d.path);
      await s.call('git.merge', {'name': 'feat'});
      final state = await stateOf(s);
      final byPath = {for (final c in state['conflicts'] as List) c['path']: '${c['yours']}/${c['theirs']}'};
      expect(byPath, {
        'both-new.txt': 'Added/Added',
        'deleted-here.txt': 'Deleted/Modified',
        'deleted-there.txt': 'Modified/Deleted',
      });

      // 我方已删除:采用「Yours」= 保持删除;采用「Theirs」= 要回对方改过的文件
      expect((await s.call('git.accept_side', {'path': 'deleted-here.txt', 'side': 'yours'}))['status'], 'ok');
      expect(File('${d.path}/deleted-here.txt').existsSync(), isFalse);
      // 对方删除了:采用「Theirs」= 删除
      expect((await s.call('git.accept_side', {'path': 'deleted-there.txt', 'side': 'theirs'}))['status'], 'ok');
      expect(File('${d.path}/deleted-there.txt').existsSync(), isFalse);
      expect((await s.call('git.accept_side', {'path': 'both-new.txt', 'side': 'theirs'}))['status'], 'ok');
      expect(read(d, 'both-new.txt'), 'feat version\n');
      expect(pathsOf(await stateOf(s)), isEmpty);
      expect((await s.call('git.continue_operation'))['status'], 'ok');
    });

    test('accepting the surviving side of a delete / modify conflict brings the file back', () async {
      final d = initRepo();
      write(d, 'f.txt', 'x\n');
      commit(d, 'base');
      git(d, ['switch', '-q', '-c', 'feat']);
      write(d, 'f.txt', 'feat edit\n');
      commit(d, 'feat');
      git(d, ['switch', '-q', 'main']);
      File('${d.path}/f.txt').deleteSync();
      commit(d, 'main deletes');
      final s = GitService(d.path);
      await s.call('git.merge', {'name': 'feat'});
      expect((await s.call('git.accept_side', {'path': 'f.txt', 'side': 'theirs'}))['status'], 'ok');
      expect(read(d, 'f.txt'), 'feat edit\n');
    });

    test('bad requests are rejected without touching anything', () async {
      final d = conflictingRepo();
      write(d, 'clean.txt', 'c\n');
      final s = GitService(d.path);
      await s.call('git.merge', {'name': 'feat'});
      expect((await s.call('git.accept_side', {'path': 'a.txt', 'side': 'middle'}))['status'], 'error');
      expect((await s.call('git.accept_side', {'path': 'dir/b.txt', 'side': 'yours'}))['error'], contains('没有冲突'), reason: '只能处理冲突文件');
      expect((await s.call('git.accept_side', {'path': '--force', 'side': 'yours'}))['status'], 'error');
      expect(read(d, 'a.txt'), contains('<<<<<<<'), reason: '没有被改动');
    });
  });

  group('rebase and cherry-pick', () {
    test('rebase: shows the rebased branch, swaps yours/theirs, accepting yours keeps your own commit', () async {
      final d = conflictingRepo();
      git(d, ['switch', '-q', 'feat']);
      final s = GitService(d.path);
      final r = await s.call('git.rebase_onto', {'name': 'main'});
      expect(r['status'], 'error');

      final state = await stateOf(s);
      expect(state['operation'], 'rebase');
      expect(state['branch'], 'feat', reason: '变基时 HEAD 是游离的,分支名取自 rebase-merge/head-name');
      expect(state['onto'], 'main');
      expect(pathsOf(state), ['a.txt']);

      // 「Yours」是自己的提交('feat change'),即使 git 的 --ours 是对方的分支
      expect((await s.call('git.accept_side', {'path': 'a.txt', 'side': 'yours'}))['status'], 'ok');
      expect(read(d, 'a.txt'), 'feat change\n');
      expect((await s.call('git.continue_operation'))['status'], 'ok');
      expect((await stateOf(s))['operation'], isNull);
      expect(git(d, ['branch', '--show-current']), 'feat');
      expect(git(d, ['log', '--format=%s', '-n', '2']).split('\n'), ['feat edits a', 'main edits a']);
    });

    test('rebase: accepting theirs takes the upstream side; abort goes back to the original branch', () async {
      final d = conflictingRepo();
      git(d, ['switch', '-q', 'feat']);
      final s = GitService(d.path);
      await s.call('git.rebase_onto', {'name': 'main'});
      expect((await s.call('git.accept_side', {'path': 'a.txt', 'side': 'theirs'}))['status'], 'ok');
      expect(read(d, 'a.txt'), 'main change\n');

      expect((await s.call('git.abort_operation'))['status'], 'ok');
      expect((await stateOf(s))['operation'], isNull);
      expect(git(d, ['branch', '--show-current']), 'feat');
      expect(read(d, 'a.txt'), 'feat change\n');
    });

    test('cherry-pick left in progress by git is recognised', () async {
      final d = conflictingRepo();
      final pick = git(d, ['rev-parse', '--short', 'feat']);
      git(d, ['cherry-pick', 'feat'], allowFail: true);
      final s = GitService(d.path);
      final state = await stateOf(s);
      expect(state['operation'], 'cherry-pick');
      expect(state['branch'], 'main');
      expect(state['incoming'], anyOf('feat', pick));
      expect(pathsOf(state), ['a.txt']);
      expect((await s.call('git.abort_operation'))['status'], 'ok');
      expect((await stateOf(s))['operation'], isNull);
    });
  });

  group('three-way merge', () {
    test('merge_versions gives base / yours / theirs; resolve_with writes the result and marks it resolved', () async {
      final d = conflictingRepo();
      final s = GitService(d.path);
      await s.call('git.merge', {'name': 'feat'});
      final v = await s.call('git.merge_versions', {'path': 'a.txt'});
      expect(v['status'], 'ok');
      expect(v['base'], 'base\n');
      expect(v['yours'], 'main change\n');
      expect(v['theirs'], 'feat change\n');

      expect((await s.call('git.resolve_with', {'path': 'a.txt', 'content': 'main change\nfeat change\n'}))['status'], 'ok');
      expect(read(d, 'a.txt'), 'main change\nfeat change\n');
      expect(pathsOf(await stateOf(s)), isEmpty);
      expect((await s.call('git.continue_operation'))['status'], 'ok');
      expect(git(d, ['show', 'HEAD:a.txt']), 'main change\nfeat change');
    });

    test('rebase: yours is your own commit, theirs is upstream', () async {
      final d = conflictingRepo();
      git(d, ['switch', '-q', 'feat']);
      final s = GitService(d.path);
      await s.call('git.rebase_onto', {'name': 'main'});
      final v = await s.call('git.merge_versions', {'path': 'a.txt'});
      expect(v['yours'], 'feat change\n');
      expect(v['theirs'], 'main change\n');
    });

    test('a side without the file gives null; non-conflicted paths are refused', () async {
      final d = initRepo();
      write(d, 'f.txt', 'x\n');
      commit(d, 'base');
      git(d, ['switch', '-q', '-c', 'feat']);
      write(d, 'f.txt', 'feat\n');
      commit(d, 'feat');
      git(d, ['switch', '-q', 'main']);
      File('${d.path}/f.txt').deleteSync();
      write(d, 'other.txt', 'o\n');
      commit(d, 'main');
      final s = GitService(d.path);
      await s.call('git.merge', {'name': 'feat'});
      final v = await s.call('git.merge_versions', {'path': 'f.txt'});
      expect(v['yours'], isNull);
      expect(v['theirs'], 'feat\n');
      expect((await s.call('git.merge_versions', {'path': 'other.txt'}))['error'], contains('没有冲突'));
      expect((await s.call('git.resolve_with', {'path': 'other.txt', 'content': 'x'}))['status'], 'error');
      expect(read(d, 'other.txt'), 'o\n');
    });

    test('project opened at a subdirectory of the repo: paths are repo-relative and still work; glob characters are literal', () async {
      final d = initRepo();
      write(d, 'svc/src/A.java', 'base\n');
      write(d, 'svc/[x].txt', 'base\n');
      write(d, 'svc/x.txt', 'untouched\n');
      commit(d, 'base');
      git(d, ['switch', '-q', '-c', 'feat']);
      write(d, 'svc/src/A.java', 'feat\n');
      write(d, 'svc/[x].txt', 'feat\n');
      commit(d, 'feat');
      git(d, ['switch', '-q', 'main']);
      write(d, 'svc/src/A.java', 'main\n');
      write(d, 'svc/[x].txt', 'main\n');
      commit(d, 'main');

      final s = GitService('${d.path}/svc');
      await s.call('git.merge', {'name': 'feat'});
      expect(pathsOf(await stateOf(s))..sort(), ['svc/[x].txt', 'svc/src/A.java']);
      expect((await s.call('git.merge_versions', {'path': 'svc/src/A.java'}))['theirs'], 'feat\n');
      expect((await s.call('git.accept_side', {'path': 'svc/src/A.java', 'side': 'theirs'}))['status'], 'ok');
      expect(read(d, 'svc/src/A.java'), 'feat\n');
      expect((await s.call('git.resolve_with', {'path': 'svc/[x].txt', 'content': 'merged\n'}))['status'], 'ok');
      expect(read(d, 'svc/[x].txt'), 'merged\n');
      expect(read(d, 'svc/x.txt'), 'untouched\n', reason: '[x] 没被当成通配符去匹配 x.txt');
      expect(pathsOf(await stateOf(s)), isEmpty);
    });
  });
}
