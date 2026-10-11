import 'package:code_lite_ui/features/activity_stripe/activity_stripe_widget.dart';
import 'package:code_lite_ui/features/bottom_tools/bottom_tools_widget.dart';
import 'package:code_lite_ui/features/title_bar/title_bar_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget _stripe({bool notification = false}) => MaterialApp(
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
              hasNotification: notification,
            ),
          ],
        ),
      ),
    );

void main() {
  testWidgets('debug and notifications sit at the bottom of the left stripe, below Git', (tester) async {
    tester.view.physicalSize = const Size(800, 560);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(_stripe());
    expect(tester.takeException(), isNull, reason: '矮窗口下八个按钮也放得下');

    double top(String tooltip) => tester.getTopLeft(find.byTooltip(tooltip)).dy;
    expect(find.byTooltip('Debug (Shift+F9)'), findsOneWidget);
    expect(find.byTooltip('通知'), findsOneWidget);
    expect(top('Git 提交与日志'), lessThan(top('Debug (Shift+F9)')));
    expect(top('Debug (Shift+F9)'), lessThan(top('通知')));
    // the bell is the lowest button, close to the bottom edge of the stripe
    expect(tester.getBottomLeft(find.byTooltip('通知')).dy, greaterThan(560 - 60));
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
