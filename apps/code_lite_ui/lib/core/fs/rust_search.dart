import 'dart:convert';
import 'dart:ffi';
import 'dart:isolate';
import 'dart:typed_data';

import '../ffi/codelite_bindings.dart' show codeliteLibraryPath;

typedef _SearchC = Pointer<Char> Function(Pointer<Char> request);
typedef _AllocC = Pointer<Char> Function(Size len);
typedef _AllocDart = Pointer<Char> Function(int len);
typedef _FreeBufC = Void Function(Pointer<Char> ptr, Size len);
typedef _FreeBufDart = void Function(Pointer<Char> ptr, int len);
typedef _FreeStrC = Void Function(Pointer<Char> ptr);
typedef _FreeStrDart = void Function(Pointer<Char> ptr);

/// 全局搜索 / 替换交给 Rust(`codelite_search`,内部多线程并行):在后台 isolate 里调,不卡界面。
/// [request]:`{"op":"search"|"replace","root","query","replacement","options"}`。
/// 没有 Rust 库、库太旧没有这个函数时返回 null(调用方用 Dart 的实现)。
Future<Map<String, dynamic>?> rustSearch(Map<String, dynamic> request) async {
  final path = codeliteLibraryPath();
  if (path == null) return null;
  final json = jsonEncode(request);
  final out = await Isolate.run(() => _call(path, json));
  if (out == null) return null;
  final decoded = jsonDecode(out);
  return decoded is Map<String, dynamic> ? decoded : null;
}

/// 在后台 isolate 里:打开同一个库,调用,拷出结果,再把内存还给 Rust(谁分配谁释放)。
String? _call(String libraryPath, String request) {
  final lib = DynamicLibrary.open(libraryPath);
  if (!lib.providesSymbol('codelite_search')) return null;
  final search = lib.lookupFunction<_SearchC, _SearchC>('codelite_search');
  final alloc = lib.lookupFunction<_AllocC, _AllocDart>('codelite_string_alloc');
  final freeBuf = lib.lookupFunction<_FreeBufC, _FreeBufDart>('codelite_buffer_free');
  final freeStr = lib.lookupFunction<_FreeStrC, _FreeStrDart>('codelite_string_free');

  final bytes = utf8.encode(request);
  final req = alloc(bytes.length);
  req.cast<Uint8>().asTypedList(bytes.length + 1)
    ..setAll(0, bytes)
    ..[bytes.length] = 0;
  final res = search(req);
  freeBuf(req, bytes.length);
  if (res == nullptr) return null;
  final p = res.cast<Uint8>();
  var len = 0;
  while (p[len] != 0) {
    len++;
  }
  final text = utf8.decode(Uint8List.fromList(p.asTypedList(len)), allowMalformed: true);
  freeStr(res);
  return text;
}
