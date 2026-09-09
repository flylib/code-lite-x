import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/search/global_search_modal.dart';

void main() {
  testWidgets('GlobalSearchModal renders search, toggles and replace inputs', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1000, 700));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    final client = ApiClient();

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () {
                GlobalSearchModal.show(
                  context,
                  client: client,
                  onNavigate: (_, __) {},
                );
              },
              child: const Text('Open Search'),
            ),
          ),
        ),
      ),
    );

    // Open Modal
    await tester.tap(find.text('Open Search'));
    await tester.pumpAndSettle();

    // Verify Title and Controls
    expect(find.text('Find in Files'), findsOneWidget);
    expect(find.text('(Cmd+Shift+F)'), findsOneWidget);
    expect(find.text('Cc'), findsOneWidget);
    expect(find.text('W'), findsOneWidget);
    expect(find.text('.*'), findsOneWidget);
    expect(find.text('Find'), findsOneWidget);
    expect(find.text('Replace Mode'), findsOneWidget);

    // Toggle Replace Mode
    await tester.tap(find.text('Replace Mode'));
    await tester.pumpAndSettle();

    expect(find.text('Replace in Files'), findsOneWidget);
    expect(find.text('Replace All'), findsOneWidget);
    expect(find.text('Hide Replace'), findsOneWidget);

    // Close Dialog
    await tester.tap(find.byIcon(Icons.close));
    await tester.pumpAndSettle();

    expect(find.text('Find in Files'), findsNothing);
  });
}
