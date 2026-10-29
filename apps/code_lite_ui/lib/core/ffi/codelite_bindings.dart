import 'dart:convert';
import 'dart:ffi';
import 'dart:io';
import 'dart:typed_data';

import '../l10n/l10n.dart';
import 'pty_frame.dart';

// Native function typedefs
typedef _InitC = Pointer<Void> Function(Pointer<Char> path);
typedef _InitDart = Pointer<Void> Function(Pointer<Char> path);

typedef _DestroyC = Void Function(Pointer<Void> ctx);
typedef _DestroyDart = void Function(Pointer<Void> ctx);

typedef _VersionC = Pointer<Char> Function();
typedef _VersionDart = Pointer<Char> Function();

typedef _StringAllocC = Pointer<Char> Function(Size len);
typedef _StringAllocDart = Pointer<Char> Function(int len);

typedef _StringFreeC = Void Function(Pointer<Char> ptr);
typedef _StringFreeDart = void Function(Pointer<Char> ptr);

typedef _BufferFreeC = Void Function(Pointer<Char> ptr, Size len);
typedef _BufferFreeDart = void Function(Pointer<Char> ptr, int len);
































typedef _TerminalExecC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> cmd, Pointer<Char> argsJson);
typedef _TerminalExecDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> cmd, Pointer<Char> argsJson);
typedef _PtyOpenC = Pointer<Char> Function(Pointer<Void> ctx, Uint16 rows, Uint16 cols);
typedef _PtyOpenDart = Pointer<Char> Function(Pointer<Void> ctx, int rows, int cols);
typedef _PtyWriteC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, Pointer<Char> data);
typedef _PtyWriteDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, Pointer<Char> data);
typedef _PtyResizeC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, Uint16 rows, Uint16 cols);
typedef _PtyResizeDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, int rows, int cols);
typedef _PtyFrameC = Pointer<Uint8> Function(Pointer<Void> ctx, Pointer<Char> id, Int64 sinceSeq, Uint32 scrollback, Pointer<Size> outLen);
typedef _PtyFrameDart = Pointer<Uint8> Function(Pointer<Void> ctx, Pointer<Char> id, int sinceSeq, int scrollback, Pointer<Size> outLen);
typedef _BytesFreeC = Void Function(Pointer<Uint8> ptr, Size len);
typedef _BytesFreeDart = void Function(Pointer<Uint8> ptr, int len);

typedef _IndexRefreshC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> root);
typedef _IndexQueryC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> root, Pointer<Char> query, Uint32 limit);
typedef _IndexQueryDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> root, Pointer<Char> query, int limit);

typedef _PtySnapshotC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, Int64 sinceSeq, Uint32 scrollback);
typedef _PtySnapshotDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id, int sinceSeq, int scrollback);
typedef _PtyCloseC = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id);
typedef _PtyCloseDart = Pointer<Char> Function(Pointer<Void> ctx, Pointer<Char> id);

























/// Dart FFI bindings to Rust Core dynamic library (`libcodelite.dylib`).
class CodeLiteBindings {
  static final CodeLiteBindings instance = CodeLiteBindings._();
  CodeLiteBindings._();

  /// 一个全新的绑定:自己的 Rust 上下文(终端会话活在里面)。
  /// 每个打开的项目各用一个,互不影响 —— 单例 [instance] 只有一个上下文,
  /// 多个项目共用它,切换一次就把别的项目的终端全杀了。
  factory CodeLiteBindings.create() => CodeLiteBindings._();

  DynamicLibrary? _dylib;
  Pointer<Void>? _ctx;
  bool _initialized = false;
  bool _symbolsBound = false;

  bool get isAvailable => _dylib != null && _ctx != null && _ctx!.address != 0;

  // Function pointers
  late final _InitDart _init;
  late final _DestroyDart _destroy;
  late final _VersionDart _version;
  late final _StringAllocDart _stringAlloc;
  late final _StringFreeDart _stringFree;
  late final _BufferFreeDart _bufferFree;
  late final _TerminalExecDart _terminalExec;
  late final _PtyOpenDart _ptyOpen;
  late final _PtyWriteDart _ptyWrite;
  late final _PtyResizeDart _ptyResize;
  late final _PtySnapshotDart _ptySnapshot;

  /// 二进制画面帧;库太旧(没有这两个函数)时为 null,退回 JSON 快照。
  _PtyFrameDart? _ptyFrame;

  /// 项目文件索引(Go to File);库太旧时为 null。
  _IndexRefreshC? _indexRefresh;
  _IndexQueryDart? _indexQuery;

  /// 文件监视;库太旧时为 null。
  _IndexRefreshC? _watchStart;
  _IndexRefreshC? _watchPoll;
  _BytesFreeDart? _bytesFree;

  /// 复用的长度出参(只在调用它的线程上用)。
  Pointer<Size>? _lenOut;
  late final _PtyCloseDart _ptyClose;

  Pointer<Void>? get contextPointer => _ctx;

  /// Loads the dynamic library and initializes Rust Core.
  bool initialize([String workspacePath = '.']) {
    if (_initialized) return isAvailable;

    try {
      // 库与符号只绑定一次:这些是 late final,二次赋值会抛 LateInitializationError。
      // reinitialize 走到这里时直接复用,只重建下面的 Rust 上下文。
      if (!_symbolsBound) {
        _dylib = _loadLibrary();
        if (_dylib == null) return false;
        _bindSymbols();
        _symbolsBound = true;
      }

      final pathPtr = _toCString(workspacePath);
      _ctx = _init(pathPtr.pointer);
      _freeAllocatedString(pathPtr);

      _initialized = _ctx != null && _ctx!.address != 0;
      return _initialized;
    } catch (e) {
      if (!_symbolsBound) _dylib = null;
      _ctx = null;
      _initialized = false;
      return false;
    }
  }

  void _bindSymbols() {
    _init = _dylib!.lookupFunction<_InitC, _InitDart>('codelite_init');
    _destroy = _dylib!.lookupFunction<_DestroyC, _DestroyDart>('codelite_destroy');
    _version = _dylib!.lookupFunction<_VersionC, _VersionDart>('codelite_version');
    _stringAlloc = _dylib!.lookupFunction<_StringAllocC, _StringAllocDart>('codelite_string_alloc');
    _stringFree = _dylib!.lookupFunction<_StringFreeC, _StringFreeDart>('codelite_string_free');
    _bufferFree = _dylib!.lookupFunction<_BufferFreeC, _BufferFreeDart>('codelite_buffer_free');
    _terminalExec = _dylib!.lookupFunction<_TerminalExecC, _TerminalExecDart>('codelite_terminal_exec');
    _ptyOpen = _dylib!.lookupFunction<_PtyOpenC, _PtyOpenDart>('codelite_pty_open');
    _ptyWrite = _dylib!.lookupFunction<_PtyWriteC, _PtyWriteDart>('codelite_pty_write');
    _ptyResize = _dylib!.lookupFunction<_PtyResizeC, _PtyResizeDart>('codelite_pty_resize');
    _ptySnapshot = _dylib!.lookupFunction<_PtySnapshotC, _PtySnapshotDart>('codelite_pty_snapshot');
    if (_dylib!.providesSymbol('codelite_index_query') && _dylib!.providesSymbol('codelite_index_refresh')) {
      _indexRefresh = _dylib!.lookupFunction<_IndexRefreshC, _IndexRefreshC>('codelite_index_refresh');
      _indexQuery = _dylib!.lookupFunction<_IndexQueryC, _IndexQueryDart>('codelite_index_query');
    }
    if (_dylib!.providesSymbol('codelite_watch_start') && _dylib!.providesSymbol('codelite_watch_poll')) {
      _watchStart = _dylib!.lookupFunction<_IndexRefreshC, _IndexRefreshC>('codelite_watch_start');
      _watchPoll = _dylib!.lookupFunction<_IndexRefreshC, _IndexRefreshC>('codelite_watch_poll');
    }
    if (_dylib!.providesSymbol('codelite_pty_frame') && _dylib!.providesSymbol('codelite_bytes_free')) {
      _ptyFrame = _dylib!.lookupFunction<_PtyFrameC, _PtyFrameDart>('codelite_pty_frame');
      _bytesFree = _dylib!.lookupFunction<_BytesFreeC, _BytesFreeDart>('codelite_bytes_free');
    }
    _ptyClose = _dylib!.lookupFunction<_PtyCloseC, _PtyCloseDart>('codelite_pty_close');
  }

  /// 销毁当前上下文并以新的工作区根重新初始化(File → Open)。
  /// 动态库与函数指针沿用,只重建 Rust 侧的 CodeLiteContext。
  bool reinitialize(String workspacePath) {
    dispose();
    return initialize(workspacePath);
  }

  void dispose() {
    if (_ctx != null && _ctx!.address != 0) {
      _destroy(_ctx!);
      _ctx = null;
      _initialized = false;
    }
  }

  String getVersion() {
    if (!isAvailable) return 'offline';
    final ptr = _version();
    return _fromCString(ptr);
  }

  // ---------------------------------------------------------------------------
  // LSP (Language Server Protocol) Cognitive Capabilities (P2.1 - P2.6)
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Phase 4: Viewport Tokens, Workspace Search & Terminal Execution
  // ---------------------------------------------------------------------------

  Map<String, dynamic> terminalExec(String cmd, List<String> args) {
    if (!isAvailable) return {'status': 'error', 'error': tr('原生库不可用', 'Bindings unavailable')};
    final cmdPtr = _toCString(cmd);
    final argsPtr = _toCString(jsonEncode(args));
    final ptr = _terminalExec(_ctx!, cmdPtr.pointer, argsPtr.pointer);
    _freeAllocatedString(cmdPtr);
    _freeAllocatedString(argsPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  // --- 交互式终端(PTY)。屏幕由 Rust 侧 vt100 排好版,这里只搬 JSON。

  Map<String, dynamic> ptyOpen(int rows, int cols) {
    if (!isAvailable) return {'status': 'error', 'error': tr('FFI 不可用', 'FFI not available')};
    return _parseJsonMap(_fromCString(_ptyOpen(_ctx!, rows, cols)));
  }

  Map<String, dynamic> ptyWrite(String id, String data) {
    if (!isAvailable) return {'status': 'error', 'error': tr('FFI 不可用', 'FFI not available')};
    final idPtr = _toCString(id);
    final dataPtr = _toCString(data);
    final ptr = _ptyWrite(_ctx!, idPtr.pointer, dataPtr.pointer);
    _freeAllocatedString(idPtr);
    _freeAllocatedString(dataPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> ptyResize(String id, int rows, int cols) {
    if (!isAvailable) return {'status': 'error', 'error': tr('FFI 不可用', 'FFI not available')};
    final idPtr = _toCString(id);
    final ptr = _ptyResize(_ctx!, idPtr.pointer, rows, cols);
    _freeAllocatedString(idPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  /// 开始监视 [root](Rust,过滤掉构建产物等的事件)。库里没有 / 系统不让监视时返回 false。
  bool watchStart(String root) {
    final f = _watchStart;
    if (!isAvailable || f == null) return false;
    final rootPtr = _toCString(root);
    final r = _parseJsonMap(_fromCString(f(_ctx!, rootPtr.pointer)));
    _freeAllocatedString(rootPtr);
    return r['status'] == 'ok';
  }

  /// 取走 [root] 攒下的文件变化;没在监视 / 库里没有时返回 null。
  Map<String, dynamic>? watchPoll(String root) {
    final f = _watchPoll;
    if (!isAvailable || f == null) return null;
    final rootPtr = _toCString(root);
    final r = _parseJsonMap(_fromCString(f(_ctx!, rootPtr.pointer)));
    _freeAllocatedString(rootPtr);
    return r['status'] == 'ok' ? r : null;
  }

  /// 在后台重新扫 [root] 的文件清单。库里没有这个函数时返回 false。
  bool indexRefresh(String root) {
    final f = _indexRefresh;
    if (!isAvailable || f == null) return false;
    final rootPtr = _toCString(root);
    final ptr = f(_ctx!, rootPtr.pointer);
    _freeAllocatedString(rootPtr);
    _fromCString(ptr);
    return true;
  }

  /// 按文件名模糊查找(Rust 文件索引)。库里没有这个函数时返回 null。
  Map<String, dynamic>? indexQuery(String root, String query, int limit) {
    final f = _indexQuery;
    if (!isAvailable || f == null) return null;
    final rootPtr = _toCString(root), queryPtr = _toCString(query);
    final ptr = f(_ctx!, rootPtr.pointer, queryPtr.pointer, limit);
    _freeAllocatedString(rootPtr);
    _freeAllocatedString(queryPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  /// 一帧终端画面(二进制,只带变了的行)。库里没有这个函数时返回 null(调用方退回 [ptySnapshot])。
  PtyFrame? ptyFrame(String id, {int sinceSeq = -1, int scrollback = 0}) {
    final frame = _ptyFrame, free = _bytesFree;
    if (!isAvailable || frame == null || free == null) return null;
    final lenOut = _lenOut ??= _allocSize();
    final idPtr = _toCString(id);
    final ptr = frame(_ctx!, idPtr.pointer, sinceSeq, scrollback, lenOut);
    _freeAllocatedString(idPtr);
    if (ptr == nullptr) return PtyFrame.lostFrame;
    final len = lenOut.value;
    // 先拷出来再还给 Rust(谁分配谁释放)
    final bytes = Uint8List.fromList(ptr.asTypedList(len));
    free(ptr, len);
    return PtyFrame.decode(bytes);
  }

  /// 长度出参:借 Rust 的分配函数要一块 8 字节内存(不引入 package:ffi),进程结束前不释放。
  Pointer<Size> _allocSize() => _stringAlloc(sizeOf<Size>()).cast<Size>();

  Map<String, dynamic> ptySnapshot(String id, {int sinceSeq = -1, int scrollback = 0}) {
    if (!isAvailable) return {'status': 'error', 'error': tr('FFI 不可用', 'FFI not available')};
    final idPtr = _toCString(id);
    final ptr = _ptySnapshot(_ctx!, idPtr.pointer, sinceSeq, scrollback);
    _freeAllocatedString(idPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  Map<String, dynamic> ptyClose(String id) {
    if (!isAvailable) return {'status': 'error', 'error': tr('FFI 不可用', 'FFI not available')};
    final idPtr = _toCString(id);
    final ptr = _ptyClose(_ctx!, idPtr.pointer);
    _freeAllocatedString(idPtr);
    return _parseJsonMap(_fromCString(ptr));
  }

  // ---------------------------------------------------------------------------
  // Phase 5: Streaming AI Chat, Message Persistence & Git Operations
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Context Engine & Memory (Phase 10)
  // ---------------------------------------------------------------------------

  // ---------------------------------------------------------------------------
  // Memory and Conversion Helpers
  // ---------------------------------------------------------------------------

  _AllocatedString _toCString(String str) {
    final bytes = utf8.encode(str);
    final ptr = _stringAlloc(bytes.length);
    final bytePtr = ptr.cast<Uint8>();
    for (int i = 0; i < bytes.length; i++) {
      bytePtr[i] = bytes[i];
    }
    bytePtr[bytes.length] = 0;
    return _AllocatedString(ptr, bytes.length);
  }

  void _freeAllocatedString(_AllocatedString str) {
    _bufferFree(str.pointer, str.length);
  }

  String _fromCString(Pointer<Char> ptr) {
    if (ptr.address == 0) return '';
    final units = <int>[];
    int i = 0;
    final bytePtr = ptr.cast<Uint8>();
    while (true) {
      final b = bytePtr[i];
      if (b == 0) break;
      units.add(b);
      i++;
    }
    _stringFree(ptr);
    return utf8.decode(units, allowMalformed: true);
  }

  Map<String, dynamic> _parseJsonMap(String jsonStr) {
    try {
      final decoded = jsonDecode(jsonStr);
      if (decoded is Map<String, dynamic>) return decoded;
    } catch (_) {}
    return {};
  }

  DynamicLibrary? _loadLibrary() {
    final path = codeliteLibraryPath();
    if (path != null) {
      try {
        return DynamicLibrary.open(path);
      } catch (_) {}
    }
    try {
      return Platform.isMacOS
          ? DynamicLibrary.open('libcodelite.dylib')
          : DynamicLibrary.process();
    } catch (_) {
      return null;
    }
  }
}

/// Rust 库文件的路径(第一个存在的候选);找不到返回 null。
/// 后台 isolate 要自己打开同一个库(比如全局搜索),用它保证和主 isolate 是同一份。
String? codeliteLibraryPath() {
  // 打包后的 .app:库在 Contents/Frameworks,可执行文件在 Contents/MacOS。
  final bundled = Platform.isMacOS
      ? '${File(Platform.resolvedExecutable).parent.parent.path}/Frameworks/libcodelite.dylib'
      : null;
  final candidates = [
    if (bundled != null) bundled,
    'target/debug/libcodelite.dylib',
    'target/release/libcodelite.dylib',
    '../../target/debug/libcodelite.dylib',
    '../../target/release/libcodelite.dylib',
    'libcodelite.dylib',
    '/Users/dev/rust/code-lite-x/target/debug/libcodelite.dylib',
    '/Users/dev/rust/code-lite-x/target/release/libcodelite.dylib',
    'target/debug/libcodelite.so',
    '../../target/debug/libcodelite.so',
    'codelite.dll',
  ];
  for (final path in candidates) {
    if (File(path).existsSync()) return File(path).absolute.path;
  }
  return null;
}

class _AllocatedString {
  final Pointer<Char> pointer;
  final int length;

  _AllocatedString(this.pointer, this.length);
}
