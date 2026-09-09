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

    // Verify Editor & Tabs — seeded file matches design/Main.dc.html
    expect(find.text('planner.rs'), findsWidgets);

    // Verify Bottom Tools Tab
    expect(find.text('Git Log: HEAD'), findsOneWidget);
    expect(find.text('SQLite State & Rollback'), findsOneWidget);

    // Verify AI Agent drawer
    expect(find.text('CodeLite AI Assistant'), findsOneWidget);
  });

  testWidgets('right activity stripe swaps the right tool window', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();

    // The assistant is the default right tool window.
    expect(find.text('CodeLite AI Assistant'), findsOneWidget);
    expect(find.text('Cargo'), findsNothing);

    // Selecting Cargo replaces it rather than stacking another panel.
    await tester.tap(find.byTooltip('Cargo'));
    await tester.pump();

    expect(find.text('Cargo'), findsOneWidget);
    expect(find.text('CodeLite AI Assistant'), findsNothing);

    // Selecting the same tool again collapses the column.
    await tester.tap(find.byTooltip('Cargo'));
    await tester.pump();

    expect(find.text('Cargo'), findsNothing);
  });

  testWidgets('left activity stripe collapses the project panel on re-tap', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();

    expect(find.text('Project'), findsWidgets);

    await tester.tap(find.byTooltip('项目 (⌘1)'));
    await tester.pump();

    expect(find.text('Project'), findsNothing);
  });
}
