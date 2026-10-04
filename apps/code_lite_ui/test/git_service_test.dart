// GitService 的集成测试:真实 git CLI + 临时仓库。
// 逐条移植自原 Rust `code-lite-fs::git` / `git_history` 的单测,断言保持一致,
// 额外覆盖 `call` 的 JSON 契约(status 包装、参数校验、未知方法)。

import 'dart:convert';
import 'dart:io';

import 'package:code_lite_ui/core/git/git_parsing.dart';
import 'package:code_lite_ui/core/git/git_service.dart';
import 'package:flutter_test/flutter_test.dart';

// ---------------------------------------------------------------------------
// 测试工具
// ---------------------------------------------------------------------------

/// 测试用临时目录,测试结束(含断言失败)自动清理。
Directory tempDir(String tag) {
  final d = Directory.systemTemp.createTempSync('codelite_hist_${tag}_');
  addTearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  return d;
}

String git(Directory dir, List<String> args, {Map<String, String>? env}) {
  final r = Process.runSync('git', ['-C', dir.path, ...args],
      environment: env, stdoutEncoding: utf8, stderrEncoding: utf8);
  if (r.exitCode != 0) fail('git $args failed: ${r.stderr}');
  return (r.stdout as String).trim();
}

void configure(Directory dir) {
  for (final kv in const [
    ['user.name', 'CodeLite Tester'],
    ['user.email', 'tester@codelite.dev'],
    ['commit.gpgsign', 'false'],
    ['tag.gpgsign', 'false'],
    ['core.autocrlf', 'false'],
  ]) {
    git(dir, ['config', kv[0], kv[1]]);
  }
}

(Directory, GitService) initRepo() {
  final d = tempDir('repo');
  git(d, ['init', '-q', '-b', 'main']);
  configure(d);
  return (d, GitService(d.path));
}

/// 裸仓库作为远程,并把本地 main 推上去建立上游。
Directory addBareRemote(Directory dir) {
  final bare = tempDir('remote');
  git(bare, ['init', '-q', '--bare', '-b', 'main']);
  git(dir, ['remote', 'add', 'origin', bare.path]);
  git(dir, ['push', '-q', '-u', 'origin', 'main']);
  return bare;
}

void write(Directory dir, String path, String content) {
  final f = File('${dir.path}/$path');
  f.parent.createSync(recursive: true);
  f.writeAsStringSync(content);
}

String read(Directory dir, String path) => File('${dir.path}/$path').readAsStringSync();

bool exists(Directory dir, String path) => File('${dir.path}/$path').existsSync();

String commitFile(Directory dir, String path, String content, String message) {
  write(dir, path, content);
  git(dir, ['add', '--', path]);
  git(dir, ['commit', '-q', '-m', message]);
  return git(dir, ['rev-parse', 'HEAD']);
}

String commitFileAt(Directory dir, String path, String content, String message, int ts) {
  write(dir, path, content);
  git(dir, ['add', '--', path]);
  final date = '@$ts +0000';
  git(dir, ['commit', '-q', '-m', message], env: {'GIT_AUTHOR_DATE': date, 'GIT_COMMITTER_DATE': date});
  return git(dir, ['rev-parse', 'HEAD']);
}

String head(Directory dir) => git(dir, ['rev-parse', 'HEAD']);

/// HEAD 历史的提交标题,最新在前。
List<String> subjects(Directory dir) => git(dir, ['log', '--format=%s', 'HEAD']).split('\n');

bool isClean(Directory dir) => git(dir, ['status', '--porcelain']).isEmpty;

bool gitPathExists(Directory dir, String name) {
  final p = git(dir, ['rev-parse', '--git-path', name]);
  final full = File(p).isAbsolute ? p : '${dir.path}/$p';
  return FileSystemEntity.typeSync(full) != FileSystemEntityType.notFound;
}

/// 仓库没有被留在半途状态(对应 Rust 的 ensure_idle().is_ok())。
void assertNoOperation(Directory dir) {
  for (final n in const ['rebase-merge', 'rebase-apply', 'CHERRY_PICK_HEAD', 'REVERT_HEAD', 'MERGE_HEAD']) {
    expect(gitPathExists(dir, n), isFalse, reason: 'repo was left mid-operation ($n)');
  }
}

/// 列表里有一个深度相等的元素(`contains` 对 Map 只比较引用)。
Matcher has(Object expected) => anyElement(equals(expected));

Map<String, dynamic> ref(String name, String kind) => {'name': name, 'kind': kind};

Future<Map<String, dynamic>> ok(GitService g, String method, [Map<String, dynamic> params = const {}]) async {
  final res = await g.call(method, params);
  expect(res['status'], 'ok', reason: '$method failed: ${res['error']}');
  return res;
}

Future<String> err(GitService g, String method, [Map<String, dynamic> params = const {}]) async {
  final res = await g.call(method, params);
  expect(res['status'], 'error', reason: '$method unexpectedly succeeded: $res');
  return res['error'] as String;
}

Future<List<Map<String, dynamic>>> logCommits(GitService g, [Map<String, dynamic> q = const {}]) async =>
    ((await ok(g, 'git.log', q))['commits'] as List).cast<Map<String, dynamic>>();

Future<List<String>> logSubjects(GitService g, [Map<String, dynamic> q = const {}]) async =>
    [for (final c in await logCommits(g, q)) c['subject'] as String];

Map<String, dynamic> change(String path, String? oldPath, String status) =>
    {'path': path, 'old_path': oldPath, 'status': status};

Map<String, dynamic> entry(String hash, String action, [String? message]) =>
    {'hash': hash, 'action': action, if (message != null) 'message': message};

void main() {
  // =========================================================================
  // 工作区状态(原 git.rs)
  // =========================================================================

  test('git engine workflow: status / stage / commit / diff', () async {
    final (dir, g) = initRepo();
    expect(await g.isRepo(), isTrue);

    // 1. 未跟踪文件
    write(dir, 'README.md', '# CodeLiteX Project\n');
    final s1 = await g.status();
    expect(s1.containsKey('status'), isFalse, reason: 'status 成功时不带 status 字段');
    // 未诞生分支时 porcelain 给的是 "No commits yet on main",与旧 Rust 实现一样原样透传
    expect(s1['branch'], contains('main'));
    expect(s1['changes'], has({'path': 'README.md', 'status': 'untracked', 'is_staged': false}));

    // 2. 暂存
    expect(await g.stage('README.md'), {'status': 'ok'});
    expect((await g.status())['changes'], has({'path': 'README.md', 'status': 'added', 'is_staged': true}));

    // 3. 提交
    final c = await g.commit('Initial commit');
    expect(c['status'], 'ok');
    expect(c['commit_hash'], isNotEmpty);
    expect(head(dir), startsWith(c['commit_hash'] as String));
    final s3 = await g.status();
    expect(s3['branch'], 'main');
    expect(s3['changes'], isEmpty);

    // 4. 修改
    write(dir, 'README.md', '# CodeLiteX Project\nLine 2.\n');
    expect((await g.status())['changes'], has({'path': 'README.md', 'status': 'modified', 'is_staged': false}));

    // 5. Diff(工作区 / 暂存区)与取消暂存
    final d = await g.diff(path: 'README.md');
    expect(d['status'], 'ok');
    expect(d['diff'], contains('+Line 2.'));
    await g.stage('README.md');
    expect((await g.diff(path: 'README.md'))['diff'], isEmpty);
    expect((await g.diff(staged: true))['diff'], contains('+Line 2.'));
    expect(await g.unstage('README.md'), {'status': 'ok'});
    expect((await g.diff(staged: true))['diff'], isEmpty);

    // 失败路径:错误编码为 {"status":"error","error":"Git command failed ..."}
    final bad = await g.commit('nothing staged');
    expect(bad['status'], 'error');
    expect(bad['error'], startsWith('Git command failed (exit code 1)'));
  });

  test('diff hunks and revert file', () async {
    final (dir, g) = initRepo();
    write(dir, 'main.rs', 'fn main() {\n    println!("Hello");\n}\n');
    await g.stage('main.rs');
    await g.commit('Add main.rs');

    // 改第 2 行并追加第 4 行
    write(dir, 'main.rs', 'fn main() {\n    println!("CodeLiteX");\n}\n// EOF\n');
    final res = await g.fileDiffHunks('main.rs');
    expect(res['status'], 'ok');
    final hunks = (res['hunks'] as List).cast<Map<String, dynamic>>();
    expect(hunks, isNotEmpty);
    expect(hunks.any((h) => h['kind'] == 'modified' || h['kind'] == 'added'), isTrue);
    expect(hunks, has({'line': 1, 'kind': 'modified', 'original_content': '    println!("Hello");', 'new_content': '    println!("CodeLiteX");'}));
    expect(hunks, has({'line': 3, 'kind': 'added', 'new_content': '// EOF'}));

    expect(await g.revertFile('main.rs'), {'status': 'ok'});
    final restored = read(dir, 'main.rs');
    expect(restored, contains('println!("Hello");'));
    expect(restored, isNot(contains('CodeLiteX')));
    expect((await g.fileDiffHunks('main.rs'))['hunks'], isEmpty);
    expect((await g.fileDiffHunks('  '))['hunks'], isEmpty);
  });

  test('hunk parser: pure deletion and multi-line modification', () {
    const raw = 'diff --git a/f b/f\n--- a/f\n+++ b/f\n'
        '@@ -2,2 +1,0 @@\n-gone 1\n-gone 2\n'
        '@@ -5,2 +4,3 @@\n-old a\n-old b\n+new a\n+new b\n+new c\n';
    expect(parseDiffHunks(raw), [
      {'line': 0, 'kind': 'deleted', 'original_content': 'gone 1\ngone 2'},
      {'line': 3, 'kind': 'modified', 'original_content': 'old a\nold b', 'new_content': 'new a'},
      {'line': 4, 'kind': 'modified', 'new_content': 'new b'},
      {'line': 5, 'kind': 'modified', 'new_content': 'new c'},
    ]);
    expect(parseHunkHeader('@@ -3 +4 @@ fn x'), (3, 1, 4, 1));
    expect(parseHunkHeader('@@ garbage @@'), isNull);
  });

  // =========================================================================
  // 纯解析(原 git_history.rs)
  // =========================================================================

  test('parse refs classification', () {
    expect(
      parseRefs('HEAD -> refs/heads/main, tag: refs/tags/v1.0, refs/remotes/origin/dev, refs/remotes/origin/HEAD, refs/stash'),
      [ref('HEAD', 'head'), ref('main', 'local'), ref('v1.0', 'tag'), ref('origin/dev', 'remote')],
    );
    expect(parseRefs('HEAD, refs/heads/feat/x'), [ref('HEAD', 'head'), ref('feat/x', 'local')]);
    expect(parseRefs(''), isEmpty);
  });

  test('parse name-status and escape', () async {
    final changes = parseNameStatusZ('M\x00a b.txt\x00R087\x00old.rs\x00new.rs\x00C100\x00x\x00y\x00D\x00gone\x00');
    expect(changes.length, 4);
    expect(changes[0], change('a b.txt', null, 'M'));
    expect(changes[1], change('new.rs', 'old.rs', 'R'));
    expect(changes[2]['status'], 'C');
    expect(changes[3]['status'], 'D');
    expect(ereEscape('a.b(c)*'), r'a\.b\(c\)\*');
    expect(isHexPrefix('abcd') && isHexPrefix('0123456789abcdef'), isTrue);
    expect(isHexPrefix('abc') || isHexPrefix('xyz12') || isHexPrefix('a' * 41), isFalse);
    // reset 模式在解析提交之前校验,非仓库目录也能得到同样的错误
    final g = GitService(tempDir('plain').path);
    expect(await err(g, 'git.reset', {'hash': 'HEAD', 'mode': 'keep'}), '不支持的 reset 模式: keep');
  });

  // =========================================================================
  // 读操作
  // =========================================================================

  test('log parses commits, refs and special subjects', () async {
    final (dir, g) = initRepo();
    final c1 = commitFile(dir, 'a.txt', '1\n', 'first');
    const weird = '修复\t问题 ✓ — émoji 🎉 | pipes; "quotes"';
    final c2 = commitFile(dir, 'b.txt', '2\n', weird);
    git(dir, ['tag', '-a', 'v1.0', '-m', 'release', c2]);
    git(dir, ['tag', 'lw', c1]);
    git(dir, ['branch', 'dev', c1]);

    final res = await ok(g, 'git.log');
    expect(res['head'], c2);
    expect(res['has_more'], isFalse);
    expect(res.containsKey('warning'), isFalse);
    final commits = (res['commits'] as List).cast<Map<String, dynamic>>();
    expect(commits.length, 2);
    final top = commits[0];
    expect(top['hash'], c2);
    expect(top['subject'], weird);
    expect(top['parents'], [c1]);
    expect(top['author'], 'CodeLite Tester');
    expect(top['email'], 'tester@codelite.dev');
    expect(top['time'] as int, greaterThan(0));
    expect(top['refs'], [ref('HEAD', 'head'), ref('main', 'local'), ref('v1.0', 'tag')]);
    final bottom = commits[1];
    expect(bottom['parents'], isEmpty);
    expect(bottom['refs'], has(ref('lw', 'tag')));
    expect(bottom['refs'], has(ref('dev', 'local')));

    // stash 不应出现在全量历史里
    write(dir, 'a.txt', 'dirty\n');
    git(dir, ['stash', '-q']);
    expect((await logCommits(g)).length, 2);

    // 游离 HEAD:HEAD 与 main 分开列出
    git(dir, ['checkout', '-q', '--detach', c2]);
    expect((await logCommits(g))[0]['refs'], [ref('HEAD', 'head'), ref('v1.0', 'tag'), ref('main', 'local')]);
    final b = await ok(g, 'git.branches');
    expect(b['detached'], isTrue);
    expect(b['current'], isNull);
    expect(b['head'], c2);
  });

  test('log text search by message and hash', () async {
    final (dir, g) = initRepo();
    final alpha = commitFile(dir, 'a', '1', 'Add feature alpha');
    commitFile(dir, 'b', '2', 'Fix bug in parser');
    commitFile(dir, 'c', '3', 'fix typo (docs)');

    expect((await logSubjects(g, {'text': 'fix'})).length, 2);
    expect(await logSubjects(g, {'text': 'fix', 'match_case': true}), ['fix typo (docs)']);
    // 非正则模式下特殊字符按字面匹配
    expect(await logSubjects(g, {'text': 'typo (docs'}), ['fix typo (docs)']);
    expect(await logSubjects(g, {'text': 'a.d'}), isEmpty);
    expect(await logSubjects(g, {'text': r'^Add .*alpha$', 'regex': true}), ['Add feature alpha']);
    // 非法正则返回错误而非崩溃
    await err(g, 'git.log', {'text': '(', 'regex': true});

    // 按短哈希搜索:即使消息不匹配也要带出该提交,并排在最前
    final short = alpha.substring(0, 8);
    final res = await logCommits(g, {'text': short});
    expect(res.length, 1);
    expect(res[0]['hash'], alpha);
    // 翻页时不重复出现
    final page2 = await logCommits(g, {'text': short, 'skip': 1});
    expect(page2.every((c) => c['hash'] != alpha), isTrue);
  });

  test('log filters: author, since, paths, branch and paging', () async {
    final (dir, g) = initRepo();
    commitFileAt(dir, 'a.txt', '1', 'old root', 1600000000);
    write(dir, 'dir/b.txt', 'b');
    git(dir, ['add', '.']);
    git(dir, ['commit', '-q', '-m', 'by alice', '--author', 'Alice <alice@x.dev>']);
    write(dir, 'a.txt', '2');
    git(dir, ['add', '.']);
    git(dir, ['commit', '-q', '-m', 'by alice smith', '--author', 'Alice Smith <as@x.dev>']);
    git(dir, ['switch', '-q', '-c', 'side']);
    final side = commitFile(dir, 'side.txt', 's', 'side work');
    git(dir, ['switch', '-q', 'main']);

    expect(await logSubjects(g, {'author': 'Alice'}), ['by alice']);
    expect((await ok(g, 'git.authors'))['authors'], ['Alice', 'Alice Smith', 'CodeLite Tester']);

    final recent = await logSubjects(g, {'since': 1650000000});
    expect(recent.length, 3);
    expect(recent, isNot(contains('old root')));

    expect(await logSubjects(g, {'paths': ['dir']}), ['by alice']);
    final onlyA = await logCommits(g, {'paths': ['a.txt']});
    expect(onlyA.length, 2);
    // 路径过滤时父提交被改写,图谱保持连通
    expect(onlyA[0]['parents'], [onlyA[1]['hash']]);

    expect((await logCommits(g)).length, 4);
    expect((await logSubjects(g, {'branch': 'main'})).length, 3);
    expect((await logCommits(g, {'branch': 'side'}))[0]['hash'], side);
    expect(await err(g, 'git.log', {'branch': '--all'}), '无效的分支: --all');

    final page1 = await ok(g, 'git.log', {'limit': 3});
    expect((page1['commits'] as List).length, 3);
    expect(page1['has_more'], isTrue);
    final page2 = await ok(g, 'git.log', {'limit': 3, 'skip': 3});
    expect((page2['commits'] as List).length, 1);
    expect(page2['has_more'], isFalse);
    expect((page2['commits'] as List)[0]['subject'], 'old root');

    // UI 会显式传 null:与缺省同等对待
    expect(
      (await logCommits(g, {'text': null, 'regex': null, 'match_case': null, 'paths': null, 'since': null})).length,
      4,
    );
  });

  test('empty repo is not an error', () async {
    final (_, g) = initRepo();
    final res = await ok(g, 'git.log');
    expect(res['commits'], isEmpty);
    expect(res['head'], '');
    expect((await ok(g, 'git.log', {'branch': 'HEAD'}))['commits'], isEmpty);
    final b = await ok(g, 'git.branches');
    expect(b['current'], 'main');
    expect(b['head'], '');
    expect(b['detached'], isFalse);
    expect(b['local'], isEmpty);
    expect((await ok(g, 'git.authors'))['authors'], isEmpty);
    await err(g, 'git.undo_commit');
    // 空仓库也能拿到状态与分支名
    expect((await g.status())['branch'], isNotEmpty);
  });

  test('branches with upstream and pushed state', () async {
    final (dir, g) = initRepo();
    final c1 = commitFile(dir, 'a', '1', 'one');
    addBareRemote(dir);
    git(dir, ['switch', '-q', '-c', 'dev']);
    commitFile(dir, 'b', '2', 'two');
    git(dir, ['push', '-q', '-u', 'origin', 'dev']);
    git(dir, ['switch', '-q', 'main']);
    git(dir, ['fetch', '-q', 'origin']);
    git(dir, ['remote', 'set-head', 'origin', 'main']);
    git(dir, ['tag', '-a', 'v1', '-m', 'annotated', c1]);
    final localOnly = commitFile(dir, 'c', '3', 'three');

    final b = await ok(g, 'git.branches');
    expect(b['current'], 'main');
    expect(b['head'], localOnly);
    expect(b['detached'], isFalse);
    final local = (b['local'] as List).cast<Map<String, dynamic>>();
    final main = local.firstWhere((l) => l['name'] == 'main');
    expect(main['current'], isTrue);
    expect(main['upstream'], 'origin/main');
    final dev = local.firstWhere((l) => l['name'] == 'dev');
    expect(dev['current'], isFalse);
    expect(dev['upstream'], 'origin/dev');
    final remote = (b['remote'] as List).cast<Map<String, dynamic>>();
    expect([for (final r in remote) r['name']], ['origin/dev', 'origin/main']);
    expect((remote[0]['remote'], remote[0]['short']), ('origin', 'dev'));
    expect(b['tags'], [
      {'name': 'v1', 'hash': c1},
    ]);

    final log = await logCommits(g);
    final root = log.firstWhere((c) => c['hash'] == c1);
    expect(root['refs'], has(ref('origin/main', 'remote')));
    expect((root['refs'] as List).every((x) => x['name'] != 'origin/HEAD'), isTrue);

    expect((await ok(g, 'git.is_pushed', {'hash': c1}))['pushed'], isTrue);
    expect((await ok(g, 'git.is_pushed', {'hash': localOnly}))['pushed'], isFalse);
    final details = await ok(g, 'git.commit_details', {'hash': c1});
    expect(details['pushed'], isTrue);
    expect(details['is_head'], isFalse);
  });

  test('commit details: root and rename', () async {
    final (dir, g) = initRepo();
    const body = 'line one\nline two\nline three\nline four\n';
    final root = commitFile(dir, 'a.txt', body, 'root commit');
    commitFile(dir, 'b.txt', 'bee\n', 'add b');
    git(dir, ['mv', 'a.txt', 'c.txt']);
    write(dir, 'b.txt', 'bee\nmore\n');
    git(dir, ['add', '.']);
    git(dir, ['commit', '-q', '-m', 'Rename a to c\n\nBody paragraph.\n']);
    final top = head(dir);

    final rd = await ok(g, 'git.commit_details', {'hash': root.substring(0, 10)});
    expect(rd['hash'], root);
    expect(rd['parents'], isEmpty);
    expect(rd['message'], 'root commit');
    expect(rd['files'], [change('a.txt', null, 'A')]);
    expect(rd['is_head'] == false && rd['pushed'] == false, isTrue);
    final rootDiff = await ok(g, 'git.commit_file_diff', {'hash': root, 'path': 'a.txt'});
    expect(rootDiff['diff'], contains('+line one'));

    final td = await ok(g, 'git.commit_details', {'hash': top});
    expect(td['is_head'], isTrue);
    expect(td['message'], 'Rename a to c\n\nBody paragraph.');
    expect(td['committer'], 'CodeLite Tester');
    expect(td['author_time'] as int > 0 && td['commit_time'] as int > 0, isTrue);
    expect(td['refs'], [ref('HEAD', 'head'), ref('main', 'local')]);
    expect(td['files'], has(change('c.txt', 'a.txt', 'R')));
    expect(td['files'], has(change('b.txt', null, 'M')));
    final renameDiff = await ok(g, 'git.commit_file_diff', {'hash': top, 'path': 'c.txt', 'old_path': 'a.txt'});
    expect(renameDiff['diff'], contains('rename from a.txt'));
    final modDiff = (await ok(g, 'git.commit_file_diff', {'hash': top, 'path': 'b.txt'}))['diff'] as String;
    expect(modDiff.contains('+more') && modDiff.contains('--- a/b.txt'), isTrue);

    expect(await err(g, 'git.commit_details', {'hash': 'deadbeefdeadbeef'}), '找不到提交: deadbeefdeadbeef');
    expect(await err(g, 'git.commit_details', {'hash': ''}), '缺少提交哈希');
  });

  test('tree, file at revision, patch and compare with local', () async {
    final (dir, g) = initRepo();
    write(dir, 'a.txt', 'alpha\n');
    write(dir, 'dir/b.txt', 'beta\n');
    File('${dir.path}/bin.dat').writeAsBytesSync([0, 1, 2, 3, 0, 255]);
    git(dir, ['add', '.']);
    git(dir, ['commit', '-q', '-m', 'snapshot']);
    final c = head(dir);

    final paths = ((await ok(g, 'git.tree_at', {'hash': c}))['paths'] as List).cast<String>()..sort();
    expect(paths, ['a.txt', 'bin.dat', 'dir/b.txt']);

    expect(await ok(g, 'git.file_at', {'hash': c, 'path': 'dir/b.txt'}), {'content': 'beta\n', 'binary': false, 'status': 'ok'});
    expect(await ok(g, 'git.file_at', {'hash': c, 'path': 'bin.dat'}), {'content': '', 'binary': true, 'status': 'ok'});
    expect(await err(g, 'git.file_at', {'hash': c, 'path': 'missing.txt'}), '文件在该提交中不存在: missing.txt');

    final patch = (await ok(g, 'git.create_patch', {'hash': c}))['patch'] as String;
    expect(patch, contains('Subject: [PATCH] snapshot'));
    expect(patch, contains('+alpha'));

    write(dir, 'a.txt', 'alpha\nnew line\n');
    File('${dir.path}/dir/b.txt').deleteSync();
    final files = ((await ok(g, 'git.compare_local', {'hash': c}))['files'] as List).cast<Map<String, dynamic>>()
      ..sort((a, b) => (a['path'] as String).compareTo(b['path'] as String));
    expect(files, [change('a.txt', null, 'M'), change('dir/b.txt', null, 'D')]);
    final diff = await ok(g, 'git.compare_local_diff', {'hash': c, 'path': 'a.txt'});
    expect(diff['diff'], contains('+new line'));
  });

  // =========================================================================
  // 写操作
  // =========================================================================

  test('cherry-pick success and conflict aborts', () async {
    final (dir, g) = initRepo();
    commitFile(dir, 'f.txt', 'base\n', 'base');
    git(dir, ['switch', '-q', '-c', 'feature']);
    final addG = commitFile(dir, 'g.txt', 'gee\n', 'add g');
    final changeF = commitFile(dir, 'f.txt', 'feature\n', 'feature edits f');
    git(dir, ['switch', '-q', 'main']);
    commitFile(dir, 'f.txt', 'main\n', 'main edits f');

    expect(await ok(g, 'git.cherry_pick', {'hash': addG}), {'status': 'ok'});
    expect(read(dir, 'g.txt'), 'gee\n');
    expect(subjects(dir)[0], 'add g');

    final before = head(dir);
    final e = await err(g, 'git.cherry_pick', {'hash': changeF});
    expect(e, startsWith('Cherry-pick 冲突,已中止'));
    expect(head(dir), before);
    expect(isClean(dir), isTrue);
    expect(gitPathExists(dir, 'CHERRY_PICK_HEAD'), isFalse);
    assertNoOperation(dir);
    expect(read(dir, 'f.txt'), 'main\n');
  });

  test('revert and conflict aborts', () async {
    final (dir, g) = initRepo();
    commitFile(dir, 'f.txt', 'one\n', 'one');
    final add = commitFile(dir, 'g.txt', 'gee\n', 'add g');
    await ok(g, 'git.revert', {'hash': add});
    expect(exists(dir, 'g.txt'), isFalse);
    expect(subjects(dir)[0], startsWith('Revert "add g"'));

    final edit = commitFile(dir, 'f.txt', 'two\n', 'two');
    commitFile(dir, 'f.txt', 'three\n', 'three');
    final before = head(dir);
    final e = await err(g, 'git.revert', {'hash': edit});
    expect(e, startsWith('Revert 冲突,已中止'));
    expect(head(dir), before);
    expect(isClean(dir), isTrue);
    expect(gitPathExists(dir, 'REVERT_HEAD'), isFalse);
  });

  test('reset modes and undo commit', () async {
    final (dir, g) = initRepo();
    final c1 = commitFile(dir, 'f.txt', '1\n', 'one');
    commitFile(dir, 'f.txt', '2\n', 'two');
    final c3 = commitFile(dir, 'f.txt', '3\n', 'three');

    await ok(g, 'git.reset', {'hash': c1, 'mode': 'soft'});
    expect(head(dir), c1);
    expect(git(dir, ['diff', '--cached']), isNotEmpty);

    await ok(g, 'git.reset', {'hash': c3, 'mode': 'hard'});
    expect(head(dir), c3);
    expect(isClean(dir), isTrue);

    await ok(g, 'git.reset', {'hash': c1, 'mode': 'mixed'});
    expect(git(dir, ['diff', '--cached']), isEmpty);
    expect(git(dir, ['diff']), isNotEmpty);
    await ok(g, 'git.reset', {'hash': c3, 'mode': 'hard'});

    await ok(g, 'git.undo_commit');
    expect(subjects(dir), ['two', 'one']);
    expect(git(dir, ['diff', '--cached']), contains('+3'));
    expect(read(dir, 'f.txt'), '3\n');

    await ok(g, 'git.reset', {'hash': c1, 'mode': 'hard'});
    expect(await err(g, 'git.undo_commit'), contains('没有父提交'));
  });

  test('checkout, new branch and tag', () async {
    final (dir, g) = initRepo();
    final c1 = commitFile(dir, 'a', '1', 'one');
    final c2 = commitFile(dir, 'b', '2', 'two');

    await ok(g, 'git.new_branch', {'name': 'feat/x', 'hash': c1, 'checkout': false});
    expect(git(dir, ['rev-parse', 'feat/x']), c1);
    expect((await ok(g, 'git.branches'))['current'], 'main');
    await ok(g, 'git.new_branch', {'name': 'co', 'hash': c1, 'checkout': true});
    expect((await ok(g, 'git.branches'))['current'], 'co');
    expect(head(dir), c1);
    expect(await err(g, 'git.new_branch', {'name': 'bad..name', 'hash': c1}), '无效的分支名: bad..name');
    await err(g, 'git.new_branch', {'name': '-x', 'hash': c1});
    await err(g, 'git.new_branch', {'name': '', 'hash': c1});

    await ok(g, 'git.new_tag', {'name': 'v1', 'hash': c2, 'message': 'release one'});
    await ok(g, 'git.new_tag', {'name': 'v2', 'hash': c2});
    await ok(g, 'git.new_tag', {'name': 'v3', 'hash': c2, 'message': '  '});
    expect(git(dir, ['cat-file', '-t', 'v1']), 'tag');
    expect(git(dir, ['cat-file', '-t', 'v2']), 'commit');
    expect(git(dir, ['cat-file', '-t', 'v3']), 'commit');
    expect(((await ok(g, 'git.branches'))['tags'] as List).every((t) => t['hash'] == c2), isTrue);
    expect(await err(g, 'git.new_tag', {'name': 'bad tag', 'hash': c2}), '无效的标签名: bad tag');

    await ok(g, 'git.checkout_revision', {'hash': c2});
    final b = await ok(g, 'git.branches');
    expect(b['detached'], isTrue);
    expect(b['head'], c2);
  });

  test('reword HEAD and non-HEAD', () async {
    final (dir, g) = initRepo();
    commitFile(dir, 'a', '1', 'one');
    final c2 = commitFile(dir, 'b', '2', 'two');
    commitFile(dir, 'c', '3', 'three');

    // HEAD:只改消息,暂存区的修改不能被带进提交
    write(dir, 'staged.txt', 'staged\n');
    git(dir, ['add', 'staged.txt']);
    await ok(g, 'git.reword', {'hash': 'HEAD', 'message': 'three, reworded\n\nwith body'});
    expect(subjects(dir), ['three, reworded', 'two', 'one']);
    expect(git(dir, ['log', '-1', '--format=%B']), 'three, reworded\n\nwith body');
    expect(git(dir, ['show', '--name-only', '--format=', 'HEAD']), isNot(contains('staged.txt')));
    expect(git(dir, ['diff', '--cached', '--name-only']), contains('staged.txt'));

    // 非 HEAD:脚本化 rebase,本地修改经 autostash 保留
    await ok(g, 'git.reword', {'hash': c2, 'message': "two, reworded (it's quoted)"});
    expect(subjects(dir), ['three, reworded', "two, reworded (it's quoted)", 'one']);
    expect(git(dir, ['log', '-1', '--format=%B']), 'three, reworded\n\nwith body');
    expect(read(dir, 'staged.txt'), 'staged\n');
    assertNoOperation(dir);

    expect(await err(g, 'git.reword', {'hash': 'HEAD', 'message': '   '}), '提交信息不能为空');
  });

  test('drop commit', () async {
    final (dir, g) = initRepo();
    commitFile(dir, 'f1', '1', 'one');
    final c2 = commitFile(dir, 'f2', '2', 'two');
    commitFile(dir, 'f3', '3', 'three');
    await ok(g, 'git.drop', {'hash': c2});
    expect(subjects(dir), ['three', 'one']);
    expect(!exists(dir, 'f2') && exists(dir, 'f3'), isTrue);
    await ok(g, 'git.drop', {'hash': 'HEAD'});
    expect(subjects(dir), ['one']);
    assertNoOperation(dir);
  });

  test('fixup and squash into', () async {
    final (dir, g) = initRepo();
    final c1 = commitFile(dir, 'a.txt', 'one\n', 'A');
    commitFile(dir, 'b.txt', 'bee\n', 'B');
    commitFile(dir, 'c.txt', 'see\n', 'C');

    expect(await err(g, 'git.fixup', {'hash': c1}), '没有已暂存的修改');

    // 根提交 fixup(--root),同时有一个未暂存的修改要经 autostash 保留
    write(dir, 'a.txt', 'one\ntwo\n');
    git(dir, ['add', 'a.txt']);
    write(dir, 'c.txt', 'see\nunstaged\n');
    await ok(g, 'git.fixup', {'hash': c1});
    expect(subjects(dir), ['C', 'B', 'A']);
    expect(git(dir, ['show', 'HEAD~2:a.txt']), 'one\ntwo');
    expect(read(dir, 'c.txt'), 'see\nunstaged\n');
    expect(git(dir, ['diff', '--cached']), isEmpty);
    git(dir, ['checkout', '--', 'c.txt']);

    // squash_into:并入并替换目标提交消息
    final b = git(dir, ['rev-parse', 'HEAD~1']);
    write(dir, 'b.txt', 'bee\nbuzz\n');
    git(dir, ['add', 'b.txt']);
    await ok(g, 'git.squash_into', {'hash': b, 'message': 'B, now with buzz\n\ndetails'});
    expect(subjects(dir), ['C', 'B, now with buzz', 'A']);
    expect(git(dir, ['log', '-1', '--format=%B', 'HEAD~1']), 'B, now with buzz\n\ndetails');
    expect(git(dir, ['show', 'HEAD~1:b.txt']), 'bee\nbuzz');
    expect(isClean(dir), isTrue);
    assertNoOperation(dir);

    write(dir, 'b.txt', 'x\n');
    git(dir, ['add', 'b.txt']);
    expect(await err(g, 'git.squash_into', {'hash': 'HEAD', 'message': ''}), '提交信息不能为空');
  });

  test('fixup conflict restores staged changes', () async {
    final (dir, g) = initRepo();
    final c1 = commitFile(dir, 'f.txt', 'a\n', 'one');
    commitFile(dir, 'f.txt', 'b\n', 'two');
    write(dir, 'f.txt', 'c\n');
    git(dir, ['add', 'f.txt']);
    final before = head(dir);
    final e = await err(g, 'git.fixup', {'hash': c1});
    expect(e, startsWith('Rebase 失败,已中止'));
    expect(head(dir), before);
    expect(git(dir, ['diff', '--cached']), contains('+c'));
    assertNoOperation(dir);
  });

  test('rebase plan and interactive rebase', () async {
    final (dir, g) = initRepo();
    final c = [for (var i = 1; i <= 5; i++) commitFile(dir, 'f$i', '$i\n', 'commit $i')];

    final plan = await ok(g, 'git.rebase_plan', {'hash': c[1]});
    expect(plan['base'], c[0]);
    final entries = (plan['entries'] as List).cast<Map<String, dynamic>>();
    expect([for (final e in entries) e['hash']], [c[1], c[2], c[3], c[4]]);
    expect(entries[0]['subject'], 'commit 2');
    expect(entries[0]['message'], 'commit 2');
    final rootPlan = await ok(g, 'git.rebase_plan', {'hash': c[0]});
    expect(rootPlan.containsKey('base') && rootPlan['base'] == null, isTrue);

    // 首条为 squash / 计划与历史不一致 → 拒绝
    expect(
      await err(g, 'git.rebase_interactive', {'base': c[0], 'entries': [entry(c[1], 'squash')]}),
      '第一个提交不能是 squash / fixup',
    );
    expect(await err(g, 'git.rebase_interactive', {'base': c[0], 'entries': [entry(c[1], 'pick')]}), contains('不一致'));
    expect(head(dir), c[4]);
    // 非法 action 属于参数错误
    expect(
      await err(g, 'git.rebase_interactive', {'base': c[0], 'entries': [entry(c[1], 'edit')]}),
      startsWith('参数无效: unknown variant `edit`'),
    );

    // 重排 + reword + squash(带消息)+ drop 一次完成
    await ok(g, 'git.rebase_interactive', {
      'base': c[0],
      'entries': [
        entry(c[2], 'pick'),
        entry(c[1], 'reword', 'two reworded'),
        entry(c[4], 'squash', 'two and five'),
        entry(c[3], 'drop'),
      ],
    });
    expect(subjects(dir), ['two and five', 'commit 3', 'commit 1']);
    expect(exists(dir, 'f2') && exists(dir, 'f5') && !exists(dir, 'f4'), isTrue);
    expect(git(dir, ['diff-tree', '--no-commit-id', '--name-only', '-r', 'HEAD']), 'f2\nf5');
    assertNoOperation(dir);

    // 从根开始;squash 不带消息时保留 git 默认的合并消息,fixup 丢弃消息
    final plan2 = await ok(g, 'git.rebase_plan', {'hash': 'HEAD~2'});
    expect(plan2['base'], isNull);
    final p = [for (final e in plan2['entries'] as List) e['hash'] as String];
    await ok(g, 'git.rebase_interactive', {
      'base': null,
      'entries': [entry(p[0], 'pick'), entry(p[1], 'squash'), entry(p[2], 'fixup')],
    });
    expect(subjects(dir).length, 1);
    final body = git(dir, ['log', '-1', '--format=%B']);
    expect(body.contains('commit 1') && body.contains('commit 3') && !body.contains('two and five'), isTrue);
    expect(exists(dir, 'f5'), isTrue);
  });

  test('rebase rejects merges and foreign commits', () async {
    final (dir, g) = initRepo();
    final c1 = commitFile(dir, 'a', '1', 'one');
    git(dir, ['switch', '-q', '-c', 'side']);
    final side = commitFile(dir, 's', 's', 'side');
    git(dir, ['switch', '-q', 'main']);
    commitFile(dir, 'b', '2', 'two');
    git(dir, ['merge', '-q', '--no-ff', '-m', 'merge side', 'side']);

    expect(await err(g, 'git.rebase_plan', {'hash': c1}), '范围内包含合并提交,不支持交互式 rebase');
    await err(g, 'git.reword', {'hash': c1, 'message': 'x'});
    await err(g, 'git.drop', {'hash': c1});

    git(dir, ['switch', '-q', 'side']);
    commitFile(dir, 't', 't', 'side 2');
    git(dir, ['switch', '-q', 'main']);
    final foreign = git(dir, ['rev-parse', 'side']);
    expect(await err(g, 'git.rebase_plan', {'hash': foreign}), contains('不在当前分支'));
    await err(g, 'git.rebase_plan', {'hash': side});
  });

  test('interactive rebase conflict aborts', () async {
    final (dir, g) = initRepo();
    final c1 = commitFile(dir, 'f.txt', 'a\n', 'one');
    final c2 = commitFile(dir, 'f.txt', 'b\n', 'two');
    final c3 = commitFile(dir, 'f.txt', 'c\n', 'three');
    write(dir, 'other.txt', 'local\n');

    final e = await err(g, 'git.rebase_interactive', {
      'base': c1,
      'entries': [entry(c3, 'pick'), entry(c2, 'pick')],
    });
    expect(e, startsWith('Rebase 失败,已中止'));
    expect(head(dir), c3);
    expect(subjects(dir), ['three', 'two', 'one']);
    expect(read(dir, 'f.txt'), 'c\n');
    expect(read(dir, 'other.txt'), 'local\n');
    assertNoOperation(dir);
  });

  test('push up to', () async {
    final (dir, g) = initRepo();
    commitFile(dir, 'a', '1', 'one');
    final bare = addBareRemote(dir);
    final c2 = commitFile(dir, 'b', '2', 'two');
    final c3 = commitFile(dir, 'c', '3', 'three');

    expect(await ok(g, 'git.push_up_to', {'hash': c2}), {'remote': 'origin', 'branch': 'main', 'status': 'ok'});
    expect(git(bare, ['rev-parse', 'main']), c2);
    git(dir, ['fetch', '-q', 'origin']);
    expect((await ok(g, 'git.is_pushed', {'hash': c2}))['pushed'], isTrue);
    expect((await ok(g, 'git.is_pushed', {'hash': c3}))['pushed'], isFalse);

    // 无上游:默认 origin + 当前分支名
    git(dir, ['switch', '-q', '-c', 'topic']);
    final t1 = commitFile(dir, 't', 't', 'topic work');
    expect(await ok(g, 'git.push_up_to', {'hash': t1}), {'remote': 'origin', 'branch': 'topic', 'status': 'ok'});
    expect(git(bare, ['rev-parse', 'topic']), t1);

    // 不在当前分支历史上 / 游离 HEAD → 拒绝
    git(dir, ['switch', '-q', 'main']);
    expect(await err(g, 'git.push_up_to', {'hash': t1}), contains('不在当前分支'));
    git(dir, ['checkout', '-q', '--detach', 'HEAD']);
    expect(await err(g, 'git.push_up_to', {'hash': c2}), contains('游离'));
  });

  test('log returns readable commits when history is corrupt', () async {
    final (dir, g) = initRepo();
    final oldest = commitFileAt(dir, 'a.txt', 'a', 'first', 1700000000);
    commitFileAt(dir, 'b.txt', 'b', 'second', 1700000100);
    commitFileAt(dir, 'c.txt', 'c', 'third', 1700000200);

    // 模拟磁盘损坏:最老那个提交的 loose 对象变成无法解压的垃圾(loose 对象是只读的,先放开写权限)
    final obj = '${dir.path}/.git/objects/${oldest.substring(0, 2)}/${oldest.substring(2)}';
    expect(Process.runSync('chmod', ['u+w', obj]).exitCode, 0);
    File(obj).writeAsBytesSync(utf8.encode('not zlib at all'));

    final res = await ok(g, 'git.log');
    // git 输出一个提交前要先解析它的父提交,所以紧挨着损坏点的 "second" 也出不来
    expect([for (final c in res['commits'] as List) c['subject']], ['third']);
    expect(res['has_more'], isFalse);
    final warning = res['warning'] as String?;
    expect(warning, isNotNull, reason: "partial log must carry git's error");
    expect(warning!.contains(oldest.substring(0, 7)) || warning.contains('corrupt'), isTrue, reason: warning);

    // 一条都读不到时仍然是错误
    await err(g, 'git.log', {'branch': oldest});
  });

  // =========================================================================
  // call 的 JSON 契约
  // =========================================================================

  test('call: unknown method, missing / mistyped params never throw', () async {
    final (dir, g) = initRepo();
    final c1 = commitFile(dir, 'a', '1', 'one');
    expect(await g.call('git.nope'), {'status': 'error', 'error': '未知的 git 方法: git.nope'});
    expect(await g.call('  '), {'status': 'error', 'error': 'method is required'});
    expect(await err(g, 'git.cherry_pick'), '参数无效: missing field `hash`');
    expect(await err(g, 'git.cherry_pick', {'hash': 42}), startsWith('参数无效: invalid type: integer `42`'));
    expect(await err(g, 'git.log', {'limit': 'ten'}), startsWith('参数无效: invalid type'));
    // 方法名两侧空白被忽略;多余字段被忽略
    expect((await g.call(' git.is_pushed ', {'hash': c1, 'extra': true}))['status'], 'ok');
    // 非仓库目录:git 自己的报错原样带回
    final outside = GitService(tempDir('plain').path);
    expect(await err(outside, 'git.branches'), startsWith('Git command failed (exit code 128)'));
    expect((await outside.status())['status'], 'error');
    expect(await outside.isRepo(), isFalse);
  });
}
