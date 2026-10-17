import 'dart:async';

import 'package:code_lite_ui/core/build_tools/makefile.dart';
import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/make/make_panel.dart';
import 'package:code_lite_ui/features/make/make_store.dart';
import 'package:code_lite_ui/features/settings/settings_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// bcpoker_proto 的 Makefile 的样子(截图里那份)。
const _proto = '''.PHONY: sync-worker-go

mq-go:
\t@protoc --proto_path=.  --go_out=. roomgameserver.proto model.proto mq.proto

.PHONY: service-wallet-go
service-wallet-go:
\t@protoc --proto_path=.  --go_out=. --go-grpc_out=. wallet.proto common.proto

.PHONY: java-all
java-all: java-client java-chat java-ext

.PHONY: java-client
java-client:
\t@protoc --proto_path=. --proto_path=./client  --java_out=./javaproto/src/main/java a.proto
''';

void main() {
  group('parse', () {
    test('targets of the bcpoker_proto Makefile, on the lines IntelliJ shows ▶', () {
      final t = parseMakeTargets(_proto);
      expect(t.map((x) => '${x.name}@${x.line + 1}'), [
        '.PHONY@1',
        'mq-go@3',
        'service-wallet-go@7',
        'java-all@11',
        'java-client@14',
      ]);
      expect(t.first.special, isTrue);
      expect(t[1].special, isFalse);
    });

    test('assignments, recipes, patterns, variables, define blocks and continuations are not targets', () {
      const src = '''
CC := gcc
CFLAGS ?= -O2
URL = http://x:8080/a
X ::= 1
target-specific: CFLAGS += -g
%.o: %.c
\t\$(CC) -c \$<
\$(BIN): main.o
\techo "fake: rule"
define TEMPLATE
inside: not-a-target
endef
build test \\
  lint: deps
install:: build
ifeq (\$(OS),Darwin)
mac-only: ; echo mac
endif
weird: \$(subst a:b,c,d)
# comment: no
build: again
''';
      expect(parseMakeTargets(src).map((t) => t.name), [
        'target-specific', 'build', 'test', 'lint', 'install', 'mac-only', 'weird',
      ]);
      expect(parseMakeTargets(src).firstWhere((t) => t.name == 'lint').line, 12, reason: '续行算第一行');
    });

    test('file names and command lines', () {
      expect(isMakefileName('Makefile'), isTrue);
      expect(isMakefileName('sub/dir/GNUmakefile'), isTrue);
      expect(isMakefileName('rules.mk'), isTrue);
      expect(isMakefileName('Makefile.txt'), isFalse);
      expect(makeCommandLine('', 'Makefile', 'java-all'), 'make java-all');
      expect(makeCommandLine('', 'proto/Makefile', 'gen'), 'make -C proto gen');
      expect(makeCommandLine('/opt/homebrew/bin/gmake', 'build/rules.mk', 'x'), '/opt/homebrew/bin/gmake -C build -f rules.mk x');
      expect(makeCommandLine('/Applications/My Tools/make', 'Makefile', 'a b'), "'/Applications/My Tools/make' 'a b'");
    });
  });

  group('store', () {
    late Map<String, String> files;
    late List<String>? listed;
    late List<(String, String)> ran;
    late String makePath;
    late StreamController<String> saved;

    MakeStore make() => MakeStore(
          projectRoot: () => '/p',
          read: (path) async => files[path],
          listMakefiles: () async => listed,
          runner: (title, cmd) => ran.add((title, cmd)),
          makePath: () => makePath,
          fileSaved: saved.stream,
        );

    setUp(() {
      files = {'Makefile': _proto, 'sub/Makefile': 'gen:\n\techo\n', 'notes.txt': 'x'};
      listed = ['sub/Makefile', 'Makefile'];
      ran = [];
      makePath = '';
      saved = StreamController<String>.broadcast();
    });
    tearDown(() => saved.close());

    test('finds the Makefiles (root first), hides special targets, runs with the configured make', () async {
      final s = make();
      await s.reload();
      expect(s.files.map((f) => f.path), ['Makefile', 'sub/Makefile']);
      expect(s.hasMakefiles, isTrue);
      expect(s.isExpanded('Makefile'), isTrue, reason: '第一个默认展开');
      expect(s.visibleTargets(s.files.first).map((t) => t.name), ['mq-go', 'service-wallet-go', 'java-all', 'java-client']);
      s.toggleShowSpecial();
      expect(s.visibleTargets(s.files.first).first.name, '.PHONY');
      s.toggleSortByName();
      expect(s.visibleTargets(s.files.first).map((t) => t.name).take(3), ['.PHONY', 'java-all', 'java-client']);

      s.run('Makefile', 'java-all');
      makePath = '/opt/homebrew/bin/gmake';
      s.run('sub/Makefile', 'gen');
      s.runTarget('/p/Makefile', 'mq-go'); // 行号栏的 ▶,绝对路径
      expect(ran, [
        ('make java-all', 'make java-all'),
        ('make gen', '/opt/homebrew/bin/gmake -C sub gen'),
        ('make mq-go', '/opt/homebrew/bin/gmake mq-go'),
      ]);
      expect(s.runSelected(), isFalse);
      s.select('Makefile', 'java-client');
      expect(s.runSelected(), isTrue);
      expect(ran.last.$2, '/opt/homebrew/bin/gmake java-client');
      s.dispose();
    });

    test('file list not ready yet: the root Makefile first; saving a Makefile re-reads it', () async {
      listed = null;
      final s = make();
      await s.reload();
      expect(s.files.map((f) => f.path), ['Makefile']);
      files['Makefile'] = 'only:\n';
      listed = ['Makefile'];
      saved.add('Makefile');
      await Future<void>.delayed(const Duration(milliseconds: 20));
      expect(s.files.single.targets.single.name, 'only');
      saved.add('notes.txt'); // 不是 Makefile:不重读
      s.dispose();
    });
  });

  testWidgets('panel: Makefile node with its targets; double-click runs; toolbar run / sort / settings', (tester) async {
    final ran = <String>[];
    var settingsOpened = 0;
    final opened = <(String, int)>[];
    final s = MakeStore(
      projectRoot: () => '/p',
      read: (path) async => path == 'Makefile' ? _proto : null,
      listMakefiles: () async => ['Makefile'],
      runner: (title, cmd) => ran.add(cmd),
      makePath: () => '',
    );
    await tester.runAsync(s.reload);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 320,
          child: MakePanel(store: s, onOpenFileAt: (p, l) => opened.add((p, l)), onOpenSettings: () => settingsOpened++),
        ),
      ),
    ));
    expect(find.text('make'), findsOneWidget);
    expect(find.text('Makefile'), findsOneWidget);
    expect(find.text('java-all'), findsOneWidget);
    expect(find.text('.PHONY'), findsNothing, reason: '特殊目标默认不显示');

    // 双击运行
    await tester.tap(find.text('java-all'));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tap(find.text('java-all'));
    await tester.pump();
    expect(ran, ['make java-all']);

    // 选中后工具栏 ▶
    await tester.tap(find.text('mq-go'));
    await tester.pump(const Duration(milliseconds: 500));
    await tester.tap(find.byKey(const ValueKey('make-run')));
    await tester.pump();
    expect(ran.last, 'make mq-go');

    // 右键 ▸ 跳到定义
    await tester.tap(find.text('java-client'), buttons: kSecondaryButton);
    await tester.pumpAndSettle();
    await tester.tap(find.text('跳到定义'));
    await tester.pumpAndSettle();
    expect(opened, [('Makefile', 13)]);

    await tester.tap(find.byKey(const ValueKey('make-special')));
    await tester.pump();
    expect(find.text('.PHONY'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('make-settings')));
    expect(settingsOpened, 1);
    s.dispose();
  });

  testWidgets('editor: a ▶ on each target line of a Makefile runs it', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ctrl = CodeEditorController(initialText: _proto);
    final ran = <(String, String)>[];
    Future<void> show(String file) => tester.pumpWidget(MaterialApp(
          home: Scaffold(
            body: EditorViewWidget(
              openTabs: [file],
              activeFile: file,
              codeContent: '',
              controller: ctrl,
              appearance: EditorAppearance(),
              onSelectTab: (_) {},
              onCloseTab: (_) {},
              onRunMakeTarget: (path, target) => ran.add((path, target)),
            ),
          ),
        ));
    await show('Makefile');
    expect(find.byKey(const ValueKey('make-run-java-all')), findsOneWidget);
    expect(find.byKey(const ValueKey('make-run-mq-go')), findsOneWidget);
    expect(find.byKey(const ValueKey('make-run-.PHONY')), findsNothing);
    // ▶ 和行号「11」在同一行
    expect(
      tester.getCenter(find.byKey(const ValueKey('make-run-java-all'))).dy,
      closeTo(tester.getCenter(find.text('11')).dy, 2),
    );
    await tester.tap(find.byKey(const ValueKey('make-run-java-all')));
    expect(ran, [('Makefile', 'java-all')]);

    // 不是 Makefile 就没有
    await show('notes.txt');
    expect(find.byKey(const ValueKey('make-run-java-all')), findsNothing);
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });

  testWidgets('settings: Build Tools ▸ Make path is saved', (tester) async {
    final client = ApiClient(initialRoot: '.');
    final sessions = EditorSessionManager(client: client);
    final saved = <Map<String, dynamic>>[];
    final settings = SettingsStore(sessions: sessions, load: () async => {'buildTools': {'makePath': '/usr/bin/make'}}, save: (j) async => saved.add(j));
    await tester.runAsync(settings.load);
    expect(settings.makePath, '/usr/bin/make');
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsDialog(settings: settings, openBuildTools: true))));
    expect(find.text('make 可执行文件'), findsOneWidget);
    await tester.enterText(find.byKey(const ValueKey('make-path-field')), '/opt/homebrew/bin/gmake');
    expect(settings.makePath, '/opt/homebrew/bin/gmake');
    expect(saved.last['buildTools'], {'makePath': '/opt/homebrew/bin/gmake'});
    await tester.enterText(find.byKey(const ValueKey('make-path-field')), '');
    expect(saved.last.containsKey('buildTools'), isFalse, reason: '空 = 用 PATH 里的 make,不存');
    await tester.pumpWidget(const SizedBox());
    settings.dispose();
    sessions.dispose();
    await tester.runAsync(client.dispose);
  });
}
