import 'dart:async';
import 'dart:io';

import 'web_content_types.dart';

export 'web_content_types.dart';

/// 项目的静态文件服务器(IntelliJ 的 built-in server):在浏览器里打开 HTML 时用
/// `http://localhost:63342/<项目名>/<相对路径>`,不用 file://(相对路径的脚本、fetch、模块才都能用)。
///
/// - 每个项目一个,第一次要用时才启动,项目关掉时随之关闭([close]);
///   63342 被占了(别的项目、或者 IntelliJ 开着)就往后找一个空端口;
/// - 只听本机回环地址,并且只认 Host 是 localhost / 127.0.0.1 / [::1] 的请求 ——
///   挡住 DNS 重绑定:别的网页把自己的域名解析到 127.0.0.1 也读不到项目文件;
/// - 只给出这个项目目录里的文件,`..` 走不出去;不缓存,改完刷新就是新的。
class BuiltInWebServer {
  BuiltInWebServer({required String root, this.preferredPort = 63342})
      : root = _trimSlash(root),
        name = _trimSlash(root).split('/').where((s) => s.isNotEmpty).lastOrNull ?? 'project';

  /// 项目目录。
  final String root;

  /// 地址里的项目名(目录名)。
  final String name;

  final int preferredPort;

  final List<HttpServer> _servers = [];
  Future<int?>? _starting;

  int? get port => _servers.isEmpty ? null : _servers.first.port;

  bool _closed = false;

  /// [filePath](绝对路径,或相对项目目录)在浏览器里的地址;文件不在项目目录里、服务器起不来或已关闭时返回 null(调用方退回 file://)。
  Future<String?> urlFor(String filePath) async {
    if (_closed) return null;
    final abs = filePath.startsWith('/') ? filePath : '$root/$filePath';
    if (!abs.startsWith('$root/')) return null;
    final port = await (_starting ??= _start());
    if (port == null || _closed) return null;
    final rel = abs.substring(root.length + 1).split('/').map(Uri.encodeComponent).join('/');
    return 'http://localhost:$port/${Uri.encodeComponent(name)}/$rel';
  }

  Future<int?> _start() async {
    for (var p = preferredPort; p < preferredPort + 20; p++) {
      HttpServer v4;
      try {
        v4 = await HttpServer.bind(InternetAddress.loopbackIPv4, p);
      } on SocketException {
        continue;
      }
      _servers.add(v4);
      // 浏览器解析 localhost 可能先走 IPv6:同一端口在 ::1 上也听一份(没有 IPv6 就算了)
      try {
        _servers.add(await HttpServer.bind(InternetAddress.loopbackIPv6, p, v6Only: true));
      } on SocketException {
        // ignore
      }
      for (final s in _servers) {
        s.listen(_handle, onError: (Object _) {});
      }
      return p;
    }
    return null;
  }

  static final RegExp _localHost = RegExp(r'^(localhost|127\.0\.0\.1|\[::1\])(:\d+)?$', caseSensitive: false);

  Future<void> _handle(HttpRequest req) async {
    final res = req.response;
    try {
      res.headers.set('Cache-Control', 'no-store');
      final host = req.headers.value(HttpHeaders.hostHeader) ?? '';
      if (!_localHost.hasMatch(host)) return await _fail(res, HttpStatus.forbidden, 'Forbidden');
      if (req.method != 'GET' && req.method != 'HEAD') return await _fail(res, HttpStatus.methodNotAllowed, 'Method Not Allowed');

      final segs = req.uri.pathSegments;
      if (segs.isEmpty) return await _fail(res, HttpStatus.notFound, 'Not Found');
      final rest = segs.skip(1).where((s) => s.isNotEmpty).toList();
      if (segs.first != name || rest.any((s) => s == '..' || s.contains('/') || s.contains(r'\'))) {
        return await _fail(res, HttpStatus.notFound, 'Not Found');
      }
      var path = rest.isEmpty ? root : '$root/${rest.join('/')}';
      if (await FileSystemEntity.isDirectory(path)) {
        // 目录:没以 / 结尾先跳过去(页面里的相对路径才对),再给 index.html
        if (!req.uri.path.endsWith('/')) {
          res.statusCode = HttpStatus.movedPermanently;
          res.headers.set(HttpHeaders.locationHeader, '${req.uri.path}/');
          return await res.close();
        }
        path = '$path/index.html';
      }
      final file = File(path);
      if (!await file.exists()) return await _fail(res, HttpStatus.notFound, 'Not Found');
      res.headers.contentType = ContentType.parse(contentTypeOf(path));
      res.headers.contentLength = await file.length();
      if (req.method == 'HEAD') return await res.close();
      await res.addStream(file.openRead());
      await res.close();
    } catch (_) {
      try {
        await _fail(res, HttpStatus.internalServerError, 'Internal Server Error');
      } catch (_) {}
    }
  }

  Future<void> _fail(HttpResponse res, int status, String text) async {
    res.statusCode = status;
    res.headers.contentType = ContentType.text;
    res.write(text);
    await res.close();
  }

  /// 关掉(项目关闭时):端口释放,之后不再给地址。正在启动的话等它起来再关。
  Future<void> close() async {
    _closed = true;
    await _starting;
    for (final s in _servers) {
      await s.close(force: true);
    }
    _servers.clear();
  }

  static String _trimSlash(String p) => p.length > 1 && p.endsWith('/') ? p.substring(0, p.length - 1) : p;
}
