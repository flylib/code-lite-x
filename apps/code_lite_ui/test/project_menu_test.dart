import 'package:code_lite_ui/core/theme/intellij_theme.dart';
import 'package:code_lite_ui/features/title_bar/project_menu.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

Widget host(Widget chip) => MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topLeft, child: chip)));

void main() {
  test('badge letters: first and last word, or the first two letters of one word', () {
    expect(projectInitials('bcpoker_data_archiving'), 'BA');
    expect(projectInitials('bcpoker_game_server'), 'BS');
    expect(projectInitials('bcpoker-claude-skills'), 'BS');
    expect(projectInitials('bcpoker_proto'), 'BP');
    expect(projectInitials('bcpoker-webserver'), 'BW');
    expect(projectInitials('rail-ticket-hunter'), 'RH');
    expect(projectInitials('code'), 'CO');
    expect(projectInitials('x'), 'X');
    expect(projectInitials('__'), '?');
    expect(projectInitials(''), '?');
  });

  test('a project keeps its colour', () {
    expect(projectColor('bcpoker_admin'), projectColor('bcpoker_admin'));
    final colours = {for (final n in ['a', 'b', 'c', 'd', 'e', 'f', 'g', 'h', 'i', 'j']) projectColor(n)};
    expect(colours.length, greaterThan(3));
  });

  test('paths under the home folder are shortened', () {
    expect(abbreviatePath('/Users/dev/Worker/java/app', '/Users/dev'), '~/Worker/java/app');
    expect(abbreviatePath('/Users/dev', '/Users/dev'), '~');
    expect(abbreviatePath('/Users/devious/x', '/Users/dev'), '/Users/devious/x', reason: '不是同一个目录前缀');
    expect(abbreviatePath('/opt/app', '/Users/dev'), '/opt/app');
    expect(abbreviatePath('/opt/app', null), '/opt/app');
    expect(projectNameOf('/a/b/c/'), 'c');
  });

  testWidgets('the popup lists New/Open/Clone, the open project and the recent ones, and switches on tap', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(host(ProjectChip(
      projectPath: '/Users/dev/Worker/java/bcpoker_data_archiving',
      recent: const [
        '/Users/dev/Worker/java/bcpoker_data_archiving', // the open one is not listed twice
        '/Users/dev/Worker/java/bcpoker_proto',
        '/Users/dev/Worker/java/bcpoker_pay',
      ],
      home: '/Users/dev',
      onSwitch: (p) => calls.add('switch $p'),
      onNewProject: () => calls.add('new'),
      onOpen: () => calls.add('open'),
      onClone: () => calls.add('clone'),
    )));

    expect(find.text('bcpoker_data_archiving'), findsOneWidget);
    expect(find.text('BA'), findsOneWidget);

    await tester.tap(find.text('bcpoker_data_archiving'));
    await tester.pumpAndSettle();
    expect(find.text('New Project…'), findsOneWidget);
    expect(find.text('Open…'), findsOneWidget);
    expect(find.text('Clone Repository…'), findsOneWidget);
    expect(find.text('Open Projects'), findsOneWidget);
    expect(find.text('Recent Projects'), findsOneWidget);
    expect(find.text('bcpoker_data_archiving'), findsNWidgets(2), reason: '标题栏一个 + 弹窗里的已打开项目一个');
    expect(find.text('~/Worker/java/bcpoker_proto'), findsOneWidget);

    await tester.tap(find.text('bcpoker_proto'));
    await tester.pumpAndSettle();
    expect(calls, ['switch /Users/dev/Worker/java/bcpoker_proto']);
    expect(find.text('Recent Projects'), findsNothing, reason: '选完就关闭');

    for (final (label, expected) in [('New Project…', 'new'), ('Open…', 'open'), ('Clone Repository…', 'clone')]) {
      await tester.tap(find.text('bcpoker_data_archiving'));
      await tester.pumpAndSettle();
      await tester.tap(find.text(label));
      await tester.pumpAndSettle();
      expect(calls.last, expected);
    }
  });

  testWidgets('with no project the chip says so and the list has only the recent ones', (tester) async {
    await tester.pumpWidget(host(ProjectChip(
      projectPath: null,
      recent: const ['/a/one'],
      onSwitch: (_) {},
      onNewProject: () {},
      onOpen: () {},
      onClone: () {},
    )));
    expect(find.text('No Project'), findsOneWidget);
    await tester.tap(find.text('No Project'));
    await tester.pumpAndSettle();
    expect(find.text('Open Projects'), findsNothing);
    expect(find.text('Recent Projects'), findsOneWidget);
    expect(find.text('one'), findsOneWidget);
  });

  testWidgets('Esc and a click outside close the popup', (tester) async {
    await tester.pumpWidget(host(ProjectChip(
      projectPath: '/p/app',
      recent: const [],
      onSwitch: (_) {},
      onNewProject: () {},
      onOpen: () {},
      onClone: () {},
    )));
    await tester.tap(find.text('app'));
    await tester.pumpAndSettle();
    expect(find.text('Open…'), findsOneWidget);
    await tester.sendKeyEvent(LogicalKeyboardKey.escape);
    await tester.pumpAndSettle();
    expect(find.text('Open…'), findsNothing);

    await tester.tap(find.text('app'));
    await tester.pumpAndSettle();
    await tester.tapAt(const Offset(700, 500));
    await tester.pumpAndSettle();
    expect(find.text('Open…'), findsNothing);
  });

  testWidgets('the popup lists every open project (the current one marked), and the recent list leaves the open ones out', (tester) async {
    final calls = <String>[];
    await tester.pumpWidget(host(ProjectChip(
      projectPath: '/w/beta',
      openProjects: const ['/w/alpha', '/w/beta', '/w/gamma'],
      recent: const ['/w/beta', '/w/delta', '/w/alpha', '/w/epsilon'],
      home: '/w',
      onSwitch: (p) => calls.add('switch ${projectNameOf(p)}'),
      onNewProject: () {},
      onOpen: () {},
      onClone: () {},
    )));
    await tester.tap(find.text('beta'));
    await tester.pumpAndSettle();
    expect(find.text('Open Projects'), findsOneWidget);
    expect(find.text('Recent Projects'), findsOneWidget);
    expect(find.text('alpha'), findsOneWidget);
    expect(find.text('gamma'), findsOneWidget);
    expect(find.text('delta'), findsOneWidget, reason: '只在最近列表里的');
    expect(find.text('epsilon'), findsOneWidget);
    expect(find.text('~/alpha'), findsOneWidget, reason: 'alpha 既在打开的里面也在最近里,只列一次(在打开的里)');

    await tester.tap(find.text('gamma'));
    await tester.pumpAndSettle();
    expect(calls, ['switch gamma'], reason: '点已打开的项目就是切换');
  });

  group('project search', () {
    const home = '/Users/dev';
    const admin = '/Users/dev/Worker/java/bcpoker_admin';
    const archiving = '/Users/dev/Worker/java/bcpoker_data_archiving';
    const proto = '/Users/dev/Worker/java/bcpoker_proto';
    const rail = '/Users/dev/go/rail-ticket-hunter';

    test('matching: name prefix > name contains > name subsequence > path contains > path subsequence', () {
      expect(projectMatchScore('bcp', admin, home: home), 0);
      expect(projectMatchScore('ADM', admin, home: home), 1, reason: '不分大小写,名字里包含');
      expect(projectMatchScore('ticket', rail, home: home), 1);
      expect(projectMatchScore('bpa', admin, home: home), 2, reason: '名字里按顺序出现');
      expect(projectMatchScore('worker', admin, home: home), 3, reason: '路径里包含');
      expect(projectMatchScore('ad', archiving, home: home), 4, reason: '截图里的 ad:路径里 java 的 a 在前、data 的 d 在后');
      expect(projectMatchScore('zzz', admin, home: home), isNull);
      expect(projectMatchScore('', admin, home: home), 0);
      expect(projectMatchScore('  ', admin, home: home), 0);
      expect(projectMatchScore('dev', admin, home: home), isNull, reason: '~ 缩写后 home 不在显示的路径里,不拿它凑数');
    });

    test('filtering keeps only matches, best first, ties in the original (most recent first) order', () {
      expect(filterProjects('ad', [archiving, admin, proto, rail], home: home), [admin, archiving]);
      expect(filterProjects('bcpoker', [rail, proto, admin, archiving], home: home), [proto, admin, archiving]);
      expect(filterProjects('', [proto, rail], home: home), [proto, rail]);
      expect(filterProjects('nothing', [proto, rail], home: home), isEmpty);
    });

    Future<void> openPopup(WidgetTester tester, List<String> calls, {String? current = admin}) async {
      await tester.pumpWidget(host(ProjectChip(
        projectPath: current,
        recent: const [admin, archiving, proto, rail],
        home: home,
        onSwitch: (p) => calls.add('switch ${projectNameOf(p)}'),
        onNewProject: () => calls.add('new'),
        onOpen: () => calls.add('open'),
        onClone: () => calls.add('clone'),
      )));
      await tester.tap(find.text(current == null ? 'No Project' : projectNameOf(current)));
      await tester.pumpAndSettle();
    }

    testWidgets('the search box is focused as the popup opens: typing filters at once, headers and actions follow the query', (tester) async {
      final calls = <String>[];
      await openPopup(tester, calls);
      expect(find.byType(TextField), findsOneWidget);
      expect(tester.widget<TextField>(find.byType(TextField)).focusNode?.hasFocus ?? true, isTrue);
      expect(find.text('New Project…'), findsOneWidget);
      expect(find.text('rail-ticket-hunter'), findsOneWidget);

      // 不用先点输入框,直接敲
      await tester.enterText(find.byType(TextField), 'a');
      await tester.pumpAndSettle();
      expect(find.text('rail-ticket-hunter'), findsOneWidget, reason: 'a 能按顺序在名字里找到');
      await tester.enterText(find.byType(TextField), 'ad');
      await tester.pumpAndSettle();
      expect(find.text('New Project…'), findsNothing, reason: '没有操作匹配 ad');
      expect(find.text('Open Projects'), findsOneWidget);
      expect(find.text('Recent Projects'), findsOneWidget);
      expect(find.text('bcpoker_data_archiving'), findsOneWidget);
      expect(find.text('~/Worker/java/bcpoker_data_archiving'), findsOneWidget);
      expect(find.text('bcpoker_proto'), findsNothing);
      expect(find.text('rail-ticket-hunter'), findsNothing);
      expect(find.text('bcpoker_admin'), findsNWidgets(2), reason: '标题栏一个 + 弹窗里已打开的一个');

      // 操作也按名字过滤
      await tester.enterText(find.byType(TextField), 'clo');
      await tester.pumpAndSettle();
      expect(find.text('Clone Repository…'), findsOneWidget);
      expect(find.text('Open…'), findsNothing);
      expect(find.text('Open Projects'), findsNothing);

      await tester.enterText(find.byType(TextField), 'qqq');
      await tester.pumpAndSettle();
      expect(find.text('没有匹配的项目'), findsOneWidget);

      // × 清空,回到完整列表
      await tester.tap(find.byTooltip('清除'));
      await tester.pumpAndSettle();
      expect(find.text('New Project…'), findsOneWidget);
      expect(find.text('rail-ticket-hunter'), findsOneWidget);
      expect(find.byTooltip('清除'), findsNothing);
    });

    testWidgets('Enter opens the highlighted match (the first one by default); arrow keys move the highlight', (tester) async {
      final calls = <String>[];
      await openPopup(tester, calls, current: rail);
      await tester.enterText(find.byType(TextField), 'bcpoker');
      await tester.pumpAndSettle();
      // 高亮在第一个匹配上
      Finder highlighted() => find.byWidgetPredicate((w) => w is Container && w.color == IntelliJTheme.selectionBg);
      expect(highlighted(), findsOneWidget);
      expect(find.descendant(of: highlighted(), matching: find.text('bcpoker_admin')), findsOneWidget);

      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(find.descendant(of: highlighted(), matching: find.text('bcpoker_data_archiving')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.pump();
      expect(find.descendant(of: highlighted(), matching: find.text('bcpoker_admin')), findsOneWidget, reason: '到底回到顶部');
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowUp);
      await tester.pump();
      expect(find.descendant(of: highlighted(), matching: find.text('bcpoker_proto')), findsOneWidget, reason: '往上从顶部绕到底部');

      await tester.testTextInput.receiveAction(TextInputAction.done); // 键盘回车走文本输入通道
      await tester.pumpAndSettle();
      expect(calls, ['switch bcpoker_proto']);
      expect(find.byType(TextField), findsNothing, reason: '选完就关闭');
    });

    testWidgets('typing then Enter switches to the first match; Enter with no matches does nothing; changing the query resets the highlight', (tester) async {
      final calls = <String>[];
      await openPopup(tester, calls);
      await tester.enterText(find.byType(TextField), 'proto');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(calls, ['switch bcpoker_proto']);

      calls.clear();
      await tester.tap(find.text('bcpoker_admin'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'bcpoker');
      await tester.pumpAndSettle();
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.sendKeyEvent(LogicalKeyboardKey.arrowDown);
      await tester.enterText(find.byType(TextField), 'bcpoker_p');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(calls, ['switch bcpoker_proto'], reason: '改了查询,高亮回到第一个匹配');

      calls.clear();
      await tester.tap(find.text('bcpoker_admin'));
      await tester.pumpAndSettle();
      await tester.enterText(find.byType(TextField), 'qqq');
      await tester.pumpAndSettle();
      await tester.testTextInput.receiveAction(TextInputAction.done);
      await tester.pumpAndSettle();
      expect(calls, isEmpty);
      expect(find.byType(TextField), findsOneWidget, reason: '没有匹配时回车不关弹窗');
    });

    testWidgets('with no query the open project is highlighted, and Esc still closes the popup', (tester) async {
      await openPopup(tester, <String>[]);
      final highlighted = find.byWidgetPredicate((w) => w is Container && w.color == IntelliJTheme.selectionBg);
      expect(find.descendant(of: highlighted, matching: find.text('bcpoker_admin')), findsOneWidget);
      await tester.sendKeyEvent(LogicalKeyboardKey.escape);
      await tester.pumpAndSettle();
      expect(find.byType(TextField), findsNothing);
    });
  });
}
