import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// ⌘X 没选中时:删掉当前行并把这一行放进剪贴板(同 IntelliJ);⌘V 粘回来时作为整行插到当前行上面。
void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  String? clipboard;

  setUp(() {
    clipboard = null;
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
      if (call.method == 'Clipboard.setData') clipboard = (call.arguments as Map)['text'] as String?;
      if (call.method == 'Clipboard.getData') return clipboard == null ? null : {'text': clipboard};
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null);
  });

  test('no selection: the caret line is removed and copied; the caret stays in the same column', () async {
    final c = CodeEditorController(initialText: 'one\n  two\nthree');
    c.setCursor(const EditorPosition(1, 3));
    await c.cut();
    expect(c.text, 'one\nthree');
    expect(clipboard, '  two\n');
    expect(c.cursorPosition, const EditorPosition(1, 3));
    c.undo();
    expect(c.text, 'one\n  two\nthree', reason: '一步撤销');
    c.dispose();
  });

  test('last line, only line, empty file', () async {
    final c = CodeEditorController(initialText: 'a\nlast');
    c.setCursor(const EditorPosition(1, 2));
    await c.cut();
    expect(c.text, 'a');
    expect(clipboard, 'last\n');
    expect(c.cursorPosition, const EditorPosition(0, 1));
    await c.cut();
    expect(c.text, '', reason: '只剩一行:清空');
    expect(clipboard, 'a\n');
    clipboard = 'untouched';
    await c.cut();
    expect(clipboard, 'untouched', reason: '空文件不动剪贴板');
    c.dispose();
  });

  test('cut then paste moves the line above the caret line', () async {
    final c = CodeEditorController(initialText: 'one\ntwo\nthree\nfour');
    c.setCursor(const EditorPosition(0, 1));
    await c.cut(); // 剪掉 one
    c.setCursor(const EditorPosition(2, 2)); // four 的中间
    await c.paste();
    expect(c.text, 'two\nthree\none\nfour', reason: '整行插在 four 上面,不插进 four 中间');
    expect(c.cursorPosition, const EditorPosition(3, 2), reason: '光标跟着 four 走');
  });

  test('with a selection it still cuts just the selection; ordinary clipboard text pastes inline', () async {
    final c = CodeEditorController(initialText: 'hello world');
    c.setSelection(const EditorPosition(0, 5), const EditorPosition(0, 11));
    await c.cut();
    expect(c.text, 'hello');
    expect(clipboard, ' world');
    c.setCursor(const EditorPosition(0, 0));
    await c.paste();
    expect(c.text, ' worldhello');
    c.dispose();
  });
}
