import 'dart:io';

import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/fs/workspace_fs_native.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_session_manager.dart';
import 'package:flutter_test/flutter_test.dart';

void type(CodeEditorController c, String s) {
  for (final ch in s.split('')) {
    c.insertText(ch);
  }
}

void main() {
  group('CodeEditorController undo history', () {
    late CodeEditorController c;
    setUp(() => c = CodeEditorController(initialText: 'abc'));
    tearDown(() => c.dispose());

    test('consecutive typing is one undo step and restores the cursor', () {
      c.setCursor(const EditorPosition(0, 3));
      type(c, 'def');
      expect(c.text, 'abcdef');
      expect(c.canUndo, isTrue);

      expect(c.undo(), isTrue);
      expect(c.text, 'abc');
      expect(c.cursorPosition, const EditorPosition(0, 3));
      expect(c.canUndo, isFalse);
      expect(c.canRedo, isTrue);

      expect(c.redo(), isTrue);
      expect(c.text, 'abcdef');
      expect(c.cursorPosition, const EditorPosition(0, 6));
    });

    test('newline and cursor moves break typing groups', () {
      c.setCursor(const EditorPosition(0, 3));
      type(c, 'x');
      c.insertNewline();
      type(c, 'y');
      c.setCursor(const EditorPosition(0, 0));
      type(c, 'z');
      // 四步:x / 换行 / y / z
      expect(c.text, 'zabcx\ny');
      c.undo();
      expect(c.text, 'abcx\ny');
      c.undo();
      expect(c.text, 'abcx\n');
      c.undo();
      expect(c.text, 'abcx');
      c.undo();
      expect(c.text, 'abc');
      expect(c.canUndo, isFalse);
    });

    test('backspace and forward delete runs merge', () {
      c.setText('hello world');
      c.setCursor(const EditorPosition(0, 11));
      for (var i = 0; i < 5; i++) {
        c.deleteBackward();
      }
      expect(c.text, 'hello ');
      c.undo();
      expect(c.text, 'hello world');

      c.setCursor(const EditorPosition(0, 0));
      for (var i = 0; i < 6; i++) {
        c.deleteForward();
      }
      expect(c.text, 'world');
      c.undo();
      expect(c.text, 'hello world');
      expect(c.canUndo, isFalse);
    });

    test('runs of identical characters still merge (diff is ambiguous there)', () {
      c.setText('x');
      c.setCursor(const EditorPosition(0, 1));
      type(c, 'aaa');
      c.undo();
      expect(c.text, 'x');
      expect(c.canUndo, isFalse);

      c.setText('xlllly');
      c.setCursor(const EditorPosition(0, 5));
      for (var i = 0; i < 4; i++) {
        c.deleteBackward();
      }
      expect(c.text, 'xy');
      c.undo();
      expect(c.text, 'xlllly');
      expect(c.cursorPosition, const EditorPosition(0, 5));
      expect(c.canUndo, isFalse);
    });

    test('replacing a selection is one step and undo restores the selection', () {
      c.setText('one two three');
      c.setSelection(const EditorPosition(0, 4), const EditorPosition(0, 7));
      c.insertText('2');
      expect(c.text, 'one 2 three');
      c.undo();
      expect(c.text, 'one two three');
      expect(c.selection.start, const EditorPosition(0, 4));
      expect(c.selection.end, const EditorPosition(0, 7));
    });

    test('a new edit after undo clears redo', () {
      type(c, 'X');
      c.undo();
      expect(c.canRedo, isTrue);
      type(c, 'Y');
      expect(c.canRedo, isFalse);
      expect(c.redo(), isFalse);
    });

    test('dirty tracks the saved text, not the history depth', () {
      final changes = <bool>[];
      c.onDirtyChanged = changes.add;
      expect(c.isDirty, isFalse);
      c.setCursor(const EditorPosition(0, 3));
      type(c, '!');
      expect(c.isDirty, isTrue);
      c.undo();
      expect(c.isDirty, isFalse, reason: '撤销回到已保存的内容就不算修改');
      c.redo();
      c.markSaved();
      expect(c.isDirty, isFalse);
      c.undo();
      expect(c.isDirty, isTrue, reason: '保存点之后再撤销,内容又和磁盘不同了');
      expect(changes, [true, false, true, false, true]);
    });

    test('markSaved breaks the typing group', () {
      c.setCursor(const EditorPosition(0, 3));
      type(c, 'x');
      c.markSaved();
      type(c, 'y');
      c.undo();
      expect(c.text, 'abcx');
    });

    test('setText loads a document and clears history; replaceAllText is undoable', () {
      type(c, 'q');
      c.setText('fresh');
      expect(c.canUndo, isFalse);
      expect(c.isDirty, isFalse);

      c.replaceAllText('rewritten');
      expect(c.isDirty, isTrue);
      c.undo();
      expect(c.text, 'fresh');
    });

    test('undo/redo notify text listeners without recording new history', () {
      final seen = <String>[];
      c.addTextListener(() => seen.add(c.text));
      c.setCursor(const EditorPosition(0, 3));
      type(c, 'Z');
      c.undo();
      c.redo();
      expect(seen, ['abcZ', 'abc', 'abcZ']);
      expect(c.canRedo, isFalse);
      c.undo();
      expect(c.canUndo, isFalse, reason: '撤销/重做本身不该产生历史记录');
    });

    test('multi-line edits round-trip', () {
      c.setText('a\nb\nc');
      c.setSelection(const EditorPosition(0, 1), const EditorPosition(2, 0));
      c.insertText('XY\nZ');
      expect(c.text, 'aXY\nZc');
      c.undo();
      expect(c.text, 'a\nb\nc');
      c.redo();
      expect(c.text, 'aXY\nZc');
    });
  });

  group('file read / save', () {
    late Directory root;
    setUp(() => root = Directory.systemTemp.createTempSync('clx_file_'));
    tearDown(() => root.deleteSync(recursive: true));

    test('reads text, refuses binary, saves atomically and keeps the mode', () async {
      File('${root.path}/run.sh').writeAsStringSync('echo old\n');
      await Process.run('chmod', ['755', '${root.path}/run.sh']);
      File('${root.path}/blob.bin').writeAsBytesSync([1, 2, 0, 3]);

      final r = await readTextFile(root.path, 'run.sh');
      expect(r['status'], 'ok');
      expect(r['content'], 'echo old\n');

      final bin = await readTextFile(root.path, 'blob.bin');
      expect(bin['status'], 'error');
      expect(bin['binary'], isTrue);

      final w = await writeTextFile(root.path, 'run.sh', 'echo new\n');
      expect(w['status'], 'ok');
      expect(File('${root.path}/run.sh').readAsStringSync(), 'echo new\n');
      expect(File('${root.path}/run.sh').statSync().mode & 0x1ff, 0x1ed, reason: '0755 must survive the rename');
      expect(root.listSync().where((e) => e.path.contains('.codelite-save-')), isEmpty);

      final created = await writeTextFile(root.path, 'new/dir/file.txt', 'hi');
      expect(created['status'], 'ok');
      expect(File('${root.path}/new/dir/file.txt').readAsStringSync(), 'hi');

      expect((await readTextFile(root.path, 'missing.txt'))['status'], 'error');
    });

    test('session saves the editor text to disk; a tab that failed to load cannot save', () async {
      File('${root.path}/a.txt').writeAsStringSync('v1');
      File('${root.path}/blob.bin').writeAsBytesSync([0, 0, 0]);
      final client = _NoLspClient(root.path);
      final sessions = EditorSessionManager(client: client);
      addTearDown(sessions.dispose);

      final tab = await sessions.openFile('a.txt');
      tab.controller.setCursor(const EditorPosition(0, 2));
      type(tab.controller, '+edit');
      expect(sessions.isTabDirty('a.txt'), isTrue);
      expect(await sessions.saveActiveFile(), isTrue);
      expect(File('${root.path}/a.txt').readAsStringSync(), 'v1+edit');
      expect(sessions.isTabDirty('a.txt'), isFalse);

      // Undo 回到磁盘之前的内容后再保存,磁盘跟着回去。
      await sessions.undoActive();
      expect(tab.controller.text, 'v1');
      await sessions.saveActiveFile();
      expect(File('${root.path}/a.txt').readAsStringSync(), 'v1');

      final bad = await sessions.openFile('blob.bin');
      expect(bad.loadError, isNotNull);
      bad.controller.replaceAllText('oops');
      expect(await sessions.saveActiveFile(), isFalse);
      expect(File('${root.path}/blob.bin').readAsBytesSync(), [0, 0, 0], reason: '占位文字绝不能覆盖真文件');
    });
  });
}

/// 只测编辑与保存,不拉起语言服务器。
class _NoLspClient extends ApiClient {
  _NoLspClient(String root) : super(initialRoot: root);

  @override
  Future<void> lspDidOpen(String path, String text) async {}

  @override
  Future<void> lspDidChange(String path, String text) async {}

  @override
  Future<void> lspDidClose(String path) async {}
}
