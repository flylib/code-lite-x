import 'lsp_common.dart' show lspMaskCode;

/// IntelliJ 的「复制引用」格式(Java):类 `com.foo.Outer.Inner`,方法 `com.foo.Bar#baz(java.lang.String, int)`,
/// 字段 `com.foo.Bar#count`。参数类型是擦除泛型后的全限定名。在 Search Everywhere 里输入这种引用能定位回去。
class CodeReference {
  const CodeReference({required this.className, this.member, this.params, this.line});

  /// 点分的类名:可以是全限定名(`com.foo.Bar`),也可以只是后面一段(`foo.Bar`、`Bar`);嵌套类 `Outer.Inner`。
  final String className;

  /// `#` 后面的方法 / 字段名;只给类时为 null。
  final String? member;

  /// 方法的参数类型(给了括号时;`()` 是空列表);没给括号时为 null(不按参数挑重载)。
  final List<String>? params;

  /// `:12` 给出的行号(1 起)。
  final int? line;

  /// 类名的最后一段(简单名)。
  String get simpleName => className.split('.').last;
}

final RegExp _refPattern = RegExp(
  r'^\s*([A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)*)(?:#([A-Za-z_$][\w$]*)(?:\(([^)]*)\))?)?(?::(\d+))?\s*$',
);

/// 把 `com.foo.Bar#baz(java.lang.String)` 这类字符串拆开;不像引用(普通的搜索词、`app.dart` 这种文件名)返回 null。
/// 判断标准:有 `#`,或者有点而且最后一段大写开头(类名)。
CodeReference? parseCodeReference(String raw) {
  final m = _refPattern.firstMatch(raw);
  if (m == null) return null;
  final cls = m.group(1)!;
  final member = m.group(2);
  final last = cls.split('.').last;
  final looksLikeClass = last.isNotEmpty && last[0].toUpperCase() == last[0] && last[0].toLowerCase() != last[0];
  if (member == null && (!cls.contains('.') || !looksLikeClass)) return null;
  if (member != null && !looksLikeClass) return null;
  final paramText = m.group(3);
  return CodeReference(
    className: cls,
    member: member,
    params: paramText == null
        ? (raw.contains('(') && member != null ? const [] : null)
        : [for (final p in _splitTopLevel(paramText)) if (p.trim().isNotEmpty) p.trim()],
    line: m.group(4) == null ? null : int.parse(m.group(4)!),
  );
}

/// 文件里一个类 / 接口 / 枚举 / record 的声明。
class _JavaClass {
  _JavaClass(this.name, this.kind, this.nameOffset, this.open, this.close, this.parent);

  final String name;
  final String kind;
  final int nameOffset;

  /// 类体的 `{` 与对应的 `}`(没闭合时为文本末尾)。
  final int open;
  final int close;
  final _JavaClass? parent;

  /// 从最外层到自己的名字:`Outer.Inner`。
  List<String> get path => [...?parent?.path, name];
}

/// 一次扫描:去掉注释 / 字符串后的文本、包名、import、所有类声明,以及每个位置的花括号 / 圆括号深度。
class _JavaFile {
  _JavaFile(this.text) : masked = lspMaskCode(text, 'java') {
    final n = masked.length;
    braceDepth = List.filled(n + 1, 0);
    parenDepth = List.filled(n + 1, 0);
    var b = 0, p = 0;
    for (var i = 0; i < n; i++) {
      braceDepth[i] = b;
      parenDepth[i] = p;
      final c = masked.codeUnitAt(i);
      if (c == 0x7B) b++;
      if (c == 0x7D && b > 0) b--;
      if (c == 0x28) p++;
      if (c == 0x29 && p > 0) p--;
    }
    braceDepth[n] = b;
    parenDepth[n] = p;

    package = RegExp(r'^\s*package\s+([\w.$]+)\s*;', multiLine: true).firstMatch(masked)?.group(1) ?? '';
    for (final m in RegExp(r'^\s*import\s+(?!static\b)([\w.$]+)\s*;', multiLine: true).allMatches(masked)) {
      final fqn = m.group(1)!;
      imports[fqn.split('.').last] = fqn;
    }

    final stack = <_JavaClass>[];
    for (final m in RegExp(r'\b(class|interface|enum|record)\s+([A-Za-z_$][\w$]*)').allMatches(masked)) {
      // `Foo.class`、`.record(` 这类不是声明
      if (m.start > 0 && masked[m.start - 1] == '.') continue;
      final open = masked.indexOf('{', m.end);
      if (open < 0) continue;
      // record 的头里有括号;别的声明在 `{` 之前不应出现 `;`
      final header = masked.substring(m.end, open);
      if (header.contains(';')) continue;
      final close = _matching(open);
      while (stack.isNotEmpty && stack.last.close < m.start) {
        stack.removeLast();
      }
      final cls = _JavaClass(m.group(2)!, m.group(1)!, m.start + m.group(0)!.length - m.group(2)!.length, open, close,
          stack.isEmpty ? null : stack.last);
      classes.add(cls);
      stack.add(cls);
    }
  }

  final String text;
  final String masked;
  late final List<int> braceDepth;
  late final List<int> parenDepth;
  late final String package;
  final Map<String, String> imports = {};
  final List<_JavaClass> classes = [];

  int _matching(int open) {
    var d = 0;
    for (var i = open; i < masked.length; i++) {
      final c = masked.codeUnitAt(i);
      if (c == 0x7B) d++;
      if (c == 0x7D && --d == 0) return i;
    }
    return masked.length;
  }

  /// 包住 [offset] 的最内层类(在类体里,不含声明头)。
  _JavaClass? enclosing(int offset) {
    _JavaClass? best;
    for (final c in classes) {
      if (c.open < offset && offset < c.close && (best == null || c.open > best.open)) best = c;
    }
    return best;
  }

  String fqnOf(_JavaClass c) => [if (package.isNotEmpty) package, ...c.path].join('.');

  /// [offset] 在 [c] 的类体这一层(不在方法体、初始化块或括号里)。
  bool memberLevel(_JavaClass c, int offset) =>
      braceDepth[offset] == braceDepth[c.open] + 1 && parenDepth[offset] == parenDepth[c.open];

  int skipSpaceForward(int i) {
    while (i < masked.length && _isSpace(masked.codeUnitAt(i))) {
      i++;
    }
    return i;
  }

  int skipSpaceBack(int i) {
    while (i > 0 && _isSpace(masked.codeUnitAt(i - 1))) {
      i--;
    }
    return i;
  }

  /// [start] 之前紧挨着的那个词(跳过空白)。
  String previousWord(int start) {
    final e = skipSpaceBack(start);
    var s = e;
    while (s > 0 && _isIdent(masked.codeUnitAt(s - 1))) {
      s--;
    }
    return masked.substring(s, e);
  }

  /// [start, end) 这个名字是不是 [c] 里的成员声明:方法 / 构造器返回 'method',字段 / 枚举常量返回 'field',否则 null。
  String? memberKind(_JavaClass c, int start, int end) {
    if (!memberLevel(c, start)) return null;
    final after = skipSpaceForward(end);
    final next = after < masked.length ? masked[after] : '';
    final beforeEnd = skipSpaceBack(start);
    final prev = beforeEnd > 0 ? masked[beforeEnd - 1] : '';
    final prevWord = previousWord(start);
    if (prev == '@' || prev == '.' || prevWord == 'new') return null;

    // 枚举常量:类体里第一个顶层 `;` 之前的名字
    if (c.kind == 'enum' && !_hasMemberSemicolon(c, start) && (next == '(' || next == ',' || next == ';' || next == '{' || next == '}')) {
      return 'field';
    }
    final typeBefore = prev.isNotEmpty && (_isIdent(prev.codeUnitAt(0)) || prev == '>' || prev == ']');
    if (next == '(') {
      if (typeBefore && !_keywords.contains(prevWord)) return 'method';
      // 构造器:前面是修饰符、注解的 `)`、上一个成员的结尾或类体开头
      final name = masked.substring(start, end);
      if (name == c.name && (prev == '' || prev == ';' || prev == '{' || prev == '}' || prev == ')' || _modifiers.contains(prevWord))) {
        return 'method';
      }
      return null;
    }
    if ((next == '=' || next == ';' || next == ',') && typeBefore && !_keywords.contains(prevWord)) return 'field';
    return null;
  }

  bool _hasMemberSemicolon(_JavaClass c, int before) {
    for (var i = c.open + 1; i < before; i++) {
      if (masked.codeUnitAt(i) == 0x3B && memberLevel(c, i)) return true;
    }
    return false;
  }

  /// 方法名后面括号里的参数类型(擦除泛型、去掉注解和 final,还没限定)。
  List<String> paramTypes(int nameEnd) {
    final open = masked.indexOf('(', nameEnd);
    if (open < 0) return const [];
    var d = 0, close = masked.length;
    for (var i = open; i < masked.length; i++) {
      final c = masked.codeUnitAt(i);
      if (c == 0x28) d++;
      if (c == 0x29 && --d == 0) {
        close = i;
        break;
      }
    }
    final inside = masked.substring(open + 1, close);
    return [
      for (final p in _splitTopLevel(inside))
        if (_paramType(p) case final t? when t.isNotEmpty) t,
    ];
  }

  /// 擦除泛型后的类型 → 全限定名(IntelliJ 复制引用的写法)。
  String qualify(String type) {
    var base = type.replaceAll(RegExp(r'\s+'), '');
    var suffix = '';
    while (true) {
      if (base.endsWith('[]')) {
        suffix = '[]$suffix';
        base = base.substring(0, base.length - 2);
      } else if (base.endsWith('...')) {
        suffix = '...$suffix';
        base = base.substring(0, base.length - 3);
      } else {
        break;
      }
    }
    if (_primitives.contains(base)) return '$base$suffix';
    final parts = base.split('.');
    final first = parts.first;
    // 已经是全限定名(小写开头的包名)
    if (parts.length > 1 && first.isNotEmpty && first[0] == first[0].toLowerCase()) return '$base$suffix';
    final nested = classes.where((c) => c.name == first).firstOrNull;
    final head = imports[first] ??
        (nested != null ? fqnOf(nested) : null) ??
        (_javaLang.contains(first) ? 'java.lang.$first' : null) ??
        (_looksLikeTypeParameter(first) ? first : (package.isEmpty ? first : '$package.$first'));
    return [head, ...parts.skip(1)].join('.') + suffix;
  }

  ({int line, int col}) lineColOf(int offset) {
    var line = 0, start = 0;
    for (var i = 0; i < offset && i < text.length; i++) {
      if (text.codeUnitAt(i) == 0x0A) {
        line++;
        start = i + 1;
      }
    }
    return (line: line, col: offset - start);
  }

  int offsetOf(int line, int col) {
    var l = 0, i = 0;
    while (l < line && i < text.length) {
      if (text.codeUnitAt(i) == 0x0A) l++;
      i++;
    }
    var end = text.indexOf('\n', i);
    if (end < 0) end = text.length;
    return (i + col).clamp(i, end);
  }
}

/// [text] 第 [line] 行第 [col] 列(都从 0 起)那个名字的 IntelliJ 引用:它是类 / 方法 / 构造器 / 字段 / 枚举常量的
/// **声明**时才有(局部变量、参数、调用处都返回 null,调用处要先跳到定义再算)。
String? javaReferenceAt(String text, int line, int col) {
  final f = _JavaFile(text);
  final at = f.offsetOf(line, col);
  var s = at, e = at;
  while (s > 0 && _isIdent(f.masked.codeUnitAt(s - 1))) {
    s--;
  }
  while (e < f.masked.length && _isIdent(f.masked.codeUnitAt(e))) {
    e++;
  }
  if (s == e || _isDigit(f.masked.codeUnitAt(s))) return null;

  final declared = f.classes.where((c) => c.nameOffset == s).firstOrNull;
  if (declared != null) return f.fqnOf(declared);

  final cls = f.enclosing(s);
  if (cls == null) return null;
  final name = f.masked.substring(s, e);
  return switch (f.memberKind(cls, s, e)) {
    'method' => '${f.fqnOf(cls)}#$name(${f.paramTypes(e).map(f.qualify).join(', ')})',
    'field' => '${f.fqnOf(cls)}#$name',
    _ => null,
  };
}

/// 在 [text] 里找引用指的位置:[classPath] 是类名的最后几段(`['Bar']`、`['Outer', 'Inner']`),
/// [member] 为 null 时找类的声明;[params] 给了就按参数个数和类型简单名挑重载,挑不出来用第一个同名的。
/// 返回名字所在的行列(0 起);找不到返回 null。
({int line, int col})? findJavaMember(String text, List<String> classPath, {String? member, List<String>? params}) {
  final f = _JavaFile(text);
  bool pathMatches(_JavaClass c) {
    final p = c.path;
    if (p.length < classPath.length) return false;
    for (var i = 1; i <= classPath.length; i++) {
      if (p[p.length - i] != classPath[classPath.length - i]) return false;
    }
    return true;
  }

  final cls = f.classes.where(pathMatches).firstOrNull;
  if (cls == null) return null;
  if (member == null) return f.lineColOf(cls.nameOffset);

  final candidates = <(int, String)>[];
  for (final m in RegExp('\\b${RegExp.escape(member)}\\b').allMatches(f.masked)) {
    if (m.start <= cls.open || m.end >= cls.close || f.enclosing(m.start) != cls) continue;
    final kind = f.memberKind(cls, m.start, m.end);
    if (kind != null) candidates.add((m.start, kind));
  }
  if (candidates.isEmpty) return null;
  if (params != null) {
    String simple(String t) => t.replaceAll(RegExp(r'\s+'), '').split('.').last;
    for (final (start, kind) in candidates) {
      if (kind != 'method') continue;
      final types = f.paramTypes(start + member.length);
      if (types.length != params.length) continue;
      var same = true;
      for (var i = 0; i < types.length; i++) {
        if (simple(types[i]) != simple(_erase(params[i]))) same = false;
      }
      if (same) return f.lineColOf(start);
    }
  }
  return f.lineColOf(candidates.first.$1);
}

/// 一个参数声明 → 它的类型(去掉注解、final、名字,擦除泛型)。
String? _paramType(String raw) {
  var p = raw.replaceAll(RegExp(r'@[\w$.]+\s*(\([^()]*\))?'), ' ').replaceAll(RegExp(r'\bfinal\b'), ' ').trim();
  if (p.isEmpty) return null;
  p = _erase(p);
  // C 风格数组 `int a[]`:把 [] 挪到类型上
  var trailing = '';
  final c = RegExp(r'((?:\s*\[\s*\])+)\s*$').firstMatch(p);
  if (c != null) {
    trailing = c.group(1)!.replaceAll(RegExp(r'\s+'), '');
    p = p.substring(0, c.start);
  }
  final name = RegExp(r'[A-Za-z_$][\w$]*\s*$').firstMatch(p);
  if (name == null) return null;
  final type = p.substring(0, name.start).trim();
  if (type.isEmpty) return null; // lambda 参数之类没有类型
  return type.replaceAll(RegExp(r'\s+'), '') + trailing;
}

/// 去掉 `<...>`(可嵌套)。
String _erase(String type) {
  final out = StringBuffer();
  var d = 0;
  for (final ch in type.split('')) {
    if (ch == '<') {
      d++;
    } else if (ch == '>') {
      if (d > 0) d--;
    } else if (d == 0) {
      out.write(ch);
    }
  }
  return out.toString().trim();
}

/// 按顶层逗号拆(尖括号、圆括号里的逗号不算)。
List<String> _splitTopLevel(String s) {
  final out = <String>[];
  var d = 0, start = 0;
  for (var i = 0; i < s.length; i++) {
    final ch = s[i];
    if (ch == '<' || ch == '(') d++;
    if ((ch == '>' || ch == ')') && d > 0) d--;
    if (ch == ',' && d == 0) {
      out.add(s.substring(start, i));
      start = i + 1;
    }
  }
  out.add(s.substring(start));
  return out;
}

bool _looksLikeTypeParameter(String name) => RegExp(r'^[A-Z][A-Z0-9]?$').hasMatch(name);

bool _isIdent(int c) => (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36;
bool _isDigit(int c) => c >= 48 && c <= 57;
bool _isSpace(int c) => c == 0x20 || c == 0x09 || c == 0x0A || c == 0x0D;

const _primitives = {'boolean', 'byte', 'char', 'short', 'int', 'long', 'float', 'double', 'void'};
const _modifiers = {'public', 'protected', 'private', 'static', 'final', 'abstract', 'synchronized', 'native', 'strictfp', 'default'};
const _keywords = {'return', 'new', 'throw', 'case', 'else', 'do', 'if', 'while', 'for', 'switch', 'catch', 'yield', 'assert'};
const _javaLang = {
  'Object', 'String', 'Integer', 'Long', 'Short', 'Byte', 'Character', 'Boolean', 'Double', 'Float', 'Number', 'Void',
  'Class', 'Enum', 'Record', 'Iterable', 'Comparable', 'CharSequence', 'Runnable', 'Thread', 'Throwable', 'Exception',
  'RuntimeException', 'Error', 'StringBuilder', 'StringBuffer', 'Math', 'System', 'Override', 'Deprecated',
  'FunctionalInterface', 'SuppressWarnings', 'AutoCloseable', 'Cloneable', 'IllegalArgumentException',
  'IllegalStateException', 'NullPointerException', 'UnsupportedOperationException', 'InterruptedException',
};
