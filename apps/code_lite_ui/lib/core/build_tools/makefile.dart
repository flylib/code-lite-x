/// Makefile 的目标(IntelliJ 的 make 工具窗 / 行号栏的运行按钮用):不跑 make,按 GNU make 的语法读规则行。
library;

/// Makefile 里的一个目标。
class MakeTarget {
  const MakeTarget(this.name, this.line);

  final String name;

  /// 定义它的行(0 起;规则续行时是第一行)。
  final int line;

  /// `.PHONY`、`.DEFAULT` 这类以点开头的特殊目标:默认不显示。
  bool get special => name.startsWith('.');

  @override
  bool operator ==(Object other) => other is MakeTarget && other.name == name && other.line == line;

  @override
  int get hashCode => Object.hash(name, line);

  @override
  String toString() => '$name@$line';
}

/// 文件名是不是 Makefile(GNU make 默认找的三个名字,以及 `.mk` / `.mak` 片段)。
bool isMakefileName(String path) {
  final name = path.split(RegExp(r'[/\\]')).last;
  if (name == 'Makefile' || name == 'makefile' || name == 'GNUmakefile') return true;
  final lower = name.toLowerCase();
  return lower.endsWith('.mk') || lower.endsWith('.mak');
}

/// make 不加 `-f` 就会找的文件名。
bool isDefaultMakefileName(String name) => name == 'Makefile' || name == 'makefile' || name == 'GNUmakefile';

const Set<String> _directives = {
  'include', '-include', 'sinclude', 'ifeq', 'ifneq', 'ifdef', 'ifndef', 'else', 'endif', 'export', 'unexport',
  'override', 'vpath', 'undefine', 'private', 'load', '-load',
};

/// 读出 [text] 里的目标(按出现顺序,同名的只留第一次定义)。
///
/// 规则行:不以 Tab 开头(那是命令)、冒号前没有 `=`(变量赋值)、冒号不是 `:=` / `::=` / `:::=`。
/// 模式规则(`%.o: %.c`)和用了变量的目标名(`$(BIN):`)不算,跑不了;`define … endef` 里的内容跳过。
List<MakeTarget> parseMakeTargets(String text) {
  final lines = text.split('\n');
  final out = <MakeTarget>[];
  final seen = <String>{};
  var inDefine = false;
  var i = 0;
  while (i < lines.length) {
    final start = i;
    var line = lines[i].replaceAll('\r', '');
    // 反斜杠续行拼成一行
    while (line.endsWith('\\') && i + 1 < lines.length) {
      i++;
      line = '${line.substring(0, line.length - 1)} ${lines[i].replaceAll('\r', '').trimLeft()}';
    }
    i++;
    if (line.startsWith('\t')) continue; // 命令
    final trimmed = line.trimLeft();
    final word = trimmed.split(RegExp(r'\s+')).first;
    if (inDefine) {
      if (word == 'endef') inDefine = false;
      continue;
    }
    if (word == 'define' || (word == 'override' && trimmed.split(RegExp(r'\s+')).elementAtOrNull(1) == 'define')) {
      inDefine = true;
      continue;
    }
    if (trimmed.isEmpty || trimmed.startsWith('#') || _directives.contains(word)) continue;
    final hash = line.indexOf('#');
    final code = hash >= 0 ? line.substring(0, hash) : line;
    final colon = _ruleColon(code);
    if (colon < 0) continue;
    final head = code.substring(0, colon);
    if (head.contains('=')) continue; // 变量赋值(值里带冒号)
    for (final name in head.trim().split(RegExp(r'\s+'))) {
      if (name.isEmpty || name.contains('%') || name.contains(r'$')) continue;
      if (seen.add(name)) out.add(MakeTarget(name, start));
    }
  }
  return out;
}

/// 规则的冒号位置;是赋值(`:=` `::=` `:::=`)或没有冒号时返回 -1。
int _ruleColon(String code) {
  var depth = 0; // $( … ) 里的冒号不算(比如 $(subst a:b, …))
  for (var k = 0; k < code.length; k++) {
    final c = code[k];
    if (c == r'$' && k + 1 < code.length && (code[k + 1] == '(' || code[k + 1] == '{')) {
      depth++;
      k++;
      continue;
    }
    if ((c == ')' || c == '}') && depth > 0) {
      depth--;
      continue;
    }
    if (c != ':' || depth > 0) continue;
    var j = k;
    while (j < code.length && code[j] == ':') {
      j++;
    }
    if (j < code.length && code[j] == '=') return -1; // := ::= :::=
    return k;
  }
  return -1;
}

/// 运行 [target] 的命令行(在项目根目录的 shell 里执行)。
///
/// [make] 是设置里的 make 路径(空则用 PATH 里的 `make`);[makefile] 相对项目根:
/// 不在根目录时加 `-C <目录>`,不是默认文件名时加 `-f <文件名>`。
String makeCommandLine(String make, String makefile, String target) {
  final exe = make.trim().isEmpty ? 'make' : make.trim();
  final parts = makefile.replaceAll('\\', '/').split('/');
  final name = parts.removeLast();
  final dir = parts.join('/');
  return [
    _quote(exe),
    if (dir.isNotEmpty) ...['-C', _quote(dir)],
    if (!isDefaultMakefileName(name)) ...['-f', _quote(name)],
    _quote(target),
  ].join(' ');
}

String _quote(String s) => RegExp(r'^[A-Za-z0-9_./:=@%+,-]+$').hasMatch(s) ? s : "'${s.replaceAll("'", r"'\''")}'";
