import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

/// 光标 / 点击定位必须和实际排出来的字形对齐:
/// 曾经按「列数 × 固定字宽」算,且没减代码区内边距,在比例字体或中文行上
/// 光标画在一处、字却插到另一处。
void main() {
  const text = 'python3 -m http.server 3000\n## 运行 中文\n';

  Future<CodeEditorController> pumpEditor(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ctrl = CodeEditorController(initialText: text);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorViewWidget(
          // 不用 .md:Markdown 文件默认带预览,预览里也有同样的文字
          openTabs: const ['notes.txt'],
          activeFile: 'notes.txt',
          codeContent: ctrl.text,
          controller: ctrl,
          onSelectTab: (_) {},
          onCloseTab: (_) {},
          onCodeChanged: (_) {},
        ),
      ),
    ));
    await tester.pump();
    return ctrl;
  }

  Future<void> disposeEditor(WidgetTester tester, CodeEditorController ctrl) async {
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  }

  RenderParagraph paragraphOf(WidgetTester tester, String line) => tester.renderObject<RenderParagraph>(
        find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == line),
      );

  /// 第 [col] 个字符边界在屏幕上的位置(取行高中部)。
  Offset boundary(RenderParagraph p, int col) =>
      p.localToGlobal(p.getOffsetForCaret(TextPosition(offset: col), Rect.zero) + Offset(0, p.size.height / 2));

  Rect caretRect(WidgetTester tester) => tester.getRect(find.byWidgetPredicate(
        (w) => w is Container && w.color == const Color(0xFF589DF6) && w.constraints?.maxWidth == 2,
      ));

  for (final (line, lineIndex, col) in [
    ('python3 -m http.server 3000', 0, 22),
    ('## 运行 中文', 1, 5),
  ]) {
    testWidgets('click before char $col of "$line" puts the caret exactly there', (tester) async {
      final ctrl = await pumpEditor(tester);
      final p = paragraphOf(tester, line);

      await tester.tapAt(boundary(p, col) + const Offset(1, 0));
      await tester.pump(kDoubleTapTimeout); // 有双击识别器竞争,单击要等它放弃
      expect(ctrl.cursorPosition, EditorPosition(lineIndex, col));
      expect(caretRect(tester).left, moreOrLessEquals(boundary(p, col).dx, epsilon: 0.5));

      // 输入落在光标处,光标随之右移到新字符之后
      ctrl.insertText('11');
      await tester.pump();
      expect(ctrl.lines[lineIndex], '${line.substring(0, col)}11${line.substring(col)}');
      final after = paragraphOf(tester, ctrl.lines[lineIndex]);
      expect(caretRect(tester).left, moreOrLessEquals(boundary(after, col + 2).dx, epsilon: 0.5));
      await disposeEditor(tester, ctrl);
    });
  }

  testWidgets('click past the end of a line lands at its end', (tester) async {
    final ctrl = await pumpEditor(tester);
    final p = paragraphOf(tester, '## 运行 中文');
    await tester.tapAt(boundary(p, 8) + const Offset(300, 0));
    await tester.pump(kDoubleTapTimeout);
    expect(ctrl.cursorPosition, const EditorPosition(1, 8));
    await disposeEditor(tester, ctrl);
  });
}
