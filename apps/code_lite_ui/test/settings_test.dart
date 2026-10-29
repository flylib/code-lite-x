import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:code_lite_ui/features/settings/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设置:自动保存开关 / 延迟、编辑器外观,读写 settings.json(这里用内存代替)。
void main() {
  late ApiClient client;
  late EditorSessionManager sessions;
  late List<Map<String, dynamic>> written;

  SettingsStore store({Map<String, dynamic> initial = const {}}) => SettingsStore(
        sessions: sessions,
        load: () async => initial,
        save: (j) async => written.add(j),
      );

  setUp(() {
    client = ApiClient(initialRoot: '.');
    sessions = EditorSessionManager(client: client);
    written = [];
  });

  tearDown(() async {
    sessions.dispose();
    await client.dispose();
  });

  test('loads saved values into the session manager and appearance', () async {
    final s = store(initial: {
      'editor': {
        'autosave': false,
        'autosaveDelayMs': 2000,
        'appearance': {'lineNumbers': false, 'breadcrumbs': false, 'blameColors': 'age'},
      },
    });
    await s.load();
    expect(sessions.autosave, isFalse);
    expect(sessions.autosaveDelay, const Duration(seconds: 2));
    expect(sessions.appearance.showLineNumbers, isFalse);
    expect(sessions.appearance.showBreadcrumbs, isFalse);
    expect(sessions.appearance.showIndentGuides, isTrue, reason: '没写的项保持默认');
    expect(written, isEmpty, reason: '读入时不回写');
    s.dispose();
  });

  test('changes are written back, including gutter-menu appearance toggles', () async {
    final s = store();
    await s.load();
    s.setAutosave(false);
    expect((written.last['editor'] as Map)['autosave'], isFalse);
    s.setAutosaveDelay(const Duration(seconds: 1));
    expect((written.last['editor'] as Map)['autosaveDelayMs'], 1000);
    sessions.appearance.toggleIndentGuides(); // 行号栏右键菜单改的也要落盘
    expect(((written.last['editor'] as Map)['appearance'] as Map)['indentGuides'], isFalse);
    s.dispose();
  });

  test('bad values in the file are ignored', () async {
    final s = store(initial: {
      'editor': {'autosave': 'yes', 'autosaveDelayMs': 5, 'appearance': 'oops'},
    });
    await s.load();
    expect(sessions.autosave, isTrue);
    expect(sessions.autosaveDelay, EditorSessionManager.defaultAutosaveDelay);
    s.dispose();
  });

  testWidgets('settings dialog toggles autosave and appearance', (tester) async {
    final s = store();
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(onPressed: () => showSettingsDialog(context, s), child: const Text('open')),
        ),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsOneWidget);
    expect(find.text('自动保存文件'), findsOneWidget);

    await tester.tap(find.text('自动保存文件'));
    await tester.pump();
    expect(sessions.autosave, isFalse);

    await tester.tap(find.text('外观'));
    await tester.pumpAndSettle();
    // 显示开关在字号、配色之后:滚动到可见
    await tester.scrollUntilVisible(find.text('显示行号'), 200, scrollable: find.byType(Scrollable).last);
    await tester.tap(find.text('显示行号'));
    await tester.pump();
    expect(sessions.appearance.showLineNumbers, isFalse);
    expect(((written.last['editor'] as Map)['appearance'] as Map)['lineNumbers'], isFalse);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    expect(find.text('设置'), findsNothing);
    s.dispose();
  });
}
