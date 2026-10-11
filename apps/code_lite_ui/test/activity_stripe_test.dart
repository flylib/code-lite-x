import 'package:code_lite_ui/features/activity_stripe/activity_stripe_widget.dart';
import 'package:code_lite_ui/features/activity_stripe/stripe_button.dart';
import 'package:code_lite_ui/features/bottom_tools/bottom_tools_widget.dart';
import 'package:code_lite_ui/features/title_bar/title_bar_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _stripe() => MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            ActivityStripeWidget(
              leftTool: SideTool.project,
              isLeftOpen: true,
              bottomTab: BottomToolTab.terminal,
              isBottomOpen: false,
              onSelectTool: (_) {},
              onSelectBottomTab: (_) {},
            ),
          ],
        ),
      ),
    );

void main() {
  testWidgets('debug sits at the bottom of the left stripe, below Git; notifications moved to the right stripe', (tester) async {
    tester.view.physicalSize = const Size(800, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_stripe());
    expect(tester.takeException(), isNull, reason: '矮窗口下按钮也放得下');

    double top(String tooltip) => tester.getTopLeft(find.byTooltip(tooltip)).dy;
    expect(find.byTooltip('Debug (Shift+F9)'), findsOneWidget);
    expect(find.byTooltip('通知'), findsNothing, reason: '通知在右活动条(IntelliJ 的位置)');
    expect(top('Git 提交与日志'), lessThan(top('Debug (Shift+F9)')));
    expect(tester.getBottomLeft(find.byTooltip('Debug (Shift+F9)')).dy, greaterThan(560 - 60));
  });

  testWidgets('right stripe: bell on top, then right-docked tools, a divider, then the bottom-slot ones', (tester) async {
    final place = {
      SideTool.build: (ToolSide.right, ToolSlot.top),
      SideTool.structure: (ToolSide.right, ToolSlot.bottom),
    };
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(
          children: [
            const Spacer(),
            RightStripeWidget(
              visibleTools: const {SideTool.build},
              sideOf: (t) => place[t]?.$1 ?? ToolSide.left,
              slotOf: (t) => place[t]?.$2 ?? ToolSlot.top,
              onSelectTool: (_) {},
              buildToolTitle: 'Maven',
              hasNotification: true,
            ),
          ],
        ),
      ),
    ));
    double top(String tooltip) => tester.getTopLeft(find.byTooltip(tooltip)).dy;
    expect(top('通知'), lessThan(top('Maven')));
    expect(top('Maven'), lessThan(top('结构 (⌘7)')));
    expect(find.byTooltip('项目 (⌘1)'), findsNothing, reason: '左侧的工具窗不在右活动条');
    final active = {for (final b in tester.widgetList<StripeButton>(find.byType(StripeButton))) if (b.isActive) b.tooltip};
    expect(active, {'Maven'});
  });

  testWidgets('the title bar shows the project and branch chips left of the file name', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TitleBarWidget(
          activeFile: 'src/main.rs',
          onUndo: () {},
          onRedo: () {},
          projectChip: const Text('PROJECT-CHIP'),
          branchChip: const Text('BRANCH-CHIP'),
        ),
      ),
    ));
    final project = tester.getTopLeft(find.text('PROJECT-CHIP')).dx;
    final branch = tester.getTopLeft(find.text('BRANCH-CHIP')).dx;
    final file = tester.getTopLeft(find.text('src/main.rs')).dx;
    expect(project, lessThan(branch));
    expect(branch, lessThan(file));
    expect(find.text('main'), findsNothing, reason: '不再有写死的 main');
  });

  testWidgets('the title bar no longer has a Debug button, Run stays', (tester) async {
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TitleBarWidget(activeFile: '', onUndo: () {}, onRedo: () {}, onSearch: () {}),
      ),
    ));
    expect(find.byTooltip('Debug (Shift+F9)'), findsNothing);
    expect(find.byTooltip('Run (Shift+F10)'), findsOneWidget);
  });
}
