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
}
