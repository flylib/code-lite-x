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

    // The right column starts closed — no tool window should pay FFI cost on boot.
    expect(find.text('CodeLite AI Assistant'), findsNothing);
    expect(find.text('Cargo'), findsNothing);
  });

  testWidgets('right activity stripe opens, swaps and collapses tool windows', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();

    // Nothing is docked on the right until asked for.
    expect(find.text('Cargo'), findsNothing);
    expect(find.text('CodeLite AI Assistant'), findsNothing);

    await tester.tap(find.byTooltip('Cargo'));
    await tester.pump();
    expect(find.text('Cargo'), findsOneWidget);

    // Picking another tool replaces it rather than stacking a second panel.
    await tester.tap(find.byTooltip('助手'));
    await tester.pump();
    expect(find.text('CodeLite AI Assistant'), findsOneWidget);
    expect(find.text('Cargo'), findsNothing);

    // Selecting the open tool again collapses the column.
    await tester.tap(find.byTooltip('助手'));
    await tester.pump();
    expect(find.text('CodeLite AI Assistant'), findsNothing);
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
