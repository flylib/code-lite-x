import '../l10n/l10n.dart';

/// 标签的路径转成绝对路径。文件树给的标签路径本来就是绝对路径(项目内其它入口给的是相对项目根的),
/// 绝对的原样返回,相对的接在 [root] 后面。
String absoluteFilePath(String root, String path) {
  final absolute = path.startsWith('/') || path.startsWith(r'\\') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
  if (absolute) return path;
  return root.endsWith('/') || root.endsWith(r'\') ? '$root$path' : '$root/$path';
}

/// 改名时新名字哪里不行(空、带 `/`、`.` / `..`);可以用返回 null。
String? renameNameError(String name) {
  final n = name.trim();
  if (n.isEmpty) return tr('名字不能为空', 'The name cannot be empty');
  if (n.contains('/') || n.contains(r'\')) return tr('名字里不能有 /', 'The name cannot contain /');
  if (n == '.' || n == '..') return tr('不能叫 $n', 'The name cannot be $n');
  return null;
}
