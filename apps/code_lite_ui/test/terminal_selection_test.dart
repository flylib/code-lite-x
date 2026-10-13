import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/terminal/terminal_selection.dart';
import 'package:code_lite_ui/features/terminal/terminal_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

TermLine _line(String text, {int cols = 12, bool wrapped = false}) {
  final cells = List<String>.filled(cols, ' ');
  var c = 0;
  for (final r in text.runes) {
    final wide = r >= 0x4e00 && r <= 0x9fff;
    cells[c] = String.fromCharCode(r);
    if (wide) cells[c + 1] = '';
    c += wide ? 2 : 1;
  }
  return TermLine(cells, wrapped: wrapped);
}

/// 假终端:100 行历史("line 1".."line 100"),屏幕 5 行 × 40 列;回滚偏移按 vt100 的规则夹到 [0, 95]。
class _FakePty extends ApiClient {
  _FakePty() : super(initialRoot: '.');

  final List<String> written = [];
  static const total = 100, rows = 5;

  @override
  Map<String, dynamic> ptyResize(String id, int rows, int cols) => {'status': 'ok'};

  @override
  Map<String, dynamic> ptyWrite(String id, String data) {
    written.add(data);
    return {'status': 'ok'};
  }

  @override
  Map<String, dynamic> ptySnapshot(String id, {int sinceSeq = -1, int scrollback = 0}) {
    if (sinceSeq == 1) return {'status': 'ok', 'unchanged': true, 'seq': 1, 'alive': true};
    const history = total - rows;
    final offset = scrollback.clamp(0, history);
    final top = history - offset;
    return {
      'status': 'ok',
      'seq': 1,
      'alive': true,
      'rows': [
        for (var i = 0; i < rows; i++)
          [
            {'c': 0, 't': 'line ${top + i + 1}', 'fg': -1, 'bg': -1, 'a': 0},
          ],
      ],
      'wrapped': [for (var i = 0; i < rows; i++) false],
      'size': [rows, 40],
      'cursor': [4, 0],
      'cursor_visible': offset == 0,
      'scrollback': offset,
      'history': history,
      'alt_screen': false,
    };
  }
}

void main() {
  group('text', () {
    test('several lines: trailing blanks dropped, partial first / last lines, \\n between', () {
      final lines = {0: _line('hello world'), 1: _line('second'), 2: _line('third line')};
      const sel = TermSelection(TermPos(2, 4), TermPos(0, 6)); // 反着拖也一样
      expect(selectionText(sel, (l) => lines[l], 12), 'world\nsecond\nthird');
    });

    test('a soft-wrapped line joins the next one without a newline (long paths copy whole)', () {
      final lines = {0: _line('/Users/dev/W', wrapped: true), 1: _line('orker/a.java')};
      expect(selectionText(const TermSelection(TermPos(0, 0), TermPos(1, 11)), (l) => lines[l], 12), '/Users/dev/Worker/a.java');
    });

    test('wide characters copy once; missing lines stop the copy', () {
      final lines = {0: _line('找不到符号 x')};
      expect(selectionText(const TermSelection(TermPos(0, 0), TermPos(0, 11)), (l) => lines[l], 12), '找不到符号 x');
      expect(selectionText(const TermSelection(TermPos(0, 0), TermPos(3, 2)), (l) => lines[l], 12), '找不到符号 x');
    });

    test('double-click word: paths, dots and colons are part of it; brackets / spaces / quotes are not', () {
      final cells = _line('at "com.bcpoker.admin.Foo:12" [x]', cols: 40).cells;
      expect(wordRange(cells, 8), (4, 27), reason: 'com.bcpoker.admin.Foo:12');
      expect(wordRange(cells, 31), (31, 31));
      final cn = _line('位置 类', cols: 10).cells;
      expect(wordRange(cn, 1), (0, 3), reason: '点在宽字符后半格也算这个词');
    });
  });

  group('view', () {
    late _FakePty pty;
    late List<String> clipboard;

    Future<void> pump(WidgetTester tester) async {
      pty = _FakePty();
      clipboard = [];
      tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, (call) async {
        if (call.method == 'Clipboard.setData') clipboard.add((call.arguments as Map)['text'] as String);
        return null;
      });
      addTearDown(() => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(SystemChannels.platform, null));
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: SizedBox(width: 400, height: 140, child: TerminalView(sessionId: 't', client: pty, onExited: () {}, onLost: () {})),
        ),
      ));
      await tester.pump();
    }

    Future<void> done(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      await tester.runAsync(() => pty.dispose());
    }

    /// 第 [row] 行第 [col] 格的中心(内边距 + 单元格大小从视图里量出来)。
    Offset cell(WidgetTester tester, int row, int col) {
      final box = tester.getTopLeft(find.byType(TerminalView));
      final size = TerminalView.cellSizeOf(tester.element(find.byType(TerminalView)));
      const pad = TerminalView.padding;
      return box + Offset(pad + (col + 0.5) * size.width, pad + (row + 0.5) * size.height);
    }

    Future<void> copyKey(WidgetTester tester) async {
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
    }

    testWidgets('drag selects, ⌘C copies; a plain click clears; typing clears too', (tester) async {
      await pump(tester);
      final g = await tester.startGesture(cell(tester, 0, 0));
      await g.moveTo(cell(tester, 1, 2));
      await g.up();
      await tester.pump();
      await copyKey(tester);
      expect(clipboard.single, 'line 96\nlin');
      expect(pty.written, isEmpty, reason: '有选区时 ⌘C 只复制,不发给 shell');

      await tester.tapAt(cell(tester, 3, 3));
      await tester.pump(const Duration(milliseconds: 500));
      await copyKey(tester);
      expect(clipboard, hasLength(1), reason: '单击取消了选区,⌘C 什么也不复制');
      await done(tester);
    });

    testWidgets('double-click selects a word', (tester) async {
      await pump(tester);
      final at = cell(tester, 2, 1);
      await tester.tapAt(at);
      await tester.tapAt(at);
      await tester.pump();
      await copyKey(tester);
      expect(clipboard.last, 'line');
      await done(tester);
    });

    testWidgets('triple-click selects the whole line', (tester) async {
      await pump(tester);
      final at = cell(tester, 2, 1);
      await tester.tapAt(at);
      await tester.tapAt(at);
      await tester.tapAt(at);
      await tester.pump();
      await copyKey(tester);
      expect(clipboard.last, 'line 98');
      await done(tester);
    });

    testWidgets('select all copies the whole history, fetching the parts that are scrolled away', (tester) async {
      await pump(tester);
      await tester.tapAt(cell(tester, 0, 0));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyA);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      await tester.pump();
      await copyKey(tester);
      final lines = clipboard.single.split('\n');
      expect(lines, hasLength(100));
      expect(lines.first, 'line 1');
      expect(lines.last, 'line 100');
      await done(tester);
    });

    testWidgets('without a selection Ctrl+C still interrupts; typing a key clears a selection', (tester) async {
      await pump(tester);
      await tester.tapAt(cell(tester, 0, 0));
      await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
      expect(pty.written, ['\x03']);

      final g = await tester.startGesture(cell(tester, 1, 0)); // 另一行:不和上面的单击连成双击
      await g.moveTo(cell(tester, 0, 3));
      await g.up();
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      await copyKey(tester);
      expect(clipboard, isEmpty, reason: '回车发给 shell 时选区取消了');
      await tester.pump(const Duration(milliseconds: 50));
      await done(tester);
    });
  });
}
