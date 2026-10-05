import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/status_bar/status_bar_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _StatusClient extends ApiClient {
  _StatusClient() : super(initialRoot: '.');
  List<Map<String, dynamic>> servers = [];

  @override
  Future<Map<String, dynamic>> lspStatus() async => {'servers': servers};
}

void main() {
  late _StatusClient client;
  setUp(() => client = _StatusClient());
  tearDown(() async => client.dispose());

  Future<void> pump(WidgetTester tester, String file) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(body: StatusBarWidget(activeFile: file, diagnostics: const [], client: client)),
    ));
    await tester.pump();
  }

  testWidgets('shows the server of the current file language, not a hard-coded rust-analyzer', (tester) async {
    client.servers = [
      {'language': 'rust', 'command': '/Users/x/.cargo/bin/rust-analyzer', 'state': 'running', 'initialized': true},
      {'language': 'go', 'command': '/Users/x/go/bin/gopls', 'state': 'running', 'initialized': true},
    ];
    await pump(tester, 'internal/api/clientlog.go');
    expect(find.text('gopls'), findsOneWidget);
    expect(find.text('rust-analyzer'), findsNothing);

    await pump(tester, 'src/main.rs');
    await tester.pump(const Duration(seconds: 2));
    expect(find.text('rust-analyzer'), findsOneWidget);
    await tester.pumpWidget(const SizedBox());
  });

  testWidgets('starting / missing / crashed states, jdtls name, and nothing for files without a server', (tester) async {
    client.servers = [
      {'language': 'go', 'command': '/Users/x/go/bin/gopls', 'state': 'running', 'initialized': false},
    ];
    await pump(tester, 'a.go');
    expect(find.text('gopls 启动中…'), findsOneWidget);

    client.servers = [
      {'language': 'go', 'command': 'gopls', 'state': 'missing', 'initialized': false},
    ];
    await tester.pump(const Duration(seconds: 2));
    await tester.pump();
    expect(find.text('未安装 gopls'), findsOneWidget);

    client.servers = [
      {'language': 'java', 'command': '/opt/jdk/bin/java -jar launcher.jar', 'state': 'crashed', 'initialized': false, 'error': 'exited with code 1'},
    ];
    await pump(tester, 'A.java');
    expect(find.text('jdtls 已退出'), findsOneWidget);

    await pump(tester, 'README.md');
    expect(find.byType(LspStatusChip), findsNothing, reason: 'Markdown 没有语言服务器');
    await pump(tester, '');
    expect(find.byType(LspStatusChip), findsNothing, reason: '没打开文件');
    await tester.pumpWidget(const SizedBox());
  });
}
