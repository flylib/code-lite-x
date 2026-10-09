import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/lsp_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 没用到的变量 / 字段:LSP 给的 Unnecessary 标记 → 文字变灰,没有下划线,不算警告(IntelliJ 的做法)。
Map<String, dynamic> _json({int line = 0, int from = 0, int to = 5, int severity = 2, List<int>? tags, int? endLine}) => {
      'range': {
        'start': {'line': line, 'character': from},
        'end': {'line': endLine ?? line, 'character': to},
      },
      'severity': severity,
      'message': 'The value of the field X.y is not used',
      'code': '570425421',
      if (tags != null) 'tags': tags,
    };

String _text(List<TextSpan> spans) => spans.map((s) => s.text).join();

void main() {
  group('model', () {
    test('tags parse; an unused warning is neither a warning nor an error', () {
      final unused = EditorDiagnostic.fromJson(_json(tags: [1]));
      expect(unused.isUnnecessary, isTrue);
      expect(unused.isWarning, isFalse, reason: '不算警告:状态栏计数、行号栏图标、下划线都不该有它');
      expect(unused.isError, isFalse);

      final plain = EditorDiagnostic.fromJson(_json());
      expect(plain.isUnnecessary, isFalse);
      expect(plain.isWarning, isTrue);
      expect(EditorDiagnostic.fromJson(_json(severity: 1, tags: [2])).isError, isTrue, reason: '只有 Deprecated 标记的照旧');
      expect(EditorDiagnostic.fromJson({'message': 'x'}).tags, isEmpty);
    });
  });

  group('fadeUnused', () {
    const keyword = TextStyle(color: Color(0xFFCC7832), fontWeight: FontWeight.bold);
    // private long targetExistingRows = -1L;
    const spans = [
      TextSpan(text: 'private', style: keyword),
      TextSpan(text: ' long '),
      TextSpan(text: 'targetExistingRows', style: TextStyle(color: Colors.white, fontStyle: FontStyle.italic)),
      TextSpan(text: ' = -1L;'),
    ];
    const line = 'private long targetExistingRows = -1L;';

    test('greys exactly the reported range, splitting spans at its edges and keeping other style', () {
      final d = EditorDiagnostic.fromJson(_json(from: 13, to: 31, tags: [1]));
      final out = fadeUnused(spans, line, [d], 0);
      expect(_text(out), line, reason: '文字不变,宽度测量不受影响');
      expect(out.map((s) => s.text), ['private', ' long ', 'targetExistingRows', ' = -1L;']);
      expect(out[2].style!.color, unusedTextColor);
      expect(out[2].style!.fontStyle, FontStyle.italic);
      expect(out[0].style, keyword);
      expect(out[1].style, isNull);

      // 范围落在一个片段中间:切成三段
      final mid = fadeUnused(spans, line, [EditorDiagnostic.fromJson(_json(from: 13, to: 19, tags: [1]))], 0);
      expect(_text(mid), line);
      expect([for (final s in mid) if (s.style?.color == unusedTextColor) s.text], ['target']);
      // 跨片段:private 的后半 + 空白
      final across = fadeUnused(spans, line, [EditorDiagnostic.fromJson(_json(from: 4, to: 9, tags: [1]))], 0);
      expect(_text(across), line);
      expect([for (final s in across) if (s.style?.color == unusedTextColor) s.text], ['ate', ' l']);
      expect(across.first.style, keyword, reason: '没被覆盖的部分保持原样');
    });

    test('ignores ordinary diagnostics, other lines, empty ranges; clamps; multi-line goes to end of line', () {
      expect(identical(fadeUnused(spans, line, [EditorDiagnostic.fromJson(_json(from: 13, to: 31))], 0), spans), isTrue, reason: '没有标记:原样返回');
      expect(identical(fadeUnused(spans, line, [EditorDiagnostic.fromJson(_json(line: 3, from: 13, to: 31, tags: [1]))], 0), spans), isTrue);
      expect(identical(fadeUnused(spans, line, [EditorDiagnostic.fromJson(_json(from: 5, to: 5, tags: [1]))], 0), spans), isTrue);

      final clamped = fadeUnused(spans, line, [EditorDiagnostic.fromJson(_json(from: 31, to: 999, tags: [1]))], 0);
      expect(_text(clamped), line);
      expect([for (final s in clamped) if (s.style?.color == unusedTextColor) s.text], [' = -1L;']);

      final multi = fadeUnused(spans, line, [EditorDiagnostic.fromJson(_json(from: 8, to: 3, endLine: 4, tags: [1]))], 0);
      expect([for (final s in multi) if (s.style?.color == unusedTextColor) s.text].join(), line.substring(8));
      expect(fadeUnused(const [TextSpan(text: '')], '', [EditorDiagnostic.fromJson(_json(tags: [1]))], 0), hasLength(1));
    });
  });

  testWidgets('editor: unused field is grey with no underline; a real warning on another line still is underlined', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ctrl = CodeEditorController(initialText: 'private long targetExistingRows = -1L;\nint other = 1;');
    final diagnostics = [
      EditorDiagnostic.fromJson(_json(from: 13, to: 31, tags: [1])),
    ];
    Widget editor(List<EditorDiagnostic> diags) => MaterialApp(
          home: Scaffold(
            body: EditorViewWidget(
              openTabs: const ['A.java'],
              activeFile: 'A.java',
              codeContent: '',
              controller: ctrl,
              appearance: EditorAppearance(),
              diagnostics: diags,
              onSelectTab: (_) {},
              onCloseTab: (_) {},
            ),
          ),
        );
    Finder squiggles() => find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).border is Border && ((w.decoration! as BoxDecoration).border! as Border).bottom.color == const Color(0xFFE5C07B));

    await tester.pumpWidget(editor(diagnostics));
    await tester.pump();
    final line0 = tester.widget<RichText>(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'private long targetExistingRows = -1L;'));
    final greyed = <String>[];
    (line0.text as TextSpan).visitChildren((s) {
      if (s is TextSpan && s.style?.color == unusedTextColor) greyed.add(s.text!);
      return true;
    });
    expect(greyed.join(), 'targetExistingRows');
    expect(squiggles(), findsNothing, reason: '没有黄色下划线');

    // 对照:同一位置换成普通警告,就有下划线
    await tester.pumpWidget(editor([EditorDiagnostic.fromJson(_json(from: 13, to: 31))]));
    await tester.pump();
    expect(squiggles(), findsOneWidget);

    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}
