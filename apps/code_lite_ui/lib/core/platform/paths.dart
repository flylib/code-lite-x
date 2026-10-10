/// 标签的路径转成绝对路径。文件树给的标签路径本来就是绝对路径(项目内其它入口给的是相对项目根的),
/// 绝对的原样返回,相对的接在 [root] 后面。
String absoluteFilePath(String root, String path) {
  final absolute = path.startsWith('/') || path.startsWith(r'\\') || RegExp(r'^[A-Za-z]:[\\/]').hasMatch(path);
  if (absolute) return path;
  return root.endsWith('/') || root.endsWith(r'\') ? '$root$path' : '$root/$path';
}
