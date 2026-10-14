import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/core/ffi/pty_frame.dart';
import 'package:code_lite_ui/features/terminal/terminal_view.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 假终端:100 行历史,屏幕 5 行;记下每次读取要的回滚偏移,偏移按 vt100 的规则夹到 [0, 95]。
class _FakePty extends ApiClient {
  _FakePty() : super(initialRoot: '.');

  int seq = 1;
  int offset = 0;
  final List<int> requested = [];

  @override
  Map<String, dynamic> ptyResize(String id, int rows, int cols) => {'status': 'ok'};

  /// 界面取画面走二进制帧;假终端用自己的 JSON 快照转一帧(整屏)。
  @override
  PtyFrame ptyFrame(String id, {int sinceSeq = -1, int scrollback = 0}) =>
      PtyFrame.fromSnapshot(ptySnapshot(id, sinceSeq: sinceSeq, scrollback: scrollback));

  @override
  Map<String, dynamic> ptyWrite(String id, String data) => {'status': 'ok'};

  @override
  Map<String, dynamic> ptySnapshot(String id, {int sinceSeq = -1, int scrollback = 0}) {
    if (sinceSeq == seq) return {'status': 'ok', 'unchanged': true, 'seq': seq, 'alive': true};
    requested.add(scrollback);
    offset = scrollback.clamp(0, 95);
    final top = 96 - offset;
    return {
      'status': 'ok',
      'seq': seq,
      'alive': true,
      'rows': [
        for (var i = 0; i < 5; i++)
          [
            {'c': 0, 't': 'line ${top + i}', 'fg': -1, 'bg': -1, 'a': 0},
          ],
      ],
      'size': [5, 40],
      'cursor': [4, 0],
      'cursor_visible': offset == 0,
      'scrollback': offset,
      'alt_screen': false,
    };
  }
}

void main() {
  testWidgets('history scrolls with the mouse wheel and with a two-finger trackpad pan; small steps add up', (tester) async {
    final pty = _FakePty();
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 400,
          height: 200,
          child: TerminalView(sessionId: 't', client: pty, onExited: () {}, onLost: () {}),
        ),
      ),
    ));
    await tester.pump();
    final center = tester.getCenter(find.byType(TerminalView));
    expect(pty.offset, 0);

    // 鼠标滚轮往上:翻历史
    final mouse = TestPointer(1, PointerDeviceKind.mouse);
    await tester.sendEventToBinding(mouse.hover(center));
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -200)));
    await tester.pump();
    expect(pty.offset, greaterThan(5), reason: '滚轮往上翻');
    final afterWheel = pty.offset;

    // macOS 触控板双指:pan/zoom 手势,手指往下 = 往上翻;每次只动几个像素也要累计起来
    final pad = TestPointer(2, PointerDeviceKind.trackpad);
    await tester.sendEventToBinding(pad.panZoomStart(center));
    for (var i = 1; i <= 40; i++) {
      await tester.sendEventToBinding(pad.panZoomUpdate(center, pan: Offset(0, 4.0 * i)));
    }
    await tester.sendEventToBinding(pad.panZoomEnd());
    await tester.pump();
    expect(pty.offset, greaterThan(afterWheel), reason: '触控板往上翻(160px 攒成好几行)');

    // 翻到顶:夹在最早一行;再往回滚立刻就动
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, -100000)));
    await tester.pump();
    expect(pty.offset, 95);
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 60)));
    await tester.pump();
    expect(pty.offset, lessThan(95));

    // 一直往下滚回到底部
    await tester.sendEventToBinding(mouse.scroll(const Offset(0, 100000)));
    await tester.pump();
    expect(pty.offset, 0);

    await tester.pumpWidget(const SizedBox());
    await tester.runAsync(() => pty.dispose());
  });
}
