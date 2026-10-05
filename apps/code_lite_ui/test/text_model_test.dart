import 'dart:math';

import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/ime_text_input_client.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 文本内核:以行为准、只改受影响的行、撤销直接记录改动。用随机编辑和纯字符串参照模型对拍。
void main() {
  int offsetOf(String text, EditorPosition p) {
    final lines = text.split('\n');
    var o = 0;
    for (var i = 0; i < p.line; i++) {
      o += lines[i].length + 1;
    }
    return o + p.col;
  }

  test('random edits match a plain-string model; undo all / redo all round-trip', () {
    final rnd = Random(42);
    const initial = 'alpha beta\n  gamma {\n\tdelta\n\nepsilon 中文 😀';
    final c = CodeEditorController(initialText: initial);
    var model = initial;
    final snapshots = <String>[initial];

    EditorPosition randomPos() {
      final line = rnd.nextInt(c.lineCount);
      return EditorPosition(line, rnd.nextInt(c.lineAt(line).length + 1));
    }

    for (var step = 0; step < 600; step++) {
      // 断开合并:每步都是独立的一步撤销,方便逐步核对
      c.setCursor(randomPos());
      final op = rnd.nextInt(8);
      final head = c.cursorPosition;
      final o = offsetOf(model, head);
      switch (op) {
        case 0: // 输入
          final s = ['x', 'yz', '中', '\n', 'a\nb', ''][rnd.nextInt(6)];
          c.insertText(s);
          model = model.replaceRange(o, o, s);
        case 1: // 退格
          if (o > 0) {
            // 代理对:按 UTF-16 一个单元删(与编辑器行为一致)
            c.deleteBackward();
            model = model.replaceRange(o - 1, o, '');
          }
        case 2: // Delete
          if (o < model.length) {
            c.deleteForward();
            model = model.replaceRange(o, o + 1, '');
          }
        case 3: // 选区替换
          final other = randomPos();
          c.setSelection(head, other);
          final a = min(o, offsetOf(model, other)), b = max(o, offsetOf(model, other));
          c.insertText('R');
          model = model.replaceRange(a, b, 'R');
        case 4: // 回车(自动缩进:按编辑器结果核对整段文本)
          c.insertNewline();
          model = c.text;
        case 5: // 多行缩进 / 反缩进
          final other = randomPos();
          c.setSelection(head, other);
          rnd.nextBool() ? c.insertTab() : c.unindent();
          model = c.text;
        case 6: // replaceRange
          final other = randomPos();
          final a = min(o, offsetOf(model, other)), b = max(o, offsetOf(model, other));
          c.replaceRange(head, other, 'Q\n');
          model = model.replaceRange(a, b, 'Q\n');
        case 7: // 整体替换
          final t = model.replaceFirst('a', 'A');
          c.replaceAllText(t);
          model = t;
      }
      expect(c.text, model, reason: 'step $step op $op');
      expect(c.length, model.length);
      expect(c.lines.join('\n'), model);
      if (snapshots.last != model) snapshots.add(model);
    }
    // 全部撤销回到起点,经过的每个状态都在快照里
    var undone = 0;
    while (c.undo()) {
      undone++;
      expect(snapshots.contains(c.text), isTrue);
    }
    expect(c.text, initial);
    expect(c.isDirty, isFalse);
    while (c.redo()) {
      undone--;
    }
    expect(undone, 0);
    expect(c.text, model);
    c.dispose();
  });

  test('lines snapshot is stable between edits and changes after one; version counts edits', () {
    final c = CodeEditorController(initialText: 'a\nb');
    final l1 = c.lines;
    final v1 = c.version;
    c.setCursor(const EditorPosition(1, 1));
    expect(identical(c.lines, l1), isTrue, reason: '只移动光标:同一个快照');
    c.insertText('!');
    expect(identical(c.lines, l1), isFalse);
    expect(c.lines, ['a', 'b!']);
    expect(c.version, v1 + 1);
    expect(() => c.lines.add("x"), throwsUnsupportedError);
    c.dispose();
  });

  test('dirty state: back to the saved text by typing or undo is clean', () {
    final c = CodeEditorController(initialText: 'hello');
    c.setCursor(const EditorPosition(0, 5));
    c.insertText('!');
    expect(c.isDirty, isTrue);
    c.deleteBackward();
    expect(c.isDirty, isFalse, reason: '内容与保存时相同(同长度时比对全文)');
    c.insertText('?');
    c.markSaved();
    expect(c.isDirty, isFalse);
    c.undo();
    expect(c.isDirty, isTrue, reason: '撤销到保存点之前');
    c.redo();
    expect(c.isDirty, isFalse, reason: '回到保存点');
    c.setText('loaded', markDirty: true);
    expect(c.isDirty, isTrue);
    c.dispose();
  });

  test('text listeners get no payload; text is only joined when read', () {
    final c = CodeEditorController(initialText: 'x\ny');
    var calls = 0;
    c.addTextListener(() => calls++);
    c.setCursor(const EditorPosition(1, 1));
    c.insertText('z');
    c.deleteBackward();
    expect(calls, 2);
    expect(c.text, 'x\ny');
    c.dispose();
  });

  group('IME window', () {
    TestWidgetsFlutterBinding.ensureInitialized();

    test('sends only the caret line and applies commits to the right place', () {
      final c = CodeEditorController(initialText: 'first line\nsecond\nthird');
      final focus = FocusNode()..requestFocus();
      final bridge = ImeTextInputBridge(controller: c, focusNode: focus);
      c.setCursor(const EditorPosition(1, 6));
      bridge.attach();
      expect(bridge.currentTextEditingValue!.text, 'second', reason: '只发光标所在行');
      expect(bridge.currentTextEditingValue!.selection, const TextSelection.collapsed(offset: 6));

      bridge.updateEditingValue(const TextEditingValue(
        text: 'secondni',
        composing: TextRange(start: 6, end: 8),
        selection: TextSelection.collapsed(offset: 8),
      ));
      bridge.updateEditingValue(const TextEditingValue(
        text: 'second你',
        selection: TextSelection.collapsed(offset: 7),
      ));
      expect(c.text, 'first line\nsecond你\nthird');
      expect(c.cursorPosition, const EditorPosition(1, 7));

      // 输入法插入换行:窗口跟到新行
      bridge.updateEditingValue(const TextEditingValue(text: 'second你\n', selection: TextSelection.collapsed(offset: 8)));
      expect(c.lines, ['first line', 'second你', '', 'third']);
      expect(bridge.currentTextEditingValue!.text, '');

      // 多行选区:窗口覆盖选区涉及的行
      c.setSelection(const EditorPosition(0, 6), const EditorPosition(1, 3));
      bridge.syncState();
      expect(bridge.currentTextEditingValue!.text, 'first line\nsecond你');
      bridge.updateEditingValue(const TextEditingValue(text: 'first 好ond你', selection: TextSelection.collapsed(offset: 7)));
      expect(c.lines.first, 'first 好ond你');
      bridge.detach();
      focus.dispose();
      c.dispose();
    });
  });
}
