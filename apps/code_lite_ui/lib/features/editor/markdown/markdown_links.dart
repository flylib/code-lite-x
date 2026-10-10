// Markdown 预览里的链接与图片地址怎么解释。纯函数,不碰文件系统(是否存在由调用方查)。

import '../open_in_browser.dart' show absoluteFilePath;

/// 按扩展名判断是不是 Markdown 文件。
bool isMarkdownFile(String path) {
  final name = path.split('/').last.split(r'\').last.toLowerCase();
  final dot = name.lastIndexOf('.');
  if (dot <= 0) return false;
  return const {'md', 'markdown', 'mdown', 'mkd'}.contains(name.substring(dot + 1));
}

enum LinkKind {
  /// 网址 / 邮件:交给系统浏览器。
  external,

  /// 页内锚点(`#标题`)。
  anchor,

  /// 本地文件:[LinkTarget.candidates] 里第一个存在的就是它。
  file,

  /// 空的、`javascript:` 之类不该处理的。
  none,
}

class LinkTarget {
  const LinkTarget(this.kind, {this.url = '', this.candidates = const [], this.fragment});

  final LinkKind kind;

  /// [LinkKind.external] 时的完整网址。
  final String url;

  /// [LinkKind.file] 时可能的绝对路径,按优先级排列。
  final List<String> candidates;

  /// 链接里 `#` 后面的部分。
  final String? fragment;
}

/// 解释 Markdown 里的 [href]。[fromFile] 是这篇文档的路径(绝对或相对项目根),[root] 是项目根目录。
///
/// 相对链接相对这篇文档所在的目录;`/开头` 的按 GitHub 的习惯先当成相对项目根,不存在再当成系统绝对路径。
LinkTarget resolveMarkdownLink(String? href, {required String fromFile, required String root}) {
  final raw = (href ?? '').trim();
  if (raw.isEmpty) return const LinkTarget(LinkKind.none);
  if (raw.startsWith('#')) return LinkTarget(LinkKind.anchor, fragment: Uri.decodeComponent(raw.substring(1)));

  final uri = Uri.tryParse(raw);
  if (uri != null && uri.hasScheme && !RegExp(r'^[A-Za-z]:[\\/]').hasMatch(raw)) {
    final scheme = uri.scheme.toLowerCase();
    if (const {'http', 'https', 'mailto'}.contains(scheme)) return LinkTarget(LinkKind.external, url: raw);
    if (scheme == 'file') {
      return LinkTarget(LinkKind.file, candidates: [normalizePath(Uri.decodeFull(uri.path))], fragment: uri.fragment.isEmpty ? null : uri.fragment);
    }
    return const LinkTarget(LinkKind.none);
  }

  var path = raw;
  String? fragment;
  final hash = path.indexOf('#');
  if (hash >= 0) {
    fragment = path.substring(hash + 1);
    path = path.substring(0, hash);
  }
  final query = path.indexOf('?');
  if (query >= 0) path = path.substring(0, query);
  if (path.isEmpty) return LinkTarget(LinkKind.anchor, fragment: fragment);
  path = _decode(path);

  if (path.startsWith('/')) {
    return LinkTarget(LinkKind.file, candidates: [normalizePath(absoluteFilePath(root, path.substring(1))), normalizePath(path)], fragment: fragment);
  }
  final from = absoluteFilePath(root, fromFile);
  final slash = from.lastIndexOf('/');
  final dir = slash <= 0 ? root : from.substring(0, slash);
  return LinkTarget(LinkKind.file, candidates: [normalizePath('$dir/$path')], fragment: fragment);
}

String _decode(String s) {
  try {
    return Uri.decodeFull(s);
  } catch (_) {
    return s; // 没编码好的 % 原样留着
  }
}

/// 规整路径:去掉 `.`、重复的 `/`,处理 `..`(不会越过根)。
String normalizePath(String path) {
  final absolute = path.startsWith('/');
  final out = <String>[];
  for (final part in path.split('/')) {
    if (part.isEmpty || part == '.') continue;
    if (part == '..') {
      if (out.isNotEmpty && out.last != '..') {
        out.removeLast();
      } else if (!absolute) {
        out.add('..');
      }
      continue;
    }
    out.add(part);
  }
  return '${absolute ? '/' : ''}${out.join('/')}';
}

enum ImageKind { network, data, file, none }

class ImageSource {
  const ImageSource(this.kind, {this.url = '', this.candidates = const []});

  final ImageKind kind;
  final String url;
  final List<String> candidates;
}

/// 解释 `![alt](src)` 里的 [src]。
ImageSource resolveMarkdownImage(String src, {required String fromFile, required String root}) {
  final raw = src.trim();
  if (raw.isEmpty) return const ImageSource(ImageKind.none);
  final lower = raw.toLowerCase();
  if (lower.startsWith('http://') || lower.startsWith('https://')) return ImageSource(ImageKind.network, url: raw);
  if (lower.startsWith('data:')) return ImageSource(ImageKind.data, url: raw);
  final target = resolveMarkdownLink(raw, fromFile: fromFile, root: root);
  return target.kind == LinkKind.file ? ImageSource(ImageKind.file, candidates: target.candidates) : const ImageSource(ImageKind.none);
}
