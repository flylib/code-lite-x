import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import 'codelite_bindings.dart' show codeliteLibraryPath;

typedef _OpenC = Pointer<Void> Function(Pointer<Uint8> grammar, Pointer<Uint8> text, Size len);
typedef _OpenDart = Pointer<Void> Function(Pointer<Uint8> grammar, Pointer<Uint8> text, int len);
typedef _EditC = Void Function(Pointer<Void> doc, Uint32 start, Uint32 oldCount, Pointer<Uint8> text, Size len);
typedef _EditDart = void Function(Pointer<Void> doc, int start, int oldCount, Pointer<Uint8> text, int len);
typedef _StatusC = Uint64 Function(Pointer<Void> doc);
typedef _StatusDart = int Function(Pointer<Void> doc);
typedef _HighlightC = Pointer<Uint8> Function(Pointer<Void> doc, Uint32 from, Uint32 to, Pointer<Size> outLen);
typedef _HighlightDart = Pointer<Uint8> Function(Pointer<Void> doc, int from, int to, Pointer<Size> outLen);
typedef _AllocC = Pointer<Uint8> Function(Size len);
typedef _AllocDart = Pointer<Uint8> Function(int len);
typedef _FreeBufC = Void Function(Pointer<Uint8> ptr, Size len);
typedef _FreeBufDart = void Function(Pointer<Uint8> ptr, int len);
typedef _CloseDart = void Function(Pointer<Void> doc);

class _Fns {
  _Fns(DynamicLibrary lib)
      : open = lib.lookupFunction<_OpenC, _OpenDart>('codelite_syntax_open'),
        edit = lib.lookupFunction<_EditC, _EditDart>('codelite_syntax_edit'),
        status = lib.lookupFunction<_StatusC, _StatusDart>('codelite_syntax_status'),
        highlight = lib.lookupFunction<_HighlightC, _HighlightDart>('codelite_syntax_highlight'),
        folds = lib.providesSymbol('codelite_syntax_folds') ? lib.lookupFunction<_HighlightC, _HighlightDart>('codelite_syntax_folds') : null,
        closePtr = lib.lookup<NativeFunction<Void Function(Pointer<Void>)>>('codelite_syntax_close'),
        alloc = lib.lookupFunction<_AllocC, _AllocDart>('codelite_string_alloc'),
        freeInput = lib.lookupFunction<_FreeBufC, _FreeBufDart>('codelite_buffer_free'),
        freeBytes = lib.lookupFunction<_FreeBufC, _FreeBufDart>('codelite_bytes_free');

  final _OpenDart open;
  final _EditDart edit;
  final _StatusDart status;
  final _HighlightDart highlight;

  /// 旧库没有折叠:null。
  final _HighlightDart? folds;
  final Pointer<NativeFunction<Void Function(Pointer<Void>)>> closePtr;
  late final _CloseDart close = closePtr.asFunction<_CloseDart>();
  final _AllocDart alloc;
  final _FreeBufDart freeInput;
  final _FreeBufDart freeBytes;

  /// 忘了关的文档(比如没走 dispose 的测试)由 GC 回收时关掉。
  late final NativeFinalizer finalizer = NativeFinalizer(closePtr.cast());

  late final Pointer<Size> outLen = alloc(sizeOf<Size>()).cast<Size>();

  /// 放进 Rust 分配的缓冲(Rust 释放);[run] 拿到指针和长度。
  T withBytes<T>(List<int> bytes, T Function(Pointer<Uint8> p, int len) run) {
    final p = alloc(bytes.length);
    p.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    try {
      return run(p, bytes.length);
    } finally {
      freeInput(p, bytes.length);
    }
  }
}

_Fns? _fns;
var _tried = false;

_Fns? _load() {
  if (_tried) return _fns;
  _tried = true;
  final path = codeliteLibraryPath();
  if (path == null) return null;
  try {
    final lib = DynamicLibrary.open(path);
    for (final s in ['codelite_syntax_open', 'codelite_syntax_highlight', 'codelite_bytes_free']) {
      if (!lib.providesSymbol(s)) return null;
    }
    return _fns = _Fns(lib);
  } catch (_) {
    return null;
  }
}

/// 每行后面都带 `\n`(Rust 那边的约定:改几行就是一段字节替换)。
List<int> _encodeLines(List<String> lines) {
  final sb = StringBuffer();
  for (final l in lines) {
    sb
      ..write(l)
      ..write('\n');
  }
  return utf8.encode(sb.toString());
}

/// 一个文档的语法树(tree-sitter,在 Rust 里;见 crates/code-lite-syntax)。
class SyntaxTreeDoc implements Finalizable {
  SyntaxTreeDoc._(this._f, this._ptr) {
    _f.finalizer.attach(this, _ptr, detach: this);
  }

  final _Fns _f;
  Pointer<Void> _ptr;

  /// 打开文档([grammar] 见 `code_lite_syntax::NAMES`);没有 Rust 库或不认识这个语法时返回 null。
  /// 第一次解析在 Rust 的后台线程里。
  static SyntaxTreeDoc? open(String grammar, List<String> lines) {
    final f = _load();
    if (f == null) return null;
    final ptr = f.withBytes(utf8.encode(grammar), (g, _) => f.withBytes(_encodeLines(lines), (t, n) => f.open(g, t, n)));
    if (ptr == nullptr) return null;
    return SyntaxTreeDoc._(f, ptr);
  }

  /// 第 [start] 行起的 [oldCount] 行换成 [newLines]。
  void edit(int start, int oldCount, List<String> newLines) {
    if (_ptr == nullptr) return;
    _f.withBytes(_encodeLines(newLines), (t, n) => _f.edit(_ptr, start, oldCount, t, n));
  }

  /// `generation << 1 | 后台还在解析`。
  int get status => _ptr == nullptr ? 0 : _f.status(_ptr);

  /// 第 [from, to) 行的着色;语法树还没建好时返回 null。
  SyntaxSlice? highlight(int from, int to) {
    if (_ptr == nullptr) return null;
    final out = _f.highlight(_ptr, from, to, _f.outLen);
    final len = _f.outLen.value;
    if (out == nullptr) return null;
    try {
      return SyntaxSlice.decode(out.asTypedList(len));
    } finally {
      _f.freeBytes(out, len);
    }
  }

  /// 从第 [from, to) 行开始的折叠范围(起始行、结束行,隐藏 起始行+1..=结束行);语法树还没建好时返回 null。
  List<FoldRange>? folds(int from, int to) {
    final fn = _f.folds;
    if (_ptr == nullptr || fn == null) return null;
    final out = fn(_ptr, from, to, _f.outLen);
    final len = _f.outLen.value;
    if (out == nullptr) return null;
    try {
      final b = out.asTypedList(len);
      if (len < 12 || b[0] != 1) return null;
      final d = ByteData.sublistView(b);
      final n = d.getUint32(8, Endian.little);
      return [
        for (var i = 0; i < n; i++) FoldRange(d.getUint32(12 + i * 8, Endian.little), d.getUint32(16 + i * 8, Endian.little)),
      ];
    } finally {
      _f.freeBytes(out, len);
    }
  }

  void close() {
    if (_ptr == nullptr) return;
    _f.finalizer.detach(this);
    _f.close(_ptr);
    _ptr = nullptr;
  }
}

/// [from] 起每一行的着色:扁平的 `[起列, 止列, 种类, …]`(UTF-16 列);`null` = 这行语法树还没跟上。
class SyntaxSlice {
  const SyntaxSlice(this.generation, this.from, this.lines);
  final int generation;
  final int from;
  final List<Uint32List?> lines;

  /// 格式见 `code_lite_syntax::Document::highlight`。没有语法树时返回 null。
  static SyntaxSlice? decode(Uint8List b) {
    if (b.length < 16 || b[0] != 1 || b[1] != 1) return null;
    final d = ByteData.sublistView(b);
    final generation = d.getUint32(4, Endian.little);
    final from = d.getUint32(8, Endian.little);
    final n = d.getUint32(12, Endian.little);
    final lines = <Uint32List?>[];
    var o = 16;
    for (var i = 0; i < n; i++) {
      final dirty = b[o] == 1;
      final count = d.getUint32(o + 1, Endian.little);
      o += 5;
      if (dirty) {
        lines.add(null);
        continue;
      }
      final t = Uint32List(count * 3);
      for (var k = 0; k < count; k++) {
        t[k * 3] = d.getUint32(o, Endian.little);
        t[k * 3 + 1] = d.getUint32(o + 4, Endian.little);
        t[k * 3 + 2] = b[o + 8];
        o += 9;
      }
      lines.add(t);
    }
    return SyntaxSlice(generation, from, lines);
  }
}

/// 一段可折叠的范围:收起时 [start] 行留着,[start]+1 ..= [end] 行藏起来。
class FoldRange {
  const FoldRange(this.start, this.end);
  final int start;
  final int end;

  @override
  bool operator ==(Object other) => other is FoldRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  @override
  String toString() => 'FoldRange($start..$end)';
}

/// 文件路径 → 语法名(`code_lite_syntax::NAMES`);没有对应语法返回 null。
String? syntaxGrammarForPath(String path) {
  final dot = path.lastIndexOf('.');
  final ext = dot < 0 ? '' : path.substring(dot + 1).toLowerCase();
  return switch (ext) {
    'java' => 'java',
    'dart' => 'dart',
    'py' || 'pyi' || 'pyw' => 'python',
    'go' => 'go',
    'rs' => 'rust',
    'js' || 'mjs' || 'cjs' || 'jsx' => 'javascript',
    'ts' || 'mts' || 'cts' => 'typescript',
    'tsx' => 'tsx',
    _ => null,
  };
}

typedef _OutlineC = Pointer<Uint8> Function(Pointer<Uint8> grammar, Pointer<Uint8> text, Size len);
typedef _OutlineDart = Pointer<Uint8> Function(Pointer<Uint8> grammar, Pointer<Uint8> text, int len);
typedef _FreeStrC = Void Function(Pointer<Uint8> ptr);
typedef _FreeStrDart = void Function(Pointer<Uint8> ptr);

/// 结构视图的大纲交给 Rust 的语法树(没有语言服务器时用,代替正则大纲):在后台 isolate 里解析,不卡界面。
/// 格式同 `lspParseDocumentSymbols`。没有 Rust 库、库太旧、或这种文件没有语法时返回 null。
Future<List<Map<String, dynamic>>?> rustOutline(String path, String text) async {
  final grammar = syntaxGrammarForPath(path);
  final lib = codeliteLibraryPath();
  if (grammar == null || lib == null) return null;
  final out = await Isolate.run(() => _outline(lib, grammar, text));
  if (out == null) return null;
  final decoded = jsonDecode(out);
  return decoded is List ? decoded.cast<Map<String, dynamic>>() : null;
}

String? _outline(String libraryPath, String grammar, String text) {
  final lib = DynamicLibrary.open(libraryPath);
  if (!lib.providesSymbol('codelite_syntax_outline')) return null;
  final outline = lib.lookupFunction<_OutlineC, _OutlineDart>('codelite_syntax_outline');
  final alloc = lib.lookupFunction<_AllocC, _AllocDart>('codelite_string_alloc');
  final freeBuf = lib.lookupFunction<_FreeBufC, _FreeBufDart>('codelite_buffer_free');
  final freeStr = lib.lookupFunction<_FreeStrC, _FreeStrDart>('codelite_string_free');
  Pointer<Uint8> put(List<int> bytes) {
    final p = alloc(bytes.length);
    p.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    return p;
  }

  final g = utf8.encode(grammar), t = utf8.encode(text);
  final pg = put(g), pt = put(t);
  try {
    final res = outline(pg, pt, t.length);
    if (res == nullptr) return null;
    var len = 0;
    while (res[len] != 0) {
      len++;
    }
    final json = utf8.decode(Uint8List.fromList(res.asTypedList(len)), allowMalformed: true);
    freeStr(res);
    return json;
  } finally {
    freeBuf(pg, g.length);
    freeBuf(pt, t.length);
  }
}
