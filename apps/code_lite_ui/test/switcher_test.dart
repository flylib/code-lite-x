import 'package:code_lite_ui/core/keymap/keymap.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/search/recent_files_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Switcher(⌃⇥,同 IntelliJ):按住 Ctrl,Tab 往下选、⇧Tab 往上(绕回),松开 Ctrl 打开选中的;
/// 按住 Ctrl 按助记键打开工具窗;⌃⇥ 按一下就松开 = 回到上一个文件。
void main() {
  test('the default shortcut is Ctrl+Tab (and Ctrl+Shift+Tab) on every platform', () {
    final a = keymapActionById(KeymapIds.switcher)!;
    expect(a.mac, ['ctrl TAB', 'ctrl shift TAB']);
    expect(a.other, ['ctrl TAB', 'ctrl shift TAB']);
  });

  const files = [
    RecentFileItem(path: '/p/A.java', name: 'A.java', directory: '~/p'),
    RecentFileItem(path: '/p/B.java', name: 'B.java', directory: '~/p'),
    RecentFileItem(path: '/p/C.java', name: 'C.java', directory: '~/p/c'),
  ];
  final tools = [
    RecentToolItem(id: KeymapIds.project, label: 'Project', icon: (c, s) => Icon(Icons.folder, color: c, size: s), mnemonic: '1'),
    RecentToolItem(id: KeymapIds.git, label: 'Git', icon: (c, s) => Icon(Icons.commit, color: c, size: s), mnemonic: '9'),
  ];

  /// 弹出 Switcher(调用前要不要按住 Ctrl 由测试决定);返回的函数取结果。
  Future<RecentFilesChoice? Function()> open(WidgetTester tester, {bool reverse = false}) async {
    RecentFilesChoice? chosen;
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Builder(
          builder: (context) => TextButton(
            onPressed: () async => chosen = await showSwitcherDialog(context, files: files, tools: tools, currentFile: '/p/A.java', reverse: reverse),
            child: const Text('open'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pump();
    await tester.pump();
    return () => chosen;
  }

  Future<void> releaseCtrl(WidgetTester tester) async {
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pumpAndSettle();
  }

  testWidgets('holding Ctrl: Tab moves down and wraps, Shift+Tab moves up; releasing Ctrl opens the selection', (tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    final chosen = await open(tester);
    expect(find.text('切换器'), findsOneWidget);
    expect(find.text('1'), findsOneWidget, reason: '工具窗前面是助记键');
    expect(find.byKey(const ValueKey('recent-files-edited-only')), findsNothing);
    expect(tester.widget<Text>(find.byKey(const ValueKey('recent-files-location'))).data, '~/p', reason: '一开始选中上一个文件 B');

    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // → C
    await tester.pump();
    expect(tester.widget<Text>(find.byKey(const ValueKey('recent-files-location'))).data, '~/p/c');
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // 绕回 → A
    await tester.sendKeyDownEvent(LogicalKeyboardKey.shiftLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab); // ⇧Tab 绕回 → C
    await tester.sendKeyUpEvent(LogicalKeyboardKey.shiftLeft);
    await tester.pump();
    expect(find.text('切换器'), findsOneWidget, reason: '还按着 Ctrl,不关');

    await releaseCtrl(tester);
    expect(find.text('切换器'), findsNothing);
    expect(chosen()?.file, '/p/C.java');
  });

  testWidgets('Ctrl+Tab tapped and released at once goes straight back to the previous file', (tester) async {
    final chosen = await open(tester); // 弹出时 Ctrl 已经松开了
    await tester.pumpAndSettle();
    expect(find.text('切换器'), findsNothing);
    expect(chosen()?.file, '/p/B.java');
  });

  testWidgets('Ctrl+Shift+Tab starts from the last file; a mnemonic opens its tool window', (tester) async {
    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    var chosen = await open(tester, reverse: true);
    expect(tester.widget<Text>(find.byKey(const ValueKey('recent-files-location'))).data, '~/p/c');
    await tester.sendKeyEvent(LogicalKeyboardKey.digit9);
    await tester.pumpAndSettle();
    expect(chosen()?.tool, KeymapIds.git);
    await releaseCtrl(tester); // 已经关了,松开 Ctrl 不能再关掉下面的页面
    expect(find.text('open'), findsOneWidget);

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    chosen = await open(tester);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(chosen(), isNull);
    await releaseCtrl(tester);
    expect(find.text('open'), findsOneWidget);
  });

  testWidgets('Ctrl+Tab in the editor is not a tab: it reaches the app shortcut', (tester) async {
    final ctrl = CodeEditorController(initialText: 'ab\n');
    var switched = 0;
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: CallbackShortcuts(
          bindings: {const SingleActivator(LogicalKeyboardKey.tab, control: true): () => switched++},
          child: EditorViewWidget(
            openTabs: const ['notes.txt'],
            activeFile: 'notes.txt',
            codeContent: ctrl.text,
            controller: ctrl,
            onSelectTab: (_) {},
            onCloseTab: (_) {},
            onCodeChanged: (_) {},
          ),
        ),
      ),
    ));
    await tester.tap(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'ab'));
    await tester.pump();

    await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
    await tester.pump();
    expect(ctrl.text, 'ab\n');
    expect(switched, 1);

    await tester.sendKeyEvent(LogicalKeyboardKey.tab);
    await tester.pump();
    expect(ctrl.text, isNot('ab\n'), reason: '不按 Ctrl 的 Tab 照常缩进');

    await tester.pump(const Duration(seconds: 1));
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}
