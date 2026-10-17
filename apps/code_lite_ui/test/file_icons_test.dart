import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/project_explorer/project_explorer_widget.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// 文件图标:同一种文件在文件树、编辑器标签、Go to File 里是同一个图标;Markdown 用 Markdown 标志。
void main() {
  test('markdown files get the Markdown mark, Makefiles the M, the rest a Material icon', () {
    for (final name in ['card.md', 'README.markdown']) {
      expect(fileTypeIconWidget(name), isA<MarkdownIcon>(), reason: name);
    }
    expect(fileTypeIconWidget('Makefile'), isA<MakefileIcon>());
    expect(fileTypeIconWidget('A.java'), isA<Icon>());
  });

  testWidgets('the file tree and the editor tabs show the same icons', (tester) async {
    final ctrl = CodeEditorController(initialText: '# card');
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: Row(children: [
          SizedBox(
            width: 240,
            child: ProjectExplorerWidget(
              treeData: const {
                'name': 'p',
                'path': '/p',
                'is_dir': true,
                'children': [
                  {'name': 'card.md', 'path': '/p/card.md', 'is_dir': false},
                  {'name': 'A.java', 'path': '/p/A.java', 'is_dir': false},
                ],
              },
              activeFilePath: '',
              onSelectFile: (_) {},
            ),
          ),
          Expanded(
            child: EditorViewWidget(
              openTabs: const ['/p/card.md', '/p/A.java'],
              activeFile: '/p/A.java',
              codeContent: '',
              controller: ctrl,
              appearance: EditorAppearance(),
              onSelectTab: (_) {},
              onCloseTab: (_) {},
            ),
          ),
        ]),
      ),
    ));
    await tester.pump();
    final tree = find.byType(ProjectExplorerWidget);
    final tabs = find.byType(EditorViewWidget);
    expect(find.descendant(of: tree, matching: find.byType(MarkdownIcon)), findsOneWidget);
    expect(find.descendant(of: tabs, matching: find.byType(MarkdownIcon)), findsOneWidget, reason: '标签上不再是「M↓」文字');
    expect(find.descendant(of: tabs, matching: find.text('M↓')), findsNothing);
    final javaIcon = fileTypeIcon('A.java').$1;
    expect(find.descendant(of: tree, matching: find.byIcon(javaIcon)), findsOneWidget);
    expect(find.descendant(of: tabs, matching: find.byIcon(javaIcon)), findsOneWidget, reason: 'Java 在标签上也是文件树那个图标');
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });
}
