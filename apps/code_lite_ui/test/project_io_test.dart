import 'dart:io';

import 'package:code_lite_ui/core/platform/workspace_io.dart' as io;
import 'package:flutter_test/flutter_test.dart';

Directory tempDir(String tag) {
  final d = Directory.systemTemp.createTempSync('clx_projio_${tag}_');
  addTearDown(() {
    if (d.existsSync()) d.deleteSync(recursive: true);
  });
  return d;
}

void main() {
  test('repository names come from the last part of the address', () {
    expect(io.repositoryNameFromUrl('git@github.com:flylib/code-lite-x.git'), 'code-lite-x');
    expect(io.repositoryNameFromUrl('https://github.com/a/b.git'), 'b');
    expect(io.repositoryNameFromUrl('https://example.com/a/b/'), 'b');
    expect(io.repositoryNameFromUrl('/tmp/some/repo'), 'repo');
    expect(io.repositoryNameFromUrl('  '), '');
  });

  group('cloneRepository', () {
    Directory source() {
      final d = tempDir('src');
      Process.runSync('git', ['init', '-q', '-b', 'main'], workingDirectory: d.path);
      File('${d.path}/a.txt').writeAsStringSync('a\n');
      for (final args in [
        ['add', '.'],
        ['-c', 'user.name=T', '-c', 'user.email=t@e.com', 'commit', '-q', '-m', 'first'],
      ]) {
        final r = Process.runSync('git', args, workingDirectory: d.path);
        if (r.exitCode != 0) fail('${r.stderr}');
      }
      return d;
    }

    test('clones into parent/name, defaulting the name from the address', () async {
      final src = source();
      final parent = tempDir('parent');
      final (path, err) = await io.cloneRepository(src.path, parent.path, name: 'copy');
      expect(err, isNull);
      expect(path, '${parent.path}/copy');
      expect(File('$path/a.txt').existsSync(), isTrue);

      final (path2, err2) = await io.cloneRepository(src.path, parent.path);
      expect(err2, isNull);
      expect(path2, '${parent.path}/${io.repositoryNameFromUrl(src.path)}');
    });

    test('refuses a taken target, a missing parent, bad addresses and failing clones', () async {
      final src = source();
      final parent = tempDir('parent');
      Directory('${parent.path}/taken').createSync();
      File('${parent.path}/taken/x').writeAsStringSync('x');
      expect((await io.cloneRepository(src.path, parent.path, name: 'taken')).$2, contains('已存在'));
      expect((await io.cloneRepository(src.path, '${parent.path}/missing', name: 'x')).$2, contains('目录不存在'));
      expect((await io.cloneRepository('', parent.path)).$2, isNotNull);
      expect((await io.cloneRepository('--upload-pack=evil', parent.path, name: 'x')).$2, isNotNull);
      expect((await io.cloneRepository(src.path, parent.path, name: '../escape')).$2, isNotNull);
      final bad = await io.cloneRepository('${parent.path}/not-a-repo', parent.path, name: 'y');
      expect(bad.$1, isNull);
      expect(bad.$2, isNotEmpty);
      expect(Directory('${parent.path}/y').existsSync(), isFalse, reason: '失败不留下半成品目录');
    });

    test('an empty target folder is fine', () async {
      final src = source();
      final parent = tempDir('parent');
      Directory('${parent.path}/empty').createSync();
      expect((await io.cloneRepository(src.path, parent.path, name: 'empty')).$2, isNull);
    });
  });

  group('createProject', () {
    test('creates the folder and makes it a repository', () async {
      final parent = tempDir('parent');
      final (path, err) = await io.createProject(parent.path, '  my-app ');
      expect(err, isNull);
      expect(path, '${parent.path}/my-app');
      expect(Directory('$path/.git').existsSync(), isTrue);
    });

    test('rejects empty names, separators, taken folders and a missing parent', () async {
      final parent = tempDir('parent');
      for (final bad in ['', '  ', '.', '..', 'a/b', r'a\b']) {
        expect((await io.createProject(parent.path, bad)).$2, isNotNull, reason: bad);
      }
      Directory('${parent.path}/taken').createSync();
      File('${parent.path}/taken/x').writeAsStringSync('x');
      expect((await io.createProject(parent.path, 'taken')).$2, contains('已存在'));
      expect((await io.createProject('${parent.path}/nope', 'x')).$2, contains('目录不存在'));
      expect(Directory('${parent.path}/a').existsSync(), isFalse);
    });
  });
}
