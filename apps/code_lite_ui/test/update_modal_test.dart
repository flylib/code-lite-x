import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/update/update_modal.dart';

void main() {
  testWidgets('UpdateModal opens, displays release info, downloads and applies update', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = ApiClient();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                UpdateModal.show(
                  context,
                  client: client,
                  currentVersion: '0.1.0',
                );
              },
              child: const Text('Check for Updates'),
            ),
          ),
        ),
      ),
    );

    // Open Modal
    await tester.tap(find.text('Check for Updates'));
    await tester.pump();
    await tester.pumpAndSettle();

    // Verify Title and Versions
    expect(find.text('CodeLiteX Software Update'), findsOneWidget);
    expect(find.text('v0.1.0'), findsOneWidget);
    expect(find.text('v0.1.1'), findsOneWidget);
    expect(find.text('Release Notes:'), findsOneWidget);

    // Verify Strategy Badge
    expect(find.byType(UpdateModal), findsOneWidget);

    // Verify Download & Verify button
    expect(find.text('Download & Verify'), findsOneWidget);

    // Click Download & Verify
    await tester.tap(find.text('Download & Verify'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pumpAndSettle();

    // Verify Ready to Apply
    expect(find.text('Restart & Apply'), findsOneWidget);

    // Click Restart & Apply
    await tester.tap(find.text('Restart & Apply'));
    await tester.pump();
    await tester.pumpAndSettle();

    // Verify success banner and Done button
    expect(find.text('Done'), findsOneWidget);

    // Close Modal
    await tester.tap(find.text('Done'));
    await tester.pumpAndSettle();

    expect(find.text('CodeLiteX Software Update'), findsNothing);
  });
}
