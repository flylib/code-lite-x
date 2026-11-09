import '../../core/lsp/java_reference.dart';
import '../../core/lsp/lsp.dart' show LspLocation;
import '../../core/platform/paths.dart' show absoluteFilePath;

/// IntelliJ 的「复制引用」(⌥⇧⌘C)要复制的文字:
/// - Java 文件里光标在类 / 方法 / 字段的**声明**上:`com.foo.Bar`、`com.foo.Bar#baz(com.foo.Dto, int)`、`com.foo.Bar#count`;
/// - 光标在调用处(`service.baz()` 的 baz):先问语言服务器跳到定义([definition]),按定义处算;
/// - 都没有(不是 Java、光标不在名字上、局部变量……):`相对项目的路径:行号`。
///
/// [path] 是标签的路径(相对或绝对),[line] / [col] 从 0 起;[readText] 读别的文件(定义在另一个文件里时)。
Future<String> computeCopyReference({
  required String root,
  required String path,
  required String text,
  required int line,
  required int col,
  Future<LspLocation?> Function()? definition,
  Future<String?> Function(String path)? readText,
}) async {
  final abs = absoluteFilePath(root, path);
  String fallback() {
    final rel = abs.startsWith('$root/') ? abs.substring(root.length + 1) : abs;
    return '$rel:${line + 1}';
  }

  if (!abs.toLowerCase().endsWith('.java')) return fallback();
  final here = javaReferenceAt(text, line, col);
  if (here != null) return here;

  final target = await definition?.call();
  if (target != null) {
    final targetAbs = absoluteFilePath(root, target.path);
    final targetText = targetAbs == abs ? text : await readText?.call(target.path);
    if (targetText != null && targetAbs.toLowerCase().endsWith('.java')) {
      final there = javaReferenceAt(targetText, target.line, target.col);
      if (there != null) return there;
    }
  }
  return fallback();
}
