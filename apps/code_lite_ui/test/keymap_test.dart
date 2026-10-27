import 'dart:io';

import 'package:code_lite_ui/app.dart';
import 'package:code_lite_ui/core/keymap/intellij_keymap_io.dart';
import 'package:code_lite_ui/core/keymap/keymap.dart';
import 'package:code_lite_ui/core/state/layout_store.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/project_explorer/project_explorer_widget.dart';
import 'package:code_lite_ui/features/project_explorer/structure_widget.dart';
import 'package:code_lite_ui/features/settings/keymap_page.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 快捷键:默认键位同 IntelliJ,可以改、可以从本机 IntelliJ 的配置导入。先做打开 / 收起工具窗。
void main() {
  group('keystroke', () {
    test('IntelliJ text round-trips; labels per platform', () {
      final k = KeyStroke.parse('shift meta F12')!;
      expect(k, const KeyStroke('F12', meta: true, shift: true));
      expect(k.text, 'shift meta F12');
      expect(k.label(mac: true), '⇧⌘F12');
      expect(k.label(mac: false), 'Shift+Meta+F12');
      expect(KeyStroke.parse('control shift F12'), const KeyStroke('F12', ctrl: true, shift: true));
      expect(KeyStroke.parse('meta 1')!.label(mac: true), '⌘1');
      expect(KeyStroke.parse('alt F12')!.label(mac: true), '⌥F12');
      expect(KeyStroke.parse('alt 1')!.label(mac: false), 'Alt+1');
      expect(KeyStroke.parse('meta BACK_QUOTE')!.label(mac: true), '⌘`');
      expect(KeyStroke.parse('meta shift NOT_A_KEY'), isNull);
      expect(KeyStroke.parse('altGraph A'), isNull);
      final a = KeyStroke.parse('meta 1')!.activator as SingleActivator;
      expect((a.trigger, a.meta, a.control, a.alt, a.shift), (LogicalKeyboardKey.digit1, true, false, false, false));
    });
  });

  group('store', () {
    test('macOS defaults are IntelliJ\'s (⌘1 project, ⌘0 commit, ⌘7 structure, ⌘9 git, ⌥F12 terminal, ⇧⌘F12 hide all)', () {
      final k = KeymapStore(mac: true);
      expect({for (final a in keymapActions) a.id: k.labelOf(a.id)}, {
        KeymapIds.project: '⌘1',
        KeymapIds.commit: '⌘0',
        KeymapIds.pullRequests: null,
        KeymapIds.structure: '⌘7',
        KeymapIds.openProjects: null,
        KeymapIds.build: null,
        KeymapIds.terminal: '⌥F12',
        KeymapIds.git: '⌘9',
        KeymapIds.hideAll: '⇧⌘F12',
        KeymapIds.make: null,
        KeymapIds.gotoFile: '⇧⌘O',
        KeymapIds.collapseRegion: '⌘-',
        KeymapIds.expandRegion: '⌘=',
        KeymapIds.collapseAll: '⇧⌘-',
        KeymapIds.expandAll: '⇧⌘=',
        KeymapIds.duplicate: '⌘D',
        KeymapIds.find: '⌘F',
        KeymapIds.findNext: '⌘G',
        KeymapIds.findPrevious: '⇧⌘G',
        KeymapIds.rename: '⇧F6',
        KeymapIds.problems: '⌘6',
      });
      expect(KeymapStore(mac: false).labelOf(KeymapIds.rename), 'Shift+F6');
      expect(keymapActionById(KeymapIds.rename)!.group, '重构');
      expect(KeymapStore(mac: false).labelOf(KeymapIds.find), 'Ctrl+F');
      expect(KeymapStore(mac: false).labelOf(KeymapIds.findNext), 'F3');
      for (final id in [KeymapIds.find, KeymapIds.findNext, KeymapIds.findPrevious]) {
        expect(keymapActionById(id)!.group, '编辑');
      }
      expect(KeymapStore(mac: false).labelOf(KeymapIds.duplicate), 'Ctrl+D');
      expect(keymapActionById(KeymapIds.duplicate)!.group, '编辑');
      expect(KeymapStore(mac: false).labelOf(KeymapIds.collapseRegion), 'Ctrl+-');
      expect(KeymapStore(mac: false).labelOf(KeymapIds.gotoFile), 'Ctrl+Shift+N');
      expect(KeymapStore(mac: false).labelOf(KeymapIds.project), 'Alt+1');
    });

    test('add / remove / reset; a shortcut moves away from the action that had it; only changes are stored', () {
      final k = KeymapStore(mac: true);
      final cmd2 = KeyStroke.parse('meta 2')!;
      k.add(KeymapIds.openProjects, cmd2);
      expect(k.labelOf(KeymapIds.openProjects), '⌘2');
      expect(k.isCustomized(KeymapIds.openProjects), isTrue);

      // ⌘1 给 Opening Projects:项目那边就没有 ⌘1 了
      k.add(KeymapIds.openProjects, KeyStroke.parse('meta 1')!);
      expect(k.shortcutsOf(KeymapIds.project), isEmpty);
      expect(k.actionUsing(KeyStroke.parse('meta 1')!), KeymapIds.openProjects);

      k.remove(KeymapIds.openProjects, cmd2);
      expect(k.labelOf(KeymapIds.openProjects), '⌘1');
      k.reset(KeymapIds.project);
      expect(k.labelOf(KeymapIds.project), '⌘1');
      expect(k.isCustomized(KeymapIds.project), isFalse);

      // 改回和默认一样:不算改过
      k.remove(KeymapIds.structure, KeyStroke.parse('meta 7')!);
      k.add(KeymapIds.structure, KeyStroke.parse('meta 7')!);
      expect(k.isCustomized(KeymapIds.structure), isFalse);

      final json = k.toJson();
      expect(json['overrides'], {
        KeymapIds.openProjects: ['meta 1'],
      });
      final again = KeymapStore(mac: true)..applyJson(json);
      expect(again.labelOf(KeymapIds.openProjects), '⌘1');
      expect(again.labelOf(KeymapIds.project), '⌘1', reason: 'project 被 reset 过,用默认');
      k.resetAll();
      expect(k.toJson()['overrides'], isEmpty);
    });

    test('saved with the settings file; old settings without a keymap still load', () async {
      final saved = <Map<String, dynamic>>[];
      final keymap = KeymapStore(mac: true);
      final settings = SettingsStore(
        appearance: EditorAppearance(),
        layout: LayoutStore(),
        keymap: keymap,
        load: () async => {
          'keymap': {
            'overrides': {KeymapIds.terminal: ['meta T'], 'NoSuchAction': ['meta Q']},
          },
        },
        save: (j) async => saved.add(j),
      );
      await settings.load();
      expect(keymap.labelOf(KeymapIds.terminal), '⌘T');
      keymap.add(KeymapIds.git, KeyStroke.parse('shift meta K')!);
      expect((saved.last['keymap'] as Map)['overrides'], {KeymapIds.terminal: ['meta T'], KeymapIds.git: ['meta 9', 'shift meta K']});
      settings.dispose();
    });
  });

  group('IntelliJ', () {
    const user = '''
<keymap version="1" name="macOS copy" parent="Mac OS X 10.5+">
  <action id="ActivateProjectToolWindow">
    <keyboard-shortcut first-keystroke="shift meta 1" />
  </action>
  <action id="ActivateStructureToolWindow" />
  <action id="Git.Pull">
    <keyboard-shortcut first-keystroke="meta p" />
  </action>
</keymap>''';
    const mac = '''
<keymap name="Mac OS X 10.5+" parent="\$default" version="1" disable-mnemonics="true">
  <action id="ActivateProjectToolWindow"><keyboard-shortcut first-keystroke="meta 1"/></action>
  <action id="ActivateCommitToolWindow"><keyboard-shortcut first-keystroke="meta 0"/></action>
  <action id="ActivateStructureToolWindow"><keyboard-shortcut first-keystroke="meta 7"/></action>
  <action id="ActivateVersionControlToolWindow"><keyboard-shortcut first-keystroke="meta 9"/></action>
</keymap>''';
    const def = '''
<keymap name="\$default" version="1">
  <action id="ActivateTerminalToolWindow"><keyboard-shortcut first-keystroke="alt F12"/></action>
  <action id="HideAllWindows"><keyboard-shortcut first-keystroke="control shift F12"/></action>
  <action id="ActivatePull RequestsToolWindow"><keyboard-shortcut first-keystroke="control shift P" second-keystroke="R"/></action>
</keymap>''';

    Map<String, IntelliJKeymapFile> files(List<String> xmls) => {
          for (final x in xmls)
            if (IntelliJKeymapFile.parse(x) case final f?) f.name: f,
        };

    test('walks the parent chain: the user\'s own changes win, \$default Ctrl becomes ⌘ on macOS, two-stroke shortcuts are skipped', () {
      final r = resolveIntelliJKeymap('macOS copy', files([user, mac, def]));
      expect(r[KeymapIds.project], ['shift meta 1'], reason: '用户改过');
      expect(r[KeymapIds.structure], isEmpty, reason: '用户去掉了');
      expect(r[KeymapIds.commit], ['meta 0']);
      expect(r[KeymapIds.git], ['meta 9']);
      expect(r[KeymapIds.terminal], ['alt F12']);
      expect(r[KeymapIds.hideAll], ['meta shift F12'], reason: '继承 \$default 的 Ctrl 在 macOS 键位里是 ⌘');
      expect(r[KeymapIds.pullRequests], isEmpty, reason: '两段式快捷键不支持');
      expect(r.containsKey(KeymapIds.openProjects), isFalse, reason: 'CodeLiteX 自己的操作,导入不动它');

      final k = KeymapStore(mac: true)..applyIntelliJ('macOS copy', r);
      expect(k.labelOf(KeymapIds.project), '⇧⌘1');
      expect(k.labelOf(KeymapIds.structure), isNull);
      expect(k.labelOf(KeymapIds.hideAll), '⇧⌘F12');
      expect(k.importedFrom, 'macOS copy');
      expect(k.isCustomized(KeymapIds.commit), isFalse, reason: '和默认一样');
    });

    test('built-in keymaps missing (no IntelliJ app): only the user\'s own changes are imported', () {
      final r = resolveIntelliJKeymap('macOS copy', files([user]));
      expect(r, {KeymapIds.project: ['shift meta 1'], KeymapIds.structure: <String>[]});
    });

    test('reads the newest IntelliJ config folder and its active keymap from disk', () async {
      final home = Directory.systemTemp.createTempSync('clx_home_');
      addTearDown(() => home.deleteSync(recursive: true));
      final base = '${home.path}/Library/Application Support/JetBrains';
      for (final v in ['IntelliJIdea2023.3', 'IntelliJIdea2025.3', 'GoLand2026.2']) {
        Directory('$base/$v/keymaps').createSync(recursive: true);
      }
      File('$base/IntelliJIdea2025.3/keymaps/macOS copy.xml').writeAsStringSync(user);
      Directory('$base/IntelliJIdea2025.3/options/mac').createSync(recursive: true);
      File('$base/IntelliJIdea2025.3/options/mac/keymap.xml')
          .writeAsStringSync('<application><component name="KeymapManager"><active_keymap name="macOS copy" /></component></application>');
      File('$base/IntelliJIdea2023.3/keymaps/old.xml').writeAsStringSync(user.replaceAll('shift meta 1', 'meta 8'));

      final r = await readIntelliJKeymap(home: home.path, appDirs: const []);
      expect(r, isNotNull);
      expect(r!.name, 'macOS copy');
      expect(r.source, 'IntelliJIdea2025.3');
      expect(r.shortcuts[KeymapIds.project], ['shift meta 1']);
      expect(await readIntelliJKeymap(home: '${home.path}/nobody', appDirs: const []), isNull);
    }, skip: !Platform.isMacOS);
  });

  group('ui', () {
    testWidgets('settings page: import from IntelliJ, add a shortcut by pressing it (conflicts move), remove one, reset', (tester) async {
      final keymap = KeymapStore(mac: true);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: KeymapPage(
              keymap: keymap,
              readIntelliJ: () async => (name: 'macOS copy', shortcuts: {KeymapIds.project: ['shift meta 1']}, source: 'IntelliJIdea2025.3'),
            ),
          ),
        ),
      ));
      expect(find.text('⌘1'), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('keymap-import')));
      await tester.pumpAndSettle();
      expect(find.text('⇧⌘1'), findsOneWidget);
      expect(find.textContaining('已从 IntelliJIdea2025.3 导入「macOS copy」'), findsOneWidget);

      // Opening Projects:按 ⌘7(结构在用)
      await tester.tap(find.byKey(const ValueKey('keymap-add-${KeymapIds.openProjects}')));
      await tester.pumpAndSettle();
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.digit7);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.digit7);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      expect(find.descendant(of: find.byKey(const ValueKey('keymap-recorded')), matching: find.text('⌘7')), findsOneWidget);
      expect(find.textContaining('已用于「结构」'), findsOneWidget);
      await tester.tap(find.text('确定'));
      await tester.pumpAndSettle();
      expect(keymap.labelOf(KeymapIds.openProjects), '⌘7');
      expect(keymap.labelOf(KeymapIds.structure), isNull);

      // 去掉一个、恢复默认
      await tester.tap(find.byTooltip('去掉 ⇧⌘1'));
      await tester.pump();
      expect(keymap.shortcutsOf(KeymapIds.project), isEmpty);
      await tester.tap(find.descendant(of: find.byKey(const ValueKey('keymap-row-${KeymapIds.project}')), matching: find.byTooltip('恢复默认')));
      await tester.pump();
      expect(keymap.labelOf(KeymapIds.project), '⌘1');

      // 录制时单按 Esc 取消
      await tester.tap(find.byKey(const ValueKey('keymap-add-${KeymapIds.git}')));
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('keymap-recorded')), findsNothing);
      expect(keymap.labelOf(KeymapIds.git), '⌘9');
    });

    testWidgets('in the app the default keys open / close tool windows; Hide All hides everything and brings it back', (tester) async {
      tester.view.physicalSize = const Size(1280, 800);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      await tester.pumpWidget(const CodeLiteApp());
      await tester.pump();
      // 测试环境不是 macOS:用 IntelliJ 的 Default 键位(Alt+1 / Alt+7 / Alt+F12 / Ctrl+Shift+F12)
      Future<void> press(List<LogicalKeyboardKey> mods, LogicalKeyboardKey key) async {
        for (final m in mods) {
          await tester.sendKeyDownEvent(m);
        }
        await tester.sendKeyEvent(key);
        for (final m in mods.reversed) {
          await tester.sendKeyUpEvent(m);
        }
        await tester.pump();
      }

      expect(find.byType(ProjectExplorerWidget), findsOneWidget);
      await press([LogicalKeyboardKey.altLeft], LogicalKeyboardKey.digit1);
      expect(find.byType(ProjectExplorerWidget), findsNothing, reason: '再按一次收起(同 IntelliJ)');
      await press([LogicalKeyboardKey.altLeft], LogicalKeyboardKey.digit1);
      expect(find.byType(ProjectExplorerWidget), findsOneWidget);

      await press([LogicalKeyboardKey.altLeft], LogicalKeyboardKey.digit7);
      expect(find.byType(StructureWidget), findsOneWidget);
      await press([LogicalKeyboardKey.altLeft], LogicalKeyboardKey.f12);
      expect(find.text('Terminal'), findsOneWidget);

      await press([LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.f12);
      expect(find.byType(StructureWidget), findsNothing);
      expect(find.text('Terminal'), findsNothing);
      await press([LogicalKeyboardKey.controlLeft, LogicalKeyboardKey.shiftLeft], LogicalKeyboardKey.f12);
      expect(find.byType(StructureWidget), findsOneWidget, reason: '再按一次恢复刚才开着的');
      expect(find.text('Terminal'), findsOneWidget);
      expect(find.byTooltip('结构 (Alt+7)'), findsOneWidget, reason: '按钮提示显示当前快捷键');
    });
  });
}
