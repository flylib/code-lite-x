import 'package:code_lite_ui/features/project_explorer/structure_widget.dart';
import 'package:code_lite_ui/features/project_explorer/project_explorer_widget.dart';
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
    // 标题栏不再显示写死的项目名 / 版本徽标。
    expect(find.text('[Flutter + Rust]'), findsNothing);
    expect(find.text('v0.1.0'), findsNothing);
    expect(find.text('main'), findsWidgets);

    // 启动不再硬编码打开某个文件:恢复上次项目,没有就是空态,由 File → Open 进入项目。
    expect(find.text('planner.rs'), findsNothing);

    // 底部工具窗默认收起(启动时不跑 git log),从左侧条下半段打开。
    expect(find.text('Log'), findsNothing);
    expect(find.byTooltip('Git 提交与日志'), findsOneWidget);
    expect(find.byTooltip('操作记录与回滚'), findsNothing); // SQLite 回滚面板已移除
    expect(find.byTooltip('助手'), findsNothing); // AI 助手已移除
    expect(find.byTooltip('Commit (⌘0)'), findsOneWidget);

    // Cargo 工具窗已移除。
    expect(find.text('Cargo'), findsNothing);
  });

  testWidgets('right activity stripe has no Cargo tool window any more', (WidgetTester tester) async {
    await tester.binding.setSurfaceSize(const Size(1280, 800));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await tester.pumpWidget(const CodeLiteApp());
    await tester.pump();

    expect(find.byTooltip('Cargo'), findsNothing);
    expect(find.byTooltip('通知'), findsOneWidget);
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
    await tester.tap(find.byTooltip('结构 (⌘7)'));
    await tester.pump();
    expect(tester.getSize(find.byType(StructureWidget)).width, 370);

    // 拖得过窄会停在下限。
    await tester.drag(splitter, const Offset(-1000, 0));
    await tester.pump();
    expect(tester.getSize(find.byType(StructureWidget)).width, 160);

    // 最窄宽度下切回项目面板也不能溢出(溢出会作为异常让测试失败)。
    await tester.tap(find.byTooltip('项目 (⌘1)'));
    await tester.pump();
    expect(tester.getSize(panel).width, 160);
  });
}
