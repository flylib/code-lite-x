import 'dart:convert';
import 'dart:ffi';
import 'dart:typed_data';

import 'codelite_bindings.dart' show codeliteLibraryPath;

typedef _DiffC = Pointer<Uint8> Function(Pointer<Uint8> a, Size aLen, Uint32 aCount, Pointer<Uint8> b, Size bLen, Uint32 bCount, Pointer<Size> outLen);
typedef _DiffDart = Pointer<Uint8> Function(Pointer<Uint8> a, int aLen, int aCount, Pointer<Uint8> b, int bLen, int bCount, Pointer<Size> outLen);
typedef _AllocC = Pointer<Uint8> Function(Size len);
typedef _AllocDart = Pointer<Uint8> Function(int len);
typedef _FreeBufC = Void Function(Pointer<Uint8> ptr, Size len);
typedef _FreeBufDart = void Function(Pointer<Uint8> ptr, int len);

class _Fns {
  _Fns(DynamicLibrary lib)
      : diff = lib.lookupFunction<_DiffC, _DiffDart>('codelite_line_diff'),
        alloc = lib.lookupFunction<_AllocC, _AllocDart>('codelite_string_alloc'),
        freeInput = lib.lookupFunction<_FreeBufC, _FreeBufDart>('codelite_buffer_free'),
        freeBytes = lib.lookupFunction<_FreeBufC, _FreeBufDart>('codelite_bytes_free');

  final _DiffDart diff;
  final _AllocDart alloc;
  final _FreeBufDart freeInput;
  final _FreeBufDart freeBytes;

  /// 长度出参:借 Rust 的分配函数要一块,一直用着。
  late final Pointer<Size> outLen = alloc(sizeOf<Size>()).cast<Size>();
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
    if (!lib.providesSymbol('codelite_line_diff') || !lib.providesSymbol('codelite_bytes_free')) return null;
    return _fns = _Fns(lib);
  } catch (_) {
    return null;
  }
}

/// 按行差分交给 Rust(imara-diff,histogram):返回扁平的 `[aStart, aEnd, bStart, bEnd, …]`;
/// 没有 Rust 库 / 库太旧时返回 null(调用方用 Dart 的实现)。同步调用:5 万行整体改写也只要几十毫秒。
Uint32List? rustLineHunks(List<String> a, List<String> b) {
  final f = _load();
  if (f == null) return null;
  // 两边各拼成一段 `\n` 连起来的 UTF-8(行里不会有 \n),交给 Rust 时带上行数(区分「没有行」和「一行空串」)
  Pointer<Uint8> put(List<int> bytes) {
    final p = f.alloc(bytes.length);
    p.asTypedList(bytes.length + 1)
      ..setAll(0, bytes)
      ..[bytes.length] = 0;
    return p;
  }

  final ab = utf8.encode(a.join('\n')), bb = utf8.encode(b.join('\n'));
  final pa = put(ab), pb = put(bb);
  try {
    final out = f.diff(pa, ab.length, a.length, pb, bb.length, b.length, f.outLen);
    final len = f.outLen.value;
    if (out == nullptr) return Uint32List(0);
    final bytes = Uint8List.fromList(out.asTypedList(len));
    f.freeBytes(out, len);
    return bytes.buffer.asUint32List(0, len ~/ 4); // 小端(macOS / Windows / Linux 的 x86 与 arm 都是)
  } finally {
    f.freeInput(pa, ab.length);
    f.freeInput(pb, bb.length);
  }
}
