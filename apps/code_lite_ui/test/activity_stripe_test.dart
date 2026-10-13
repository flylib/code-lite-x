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
    expect(top('Git 提交与日志 (Alt+9)'), lessThan(top('Debug (Shift+F9)')));
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
    expect(top('Maven'), lessThan(top('结构 (Alt+7)')));
    expect(find.byTooltip('项目 (Alt+1)'), findsNothing, reason: '左侧的工具窗不在右活动条');
    final active = {for (final b in tester.widgetList<StripeButton>(find.byType(StripeButton))) if (b.isActive) b.tooltip};
    expect(active, {'Maven'});
  });

  testWidgets('title bar (IntelliJ Islands): project and branch on the left; run config, run / debug, search and settings on the right', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var searched = 0, settings = 0;
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: TitleBarWidget(
          accent: const Color(0xFF4C8FD6),
          onSearch: () => searched++,
          onSettings: () => settings++,
          projectChip: const Text('PROJECT-CHIP'),
          branchChip: const Text('BRANCH-CHIP'),
        ),
      ),
    ));
    final project = tester.getTopLeft(find.text('PROJECT-CHIP')).dx;
    final branch = tester.getTopLeft(find.text('BRANCH-CHIP')).dx;
    final run = tester.getTopLeft(find.text('Current File')).dx;
    expect(project, lessThan(branch));
    expect(branch, lessThan(run));
    expect(run, greaterThan(600), reason: '运行配置在右半边');
    expect(find.text('Search...'), findsNothing, reason: '没有搜索框,右边是搜索图标');
    expect(find.byTooltip('运行 (⇧F10)'), findsOneWidget);
    expect(find.byTooltip('Debug (⇧F9)'), findsOneWidget);
    expect(tester.getTopLeft(find.byTooltip('搜索 (⇧⌘F)')).dx, greaterThan(tester.getTopLeft(find.byTooltip('Debug (⇧F9)')).dx));

    await tester.tap(find.byTooltip('搜索 (⇧⌘F)'));
    await tester.tap(find.byTooltip('设置 (⌘,)'));
    expect((searched, settings), (1, 1));
  });
}
