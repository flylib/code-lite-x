/// 由 [LanguageSpec] 驱动的逐行分词器。
///
/// 每行的输入是「上一行结束时的状态」,输出 token 和本行结束时的状态 —— 跨行的块注释、
/// 多行字符串、XML 注释 / 跨行属性、Markdown 代码围栏因此都能正确着色,
/// 而且改一行只需从这一行往后重算到状态不再变化为止(见 DocumentHighlighter)。
library;

import 'language.dart';

enum TokenKind {
  plain,
  keyword,
  type,
  constant,
  builtin,
  function,
  string,
  number,
  comment,
  docComment,
  annotation,
  variable,

  /// 全大写常量(MAX_SIZE)/ JSON 的键 —— IntelliJ 里的紫色。
  field,
  punctuation,
  // 标记语言
  tag,
  attribute,
  attrValue,
  entity,
  // Markdown
  heading,
  bold,
  italic,
  link,
  codeSpan,
  listMarker,
  quote,
  // 配置文件
  key,
  section,
}

class Token {
  const Token(this.start, this.end, this.kind);
  final int start;
  final int end;
  final TokenKind kind;

  @override
  String toString() => '$kind[$start,$end)';
}

class LineTokens {
  const LineTokens(this.tokens, this.endState);
  final List<Token> tokens;

  /// 下一行的起始状态。0 = 普通。
  final int endState;
}

/// 对一行分词。[state] 是上一行的 [LineTokens.endState](第一行为 0)。
LineTokens tokenizeLine(LanguageSpec lang, String line, int state) => switch (lang.mode) {
      SyntaxMode.code => _CodeLexer(lang, line).run(state),
      SyntaxMode.markup => _markup(line, state),
      SyntaxMode.json => _json(line, state),
      SyntaxMode.yaml => _yaml(line),
      SyntaxMode.markdown => _markdown(line, state),
      SyntaxMode.ini => _ini(lang, line, state),
      SyntaxMode.plain => LineTokens(line.isEmpty ? const [] : [Token(0, line.length, TokenKind.plain)], 0),
    };

// ---------------------------------------------------------------------------
// 公共
// ---------------------------------------------------------------------------

class _Out {
  final List<Token> tokens = [];

  /// 相邻同类 token 合并,减少 TextSpan 数量。
  void add(int start, int end, TokenKind kind) {
    if (end <= start) return;
    if (tokens.isNotEmpty) {
      final last = tokens.last;
      if (last.end == start && last.kind == kind) {
        tokens[tokens.length - 1] = Token(last.start, end, kind);
        return;
      }
    }
    tokens.add(Token(start, end, kind));
  }
}

bool _isDigit(int c) => c >= 48 && c <= 57;
bool _isLetter(int c) => (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127;
bool _isSpace(int c) => c == 32 || c == 9;

/// 找字符串的结束位置(返回闭合符之后的下标),没闭合返回 -1。
int _findClose(String s, int from, StringRule rule) {
  var j = from;
  while (j < s.length) {
    if (rule.escapes && s.codeUnitAt(j) == 92) {
      j += 2;
      continue;
    }
    if (s.startsWith(rule.close, j)) return j + rule.close.length;
    j++;
  }
  return -1;
}

// ---------------------------------------------------------------------------
// 类 C 代码
// ---------------------------------------------------------------------------

/// 状态编码:1..9 = 第 (k-1) 个块注释内;10.. = 第 (k-10) 个多行字符串内。
class _CodeLexer {
  _CodeLexer(this.l, this.s);

  final LanguageSpec l;
  final String s;
  final _Out out = _Out();

  bool _identStart(int c) => _isLetter(c) || (l.identifierExtra.isNotEmpty && l.identifierExtra.codeUnits.contains(c) && c != 45);
  bool _identChar(int c) => _isLetter(c) || _isDigit(c) || l.identifierExtra.codeUnits.contains(c);

  TokenKind _commentKind(int index) {
    final open = l.blockComments[index].$1;
    return l.docComment != null && open == l.docComment ? TokenKind.docComment : TokenKind.comment;
  }

  LineTokens run(int state) {
    final n = s.length;
    var i = 0;
    if (state >= 1 && state < 10 && state - 1 < l.blockComments.length) {
      final close = l.blockComments[state - 1].$2;
      final e = s.indexOf(close);
      if (e < 0) {
        out.add(0, n, _commentKind(state - 1));
        return LineTokens(out.tokens, state);
      }
      out.add(0, e + close.length, _commentKind(state - 1));
      i = e + close.length;
    } else if (state >= 10 && state - 10 < l.strings.length) {
      final rule = l.strings[state - 10];
      final e = _findClose(s, 0, rule);
      if (e < 0) {
        out.add(0, n, TokenKind.string);
        return LineTokens(out.tokens, state);
      }
      out.add(0, e, TokenKind.string);
      i = e;
    }

    // C 预处理:行首 #include / #define …… 指令名用注解色,其余照常分词。
    if (l.preprocessor && i == 0) {
      var k = 0;
      while (k < n && _isSpace(s.codeUnitAt(k))) {
        k++;
      }
      if (k < n && s.codeUnitAt(k) == 35) {
        var e = k + 1;
        while (e < n && _isSpace(s.codeUnitAt(e))) {
          e++;
        }
        while (e < n && _isLetter(s.codeUnitAt(e))) {
          e++;
        }
        out.add(0, k, TokenKind.plain);
        out.add(k, e, TokenKind.annotation);
        i = e;
        // #include <foo.h>
        final rest = s.substring(e).trimLeft();
        if (rest.startsWith('<') && rest.contains('>')) {
          final a = s.indexOf('<', e), b = s.indexOf('>', a);
          out.add(e, a, TokenKind.plain);
          out.add(a, b + 1, TokenKind.string);
          i = b + 1;
        }
      }
    }

    while (i < n) {
      final c = s.codeUnitAt(i);
      if (_isSpace(c)) {
        final a = i;
        while (i < n && _isSpace(s.codeUnitAt(i))) {
          i++;
        }
        out.add(a, i, TokenKind.plain);
        continue;
      }
      // 行注释
      if (l.lineComments.any((p) => s.startsWith(p, i))) {
        out.add(i, n, TokenKind.comment);
        return LineTokens(out.tokens, 0);
      }
      // 块注释
      final bi = _blockAt(i);
      if (bi >= 0) {
        final (open, close) = l.blockComments[bi];
        final e = s.indexOf(close, i + open.length);
        if (e < 0) {
          out.add(i, n, _commentKind(bi));
          return LineTokens(out.tokens, bi + 1);
        }
        out.add(i, e + close.length, _commentKind(bi));
        i = e + close.length;
        continue;
      }
      // 字符串
      final si = _stringAt(i);
      if (si >= 0) {
        final rule = l.strings[si];
        final e = _findClose(s, i + rule.open.length, rule);
        if (rule.maxLength != null && !_isCharLiteral(i + rule.open.length, e, rule)) {
          // 不是字符字面量(Rust 生命周期 'a、Kotlin 之外的撇号):当普通字符
          out.add(i, i + 1, TokenKind.punctuation);
          i++;
          continue;
        }
        if (e < 0) {
          out.add(i, n, TokenKind.string);
          return LineTokens(out.tokens, rule.multiline ? 10 + si : 0);
        }
        out.add(i, e, TokenKind.string);
        i = e;
        continue;
      }
      // 注解 / 装饰器 / Rust 属性
      final ann = l.annotation;
      if (ann != null && s.startsWith(ann, i)) {
        if (ann == '#[') {
          final e = s.indexOf(']', i);
          final end = e < 0 ? n : e + 1;
          out.add(i, end, TokenKind.annotation);
          i = end;
          continue;
        }
        if (i + 1 < n && _identStart(s.codeUnitAt(i + 1))) {
          var e = i + 1;
          while (e < n && (_identChar(s.codeUnitAt(e)) || s.codeUnitAt(e) == 46 || s.codeUnitAt(e) == 45)) {
            e++;
          }
          out.add(i, e, TokenKind.annotation);
          i = e;
          continue;
        }
      }
      // $变量 / ${变量} / @实例变量
      final sigil = l.variableSigil;
      if (sigil != null && s.startsWith(sigil, i) && i + 1 < n) {
        final next = s.codeUnitAt(i + 1);
        if (next == 123) {
          final e = s.indexOf('}', i);
          final end = e < 0 ? n : e + 1;
          out.add(i, end, TokenKind.variable);
          i = end;
          continue;
        }
        if (next == 40 && sigil == r'$') {
          // $(...) 命令替换 / Makefile 变量
          final e = s.indexOf(')', i);
          final end = e < 0 ? n : e + 1;
          out.add(i, end, TokenKind.variable);
          i = end;
          continue;
        }
        if (_isLetter(next) || _isDigit(next) || '@*#?!-'.codeUnits.contains(next)) {
          var e = i + 2;
          if (_isLetter(next)) {
            while (e < n && (_isLetter(s.codeUnitAt(e)) || _isDigit(s.codeUnitAt(e)))) {
              e++;
            }
          }
          out.add(i, e, TokenKind.variable);
          i = e;
          continue;
        }
      }
      // 数字
      final prevIdent = i > 0 && _identChar(s.codeUnitAt(i - 1));
      if (!prevIdent && (_isDigit(c) || (c == 46 && i + 1 < n && _isDigit(s.codeUnitAt(i + 1))))) {
        var e = i + 1;
        while (e < n) {
          final d = s.codeUnitAt(e);
          if (_isDigit(d) || _isLetter(d)) {
            e++;
          } else if (d == 46 && e + 1 < n && _isDigit(s.codeUnitAt(e + 1))) {
            e++;
          } else if ((d == 43 || d == 45) && (s.codeUnitAt(e - 1) | 32) == 101 && !s.startsWith('0x', i)) {
            e++; // 1e-5
          } else {
            break;
          }
        }
        out.add(i, e, TokenKind.number);
        i = e;
        continue;
      }
      // 标识符
      if (_identStart(c)) {
        var e = i + 1;
        while (e < n && _identChar(s.codeUnitAt(e))) {
          e++;
        }
        out.add(i, e, _classify(s.substring(i, e), e));
        i = e;
        continue;
      }
      out.add(i, i + 1, TokenKind.punctuation);
      i++;
    }
    return LineTokens(out.tokens, 0);
  }

  /// 字符字面量:正好一个字符('x'、'中'、emoji 代理对),或以 \ 开头的短转义('\n'、'\u{1F600}')。
  bool _isCharLiteral(int contentStart, int end, StringRule rule) {
    if (end < 0) return false;
    final len = end - rule.close.length - contentStart;
    if (len <= 0) return false;
    if (s.codeUnitAt(contentStart) == 92) return end - contentStart <= rule.maxLength!;
    return len == 1 || (len == 2 && s.codeUnitAt(contentStart) >= 0xD800 && s.codeUnitAt(contentStart) <= 0xDBFF);
  }

  int _blockAt(int i) {
    for (var k = 0; k < l.blockComments.length; k++) {
      if (s.startsWith(l.blockComments[k].$1, i)) return k;
    }
    return -1;
  }

  int _stringAt(int i) {
    for (var k = 0; k < l.strings.length; k++) {
      final open = l.strings[k].open;
      if (!s.startsWith(open, i)) continue;
      // r"…" 之类带字母前缀的,前面不能紧挨着标识符(否则 `bar"` 会被当成 r"…")
      if (_isLetter(open.codeUnitAt(0)) && i > 0 && _identChar(s.codeUnitAt(i - 1))) continue;
      return k;
    }
    return -1;
  }

  TokenKind _classify(String word, int end) {
    final key = l.caseInsensitive ? word.toLowerCase() : word;
    if (l.keywords.contains(key)) return TokenKind.keyword;
    if (l.constants.contains(key)) return TokenKind.constant;
    if (l.types.contains(key)) return TokenKind.type;
    var j = end;
    while (j < s.length && _isSpace(s.codeUnitAt(j))) {
      j++;
    }
    final call = j < s.length && s.codeUnitAt(j) == 40;
    if (l.builtins.contains(key)) return TokenKind.builtin;
    final first = word.codeUnitAt(0);
    if (l.upperCaseIsType && first >= 65 && first <= 90) {
      // 全大写(MAX_SIZE)是常量,其余大写开头是类型
      final allCaps = word.length > 1 && word == word.toUpperCase() && word.contains(RegExp('[A-Z]'));
      if (allCaps) return TokenKind.field;
      return call ? TokenKind.function : TokenKind.type;
    }
    return call ? TokenKind.function : TokenKind.plain;
  }
}

// ---------------------------------------------------------------------------
// XML / HTML
// ---------------------------------------------------------------------------

/// 状态:1 注释内;2 标签内(属性跨行);3 CDATA 内;4 / 5 双 / 单引号属性值跨行。
LineTokens _markup(String s, int state) {
  final out = _Out();
  final n = s.length;
  var i = 0;

  int closeAt(String close, int from, TokenKind kind, int keepState) {
    final e = s.indexOf(close, from);
    if (e < 0) {
      out.add(i, n, kind);
      i = n;
      return keepState;
    }
    out.add(i, e + close.length, kind);
    i = e + close.length;
    return -1;
  }

  while (true) {
    if (state == 1) {
      final r = closeAt('-->', i, TokenKind.comment, 1);
      if (r >= 0) return LineTokens(out.tokens, r);
      state = 0;
    } else if (state == 3) {
      final r = closeAt(']]>', i, TokenKind.string, 3);
      if (r >= 0) return LineTokens(out.tokens, r);
      state = 0;
    } else if (state == 4 || state == 5) {
      final r = closeAt(state == 4 ? '"' : "'", i, TokenKind.attrValue, state);
      if (r >= 0) return LineTokens(out.tokens, r);
      state = 2;
    } else if (state == 2) {
      // 标签内部:属性名 = "值",直到 > 或 />
      while (i < n) {
        final c = s.codeUnitAt(i);
        if (_isSpace(c)) {
          out.add(i, i + 1, TokenKind.plain);
          i++;
        } else if (c == 62 || (c == 47 && i + 1 < n && s.codeUnitAt(i + 1) == 62) || (c == 63 && i + 1 < n && s.codeUnitAt(i + 1) == 62)) {
          final len = c == 62 ? 1 : 2;
          out.add(i, i + len, TokenKind.tag);
          i += len;
          state = 0;
          break;
        } else if (c == 34 || c == 39) {
          final e = s.indexOf(String.fromCharCode(c), i + 1);
          if (e < 0) {
            out.add(i, n, TokenKind.attrValue);
            return LineTokens(out.tokens, c == 34 ? 4 : 5);
          }
          out.add(i, e + 1, TokenKind.attrValue);
          i = e + 1;
        } else if (c == 61) {
          out.add(i, i + 1, TokenKind.punctuation);
          i++;
        } else {
          final a = i;
          while (i < n && !_isSpace(s.codeUnitAt(i)) && !'=>/"\''.codeUnits.contains(s.codeUnitAt(i))) {
            i++;
          }
          if (i == a) i++;
          out.add(a, i, TokenKind.attribute);
        }
      }
      if (state == 2) return LineTokens(out.tokens, 2);
    } else {
      // 文本
      if (i >= n) return LineTokens(out.tokens, 0);
      final lt = s.indexOf('<', i);
      final textEnd = lt < 0 ? n : lt;
      _markupText(s, i, textEnd, out);
      i = textEnd;
      if (lt < 0) return LineTokens(out.tokens, 0);
      if (s.startsWith('<!--', i)) {
        state = 1;
        out.add(i, i + 4, TokenKind.comment);
        i += 4;
      } else if (s.startsWith('<![CDATA[', i)) {
        state = 3;
        out.add(i, i + 9, TokenKind.annotation);
        i += 9;
      } else if (s.startsWith('<!', i) || s.startsWith('<?', i)) {
        // <!DOCTYPE …> / <?xml …?>
        var e = i + 2;
        while (e < n && _isLetter(s.codeUnitAt(e))) {
          e++;
        }
        out.add(i, e, TokenKind.annotation);
        i = e;
        state = 2;
      } else {
        var e = i + 1;
        if (e < n && s.codeUnitAt(e) == 47) e++;
        while (e < n && (_isLetter(s.codeUnitAt(e)) || _isDigit(s.codeUnitAt(e)) || ':.-'.codeUnits.contains(s.codeUnitAt(e)))) {
          e++;
        }
        out.add(i, e, TokenKind.tag);
        i = e;
        state = 2;
      }
    }
  }
}

/// 标签之间的文本:实体 &amp; 与模板占位 #{…} / ${…}(MyBatis、模板引擎)。
void _markupText(String s, int a, int b, _Out out) {
  var i = a;
  var plainFrom = a;
  while (i < b) {
    final c = s.codeUnitAt(i);
    if (c == 38) {
      final e = s.indexOf(';', i);
      if (e > i && e < b && e - i < 10) {
        out.add(plainFrom, i, TokenKind.plain);
        out.add(i, e + 1, TokenKind.entity);
        i = e + 1;
        plainFrom = i;
        continue;
      }
    }
    if ((c == 35 || c == 36) && i + 1 < b && s.codeUnitAt(i + 1) == 123) {
      final e = s.indexOf('}', i);
      if (e > i && e < b) {
        out.add(plainFrom, i, TokenKind.plain);
        out.add(i, e + 1, TokenKind.variable);
        i = e + 1;
        plainFrom = i;
        continue;
      }
    }
    i++;
  }
  out.add(plainFrom, b, TokenKind.plain);
}

// ---------------------------------------------------------------------------
// JSON(含 jsonc 注释)
// ---------------------------------------------------------------------------

/// 状态:1 块注释内。
LineTokens _json(String s, int state) {
  final out = _Out();
  final n = s.length;
  var i = 0;
  if (state == 1) {
    final e = s.indexOf('*/');
    if (e < 0) return LineTokens([Token(0, n, TokenKind.comment)], 1);
    out.add(0, e + 2, TokenKind.comment);
    i = e + 2;
  }
  while (i < n) {
    final c = s.codeUnitAt(i);
    if (c == 34) {
      final e = _findClose(s, i + 1, const StringRule('"'));
      final end = e < 0 ? n : e;
      var j = end;
      while (j < n && _isSpace(s.codeUnitAt(j))) {
        j++;
      }
      out.add(i, end, j < n && s.codeUnitAt(j) == 58 ? TokenKind.field : TokenKind.string);
      i = end;
    } else if (s.startsWith('//', i)) {
      out.add(i, n, TokenKind.comment);
      break;
    } else if (s.startsWith('/*', i)) {
      final e = s.indexOf('*/', i + 2);
      if (e < 0) {
        out.add(i, n, TokenKind.comment);
        return LineTokens(out.tokens, 1);
      }
      out.add(i, e + 2, TokenKind.comment);
      i = e + 2;
    } else if (_isDigit(c) || (c == 45 && i + 1 < n && _isDigit(s.codeUnitAt(i + 1)))) {
      var e = i + 1;
      while (e < n && (_isDigit(s.codeUnitAt(e)) || '.eE+-'.codeUnits.contains(s.codeUnitAt(e)))) {
        e++;
      }
      out.add(i, e, TokenKind.number);
      i = e;
    } else if (_isLetter(c)) {
      var e = i + 1;
      while (e < n && _isLetter(s.codeUnitAt(e))) {
        e++;
      }
      final w = s.substring(i, e);
      out.add(i, e, w == 'true' || w == 'false' || w == 'null' ? TokenKind.constant : TokenKind.plain);
      i = e;
    } else {
      out.add(i, i + 1, _isSpace(c) ? TokenKind.plain : TokenKind.punctuation);
      i++;
    }
  }
  return LineTokens(out.tokens, 0);
}

// ---------------------------------------------------------------------------
// YAML
// ---------------------------------------------------------------------------

final RegExp _yamlKey = RegExp(r'''^(\s*)(- +)?((?:"[^"]*"|'[^']*'|[^\s#'"\-?:][^#:]*?|[^\s#'"][^#:]*?))\s*:(?=\s|$)''');

LineTokens _yaml(String s) {
  final out = _Out();
  final n = s.length;
  final t = s.trimLeft();
  if (t.startsWith('#')) return LineTokens([Token(0, n, TokenKind.comment)], 0);
  if (t == '---' || t == '...') return LineTokens([Token(0, n, TokenKind.keyword)], 0);
  var i = 0;
  final m = _yamlKey.firstMatch(s);
  if (m != null) {
    final indent = m.group(1)!.length;
    out.add(0, indent, TokenKind.plain);
    var k = indent;
    if (m.group(2) != null) {
      out.add(k, k + m.group(2)!.length, TokenKind.listMarker);
      k += m.group(2)!.length;
    }
    final keyEnd = k + m.group(3)!.length;
    out.add(k, keyEnd, TokenKind.key);
    i = m.end;
    out.add(keyEnd, i, TokenKind.punctuation);
  } else {
    var k = 0;
    while (k < n && _isSpace(s.codeUnitAt(k))) {
      k++;
    }
    out.add(0, k, TokenKind.plain);
    i = k;
    if (s.startsWith('- ', i) || s.substring(i) == '-') {
      out.add(i, i + 1, TokenKind.listMarker);
      i++;
    }
  }
  _yamlValue(s, i, out);
  return LineTokens(out.tokens, 0);
}

const _yamlConstants = {'true', 'false', 'yes', 'no', 'on', 'off', 'null', '~', 'True', 'False', 'Null', 'NULL'};

void _yamlValue(String s, int from, _Out out) {
  final n = s.length;
  var i = from;
  while (i < n && _isSpace(s.codeUnitAt(i))) {
    i++;
  }
  out.add(from, i, TokenKind.plain);
  if (i >= n) return;
  final c = s.codeUnitAt(i);
  // 行尾注释:# 前面要有空白
  int commentAt(int from) {
    for (var k = from; k < n; k++) {
      if (s.codeUnitAt(k) == 35 && (k == 0 || _isSpace(s.codeUnitAt(k - 1)))) return k;
    }
    return -1;
  }

  if (c == 34 || c == 39) {
    final e = s.indexOf(String.fromCharCode(c), i + 1);
    final end = e < 0 ? n : e + 1;
    out.add(i, end, TokenKind.string);
    final ci = commentAt(end);
    out.add(end, ci < 0 ? n : ci, TokenKind.plain);
    if (ci >= 0) out.add(ci, n, TokenKind.comment);
    return;
  }
  final ci = commentAt(i);
  final valueEnd = ci < 0 ? n : ci;
  final raw = s.substring(i, valueEnd);
  final v = raw.trimRight();
  TokenKind kind;
  if (v.startsWith('&') || v.startsWith('*')) {
    kind = TokenKind.variable;
  } else if (v.startsWith('!')) {
    kind = TokenKind.annotation;
  } else if (v == '|' || v == '>' || v.startsWith('|') || v.startsWith('>')) {
    kind = TokenKind.keyword;
  } else if (_yamlConstants.contains(v)) {
    kind = TokenKind.constant;
  } else if (RegExp(r'^[-+]?(\d[\d_]*(\.\d+)?([eE][-+]?\d+)?|0x[0-9a-fA-F]+|\.inf|\.nan)$').hasMatch(v)) {
    kind = TokenKind.number;
  } else {
    kind = TokenKind.plain;
  }
  out.add(i, i + v.length, kind);
  out.add(i + v.length, valueEnd, TokenKind.plain);
  if (ci >= 0) out.add(ci, n, TokenKind.comment);
}

// ---------------------------------------------------------------------------
// Markdown
// ---------------------------------------------------------------------------

/// 状态:1 在 ``` / ~~~ 代码围栏内。
LineTokens _markdown(String s, int state) {
  final n = s.length;
  final t = s.trimLeft();
  final fence = t.startsWith('```') || t.startsWith('~~~');
  if (state == 1) {
    return LineTokens(n == 0 ? const [] : [Token(0, n, TokenKind.codeSpan)], fence ? 0 : 1);
  }
  if (fence) return LineTokens([Token(0, n, TokenKind.codeSpan)], 1);
  if (RegExp(r'^\s{0,3}#{1,6}(\s|$)').hasMatch(s)) return LineTokens([Token(0, n, TokenKind.heading)], 0);
  if (RegExp(r'^\s{0,3}([-*_])(\s*\1){2,}\s*$').hasMatch(s)) return LineTokens([Token(0, n, TokenKind.listMarker)], 0);
  final out = _Out();
  var i = 0;
  final quote = RegExp(r'^\s*>').firstMatch(s);
  if (quote != null) {
    return LineTokens([Token(0, n, TokenKind.quote)], 0);
  }
  final list = RegExp(r'^(\s*)([-*+]|\d+[.)])(\s+)(\[[ xX]\]\s+)?').firstMatch(s);
  if (list != null) {
    out.add(0, list.group(1)!.length, TokenKind.plain);
    out.add(list.group(1)!.length, list.end, TokenKind.listMarker);
    i = list.end;
  }
  while (i < n) {
    final c = s.codeUnitAt(i);
    if (c == 96) {
      final e = s.indexOf('`', i + 1);
      if (e > i) {
        out.add(i, e + 1, TokenKind.codeSpan);
        i = e + 1;
        continue;
      }
    }
    if ((c == 42 || c == 95) && i + 1 < n && s.codeUnitAt(i + 1) == c) {
      final close = String.fromCharCodes([c, c]);
      final e = s.indexOf(close, i + 2);
      if (e > i + 2) {
        out.add(i, e + 2, TokenKind.bold);
        i = e + 2;
        continue;
      }
    }
    if ((c == 42 || c == 95) && i + 1 < n && !_isSpace(s.codeUnitAt(i + 1)) && (i == 0 || !_isLetter(s.codeUnitAt(i - 1)))) {
      final e = s.indexOf(String.fromCharCode(c), i + 1);
      if (e > i + 1) {
        out.add(i, e + 1, TokenKind.italic);
        i = e + 1;
        continue;
      }
    }
    if (c == 91 || (c == 33 && i + 1 < n && s.codeUnitAt(i + 1) == 91)) {
      final m = RegExp(r'!?\[[^\]]*\](\([^)]*\)|\[[^\]]*\])?').matchAsPrefix(s, i);
      if (m != null && m.end > i + 2) {
        out.add(i, m.end, TokenKind.link);
        i = m.end;
        continue;
      }
    }
    if (c == 60) {
      final m = RegExp(r'<(https?://[^>\s]+|[^@\s>]+@[^>\s]+)>').matchAsPrefix(s, i);
      if (m != null) {
        out.add(i, m.end, TokenKind.link);
        i = m.end;
        continue;
      }
    }
    out.add(i, i + 1, TokenKind.plain);
    i++;
  }
  return LineTokens(out.tokens, 0);
}

// ---------------------------------------------------------------------------
// INI / TOML / properties / .gitignore
// ---------------------------------------------------------------------------

/// 状态:1 在 TOML 的 """ 多行字符串内;2 在 ''' 内。
LineTokens _ini(LanguageSpec l, String s, int state) {
  final out = _Out();
  final n = s.length;
  if (state == 1 || state == 2) {
    final close = state == 1 ? '"""' : "'''";
    final e = s.indexOf(close);
    if (e < 0) return LineTokens(n == 0 ? const [] : [Token(0, n, TokenKind.string)], state);
    out.add(0, e + 3, TokenKind.string);
    _iniValue(s, e + 3, out);
    return LineTokens(out.tokens, 0);
  }
  var k = 0;
  while (k < n && _isSpace(s.codeUnitAt(k))) {
    k++;
  }
  out.add(0, k, TokenKind.plain);
  if (k >= n) return LineTokens(out.tokens, 0);
  if (l.lineComments.any((p) => s.startsWith(p, k))) {
    out.add(k, n, TokenKind.comment);
    return LineTokens(out.tokens, 0);
  }
  if (l.id == 'ignore') {
    if (s.codeUnitAt(k) == 33) {
      out.add(k, k + 1, TokenKind.keyword);
      k++;
    }
    out.add(k, n, TokenKind.plain);
    return LineTokens(out.tokens, 0);
  }
  if (s.codeUnitAt(k) == 91) {
    final e = s.lastIndexOf(']');
    out.add(k, e < k ? n : e + 1, TokenKind.section);
    if (e >= k) out.add(e + 1, n, TokenKind.comment);
    return LineTokens(out.tokens, 0);
  }
  // key = value / key: value(properties)
  var sep = -1;
  for (var j = k; j < n; j++) {
    final c = s.codeUnitAt(j);
    if (c == 61 || (l.id == 'properties' && c == 58)) {
      sep = j;
      break;
    }
  }
  if (sep < 0) {
    out.add(k, n, TokenKind.plain);
    return LineTokens(out.tokens, 0);
  }
  var keyEnd = sep;
  while (keyEnd > k && _isSpace(s.codeUnitAt(keyEnd - 1))) {
    keyEnd--;
  }
  out.add(k, keyEnd, TokenKind.key);
  out.add(keyEnd, sep, TokenKind.plain);
  out.add(sep, sep + 1, TokenKind.punctuation);
  if (l.id == 'properties') {
    out.add(sep + 1, n, TokenKind.string);
    return LineTokens(out.tokens, 0);
  }
  return LineTokens(out.tokens, _iniValue(s, sep + 1, out));
}

/// 值部分;返回行尾状态(TOML 多行字符串没闭合时非 0)。
int _iniValue(String s, int from, _Out out) {
  final n = s.length;
  var i = from;
  while (i < n) {
    final c = s.codeUnitAt(i);
    if (s.startsWith('"""', i) || s.startsWith("'''", i)) {
      final close = s.substring(i, i + 3);
      final e = s.indexOf(close, i + 3);
      if (e < 0) {
        out.add(i, n, TokenKind.string);
        return close == '"""' ? 1 : 2;
      }
      out.add(i, e + 3, TokenKind.string);
      i = e + 3;
    } else if (c == 34 || c == 39) {
      final e = _findClose(s, i + 1, StringRule(String.fromCharCode(c), null, false, c == 34));
      final end = e < 0 ? n : e;
      out.add(i, end, TokenKind.string);
      i = end;
    } else if (c == 35 || c == 59) {
      out.add(i, n, TokenKind.comment);
      return 0;
    } else if (_isDigit(c) || ((c == 45 || c == 43) && i + 1 < n && _isDigit(s.codeUnitAt(i + 1)))) {
      var e = i + 1;
      while (e < n && (_isDigit(s.codeUnitAt(e)) || _isLetter(s.codeUnitAt(e)) || '.:-+'.codeUnits.contains(s.codeUnitAt(e)))) {
        e++;
      }
      out.add(i, e, TokenKind.number);
      i = e;
    } else if (_isLetter(c)) {
      var e = i + 1;
      while (e < n && (_isLetter(s.codeUnitAt(e)) || _isDigit(s.codeUnitAt(e)) || s.codeUnitAt(e) == 45 || s.codeUnitAt(e) == 46)) {
        e++;
      }
      final w = s.substring(i, e);
      out.add(i, e, w == 'true' || w == 'false' ? TokenKind.constant : TokenKind.plain);
      i = e;
    } else {
      out.add(i, i + 1, _isSpace(c) ? TokenKind.plain : TokenKind.punctuation);
      i++;
    }
  }
  return 0;
}
