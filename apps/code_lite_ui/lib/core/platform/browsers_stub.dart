import 'dart:typed_data';

/// 本机安装的浏览器。web 预览里没有本机,什么都不提供。
class BrowserApp {
  const BrowserApp({required this.id, required this.name, required this.path});

  /// 稳定的标识(`chrome`、`firefox`……),也用作图标缓存的文件名。
  final String id;
  final String name;

  /// macOS 上是 .app 目录,其它系统是可执行文件。
  final String path;
}

Future<List<BrowserApp>> detectBrowsers() async => const [];

Future<String?> openInBrowser(BrowserApp browser, String file) async => '当前平台不支持';

Future<Uint8List?> browserIcon(BrowserApp browser) async => null;

/// 用系统默认浏览器打开网址。成功返回 null,失败返回原因。
Future<String?> openExternalUrl(String url) async => '当前平台不支持';
