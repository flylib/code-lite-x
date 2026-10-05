import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

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

/// State controller managing text buffer, caret position, selection,
/// and rich keyboard editing actions for CodeLiteX editor.
class CodeEditorController extends ChangeNotifier {
  String _text = '';
  List<String> _lines = [''];
  EditorSelection _selection = const EditorSelection.collapsed(EditorPosition.zero);
  int? _preferredCol;

  bool _isDirty = false;
  bool _canUndo = false;
  bool _canRedo = false;

  Timer? _blinkTimer;

  /// 光标闪烁的显隐。单独一个通知源:只有光标那一小块订阅它,
  /// 闪烁(每 500ms)不再触发整个编辑区重建。
  final ValueNotifier<bool> caretBlink = ValueNotifier(true);

  // IME composing range (if active)
  TextRange _composingRange = TextRange.empty;

  /// 会话层(同步 Rust buffer、通知 LSP)用的回调。视图层不要覆盖它,改用 [addTextListener]。
  void Function(String newText)? onTextChanged;
  final List<void Function(String newText)> _textListeners = [];

  /// 额外的文本变化监听。此前视图层直接赋值 [onTextChanged],把会话层的回调顶掉了,
  /// 编辑内容因此没同步给 Rust(保存会写回旧内容),LSP 也收不到 didChange。
  void addTextListener(void Function(String newText) listener) => _textListeners.add(listener);

  void removeTextListener(void Function(String newText) listener) => _textListeners.remove(listener);

  void _emitTextChanged() {
    if (!_applyingHistory) _recordEdit();
    onTextChanged?.call(_text);
    for (final l in List.of(_textListeners)) {
      l(_text);
    }
  }
  void Function(EditorPosition pos)? onCursorChanged;
  void Function(bool isDirty)? onDirtyChanged;

  CodeEditorController({String initialText = ''}) {
    setText(initialText, markDirty: false);
    _startBlink();
  }

  String get text => _text;
  List<String> get lines => List.unmodifiable(_lines);
  int get lineCount => _lines.length;

  EditorPosition get cursorPosition => _selection.head;
  EditorSelection get selection => _selection;
  bool get hasSelection => !_selection.isCollapsed;

  bool get isDirty => _isDirty;
  bool get canUndo => _canUndo;
  bool get canRedo => _canRedo;
  bool get cursorVisible => caretBlink.value;
  TextRange get composingRange => _composingRange;

  // ---------------------------------------------------------------------------
  // 撤销 / 重做(原在 Rust code-lite-core,迁到 Dart)
  //
  // 不逐个改各编辑方法:所有编辑最后都经过 _emitTextChanged,在那里对比"历史已知文本"
  // 与新文本,取公共前后缀得到这一步改了什么。连续输入 / 连续退格在 1 秒内合并成一步,
  // 和 IntelliJ 一样;换行、光标跳动、保存都会切断合并。
  // ---------------------------------------------------------------------------

  static const int _maxHistory = 1000;
  static const Duration _groupWindow = Duration(seconds: 1);

  final List<_TextEdit> _undoStack = [];
  final List<_TextEdit> _redoStack = [];

  /// 历史记录所知的文本(上一次记录之后的样子),用来和新文本做差。
  String _historyText = '';

  /// 编辑开始前的选区:撤销时把光标放回这里。光标移动时同步更新。
  EditorSelection _historySelection = const EditorSelection.collapsed(EditorPosition.zero);

  /// 上次保存时的文本:撤销回到这里就不再算"已修改"。
  String _savedText = '';
  bool _applyingHistory = false;
  bool _breakGroup = false;

  void _recordEdit() {
    final before = _historyText;
    final after = _text;
    if (before == after) return;
    final minLen = before.length < after.length ? before.length : after.length;
    var prefix = 0;
    while (prefix < minLen && before.codeUnitAt(prefix) == after.codeUnitAt(prefix)) {
      prefix++;
    }
    var suffix = 0;
    while (suffix < minLen - prefix &&
        before.codeUnitAt(before.length - 1 - suffix) == after.codeUnitAt(after.length - 1 - suffix)) {
      suffix++;
    }
    final removed = before.substring(prefix, before.length - suffix);
    final inserted = after.substring(prefix, after.length - suffix);
    // 单字符增删落在一串相同字符里时,前后缀比对给出的是这串的最右端(删 "llo" 的
    // 第一个 l 会被认成删第二个),位置一错连续 Delete 就合不上。用光标消歧:
    // 删除后光标就在删除点,插入后光标在插入点之后。
    if (removed.length == 1 && inserted.isEmpty) {
      prefix = _disambiguate(before, prefix, removed.codeUnitAt(0), _offsetOf(_selection.head));
    } else if (inserted.length == 1 && removed.isEmpty) {
      prefix = _disambiguate(after, prefix, inserted.codeUnitAt(0), _offsetOf(_selection.head) - 1);
    }
    final edit = _TextEdit(
      offset: prefix,
      removed: removed,
      inserted: inserted,
      selectionBefore: _historySelection,
      selectionAfter: _selection,
      time: DateTime.now(),
    );
    _shiftBookmarks(before, edit.offset, edit.removed, edit.inserted);
    if (!_mergeIntoTop(edit)) {
      _undoStack.add(edit);
      if (_undoStack.length > _maxHistory) _undoStack.removeAt(0);
    }
    _redoStack.clear();
    _historyText = after;
    _historySelection = _selection;
    _breakGroup = false;
    _syncHistoryState();
  }

  /// [text] 中 [p] 处的字符 [unit] 若属于一串相同字符,把位置挪到 [cursor](在这串范围内时)。
  int _disambiguate(String text, int p, int unit, int cursor) {
    var lo = p;
    while (lo > 0 && text.codeUnitAt(lo - 1) == unit) {
      lo--;
    }
    return (lo < p && cursor >= lo && cursor <= p) ? cursor : p;
  }

  int _offsetOf(EditorPosition pos) {
    var offset = 0;
    for (var i = 0; i < pos.line && i < _lines.length; i++) {
      offset += _lines[i].length + 1;
    }
    return offset + pos.col;
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
      merged = top.copyWith(inserted: top.inserted + e.inserted, selectionAfter: e.selectionAfter, time: e.time);
    } else if (deleting && e.offset + 1 == top.offset) {
      // 退格:往前吃
      merged = top.copyWith(offset: e.offset, removed: e.removed + top.removed, selectionAfter: e.selectionAfter, time: e.time);
    } else if (deleting && e.offset == top.offset) {
      // Delete:往后吃
      merged = top.copyWith(removed: top.removed + e.removed, selectionAfter: e.selectionAfter, time: e.time);
    }
    if (merged == null) return false;
    _undoStack[_undoStack.length - 1] = merged;
    return true;
  }

  bool undo() {
    if (_undoStack.isEmpty) return false;
    final e = _undoStack.removeLast();
    _redoStack.add(e);
    _shiftBookmarks(_text, e.offset, e.inserted, e.removed);
    _applyHistory(
      _text.replaceRange(e.offset, e.offset + e.inserted.length, e.removed),
      e.selectionBefore,
    );
    return true;
  }

  bool redo() {
    if (_redoStack.isEmpty) return false;
    final e = _redoStack.removeLast();
    _undoStack.add(e);
    _shiftBookmarks(_text, e.offset, e.removed, e.inserted);
    _applyHistory(
      _text.replaceRange(e.offset, e.offset + e.removed.length, e.inserted),
      e.selectionAfter,
    );
    return true;
  }

  void _applyHistory(String newText, EditorSelection selection) {
    _text = newText;
    _lines = newText.isEmpty ? [''] : newText.split('\n');
    _selection = EditorSelection(anchor: _clampPosition(selection.anchor), head: _clampPosition(selection.head));
    _preferredCol = _selection.head.col;
    _historyText = newText;
    _historySelection = _selection;
    _breakGroup = true;
    _applyingHistory = true;
    try {
      _emitTextChanged(); // 会话层照常同步(LSP didChange 等),但不再记入历史
    } finally {
      _applyingHistory = false;
    }
    _syncHistoryState();
    onCursorChanged?.call(_selection.head);
    _resetBlink();
    notifyListeners();
  }

  void _syncHistoryState() {
    _canUndo = _undoStack.isNotEmpty;
    _canRedo = _redoStack.isNotEmpty;
    final dirty = _text != _savedText;
    if (dirty != _isDirty) {
      _isDirty = dirty;
      onDirtyChanged?.call(dirty);
    }
  }

  /// 保存成功后调用:当前文本成为"未修改"的基准,并切断输入合并。
  void markSaved() {
    _savedText = _text;
    _breakGroup = true;
    _syncHistoryState();
    notifyListeners();
  }

  /// 作为一次编辑替换全文(进入撤销历史、通知会话层),用于输入法等整段改写。
  /// 与 [setText] 不同:后者是"载入",会清空历史。
  void replaceAllText(String newText) {
    if (newText == _text) return;
    _text = newText;
    _lines = newText.isEmpty ? [''] : newText.split('\n');
    _selection = EditorSelection.collapsed(_clampPosition(_selection.head));
    _preferredCol = _selection.head.col;
    _emitTextChanged();
    onCursorChanged?.call(_selection.head);
    _resetBlink();
    notifyListeners();
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
  // 而每一次文本变化都经过这里,能拿到准确的改动位置。
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

  /// [text] 是改动前的文本:在 [offset] 处 [removed] 被换成 [inserted]。
  /// 改动起始行之后的书签按增减的行数移动;被整行删掉的书签并到起始行(那里已有书签则丢弃)。
  void _shiftBookmarks(String text, int offset, String removed, String inserted) {
    if (_bookmarks.isEmpty) return;
    // 从行首开始的整行增删有两种等价写法("c\n" 在行首 / "\nc" 在上一行末尾)。
    // 统一成后者:删掉的书签行并到上一行,行首插入的新行把书签行往下推 —— 书签跟着内容走。
    if (offset > 0 && text.codeUnitAt(offset - 1) == 0x0A) {
      if (inserted.isEmpty && removed.endsWith('\n')) {
        offset -= 1;
        removed = '\n${removed.substring(0, removed.length - 1)}';
      } else if (removed.isEmpty && inserted.endsWith('\n')) {
        offset -= 1;
        inserted = '\n${inserted.substring(0, inserted.length - 1)}';
      }
    }
    final removedLines = '\n'.allMatches(removed).length;
    final insertedLines = '\n'.allMatches(inserted).length;
    if (removedLines == 0 && insertedLines == 0) return;
    final startLine = '\n'.allMatches(text.substring(0, offset)).length;
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
    _text = newText;
    _lines = newText.isEmpty ? [''] : newText.split('\n');
    _selection = EditorSelection.collapsed(_clampPosition(_selection.head));
    _preferredCol = _selection.head.col;
    _undoStack.clear();
    _redoStack.clear();
    _historyText = newText;
    _historySelection = _selection;
    if (!markDirty) _savedText = newText;
    final dirty = markDirty || newText != _savedText;
    _canUndo = false;
    _canRedo = false;
    if (dirty != _isDirty) {
      _isDirty = dirty;
      onDirtyChanged?.call(dirty);
    }
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
    _resetBlink();
    onCursorChanged?.call(clampedHead);
    notifyListeners();
  }

  /// Inserts text at the cursor or replaces the current selection.
  void insertText(String insertion) {
    if (insertion.isEmpty) return;

    final sel = _selection;
    final start = sel.start;
    final end = sel.end;

    final before = _getTextBefore(start);
    final after = _getTextAfter(end);

    final newContent = before + insertion + after;
    _text = newContent;
    _lines = newContent.isEmpty ? [''] : newContent.split('\n');

    // Compute new cursor position
    final insertionLines = insertion.split('\n');
    final newHeadLine = start.line + insertionLines.length - 1;
    final newHeadCol = insertionLines.length == 1
        ? start.col + insertion.length
        : insertionLines.last.length;

    final newPos = EditorPosition(newHeadLine, newHeadCol);
    _selection = EditorSelection.collapsed(newPos);
    _preferredCol = newPos.col;
    _markDirty();

    _emitTextChanged();
    onCursorChanged?.call(newPos);
    _resetBlink();
    notifyListeners();
  }

  /// Handles Backspace key.
  void deleteBackward() {
    if (hasSelection) {
      _deleteSelection();
      return;
    }

    final cur = _selection.head;
    if (cur.line == 0 && cur.col == 0) return;

    if (cur.col > 0) {
      final line = _lines[cur.line];
      final newLine = line.substring(0, cur.col - 1) + line.substring(cur.col);
      _lines[cur.line] = newLine;
      _text = _lines.join('\n');
      final newPos = EditorPosition(cur.line, cur.col - 1);
      _selection = EditorSelection.collapsed(newPos);
      _preferredCol = newPos.col;
    } else {
      // Merge with previous line
      final prevLine = _lines[cur.line - 1];
      final currLine = _lines[cur.line];
      final newCol = prevLine.length;
      _lines[cur.line - 1] = prevLine + currLine;
      _lines.removeAt(cur.line);
      _text = _lines.join('\n');
      final newPos = EditorPosition(cur.line - 1, newCol);
      _selection = EditorSelection.collapsed(newPos);
      _preferredCol = newPos.col;
    }

    _markDirty();
    _emitTextChanged();
    onCursorChanged?.call(_selection.head);
    _resetBlink();
    notifyListeners();
  }

  /// Handles Delete key (forward deletion).
  void deleteForward() {
    if (hasSelection) {
      _deleteSelection();
      return;
    }

    final cur = _selection.head;
    final currentLine = _lines[cur.line];

    if (cur.col < currentLine.length) {
      final newLine = currentLine.substring(0, cur.col) + currentLine.substring(cur.col + 1);
      _lines[cur.line] = newLine;
      _text = _lines.join('\n');
    } else if (cur.line < _lines.length - 1) {
      // Merge next line into current
      final nextLine = _lines[cur.line + 1];
      _lines[cur.line] = currentLine + nextLine;
      _lines.removeAt(cur.line + 1);
      _text = _lines.join('\n');
    } else {
      return;
    }

    _markDirty();
    _emitTextChanged();
    _resetBlink();
    notifyListeners();
  }

  void _deleteSelection() {
    final start = _selection.start;
    final end = _selection.end;

    final before = _getTextBefore(start);
    final after = _getTextAfter(end);

    _text = before + after;
    _lines = _text.isEmpty ? [''] : _text.split('\n');
    _selection = EditorSelection.collapsed(start);
    _preferredCol = start.col;

    _markDirty();
    _emitTextChanged();
    onCursorChanged?.call(start);
    _resetBlink();
    notifyListeners();
  }

  /// Handles Enter / Return key with auto-indentation.
  void insertNewline() {
    if (hasSelection) {
      _deleteSelection();
    }

    final cur = _selection.head;
    final currentLine = _lines[cur.line];

    // Compute leading whitespace for indentation
    final match = RegExp(r'^(\s*)').firstMatch(currentLine);
    var indent = match?.group(1) ?? '';

    // If previous line ends with '{' or ':', add 4 spaces
    final trimmedBefore = currentLine.substring(0, cur.col).trimRight();
    if (trimmedBefore.endsWith('{') || trimmedBefore.endsWith(':') || trimmedBefore.endsWith('(')) {
      indent += '    ';
    }

    final before = currentLine.substring(0, cur.col);
    final after = currentLine.substring(cur.col);

    _lines[cur.line] = before;
    _lines.insert(cur.line + 1, indent + after);
    _text = _lines.join('\n');

    final newPos = EditorPosition(cur.line + 1, indent.length);
    _selection = EditorSelection.collapsed(newPos);
    _preferredCol = newPos.col;

    _markDirty();
    _emitTextChanged();
    onCursorChanged?.call(newPos);
    _resetBlink();
    notifyListeners();
  }

  /// Handles Tab key (4 spaces or multi-line indent).
  void insertTab() {
    if (hasSelection && _selection.start.line != _selection.end.line) {
      // Indent all selected lines
      final startLine = _selection.start.line;
      final endLine = _selection.end.line;
      for (int i = startLine; i <= endLine; i++) {
        _lines[i] = '    ${_lines[i]}';
      }
      _text = _lines.join('\n');
      _selection = EditorSelection(
        anchor: EditorPosition(startLine, _selection.anchor.col + 4),
        head: EditorPosition(endLine, _selection.head.col + 4),
      );
      _markDirty();
      _emitTextChanged();
      notifyListeners();
    } else {
      insertText('    ');
    }
  }

  /// Handles Shift+Tab (unindent).
  void unindent() {
    final startLine = hasSelection ? _selection.start.line : _selection.head.line;
    final endLine = hasSelection ? _selection.end.line : _selection.head.line;

    bool modified = false;
    for (int i = startLine; i <= endLine; i++) {
      final line = _lines[i];
      if (line.startsWith('    ')) {
        _lines[i] = line.substring(4);
        modified = true;
      } else if (line.startsWith('  ')) {
        _lines[i] = line.substring(2);
        modified = true;
      } else if (line.startsWith('\t') || line.startsWith(' ')) {
        _lines[i] = line.substring(1);
        modified = true;
      }
    }

    if (modified) {
      _text = _lines.join('\n');
      _selection = EditorSelection.collapsed(_clampPosition(_selection.head));
      _markDirty();
      _emitTextChanged();
      notifyListeners();
    }
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
          if (current.line > 0) {
            final targetLine = current.line - 1;
            final targetCol = (_preferredCol ?? current.col).clamp(0, _lines[targetLine].length);
            target = EditorPosition(targetLine, targetCol);
          } else {
            target = const EditorPosition(0, 0);
          }
          break;

        case NavigationDirection.down:
          if (current.line < _lines.length - 1) {
            final targetLine = current.line + 1;
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
      await Clipboard.setData(ClipboardData(text: text));
    }
  }

  /// Cuts selected text to system clipboard.
  Future<void> cut() async {
    final text = getSelectedText();
    if (text.isNotEmpty) {
      await Clipboard.setData(ClipboardData(text: text));
      _deleteSelection();
    }
  }

  /// Pastes text from system clipboard.
  Future<void> paste() async {
    final data = await Clipboard.getData(Clipboard.kTextPlain);
    if (data?.text != null && data!.text!.isNotEmpty) {
      insertText(data.text!);
    }
  }

  // --- Internal helpers ---

  EditorPosition _clampPosition(EditorPosition pos) {
    if (_lines.isEmpty) return EditorPosition.zero;
    final clampedLine = pos.line.clamp(0, _lines.length - 1);
    final clampedCol = pos.col.clamp(0, _lines[clampedLine].length);
    return EditorPosition(clampedLine, clampedCol);
  }

  String _getTextBefore(EditorPosition pos) {
    final buffer = StringBuffer();
    for (int i = 0; i < pos.line; i++) {
      buffer.writeln(_lines[i]);
    }
    if (pos.line < _lines.length) {
      buffer.write(_lines[pos.line].substring(0, pos.col));
    }
    return buffer.toString();
  }

  String _getTextAfter(EditorPosition pos) {
    final buffer = StringBuffer();
    if (pos.line < _lines.length) {
      buffer.write(_lines[pos.line].substring(pos.col));
    }
    for (int i = pos.line + 1; i < _lines.length; i++) {
      buffer.write('\n');
      buffer.write(_lines[i]);
    }
    return buffer.toString();
  }

  void _markDirty() {
    if (!_isDirty) {
      _isDirty = true;
      onDirtyChanged?.call(true);
    }
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
    _blinkTimer?.cancel();
    caretBlink.dispose();
    super.dispose();
  }
}

/// 一步可撤销的编辑:在 [offset] 处把 [removed] 换成了 [inserted](UTF-16 下标)。
class _TextEdit {
  const _TextEdit({
    required this.offset,
    required this.removed,
    required this.inserted,
    required this.selectionBefore,
    required this.selectionAfter,
    required this.time,
  });

  final int offset;
  final String removed;
  final String inserted;
  final EditorSelection selectionBefore;
  final EditorSelection selectionAfter;
  final DateTime time;

  _TextEdit copyWith({int? offset, String? removed, String? inserted, EditorSelection? selectionAfter, DateTime? time}) =>
      _TextEdit(
        offset: offset ?? this.offset,
        removed: removed ?? this.removed,
        inserted: inserted ?? this.inserted,
        selectionBefore: selectionBefore,
        selectionAfter: selectionAfter ?? this.selectionAfter,
        time: time ?? this.time,
      );
}
