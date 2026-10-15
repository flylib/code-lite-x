import 'package:code_lite_ui/features/project_explorer/structure_widget.dart';
import 'package:code_lite_ui/features/project_explorer/project_explorer_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:code_lite_ui/features/title_bar/project_menu.dart';
import 'package:code_lite_ui/app.dart';
import 'package:code_lite_ui/features/bottom_tools/bottom_tools_widget.dart';
import 'package:code_lite_ui/features/activity_stripe/activity_stripe_widget.dart';

void main() {
  testWidgets('CodeLiteApp basic layout renders correctly', (WidgetTester tester) async {
    // Set a desktop resolution
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();

    // Verify Title Bar
    // 标题栏不再显示写死的项目名 / 版本徽标。
    expect(find.text('[Flutter + Rust]'), findsNothing);
    expect(find.text('v0.1.0'), findsNothing);
    // 左边是项目入口(没打开项目时写 No Project;打开了就是项目名),不再有写死的 main 分支徽标。
    expect(find.byType(ProjectChip), findsOneWidget);
    expect(find.text('main'), findsNothing);

    // 启动不再硬编码打开某个文件:恢复上次项目,没有就是空态,由 File → Open 进入项目。
    expect(find.text('planner.rs'), findsNothing);

    // 底部工具窗默认收起(启动时不跑 git log),从左侧条下半段打开。
    expect(find.text('Log'), findsNothing);
    expect(find.byTooltip('Git 提交与日志 (Alt+9)'), findsOneWidget);
    expect(find.byTooltip('操作记录与回滚'), findsNothing); // SQLite 回滚面板已移除
    expect(find.byTooltip('助手'), findsNothing); // AI 助手已移除
    expect(find.byTooltip('Commit (Alt+0)'), findsOneWidget);

    // Cargo 工具窗已移除。
    expect(find.text('Cargo'), findsNothing);
  });

  testWidgets('the left stripe has an Opening Projects button that opens its panel (empty state with no project)', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();

    expect(find.byTooltip('Opening Projects'), findsOneWidget);
    expect(find.text('Opening'), findsNothing, reason: '面板默认不显示');
    await tester.tap(find.byTooltip('Opening Projects'));
    await tester.pump();
    expect(find.text('Opening'), findsOneWidget);
    expect(find.text('没有打开的项目'), findsOneWidget);
    // 再点一次收起,和别的工具窗一样
    await tester.tap(find.byTooltip('Opening Projects'));
    await tester.pump();
    expect(find.text('Opening'), findsNothing);
  });

  testWidgets('right activity stripe has no Cargo tool window any more', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();

    expect(find.byTooltip('Cargo'), findsNothing);
    expect(find.descendant(of: find.byType(RightStripeWidget), matching: find.byTooltip('通知')), findsOneWidget, reason: '通知在右活动条顶上');
  });

  testWidgets('left activity stripe collapses the project panel on re-tap', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();

    expect(find.text('Project'), findsWidgets);

    await tester.tap(find.byTooltip('项目 (Alt+1)'));
    await tester.pump();

    expect(find.text('Project'), findsNothing);
  });

  testWidgets('dragging the side splitter resizes the left tool window, shared across tools', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();

    final splitter = find.byWidgetPredicate((w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn);
    expect(splitter, findsOneWidget);
    final panel = find.byType(ProjectExplorerWidget);
    expect(tester.getSize(panel).width, 250);
    // 面板与分隔线紧贴,中间没有空隙。
    expect(tester.getTopLeft(splitter).dx, tester.getTopRight(panel).dx);

    await tester.drag(splitter, const Offset(120, 0));
    await tester.pump();
    expect(tester.getSize(panel).width, 370);

    // 切到结构面板,宽度沿用。
    await tester.tap(find.byTooltip('结构 (Alt+7)'));
    await tester.pump();
    expect(tester.getSize(find.byType(StructureWidget)).width, 370);

    // 拖得过窄会停在下限。
    await tester.drag(splitter, const Offset(-1000, 0));
    await tester.pump();
    expect(tester.getSize(find.byType(StructureWidget)).width, 160);

    // 最窄宽度下切回项目面板也不能溢出(溢出会作为异常让测试失败)。
    await tester.tap(find.byTooltip('项目 (Alt+1)'));
    await tester.pump();
    expect(tester.getSize(panel).width, 160);
  });

  testWidgets('a tool window moved to the right side docks right of the editor, with its own stripe and resizable width', (WidgetTester tester) async {
    // 拖动分隔线按窗口宽度算上限,所以要让 MediaQuery 也是 1280 宽(setSurfaceSize 只改渲染面)
    tester.view.physicalSize = const Size(1280, 800);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);

    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();
    expect(tester.getSize(find.byType(RightStripeWidget)).width, 40, reason: '右活动条始终显示(IntelliJ 的右侧栏)');
    expect(find.descendant(of: find.byType(RightStripeWidget), matching: find.byTooltip('通知')), findsOneWidget);

    // 打开结构,再用 ⋮ ▸ 移动到 ▸ 右侧上方
    await tester.tap(find.byTooltip('结构 (Alt+7)'));
    await tester.pump();
    await tester.tap(find.byTooltip('选项'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('移动到'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('右侧上方'));
    await tester.pumpAndSettle();

    final structure = find.byType(StructureWidget);
    expect(structure, findsOneWidget);
    expect(tester.getTopLeft(structure).dx, greaterThan(640), reason: '在编辑区右边');
    expect(tester.getTopRight(structure).dx, 1280 - 40 - 2, reason: '右活动条在最右,中间隔一条 2px 的缝');
    expect(tester.getSize(structure).width, 300);
    expect(find.byType(ProjectExplorerWidget), findsNothing, reason: '打开结构时顶替了左上方的项目视图,结构搬走后左边是空的');
    await tester.tap(find.byTooltip('项目 (Alt+1)'));
    await tester.pump();
    expect(find.byType(ProjectExplorerWidget), findsOneWidget, reason: '左右可以同时开着');
    expect(structure, findsOneWidget);
    expect(find.descendant(of: find.byType(RightStripeWidget), matching: find.byTooltip('结构 (Alt+7)')), findsOneWidget);

    // 拖右侧分隔线向左 = 变宽
    final splitter = find.byWidgetPredicate((w) => w is MouseRegion && w.cursor == SystemMouseCursors.resizeColumn);
    expect(splitter, findsNWidgets(2));
    final rightSplitter = tester.getTopLeft(splitter.at(1)).dx > 640 ? splitter.at(1) : splitter.at(0);
    // 岛与岛之间的缝就是分隔线(5px),紧贴面板
    expect(tester.getSize(rightSplitter).width, 5);
    expect(tester.getTopRight(rightSplitter).dx, tester.getTopLeft(structure).dx);
    await tester.drag(rightSplitter, const Offset(-100, 0));
    await tester.pump();
    expect(tester.getSize(structure).width, 400);
    expect(tester.getSize(find.byType(ProjectExplorerWidget)).width, 250, reason: '左侧宽度不受影响');

    // 底部工具窗横跨两条活动条之间的整个宽度,右侧工具窗停在它上面(IntelliJ 的布局)
    await tester.tap(find.byTooltip('终端 (Alt+F12)'));
    await tester.pump();
    final bottom = find.byType(BottomToolsWidget);
    expect(tester.getTopLeft(bottom).dx, 40);
    expect(tester.getTopRight(bottom).dx, 1280 - 40 - 2);
    expect(tester.getBottomLeft(structure).dy, lessThan(tester.getTopLeft(bottom).dy));
    await tester.tap(find.byTooltip('终端 (Alt+F12)'));
    await tester.pump();

    // 点右活动条的按钮收起它,右活动条的按钮还在
    await tester.tap(find.descendant(of: find.byType(RightStripeWidget), matching: find.byTooltip('结构 (Alt+7)')));
    await tester.pump();
    expect(structure, findsNothing);
    expect(find.descendant(of: find.byType(RightStripeWidget), matching: find.byTooltip('结构 (Alt+7)')), findsOneWidget);
    expect(splitter, findsOneWidget);
  });
}
