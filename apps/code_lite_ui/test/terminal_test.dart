import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/terminal/terminal_store.dart';
import 'package:code_lite_ui/features/terminal/terminal_view.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 把 snapshot 的 run 拼回纯文本,便于断言。
String screenText(Map<String, dynamic> snap) => ((snap['rows'] as List?) ?? const [])
    .map((row) => (row as List).map((r) => r['t'] as String).join())
    .join('\n');

void main() {
  final client = ApiClient();

  test('PTY round trip: shell keeps cwd and env between commands', () async {
    if (!client.isFfiAvailable) return; // 没编出 dylib 时跳过
    final open = client.ptyOpen(24, 80);
    expect(open['status'], 'ok');
    final id = open['id'] as String;
    addTearDown(() => client.ptyClose(id));

    client.ptyWrite(id, 'cd / && export CLX_DART=ok\r');
    client.ptyWrite(id, r'echo "dart_$CLX_DART:$PWD"' '\r');

    var text = '';
    for (var i = 0; i < 200 && !text.contains('dart_ok:/'); i++) {
      await Future<void>.delayed(const Duration(milliseconds: 50));
      text = screenText(client.ptySnapshot(id));
    }
    expect(text, contains('dart_ok:/'));

    final seq = client.ptySnapshot(id)['seq'] as int;
    expect(client.ptySnapshot(id, sinceSeq: seq)['unchanged'], isTrue);

    expect(client.ptyClose(id)['status'], 'ok');
    expect(client.ptySnapshot(id)['status'], 'error');
  });

  testWidgets('typing on the terminal screen runs the command (no input box)', (tester) async {
    if (!client.isFfiAvailable) return;
    final store = TerminalStore(client);
    addTearDown(store.dispose);

    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: SizedBox(
          width: 800,
          height: 300,
          child: TerminalPanel(store: store, client: client, onHide: () {}),
        ),
      ),
    ));
    await tester.pump(); // _AutoOpen 在帧后开会话
    await tester.pump();
    expect(store.sessions, hasLength(1));
    expect(find.text('Local'), findsOneWidget);
    expect(find.byType(TextField), findsNothing);

    // 文本经输入法通道上屏,回车走按键通道 —— 和 macOS 上真实打字一样。
    await tester.tap(find.byType(TerminalView));
    await tester.pump();
    tester.testTextInput.enterText(r'echo clx_$((40+2))');
    await tester.sendKeyEvent(LogicalKeyboardKey.enter);

    final id = store.current!.id;
    var text = '';
    await tester.runAsync(() async {
      for (var i = 0; i < 200 && !text.contains('clx_42'); i++) {
        await Future<void>.delayed(const Duration(milliseconds: 50));
        text = screenText(client.ptySnapshot(id));
      }
    });
    expect(text, contains('clx_42'));

    // 停掉视图里的轮询计时器,避免测试结束时还挂着 Timer。
    await tester.pumpWidget(const SizedBox());
  });
}
