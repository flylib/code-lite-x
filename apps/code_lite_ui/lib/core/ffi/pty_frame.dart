import 'dart:convert';
import 'dart:typed_data';

/// 终端画面里同样式的一段文字(Rust `Run`)。宽字符(中日韩)单独成一段并占两列。
class PtyRun {
  const PtyRun(this.col, this.text, this.fg, this.bg, this.attrs);

  final int col;
  final String text;

  /// 颜色:-1 默认,0..255 调色板,0x1000000 | rgb 真彩色。
  final int fg;
  final int bg;
  final int attrs;

  static const bold = 1, italic = 2, underline = 4, inverse = 8, dim = 16;
}

/// 一行:是否自动折行(复制时接下一行)和它的各段文字。
class PtyRow {
  const PtyRow(this.wrapped, this.runs);

  final bool wrapped;
  final List<PtyRun> runs;
}

/// 一帧终端画面(Rust `encode_frame` 的二进制格式,见 crates/code-lite-terminal)。
///
/// 只带和上一帧不同的行([changed]);[full] 为真时带的是整屏。[unchanged] 时除 [seq]、[alive] 外都没有意义。
class PtyFrame {
  const PtyFrame({
    required this.lost,
    required this.unchanged,
    required this.full,
    required this.alive,
    required this.seq,
    this.rows = 0,
    this.cols = 0,
    this.cursorRow = 0,
    this.cursorCol = 0,
    this.cursorVisible = false,
    this.appCursor = false,
    this.bracketedPaste = false,
    this.altScreen = false,
    this.scrollback = 0,
    this.history = 0,
    this.changed = const {},
  });

  /// 会话没了(Rust 侧找不到它,比如项目切换重建了上下文)。
  final bool lost;
  final bool unchanged;
  final bool full;
  final bool alive;
  final int seq;
  final int rows;
  final int cols;
  final int cursorRow;
  final int cursorCol;
  final bool cursorVisible;
  final bool appCursor;
  final bool bracketedPaste;
  final bool altScreen;

  /// 向上翻的行数(0 = 跟随底部)与回滚缓冲里一共可翻多少行。
  final int scrollback;
  final int history;

  /// 这一帧带的行:行号 → 内容。
  final Map<int, PtyRow> changed;

  static const PtyFrame lostFrame = PtyFrame(lost: true, unchanged: false, full: false, alive: false, seq: -1);

  static const int version = 1;
  static const int _unchanged = 1, _full = 2, _alive = 4, _cursor = 8, _appCursor = 16, _paste = 32, _alt = 64;

  /// 解码 Rust 的二进制帧(小端)。格式不认识时当成会话丢了,界面会重新打开。
  static PtyFrame decode(Uint8List bytes) {
    if (bytes.length < 28 || bytes[0] != version) return lostFrame;
    final d = ByteData.sublistView(bytes);
    final flags = bytes[1];
    final seq = d.getUint64(2, Endian.little);
    final alive = flags & _alive != 0;
    if (flags & _unchanged != 0) return PtyFrame(lost: false, unchanged: true, full: false, alive: alive, seq: seq);
    final n = d.getUint16(26, Endian.little);
    final changed = <int, PtyRow>{};
    var o = 28;
    for (var i = 0; i < n; i++) {
      final index = d.getUint16(o, Endian.little);
      final wrapped = bytes[o + 2] != 0;
      final nRuns = d.getUint16(o + 3, Endian.little);
      o += 5;
      final runs = <PtyRun>[];
      for (var r = 0; r < nRuns; r++) {
        final col = d.getUint16(o, Endian.little);
        final fg = d.getInt32(o + 2, Endian.little);
        final bg = d.getInt32(o + 6, Endian.little);
        final attrs = bytes[o + 10];
        final len = d.getUint16(o + 11, Endian.little);
        final text = _ascii(bytes, o + 13, len) ?? utf8.decode(Uint8List.sublistView(bytes, o + 13, o + 13 + len));
        runs.add(PtyRun(col, text, fg, bg, attrs));
        o += 13 + len;
      }
      changed[index] = PtyRow(wrapped, runs);
    }
    return PtyFrame(
      lost: false,
      unchanged: false,
      full: flags & _full != 0,
      alive: alive,
      seq: seq,
      rows: d.getUint16(10, Endian.little),
      cols: d.getUint16(12, Endian.little),
      cursorRow: d.getUint16(14, Endian.little),
      cursorCol: d.getUint16(16, Endian.little),
      cursorVisible: flags & _cursor != 0,
      appCursor: flags & _appCursor != 0,
      bracketedPaste: flags & _paste != 0,
      altScreen: flags & _alt != 0,
      scrollback: d.getUint32(18, Endian.little),
      history: d.getUint32(22, Endian.little),
      changed: changed,
    );
  }

  /// 纯 ASCII 的文字直接转,省掉 UTF-8 解码(终端输出绝大多数是 ASCII)。
  static String? _ascii(Uint8List b, int start, int len) {
    for (var i = start; i < start + len; i++) {
      if (b[i] >= 0x80) return null;
    }
    return String.fromCharCodes(b, start, start + len);
  }

  /// 旧的 JSON 整屏快照转成一帧(整屏)。Rust 库太旧、没有二进制帧时用;测试里的假终端也用它。
  static PtyFrame fromSnapshot(Map<String, dynamic> json) {
    if (json['status'] != 'ok') return lostFrame;
    final seq = (json['seq'] as num?)?.toInt() ?? 0;
    final alive = json['alive'] != false;
    if (json['unchanged'] == true) return PtyFrame(lost: false, unchanged: true, full: false, alive: alive, seq: seq);
    final rawRows = (json['rows'] as List?) ?? const [];
    final wrapped = (json['wrapped'] as List?) ?? const [];
    final size = (json['size'] as List?) ?? [rawRows.length, 0];
    final cursor = (json['cursor'] as List?) ?? const [0, 0];
    return PtyFrame(
      lost: false,
      unchanged: false,
      full: true,
      alive: alive,
      seq: seq,
      rows: (size[0] as num).toInt(),
      cols: (size[1] as num).toInt(),
      cursorRow: (cursor[0] as num).toInt(),
      cursorCol: (cursor[1] as num).toInt(),
      cursorVisible: json['cursor_visible'] == true,
      appCursor: json['app_cursor'] == true,
      bracketedPaste: json['bracketed_paste'] == true,
      altScreen: json['alt_screen'] == true,
      scrollback: (json['scrollback'] as num?)?.toInt() ?? 0,
      history: (json['history'] as num?)?.toInt() ?? 0,
      changed: {
        for (var i = 0; i < rawRows.length; i++)
          i: PtyRow(
            i < wrapped.length && wrapped[i] == true,
            [
              for (final r in rawRows[i] as List)
                PtyRun((r['c'] as num).toInt(), r['t'] as String, (r['fg'] as num).toInt(), (r['bg'] as num).toInt(), (r['a'] as num).toInt()),
            ],
          ),
      },
    );
  }
}
