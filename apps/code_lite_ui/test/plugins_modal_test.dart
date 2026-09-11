import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/plugins/plugins_modal.dart';

void main() {
  testWidgets('PluginsModal renders plugins list, allows toggle, tool testing and install demo', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = ApiClient();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                PluginsModal.show(context, client: client);
              },
              child: const Text('Open Plugins'),
            ),
          ),
        ),
      ),
    );

    // 1. Open Modal
    await tester.tap(find.text('Open Plugins'));
    await tester.pump();
    await tester.pumpAndSettle();

    // 2. Verify Modal Header & Plugins
    expect(find.text('CodeLiteX 插件中心 (WASM Sandboxed Plugins)'), findsOneWidget);
    expect(find.text('SQL Inspector'), findsOneWidget);
    expect(find.text('Custom Linter'), findsOneWidget);

    // 3. Search filter
    await tester.enterText(find.byType(TextField).first, 'sql');
    await tester.pumpAndSettle();
    expect(find.text('SQL Inspector'), findsOneWidget);
    expect(find.text('Custom Linter'), findsNothing);

    // Clear search
    await tester.enterText(find.byType(TextField).first, '');
    await tester.pumpAndSettle();
    expect(find.text('SQL Inspector'), findsOneWidget);
    expect(find.text('Custom Linter'), findsOneWidget);

    // 4. Toggle plugin switch off and then back on
    final switchFinder = find.byType(Switch).first;
    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(find.text('已禁用'), findsAtLeastNWidgets(1));

    await tester.tap(switchFinder);
    await tester.pumpAndSettle();
    expect(find.text('已启用'), findsAtLeastNWidgets(1));

    // 5. Open tool tester for inspect_sql
    final inspectToolFinder = find.text('inspect_sql');
    expect(inspectToolFinder, findsOneWidget);
    await tester.tap(inspectToolFinder);
    await tester.pumpAndSettle();

    expect(find.text('测试插件工具: inspect_sql'), findsOneWidget);
    expect(find.text('在沙箱中执行工具'), findsOneWidget);

    // 6. Execute tool
    await tester.tap(find.text('在沙箱中执行工具'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.byType(SelectableText), findsOneWidget);

    // Back to plugins list
    await tester.tap(find.byIcon(Icons.arrow_back));
    await tester.pumpAndSettle();
    expect(find.text('SQL Inspector'), findsOneWidget);

    // 7. Click Install Demo WASM Plugin
    await tester.tap(find.text('安装示例 WASM 插件'));
    await tester.pump();
    await tester.pumpAndSettle();

    expect(find.text('Regex Optimizer (WASM)'), findsOneWidget);
  });
}
