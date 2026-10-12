/// 按扩展名给 Content-Type;认不出来的当二进制。
String contentTypeOf(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'html' || 'htm' => 'text/html; charset=utf-8',
    'xhtml' => 'application/xhtml+xml; charset=utf-8',
    'css' => 'text/css; charset=utf-8',
    'js' || 'mjs' || 'cjs' => 'text/javascript; charset=utf-8',
    'json' || 'map' => 'application/json; charset=utf-8',
    'xml' => 'application/xml; charset=utf-8',
    'txt' || 'md' || 'csv' || 'log' => 'text/plain; charset=utf-8',
    'svg' => 'image/svg+xml',
    'png' => 'image/png',
    'jpg' || 'jpeg' => 'image/jpeg',
    'gif' => 'image/gif',
    'webp' => 'image/webp',
    'avif' => 'image/avif',
    'ico' => 'image/x-icon',
    'bmp' => 'image/bmp',
    'woff' => 'font/woff',
    'woff2' => 'font/woff2',
    'ttf' => 'font/ttf',
    'otf' => 'font/otf',
    'eot' => 'application/vnd.ms-fontobject',
    'mp4' => 'video/mp4',
    'webm' => 'video/webm',
    'mp3' => 'audio/mpeg',
    'wav' => 'audio/wav',
    'ogg' => 'audio/ogg',
    'wasm' => 'application/wasm',
    'pdf' => 'application/pdf',
    _ => 'application/octet-stream',
  };
}
