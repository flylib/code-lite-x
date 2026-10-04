// LSP 客户端的纯 Dart 公共部分(不依赖 dart:io):原生实现 lsp_service.dart 与 web 桩共用。
//
// 包含:
//   - 语言路由:扩展名 → LSP languageId → 服务端分组(同一分组共用一个进程,如 c/cpp 共用 clangd);
//   - Content-Length 分帧解析/编码(长度按 UTF-8 字节计,不是字符数);
//   - SymbolKind 映射与 documentSymbol 结果规整为结构面板的大纲格式;
//   - 无语言服务端时的降级:括号配对诊断 + 正则大纲(移植自原 Rust virtual_server / code-lite-graph parser)。
//
// 降级逻辑先把注释与字符串内容「抹成空格」(保留换行与列号),再在剩下的纯代码上做括号匹配与正则扫描,
// 这样字符串里的 `{`、注释里的 `fn foo` 都不会误报。

import 'dart:convert';
import 'dart:typed_data';

/// 一次诊断推送:[path] 为工作区相对路径(与编辑器 tab 的路径一致),
/// [diagnostics] 为 LSP 标准 Diagnostic map(`EditorDiagnostic.fromJson` 可直接解析)。
class LspDiagnosticsEvent {
  const LspDiagnosticsEvent(this.path, this.diagnostics);

  final String path;
  final List<Map<String, dynamic>> diagnostics;

  @override
  String toString() => 'LspDiagnosticsEvent($path, ${diagnostics.length} diagnostics)';
}

// ===========================================================================
// 语言路由
// ===========================================================================

/// 有对应语言服务端的扩展名 → LSP languageId。
const Map<String, String> _routedExtensions = {
  'rs': 'rust',
  'go': 'go',
  'c': 'c',
  'h': 'c',
  'cc': 'cpp',
  'cpp': 'cpp',
  'cxx': 'cpp',
  'c++': 'cpp',
  'hpp': 'cpp',
  'hh': 'cpp',
  'hxx': 'cpp',
  'h++': 'cpp',
  'ipp': 'cpp',
  'inl': 'cpp',
  'ts': 'typescript',
  'mts': 'typescript',
  'cts': 'typescript',
  'tsx': 'typescriptreact',
  'js': 'javascript',
  'mjs': 'javascript',
  'cjs': 'javascript',
  'jsx': 'javascriptreact',
  'dart': 'dart',
  'py': 'python',
  'pyi': 'python',
};

/// 没有接服务端、但词法足够接近 C 系,值得做括号降级诊断的语言。
const Map<String, String> _fallbackOnlyExtensions = {
  'java': 'java',
  'kt': 'kotlin',
  'kts': 'kotlin',
  'swift': 'swift',
  'cs': 'csharp',
  'scala': 'scala',
  'json': 'json',
  'jsonc': 'jsonc',
};

String _extensionOf(String path) {
  final slash = path.lastIndexOf(RegExp(r'[/\\]'));
  final base = slash >= 0 ? path.substring(slash + 1) : path;
  final dot = base.lastIndexOf('.');
  if (dot <= 0 || dot == base.length - 1) return '';
  return base.substring(dot + 1).toLowerCase();
}

/// 按扩展名给出 LSP languageId;只覆盖我们会路由到语言服务端的语言,其余返回 null。
String? lspLanguageIdFor(String path) => _routedExtensions[_extensionOf(path)];

/// 降级用语言:路由语言之外,再加上只做括号诊断的 C 系语言。非代码文件(md/yaml/txt…)返回 null。
String? lspFallbackLanguageFor(String path) {
  final ext = _extensionOf(path);
  return _routedExtensions[ext] ?? _fallbackOnlyExtensions[ext];
}

/// languageId → 服务端分组。同一分组只起一个进程:clangd 同时服务 c/cpp,
/// typescript-language-server 同时服务 ts/tsx/js/jsx。
String? lspServerGroupFor(String languageId) {
  switch (languageId) {
    case 'rust':
      return 'rust';
    case 'go':
      return 'go';
    case 'c':
    case 'cpp':
      return 'cpp';
    case 'typescript':
    case 'typescriptreact':
    case 'javascript':
    case 'javascriptreact':
      return 'typescript';
    case 'dart':
      return 'dart';
    case 'python':
      return 'python';
  }
  return null;
}

/// 分组 → 组内全部 languageId(用于按 languageId 查 serverOverrides)。
const Map<String, List<String>> lspServerGroupLanguages = {
  'rust': ['rust'],
  'go': ['go'],
  'cpp': ['cpp', 'c'],
  'typescript': ['typescript', 'typescriptreact', 'javascript', 'javascriptreact'],
  'dart': ['dart'],
  'python': ['python'],
};

/// 每个分组的候选启动命令,按优先级排列;第一个能在搜索路径里找到的胜出。
/// 与原 Rust supervisor 的路由一致(vtsls 优先于 typescript-language-server)。
const Map<String, List<List<String>>> lspServerCandidates = {
  'rust': [
    ['rust-analyzer'],
  ],
  'go': [
    ['gopls'],
  ],
  'cpp': [
    ['clangd'],
  ],
  'typescript': [
    ['vtsls', '--stdio'],
    ['typescript-language-server', '--stdio'],
  ],
  'dart': [
    ['dart', 'language-server', '--protocol=lsp'],
  ],
  'python': [
    ['pyright-langserver', '--stdio'],
    ['basedpyright-langserver', '--stdio'],
    ['pylsp'],
  ],
};

// ===========================================================================
// Content-Length 分帧
// ===========================================================================

/// 增量解析 `Content-Length: N\r\n\r\n<N 字节 UTF-8 JSON>` 帧。
///
/// 管道读出的 chunk 边界与消息边界无关:一个 chunk 可能只有半个头,也可能粘着好几条消息,
/// 因此这里按字节缓冲,够一条才吐一条。N 是字节数,多字节字符必须按字节截取后再解码。
class LspFrameParser {
  final List<int> _buf = <int>[];
  int? _expected;

  /// 头部异常(超长且找不到分隔符)时丢弃缓冲,避免无限增长。
  static const int _maxHeaderBytes = 64 * 1024;

  /// 喂入一个 chunk,返回本次凑齐的完整消息体(已 UTF-8 解码)。
  List<String> add(List<int> chunk) {
    _buf.addAll(chunk);
    final out = <String>[];
    while (true) {
      if (_expected == null) {
        final sep = _findHeaderEnd();
        if (sep == null) {
          if (_buf.length > _maxHeaderBytes) _buf.clear();
          break;
        }
        final header = latin1.decode(_buf.sublist(0, sep.$1), allowInvalid: true);
        _buf.removeRange(0, sep.$1 + sep.$2);
        final len = _contentLength(header);
        // 没有 Content-Length 的头无法定位消息体:丢掉这段头,继续找下一帧(重新同步)。
        if (len == null) continue;
        _expected = len;
      }
      final len = _expected!;
      if (_buf.length < len) break;
      final body = _buf.sublist(0, len);
      _buf.removeRange(0, len);
      _expected = null;
      out.add(utf8.decode(body, allowMalformed: true));
    }
    return out;
  }

  /// 返回 (分隔符起点, 分隔符长度);兼容只用 `\n\n` 分隔的不规范实现。
  (int, int)? _findHeaderEnd() {
    final b = _buf;
    for (var i = 0; i + 1 < b.length; i++) {
      if (b[i] == 10 && b[i + 1] == 10) return (i, 2);
      if (b[i] == 13 && i + 3 < b.length && b[i + 1] == 10 && b[i + 2] == 13 && b[i + 3] == 10) return (i, 4);
    }
    return null;
  }

  static int? _contentLength(String header) {
    for (final raw in header.split('\n')) {
      final line = raw.trim();
      final colon = line.indexOf(':');
      if (colon <= 0) continue;
      if (line.substring(0, colon).trim().toLowerCase() == 'content-length') {
        final n = int.tryParse(line.substring(colon + 1).trim());
        if (n != null && n >= 0) return n;
      }
    }
    return null;
  }

  /// 把一条 JSON-RPC 消息编码成完整帧(头 + UTF-8 体)。
  static Uint8List encode(Object? message) {
    final body = utf8.encode(jsonEncode(message));
    final builder = BytesBuilder(copy: false)
      ..add(ascii.encode('Content-Length: ${body.length}\r\n\r\n'))
      ..add(body);
    return builder.takeBytes();
  }
}

// ===========================================================================
// SymbolKind 映射 / documentSymbol 结果规整
// ===========================================================================

/// LSP SymbolKind(1..26)→ 结构面板使用的小写 kind。
///
/// 结构面板额外认识 `impl`(Rust impl 块,rust-analyzer 以 Object 上报)和 `variant`(EnumMember)。
/// rust-analyzer 把 trait 报成 Interface,Rust 语境下还原成 `trait`。
String lspSymbolKindName(int kind, {String? languageId, String? name}) {
  switch (kind) {
    case 1: // File
    case 2: // Module
    case 4: // Package
      return 'module';
    case 3:
      return 'namespace';
    case 5:
      return 'class';
    case 6:
      return 'method';
    case 7:
      return 'property';
    case 8:
      return 'field';
    case 9:
      return 'constructor';
    case 10:
      return 'enum';
    case 11:
      return languageId == 'rust' ? 'trait' : 'interface';
    case 12:
      return 'function';
    case 13:
      return 'variable';
    case 14:
    case 15: // String
    case 16: // Number
    case 17: // Boolean
    case 21: // Null
      return 'constant';
    case 18: // Array
      return 'variable';
    case 19: // Object
      return (name ?? '').startsWith('impl') ? 'impl' : 'variable';
    case 20: // Key
      return 'property';
    case 22: // EnumMember
      return 'variant';
    case 23:
      return 'struct';
    case 24: // Event
      return 'property';
    case 25: // Operator
      return 'function';
    case 26: // TypeParameter(rust-analyzer 的 type alias 也走这里)
      return 'type';
  }
  return 'variable';
}

/// 把 `textDocument/documentSymbol` 的结果规整为结构面板大纲。
///
/// 同时兼容两种返回:DocumentSymbol[](分层,带 children/selectionRange)与
/// SymbolInformation[](扁平,带 location)。扁平结果按范围包含关系还原层级。
/// 起点取 selectionRange(符号名本身,跳转时不会落在文档注释上),终点取 range(整个定义)。
List<Map<String, dynamic>> lspParseDocumentSymbols(Object? result, {String? languageId}) {
  if (result is! List || result.isEmpty) return <Map<String, dynamic>>[];
  final first = result.whereType<Map>().firstOrNull;
  if (first == null) return <Map<String, dynamic>>[];
  if (first.containsKey('location') && !first.containsKey('selectionRange')) {
    return _nestSymbolInformation(result, languageId);
  }
  final out = <Map<String, dynamic>>[];
  for (final e in result) {
    if (e is Map) {
      final node = _fromDocumentSymbol(e, languageId);
      if (node != null) out.add(node);
    }
  }
  _sortNodes(out);
  return out;
}

(int, int)? _position(Object? p) {
  if (p is! Map) return null;
  final line = p['line'];
  final ch = p['character'];
  if (line is! num || ch is! num) return null;
  return (line.toInt(), ch.toInt());
}

Map<String, dynamic>? _fromDocumentSymbol(Map e, String? languageId) {
  final name = e['name'];
  final range = e['range'];
  if (name is! String || range is! Map) return null;
  final sel = e['selectionRange'] is Map ? e['selectionRange'] as Map : range;
  final start = _position(sel['start']) ?? _position(range['start']);
  final end = _position(range['end']) ?? start;
  if (start == null || end == null) return null;
  final kind = e['kind'] is num ? (e['kind'] as num).toInt() : 13;
  final children = <Map<String, dynamic>>[];
  final rawChildren = e['children'];
  if (rawChildren is List) {
    for (final c in rawChildren) {
      if (c is Map) {
        final node = _fromDocumentSymbol(c, languageId);
        if (node != null) children.add(node);
      }
    }
  }
  _sortNodes(children);
  final detail = e['detail'];
  return {
    'name': name,
    'kind': lspSymbolKindName(kind, languageId: languageId, name: name),
    'line_start': start.$1,
    'col_start': start.$2,
    'line_end': end.$1,
    'col_end': end.$2,
    if (detail is String && detail.isNotEmpty) 'detail': detail,
    'children': children,
  };
}

List<Map<String, dynamic>> _nestSymbolInformation(List<dynamic> items, String? languageId) {
  // (节点, 完整范围起点, 完整范围终点)
  final flat = <(Map<String, dynamic>, (int, int), (int, int))>[];
  for (final e in items) {
    if (e is! Map) continue;
    final name = e['name'];
    final loc = e['location'];
    if (name is! String || loc is! Map || loc['range'] is! Map) continue;
    final range = loc['range'] as Map;
    final start = _position(range['start']);
    final end = _position(range['end']) ?? start;
    if (start == null || end == null) continue;
    final kind = e['kind'] is num ? (e['kind'] as num).toInt() : 13;
    flat.add((
      {
        'name': name,
        'kind': lspSymbolKindName(kind, languageId: languageId, name: name),
        'line_start': start.$1,
        'col_start': start.$2,
        'line_end': end.$1,
        'col_end': end.$2,
        'children': <Map<String, dynamic>>[],
      },
      start,
      end,
    ));
  }
  int cmp((int, int) a, (int, int) b) => a.$1 != b.$1 ? a.$1 - b.$1 : a.$2 - b.$2;
  // 起点升序;起点相同则范围大的在前,保证容器先入栈。
  flat.sort((a, b) {
    final c = cmp(a.$2, b.$2);
    return c != 0 ? c : cmp(b.$3, a.$3);
  });
  final roots = <Map<String, dynamic>>[];
  final stack = <(Map<String, dynamic>, (int, int))>[];
  for (final item in flat) {
    while (stack.isNotEmpty && cmp(stack.last.$2, item.$3) < 0) {
      stack.removeLast();
    }
    if (stack.isEmpty) {
      roots.add(item.$1);
    } else {
      (stack.last.$1['children'] as List<Map<String, dynamic>>).add(item.$1);
    }
    stack.add((item.$1, item.$3));
  }
  return roots;
}

void _sortNodes(List<Map<String, dynamic>> nodes) {
  nodes.sort((a, b) {
    final la = a['line_start'] as int;
    final lb = b['line_start'] as int;
    return la != lb ? la - lb : (a['col_start'] as int) - (b['col_start'] as int);
  });
}

// ===========================================================================
// 词法遮罩:抹掉注释与字符串内容
// ===========================================================================

enum _SingleQuote { string, char, rustChar }

enum _Backtick { none, template, raw }

/// 各语言的注释/字符串语法差异。只建模影响括号与声明识别的部分。
class _Syntax {
  const _Syntax({
    this.lineComment = '//',
    this.blockComment = true,
    this.nestedBlock = false,
    this.singleQuote = _SingleQuote.char,
    this.doubleMultiline = false,
    this.backtick = _Backtick.none,
    this.triple = false,
    this.interpolate = false,
    this.rustRaw = false,
    this.prefixRaw = false,
    this.regexLiteral = false,
  });

  final String lineComment;
  final bool blockComment;

  /// Rust/Dart/Swift/Kotlin 的块注释可以嵌套。
  final bool nestedBlock;
  final _SingleQuote singleQuote;

  /// Rust 的普通字符串可以跨行。
  final bool doubleMultiline;
  final _Backtick backtick;

  /// `'''` / `"""` 多行字符串(Dart/Python/Kotlin/Swift/Java 文本块)。
  final bool triple;

  /// 引号字符串支持 `${...}` 插值(Dart/Kotlin;TS/JS 只在反引号模板里)。
  final bool interpolate;

  /// Rust 原始字符串 `r#"..."#`。
  final bool rustRaw;

  /// 前缀 r 的原始字符串(Dart `r'...'`、Python `r"..."`),内部不处理转义。
  final bool prefixRaw;

  /// JS/TS 正则字面量 `/.../flags`:里面的 `(`、`[`、`//` 都不是代码。
  final bool regexLiteral;
}

const _cLike = _Syntax();
const _syntaxes = <String, _Syntax>{
  'rust': _Syntax(nestedBlock: true, singleQuote: _SingleQuote.rustChar, doubleMultiline: true, rustRaw: true),
  'go': _Syntax(backtick: _Backtick.raw),
  'typescript': _Syntax(singleQuote: _SingleQuote.string, backtick: _Backtick.template, regexLiteral: true),
  'typescriptreact': _Syntax(singleQuote: _SingleQuote.string, backtick: _Backtick.template, regexLiteral: true),
  'javascript': _Syntax(singleQuote: _SingleQuote.string, backtick: _Backtick.template, regexLiteral: true),
  'javascriptreact': _Syntax(singleQuote: _SingleQuote.string, backtick: _Backtick.template, regexLiteral: true),
  'dart': _Syntax(nestedBlock: true, singleQuote: _SingleQuote.string, triple: true, interpolate: true, prefixRaw: true),
  'python': _Syntax(lineComment: '#', blockComment: false, singleQuote: _SingleQuote.string, triple: true, prefixRaw: true),
  'kotlin': _Syntax(nestedBlock: true, triple: true, interpolate: true),
  'swift': _Syntax(nestedBlock: true, triple: true),
  'scala': _Syntax(triple: true),
  'java': _Syntax(triple: true),
};

class _StrSpec {
  const _StrSpec(this.close, {this.escapes = true, this.multiline = false, this.interp = false});

  final String close;
  final bool escapes;
  final bool multiline;
  final bool interp;
}

class _Interp {
  _Interp(this.spec);

  final _StrSpec spec;
  int depth = 0;
}

bool _isIdent(int c) =>
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c == 36;

class _Masker {
  _Masker(String text, this.syn)
      : src = text.codeUnits,
        out = Uint16List.fromList(text.codeUnits);

  final List<int> src;
  final Uint16List out;
  final _Syntax syn;
  final List<_Interp> interps = [];

  int get n => src.length;

  void mask(int i) {
    final c = out[i];
    if (c != 10 && c != 13) out[i] = 32;
  }

  bool startsWith(int i, String s) {
    if (i + s.length > n) return false;
    for (var k = 0; k < s.length; k++) {
      if (src[i + k] != s.codeUnitAt(k)) return false;
    }
    return true;
  }

  String run() {
    var i = 0;
    while (i < n) {
      final c = src[i];
      final next = i + 1 < n ? src[i + 1] : -1;
      if (interps.isNotEmpty) {
        final top = interps.last;
        if (c == 123) {
          top.depth++;
        } else if (c == 125) {
          if (top.depth == 0) {
            // 插值结束,回到外层字符串继续扫描。
            interps.removeLast();
            mask(i);
            i = scanString(i + 1, top.spec);
            continue;
          }
          top.depth--;
        }
      }
      // 行注释
      if ((syn.lineComment == '//' && c == 47 && next == 47) || (syn.lineComment == '#' && c == 35)) {
        while (i < n && src[i] != 10) {
          mask(i);
          i++;
        }
        continue;
      }
      // 块注释
      if (syn.blockComment && c == 47 && next == 42) {
        var depth = 1;
        mask(i);
        mask(i + 1);
        i += 2;
        while (i < n && depth > 0) {
          final nx = i + 1 < n ? src[i + 1] : -1;
          if (src[i] == 42 && nx == 47) {
            depth--;
            mask(i);
            mask(i + 1);
            i += 2;
          } else if (syn.nestedBlock && src[i] == 47 && nx == 42) {
            depth++;
            mask(i);
            mask(i + 1);
            i += 2;
          } else {
            mask(i);
            i++;
          }
        }
        continue;
      }
      if (syn.regexLiteral && c == 47 && regexAllowed(i)) {
        final end = scanRegex(i);
        if (end > 0) {
          i = end;
          continue;
        }
      }
      final opened = openStringAt(i);
      if (opened != null) {
        i = scanString(i + opened.$2, opened.$1);
        continue;
      }
      i++;
    }
    return String.fromCharCodes(out);
  }

  static const _regexPrefixKeywords = {
    'return', 'typeof', 'case', 'do', 'else', 'in', 'of', 'void', 'yield', 'await', 'delete', 'throw', 'new',
  };

  /// `/` 处是正则还是除号:看前一个有效代码字符(已遮罩,注释/字符串不干扰)。
  /// 运算符、左括号、语句边界或 return 等关键字之后才是正则。
  bool regexAllowed(int i) {
    // JSX 的 `</tag>` 与 `/>` 不是正则。
    if (i + 1 < n && src[i + 1] == 62) return false;
    if (i > 0 && src[i - 1] == 60) return false;
    var j = i - 1;
    while (j >= 0 && (out[j] == 32 || out[j] == 9 || out[j] == 10 || out[j] == 13)) {
      j--;
    }
    if (j < 0) return true;
    final p = out[j];
    if (_isIdent(p)) {
      var k = j;
      while (k >= 0 && _isIdent(out[k])) {
        k--;
      }
      return _regexPrefixKeywords.contains(String.fromCharCodes(out.sublist(k + 1, j + 1)));
    }
    return '(,=:[!&|?{};+-*%<>~^'.contains(String.fromCharCode(p));
  }

  /// 扫描正则字面量(单行,`[...]` 字符类里的 `/` 不结束),返回结束后的位置;不像正则则返回 -1。
  int scanRegex(int start) {
    var i = start + 1;
    var inClass = false;
    while (i < n) {
      final c = src[i];
      if (c == 10) return -1;
      if (c == 92) {
        i += 2;
        continue;
      }
      if (c == 91) {
        inClass = true;
      } else if (c == 93) {
        inClass = false;
      } else if (c == 47 && !inClass) {
        for (var k = start + 1; k < i; k++) {
          mask(k);
        }
        i++;
        while (i < n && _isIdent(src[i])) {
          i++; // flags
        }
        return i;
      }
      i++;
    }
    return -1;
  }

  /// 若 i 处开启一个字符串/字符字面量,返回 (规格, 开引号长度)。
  (_StrSpec, int)? openStringAt(int i) {
    final c = src[i];
    final prevIdent = i > 0 && _isIdent(src[i - 1]);
    // Rust 原始字符串:r"..." / r#"..."# / br#"..."#
    if (syn.rustRaw && c == 114) {
      final okPrefix = !prevIdent || (src[i - 1] == 98 && (i < 2 || !_isIdent(src[i - 2])));
      if (okPrefix) {
        var j = i + 1;
        while (j < n && src[j] == 35) {
          j++;
        }
        if (j < n && src[j] == 34) {
          final hashes = j - i - 1;
          return (_StrSpec('"${'#' * hashes}', escapes: false, multiline: true), j - i + 1);
        }
      }
      return null;
    }
    if (c == 34 || c == 39) {
      final isDouble = c == 34;
      if (!isDouble) {
        switch (syn.singleQuote) {
          case _SingleQuote.string:
            break;
          case _SingleQuote.char:
            return (const _StrSpec("'"), 1);
          case _SingleQuote.rustChar:
            // 'x' / '\n' 是字符字面量;'a 是生命周期,不是字符串。
            if (i + 1 < n && src[i + 1] == 92) return (const _StrSpec("'"), 1);
            if (i + 2 < n && src[i + 2] == 39 && src[i + 1] != 10) return (const _StrSpec("'"), 1);
            if (i + 3 < n && src[i + 3] == 39 && src[i + 1] >= 0xD800 && src[i + 1] <= 0xDBFF) {
              return (const _StrSpec("'"), 1);
            }
            return null;
        }
      }
      final raw = syn.prefixRaw && _hasRawPrefix(i);
      final q = String.fromCharCode(c);
      if (syn.triple && startsWith(i, q * 3)) {
        return (_StrSpec(q * 3, escapes: !raw, multiline: true, interp: syn.interpolate && !raw), 3);
      }
      return (_StrSpec(q, escapes: !raw, multiline: isDouble && syn.doubleMultiline, interp: syn.interpolate && !raw), 1);
    }
    if (c == 96) {
      switch (syn.backtick) {
        case _Backtick.none:
          return null;
        case _Backtick.template:
          return (const _StrSpec('`', multiline: true, interp: true), 1);
        case _Backtick.raw:
          return (const _StrSpec('`', escapes: false, multiline: true), 1);
      }
    }
    return null;
  }

  /// 引号前紧挨着的 1~2 个字母前缀(r/b/f/u 组合)里含 r 即为原始字符串。
  bool _hasRawPrefix(int quote) {
    var j = quote - 1;
    var hasR = false;
    var count = 0;
    while (j >= 0 && count < 2) {
      final c = src[j];
      final lower = c | 0x20;
      if (lower == 114 || lower == 98 || lower == 102 || lower == 117) {
        if (lower == 114) hasR = true;
        j--;
        count++;
      } else {
        break;
      }
    }
    if (count == 0) return false;
    if (j >= 0 && _isIdent(src[j])) return false;
    return hasR;
  }

  /// 扫描字符串体(开引号之后),返回字符串结束后的位置;遇到 `${` 则压栈并回到代码模式。
  int scanString(int i, _StrSpec spec) {
    while (i < n) {
      final c = src[i];
      // 单行字符串遇到换行即视为结束,防止一个未闭合的引号吞掉整个文件。
      if (c == 10 && !spec.multiline) return i;
      if (spec.escapes && c == 92) {
        mask(i);
        if (i + 1 < n) mask(i + 1);
        i += 2;
        continue;
      }
      if (spec.interp && c == 36 && i + 1 < n && src[i + 1] == 123) {
        mask(i);
        mask(i + 1);
        interps.add(_Interp(spec));
        return i + 2;
      }
      if (startsWith(i, spec.close)) return i + spec.close.length;
      mask(i);
      i++;
    }
    return n;
  }
}

/// 把注释和字符串内容替换成空格(保留引号、换行与总长度,列号不变)。
String lspMaskCode(String text, String? languageId) {
  final syn = _syntaxes[languageId] ?? _cLike;
  return _Masker(text, syn).run();
}

// ===========================================================================
// 降级诊断:括号配对
// ===========================================================================

Map<String, dynamic> _bracketDiagnostic(int line, int col, String code, String message) => {
      'range': {
        'start': {'line': line, 'character': col},
        'end': {'line': line, 'character': col + 1},
      },
      'severity': 1,
      'source': 'codelite',
      'code': code,
      'message': message,
    };

/// 无语言服务端时的兜底诊断:未闭合 / 多余 / 错配的括号。
///
/// 字符串、字符字面量与注释里的括号不参与匹配。错配时回退到栈中最近的同类开括号,
/// 避免一个错字引发整文件级联报错。
List<Map<String, dynamic>> lspBracketDiagnostics(String text, String? languageId, {int maxDiagnostics = 100}) {
  final masked = lspMaskCode(text, languageId);
  final diags = <Map<String, dynamic>>[];
  final stack = <(int, int, int)>[]; // (开括号, 行, 列)
  var line = 0;
  var col = 0;
  for (var i = 0; i < masked.length; i++) {
    final c = masked.codeUnitAt(i);
    if (c == 10) {
      line++;
      col = 0;
      continue;
    }
    if (c == 40 || c == 91 || c == 123) {
      stack.add((c, line, col));
    } else if (c == 41 || c == 93 || c == 125) {
      final want = c == 41 ? 40 : (c == 93 ? 91 : 123);
      final ch = String.fromCharCode(c);
      if (stack.isNotEmpty && stack.last.$1 == want) {
        stack.removeLast();
      } else {
        final idx = stack.lastIndexWhere((e) => e.$1 == want);
        if (idx < 0) {
          diags.add(_bracketDiagnostic(line, col, 'unmatched_bracket', "Unmatched closing bracket '$ch'"));
        } else {
          final top = stack.last;
          final open = String.fromCharCode(top.$1);
          final expected = top.$1 == 40 ? ')' : (top.$1 == 91 ? ']' : '}');
          diags.add(_bracketDiagnostic(
            line,
            col,
            'mismatched_bracket',
            "Mismatched closing bracket '$ch': expected '$expected' to close '$open' at line ${top.$2 + 1}",
          ));
          stack.length = idx;
        }
      }
    }
    col++;
  }
  for (final open in stack) {
    diags.add(_bracketDiagnostic(open.$2, open.$3, 'unclosed_bracket', "Unclosed bracket '${String.fromCharCode(open.$1)}'"));
  }
  diags.sort((a, b) {
    final sa = (a['range'] as Map)['start'] as Map;
    final sb = (b['range'] as Map)['start'] as Map;
    final dl = (sa['line'] as int) - (sb['line'] as int);
    return dl != 0 ? dl : (sa['character'] as int) - (sb['character'] as int);
  });
  return diags.length > maxDiagnostics ? diags.sublist(0, maxDiagnostics) : diags;
}

// ===========================================================================
// 降级大纲:正则扫描
// ===========================================================================

enum _BodyKind { block, decl, none }

/// 声明的「体」:block 为 `{...}`(或 Python 缩进块),decl 为以 `;` / `,` / 换行(ASI)结束的单句。
class _Body {
  const _Body(this.kind, this.end, {this.terminator = 0, this.arrow = false});

  final _BodyKind kind;

  /// 体的最后一个字符的偏移(block 即 `}` 的位置)。
  final int end;

  /// decl 的结束字符(`;` `,` `}` 或换行)。
  final int terminator;

  /// 是否经过了 `=>`(Dart/TS 表达式体)。
  final bool arrow;

  bool get isBlock => kind == _BodyKind.block;
}

typedef _Classify = String? Function(RegExpMatch m, String name, _Open? parent, _Body body);
typedef _Accept = bool Function(_Body body, _Open? parent);

class _Rule {
  _Rule(String pattern, this.kind,
      {this.group = 1, this.parents, this.container = false, this.accept, this.classify, this.nameOf})
      : re = RegExp(pattern);

  final RegExp re;
  final String kind;
  final int group;

  /// 允许出现的父级 kind;'' 表示顶层;null 表示任意(非函数体内)。
  final Set<String>? parents;

  /// 容器(class/struct/impl…)的体内继续识别成员;非容器的体(函数体)整体跳过。
  final bool container;
  final _Accept? accept;
  final _Classify? classify;
  final String? Function(RegExpMatch m)? nameOf;

  bool allows(_Open? parent) => parents == null || parents!.contains(parent?.kind ?? '');
}

class _Open {
  _Open(this.node, this.kind, this.name, this.end, {required this.opaque});

  final Map<String, dynamic> node;
  final String kind;
  final String name;
  final int end;
  final bool opaque;
}

const _keywords = {
  'if', 'for', 'while', 'switch', 'catch', 'return', 'match', 'loop', 'else', 'do', 'sizeof', 'new', 'delete', //
  'throw', 'await', 'assert', 'super', 'this', 'case', 'default', 'typeof', 'yield', 'in', 'of', 'with', 'try',
  'finally', 'defined', 'elif', 'except', 'lambda', 'import', 'export', 'from', 'pub', 'let', 'var', 'const',
  'final', 'static', 'fn', 'func', 'def', 'class', 'struct', 'enum', 'impl', 'trait', 'type', 'interface',
};

class _Ctx {
  _Ctx(this.masked, {required this.asi})
      : lineStarts = _lineStarts(masked),
        braceMatch = _matchBraces(masked);

  final String masked;
  final bool asi;
  final List<int> lineStarts;
  final Int32List braceMatch;

  int get length => masked.length;

  static List<int> _lineStarts(String s) {
    final starts = <int>[0];
    for (var i = 0; i < s.length; i++) {
      if (s.codeUnitAt(i) == 10) starts.add(i + 1);
    }
    return starts;
  }

  static Int32List _matchBraces(String s) {
    final m = Int32List(s.length)..fillRange(0, s.length, -1);
    final stack = <int>[];
    for (var i = 0; i < s.length; i++) {
      final c = s.codeUnitAt(i);
      if (c == 123) {
        stack.add(i);
      } else if (c == 125 && stack.isNotEmpty) {
        m[stack.removeLast()] = i;
      }
    }
    return m;
  }

  /// 偏移 → (行, 列)。
  (int, int) position(int offset) {
    var lo = 0;
    var hi = lineStarts.length - 1;
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

  int lineEnd(int line) {
    final next = line + 1 < lineStarts.length ? lineStarts[line + 1] - 1 : length;
    var end = next;
    if (end > lineStarts[line] && end - 1 < length && masked.codeUnitAt(end - 1) == 13) end--;
    return end;
  }

  /// 从声明名处向后找体:深度 0 的 `{` → block;`;` / `,` / 外层 `}` / ASI 换行 → decl。
  _Body findBody(int from) {
    var paren = 0;
    var angle = 0;
    var arrow = false;
    var newlines = 0;
    final n = length;
    for (var i = from; i < n; i++) {
      final c = masked.codeUnitAt(i);
      final prev = i > 0 ? masked.codeUnitAt(i - 1) : 0;
      if (c == 40 || c == 91) {
        paren++;
      } else if (c == 41 || c == 93) {
        if (paren == 0) return _Body(_BodyKind.decl, i - 1, terminator: c, arrow: arrow);
        paren--;
      } else if (c == 60) {
        angle++;
      } else if (c == 62) {
        if (prev == 61) {
          if (paren == 0) arrow = true;
        } else if (prev != 45 && angle > 0) {
          angle--;
        }
      } else if (paren == 0) {
        if (c == 123) {
          final close = braceMatch[i];
          return _Body(_BodyKind.block, close >= 0 ? close : n - 1, arrow: arrow);
        }
        if (c == 125) return _Body(_BodyKind.decl, i - 1, terminator: c, arrow: arrow);
        if (c == 59) return _Body(_BodyKind.decl, i, terminator: c, arrow: arrow);
        if (c == 44 && angle == 0) return _Body(_BodyKind.decl, i, terminator: c, arrow: arrow);
        if (c == 10 && asi && _asiEnds(i)) return _Body(_BodyKind.decl, _trimBack(i), terminator: 10, arrow: arrow);
      }
      if (c == 10) {
        newlines++;
        // 括号内(长参数表、JSX)允许很长;括号外迟迟找不到终结符就放弃,避免吞掉后续声明。
        if ((paren == 0 && newlines > 40) || newlines > 2000) break;
      }
    }
    final (line, _) = position(from);
    return _Body(_BodyKind.none, lineEnd(line) - 1);
  }

  int _trimBack(int i) {
    var j = i - 1;
    while (j > 0 && (masked.codeUnitAt(j) == 32 || masked.codeUnitAt(j) == 9 || masked.codeUnitAt(j) == 13)) {
      j--;
    }
    return j;
  }

  /// Go / TS 的自动分号:行尾不是续行符号、下一行也不以 `{` / `.` 开头时,换行即语句结束。
  bool _asiEnds(int nl) {
    final j = _trimBack(nl);
    if (j < 0) return false;
    final last = masked.codeUnitAt(j);
    if (last == 10) return false; // 空行
    if (last == 62 && j > 0 && masked.codeUnitAt(j - 1) == 61) return false; // =>
    const cont = '=,([{:|&+-*/?.!';
    if (cont.contains(String.fromCharCode(last))) return false;
    var k = nl + 1;
    while (k < length) {
      final c = masked.codeUnitAt(k);
      if (c != 32 && c != 9 && c != 10 && c != 13) break;
      k++;
    }
    if (k < length) {
      final next = masked.codeUnitAt(k);
      if (next == 123 || next == 46) return false;
    }
    return true;
  }

  /// Python:找深度 0 的 `:`,其后缩进更深的行都属于体。
  _Body pythonBody(int lineIndex, int from) {
    var paren = 0;
    var colon = -1;
    for (var i = from; i < length; i++) {
      final c = masked.codeUnitAt(i);
      if (c == 40 || c == 91 || c == 123) {
        paren++;
      } else if (c == 41 || c == 93 || c == 125) {
        if (paren > 0) paren--;
      } else if (c == 58 && paren == 0) {
        colon = i;
        break;
      } else if (c == 10 && paren == 0) {
        break;
      }
    }
    if (colon < 0) return _Body(_BodyKind.decl, lineEnd(lineIndex) - 1);
    final base = _indent(lineIndex);
    final headerLine = position(colon).$1;
    var last = headerLine;
    for (var j = headerLine + 1; j < lineStarts.length; j++) {
      final start = lineStarts[j];
      final end = lineEnd(j);
      if (masked.substring(start, end).trim().isEmpty) continue;
      if (_indent(j) <= base) break;
      last = j;
    }
    return _Body(_BodyKind.block, lineEnd(last) - 1);
  }

  int _indent(int line) {
    var i = lineStarts[line];
    var w = 0;
    while (i < length) {
      final c = masked.codeUnitAt(i);
      if (c == 32) {
        w++;
      } else if (c == 9) {
        w += 4;
      } else {
        break;
      }
      i++;
    }
    return w;
  }
}

bool _anyBody(_Body b, _Open? p) => true;
bool _blockOnly(_Body b, _Open? p) => b.isBlock;
bool _notComma(_Body b, _Open? p) => b.terminator != 44;

const _rustContainers = {'impl', 'trait'};

String _rustImplName(RegExpMatch m) {
  // `impl<T: Into<String>> Display for Foo<T> where ...` → `impl Display for Foo<T>`
  var rest = m.group(1)!.substring(4);
  var i = 0;
  while (i < rest.length && rest.codeUnitAt(i) == 32) {
    i++;
  }
  if (i < rest.length && rest[i] == '<') {
    var depth = 0;
    for (; i < rest.length; i++) {
      if (rest[i] == '<') depth++;
      if (rest[i] == '>' && (i == 0 || rest[i - 1] != '-')) {
        depth--;
        if (depth == 0) {
          i++;
          break;
        }
      }
    }
  }
  rest = rest.substring(i);
  final brace = rest.indexOf('{');
  if (brace >= 0) rest = rest.substring(0, brace);
  final where = RegExp(r'\bwhere\b').firstMatch(rest);
  if (where != null) rest = rest.substring(0, where.start);
  rest = rest.replaceAll(RegExp(r'\s+'), ' ').trim();
  return rest.isEmpty ? 'impl' : 'impl $rest';
}

const _rv = r'(?:pub(?:\s*\([^)]*\))?\s+)?';

final List<_Rule> _rustRules = [
  _Rule(r'^\s*' + _rv + r'(?:(?:const|async|unsafe|default|extern(?:\s+"[^"]*")?)\s+)*fn\s+([A-Za-z_]\w*)', 'function',
      parents: {'', 'impl', 'trait', 'module'},
      classify: (m, name, p, b) => _rustContainers.contains(p?.kind) ? 'method' : 'function'),
  _Rule(r'^\s*' + _rv + r'(?:struct|union)\s+([A-Za-z_]\w*)', 'struct', parents: {'', 'module'}, container: true),
  _Rule(r'^\s*' + _rv + r'enum\s+([A-Za-z_]\w*)', 'enum', parents: {'', 'module'}, container: true),
  _Rule(r'^\s*' + _rv + r'(?:unsafe\s+)?(?:auto\s+)?trait\s+([A-Za-z_]\w*)', 'trait',
      parents: {'', 'module'}, container: true),
  _Rule(r'^\s*(?:unsafe\s+)?(impl\b.*)$', 'impl', parents: {'', 'module'}, container: true, nameOf: _rustImplName),
  _Rule(r'^\s*' + _rv + r'mod\s+([A-Za-z_]\w*)', 'module', parents: {'', 'module'}, container: true),
  _Rule(r'^\s*' + _rv + r'(?:const|static)\s+(?:mut\s+)?([A-Za-z_]\w*)\s*:', 'constant',
      parents: {'', 'module', 'impl', 'trait'}),
  _Rule(r'^\s*' + _rv + r'type\s+([A-Za-z_]\w*)', 'type', parents: {'', 'module', 'impl', 'trait'}),
  _Rule(r'^\s*' + _rv + r'([A-Za-z_]\w*)\s*:(?!:)', 'field', parents: {'struct'}),
  _Rule(r'^\s*([A-Z]\w*)\s*(?:[({,=]|$)', 'variant', parents: {'enum'}),
];

final List<_Rule> _goRules = [
  _Rule(r'^func\s*(\([^)]*\))?\s*([A-Za-z_]\w*)', 'function',
      group: 2, parents: {''}, classify: (m, name, p, b) => m.group(1) != null ? 'method' : 'function'),
  _Rule(r'^type\s+([A-Za-z_]\w*)(?:\[[^\]]*\])?\s+struct\b', 'struct', parents: {''}, container: true),
  _Rule(r'^type\s+([A-Za-z_]\w*)(?:\[[^\]]*\])?\s+interface\b', 'interface', parents: {''}, container: true),
  _Rule(r'^type\s+([A-Za-z_]\w*)', 'type', parents: {''}),
  _Rule(r'^(var|const)\s+([A-Za-z_]\w*)', 'variable',
      group: 2, parents: {''}, classify: (m, name, p, b) => m.group(1) == 'const' ? 'constant' : 'variable'),
  _Rule(r'^\s*([A-Za-z_]\w*)\s*\(', 'method', parents: {'interface'}),
  _Rule(r'^\s*([A-Za-z_]\w*)(?:\s*,\s*[A-Za-z_]\w*)*\s+[^\s=]', 'field', parents: {'struct'}),
];

final List<_Rule> _cRules = [
  _Rule(r'^\s*(?:inline\s+)?namespace\s+([A-Za-z_][\w:]*)', 'namespace',
      parents: {'', 'namespace'}, container: true, accept: _blockOnly),
  _Rule(r'^\s*(?:typedef\s+)?(?:template\s*<.*>\s*)?(class|struct|union)\s+(?:[A-Z_][A-Z0-9_]*\s+)?([A-Za-z_]\w*)',
      'struct',
      group: 2,
      parents: {'', 'namespace', 'class', 'struct'},
      container: true,
      accept: _blockOnly,
      classify: (m, name, p, b) => m.group(1) == 'class' ? 'class' : 'struct'),
  _Rule(r'^\s*(?:typedef\s+)?enum\s+(?:class\s+|struct\s+)?([A-Za-z_]\w*)', 'enum',
      parents: {'', 'namespace', 'class', 'struct'}, container: true, accept: _blockOnly),
  _Rule(
      r'^\s*(?:template\s*<.*>\s*)?(?:(?:static|inline|virtual|explicit|extern|constexpr|friend|const|unsigned|signed|struct|enum)\s+)*'
      r'(?:[A-Za-z_][\w:<>,\s\*&]*?[\s\*&]+)?(~?[A-Za-z_]\w*(?:::~?[A-Za-z_]\w*)*|operator\s*[^\s(]+)\s*\(',
      'function',
      parents: {'', 'namespace', 'class', 'struct'},
      accept: (b, p) => b.isBlock || ((p?.kind == 'class' || p?.kind == 'struct') && b.terminator == 59),
      classify: (m, name, p, b) {
        if (p != null && (p.kind == 'class' || p.kind == 'struct')) {
          return name == p.name ? 'constructor' : 'method';
        }
        return name.contains('::') ? 'method' : 'function';
      }),
  _Rule(
      r'^\s*(?:(?:static|const|mutable|inline|constexpr|volatile|unsigned|signed|struct|enum)\s+)*'
      r'[A-Za-z_][\w:<>,\*&\s]*?[\s\*&]+([A-Za-z_]\w*)\s*(?:\[[^\]]*\])?\s*(?:=[^;]*|\{[^}]*\})?;\s*$',
      'field',
      parents: {'class', 'struct'}),
  _Rule(r'^\s*([A-Za-z_]\w*)\s*(?:=[^,]*)?(?:,|$)', 'variant', parents: {'enum'}),
];

const _tsMods = r'(?:(?:export|default|declare|abstract|async)\s+)*';
const _tsTop = {'', 'namespace', 'module'};

final List<_Rule> _tsRules = [
  _Rule(r'^\s*' + _tsMods + r'class\s+([A-Za-z_$][\w$]*)', 'class', parents: _tsTop, container: true),
  _Rule(r'^\s*' + _tsMods + r'interface\s+([A-Za-z_$][\w$]*)', 'interface', parents: _tsTop, container: true),
  _Rule(r'^\s*' + _tsMods + r'(?:const\s+)?enum\s+([A-Za-z_$][\w$]*)', 'enum', parents: _tsTop, container: true),
  _Rule(r'^\s*' + _tsMods + r'type\s+([A-Za-z_$][\w$]*)\s*(?:<[^=]*>)?\s*=', 'type', parents: _tsTop),
  _Rule(r'^\s*' + _tsMods + r'(namespace|module)\s+([A-Za-z_$][\w$.]*)', 'namespace',
      group: 2, parents: _tsTop, container: true, accept: _blockOnly),
  _Rule(r'^\s*' + _tsMods + r'function\s*\*?\s*([A-Za-z_$][\w$]*)', 'function', parents: _tsTop),
  _Rule(
      r'^\s*(?:export\s+)?(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*(?::[^=]+)?=\s*(?:async\s+)?'
      r'(?:function\b|(?:\([^)]*\)|[A-Za-z_$][\w$]*)\s*(?::[^=]+)?=>)',
      'function',
      parents: _tsTop),
  _Rule(r'^\s*(?:export\s+)?(const|let|var)\s+([A-Za-z_$][\w$]*)', 'variable',
      group: 2, parents: _tsTop, classify: (m, name, p, b) => m.group(1) == 'const' ? 'constant' : 'variable'),
  _Rule(
      r'^\s*(?:(?:public|private|protected|static|readonly|async|abstract|override|declare|get|set|accessor)\s+)*'
      r'\*?(#?[A-Za-z_$][\w$]*)\s*[?!]?\s*(?:<[^>]*>)?\s*\(',
      'method',
      parents: {'class'},
      accept: _notComma,
      classify: (m, name, p, b) => name == 'constructor' ? 'constructor' : 'method'),
  _Rule(
      r'^\s*(?:(?:public|private|protected|static|readonly|abstract|override|declare|accessor)\s+)*'
      r'(#?[A-Za-z_$][\w$]*)\s*[?!]?\s*(?:[:=;]|$)',
      'property',
      parents: {'class'}),
  _Rule(r'^\s*(?:readonly\s+)?([A-Za-z_$][\w$]*)\??\s*(?:<[^>]*>)?\s*\(', 'method', parents: {'interface'}),
  _Rule(r'^\s*(?:readonly\s+)?([A-Za-z_$][\w$]*)\??\s*:', 'property', parents: {'interface'}),
  _Rule(r'^\s*([A-Za-z_$][\w$]*)\s*(?:=|,|$)', 'variant', parents: {'enum'}),
];

const _dAnno = r'(?:@[\w.]+(?:\([^)]*\))?\s+)*';
const _dType = r'(?:[A-Za-z_$][\w$<>?,.\[\]\s]*?[\w$>?\]]\s+)?';
const _dClassLike = {'class', 'enum'};

final List<_Rule> _dartRules = [
  _Rule(r'^\s*(?:(?:abstract|base|final|sealed|interface|mixin)\s+)*class\s+([A-Za-z_$][\w$]*)', 'class',
      parents: {''}, container: true),
  _Rule(r'^\s*(?:base\s+)?mixin\s+([A-Za-z_$][\w$]*)', 'class', parents: {''}, container: true),
  _Rule(r'^\s*enum\s+([A-Za-z_$][\w$]*)', 'enum', parents: {''}, container: true),
  _Rule(r'^\s*extension\s+(?:type\s+)?([A-Za-z_$][\w$]*)', 'class',
      parents: {''}, container: true, accept: _blockOnly, nameOf: (m) {
    final n = m.group(1)!;
    return n == 'on' ? 'extension' : n;
  }),
  _Rule(r'^\s*typedef\s+(?:.*?\s)?([A-Za-z_$][\w$]*)\s*(?:<[^>]*>)?\s*[=(]', 'type', parents: {''}),
  _Rule(r'^\s*' + _dAnno + r'(?:(?:static|external|abstract)\s+)*' + _dType + r'get\s+([A-Za-z_$][\w$]*)', 'property',
      accept: _notComma),
  _Rule(r'^\s*' + _dAnno + r'(?:(?:static|external|abstract)\s+)*' + _dType + r'set\s+([A-Za-z_$][\w$]*)\s*\(',
      'property',
      accept: _notComma),
  _Rule(
      r'^\s*' +
          _dAnno +
          r'((?:(?:static|external|factory|const|abstract|covariant)\s+)*)' +
          _dType +
          r'(operator\s*[^\s(]+|[A-Za-z_$][\w$]*(?:\.[A-Za-z_$][\w$]*)?)\s*(?:<[^()]*>)?\s*\(',
      'function',
      group: 2,
      accept: (b, p) => b.isBlock || b.arrow || (p != null && b.terminator == 59),
      classify: (m, name, p, b) {
        if (p == null) return 'function';
        if (m.group(1)!.contains('factory') || name == p.name || name.startsWith('${p.name}.')) {
          return 'constructor';
        }
        // 枚举里以 `;` 结尾的 `blue(2);` 是最后一个枚举值,不是方法声明。
        if (p.kind == 'enum' && !b.isBlock && !b.arrow) return null;
        return 'method';
      }),
  _Rule(r'^\s*([A-Za-z_$][\w$]*)\s*(?:\(|,|;|$)', 'variant', parents: {'enum'}),
  _Rule(
      r'^\s*' +
          _dAnno +
          r'((?:(?:static|final|const|late|var|external|covariant|abstract)\s+)*)' +
          _dType +
          r'([A-Za-z_$][\w$]*)\s*(?:=|;|,)',
      'field',
      group: 2,
      parents: _dClassLike,
      classify: (m, name, p, b) => m.group(1)!.contains('const') ? 'constant' : 'field'),
  _Rule(r'^((?:(?:final|const|late|var)\s+)+)' + _dType + r'([A-Za-z_$][\w$]*)\s*[=;]', 'variable',
      group: 2, parents: {''}, classify: (m, name, p, b) => m.group(1)!.contains('const') ? 'constant' : 'variable'),
  _Rule(r'^([A-Za-z_$][\w$<>?,.\[\]]*\??)\s+([A-Za-z_$][\w$]*)\s*=', 'variable',
      group: 2, parents: {''}, classify: (m, name, p, b) {
    const notTypes = {'import', 'export', 'part', 'library', 'typedef', 'return'};
    return notTypes.contains(m.group(1)) ? null : 'variable';
  }),
];

final List<_Rule> _pythonRules = [
  _Rule(r'^\s*class\s+([A-Za-z_]\w*)', 'class', parents: {'', 'class'}, container: true),
  _Rule(r'^\s*(?:async\s+)?def\s+([A-Za-z_]\w*)', 'function',
      parents: {'', 'class'}, classify: (m, name, p, b) => p?.kind == 'class' ? 'method' : 'function'),
  _Rule(r'^([A-Z_][A-Z0-9_]*)\s*(?::[^=]*)?=(?!=)', 'constant', parents: {''}),
];

List<_Rule>? _rulesFor(String? languageId) {
  switch (languageId) {
    case 'rust':
      return _rustRules;
    case 'go':
      return _goRules;
    case 'c':
    case 'cpp':
      return _cRules;
    case 'typescript':
    case 'typescriptreact':
    case 'javascript':
    case 'javascriptreact':
      return _tsRules;
    case 'dart':
      return _dartRules;
    case 'python':
      return _pythonRules;
  }
  return null;
}

/// Dart 的 Match 不提供分组偏移:在整段匹配里找该分组文本第一次「整词」出现的位置。
/// 各规则的名字分组前面只有关键字/修饰符/类型,名字与它们重合的情况可以忽略。
int _groupStart(RegExpMatch m, String raw) {
  final whole = m.group(0)!;
  final identStart = _isIdent(raw.codeUnitAt(0));
  final identEnd = _isIdent(raw.codeUnitAt(raw.length - 1));
  var from = 0;
  while (true) {
    final i = whole.indexOf(raw, from);
    if (i < 0) return m.start;
    final before = i > 0 ? whole.codeUnitAt(i - 1) : 32;
    final j = i + raw.length;
    final after = j < whole.length ? whole.codeUnitAt(j) : 32;
    if (!(identStart && _isIdent(before)) && !(identEnd && _isIdent(after))) return m.start + i;
    from = i + 1;
  }
}

/// 无语言服务端时的大纲:逐行正则识别声明,用括号(Python 用缩进)界定体,还原容器层级。
///
/// 函数体内部一律跳过(局部变量、闭包不进大纲);class/struct/impl 等容器体内继续识别成员。
/// 输出格式与 [lspParseDocumentSymbols] 一致(0 基行列,`children` 恒存在)。
List<Map<String, dynamic>> lspRegexOutline(String text, String? languageId) {
  final rules = _rulesFor(languageId);
  if (rules == null || text.isEmpty) return <Map<String, dynamic>>[];
  final isPython = languageId == 'python';
  final asi = isPython || languageId == 'go' || (languageId?.startsWith('typescript') ?? false) ||
      (languageId?.startsWith('javascript') ?? false);
  final ctx = _Ctx(lspMaskCode(text, languageId), asi: asi);
  final roots = <Map<String, dynamic>>[];
  final stack = <_Open>[];

  for (var li = 0; li < ctx.lineStarts.length; li++) {
    final lineStart = ctx.lineStarts[li];
    var line = ctx.masked.substring(lineStart, ctx.lineEnd(li));
    // 声明头不会太长;截断超长行(压缩代码)避免正则回溯退化成平方级。
    if (line.length > 300) line = line.substring(0, 300);
    final firstCode = line.indexOf(RegExp(r'\S'));
    if (firstCode < 0) continue;
    // 体已结束的容器出栈;行首恰好是容器的 `}` 时,该行也已在容器之外。
    while (stack.isNotEmpty && stack.last.end <= lineStart + firstCode) {
      stack.removeLast();
    }
    final parent = stack.isEmpty ? null : stack.last;
    if (parent != null && parent.opaque) continue;

    for (final rule in rules) {
      if (!rule.allows(parent)) continue;
      final m = rule.re.firstMatch(line);
      if (m == null) continue;
      final raw = m.group(rule.group);
      if (raw == null || raw.isEmpty) continue;
      final name = rule.nameOf?.call(m) ?? raw;
      if (_keywords.contains(name)) continue;
      final nameCol = _groupStart(m, raw);
      final body = isPython ? ctx.pythonBody(li, lineStart + nameCol) : ctx.findBody(lineStart + nameCol);
      if (!(rule.accept ?? _anyBody)(body, parent)) continue;
      final kind = rule.classify == null ? rule.kind : rule.classify!(m, name, parent, body);
      if (kind == null) continue;
      final endPos = ctx.position(body.end < lineStart + nameCol ? lineStart + nameCol : body.end);
      final node = <String, dynamic>{
        'name': name,
        'kind': kind,
        'line_start': li,
        'col_start': nameCol,
        'line_end': endPos.$1,
        'col_end': endPos.$2 + 1,
        'children': <Map<String, dynamic>>[],
      };
      if (parent == null) {
        roots.add(node);
      } else {
        (parent.node['children'] as List<Map<String, dynamic>>).add(node);
      }
      if (body.isBlock) {
        stack.add(_Open(node, kind, name, body.end, opaque: !rule.container));
      }
      break;
    }
  }
  return roots;
}
