import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'folding.dart';

/// Represents a line and column coordinate in the editor (0-indexed).
@immutable
class EditorPosition implements Comparable<EditorPosition> {
  final int line;
  final int col;

  const EditorPosition(this.line, this.col);

  static const zero = EditorPosition(0, 0);

  @override
  int compareTo(EditorPosition other) {
    if (line != other.line) return line.compareTo(other.line);
    return col.compareTo(other.col);
  }

  bool operator <(EditorPosition other) => compareTo(other) < 0;
  bool operator <=(EditorPosition other) => compareTo(other) <= 0;
  bool operator >(EditorPosition other) => compareTo(other) > 0;
  bool operator >=(EditorPosition other) => compareTo(other) >= 0;

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EditorPosition && runtimeType == other.runtimeType && line == other.line && col == other.col;

  @override
  int get hashCode => Object.hash(line, col);

  @override
  String toString() => 'EditorPosition($line, $col)';
}

/// Represents a text selection with an anchor and moving head (caret).
@immutable
class EditorSelection {
  final EditorPosition anchor;
  final EditorPosition head;

  const EditorSelection({required this.anchor, required this.head});

  const EditorSelection.collapsed(EditorPosition position)
      : anchor = position,
        head = position;

  bool get isCollapsed => anchor == head;

  EditorPosition get start => anchor <= head ? anchor : head;
  EditorPosition get end => anchor <= head ? head : anchor;

  bool containsLine(int line) {
    if (isCollapsed) return false;
    return line >= start.line && line <= end.line;
  }

  @override
  bool operator ==(Object other) =>
      identical(this, other) ||
      other is EditorSelection && runtimeType == other.runtimeType && anchor == other.anchor && head == other.head;

  @override
  int get hashCode => Object.hash(anchor, head);

  @override
  String toString() => 'EditorSelection(anchor: $anchor, head: $head)';
}

enum NavigationDirection { up, down, left, right }

/// 一次文本改动:改动前文档里 [start]..[end] 被换成了 [text]。[reset] 为 true 表示整篇重新载入
/// ([setText]),此时没有具体范围。依次应用这些改动即可从旧文档得到新文档(LSP 增量同步用)。
@immutable
class EditorTextChange {
  const EditorTextChange(this.start, this.end, this.text) : reset = false;

  const EditorTextChange.reset()
      : start = EditorPosition.zero,
        end = EditorPosition.zero,
        text = '',
        reset = true;

  final EditorPosition start;
  final EditorPosition end;
  final String text;
  final bool reset;
}

/// State controller managing text buffer, caret position, selection,
/// and rich keyboard editing actions for CodeLiteX editor.
class CodeEditorController extends ChangeNotifier {
  // ---------------------------------------------------------------------------
  // 文本模型:以「行」为准。每次编辑只替换受影响的几行([_edit]),
  // 全文按需拼接并缓存([text]);改一个字不再重写整个文件、重新切行、整份比对。
  // ---------------------------------------------------------------------------

  List<String> _lines = [''];

  /// [_lines] 拼成的全文;编辑后作废,下次读 [text] 时再拼。
  String? _textCache;

  /// 全文长度(UTF-16,含换行),随编辑增量维护。
  int _length = 0;

  /// 文本版本号:每次改动加一。视图层据此判断缓存是否还有效,不必比较全文。
  int _version = 0;

  /// [lines] 的快照:同一版本内是同一个对象(高亮缓存靠 identical 快速判断没变)。
  List<String>? _linesSnapshot;

  EditorSelection _selection = const EditorSelection.collapsed(EditorPosition.zero);
  int? _preferredCol;

  /// 代码折叠(哪些段收起了、可见行和文档行的换算)。光标落进收起的段时自动展开。
  final FoldState folds = FoldState();

  bool _isDirty = false;
  bool _canUndo = false;
  bool _canRedo = false;

  Timer? _blinkTimer;

  /// 光标闪烁的显隐。单独一个通知源:只有光标那一小块订阅它,
  /// 闪烁(每 500ms)不再触发整个编辑区重建。
  final ValueNotifier<bool> caretBlink = ValueNotifier(true);

  // IME composing range(相对于 IME 当前窗口文本,见 ImeTextInputBridge)
  TextRange _composingRange = TextRange.empty;

  /// 会话层(LSP didChange、自动保存)用的回调。视图层不要覆盖它,改用 [addTextListener]。
  /// 不带参数:需要全文时再读 [text](通常在防抖之后),避免每次按键都拼一次全文。
  VoidCallback? onTextChanged;
  final List<VoidCallback> _textListeners = [];

  /// 额外的文本变化监听。此前视图层直接赋值 [onTextChanged],把会话层的回调顶掉了,
  /// 编辑内容因此没同步给 Rust(保存会写回旧内容),LSP 也收不到 didChange。
  void addTextListener(VoidCallback listener) => _textListeners.add(listener);

  void removeTextListener(VoidCallback listener) => _textListeners.remove(listener);

  final List<void Function(EditorTextChange change)> _changeListeners = [];

  /// 逐次改动的监听(带范围)。比 [addTextListener] 先收到通知。
  void addChangeListener(void Function(EditorTextChange change) listener) => _changeListeners.add(listener);

  void removeChangeListener(void Function(EditorTextChange change) listener) => _changeListeners.remove(listener);

  void _emitChange(EditorTextChange change) {
    for (final l in List.of(_changeListeners)) {
      l(change);
    }
  }

  void _emitTextChanged() {
    onTextChanged?.call();
    for (final l in List.of(_textListeners)) {
      l();
    }
  }

  void Function(EditorPosition pos)? onCursorChanged;
  void Function(bool isDirty)? onDirtyChanged;

  CodeEditorController({String initialText = ''}) {
    setText(initialText, markDirty: false);
    _startBlink();
  }

  String get text => _textCache ??= _lines.join('\n');

  List<String> get lines => _linesSnapshot ??= List.unmodifiable(_lines);
  int get lineCount => _lines.length;

  /// 第 [index] 行(不复制整张行表)。
  String lineAt(int index) => _lines[index];

  /// 全文长度(UTF-16),不必拼接全文。
  int get length => _length;

  /// 每次文本改动加一。
  int get version => _version;

  // ---- 最宽行(编辑区的横向滚动宽度用) -------------------------------------------------
  //
  // 每行的显示列数,和「列数 → 有几行」的分布。编辑只更新改动的那几行:以前每敲一个字
  // 都把全文每个字符扫一遍,2 万行的文件每次按键要十几毫秒。第一次用到时才建,整体载入时作废。
  List<int>? _cols;
  final Map<int, int> _colCounts = {};
  int _maxCols = 0;

  /// 一行占几列:Tab 4 列,CJK / 全角 / emoji 2 列(代理对只记一次),其余 1 列。
  static int displayColumns(String line) {
    var cols = 0;
    for (var k = 0; k < line.length; k++) {
      final c = line.codeUnitAt(k);
      if (c == 9) {
        cols += 4;
      } else if (c >= 0x1100 && (c < 0xDC00 || c > 0xDFFF)) {
        cols += 2;
      } else if (c < 0xDC00 || c > 0xDFFF) {
        cols += 1;
      }
    }
    return cols;
  }

  /// 最宽一行的显示列数。
  int get maxColumns {
    if (_cols == null) {
      _colCounts.clear();
      _maxCols = 0;
      final cols = List<int>.filled(_lines.length, 0, growable: true); // 编辑时要随行数伸缩
      for (var i = 0; i < _lines.length; i++) {
        final c = cols[i] = displayColumns(_lines[i]);
        _colCounts[c] = (_colCounts[c] ?? 0) + 1;
        if (c > _maxCols) _maxCols = c;
      }
      _cols = cols;
    }
    return _maxCols;
  }

  /// [_edit] 把第 [first]..[last] 行换成 [replacement] 之前调用。
  void _updateColumns(int first, int last, List<String> replacement) {
    final cols = _cols;
    if (cols == null) return; // 还没人问过最宽行,不用维护
    var lostWidest = false;
    for (var i = first; i <= last; i++) {
      final c = cols[i];
      final n = _colCounts[c]! - 1;
      if (n == 0) {
        _colCounts.remove(c);
        if (c == _maxCols) lostWidest = true;
      } else {
        _colCounts[c] = n;
      }
    }
    final added = [for (final line in replacement) displayColumns(line)];
    for (final c in added) {
      _colCounts[c] = (_colCounts[c] ?? 0) + 1;
      if (c > _maxCols) {
        _maxCols = c;
        lostWidest = false;
      }
    }
    cols.replaceRange(first, last + 1, added);
    if (lostWidest) {
      // 最宽的那行没了(被改短 / 删掉):从分布里找下一个;不同的列数通常只有几十个
      _maxCols = _colCounts.keys.fold(0, (a, b) => a > b ? a : b);
    }
  }

  bool _disposed = false;

  /// 已经 [dispose](标签关了):持有它的缓存可以丢了。
  bool get isDisposed => _disposed;

  EditorPosition get cursorPosition => _selection.head;
  EditorSelection get selection => _selection;
  bool get hasSelection => !_selection.isCollapsed;

  bool get isDirty => _isDirty;
  bool get canUndo => _canUndo;
  bool get canRedo => _canRedo;
  bool get cursorVisible => caretBlink.value;
  TextRange get composingRange => _composingRange;

  // ---------------------------------------------------------------------------
  // 撤销 / 重做
  //
  // 每次编辑都经过 [_edit],那里精确知道「在哪、删了什么、插了什么」,直接记一步,
  // 不再对比编辑前后的全文。连续输入 / 连续退格在 1 秒内合并成一步,和 IntelliJ 一样;
  // 换行、光标跳动、保存都会切断合并。
  // ---------------------------------------------------------------------------

  static const int _maxHistory = 1000;
  static const Duration _groupWindow = Duration(seconds: 1);

  final List<_TextEdit> _undoStack = [];
  final List<_TextEdit> _redoStack = [];
  int _nextEditId = 1;

  /// 编辑开始前的选区:撤销时把光标放回这里。光标移动时同步更新。
  EditorSelection _historySelection = const EditorSelection.collapsed(EditorPosition.zero);

  /// 上次保存(或载入)时的文本与历史位置:判断"是否已修改"用。
  String _savedText = '';
  int _savedLength = 0;
  int _savedTopId = 0;
  bool _forceDirty = false;
  bool _applyingHistory = false;
  bool _breakGroup = false;

  int get _topId => _undoStack.isEmpty ? 0 : _undoStack.last.id;

  /// 文本是否与上次保存时不同。绝大多数情况靠历史位置和长度就能判定,
  /// 只有长度恰好相同(比如敲一个字再删掉)时才比较全文。
  bool _computeDirty() {
    if (_forceDirty) return true;
    if (_topId == _savedTopId) return false;
    if (_length != _savedLength) return true;
    return text != _savedText;
  }

  /// 文档内位置 → UTF-16 偏移。
  int _offsetOf(EditorPosition pos) {
    var offset = 0;
    for (var i = 0; i < pos.line && i < _lines.length; i++) {
      offset += _lines[i].length + 1;
    }
    return offset + pos.col;
  }

  /// UTF-16 偏移 → 文档内位置(撤销 / 重做用)。
  EditorPosition _positionOf(int offset) {
    var rest = offset;
    for (var i = 0; i < _lines.length; i++) {
      if (rest <= _lines[i].length) return EditorPosition(i, rest);
      rest -= _lines[i].length + 1;
    }
    return EditorPosition(_lines.length - 1, _lines.last.length);
  }

  /// [start]..[end] 之间的文本(只拼这一段)。
  String _rangeText(EditorPosition start, EditorPosition end) {
    if (start.line == end.line) return _lines[start.line].substring(start.col, end.col);
    final b = StringBuffer(_lines[start.line].substring(start.col));
    for (var i = start.line + 1; i < end.line; i++) {
      b
        ..write('\n')
        ..write(_lines[i]);
    }
    b
      ..write('\n')
      ..write(_lines[end.line].substring(0, end.col));
    return b.toString();
  }

  /// 所有文本修改的唯一入口:把 [start]..[end] 换成 [insertion],只动受影响的行。
  /// [selectionAfter] 为 null 时把光标收拢到原光标位置(按新文本夹紧)。
  /// [record] 为 false 时不进撤销历史(撤销 / 重做本身)。
  void _edit(EditorPosition start, EditorPosition end, String insertion, {EditorSelection? selectionAfter, bool record = true}) {
    final removed = _rangeText(start, end);
    if (removed.isEmpty && insertion.isEmpty) return;
    final offset = record ? _offsetOf(start) : 0;

    final pieces = insertion.split('\n');
    final prefix = _lines[start.line].substring(0, start.col);
    final suffix = _lines[end.line].substring(end.col);
    final List<String> replacement;
    if (pieces.length == 1) {
      replacement = ['$prefix${pieces.first}$suffix'];
    } else {
      replacement = [
        '$prefix${pieces.first}',
        ...pieces.sublist(1, pieces.length - 1),
        '${pieces.last}$suffix',
      ];
    }
    _shiftBookmarks(start, removed, insertion);
    folds.applyEdit(start.line, end.line, replacement.length);
    _updateColumns(start.line, end.line, replacement);
    _lines.replaceRange(start.line, end.line + 1, replacement);
    _length += insertion.length - removed.length;
    _textCache = null;
    _linesSnapshot = null;
    _version++;

    _selection = selectionAfter ?? EditorSelection.collapsed(_clampPosition(_selection.head));
    _preferredCol = _selection.head.col;
    folds.reveal(_selection.head.line);

    if (record && !_applyingHistory) {
      final edit = _TextEdit(
        id: _nextEditId++,
        offset: offset,
        removed: removed,
        inserted: insertion,
        selectionBefore: _historySelection,
        selectionAfter: _selection,
        time: DateTime.now(),
      );
      if (!_mergeIntoTop(edit)) {
        _undoStack.add(edit);
        if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
      }
      _redoStack.clear();
      _historySelection = _selection;
      _breakGroup = false;
    }
    _syncHistoryState();
    _emitChange(EditorTextChange(start, end, insertion));
    _emitTextChanged();
    onCursorChanged?.call(_selection.head);
    _resetBlink();
    notifyListeners();
  }

  /// 连续输入、连续退格、连续 Delete 合并成一步撤销。
  bool _mergeIntoTop(_TextEdit e) {
    if (_breakGroup || _undoStack.isEmpty || _redoStack.isNotEmpty) return false;
    final top = _undoStack.last;
    if (e.time.difference(top.time) > _groupWindow) return false;
    _TextEdit? merged;
    final typing = top.removed.isEmpty && e.removed.isEmpty;
    final deleting = top.inserted.isEmpty && e.inserted.isEmpty && e.removed.length == 1 && e.removed != '\n';
    if (typing &&
        e.inserted.length == 1 &&
        e.inserted != '\n' &&
        !top.inserted.endsWith('\n') &&
        e.offset == top.offset + top.inserted.length) {
      merged = top.copyWith(id: e.id, inserted: top.inserted + e.inserted, selectionAfter: e.selectionAfter, time: e.time);
    } else if (deleting && e.offset + 1 == top.offset) {
      // 退格:往前吃
      merged = top.copyWith(id: e.id, offset: e.offset, removed: e.removed + top.removed, selectionAfter: e.selectionAfter, time: e.time);
    } else if (deleting && e.offset == top.offset) {
      // Delete:往后吃
      merged = top.copyWith(id: e.id, removed: top.removed + e.removed, selectionAfter: e.selectionAfter, time: e.time);
    }
    if (merged == null) return false;
    _undoStack[_undoStack.length - 1] = merged;
    return true;
  }

  bool undo() {
    if (_undoStack.isEmpty) return false;
    final e = _undoStack.removeLast();
    _redoStack.add(e);
    _applyHistory(e.offset, e.inserted.length, e.removed, e.selectionBefore);
    return true;
  }

  bool redo() {
    if (_redoStack.isEmpty) return false;
    final e = _redoStack.removeLast();
    _undoStack.add(e);
    _applyHistory(e.offset, e.removed.length, e.inserted, e.selectionAfter);
    return true;
  }

  /// 在 [offset] 处把 [length] 个字符换成 [text](不进历史),光标放到 [selection]。
  void _applyHistory(int offset, int length, String text, EditorSelection selection) {
    _breakGroup = true;
    _applyingHistory = true;
    try {
      final start = _positionOf(offset);
      final end = _positionOf(offset + length);
      _edit(start, end, text, record: false, selectionAfter: selection);
      _selection = EditorSelection(anchor: _clampPosition(selection.anchor), head: _clampPosition(selection.head));
      _preferredCol = _selection.head.col;
      _historySelection = _selection;
      folds.reveal(_selection.head.line);
    } finally {
      _applyingHistory = false;
    }
    _syncHistoryState();
    notifyListeners();
  }

  void _syncHistoryState() {
    _canUndo = _undoStack.isNotEmpty;
    _canRedo = _redoStack.isNotEmpty;
    final dirty = _computeDirty();
    if (dirty != _isDirty) {
      _isDirty = dirty;
      onDirtyChanged?.call(dirty);
    }
  }

  /// 保存成功后调用:当前文本成为"未修改"的基准,并切断输入合并。
  void markSaved() {
    _savedText = text;
    _savedLength = _length;
    _savedTopId = _topId;
    _forceDirty = false;
    _breakGroup = true;
    _syncHistoryState();
    notifyListeners();
  }

  /// 作为一次编辑替换全文(进入撤销历史、通知会话层),用于差异视图「>>」等整段改写。
  /// 与 [setText] 不同:后者是"载入",会清空历史。只把真正不同的中间一段记为改动。
  void replaceAllText(String newText) {
    final old = text;
    if (newText == old) return;
    final minLen = old.length < newText.length ? old.length : newText.length;
    var p = 0;
    while (p < minLen && old.codeUnitAt(p) == newText.codeUnitAt(p)) {
      p++;
    }
    var s = 0;
    while (s < minLen - p && old.codeUnitAt(old.length - 1 - s) == newText.codeUnitAt(newText.length - 1 - s)) {
      s++;
    }
    final head = _selection.head;
    _edit(_positionOf(p), _positionOf(old.length - s), newText.substring(p, newText.length - s));
    _selection = EditorSelection.collapsed(_clampPosition(head));
    _preferredCol = _selection.head.col;
    notifyListeners();
  }

  /// 把 [start]..[end] 换成 [text](进入撤销历史),光标放在插入内容之后。输入法提交用。
  void replaceRange(EditorPosition start, EditorPosition end, String text) {
    final a = _clampPosition(start), b = _clampPosition(end);
    final s = a <= b ? a : b, e = a <= b ? b : a;
    final pieces = text.split('\n');
    final after = pieces.length == 1
        ? EditorPosition(s.line, s.col + text.length)
        : EditorPosition(s.line + pieces.length - 1, pieces.last.length);
    _edit(s, e, text, selectionAfter: EditorSelection.collapsed(after));
  }

  void setComposingRange(TextRange range) {
    _composingRange = range;
    notifyListeners();
  }

  void _startBlink() {
    _blinkTimer?.cancel();
    caretBlink.value = true;
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      caretBlink.value = !caretBlink.value;
    });
  }

  /// 编辑 / 移动光标后让光标立即显示并重新计时。调用方随后都会 notifyListeners。
  void _resetBlink() => _startBlink();

  // ---------------------------------------------------------------------------
  // 书签(行号栏 Add Bookmark / Mnemonic Bookmark)
  //
  // 放在 controller 里而不是视图里:插入 / 删除行(包括撤销重做)时书签要跟着代码走,
  // 而每一次文本变化都经过 [_edit],能拿到准确的改动位置。
  // ---------------------------------------------------------------------------

  /// 行号(0 起) → 助记符(null 表示普通书签)。
  final Map<int, String?> _bookmarks = {};

  Map<int, String?> get bookmarks => Map.unmodifiable(_bookmarks);

  bool hasBookmark(int line) => _bookmarks.containsKey(line);

  /// F3:有书签就去掉,没有就加一个普通书签。
  void toggleBookmark(int line) {
    if (_bookmarks.containsKey(line)) {
      _bookmarks.remove(line);
    } else {
      _bookmarks[line] = null;
    }
    notifyListeners();
  }

  /// 给某行设助记符(0-9 / A-Z);同一个助记符只能在一处,旧位置的会被挪过来。
  void setMnemonicBookmark(int line, String mnemonic) {
    _bookmarks.removeWhere((_, m) => m == mnemonic);
    _bookmarks[line] = mnemonic;
    notifyListeners();
  }

  void removeBookmark(int line) {
    if (!_bookmarks.containsKey(line)) return;
    _bookmarks.remove(line);
    notifyListeners();
  }

  int? lineOfMnemonic(String mnemonic) {
    for (final e in _bookmarks.entries) {
      if (e.value == mnemonic) return e.key;
    }
    return null;
  }

  /// 在 [start](改动前的位置)处 [removed] 被换成 [inserted]。
  /// 改动起始行之后的书签按增减的行数移动;被整行删掉的书签并到起始行(那里已有书签则丢弃)。
  void _shiftBookmarks(EditorPosition start, String removed, String inserted) {
    if (_bookmarks.isEmpty) return;
    final removedLines = '\n'.allMatches(removed).length;
    final insertedLines = '\n'.allMatches(inserted).length;
    if (removedLines == 0 && insertedLines == 0) return;
    // 从行首开始的整行增删有两种等价写法("c\n" 在行首 / "\nc" 在上一行末尾)。
    // 统一成后者:删掉的书签行并到上一行,行首插入的新行把书签行往下推 —— 书签跟着内容走。
    var startLine = start.line;
    if (start.col == 0 &&
        start.line > 0 &&
        ((inserted.isEmpty && removed.endsWith('\n')) || (removed.isEmpty && inserted.endsWith('\n')))) {
      startLine -= 1;
    }
    final delta = insertedLines - removedLines;
    final moved = <int, String?>{};
    _bookmarks.forEach((line, mnemonic) {
      final int target;
      if (line <= startLine) {
        target = line;
      } else if (line <= startLine + removedLines) {
        target = startLine;
      } else {
        target = line + delta;
      }
      // 并到同一行时保留助记书签,普通书签让位。
      if (!moved.containsKey(target) || (moved[target] == null && mnemonic != null)) {
        moved[target] = mnemonic;
      }
    });
    _bookmarks
      ..clear()
      ..addAll(moved);
  }

  /// 载入整份文本(打开文件 / 从磁盘重新加载):清空撤销历史。
  /// [markDirty] 为 false 时这份文本就是"已保存"的基准。要作为一次可撤销的编辑,用 [replaceAllText]。
  void setText(String newText, {bool markDirty = false}) {
    _lines = newText.isEmpty ? [''] : newText.split('\n');
    folds.lineCount = _lines.length; // 收起的段先留着,语法树更新后再核对(见 FoldState.reconcile)
    _cols = null; // 最宽行下次用到时重建
    _textCache = newText;
    _linesSnapshot = null;
    _length = newText.length;
    _version++;
    _selection = EditorSelection.collapsed(_clampPosition(_selection.head));
    _preferredCol = _selection.head.col;
    _undoStack.clear();
    _redoStack.clear();
    _historySelection = _selection;
    if (!markDirty) {
      _savedText = newText;
      _savedLength = newText.length;
    }
    _savedTopId = 0;
    _forceDirty = markDirty;
    _canUndo = false;
    _canRedo = false;
    final dirty = _computeDirty();
    if (dirty != _isDirty) {
      _isDirty = dirty;
      onDirtyChanged?.call(dirty);
    }
    _emitChange(const EditorTextChange.reset());
    _resetBlink();
    notifyListeners();
  }

  /// Sets cursor position without selection (or extends selection if extendSelection is true).
  void setCursor(EditorPosition target, {bool extendSelection = false, bool updatePreferredCol = true}) {
    final clamped = _clampPosition(target);
    if (updatePreferredCol) {
      _preferredCol = clamped.col;
    }
    if (extendSelection) {
      _selection = EditorSelection(anchor: _selection.anchor, head: clamped);
    } else {
      _selection = EditorSelection.collapsed(clamped);
    }
    _historySelection = _selection;
    _breakGroup = true;
    folds.reveal(clamped.line);
    _resetBlink();
    onCursorChanged?.call(clamped);
    notifyListeners();
  }

  /// Sets an explicit selection.
  void setSelection(EditorPosition anchor, EditorPosition head) {
    final clampedAnchor = _clampPosition(anchor);
    final clampedHead = _clampPosition(head);
    _preferredCol = clampedHead.col;
    _selection = EditorSelection(anchor: clampedAnchor, head: clampedHead);
    _historySelection = _selection;
    _breakGroup = true;
    folds.reveal(clampedHead.line);
    _resetBlink();
    onCursorChanged?.call(clampedHead);
    notifyListeners();
  }

  /// Inserts text at the cursor or replaces the current selection.
  void insertText(String insertion) {
    if (insertion.isEmpty) return;
    replaceRange(_selection.start, _selection.end, insertion);
  }

  /// Handles Backspace key.
  void deleteBackward() {
    if (hasSelection) {
      _deleteSelection();
      return;
    }
    final cur = _selection.head;
    if (cur.line == 0 && cur.col == 0) return;
    final from = cur.col > 0 ? EditorPosition(cur.line, cur.col - 1) : EditorPosition(cur.line - 1, _lines[cur.line - 1].length);
    _edit(from, cur, '', selectionAfter: EditorSelection.collapsed(from));
  }

  /// Handles Delete key (forward deletion).
  void deleteForward() {
    if (hasSelection) {
      _deleteSelection();
      return;
    }
    final cur = _selection.head;
    final EditorPosition to;
    if (cur.col < _lines[cur.line].length) {
      to = EditorPosition(cur.line, cur.col + 1);
    } else if (cur.line < _lines.length - 1) {
      to = EditorPosition(cur.line + 1, 0);
    } else {
      return;
    }
    _edit(cur, to, '', selectionAfter: EditorSelection.collapsed(cur));
  }

  void _deleteSelection() {
    final start = _selection.start;
    _edit(start, _selection.end, '', selectionAfter: EditorSelection.collapsed(start));
  }

  /// Handles Enter / Return key with auto-indentation(有选区时先替换掉选区,算一步)。
  void insertNewline() {
    final start = _selection.start;
    final end = _selection.end;
    final before = _lines[start.line].substring(0, start.col);

    // 新行沿用当前行的缩进;行尾是 { : ( 时再缩进一级
    final lineAfterDelete = before + _lines[end.line].substring(end.col);
    var indent = RegExp(r'^(\s*)').firstMatch(lineAfterDelete)?.group(1) ?? '';
    final trimmedBefore = before.trimRight();
    if (trimmedBefore.endsWith('{') || trimmedBefore.endsWith(':') || trimmedBefore.endsWith('(')) {
      indent += '    ';
    }
    final newPos = EditorPosition(start.line + 1, indent.length);
    _edit(start, end, '\n$indent', selectionAfter: EditorSelection.collapsed(newPos));
  }

  /// Handles Tab key (4 spaces or multi-line indent).
  void insertTab() {
    if (hasSelection && _selection.start.line != _selection.end.line) {
      // Indent all selected lines
      final startLine = _selection.start.line;
      final endLine = _selection.end.line;
      final block = [for (var i = startLine; i <= endLine; i++) '    ${_lines[i]}'].join('\n');
      final after = EditorSelection(
        anchor: EditorPosition(startLine, _selection.anchor.col + 4),
        head: EditorPosition(endLine, _selection.head.col + 4),
      );
      _edit(EditorPosition(startLine, 0), EditorPosition(endLine, _lines[endLine].length), block, selectionAfter: after);
    } else {
      insertText('    ');
    }
  }

  /// Handles Shift+Tab (unindent).
  void unindent() {
    final startLine = hasSelection ? _selection.start.line : _selection.head.line;
    final endLine = hasSelection ? _selection.end.line : _selection.head.line;

    var modified = false;
    final out = <String>[];
    for (var i = startLine; i <= endLine; i++) {
      final line = _lines[i];
      String next;
      if (line.startsWith('    ')) {
        next = line.substring(4);
      } else if (line.startsWith('  ')) {
        next = line.substring(2);
      } else if (line.startsWith('\t') || line.startsWith(' ')) {
        next = line.substring(1);
      } else {
        next = line;
      }
      if (next != line) modified = true;
      out.add(next);
    }
    if (!modified) return;
    final head = _selection.head;
    _edit(EditorPosition(startLine, 0), EditorPosition(endLine, _lines[endLine].length), out.join('\n'));
    _selection = EditorSelection.collapsed(_clampPosition(head));
    _preferredCol = _selection.head.col;
    notifyListeners();
  }

  // ---------------------------------------------------------------------------
  // 代码折叠
  // ---------------------------------------------------------------------------

  /// 收起 [r];光标在藏起来的行里时移到起始行行尾(IntelliJ 如此)。
  void collapseFold(FoldRange r) {
    if (!folds.collapse(r)) return;
    final head = _selection.head;
    if (folds.isHidden(head.line)) {
      _selection = EditorSelection.collapsed(EditorPosition(r.start, _lines[r.start].length));
      _preferredCol = _selection.head.col;
      _historySelection = _selection;
      onCursorChanged?.call(_selection.head);
    }
    notifyListeners();
  }

  /// 一次收起好几段(全部收起)。
  void collapseFolds(Iterable<FoldRange> ranges) {
    var changed = false;
    for (final r in ranges) {
      changed = folds.collapse(r) || changed;
    }
    if (!changed) return;
    final head = _selection.head;
    if (folds.isHidden(head.line)) {
      final line = folds.lineOfRow(folds.rowOfLine(head.line));
      _selection = EditorSelection.collapsed(EditorPosition(line, _lines[line].length));
      _preferredCol = _selection.head.col;
      _historySelection = _selection;
      onCursorChanged?.call(_selection.head);
    }
    notifyListeners();
  }

  void expandFold(int start) {
    if (folds.expand(start)) notifyListeners();
  }

  void expandAllFolds() {
    if (folds.expandAll()) notifyListeners();
  }

  /// 收起 / 展开 [r](行号栏的折叠箭头)。
  void toggleFold(FoldRange r) => folds.isCollapsed(r.start) ? expandFold(r.start) : collapseFold(r);

  /// 可折叠的范围从哪来:编辑区把语法树的查询接上(`DocumentHighlighter.foldsIn`)。
  /// 返回从第 [from, to) 行开始的范围;没有语法树时为 null 或返回空。
  List<FoldRange> Function(int from, int to)? foldRegionsProvider;

  /// 光标所在的、还没收起的最内层一段(IntelliJ 的 Collapse,⌘-)。
  void collapseRegionAtCaret() {
    final line = _selection.head.line;
    final regions = foldRegionsProvider?.call(0, line + 1) ?? const <FoldRange>[];
    FoldRange? best;
    for (final r in regions) {
      if (r.start <= line && line <= r.end && !folds.isCollapsed(r.start) && (best == null || r.start > best.start)) best = r;
    }
    if (best != null) collapseFold(best);
  }

  /// 展开光标所在行收起的段(IntelliJ 的 Expand,⌘=)。
  void expandRegionAtCaret() => expandFold(_selection.head.line);

  /// 全部收起(⇧⌘-)。
  void collapseAllRegions() => collapseFolds(foldRegionsProvider?.call(0, _lines.length) ?? const []);

  /// 语法树更新后核对收起的段(见 [FoldState.reconcile])。
  void reconcileFolds(List<FoldRange> regions, int from, int to) {
    if (folds.reconcile(regions, from, to)) notifyListeners();
  }

  /// 复制当前行 / 选中的内容(IntelliJ 的 Duplicate Line or Selection,⌘D),算一步撤销。
  /// 没选中:当前行复制到下一行,光标跟到新行的同一列;选中了:在选区后面接一份,选中复制出来的那份。
  void duplicateLineOrSelection() {
    _breakGroup = true; // 不和前面的输入合成一步撤销
    if (hasSelection) {
      final end = _selection.end;
      final text = _rangeText(_selection.start, end);
      final pieces = text.split('\n');
      final newEnd = pieces.length == 1
          ? EditorPosition(end.line, end.col + text.length)
          : EditorPosition(end.line + pieces.length - 1, pieces.last.length);
      _edit(end, end, text, selectionAfter: EditorSelection(anchor: end, head: newEnd));
    } else {
      final head = _selection.head;
      final line = _lines[head.line];
      final at = EditorPosition(head.line, line.length);
      _edit(at, at, '\n$line', selectionAfter: EditorSelection.collapsed(EditorPosition(head.line + 1, head.col)));
    }
    _breakGroup = true; // 接着打字也另起一步
    _historySelection = _selection;
  }

  /// Navigates the cursor in the given direction.
  void moveCursor({
    required NavigationDirection direction,
    bool extendSelection = false,
    bool wordJump = false,
    bool lineJump = false,
    bool documentJump = false,
  }) {
    final current = _selection.head;
    EditorPosition target;

    if (documentJump) {
      if (direction == NavigationDirection.up) {
        target = EditorPosition.zero;
      } else if (direction == NavigationDirection.down) {
        target = EditorPosition(_lines.length - 1, _lines.last.length);
      } else {
        target = current;
      }
    } else if (lineJump) {
      if (direction == NavigationDirection.left) {
        // Jump to first non-whitespace or line start
        final line = _lines[current.line];
        final firstNonSpace = line.indexOf(RegExp(r'\S'));
        if (firstNonSpace != -1 && current.col > firstNonSpace) {
          target = EditorPosition(current.line, firstNonSpace);
        } else {
          target = EditorPosition(current.line, 0);
        }
      } else if (direction == NavigationDirection.right) {
        target = EditorPosition(current.line, _lines[current.line].length);
      } else {
        target = current;
      }
    } else if (wordJump) {
      target = _findWordBoundary(current, direction);
    } else {
      switch (direction) {
        case NavigationDirection.left:
          if (!extendSelection && hasSelection) {
            target = _selection.start;
          } else if (current.col > 0) {
            target = EditorPosition(current.line, current.col - 1);
          } else if (current.line > 0) {
            target = EditorPosition(current.line - 1, _lines[current.line - 1].length);
          } else {
            target = current;
          }
          _preferredCol = target.col;
          break;

        case NavigationDirection.right:
          if (!extendSelection && hasSelection) {
            target = _selection.end;
          } else if (current.col < _lines[current.line].length) {
            target = EditorPosition(current.line, current.col + 1);
          } else if (current.line < _lines.length - 1) {
            target = EditorPosition(current.line + 1, 0);
          } else {
            target = current;
          }
          _preferredCol = target.col;
          break;

        case NavigationDirection.up:
          // 按可见行走:收起的段整段跳过
          if (folds.rowOfLine(current.line) > 0) {
            final targetLine = folds.lineOfRow(folds.rowOfLine(current.line) - 1);
            final targetCol = (_preferredCol ?? current.col).clamp(0, _lines[targetLine].length);
            target = EditorPosition(targetLine, targetCol);
          } else {
            target = const EditorPosition(0, 0);
          }
          break;

        case NavigationDirection.down:
          if (folds.rowOfLine(current.line) < folds.rowCount - 1) {
            final targetLine = folds.lineOfRow(folds.rowOfLine(current.line) + 1);
            final targetCol = (_preferredCol ?? current.col).clamp(0, _lines[targetLine].length);
            target = EditorPosition(targetLine, targetCol);
          } else {
            target = EditorPosition(_lines.length - 1, _lines.last.length);
          }
          break;
      }
    }

    final isVertical = direction == NavigationDirection.up || direction == NavigationDirection.down;
    setCursor(target, extendSelection: extendSelection, updatePreferredCol: !isVertical);
  }

  /// Selects the word at the given position.
  void selectWord(EditorPosition pos) {
    final clamped = _clampPosition(pos);
    final line = _lines[clamped.line];
    if (line.isEmpty) return;

    final col = clamped.col.clamp(0, line.length - 1);
    final char = line[col];

    bool isWordChar(String c) => RegExp(r'^[a-zA-Z0-9_]$').hasMatch(c);
    final targetType = isWordChar(char);

    int startCol = col;
    while (startCol > 0 && isWordChar(line[startCol - 1]) == targetType) {
      startCol--;
    }

    int endCol = col;
    while (endCol < line.length && isWordChar(line[endCol]) == targetType) {
      endCol++;
    }

    setSelection(
      EditorPosition(clamped.line, startCol),
      EditorPosition(clamped.line, endCol),
    );
  }

  /// Selects an entire line.
  void selectLine(int lineIndex) {
    if (lineIndex < 0 || lineIndex >= _lines.length) return;
    setSelection(
      EditorPosition(lineIndex, 0),
      EditorPosition(lineIndex, _lines[lineIndex].length),
    );
  }

  /// Selects all text in document.
  void selectAll() {
    setSelection(
      EditorPosition.zero,
      EditorPosition(_lines.length - 1, _lines.last.length),
    );
  }

  /// Returns selected text.
  String getSelectedText() {
    if (!hasSelection) return '';
    final start = _selection.start;
    final end = _selection.end;

    if (start.line == end.line) {
      return _lines[start.line].substring(start.col, end.col);
    }

    final buffer = StringBuffer();
    buffer.writeln(_lines[start.line].substring(start.col));
    for (int i = start.line + 1; i < end.line; i++) {
      buffer.writeln(_lines[i]);
    }
    buffer.write(_lines[end.line].substring(0, end.col));
    return buffer.toString();
  }

  /// Copies selected text to system clipboard.
  Future<void> copy() async {
    final text = getSelectedText();
    if (text.isNotEmpty) {
      _wholeLineClip = null;
      await Clipboard.setData(ClipboardData(text: text));
    }
  }

  /// 上一次没选中时剪下的整行(带换行)。粘贴时剪贴板里还是它,就按整行插到光标所在行的上面(同 IntelliJ)。
  String? _wholeLineClip;

  /// 剪切(⌘X)。选中了剪选中的;没选中时剪掉光标所在的整行(连同换行,同 IntelliJ),
  /// 下面的行上来,光标留在同一列。先改文本再写剪贴板,按键处理随后同步输入法时文本已经是新的。
  Future<void> cut() async {
    if (hasSelection) {
      final text = getSelectedText();
      _wholeLineClip = null;
      _deleteSelection();
      await Clipboard.setData(ClipboardData(text: text));
      return;
    }
    final line = _selection.head.line;
    final col = _selection.head.col;
    final content = _lines[line];
    if (_lines.length == 1 && content.isEmpty) return; // 空文件:没东西可剪
    _breakGroup = true;
    if (_lines.length == 1) {
      _edit(const EditorPosition(0, 0), EditorPosition(0, content.length), '', selectionAfter: const EditorSelection.collapsed(EditorPosition.zero));
    } else if (line < _lines.length - 1) {
      final next = _lines[line + 1];
      _edit(EditorPosition(line, 0), EditorPosition(line + 1, 0), '',
          selectionAfter: EditorSelection.collapsed(EditorPosition(line, col < next.length ? col : next.length)));
    } else {
      // 最后一行:连同上一行末尾的换行一起删掉,光标回到上一行
      final prev = _lines[line - 1];
      _edit(EditorPosition(line - 1, prev.length), EditorPosition(line, content.length), '',
          selectionAfter: EditorSelection.collapsed(EditorPosition(line - 1, col < prev.length ? col : prev.length)));
    }
    _breakGroup = true;
    _wholeLineClip = '$content\n';
    await Clipboard.setData(ClipboardData(text: _wholeLineClip!));
  }

  /// Pastes text from system clipboard. 剪贴板里是刚剪下的整行时,插到光标所在行的上面,光标跟着原来的文字走。
  Future<void> paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    final text = data?.text;
    if (text == null || text.isEmpty) return;
    if (!hasSelection && _wholeLineClip != null && text == _wholeLineClip) {
      final at = EditorPosition(_selection.head.line, 0);
      final lines = '\n'.allMatches(text).length;
      _breakGroup = true;
      _edit(at, at, text, selectionAfter: EditorSelection.collapsed(EditorPosition(_selection.head.line + lines, _selection.head.col)));
      _breakGroup = true;
      return;
    }
    insertText(text);
  }

  // --- Internal helpers ---

  EditorPosition _clampPosition(EditorPosition pos) {
    if (_lines.isEmpty) return EditorPosition.zero;
    final clampedLine = pos.line.clamp(0, _lines.length - 1);
    final clampedCol = pos.col.clamp(0, _lines[clampedLine].length);
    return EditorPosition(clampedLine, clampedCol);
  }




  EditorPosition _findWordBoundary(EditorPosition current, NavigationDirection dir) {
    final line = _lines[current.line];
    bool isWordChar(String c) => RegExp(r'^[a-zA-Z0-9_]$').hasMatch(c);

    if (dir == NavigationDirection.left) {
      if (current.col == 0) {
        if (current.line > 0) {
          return EditorPosition(current.line - 1, _lines[current.line - 1].length);
        }
        return current;
      }

      int idx = current.col - 1;
      while (idx > 0 && line[idx] == ' ') {
        idx--;
      }
      final inWord = isWordChar(line[idx]);
      while (idx > 0 && isWordChar(line[idx - 1]) == inWord && line[idx - 1] != ' ') {
        idx--;
      }
      return EditorPosition(current.line, idx);
    } else {
      if (current.col >= line.length) {
        if (current.line < _lines.length - 1) {
          return EditorPosition(current.line + 1, 0);
        }
        return current;
      }

      int idx = current.col;
      while (idx < line.length && line[idx] == ' ') {
        idx++;
      }
      if (idx >= line.length) return EditorPosition(current.line, line.length);
      final inWord = isWordChar(line[idx]);
      while (idx < line.length && isWordChar(line[idx]) == inWord && line[idx] != ' ') {
        idx++;
      }
      return EditorPosition(current.line, idx);
    }
  }

  @override
  void dispose() {
    _disposed = true;
    _blinkTimer?.cancel();
    caretBlink.dispose();
    super.dispose();
  }
}

/// 一步可撤销的编辑:在 [offset] 处把 [removed] 换成了 [inserted](UTF-16 下标)。
class _TextEdit {
  const _TextEdit({
    required this.id,
    required this.offset,
    required this.removed,
    required this.inserted,
    required this.selectionBefore,
    required this.selectionAfter,
    required this.time,
  });

  /// 历史位置的标识(合并后换新 id):判断"回到了保存时的状态"用。
  final int id;
  final int offset;
  final String removed;
  final String inserted;
  final EditorSelection selectionBefore;
  final EditorSelection selectionAfter;
  final DateTime time;

  _TextEdit copyWith({int? id, int? offset, String? removed, String? inserted, EditorSelection? selectionAfter, DateTime? time}) =>
      _TextEdit(
        id: id ?? this.id,
        offset: offset ?? this.offset,
        removed: removed ?? this.removed,
        inserted: inserted ?? this.inserted,
        selectionBefore: selectionBefore,
        selectionAfter: selectionAfter ?? this.selectionAfter,
        time: time ?? this.time,
      );
}
