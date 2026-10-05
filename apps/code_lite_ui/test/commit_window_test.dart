import 'dart:async';
import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/git/git_service.dart';
import 'package:code_lite_ui/features/commit/commit_panel.dart';
import 'package:code_lite_ui/features/commit/diff_tab.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  late Directory repo;
  Future<String> git(List<String> args, {String? cwd}) async {
    final r = await Process.run('git', args, workingDirectory: cwd ?? repo.path);
    if (r.exitCode != 0) throw StateError('git ${args.join(' ')}: ${r.stderr}');
    return r.stdout as String;
  }

  void write(String rel, String content) {
    final f = File('${repo.path}/$rel');
    f.parent.createSync(recursive: true);
    f.writeAsStringSync(content);
  }

  setUp(() async {
    repo = Directory.systemTemp.createTempSync('clx_commitwin_');
    await git(['init', '-q', '-b', 'main']);
    await git(['config', 'user.name', 'T']);
    await git(['config', 'user.email', 't@x']);
    write('src/a.txt', 'one\ntwo\nthree\n');
    write('src/keep.txt', 'k\n');
    await git(['add', '.']);
    await git(['commit', '-q', '-m', 'init']);
  });
  tearDown(() => repo.deleteSync(recursive: true));

  group('GitService commit-window commands', () {
    test('stash push/list/files/diff/apply/pop/drop incl. untracked', () async {
      final g = GitService(repo.path);
      write('src/a.txt', 'one\nTWO\nthree\n');
      write('new.txt', 'fresh\n');
      expect((await g.call('git.stash_push', {'message': 'wip', 'include_untracked': true}))['status'], 'ok');
      expect(File('${repo.path}/new.txt').existsSync(), isFalse);
      expect(File('${repo.path}/src/a.txt').readAsStringSync(), 'one\ntwo\nthree\n');

      final list = (await g.call('git.stash_list'))['stashes'] as List;
      expect(list.single['ref'], 'stash@{0}');
      expect(list.single['message'], contains('wip'));

      final files = (await g.call('git.stash_files', {'ref': 'stash@{0}'}))['files'] as List;
      expect(files.map((f) => '${f['status']} ${f['path']}'), containsAll(['M src/a.txt', 'U new.txt']));
      final diff = await g.call('git.stash_file_diff', {'ref': 'stash@{0}', 'path': 'src/a.txt'});
      expect(diff['diff'], contains('+TWO'));
      final udiff = await g.call('git.stash_file_diff', {'ref': 'stash@{0}', 'path': 'new.txt'});
      expect(udiff['diff'], contains('fresh'));

      expect((await g.call('git.stash_apply', {'ref': 'stash@{0}'}))['status'], 'ok');
      expect(File('${repo.path}/new.txt').readAsStringSync(), 'fresh\n');
      expect(((await g.call('git.stash_list'))['stashes'] as List), hasLength(1), reason: 'apply keeps the stash');
      await git(['checkout', '--', '.']);
      File('${repo.path}/new.txt').deleteSync();

      expect((await g.call('git.stash_apply', {'ref': 'stash@{0}', 'pop': true}))['status'], 'ok');
      expect(((await g.call('git.stash_list'))['stashes'] as List), isEmpty, reason: 'pop drops it');

      await g.call('git.stash_push', {'message': 'again'});
      expect((await g.call('git.stash_drop', {'ref': 'stash@{0}'}))['status'], 'ok');
      expect(((await g.call('git.stash_list'))['stashes'] as List), isEmpty);
      expect((await g.call('git.stash_drop', {'ref': 'HEAD'}))['status'], 'error', reason: 'only stash@{n} refs');
    });

    test('rollback restores modified + staged files and deletes added ones', () async {
      final g = GitService(repo.path);
      write('src/a.txt', 'changed\n');
      write('src/keep.txt', 'staged change\n');
      await git(['add', 'src/keep.txt']);
      write('added.txt', 'brand new\n');
      await git(['add', 'added.txt']);

      final res = await g.call('git.rollback', {'paths': ['src/a.txt', 'src/keep.txt', 'added.txt']});
      expect(res['status'], 'ok');
      expect(File('${repo.path}/src/a.txt').readAsStringSync(), 'one\ntwo\nthree\n');
      expect(File('${repo.path}/src/keep.txt').readAsStringSync(), 'k\n');
      expect(File('${repo.path}/added.txt').existsSync(), isFalse);
      expect((await git(['status', '--porcelain'])).trim(), isEmpty);
    });

    test('amend rewrites HEAD; recent messages are deduplicated newest first', () async {
      final g = GitService(repo.path);
      write('src/a.txt', 'x\n');
      await g.stage('src/a.txt');
      await g.commit('second');
      expect((await g.commit('second, reworded', amend: true))['status'], 'ok');
      expect((await git(['log', '--format=%s'])).trim().split('\n'), ['second, reworded', 'init']);
      final msgs = (await g.call('git.recent_messages', {'limit': 5}))['messages'] as List;
      expect(msgs, ['second, reworded', 'init']);
    });

    test('repo_info reports the project prefix inside a larger repo', () async {
      final info = await GitService('${repo.path}/src').call('git.repo_info');
      expect(info['prefix'], 'src/');
      expect(File(info['toplevel'] as String).resolveSymbolicLinksSync(), repo.resolveSymbolicLinksSync());
    });
  });

  group('UI', () {
    testWidgets('DiffTab shows HEAD vs working copy side by side and jumps to source', (tester) async {
      write('src/a.txt', 'one\nTWO\nthree\nfour\n');
      final client = ApiClient(initialRoot: repo.path);
      String? openedPath;
      int? openedLine;
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: DiffTab(
              client: client,
              repoPath: 'src/a.txt',
              findOpenController: (_) => null,
              onOpenSource: (p, l) {
                openedPath = p;
                openedLine = l;
              },
            ),
          ),
        ));
        for (var i = 0; i < 40 && find.text('2 differences').evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });
      expect(find.text('2 differences'), findsOneWidget); // two→TWO 修改 + four 新增
      expect(find.text('Current version'), findsOneWidget);
      // 双击右侧新增的那一行 → 打开源文件对应行(0 起)。
      await tester.tap(find.byTooltip('下一处改动'));
      await tester.tap(find.byTooltip('下一处改动'));
      await tester.pump();
      await tester.tap(find.byTooltip('跳到源文件'));
      expect(openedPath, 'src/a.txt');
      expect(openedLine, 3);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(client.dispose);
    });

    // 「>>」把一段改动恢复成 HEAD:修改、纯新增、纯删除三种块,文件未打开时写回磁盘。
    testWidgets('DiffTab >> reverts modify / insert / delete blocks on disk', (tester) async {
      // HEAD: one two three ;  当前: ONE two three four ,再删掉 two
      write('src/a.txt', 'ONE\nthree\nfour\n');
      final client = ApiClient(initialRoot: repo.path);
      final arrows = find.byTooltip('恢复为 HEAD 版本');
      Future<void> settle() async {
        await tester.runAsync(() async {
          for (var i = 0; i < 20; i++) {
            await Future<void>.delayed(const Duration(milliseconds: 30));
            await tester.pump();
          }
        });
      }

      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: DiffTab(client: client, repoPath: 'src/a.txt', findOpenController: (_) => null, onOpenSource: (_, __) {}),
          ),
        ));
      });
      await settle();
      expect(arrows, findsNWidgets(2)); // ONE/one+two 合成一块修改(+删除),four 新增

      // 写盘是真 IO:点击放进 runAsync,否则 Future 卡在 FakeAsync 区里
      await tester.runAsync(() => tester.tap(arrows.first));
      await settle();
      expect(File('${repo.path}/src/a.txt').readAsStringSync(), 'one\ntwo\nthree\nfour\n');
      expect(arrows, findsOneWidget);

      // 写盘是真 IO:点击放进 runAsync,否则 Future 卡在 FakeAsync 区里
      await tester.runAsync(() => tester.tap(arrows.first));
      await settle();
      expect(File('${repo.path}/src/a.txt').readAsStringSync(), 'one\ntwo\nthree\n');
      expect(find.text('没有差异'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(client.dispose);
    });

    testWidgets('DiffTab >> on an open file edits the buffer (undoable) and saves it', (tester) async {
      write('src/a.txt', 'one\nTWO\nthree\n');
      final client = ApiClient(initialRoot: repo.path);
      final ctrl = CodeEditorController(initialText: 'one\nTWO\nthree\n');
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: DiffTab(
              client: client,
              repoPath: 'src/a.txt',
              findOpenController: (p) => p == 'src/a.txt' ? ctrl : null,
              onOpenSource: (_, __) {},
            ),
          ),
        ));
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await tester.pump();
        }
      });
      final saved = <String>[];
      late StreamSubscription<String> sub;
      await tester.runAsync(() async {
        sub = client.onFileSaved.listen(saved.add);
        await tester.tap(find.byTooltip('恢复为 HEAD 版本'));
        for (var i = 0; i < 20; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 30));
          await tester.pump();
        }
      });
      expect(ctrl.text, 'one\ntwo\nthree\n');
      expect(File('${repo.path}/src/a.txt').readAsStringSync(), 'one\ntwo\nthree\n', reason: '与 IntelliJ 一样直接存盘');
      expect(ctrl.isDirty, isFalse);
      expect(saved, ['src/a.txt']);
      expect(ctrl.undo(), isTrue);
      expect(ctrl.text, 'one\nTWO\nthree\n');
      expect(ctrl.isDirty, isTrue, reason: '撤销后与磁盘不一致');
      await tester.runAsync(sub.cancel);
      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
      await tester.runAsync(client.dispose);
    });

    testWidgets('DiffTab: an untracked new file has an empty left side', (tester) async {
      write('brand_new.txt', 'a\nb\n');
      final client = ApiClient(initialRoot: repo.path);
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: DiffTab(client: client, repoPath: 'brand_new.txt', findOpenController: (_) => null, onOpenSource: (_, __) {}),
          ),
        ));
        for (var i = 0; i < 40 && find.text('1 difference').evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });
      expect(find.text('1 difference'), findsOneWidget);
      expect(find.textContaining('新文件'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(client.dispose);
    });

    testWidgets('CommitPanel lists changes, opens a diff on click, switches to Stash', (tester) async {
      write('src/a.txt', 'changed\n');
      write('untracked.md', 'u\n');
      final client = ApiClient(initialRoot: repo.path);
      final opened = <String>[];
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: CommitPanel(
              client: client,
              onOpenDiff: opened.add,
              onOpenFile: (_) {},
              onCommitted: () {},
            ),
          ),
        ));
        for (var i = 0; i < 40 && find.text('Unversioned Files', findRichText: true).evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });
      expect(find.textContaining('Changes', findRichText: true), findsWidgets);
      expect(find.textContaining('Unversioned Files', findRichText: true), findsOneWidget);
      expect(find.textContaining('a.txt', findRichText: true), findsOneWidget);

      await tester.tap(find.textContaining('a.txt', findRichText: true));
      await tester.pump();
      expect(opened, ['src/a.txt']);

      await tester.tap(find.text('Stash'));
      await tester.runAsync(() async {
        for (var i = 0; i < 40 && find.text('没有 stash').evaluate().isEmpty; i++) {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          await tester.pump();
        }
      });
      expect(find.text('没有 stash'), findsOneWidget);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(client.dispose);
    });

    testWidgets('CommitPanel drops a file once it is saved back to the HEAD content', (tester) async {
      write('src/a.txt', 'changed\n');
      final client = ApiClient(initialRoot: repo.path);
      await tester.binding.setSurfaceSize(const Size(400, 700));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      Future<void> settle(bool Function() done) async {
        await tester.runAsync(() async {
          for (var i = 0; i < 60 && !done(); i++) {
            await Future<void>.delayed(const Duration(milliseconds: 50));
            await tester.pump();
          }
        });
      }

      await tester.runAsync(() async {
        await tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: CommitPanel(client: client, onOpenDiff: (_) {}, onOpenFile: (_) {}, onCommitted: () {}),
          ),
        ));
      });
      final a = find.textContaining('a.txt', findRichText: true);
      await settle(() => a.evaluate().isNotEmpty);
      expect(a, findsOneWidget);

      // 编辑器保存 / 「>>」恢复都走 saveFile:内容回到 HEAD 后文件应自动从 Changes 消失。
      await tester.runAsync(() => client.saveFile('src/a.txt', 'one\ntwo\nthree\n'));
      await settle(() => a.evaluate().isEmpty);
      expect(a, findsNothing);
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(client.dispose);
    });
  });
}
