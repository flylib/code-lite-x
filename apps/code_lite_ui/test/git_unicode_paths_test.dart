import 'dart:io';

import 'package:code_lite_ui/core/git/git_parsing.dart';
import 'package:code_lite_ui/core/git/git_service.dart';
import 'package:flutter_test/flutter_test.dart';

/// 中文等非 ASCII 文件名:git 默认把它们转义成 `"\347\203\255…"`。改动列表、勾选(暂存)、Rollback 都要用真实路径。
void main() {
  const name = 'powerjob/热数据窗口删除(bcpoker主库).json';
  late Directory dir;
  late GitService git;

  Future<void> run(List<String> args) async {
    final r = await Process.run('git', args, workingDirectory: dir.path, environment: {
      'GIT_AUTHOR_NAME': 't', 'GIT_AUTHOR_EMAIL': 't@t', 'GIT_COMMITTER_NAME': 't', 'GIT_COMMITTER_EMAIL': 't@t',
    });
    expect(r.exitCode, 0, reason: '${r.stderr}');
  }

  setUp(() async {
    dir = Directory.systemTemp.createTempSync('clx_unicode_');
    await run(['init', '-q', '-b', 'main']);
    await run(['config', 'commit.gpgsign', 'false']);
    Directory('${dir.path}/powerjob').createSync();
    File('${dir.path}/$name').writeAsStringSync('{"v": 1}\n');
    await run(['add', '.']);
    await run(['commit', '-q', '-m', 'init']);
    git = GitService(dir.path);
  });

  tearDown(() => dir.deleteSync(recursive: true));

  List<Map<String, dynamic>> changes(Map<String, dynamic> s) => (s['changes'] as List).cast<Map<String, dynamic>>();

  test('the change list has the real path; checking (stage) and unchecking work; Rollback restores the file', () async {
    File('${dir.path}/$name').writeAsStringSync('{"v": 2}\n');
    var s = await git.status();
    expect(changes(s).single['path'], name, reason: '不是 "powerjob/\\347\\203\\255…" 这种转义文本');
    expect(changes(s).single['is_staged'], false);

    expect((await git.stage(name))['status'], 'ok');
    s = await git.status();
    expect(changes(s).single['is_staged'], true, reason: '勾上了');
    expect((await git.unstage(name))['status'], 'ok');
    expect(changes(await git.status()).single['is_staged'], false);

    expect((await git.revertFile(name))['status'], 'ok');
    expect(File('${dir.path}/$name').readAsStringSync(), '{"v": 1}\n');
    expect(changes(await git.status()), isEmpty);
  });

  test('untracked and renamed files with Chinese names', () async {
    File('${dir.path}/新建 文件.md').writeAsStringSync('x');
    await run(['mv', name, 'powerjob/改名后.json']);
    final paths = {for (final c in changes(await git.status())) c['path']: c['status']};
    expect(paths, {'新建 文件.md': 'untracked', 'powerjob/改名后.json': 'renamed'});
  });

  test('the quoted form git prints is decoded back (as in the screenshot)', () {
    expect(
      unquoteGitPath(r'"powerjob/\347\203\255\346\225\260\346\215\256\347\252\227\345\217\243\345\210\240\351\231\244(bcpoker\344\270\273\345\272\223).json"'),
      name,
    );
    expect(unquoteGitPath(r'"a\"b\\c\td.txt"'), 'a"b\\c\td.txt');
    expect(unquoteGitPath('plain/path.txt'), 'plain/path.txt');
    // 不带 -z 的老格式也能读对
    final (_, list) = parseStatusPorcelain(' M "powerjob/\\346\\224\\271.json"\n');
    expect(list.single['path'], 'powerjob/改.json');
  });
}
