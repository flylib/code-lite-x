import 'package:code_lite_ui/core/platform/window_chrome.dart';
import 'package:code_lite_ui/features/title_bar/title_bar_widget.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';

/// 窗口标题栏:macOS 上系统自带的红绿灯浮在 Flutter 标题栏左上角(标题栏透明、内容铺满),
/// Flutter 这边只负责留位置、空白处拖动窗口、双击缩放。
void main() {
  const channel = MethodChannel('codelitex/window');
  late List<String> calls;
  late bool nativeFullScreen;

  setUp(() {
    calls = [];
    nativeFullScreen = false;
    WindowChrome.debugReset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, (call) async {
      calls.add(call.method);
      if (call.method == 'isFullScreen') return nativeFullScreen;
      return null;
    });
  });
  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger.setMockMethodCallHandler(channel, null);
    WindowChrome.debugReset();
  });

  Widget bar({VoidCallback? onSearch}) => MaterialApp(
        home: Scaffold(
          body: Align(
            alignment: Alignment.topLeft,
            child: TitleBarWidget(
              onSearch: onSearch,
              projectChip: const SizedBox(key: ValueKey('chip'), width: 40, height: 20),
            ),
          ),
        ),
      );

  Finder circles() => find.byWidgetPredicate((w) => w is Container && w.decoration is BoxDecoration && (w.decoration! as BoxDecoration).shape == BoxShape.circle);

  Future<void> onMac(WidgetTester tester, Future<void> Function() body) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.macOS;
    try {
      await body();
    } finally {
      debugDefaultTargetPlatformOverride = null;
    }
  }

  testWidgets('no drawn red / yellow / green dots any more; macOS leaves room for the real ones, other systems do not', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 100));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await onMac(tester, () async {
      await tester.pumpWidget(bar());
      expect(circles(), findsNothing, reason: '假圆点没了:真的红绿灯是系统画的');
      expect(tester.getTopLeft(find.byKey(const ValueKey('chip'))).dx, WindowChrome.trafficLightsInset, reason: '系统红绿灯占着左边这一段');
    });

    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(bar()); // 默认平台(不是 macOS):用原生标题栏,不留位置
    expect(tester.getTopLeft(find.byKey(const ValueKey('chip'))).dx, 12);
    expect(circles(), findsNothing);
  });

  testWidgets('full screen: the system hides the lights, so the room is given back; leaving full screen takes it again', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    await onMac(tester, () async {
      await tester.pumpWidget(bar());
      WindowChrome.fullScreen.value = true;
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(const ValueKey('chip'))).dx, 12);
      WindowChrome.fullScreen.value = false;
      await tester.pump();
      expect(tester.getTopLeft(find.byKey(const ValueKey('chip'))).dx, WindowChrome.trafficLightsInset);
    });
  });

  testWidgets('init reads the current state and follows the native full-screen notifications', (tester) async {
    await onMac(tester, () async {
      nativeFullScreen = true;
      await WindowChrome.init();
      expect(WindowChrome.fullScreen.value, isTrue, reason: '启动时已经是全屏');

      Future<void> native(String method, Object? args) async {
        await tester.binding.defaultBinaryMessenger.handlePlatformMessage(
          'codelitex/window',
          const StandardMethodCodec().encodeMethodCall(MethodCall(method, args)),
          (_) {},
        );
      }

      await native('fullScreen', false);
      expect(WindowChrome.fullScreen.value, isFalse);
      await native('fullScreen', true);
      expect(WindowChrome.fullScreen.value, isTrue);
      await native('somethingElse', null); // 不认识的通知忽略
      expect(WindowChrome.fullScreen.value, isTrue);
    });
  });

  testWidgets('dragging empty title bar space starts a window drag; double-click zooms; the native side is only called on macOS', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 100));
    addTearDown(() => tester.binding.setSurfaceSize(null));

    await onMac(tester, () async {
      await tester.pumpWidget(bar());
      // 标题栏中间偏右的空白处(搜索框和左边的内容之间)
      const empty = Offset(700, 20);
      await tester.dragFrom(empty, const Offset(30, 4));
      await tester.pump();
      expect(calls, ['startDrag']);

      calls.clear();
      await tester.tapAt(empty);
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tapAt(empty);
      await tester.pumpAndSettle();
      expect(calls, ['toggleZoom']);
    });

    calls.clear();
    await tester.pumpWidget(const SizedBox());
    await tester.pumpWidget(bar()); // 其它系统:标题栏是原生的,Flutter 不接管
    await tester.dragFrom(const Offset(700, 20), const Offset(30, 4));
    await tester.tapAt(const Offset(700, 20));
    await tester.pump(const Duration(milliseconds: 50));
    await tester.tapAt(const Offset(700, 20));
    await tester.pumpAndSettle();
    expect(calls, isEmpty);
  });

  testWidgets('controls in the title bar keep working: a single tap fires at once and does not start a drag', (tester) async {
    await tester.binding.setSurfaceSize(const Size(1200, 100));
    addTearDown(() => tester.binding.setSurfaceSize(null));
    var searches = 0;
    await onMac(tester, () async {
      await tester.pumpWidget(bar(onSearch: () => searches++));
      await tester.tap(find.byTooltip('搜索 (⇧⌘F)'));
      await tester.pump(); // 没有等双击超时:单击立刻生效,不被标题栏的双击识别器拖慢
      expect(searches, 1);
      expect(calls, isEmpty);

      // 快速连点按钮不能当成双击标题栏:点在按钮上的不算空白
      await tester.tap(find.byTooltip('搜索 (⇧⌘F)'));
      await tester.pump(const Duration(milliseconds: 50));
      await tester.tap(find.byTooltip('搜索 (⇧⌘F)'));
      await tester.pumpAndSettle();
      expect(searches, 3);
      expect(calls, isEmpty, reason: '没有触发缩放');
    });
  });
}
