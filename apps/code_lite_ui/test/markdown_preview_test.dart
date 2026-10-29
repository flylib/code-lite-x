import 'dart:convert';
import 'package:code_lite_ui/core/client/api_client.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/markdown/markdown_preview.dart';
import 'package:code_lite_ui/features/editor/syntax/color_schemes.dart';
import 'package:code_lite_ui/features/editor/syntax/tokenizer.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart' show Markdown;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// Markdown 预览:渲染、实时刷新、链接、图片、三种显示方式、滚动同步。
const _doc = '''# Title

Some **bold** and *italic* and `inline` and ~~gone~~ text with a [guide](docs/guide.md) and a [site](https://example.com).

- item one
- [x] done task
- [ ] open task

> quoted words

| name | value |
|------|-------|
| a    | 1     |
| b    | 2     |

```java
public class A {}
```

```
plain block
```
''';

// 1x1 透明 PNG
final Uint8List _png = Uint8List.fromList(const [
  0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
  0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
  0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
]);

class FakeEnv {
  final List<String> opened = [];
  final List<String> urls = [];
  Set<String> existing = {'/work/app/docs/guide.md'};
  final Map<String, Uint8List> files = {};

  MarkdownEnv get env => MarkdownEnv(
        fileExists: (p) async => existing.contains(p),
        readBytes: (p) async => files[p],
        openUrl: (u) async {
          urls.add(u);
          return null;
        },
      );
}

/// 预览里所有文字块的纯文本。
List<String> texts(WidgetTester tester) => [
      for (final w in tester.widgetList<RichText>(find.descendant(of: find.byType(MarkdownPreview), matching: find.byType(RichText)))) w.text.toPlainText(),
    ];

/// 在预览的文字里找带点击处理的片段(链接)。
TextSpan? linkSpan(WidgetTester tester, String label) {
  TextSpan? found;
  for (final w in tester.widgetList<RichText>(find.descendant(of: find.byType(MarkdownPreview), matching: find.byType(RichText)))) {
    w.text.visitChildren((s) {
      if (s is TextSpan && s.text == label && s.recognizer != null) found = s;
      return found == null;
    });
  }
  return found;
}

Future<void> tapLink(WidgetTester tester, String label) async {
  final span = linkSpan(tester, label);
  expect(span, isNotNull, reason: 'link "$label" not found');
  (span!.recognizer! as TapGestureRecognizer).onTap!();
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 20));
}

void main() {
  late FakeEnv fake;
  late CodeEditorController ctrl;
  late List<String> opened;

  setUp(() {
    fake = FakeEnv();
    opened = [];
  });

  Future<void> show(WidgetTester tester, {String text = _doc, String file = 'docs/readme.md', Size size = const Size(900, 900)}) async {
    await tester.binding.setSurfaceSize(size);
    addTearDown(() => tester.binding.setSurfaceSize(null));
    ctrl = CodeEditorController(initialText: text);
    await tester.pumpWidget(MaterialApp(
      home: Scaffold(
        body: MarkdownPreview(
          controller: ctrl,
          filePath: file,
          root: '/work/app',
          scheme: darculaScheme,
          onOpenFile: opened.add,
          env: fake.env,
        ),
      ),
    ));
    await tester.pump();
  }

  Future<void> close(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  }

  testWidgets('renders headings, emphasis, lists, task lists, quotes and tables', (tester) async {
    await show(tester);
    final all = texts(tester).join('\n');
    expect(all, contains('Title'));
    expect(all, contains('bold'));
    expect(all, contains('item one'));
    expect(all, contains('done task'));
    expect(all, contains('quoted words'));
    expect(find.byIcon(Icons.check_box), findsOneWidget, reason: '[x] 是勾选的任务');
    expect(find.byIcon(Icons.check_box_outline_blank), findsOneWidget);
    expect(find.byType(Table), findsOneWidget);
    expect(all, contains('name'));
    expect(all, contains('value'));
    // 标题比正文大,行内代码有底色和等宽字体
    TextSpan? inline, heading;
    for (final w in tester.widgetList<RichText>(find.descendant(of: find.byType(MarkdownPreview), matching: find.byType(RichText)))) {
      w.text.visitChildren((s) {
        if (s is TextSpan && s.text == 'inline') inline = s;
        return true;
      });
      w.text.visitChildren((s) {
        if (s is TextSpan && s.text == 'Title') heading = s;
        return true;
      });
    }
    expect(inline!.style!.backgroundColor, const Color(0xFF2B2D30));
    expect(inline!.style!.fontFamily, 'Menlo');
    expect(heading!.style!.fontSize, 30);
    await close(tester);
  });

  testWidgets('fenced code is highlighted with the editor colours by language; blocks without a language stay plain', (tester) async {
    await show(tester);
    TextSpan? keyword;
    String? plain;
    for (final w in tester.widgetList<RichText>(find.descendant(of: find.byType(MarkdownPreview), matching: find.byType(RichText)))) {
      final span = w.text;
      span.visitChildren((s) {
        if (s is TextSpan && s.text == 'public') keyword = s;
        return true;
      });
      if (span.toPlainText() == 'plain block') plain = span.toPlainText();
    }
    expect(keyword, isNotNull, reason: 'java 代码块被分词了');
    expect(keyword!.style!.color, darculaScheme.styleOf(TokenKind.keyword)!.color, reason: '和编辑器同一套关键字颜色');
    expect(plain, isNotNull);
    expect(texts(tester), contains('public class A {}'));
    await close(tester);
  });

  testWidgets('the preview follows edits after a short pause; a burst of edits renders once', (tester) async {
    await show(tester, text: '# One');
    expect(texts(tester), contains('One'));
    ctrl.setText('# Two');
    ctrl.setText('# Three');
    await tester.pump(const Duration(milliseconds: 100));
    expect(texts(tester), contains('One'), reason: '还在防抖');
    await tester.pump(const Duration(milliseconds: 150));
    expect(texts(tester), contains('Three'));
    expect(texts(tester), isNot(contains('Two')));
    await close(tester);
  });

  testWidgets('links: web → system, existing relative file → opened in the editor, missing file → message, anchors and scripts ignored', (tester) async {
    await show(tester, text: '[web](https://example.com) [guide](guide.md#top) [gone](nope.md) [anchor](#sec) [bad](javascript:alert(1)) [abs](/docs/guide.md)');
    await tapLink(tester, 'web');
    expect(fake.urls, ['https://example.com']);

    await tapLink(tester, 'guide');
    expect(opened, ['/work/app/docs/guide.md'], reason: '相对这篇文档所在的 docs/ 目录');

    await tapLink(tester, 'gone');
    expect(find.textContaining('找不到文件: /work/app/docs/nope.md'), findsOneWidget);

    await tapLink(tester, 'anchor');
    await tapLink(tester, 'bad');
    expect(fake.urls, hasLength(1));
    expect(opened, hasLength(1));

    await tapLink(tester, 'abs');
    expect(opened.last, '/work/app/docs/guide.md', reason: '/ 开头:先当成相对项目根');
    await close(tester);
  });

  testWidgets('images: local files are loaded relative to the document, missing ones show their alt text, data urls work', (tester) async {
    fake.files['/work/app/docs/img/a.png'] = _png;
    final data = 'data:image/png;base64,${_b64(_png)}';
    await show(tester, text: '![ok](img/a.png)\n\n![missing pic](img/none.png)\n\n![inline]($data)');
    await tester.pump(const Duration(milliseconds: 50));
    // 1x1 的测试图在测试环境里没解码完时尺寸是 0,find 会当它不在屏幕上:按控件存在来数
    expect(find.byType(Image, skipOffstage: false), findsNWidgets(2), reason: '本地图片 + data 图片');
    expect(find.text('missing pic'), findsOneWidget);
    expect(find.byIcon(Icons.broken_image_outlined), findsOneWidget);
    await close(tester);
  });

  group('in the editor', () {
    late EditorAppearance appearance;
    late ScrollController editorScroll;
    late ApiClient client;
    int saves = 0;

    Future<void> editor(WidgetTester tester, String file, {String text = _doc}) async {
      await tester.binding.setSurfaceSize(const Size(1300, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      ctrl = CodeEditorController(initialText: text);
      client = ApiClient(initialRoot: '/work/app');
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: EditorViewWidget(
            apiClient: client,
            openTabs: [file],
            activeFile: file,
            codeContent: '',
            controller: ctrl,
            verticalScroll: editorScroll,
            appearance: appearance,
            onSave: () => saves++,
            onOpenFile: opened.add,
            markdownEnv: fake.env,
            onSelectTab: (_) {},
            onCloseTab: (_) {},
          ),
        ),
      ));
      await tester.pump();
    }

    /// 收尾:卸载、释放 controller,ApiClient 自己带定时器,要在 runAsync 里释放(同 settings_test 的做法)。
    Future<void> finish(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
      await tester.pump(const Duration(milliseconds: 50)); // ApiClient 构造时排了个零时长定时器,让它跑掉
      await tester.runAsync(client.dispose);
    }

    setUp(() {
      appearance = EditorAppearance();
      editorScroll = ScrollController();
      saves = 0;
    });
    tearDown(() => editorScroll.dispose());

    Finder preview() => find.byType(MarkdownPreview);
    // 编辑器里的源码行(`# Title`)是预览之外的 RichText;只看预览时它不存在
    Finder sourceLine(String text) => find.byWidgetPredicate((w) => w is RichText && w.text.toPlainText() == text);
    Finder modeButton(MarkdownViewMode m) => find.byKey(ValueKey('markdown-mode-${m.name}'));

    testWidgets('three buttons for markdown files only; default is editor and preview; each button switches', (tester) async {
      await editor(tester, 'README.md');
      expect(find.byTooltip('仅编辑器'), findsOneWidget);
      expect(find.byTooltip('编辑器和预览'), findsOneWidget);
      expect(find.byTooltip('仅预览'), findsOneWidget);
      expect(preview(), findsOneWidget, reason: '默认:编辑器 | 预览');
      expect(sourceLine('# Title'), findsOneWidget, reason: '编辑器还在');

      await tester.tap(modeButton(MarkdownViewMode.editor));
      await tester.pump();
      expect(preview(), findsNothing);
      expect(sourceLine('# Title'), findsOneWidget);

      await tester.tap(modeButton(MarkdownViewMode.preview));
      await tester.pump();
      expect(preview(), findsOneWidget);
      expect(sourceLine('# Title'), findsNothing, reason: '只看预览:没有编辑器');
      expect(appearance.markdownMode, MarkdownViewMode.preview);

      await tester.tap(modeButton(MarkdownViewMode.split));
      await tester.pump();
      expect(preview(), findsOneWidget);
      expect(sourceLine('# Title'), findsOneWidget);
      await finish(tester);
    });

    testWidgets('other files get no buttons and no preview', (tester) async {
      await editor(tester, 'src/Main.java', text: 'class A {}');
      expect(find.byTooltip('仅预览'), findsNothing);
      expect(preview(), findsNothing);
      await finish(tester);
    });

    testWidgets('split view: preview updates while typing in the editor', (tester) async {
      await editor(tester, 'README.md', text: '# Before');
      expect(texts(tester), contains('Before'));
      ctrl.setText('# After');
      await tester.pump(const Duration(milliseconds: 300));
      expect(texts(tester), contains('After'));
      await finish(tester);
    });

    testWidgets('preview only: keys cannot edit the hidden document, but Cmd+S still saves', (tester) async {
      appearance.setMarkdownMode(MarkdownViewMode.preview);
      await editor(tester, 'README.md', text: 'abc');
      final before = ctrl.text;
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.sendKeyEvent(LogicalKeyboardKey.backspace);
      await tester.sendKeyEvent(LogicalKeyboardKey.delete);
      await tester.pump();
      expect(ctrl.text, before);
      await tester.sendKeyDownEvent(LogicalKeyboardKey.metaLeft);
      await tester.sendKeyEvent(LogicalKeyboardKey.keyS);
      await tester.sendKeyUpEvent(LogicalKeyboardKey.metaLeft);
      expect(saves, 1);

      // 切回编辑器:按键又能编辑
      appearance.setMarkdownMode(MarkdownViewMode.editor);
      await tester.pump();
      await tester.sendKeyEvent(LogicalKeyboardKey.enter);
      await tester.pump();
      expect(ctrl.text, isNot(before), reason: '编辑器模式下回车插入了换行');
      await finish(tester);
    });

    testWidgets('scrolling one side scrolls the other in proportion (split view)', (tester) async {
      final long = [for (var i = 0; i < 400; i++) 'Paragraph number $i with some words.\n'].join('\n');
      await editor(tester, 'README.md', text: long);
      await tester.pump(const Duration(milliseconds: 50));
      final previewScroll = tester.widget<Scrollable>(find.descendant(of: preview(), matching: find.byType(Scrollable)).first).controller!;
      expect(editorScroll.hasClients && previewScroll.hasClients, isTrue);
      expect(previewScroll.offset, 0);

      editorScroll.jumpTo(editorScroll.position.maxScrollExtent / 2);
      await tester.pump();
      expect(previewScroll.offset / previewScroll.position.maxScrollExtent, closeTo(0.5, 0.02));

      previewScroll.jumpTo(previewScroll.position.maxScrollExtent / 4);
      await tester.pump();
      expect(editorScroll.offset / editorScroll.position.maxScrollExtent, closeTo(0.25, 0.02));
      await finish(tester);
    });

    /// 高度各不相同的块:长短不一的段落、代码块、表格、标题。
    String mixedDoc(int sections) => [
          for (var i = 0; i < sections; i++) ...[
            '## Section $i',
            'Short paragraph $i.',
            List.generate(1 + i % 7, (k) => 'A longer paragraph with several words in it, number $k of section $i, so that it wraps over a few lines in the narrow preview column.').join(' '),
            '```java\n${List.generate(2 + i % 9, (k) => 'int value$k = compute($i, $k);').join('\n')}\n```',
            '| a | b |\n|---|---|\n${List.generate(1 + i % 5, (k) => '| row $k | ${k * i} |').join('\n')}',
          ],
        ].join('\n\n');

    testWidgets('scroll sync is smooth: the preview length is exact and stays put, so it moves a steady amount per frame', (tester) async {
      // 回归:预览用懒加载列表时,总长是估的、滚到哪估到哪,同步滚动被估值甩得每帧跳几百到几万像素(分屏严重卡顿)
      await editor(tester, 'README.md', text: mixedDoc(60));
      await tester.pump(const Duration(milliseconds: 50));
      final previewScroll = tester.widget<Scrollable>(find.descendant(of: preview(), matching: find.byType(Scrollable)).first).controller!;
      final previewMax = previewScroll.position.maxScrollExtent;
      final editorMax = editorScroll.position.maxScrollExtent;
      expect(previewMax, greaterThan(5000), reason: '所有块都排出来了,不是只算屏幕上那几块');

      final deltas = <double>[];
      var last = previewScroll.offset;
      for (var i = 0; i < 200; i++) {
        editorScroll.jumpTo((editorMax * i / 200).clamp(0.0, editorMax));
        await tester.pump(const Duration(milliseconds: 16));
        expect(previewScroll.position.maxScrollExtent, previewMax, reason: '总长不随滚动变化(frame $i)');
        deltas.add((previewScroll.offset - last).abs());
        last = previewScroll.offset;
      }
      final expected = previewMax / 200; // 按比例,每帧应该移动这么多
      final worst = deltas.reduce((a, b) => a > b ? a : b);
      expect(worst, lessThan(expected * 1.5 + 2), reason: '每帧移动 ≈ $expected px,不能有突然的大跳(最大 $worst)');
      await finish(tester);
    });

    testWidgets('a very large document falls back to the lazy list and does not sync (its length is only an estimate)', (tester) async {
      await tester.binding.setSurfaceSize(const Size(1300, 800));
      addTearDown(() => tester.binding.setSurfaceSize(null));
      ctrl = CodeEditorController(initialText: mixedDoc(40));
      final lazyScroll = ScrollController();
      addTearDown(lazyScroll.dispose);
      await tester.pumpWidget(MaterialApp(
        home: Scaffold(
          body: Row(children: [
            Expanded(child: SingleChildScrollView(controller: lazyScroll, child: const SizedBox(height: 6000))),
            Expanded(child: MarkdownPreview(controller: ctrl, filePath: 'a.md', root: '/w', scheme: darculaScheme, syncWith: lazyScroll, eagerLimit: 100, env: fake.env)),
          ]),
        ),
      ));
      await tester.pump(const Duration(milliseconds: 50));
      final previewScroll = tester.widget<Scrollable>(find.descendant(of: preview(), matching: find.byType(Scrollable)).first).controller!;
      lazyScroll.jumpTo(lazyScroll.position.maxScrollExtent / 2);
      await tester.pump();
      expect(previewScroll.offset, 0, reason: '懒加载:不同步');
      previewScroll.jumpTo(300);
      await tester.pump();
      expect(lazyScroll.offset, lazyScroll.position.maxScrollExtent / 2, reason: '也不反向同步');
      expect(find.byType(Markdown), findsOneWidget, reason: '仍然能显示');
      await tester.pumpWidget(const SizedBox());
      ctrl.dispose();
    });

    testWidgets('a link in the preview opens the file through the editor callback', (tester) async {
      fake.existing = {'/work/app/docs/guide.md'};
      await editor(tester, 'docs/README.md', text: '[guide](guide.md)');
      await tapLink(tester, 'guide');
      expect(opened, ['/work/app/docs/guide.md']);
      await finish(tester);
    });
  });
}

String _b64(Uint8List b) => base64Encode(b);
