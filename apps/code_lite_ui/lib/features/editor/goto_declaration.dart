import '../../core/lsp/java_reference.dart' show findJavaMember;
import '../../core/lsp/lsp.dart' show LspLocation;
import '../../core/lsp/lsp_common.dart' show lspMaskCode, lspLanguageIdFor;

/// 跳到哪里:[path] 是语言服务器 / 文件索引给的路径(相对项目)或当前标签的路径,[line] / [col] 从 0 起。
class DeclarationTarget {
  const DeclarationTarget(this.path, this.line, this.col);

  final String path;
  final int line;
  final int col;
}

/// [text] 第 [line] 行第 [col] 列(0 起)上的名字;光标不在名字上返回 null。
({String name, int start, int end})? identifierAt(String text, int line, int col) {
  final lines = text.split('\n');
  if (line < 0 || line >= lines.length) return null;
  final s = lines[line];
  var a = col.clamp(0, s.length), b = col.clamp(0, s.length);
  while (a > 0 && _isIdent(s.codeUnitAt(a - 1))) {
    a--;
  }
  while (b < s.length && _isIdent(s.codeUnitAt(b))) {
    b++;
  }
  if (a == b || _isDigit(s.codeUnitAt(a))) return null;
  return (name: s.substring(a, b), start: a, end: b);
}

/// ⌘B(IntelliJ 的 Go to Declaration):光标上的函数 / 变量 / 类型声明在哪。
/// 1. 语言服务器的 textDocument/definition([definition]),能跨文件、认得重载和作用域;
/// 2. 没有语言服务器时:当前文件的大纲([outline])里同名的方法 / 字段 / 类;
/// 3. 当前文件里像声明的那一处(`Type name =`、`var name`、参数……),优先光标前面最近的;
/// 4. 大写开头的名字:同名的源文件([filesNamed]),跳到类的声明。
/// 都找不到返回 null。
Future<DeclarationTarget?> findDeclaration({
  required String path,
  required String text,
  required int line,
  required int col,
  Future<LspLocation?> Function()? definition,
  Future<List<Map<String, dynamic>>> Function()? outline,
  List<String> Function(String name)? filesNamed,
  Future<String?> Function(String path)? readText,
}) async {
  final id = identifierAt(text, line, col);
  if (id == null) return null;
  final name = id.name;

  final def = await definition?.call();
  if (def != null) return DeclarationTarget(def.path, def.line, def.col);

  bool atCaret(int l, int c) => l == line && c <= id.end && id.start <= c + name.length;

  // 大纲里同名的(jdtls 的方法名带参数:`foo(int)`)
  if (outline != null) {
    final found = <Map<String, dynamic>>[];
    void walk(List<dynamic> nodes) {
      for (final n in nodes) {
        if (n is! Map) continue;
        final base = (n['name'] as String? ?? '').split('(').first.trim();
        if (base == name) found.add(Map<String, dynamic>.from(n));
        walk(n['children'] as List? ?? const []);
      }
    }

    walk(await outline());
    for (final n in found) {
      final l = (n['line_start'] as num?)?.toInt() ?? 0;
      final c = (n['col_start'] as num?)?.toInt() ?? 0;
      if (!atCaret(l, c)) return DeclarationTarget(path, l, c);
    }
  }

  final local = _localDeclaration(path, text, name, line, id.start);
  if (local != null) return DeclarationTarget(path, local.$1, local.$2);

  // 类型:同名源文件
  if (filesNamed != null && name[0].toUpperCase() == name[0] && name[0].toLowerCase() != name[0]) {
    for (final p in filesNamed(name)) {
      final other = await readText?.call(p);
      if (other == null) return DeclarationTarget(p, 0, 0);
      if (p.toLowerCase().endsWith('.java')) {
        final at = findJavaMember(other, [name]);
        if (at != null) return DeclarationTarget(p, at.line, at.col);
      }
      final m = RegExp('\\b(?:class|interface|enum|struct|record|object|trait|mixin|extension|typedef|type)\\s+${RegExp.escape(name)}\\b').firstMatch(other);
      if (m == null) return DeclarationTarget(p, 0, 0);
      final before = other.substring(0, m.end - name.length);
      final l = '\n'.allMatches(before).length;
      return DeclarationTarget(p, l, before.length - (before.lastIndexOf('\n') + 1));
    }
  }
  return null;
}

/// 当前文件里看起来像 [name] 声明的地方:前面是类型(名字、`>`、`]`)或 var / let / const / val / final / def / fn……,
/// 后面是 `=` `;` `,` `)` `:`(或者函数关键字后面的 `(`)。光标那一处不算;先找光标前最近的,再找后面第一个。
(int, int)? _localDeclaration(String path, String text, String name, int caretLine, int caretCol) {
  final masked = lspMaskCode(text, lspLanguageIdFor(path));
  final lineStarts = <int>[0];
  for (var i = 0; i < masked.length; i++) {
    if (masked.codeUnitAt(i) == 0x0A) lineStarts.add(i + 1);
  }
  final caret = (caretLine < lineStarts.length ? lineStarts[caretLine] : masked.length) + caretCol;
  (int, int) lineCol(int offset) {
    var lo = 0, hi = lineStarts.length - 1;
    while (lo < hi) {
      final mid = (lo + hi + 1) >> 1;
      if (lineStarts[mid] <= offset) {
        lo = mid;
      } else {
        hi = mid - 1;
      }
    }
    return (lo, offset - lineStarts[lo]);
  }

  int? before, after;
  for (final m in RegExp('(?<![\\w\$])${RegExp.escape(name)}(?![\\w\$])').allMatches(masked)) {
    if (m.start == caret || (m.start <= caret && caret <= m.end)) continue;
    if (!_looksLikeDeclaration(masked, m.start, m.end)) continue;
    if (m.start < caret) {
      before = m.start;
    } else {
      after ??= m.start;
    }
  }
  final at = before ?? after;
  return at == null ? null : lineCol(at);
}

bool _looksLikeDeclaration(String s, int start, int end) {
  var i = start;
  while (i > 0 && _isSpace(s.codeUnitAt(i - 1))) {
    i--;
  }
  final prev = i > 0 ? s[i - 1] : '';
  var w = i;
  while (w > 0 && _isIdent(s.codeUnitAt(w - 1))) {
    w--;
  }
  final prevWord = s.substring(w, i);
  var j = end;
  while (j < s.length && (s.codeUnitAt(j) == 0x20 || s.codeUnitAt(j) == 0x09)) {
    j++;
  }
  final next = j < s.length ? s[j] : '';
  if (_declKeywords.contains(prevWord)) return true;
  if (_functionKeywords.contains(prevWord)) return next == '(' || next == '<';
  if (prev == '.' || prev == '@' || _notTypes.contains(prevWord)) return false;
  final typeBefore = prev.isNotEmpty && (_isIdent(prev.codeUnitAt(0)) || prev == '>' || prev == ']' || prev == '?');
  return typeBefore && (next == '=' || next == ';' || next == ',' || next == ')' || next == ':') && !(next == '=' && j + 1 < s.length && s[j + 1] == '=');
}

const _declKeywords = {'var', 'let', 'const', 'val', 'final', 'late'};
const _functionKeywords = {'def', 'fn', 'func', 'function', 'fun', 'class', 'interface', 'enum', 'struct', 'trait', 'type'};
const _notTypes = {
  'return', 'new', 'throw', 'else', 'case', 'yield', 'await', 'typeof', 'instanceof', 'in', 'of', 'is', 'as', 'not', 'and', 'or', 'if',
  'while', 'for', 'switch', 'catch', 'do', 'delete', 'void', 'import', 'package', 'export', 'from', 'goto', 'assert',
};

bool _isIdent(int c) => (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36;
bool _isDigit(int c) => c >= 48 && c <= 57;
bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;
