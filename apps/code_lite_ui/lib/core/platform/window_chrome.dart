import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// 原生窗口的标题栏行为。
///
/// macOS 上窗口的标题栏是透明的、内容铺满整个窗口:系统自带的红黄绿按钮(真正的关闭 / 最小化 / 缩放)
/// 浮在 Flutter 画的标题栏左上角,标题栏的空白处要自己负责拖动窗口、双击缩放。
/// 其它系统用自己的原生标题栏,这里什么也不做。
class WindowChrome {
  WindowChrome._();

  static const MethodChannel _channel = MethodChannel('codelitex/window');

  /// 标题栏左边给系统红绿灯留的宽度(三个按钮 + 左右边距)。
  static const double trafficLightsInset = 76;

  /// 窗口是不是全屏。全屏时系统把红绿灯收起来了,标题栏不必再留位置。
  static final ValueNotifier<bool> fullScreen = ValueNotifier(false);

  static bool _initialized = false;

  /// 是不是用「透明标题栏 + 原生红绿灯」这种外观。
  static bool get usesNativeTrafficLights => defaultTargetPlatform == TargetPlatform.macOS && !kIsWeb;

  /// 接收原生那边的全屏通知,并读一次当前状态。启动时调一次。
  static Future<void> init() async {
    if (_initialized || !usesNativeTrafficLights) return;
    _initialized = true;
    _channel.setMethodCallHandler((call) async {
      if (call.method == 'fullScreen') fullScreen.value = call.arguments == true;
    });
    try {
      fullScreen.value = await _channel.invokeMethod<bool>('isFullScreen') ?? false;
    } on MissingPluginException {
      // 没有原生那一半(测试、预览):当作没全屏
    }
  }

  /// 测试用:回到没初始化的状态。
  @visibleForTesting
  static void debugReset() {
    _initialized = false;
    fullScreen.value = false;
    _channel.setMethodCallHandler(null);
  }

  /// 按着标题栏空白处拖:开始拖动窗口。
  static Future<void> startDrag() => _invoke('startDrag');

  /// 双击标题栏:按系统设置缩放(或最小化)窗口。
  static Future<void> toggleZoom() => _invoke('toggleZoom');

  static Future<void> _invoke(String method) async {
    if (!usesNativeTrafficLights) return;
    try {
      await _channel.invokeMethod<void>(method);
    } on MissingPluginException {
      // 没有原生那一半
    }
  }
}
