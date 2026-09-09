import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_lite_ui/app.dart';

void main() {
  testWidgets('CodeLiteApp basic layout renders correctly', (WidgetTester tester) async {
    // Set a desktop resolution
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();

    // Verify Title Bar
    expect(find.text('code-lite-x'), findsAtLeastNWidgets(1));
    expect(find.text('[Flutter + Rust]'), findsOneWidget);
    expect(find.text('main'), findsWidgets);

    // Verify Editor & Tabs
    expect(find.text('op_store.rs'), findsWidgets);

    // Verify Bottom Tools Tab
    expect(find.text('Git Log: HEAD'), findsOneWidget);
    expect(find.text('SQLite State & Rollback'), findsOneWidget);

    // Verify AI Agent drawer
    expect(find.text('CodeLite AI Assistant'), findsOneWidget);
  });
}
