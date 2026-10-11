import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/state/settings_store.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/syntax/color_schemes.dart';
import 'package:code_lite_ui/features/editor/syntax/document_highlighter.dart';
import 'package:code_lite_ui/features/editor/syntax/languages.dart';
import 'package:code_lite_ui/features/editor/syntax/tokenizer.dart';
import 'package:code_lite_ui/features/settings/settings_dialog.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 设置:编辑器字号与代码配色方案。
void main() {
  test('font size: clamped, rounded, drives the line height; persists with the scheme', () {
    final a = EditorAppearance();
    expect(a.fontSize, 12);
    expect(a.lineHeight, 20, reason: '默认与原来的固定行高一致');
    a.setFontSize(16.4);
    expect(a.fontSize, 16);
    expect(a.lineHeight, 26);
    a.setFontSize(100);
    expect(a.fontSize, EditorAppearance.maxFontSize);
    a.setFontSize(1);
    expect(a.fontSize, EditorAppearance.minFontSize);
    a.setFontSize(14);
    a.setColorScheme('monokai');
    a.setColorScheme('no-such-scheme');
    expect(a.colorScheme.name, 'Monokai');

    final b = EditorAppearance()..applyJson(a.toJson());
    expect(b.fontSize, 14);
    expect(b.colorSchemeId, 'monokai');
    final c = EditorAppearance()..applyJson({'fontSize': 'big', 'colorScheme': 'nope'});
    expect(c.fontSize, 12);
    expect(c.colorSchemeId, 'islands', reason: '默认是 Islands Dark');

    // 旧版设置文件里的 darcula 只是当时的默认值:换成新默认;新版存下的 darcula 是用户选的,保留
    expect((EditorAppearance()..applyJson({'colorScheme': 'darcula'})).colorSchemeId, 'islands');
    expect((EditorAppearance()..applyJson({'colorScheme': 'darcula', 'schemeVersion': 2})).colorSchemeId, 'darcula');
    expect((EditorAppearance()..applyJson({'colorScheme': 'monokai'})).colorSchemeId, 'monokai');
    expect(EditorAppearance().toJson()['schemeVersion'], 2);
    expect(islandsDarkScheme.background, const Color(0xFF181A1C), reason: '代码区背景就是岛的底色');
  });

  test('every scheme defines colors for the main token kinds; Darcula matches the old colors', () {
    expect(builtinColorSchemes.map((s) => s.id).toSet(), hasLength(builtinColorSchemes.length));
    for (final s in builtinColorSchemes) {
      for (final k in [TokenKind.keyword, TokenKind.string, TokenKind.number, TokenKind.comment, TokenKind.function, TokenKind.type]) {
        expect(s.styleOf(k)?.color, isNotNull, reason: '${s.id} $k');
      }
      expect(s.background.computeLuminance(), lessThan(0.2), reason: '${s.id} 是深色方案');
    }
    expect(darculaScheme.styleOf(TokenKind.keyword)!.color, const Color(0xFFCC7832));
    expect(darculaScheme.background, const Color(0xFF1E1F22));
  });

  test('changing the scheme re-colors the whole document', () {
    final h = DocumentHighlighter();
    final java = languages.byId('java')!;
    final lines = ['public int x = 1;'];
    h.update(java, lines);
    expect(h.spansAt(0).first.style!.color, const Color(0xFFCC7832));
    h.update(java, lines, scheme: colorSchemeById('monokai'));
    // 分词状态与配色无关,换配色不必重新分词;着色片段按新配色重新生成
    expect(h.lastRetokenized, 0);
    expect(h.spansAt(0).first.style!.color, const Color(0xFFF92672));
  });

  testWidgets('editor lays out rows at the new font size and keeps clicks on the glyphs', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final appearance = EditorAppearance();
    final ctrl = CodeEditorController(initialText: List.generate(30, (i) => 'int v$i = $i;').join('\n'));
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorViewWidget(
          openTabs: const ['A.java'],
          activeFile: 'A.java',
          codeContent: '',
          controller: ctrl,
          appearance: appearance,
          onSelectTab: (_) {},
          onCloseTab: (_) {},
        ),
      ),
    ));
    await tester.pump();
    Finder line(int i) => find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'int v$i = $i;');
    double rowGap() => tester.getTopLeft(line(5)).dy - tester.getTopLeft(line(4)).dy;
    expect(rowGap(), 20);

    appearance.setFontSize(18);
    await tester.pump();
    expect(rowGap(), appearance.lineHeight);
    expect(appearance.lineHeight, 30);
    final p = tester.renderObject<RenderParagraph>(line(5));
    expect(p.text.style!.fontSize, 18);
    // 点在第 5 行第 4 个字符前,光标应正好落在那里(字宽按新字号重新测量)
    final at = p.localToGlobal(p.getOffsetForCaret(const TextPosition(offset: 4), Rect.zero) + Offset(1, p.size.height / 2));
    await tester.tapAt(at);
    await tester.pump(kDoubleTapTimeout);
    expect(ctrl.cursorPosition, const EditorPosition(5, 4));

    appearance.setColorScheme('dracula');
    await tester.pump();
    final keyword = (tester.widget<RichText>(line(5)).text as TextSpan).children!.first as TextSpan;
    expect(keyword.style!.color, const Color(0xFF8BE9FD), reason: 'int 是类型,用 Dracula 的类型色');
    expect(find.byWidgetPredicate((w) => w is ColoredBox && w.color == const Color(0xFF282A36)), findsWidgets, reason: '代码区底色跟着换');
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });

  testWidgets('settings: font size buttons and scheme cards', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 900));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final client = ApiClient(initialRoot: '.');
    final sessions = EditorSessionManager(client: client);
    final saved = <Map<String, dynamic>>[];
    final store = SettingsStore(sessions: sessions, load: () async => {}, save: (j) async => saved.add(j));
    await tester.pumpWidget(MaterialApp(
      home: Builder(
        builder: (context) => Scaffold(body: TextButton(onPressed: () => showSettingsDialog(context, store), child: const Text('open'))),
      ),
    ));
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Appearance'));
    await tester.pumpAndSettle();
    expect(find.text('Darcula'), findsOneWidget);
    expect(find.text('Monokai'), findsOneWidget);

    await tester.tap(find.byTooltip('增大'));
    await tester.pump();
    expect(sessions.appearance.fontSize, 13);
    expect(find.text('13'), findsOneWidget);
    await tester.tap(find.text('16'));
    await tester.pump();
    expect(sessions.appearance.fontSize, 16);
    await tester.tap(find.text('恢复默认'));
    await tester.pump();
    expect(sessions.appearance.fontSize, 12);

    await tester.ensureVisible(find.byKey(const ValueKey('scheme-nord')));
    await tester.pumpAndSettle();
    await tester.tap(find.byKey(const ValueKey('scheme-nord')));
    await tester.pump();
    expect(sessions.appearance.colorSchemeId, 'nord');
    final editor = (saved.last['editor'] as Map)['appearance'] as Map;
    expect(editor['colorScheme'], 'nord', reason: '写进设置文件');
    expect(editor['fontSize'], 12);

    await tester.tap(find.byTooltip('关闭'));
    await tester.pumpAndSettle();
    store.dispose();
    sessions.dispose();
    await tester.runAsync(client.dispose);
  });
}
