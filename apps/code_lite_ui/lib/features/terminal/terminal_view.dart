import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/client/api_client.dart';
import '../editor/context_menu_region.dart';
import 'terminal_selection.dart';
import '../../core/theme/intellij_theme.dart';
import 'terminal_store.dart';

/// IntelliJ 风格的终端工具窗:标题栏(Terminal | 会话标签 | +)加一块可直接输入的屏幕。
///
/// 屏幕本身就是输入面 —— 没有单独的命令输入框。按键编码成终端字节序列写进 PTY,
/// 由 shell 自己回显;画面来自 Rust 侧 vt100,这里只负责画格子。
class TerminalPanel extends StatelessWidget {
  const TerminalPanel({
    super.key,
    required this.store,
    required this.client,
    required this.onHide,
  });

  final TerminalStore store;
  final ApiClient client;

  /// 收起底部工具窗。关掉最后一个会话 / shell 退出时也走这里,与 IntelliJ 一致。
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final current = store.current;
        return Container(
          color: IntelliJTheme.editorBg,
          child: Column(
            children: [
              _TerminalHeader(store: store, onHide: onHide),
              Expanded(
                child: !store.isAvailable
                    ? const _Placeholder('终端需要 Rust Core(当前为离线预览)')
                    : current == null
                        ? _AutoOpen(store: store, error: store.error)
                        : TerminalView(
                            key: ValueKey(current.id),
                            sessionId: current.id,
                            client: client,
                            onExited: () {
                              store.close(current.id);
                              if (store.sessions.isEmpty) onHide();
                            },
                            onLost: () => store.forget(current.id),
                          ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _TerminalHeader extends StatelessWidget {
  const _TerminalHeader({required this.store, required this.onHide});

  final TerminalStore store;
  final VoidCallback onHide;

  @override
  Widget build(BuildContext context) {
    final sessions = store.sessions;
    // IntelliJ 新 UI:标题栏和内容同一块底色,没有分隔线;会话是一个个圆角标签
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 12, right: 6),
      color: IntelliJTheme.panelBg,
      child: Row(
        children: [
          const Text(
            'Terminal',
            style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600),
          ),
          const SizedBox(width: 16),
          // 会话标签和「+」占满中间,「—」贴右边(之前 Flexible + Spacer 平分空间,「—」跑到了中间)
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(
                  children: [
                    for (var i = 0; i < sessions.length; i++)
                      _SessionTab(
                        title: sessions[i].title,
                        isActive: i == store.activeIndex,
                        onTap: () => store.select(i),
                        onClose: () {
                          store.close(sessions[i].id);
                          if (store.sessions.isEmpty) onHide();
                        },
                      ),
                    _HeaderIcon(
                      icon: Icons.add,
                      tooltip: '新建会话',
                      // 尺寸由视图在下一次布局时修正,这里给个常见默认值即可。
                      onTap: store.isAvailable ? () => store.open(24, 100) : null,
                    ),
                  ],
                ),
              ),
            ),
          ),
          _HeaderIcon(icon: Icons.remove, tooltip: '隐藏', onTap: onHide),
        ],
      ),
    );
  }
}

class _SessionTab extends StatelessWidget {
  const _SessionTab({
    required this.title,
    required this.isActive,
    required this.onTap,
    required this.onClose,
  });

  final String title;
  final bool isActive;
  final VoidCallback onTap;
  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(right: 4),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(6),
        child: Container(
          height: 28,
          padding: const EdgeInsets.only(left: 10, right: 6),
          decoration: BoxDecoration(
            color: isActive ? IntelliJTheme.chipBg : null,
            borderRadius: BorderRadius.circular(6),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                title,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  color: isActive ? IntelliJTheme.textHigh : IntelliJTheme.textTab,
                  fontSize: 13,
                ),
              ),
              const SizedBox(width: 4),
              InkWell(
                onTap: onClose,
                borderRadius: BorderRadius.circular(3),
                child: const Padding(
                  padding: EdgeInsets.all(2),
                  child: Icon(Icons.close, size: 11, color: IntelliJTheme.textMuted),
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}

class _HeaderIcon extends StatelessWidget {
  const _HeaderIcon({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 15, color: onTap == null ? IntelliJTheme.textMuted : IntelliJTheme.textSecondary),
        ),
      ),
    );
  }
}

class _Placeholder extends StatelessWidget {
  const _Placeholder(this.message);

  final String message;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Text(message, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12)),
    );
  }
}

/// 没有会话时按可用区域大小开一个(打开终端工具窗即有 shell)。
class _AutoOpen extends StatefulWidget {
  const _AutoOpen({required this.store, required this.error});

  final TerminalStore store;
  final String? error;

  @override
  State<_AutoOpen> createState() => _AutoOpenState();
}

class _AutoOpenState extends State<_AutoOpen> {
  bool _tried = false;

  @override
  Widget build(BuildContext context) {
    if (widget.error != null) return _Placeholder('终端启动失败: ${widget.error}');
    return LayoutBuilder(
      builder: (context, constraints) {
        if (!_tried) {
          _tried = true;
          final metrics = _CellMetrics.of(context);
          final rows = math.max(2, (constraints.maxHeight - _kPad * 2) ~/ metrics.height);
          final cols = math.max(10, (constraints.maxWidth - _kPad * 2) ~/ metrics.width);
          // 不能在 build 里 notify:放到帧后。
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted) widget.store.open(rows, cols);
          });
        }
        return const SizedBox.expand();
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 屏幕
// ---------------------------------------------------------------------------

const double _kFontSize = 13;
const double _kLineHeight = 1.3;
const double _kPad = 8;
const String _kFont = 'Menlo';
const List<String> _kFontFallback = ['monospace', 'PingFang SC'];

class _CellMetrics {
  const _CellMetrics(this.width, this.height);

  final double width;
  final double height;

  static _CellMetrics? _cached;

  static _CellMetrics of(BuildContext context) {
    final cached = _cached;
    if (cached != null) return cached;
    final tp = TextPainter(
      text: const TextSpan(text: 'WWWWWWWWWW', style: _baseStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    return _cached = _CellMetrics(tp.width / 10, tp.height);
  }
}

const TextStyle _baseStyle = TextStyle(
  fontFamily: _kFont,
  fontFamilyFallback: _kFontFallback,
  fontSize: _kFontSize,
  height: _kLineHeight,
  color: IntelliJTheme.textPrimary,
);

class _Run {
  const _Run(this.col, this.text, this.fg, this.bg, this.attrs);

  final int col;
  final String text;
  final int fg;
  final int bg;
  final int attrs;

  static const bold = 1, italic = 2, underline = 4, inverse = 8, dim = 16;
}

class _Screen {
  const _Screen({
    required this.rows,
    required this.cursorRow,
    required this.cursorCol,
    required this.cursorVisible,
    required this.appCursor,
    required this.bracketedPaste,
    required this.altScreen,
    this.wrapped = const [],
    this.history = 0,
  });

  final List<List<_Run>> rows;

  /// 每行是不是自动折行折出来的(复制时接上下一行)。
  final List<bool> wrapped;

  /// 回滚缓冲里一共有多少行可翻;屏幕顶行的绝对行号 = history - 当前回滚偏移。
  final int history;
  final int cursorRow;
  final int cursorCol;
  final bool cursorVisible;
  final bool appCursor;
  final bool bracketedPaste;
  final bool altScreen;

  static const empty = _Screen(
    rows: [],
    cursorRow: 0,
    cursorCol: 0,
    cursorVisible: false,
    appCursor: false,
    bracketedPaste: false,
    altScreen: false,
  );

  factory _Screen.fromJson(Map<String, dynamic> json) {
    final rawRows = (json['rows'] as List?) ?? const [];
    final cursor = (json['cursor'] as List?) ?? const [0, 0];
    return _Screen(
      rows: [
        for (final row in rawRows)
          [
            for (final r in row as List)
              _Run(
                (r['c'] as num).toInt(),
                r['t'] as String,
                (r['fg'] as num).toInt(),
                (r['bg'] as num).toInt(),
                (r['a'] as num).toInt(),
              ),
          ],
      ],
      cursorRow: (cursor[0] as num).toInt(),
      cursorCol: (cursor[1] as num).toInt(),
      cursorVisible: json['cursor_visible'] == true,
      appCursor: json['app_cursor'] == true,
      bracketedPaste: json['bracketed_paste'] == true,
      altScreen: json['alt_screen'] == true,
      wrapped: [for (final w in (json['wrapped'] as List?) ?? const []) w == true],
      history: (json['history'] as num?)?.toInt() ?? 0,
    );
  }

  /// 第 [row] 行按单元格摊开([cols] 格,空格补齐,宽字符后半格是空串),复制 / 选词用。
  TermLine lineAt(int row, int cols) {
    final cells = List<String>.filled(cols, ' ');
    if (row >= 0 && row < rows.length) {
      for (final run in rows[row]) {
        var c = run.col;
        for (final rune in run.text.runes) {
          if (c >= cols) break;
          cells[c] = String.fromCharCode(rune);
          if (_isWide(rune) && c + 1 < cols) cells[c + 1] = '';
          c += _isWide(rune) ? 2 : 1;
        }
      }
    }
    return TermLine(cells, wrapped: row >= 0 && row < wrapped.length && wrapped[row]);
  }
}

class TerminalView extends StatefulWidget {
  /// 单元格大小与内边距(测试按格子算点击位置用)。
  @visibleForTesting
  static Size cellSizeOf(BuildContext context) {
    final m = _CellMetrics.of(context);
    return Size(m.width, m.height);
  }

  @visibleForTesting
  static const double padding = _kPad;

  const TerminalView({
    super.key,
    required this.sessionId,
    required this.client,
    required this.onExited,
    required this.onLost,
  });

  final String sessionId;
  final ApiClient client;

  /// shell 正常退出(用户输入 exit / Ctrl+D)。
  final VoidCallback onExited;

  /// Rust 侧已没有这个会话(项目切换重建了上下文)。
  final VoidCallback onLost;

  @override
  State<TerminalView> createState() => _TerminalViewState();
}

class _TerminalViewState extends State<TerminalView> implements TextInputClient {
  static const _pollInterval = Duration(milliseconds: 33);

  final FocusNode _focus = FocusNode(debugLabel: 'terminal');
  Timer? _timer;
  Timer? _kick;
  _Screen _screen = _Screen.empty;
  int _seq = -1;
  int _scrollback = 0;
  int _rows = 0;
  int _cols = 0;
  bool _ended = false;

  TextInputConnection? _ime;
  TextEditingValue _imeValue = TextEditingValue.empty;

  bool get _composing => _imeValue.composing.isValid && !_imeValue.composing.isCollapsed;

  @override
  void initState() {
    super.initState();
    _focus.addListener(_onFocusChange);
    _poll();
    _timer = Timer.periodic(_pollInterval, (_) => _poll());
  }

  @override
  void dispose() {
    _timer?.cancel();
    _kick?.cancel();
    _closeIme();
    _focus
      ..removeListener(_onFocusChange)
      ..dispose();
    super.dispose();
  }

  void _poll() {
    if (!mounted || _ended) return;
    final res = widget.client.ptySnapshot(widget.sessionId, sinceSeq: _seq, scrollback: _scrollback);
    if (res['status'] != 'ok') {
      _ended = true;
      widget.onLost();
      return;
    }
    if (res['alive'] == false) {
      _ended = true;
      widget.onExited();
      return;
    }
    if (res['unchanged'] == true) return;
    setState(() {
      _seq = (res['seq'] as num).toInt();
      _scrollback = (res['scrollback'] as num?)?.toInt() ?? 0;
      _screen = _Screen.fromJson(res);
    });
    _updateImeGeometry();
  }

  /// 视图尺寸变了就同步给 PTY,shell 和全屏程序(vim/top)会按新尺寸重排。
  void _syncSize(int rows, int cols) {
    if (rows == _rows && cols == _cols) return;
    _rows = rows;
    _cols = cols;
    widget.client.ptyResize(widget.sessionId, rows, cols);
    _seq = -1;
  }

  void _send(String data) {
    if (data.isEmpty) return;
    widget.client.ptyWrite(widget.sessionId, data);
    if (_sel != null) setState(() => _sel = null); // 打字就取消选区
    if (_scrollback != 0) {
      _scrollback = 0;
      _seq = -1;
    }
    // 回显来自 shell;稍等一下立刻拉一次,别等下一个轮询周期。
    _kick?.cancel();
    _kick = Timer(const Duration(milliseconds: 8), _poll);
  }

  // --- 键盘 -------------------------------------------------------------------

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final keys = HardwareKeyboard.instance;
    final key = event.logicalKey;

    // 输入法组字中:回车/退格/方向键都归输入法。
    if (_composing) return KeyEventResult.ignored;

    // 复制选中的输出:⌘C(其它平台 Ctrl+Shift+C)。没有选区时 ⌘C 不管,Ctrl+C 照常是中断。
    final copyChord = key == LogicalKeyboardKey.keyC &&
        (keys.isMetaPressed || (keys.isControlPressed && keys.isShiftPressed));
    if (copyChord && _hasSelection) {
      _copy();
      return KeyEventResult.handled;
    }

    if (keys.isMetaPressed) {
      if (key == LogicalKeyboardKey.keyA) {
        _selectAll();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyV) {
        _paste();
        return KeyEventResult.handled;
      }
      if (key == LogicalKeyboardKey.keyK) {
        _send('\x0c'); // ⌘K:清屏(IntelliJ 同款),交给 shell 处理成 clear
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored; // 其余 ⌘ 组合留给应用快捷键
    }

    final special = _encodeSpecial(key, shift: keys.isShiftPressed, alt: keys.isAltPressed);
    if (special != null) {
      _send(special);
      return KeyEventResult.handled;
    }

    if (keys.isControlPressed) {
      final ctrl = _encodeCtrl(key);
      if (ctrl != null) {
        _send(ctrl);
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

    // 可打印字符:接上输入法时交给它(这样中文、日文都能输入),
    // 没有输入法连接时(测试 / 无 IME 平台)直接发。
    if (_ime?.attached ?? false) return KeyEventResult.ignored;
    final ch = event.character;
    if (ch != null && ch.isNotEmpty && ch.codeUnitAt(0) >= 0x20 && ch.codeUnitAt(0) != 0x7f) {
      _send(ch);
      return KeyEventResult.handled;
    }
    return KeyEventResult.ignored;
  }

  String? _encodeSpecial(LogicalKeyboardKey key, {required bool shift, required bool alt}) {
    final app = _screen.appCursor;
    String arrow(String c) => app ? '\x1bO$c' : '\x1b[$c';
    if (key == LogicalKeyboardKey.enter || key == LogicalKeyboardKey.numpadEnter) return '\r';
    if (key == LogicalKeyboardKey.backspace) return alt ? '\x17' : '\x7f'; // ⌥⌫ 删一个词
    if (key == LogicalKeyboardKey.tab) return shift ? '\x1b[Z' : '\t';
    if (key == LogicalKeyboardKey.escape) return '\x1b';
    if (key == LogicalKeyboardKey.arrowUp) return arrow('A');
    if (key == LogicalKeyboardKey.arrowDown) return arrow('B');
    if (key == LogicalKeyboardKey.arrowRight) return alt ? '\x1bf' : arrow('C'); // ⌥→ 下一个词
    if (key == LogicalKeyboardKey.arrowLeft) return alt ? '\x1bb' : arrow('D'); // ⌥← 上一个词
    if (key == LogicalKeyboardKey.home) return arrow('H');
    if (key == LogicalKeyboardKey.end) return arrow('F');
    if (key == LogicalKeyboardKey.delete) return '\x1b[3~';
    if (key == LogicalKeyboardKey.pageUp) return '\x1b[5~';
    if (key == LogicalKeyboardKey.pageDown) return '\x1b[6~';
    return null;
  }

  /// Ctrl+字母 → 0x01..0x1a(Ctrl+C 中断、Ctrl+D EOF、Ctrl+R 搜历史……)。
  String? _encodeCtrl(LogicalKeyboardKey key) {
    final label = key.keyLabel;
    if (label.length != 1) return null;
    final c = label.toUpperCase().codeUnitAt(0);
    if (c >= 0x41 && c <= 0x5a) return String.fromCharCode(c - 0x40);
    if (label == '[') return '\x1b';
    if (label == '\\') return '\x1c';
    if (label == ']') return '\x1d';
    return null;
  }

  Future<void> _paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty || !mounted) return;
    // 终端里换行是 \r;开了 bracketed paste 的 shell 会把整段当作一次粘贴而不是逐行执行。
    final normalized = text.replaceAll('\r\n', '\r').replaceAll('\n', '\r');
    _send(_screen.bracketedPaste ? '\x1b[200~$normalized\x1b[201~' : normalized);
  }

  // --- 输入法 -----------------------------------------------------------------

  void _onFocusChange() {
    if (_focus.hasFocus) {
      _openIme();
    } else {
      _closeIme();
    }
    setState(() {});
  }

  void _openIme() {
    if (_ime?.attached ?? false) return;
    _imeValue = TextEditingValue.empty;
    _ime = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputType: TextInputType.text,
        autocorrect: false,
        enableSuggestions: false,
        enableIMEPersonalizedLearning: false,
        keyboardAppearance: Brightness.dark,
      ),
    )
      ..setEditingState(_imeValue)
      ..show();
    _updateImeGeometry();
  }

  void _closeIme() {
    _ime?.close();
    _ime = null;
    _imeValue = TextEditingValue.empty;
  }

  /// 让输入法候选框贴着光标出现。
  void _updateImeGeometry() {
    final ime = _ime;
    if (ime == null || !ime.attached) return;
    final box = context.findRenderObject() as RenderBox?;
    if (box == null || !box.hasSize) return;
    final m = _CellMetrics.of(context);
    ime.setEditableSizeAndTransform(box.size, box.getTransformTo(null));
    final caret = Rect.fromLTWH(
      _kPad + _screen.cursorCol * m.width,
      _kPad + _screen.cursorRow * m.height,
      m.width,
      m.height,
    );
    ime.setComposingRect(caret);
    ime.setCaretRect(caret);
  }

  @override
  TextEditingValue? get currentTextEditingValue => _imeValue;

  @override
  void updateEditingValue(TextEditingValue value) {
    if (value.composing.isValid && !value.composing.isCollapsed) {
      // 还在组字:只显示,不发给 shell。
      setState(() => _imeValue = value);
      return;
    }
    // 上屏:把整段文本发出去,然后清空,下一次输入从空开始。
    final committed = value.text;
    setState(() => _imeValue = TextEditingValue.empty);
    _ime?.setEditingState(TextEditingValue.empty);
    if (committed.isNotEmpty) _send(committed.replaceAll('\n', '\r'));
  }

  @override
  void performAction(TextInputAction action) {}

  @override
  void performSelector(String selectorName) {
    // macOS 把未被按键处理器消费的编辑命令发到这里;终端里不需要。
  }

  @override
  void connectionClosed() {
    _ime = null;
    _imeValue = TextEditingValue.empty;
  }

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  /// Flutter 3.4x 新增:浏览器自动填充时平台把焦点交还输入框。桌面端不会调用,沿用默认实现。
  @override
  bool onFocusReceived() => false;

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void showToolbar() {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  void didChangeInputControl(TextInputControl? oldControl, TextInputControl? newControl) {}

  // --- 选区与复制 ------------------------------------------------------------------

  TermSelection? _sel;

  /// 按下后鼠标挪到别的格子才算开始选;只是点一下不选。
  bool _dragging = false;
  bool _pressed = false;
  Duration? _lastDown;
  Offset _lastDownAt = Offset.zero;
  int _clicks = 0;

  bool get _hasSelection => _sel != null;

  /// 屏幕顶行的绝对行号(0 = 回滚缓冲里最早的一行)。
  int get _topLine => _screen.history - _scrollback;

  int get _viewCols => _cols > 0 ? _cols : 80;

  TermPos _posAt(Offset local) {
    final m = _CellMetrics.of(context);
    final rows = math.max(1, _screen.rows.length);
    final row = ((local.dy - _kPad) / m.height).floor().clamp(0, rows - 1);
    final col = ((local.dx - _kPad) / m.width).floor().clamp(0, _viewCols - 1);
    return TermPos(_topLine + row, col);
  }

  void _onPointerDown(PointerDownEvent e) {
    if (e.buttons != kPrimaryButton) return;
    _focus.requestFocus();
    // 用事件自己的时间戳判断连击(和手势识别器一样)
    final last = _lastDown;
    final again = last != null && e.timeStamp - last < const Duration(milliseconds: 400) && (e.localPosition - _lastDownAt).distance < 6;
    _clicks = again ? (_clicks % 3) + 1 : 1;
    _lastDown = e.timeStamp;
    _lastDownAt = e.localPosition;
    _pressed = true;
    _dragging = false;
    final p = _posAt(e.localPosition);
    final line = _screen.lineAt(p.line - _topLine, _viewCols);
    setState(() {
      switch (_clicks) {
        case 2: // 双击:选词
          final (a, b) = wordRange(line.cells, p.col);
          _sel = TermSelection(TermPos(p.line, a), TermPos(p.line, b));
        case 3: // 三击:选整行
          _sel = TermSelection(TermPos(p.line, 0), TermPos(p.line, _viewCols - 1));
        default:
          _sel = null; // 单击:取消选区,等拖动再选
          _anchor = p;
      }
    });
  }

  TermPos? _anchor;

  void _onPointerMove(PointerMoveEvent e) {
    if (!_pressed || _clicks != 1 || e.buttons != kPrimaryButton) return;
    final anchor = _anchor;
    if (anchor == null) return;
    // 拖到上 / 下边缘外面:跟着翻(选长输出时)
    final m = _CellMetrics.of(context);
    final height = context.size?.height ?? 0;
    if (e.localPosition.dy < _kPad) _scrollBy(-m.height);
    if (height > 0 && e.localPosition.dy > height - _kPad) _scrollBy(m.height);
    final p = _posAt(e.localPosition);
    if (!_dragging && p == anchor) return;
    _dragging = true;
    setState(() => _sel = TermSelection(anchor, p));
  }

  void _onPointerUp(PointerUpEvent e) => _pressed = false;

  void _selectAll() {
    final int last = _topLine + math.max<int>(0, _screen.rows.length - 1);
    setState(() => _sel = TermSelection(const TermPos(0, 0), TermPos(last, _viewCols - 1)));
  }

  /// 选中的文字。看不到的那部分(选区比一屏长、或者翻走了)按页向 PTY 取回来。
  String _selectedText() {
    final sel = _sel;
    if (sel == null) return '';
    final cols = _viewCols;
    final lines = <int, TermLine>{};
    void take(_Screen screen, int top) {
      for (var r = 0; r < screen.rows.length; r++) {
        lines[top + r] = screen.lineAt(r, cols);
      }
    }

    take(_screen, _topLine);
    TermLine? lineAt(int line) {
      if (lines.containsKey(line)) return lines[line];
      // 让这一行出现在屏幕顶上再读一页
      final res = widget.client.ptySnapshot(widget.sessionId, scrollback: math.max(0, _screen.history - line));
      if (res['status'] != 'ok' || res['unchanged'] == true) return null;
      final page = _Screen.fromJson(res);
      take(page, page.history - ((res['scrollback'] as num?)?.toInt() ?? 0));
      return lines[line];
    }

    return selectionText(sel, lineAt, cols);
  }

  void _copy() {
    final text = _selectedText();
    if (text.isEmpty) return;
    Clipboard.setData(ClipboardData(text: text));
  }

  // --- 滚动:翻回滚缓冲(鼠标滚轮 + 触控板) -----------------------------------------

  /// 还不够一行的滚动量(像素)。触控板一次只滚几个像素,不攒起来的话每次都四舍五入成 0,怎么滚都不动。
  double _scrollRemainder = 0;

  /// 鼠标滚轮。
  void _onPointerSignal(PointerSignalEvent event) {
    if (event is PointerScrollEvent) _scrollBy(event.scrollDelta.dy);
  }

  /// macOS 触控板的双指滚动不是滚轮事件,是 pan/zoom 手势:手指往下 = 往上翻(看更早的输出)。
  void _onPanZoomUpdate(PointerPanZoomUpdateEvent event) => _scrollBy(-event.localPanDelta.dy);

  /// [dy] 像素,正数往下(往新的输出走),负数往上翻历史。
  void _scrollBy(double dy) {
    // 全屏程序(vim/less)自己管滚动,备用屏没有回滚缓冲。
    if (_screen.altScreen) return;
    final m = _CellMetrics.of(context);
    _scrollRemainder += dy;
    final lines = _scrollRemainder ~/ m.height;
    if (lines == 0) return;
    _scrollRemainder -= lines * m.height;
    final next = math.max<int>(0, _scrollback - lines);
    if (next == _scrollback) {
      _scrollRemainder = 0; // 到底了 / 到顶了:不要攒着,反方向一滚就要动
      return;
    }
    _scrollback = next;
    _seq = -1;
    _poll();
    // 翻过头时 vt100 会夹到最早一行:按实际偏移校正,往回滚才不会先空转
    if (_scrollback < next) _scrollRemainder = 0;
  }

  @override
  Widget build(BuildContext context) {
    final m = _CellMetrics.of(context);
    return LayoutBuilder(
      builder: (context, constraints) {
        final rows = math.max(2, (constraints.maxHeight - _kPad * 2) ~/ m.height);
        final cols = math.max(10, (constraints.maxWidth - _kPad * 2) ~/ m.width);
        _syncSize(rows, cols);
        final menu = ContextMenuRegion(
          menuBuilder: (_) => [
            MenuItemButton(onPressed: _hasSelection ? _copy : null, child: const Text('复制')),
            MenuItemButton(onPressed: _paste, child: const Text('粘贴')),
            MenuItemButton(onPressed: _selectAll, child: const Text('全选')),
          ],
          child: GestureDetector(
            behavior: HitTestBehavior.opaque,
            onTap: _focus.requestFocus,
            child: Focus(
              focusNode: _focus,
              autofocus: true,
              onKeyEvent: _onKey,
              child: MouseRegion(
                cursor: SystemMouseCursors.text,
                child: CustomPaint(
                  size: Size.infinite,
                  painter: _TerminalPainter(
                    screen: _screen,
                    metrics: m,
                    focused: _focus.hasFocus,
                    composing: _composing ? _imeValue.text : null,
                    selection: _sel,
                    topLine: _topLine,
                    cols: cols,
                  ),
                ),
              ),
            ),
          ),
        );
        return Listener(
          onPointerSignal: _onPointerSignal,
          onPointerPanZoomUpdate: _onPanZoomUpdate,
          onPointerDown: _onPointerDown,
          onPointerMove: _onPointerMove,
          onPointerUp: _onPointerUp,
          child: menu,
        );
      },
    );
  }
}

class _TerminalPainter extends CustomPainter {
  _TerminalPainter({
    required this.screen,
    required this.metrics,
    required this.focused,
    required this.composing,
    this.selection,
    this.topLine = 0,
    this.cols = 0,
  });

  final _Screen screen;
  final _CellMetrics metrics;
  final bool focused;
  final String? composing;

  /// 选区(绝对行号);[topLine] 是屏幕顶行的绝对行号。
  final TermSelection? selection;
  final int topLine;
  final int cols;

  static const Color selectionColor = Color(0x664A88E8);

  @override
  void paint(Canvas canvas, Size size) {
    final cw = metrics.width;
    final ch = metrics.height;
    final bgPaint = Paint();

    for (var r = 0; r < screen.rows.length; r++) {
      final y = _kPad + r * ch;
      // 选区底色画在文字下面
      final selected = selection?.colsOn(topLine + r, cols);
      if (selected != null) {
        final (c0, c1) = selected;
        canvas.drawRect(Rect.fromLTWH(_kPad + c0 * cw, y, (c1 - c0 + 1) * cw, ch), Paint()..color = selectionColor);
      }
      for (final run in screen.rows[r]) {
        final inverse = run.attrs & _Run.inverse != 0;
        var fg = _color(run.fg, foreground: true);
        var bg = run.bg == -1 ? null : _color(run.bg, foreground: false);
        if (inverse) {
          final oldFg = fg;
          fg = bg ?? IntelliJTheme.editorBg;
          bg = oldFg;
        }
        final x = _kPad + run.col * cw;
        final cells = _cellWidth(run.text);
        if (bg != null) {
          canvas.drawRect(Rect.fromLTWH(x, y, cells * cw, ch), bgPaint..color = bg);
        }
        if (run.text.trim().isEmpty) continue;
        if (run.attrs & _Run.bold != 0 && run.fg >= 0 && run.fg < 8) {
          fg = _color(run.fg + 8, foreground: true); // 经典终端行为:粗体用亮色
        }
        if (run.attrs & _Run.dim != 0) fg = fg.withValues(alpha: 0.6);
        final tp = TextPainter(
          text: TextSpan(
            text: run.text,
            style: _baseStyle.copyWith(
              color: fg,
              fontWeight: run.attrs & _Run.bold != 0 ? FontWeight.bold : FontWeight.normal,
              fontStyle: run.attrs & _Run.italic != 0 ? FontStyle.italic : FontStyle.normal,
              decoration: run.attrs & _Run.underline != 0 ? TextDecoration.underline : null,
              decorationColor: fg,
            ),
          ),
          textDirection: TextDirection.ltr,
          maxLines: 1,
        )..layout();
        canvas.save();
        canvas.clipRect(Rect.fromLTWH(x, y, cells * cw, ch));
        tp.paint(canvas, Offset(x, y));
        canvas.restore();
      }
    }

    final cx = _kPad + screen.cursorCol * cw;
    final cy = _kPad + screen.cursorRow * ch;

    // 输入法组字中的文本:贴在光标处,下划线标出,尚未发给 shell。
    final comp = composing;
    if (comp != null && comp.isNotEmpty) {
      final tp = TextPainter(
        text: TextSpan(
          text: comp,
          style: _baseStyle.copyWith(
            color: IntelliJTheme.textHigh,
            backgroundColor: IntelliJTheme.editorBg,
            decoration: TextDecoration.underline,
            decorationColor: IntelliJTheme.accentBlue,
          ),
        ),
        textDirection: TextDirection.ltr,
      )..layout();
      tp.paint(canvas, Offset(cx, cy));
      return;
    }

    if (!screen.cursorVisible) return;
    final cursorRect = Rect.fromLTWH(cx, cy, cw, ch);
    if (focused) {
      canvas.drawRect(cursorRect, Paint()..color = IntelliJTheme.textPrimary.withValues(alpha: 0.85));
      final under = _charAt(screen.cursorRow, screen.cursorCol);
      if (under != null && under.trim().isNotEmpty) {
        final tp = TextPainter(
          text: TextSpan(text: under, style: _baseStyle.copyWith(color: IntelliJTheme.editorBg)),
          textDirection: TextDirection.ltr,
        )..layout();
        tp.paint(canvas, Offset(cx, cy));
      }
    } else {
      canvas.drawRect(
        cursorRect.deflate(0.5),
        Paint()
          ..color = IntelliJTheme.textMuted
          ..style = PaintingStyle.stroke,
      );
    }
  }

  String? _charAt(int row, int col) {
    if (row >= screen.rows.length) return null;
    for (final run in screen.rows[row]) {
      final len = run.text.runes.length;
      if (col >= run.col && col < run.col + len) {
        return String.fromCharCode(run.text.runes.elementAt(col - run.col));
      }
    }
    return null;
  }

  @override
  bool shouldRepaint(_TerminalPainter old) =>
      old.screen != screen ||
      old.focused != focused ||
      old.composing != composing ||
      old.selection != selection ||
      old.topLine != topLine ||
      old.cols != cols;
}

/// 一个 run 占几列。Rust 侧保证宽字符(中日韩)单独成 run,所以这里只需区分两种情况。
int _cellWidth(String text) {
  final runes = text.runes;
  if (runes.length == 1 && _isWide(runes.first)) return 2;
  return runes.length;
}

bool _isWide(int cp) =>
    (cp >= 0x1100 && cp <= 0x115f) ||
    (cp >= 0x2e80 && cp <= 0xa4cf) ||
    (cp >= 0xac00 && cp <= 0xd7a3) ||
    (cp >= 0xf900 && cp <= 0xfaff) ||
    (cp >= 0xfe30 && cp <= 0xfe4f) ||
    (cp >= 0xff00 && cp <= 0xff60) ||
    (cp >= 0xffe0 && cp <= 0xffe6) ||
    (cp >= 0x1f300 && cp <= 0x1faff) ||
    (cp >= 0x20000 && cp <= 0x3fffd);

/// Darcula 配色的 16 色,加 xterm 的 6×6×6 色立方和 24 级灰。
const List<Color> _ansi16 = [
  Color(0xFF000000), Color(0xFFF0524F), Color(0xFF5C962C), Color(0xFFA68A0D),
  Color(0xFF3993D4), Color(0xFFA771BF), Color(0xFF00A3A3), Color(0xFF808080),
  Color(0xFF595959), Color(0xFFFF4050), Color(0xFF4FC414), Color(0xFFE5BF00),
  Color(0xFF1FB0FF), Color(0xFFED7EED), Color(0xFF00E5E5), Color(0xFFFFFFFF),
];

Color _color(int code, {required bool foreground}) {
  if (code < 0) return foreground ? IntelliJTheme.textPrimary : IntelliJTheme.editorBg;
  if (code >= 0x1000000) return Color(0xFF000000 | (code & 0xFFFFFF));
  if (code < 16) return _ansi16[code];
  if (code < 232) {
    final i = code - 16;
    int level(int v) => v == 0 ? 0 : 55 + v * 40;
    return Color.fromARGB(255, level(i ~/ 36), level((i ~/ 6) % 6), level(i % 6));
  }
  final g = 8 + (code - 232) * 10;
  return Color.fromARGB(255, g, g, g);
}
