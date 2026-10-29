import 'package:code_lite_ui/app.dart';
import 'package:code_lite_ui/core/l10n/l10n.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/settings/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设置 ▸ 语言和地区:中文 / English,换了立刻生效并记下来;没选过时跟系统。
void main() {
  tearDown(() {
    L10n.systemLanguage = () => AppLanguage.zh;
    L10n.language.value = AppLanguage.zh;
  });

  test('tr picks the current language', () {
    expect(tr('设置', 'Settings'), '设置');
    L10n.language.value = AppLanguage.en;
    expect(tr('设置', 'Settings'), 'Settings');
  });

  test('menu search matches either language', () {
    expect(matchesEitherLanguage('push', '推送…', 'Push…'), isTrue);
    expect(matchesEitherLanguage('推送', '推送…', 'Push…'), isTrue);
    expect(matchesEitherLanguage('', '推送…', 'Push…'), isTrue);
    expect(matchesEitherLanguage('clone', '推送…', 'Push…'), isFalse);
  });

  test('without a saved choice the language follows the system; a choice is saved and wins next time', () async {
    final saved = <Map<String, dynamic>>[];
    L10n.systemLanguage = () => AppLanguage.en;
    final s = SettingsStore(appearance: EditorAppearance(), load: () async => {}, save: (j) async => saved.add(j));
    await s.load();
    expect(L10n.language.value, AppLanguage.en, reason: '没选过:跟系统');
    expect(s.toJson().containsKey('language'), isFalse, reason: '没选过就不写,以后系统换了语言还能跟着');

    s.setLanguage(AppLanguage.zh);
    expect(L10n.language.value, AppLanguage.zh);
    expect(saved.last['language'], 'zh');

    final again = SettingsStore(appearance: EditorAppearance(), load: () async => saved.last, save: (_) async {});
    L10n.language.value = AppLanguage.en;
    await again.load();
    expect(L10n.language.value, AppLanguage.zh, reason: '选过的优先于系统语言');
    s.dispose();
    again.dispose();
  });

  testWidgets('the Language and Region page switches the whole UI at once', (tester) async {
    final s = SettingsStore(appearance: EditorAppearance(), load: () async => {}, save: (_) async {});
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(MaterialApp(home: Scaffold(body: SettingsDialog(settings: s))));
    expect(find.text('设置'), findsOneWidget);
    await tester.tap(find.byKey(const ValueKey('settings-nav-language')));
    await tester.pump();
    expect(find.text('界面语言'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('language-en')));
    await tester.pump();
    expect(L10n.language.value, AppLanguage.en);
    expect(find.text('Settings'), findsOneWidget, reason: '标题跟着变');
    expect(find.text('Language'), findsOneWidget);
    expect(find.text('Language and Region'), findsOneWidget);

    await tester.tap(find.byKey(const ValueKey('language-zh')));
    await tester.pump();
    expect(find.text('设置'), findsOneWidget);
    s.dispose();
  });

  testWidgets('in English the workbench shows no Chinese text (titles, tooltips, panels, settings)', (tester) async {
    L10n.language.value = AppLanguage.en;
    L10n.systemLanguage = () => AppLanguage.en;
    await tester.binding.setSurfaceSize(const Size(1400, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();

    final cjk = RegExp(r'[\u4e00-\u9fff]');
    List<String> chinese() => [
          for (final t in tester.widgetList<Text>(find.byType(Text)))
            if (cjk.hasMatch(t.data ?? t.textSpan?.toPlainText() ?? '')) t.data ?? t.textSpan!.toPlainText(),
          for (final t in tester.widgetList<Tooltip>(find.byType(Tooltip)))
            if (cjk.hasMatch(t.message ?? '')) t.message!,
        ];

    expect(chinese(), isEmpty, reason: '工作台');
    // 打开几个面板再看:Opening、Problems、终端
    for (final tip in ['Opening Projects', 'Problems', 'Terminal']) {
      final f = find.byWidgetPredicate((w) => w is Tooltip && (w.message ?? '').startsWith(tip));
      expect(f, findsWidgets, reason: '$tip 的按钮');
      await tester.tap(f.first);
      await tester.pump();
      expect(chinese(), isEmpty, reason: tip);
    }
    await tester.pumpWidget(const SizedBox());
  });
}
