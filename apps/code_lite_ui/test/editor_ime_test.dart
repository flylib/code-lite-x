import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 中文输入法:编辑器接上输入法时,字母键要交给输入法组字,不能自己先插进文档
/// (以前第一个字母被编辑器直接插进去,输入法收不到,拼音打不出来)。
void main() {
  Future<CodeEditorController> pumpEditor(WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 600));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final ctrl = CodeEditorController(initialText: 'ab\n');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: EditorViewWidget(
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
    await tester.tap(find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == 'ab'));
    await tester.pump();
    ctrl.setCursor(const EditorPosition(0, 1));
    await tester.pump();
    return ctrl;
  }

  testWidgets('with the input method attached, letters go to it; pinyin composes and the chosen word replaces it', (tester) async {
    final ctrl = await pumpEditor(tester);
    expect(tester.testTextInput.hasAnyClients, isTrue, reason: '编辑器有焦点时接上了输入法');

    // 键盘事件本身不插字:交给输入法
    await tester.sendKeyEvent(LogicalKeyboardKey.keyR);
    await tester.pump();
    expect(ctrl.text, 'ab\n');

    // 输入法组字:r → 拼音 "r" 标着组字区
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'arb',
      selection: TextSelection.collapsed(offset: 2),
      composing: TextRange(start: 1, end: 2),
    ));
    await tester.pump();
    expect(ctrl.text, 'arb\n');

    // 组字时退格是给输入法的,不动文档
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(ctrl.text, 'arb\n');

    // 选了「人」:上屏替换拼音
    tester.testTextInput.updateEditingValue(const TextEditingValue(
      text: 'a人b',
      selection: TextSelection.collapsed(offset: 2),
    ));
    await tester.pump();
    expect(ctrl.text, 'a人b\n');
    expect(ctrl.cursorPosition, const EditorPosition(0, 2));

    // 上屏之后退格照常删字
    await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
    await tester.pump();
    expect(ctrl.text, 'ab\n');

    await tester.pump(const Duration(seconds: 1)); // 点击的双击判定计时器
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}
