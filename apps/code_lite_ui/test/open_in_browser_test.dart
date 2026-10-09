import 'dart:io';
import 'dart:typed_data';

import 'package:code_lite_ui/core/platform/browsers.dart';
import 'package:code_lite_ui/features/editor/code_editor_controller.dart';
import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/editor_view_widget.dart';
import 'package:code_lite_ui/features/editor/open_in_browser.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

/// HTML 文件:编辑区右上角列出本机的浏览器,点哪个就用哪个打开。
const _chrome = BrowserApp(id: 'chrome', name: 'Google Chrome', path: '/Applications/Google Chrome.app');
const _firefox = BrowserApp(id: 'firefox', name: 'Firefox', path: '/Applications/Firefox.app');
const _safari = BrowserApp(id: 'safari', name: 'Safari', path: '/Applications/Safari.app');

class _Calls {
  final List<String> log = [];
  String? openError;
  int detects = 0;

  BrowserService service(List<BrowserApp> installed) => BrowserService(
        detect: () async {
          detects++;
          return installed;
        },
        open: (b, file) async {
          log.add('open ${b.id} $file');
          return openError;
        },
        icon: (b) async => null, // 没有图标 → 字母徽标
      );
}

void main() {
  test('only html-like files get the browser buttons', () {
    for (final p in ['index.html', 'a/b/Page.HTM', 'x.xhtml']) {
      expect(isHtmlFile(p), isTrue, reason: p);
    }
    for (final p in ['a.java', 'html', 'notes.html.bak', 'README.md', 'a.htmlx']) {
      expect(isHtmlFile(p), isFalse, reason: p);
    }
  });

  group('bar', () {
    Widget host(Widget bar) => MaterialApp(home: Scaffold(body: Align(alignment: Alignment.topRight, child: bar)));

    testWidgets('lists installed browsers in order; a click saves first, then opens that browser with the absolute path', (tester) async {
      final calls = _Calls();
      await tester.pumpWidget(host(OpenInBrowserBar(
        service: calls.service([_chrome, _firefox, _safari]),
        file: '/work/app/web/index.html',
        beforeOpen: () async => calls.log.add('save'),
      )));
      await tester.pumpAndSettle();
      expect(find.byKey(const ValueKey('open-in-chrome')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-in-firefox')), findsOneWidget);
      expect(find.byKey(const ValueKey('open-in-safari')), findsOneWidget);
      expect(tester.getCenter(find.byKey(const ValueKey('open-in-chrome'))).dx,
          lessThan(tester.getCenter(find.byKey(const ValueKey('open-in-firefox'))).dx));
      expect(find.byTooltip('在 Firefox 中打开 index.html'), findsOneWidget);
      expect(find.text('G'), findsOneWidget, reason: '没有图标时用首字母');

      await tester.tap(find.byKey(const ValueKey('open-in-firefox')));
      await tester.pumpAndSettle();
      expect(calls.log, ['save', 'open firefox /work/app/web/index.html'], reason: '先把改动存盘,浏览器才看得到');
      await tester.tap(find.byKey(const ValueKey('open-in-safari')));
      await tester.pumpAndSettle();
      expect(calls.log.last, 'open safari /work/app/web/index.html');
    });

    testWidgets('nothing is shown without browsers; a failure is reported; detection runs only once', (tester) async {
      final none = _Calls();
      await tester.pumpWidget(host(OpenInBrowserBar(service: none.service(const []), file: '/a.html')));
      await tester.pumpAndSettle();
      expect(find.byType(InkWell), findsNothing);

      final bad = _Calls()..openError = 'not allowed';
      final service = bad.service([_chrome]);
      await tester.pumpWidget(host(OpenInBrowserBar(service: service, file: '/a.html')));
      await tester.pumpAndSettle();
      await tester.tap(find.byKey(const ValueKey('open-in-chrome')));
      await tester.pumpAndSettle();
      expect(find.text('无法用 Google Chrome 打开:not allowed'), findsOneWidget);

      await tester.pumpWidget(host(OpenInBrowserBar(service: service, file: '/b.html')));
      await tester.pumpAndSettle();
      expect(bad.detects, 1, reason: '换文件不重新检测');
    });

    testWidgets('an icon, when there is one, replaces the letter', (tester) async {
      // 1x1 透明 PNG
      final png = Uint8List.fromList(const [
        0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x48, 0x44, 0x52, 0x00, 0x00, 0x00, 0x01, 0x00, 0x00, 0x00, 0x01,
        0x08, 0x06, 0x00, 0x00, 0x00, 0x1F, 0x15, 0xC4, 0x89, 0x00, 0x00, 0x00, 0x0D, 0x49, 0x44, 0x41, 0x54, 0x78, 0x9C, 0x63, 0x00, 0x01, 0x00, 0x00,
        0x05, 0x00, 0x01, 0x0D, 0x0A, 0x2D, 0xB4, 0x00, 0x00, 0x00, 0x00, 0x49, 0x45, 0x4E, 0x44, 0xAE, 0x42, 0x60, 0x82,
      ]);
      final service = BrowserService(detect: () async => [_chrome], open: (_, __) async => null, icon: (_) async => png);
      await tester.pumpWidget(host(OpenInBrowserBar(service: service, file: '/a.html')));
      await tester.pumpAndSettle();
      expect(find.byType(Image), findsOneWidget);
      expect(find.text('G'), findsNothing);
    });
  });

  testWidgets('editor: the bar floats top-right for an html file and is absent otherwise', (tester) async {
    await tester.binding.setSurfaceSize(const Size(900, 400));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    final calls = _Calls();
    final service = calls.service([_chrome, _firefox]);
    final ctrl = CodeEditorController(initialText: '<html></html>');
    Widget editor(String file) => MaterialApp(
          home: Scaffold(
            body: EditorViewWidget(
              openTabs: [file],
              activeFile: file,
              codeContent: '',
              controller: ctrl,
              appearance: EditorAppearance(),
              paneActionsBuilder: (path) => isHtmlFile(path) ? OpenInBrowserBar(service: service, file: '/p/$path') : null,
              onSelectTab: (_) {},
              onCloseTab: (_) {},
            ),
          ),
        );

    await tester.pumpWidget(editor('web/index.html'));
    await tester.pumpAndSettle();
    final bar = find.byKey(const ValueKey('open-in-firefox'));
    expect(bar, findsOneWidget);
    final editorBox = tester.getRect(find.byType(EditorViewWidget));
    final pos = tester.getTopRight(bar);
    expect(pos.dx, lessThan(editorBox.right - 12), reason: '让开右边的错误条');
    expect(pos.dx, greaterThan(editorBox.right - 120), reason: '在右上角');
    expect(pos.dy, lessThan(editorBox.top + 120));
    await tester.tap(bar);
    await tester.pumpAndSettle();
    expect(calls.log, ['open firefox /p/web/index.html']);

    await tester.pumpWidget(editor('src/Main.java'));
    await tester.pumpAndSettle();
    expect(find.byKey(const ValueKey('open-in-firefox')), findsNothing);

    await tester.pumpWidget(const SizedBox());
    ctrl.dispose();
  });

  test('on macOS: finds the real browsers and converts a real app icon to a PNG', () async {
    if (!Platform.isMacOS) return;
    final found = await detectBrowsers();
    expect(found.map((b) => b.id), contains('safari'), reason: 'Safari 是系统自带的');
    for (final b in found) {
      expect(Directory(b.path).existsSync(), isTrue, reason: b.path);
    }
    final order = ['chrome', 'firefox', 'safari', 'edge', 'brave', 'arc', 'opera', 'vivaldi', 'chromium', 'orion'];
    final ids = found.map((b) => b.id).toList();
    expect(ids, [for (final id in order) if (ids.contains(id)) id], reason: '顺序固定');

    final icon = await browserIcon(found.firstWhere((b) => b.id == 'safari'));
    expect(icon, isNotNull);
    expect(icon!.sublist(0, 8), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A], reason: '是 PNG');
    expect(icon.length, greaterThan(500));
    expect(await browserIcon(const BrowserApp(id: 'nope', name: 'Nope', path: '/Applications/Nope.app')), isNull);
  });
}
