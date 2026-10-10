import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/lsp_overlay.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 错误(找不到定义的变量 / 方法、语法错误……):出问题的那个词变红,不画下划线(IntelliJ 的做法)。
Map<String, dynamic> _json({int line = 0, int from = 0, int to = 5, int severity = 1, List<int>? tags, int? endLine, String message = 'The method foo() is undefined'}) => {
      'range': {
        'start': {'line': line, 'character': from},
        'end': {'line': endLine ?? line, 'character': to},
      },
      'severity': severity,
      'message': message,
      'code': '67108964',
      if (tags != null) 'tags': tags,
    };

EditorDiagnostic diag({int line = 0, int from = 0, int to = 5, int severity = 1, List<int>? tags, int? endLine}) =>
    EditorDiagnostic.fromJson(_json(line: line, from: from, to: to, severity: severity, tags: tags, endLine: endLine));

List<String> red(List<TextSpan> spans) => [for (final s in spans) if (s.style?.color == errorTextColor) s.text!];
String plain(List<TextSpan> spans) => spans.map((s) => s.text).join();

void main() {
  // params.put("bulkSize", String.valueOf(this.config.getDefaultBulkSize()));
  const line = 'params.put("bulkSize", String.valueOf(this.config.getDefaultBulkSize()));';
  const spans = [
    TextSpan(text: 'params'),
    TextSpan(text: '.put('),
    TextSpan(text: '"bulkSize"', style: TextStyle(color: Color(0xFF6AAB73))),
    TextSpan(text: ', String.valueOf(this.config.'),
    TextSpan(text: 'getDefaultBulkSize', style: TextStyle(color: Color(0xFFFFC66D), fontWeight: FontWeight.bold)),
    TextSpan(text: '()));'),
  ];
  final at = line.indexOf('getDefaultBulkSize');

  group('colouring', () {
    test('only the reported word turns red, other styling on it is kept, the text never changes', () {
      final out = colorDiagnosticRanges(spans, line, [diag(from: at, to: at + 'getDefaultBulkSize'.length)], 0);
      expect(plain(out), line, reason: '文字不变,不影响宽度测量');
      expect(red(out), ['getDefaultBulkSize']);
      final word = out.firstWhere((s) => s.text == 'getDefaultBulkSize');
      expect(word.style!.fontWeight, FontWeight.bold);
      expect(word.style!.color, errorTextColor);
      expect(out.first.style, isNull, reason: '别处原样');
    });

    test('a range inside a span splits it; a range across spans colours each part', () {
      final inside = colorDiagnosticRanges(spans, line, [diag(from: 3, to: 5)], 0);
      expect(plain(inside), line);
      expect(red(inside), ['am']);
      final across = colorDiagnosticRanges(spans, line, [diag(from: 4, to: 10)], 0);
      expect(plain(across), line);
      expect(red(across).join(), line.substring(4, 10));
    });

    test('warnings, hints and other lines are left alone', () {
      expect(identical(colorDiagnosticRanges(spans, line, [diag(severity: 2, from: at, to: at + 5)], 0), spans), isTrue, reason: '普通警告不改字色(它画下划线)');
      expect(identical(colorDiagnosticRanges(spans, line, [diag(severity: 3, from: 0, to: 4)], 0), spans), isTrue);
      expect(identical(colorDiagnosticRanges(spans, line, [diag(line: 7, from: 0, to: 4)], 0), spans), isTrue);
      expect(identical(colorDiagnosticRanges(spans, line, const [], 0), spans), isTrue);
    });

    test('an empty range (server gave only a position) reddens the identifier there, or the neighbouring character', () {
      final onWord = colorDiagnosticRanges(spans, line, [diag(from: at + 4, to: at + 4)], 0);
      expect(red(onWord).join(), 'getDefaultBulkSize', reason: '整个标识符');
      // 位置在标点上:染紧挨着的那个字符
      final onPunct = colorDiagnosticRanges(spans, line, [diag(from: line.length - 1, to: line.length - 1)], 0);
      expect(red(onPunct).join(), ';');
      // 位置在行尾
      final atEnd = colorDiagnosticRanges(spans, line, [diag(from: line.length, to: line.length)], 0);
      expect(red(atEnd).join(), ';');
      expect(colorDiagnosticRanges(const [TextSpan(text: '')], '', [diag(from: 0, to: 0)], 0), hasLength(1), reason: '空行没有东西可染');
    });

    test('a multi-line range goes red to the end of its first line; ranges past the line end are clamped', () {
      expect(red(colorDiagnosticRanges(spans, line, [diag(from: 20, to: 2, endLine: 3)], 0)).join(), line.substring(20));
      expect(red(colorDiagnosticRanges(spans, line, [diag(from: line.length - 3, to: 999)], 0)).join(), line.substring(line.length - 3));
    });

    test('red wins over grey where an error and an unused hint overlap; each keeps its own part', () {
      final out = colorDiagnosticRanges(spans, line, [
        diag(from: 0, to: 12, severity: 2, tags: [1]), // 没用到:params.put("b
        diag(from: 7, to: 12), // 错误:put("b
      ], 0);
      expect(plain(out), line);
      expect([for (final s in out) if (s.style?.color == errorTextColor) s.text].join(), line.substring(7, 12));
      expect([for (final s in out) if (s.style?.color == unusedTextColor) s.text].join(), line.substring(0, 7));
    });

    test('two errors on one line are both red', () {
      final out = colorDiagnosticRanges(spans, line, [diag(from: 0, to: 6), diag(from: at, to: at + 4)], 0);
      expect(red(out).join(), 'paramsgetD');
    });
  });

  testWidgets('editor: an error reddens its word and draws no underline; a plain warning still underlines', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ctrl = CodeEditorController(initialText: '$line\nint other = 1;');
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
    // 下划线是行底部那条 2px 高、带底边线的容器;错误的和警告的颜色不同,各数各的
    Finder underline(Color c) => find.byWidgetPredicate((w) =>
        w is Container &&
        w.decoration is BoxDecoration &&
        (w.decoration! as BoxDecoration).border is Border &&
        ((w.decoration! as BoxDecoration).border! as Border).bottom.color == c);
    const redLine = Color(0xFFF97A7A);
    const yellowLine = Color(0xFFE5C07B);

    await tester.pumpWidget(editor([diag(from: at, to: at + 'getDefaultBulkSize'.length)]));
    await tester.pump();
    final text = tester.widget<RichText>(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == line));
    final reddened = <String>[];
    text.text.visitChildren((s) {
      if (s is TextSpan && s.style?.color == errorTextColor) reddened.add(s.text!);
      return true;
    });
    expect(reddened.join(), 'getDefaultBulkSize');
    expect(underline(redLine), findsNothing, reason: '不再画红色下划线');
    expect(underline(yellowLine), findsNothing);

    // 警告:字色不变,仍然黄色下划线
    await tester.pumpWidget(editor([diag(from: at, to: at + 5, severity: 2)]));
    await tester.pump();
    expect(underline(yellowLine), findsOneWidget);
    final warned = tester.widget<RichText>(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == line));
    var anyRed = false;
    warned.text.visitChildren((s) {
      if (s is TextSpan && s.style?.color == errorTextColor) anyRed = true;
      return true;
    });
    expect(anyRed, isFalse);

    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}
