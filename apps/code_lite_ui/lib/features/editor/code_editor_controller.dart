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

  bool _cursorVisible = true;
  Timer? _blinkTimer;

  // IME composing range (if active)
  TextRange _composingRange = TextRange.empty;

  // AI Ghost-text (Fill-in-the-Middle) state
  String? _ghostText;
  EditorPosition? _ghostPosition;

  void Function(String newText)? onTextChanged;
  void Function(EditorPosition pos)? onCursorChanged;
  void Function(bool isDirty)? onDirtyChanged;
  void Function(String? ghostText)? onGhostTextChanged;

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
  bool get cursorVisible => _cursorVisible;
  TextRange get composingRange => _composingRange;

  String? get ghostText => _ghostText;
  EditorPosition? get ghostPosition => _ghostPosition;
  bool get hasGhostText => _ghostText != null && _ghostText!.isNotEmpty;

  /// Sets the active inline ghost text suggestion at the specified position.
  void setGhostText(String? text, {EditorPosition? position}) {
    final targetPos = position ?? cursorPosition;
    if (_ghostText == text && _ghostPosition == targetPos) return;
    _ghostText = (text != null && text.isNotEmpty) ? text : null;
    _ghostPosition = _ghostText != null ? targetPos : null;
    onGhostTextChanged?.call(_ghostText);
    notifyListeners();
  }

  /// Clears active ghost text suggestion.
  void clearGhostText() {
    if (_ghostText != null) {
      _ghostText = null;
      _ghostPosition = null;
      onGhostTextChanged?.call(null);
      notifyListeners();
    }
  }

  /// Fully accepts active ghost text and inserts it at cursor position.
  bool acceptGhostText() {
    if (_ghostText == null || _ghostText!.isEmpty) return false;
    if (_ghostPosition != null && _ghostPosition != cursorPosition) {
      clearGhostText();
      return false;
    }

    final toInsert = _ghostText!;
    clearGhostText();
    insertText(toInsert);
    return true;
  }

  /// Accepts the next word or token from the ghost text suggestion.
  bool acceptGhostTextWord() {
    if (_ghostText == null || _ghostText!.isEmpty) return false;
    if (_ghostPosition != null && _ghostPosition != cursorPosition) {
      clearGhostText();
      return false;
    }

    final full = _ghostText!;
    bool isWord(String ch) => RegExp(r'^[a-zA-Z0-9_]$').hasMatch(ch);

    int end = 0;
    if (end < full.length && isWord(full[end])) {
      while (end < full.length && isWord(full[end])) {
        end++;
      }
    } else if (end < full.length && (full[end] == ' ' || full[end] == '\t')) {
      while (end < full.length && (full[end] == ' ' || full[end] == '\t')) {
        end++;
      }
    } else {
      end = 1;
    }

    final word = full.substring(0, end);
    final remaining = full.substring(end);

    insertText(word);
    if (remaining.isNotEmpty) {
      _ghostText = remaining;
      _ghostPosition = cursorPosition;
      onGhostTextChanged?.call(_ghostText);
      notifyListeners();
    } else {
      clearGhostText();
    }
    return true;
  }

  /// Returns text before cursor for FIM (up to maxChars).
  String getPrefixForFim([int maxChars = 1000]) {
    final before = _getTextBefore(cursorPosition);
    if (before.length <= maxChars) return before;
    return before.substring(before.length - maxChars);
  }

  /// Returns text after cursor for FIM (up to maxChars).
  String getSuffixForFim([int maxChars = 500]) {
    final after = _getTextAfter(cursorPosition);
    if (after.length <= maxChars) return after;
    return after.substring(0, maxChars);
  }

  void setHistoryStatus({required bool canUndo, required bool canRedo, bool? isDirty}) {
    _canUndo = canUndo;
    _canRedo = canRedo;
    if (isDirty != null && _isDirty != isDirty) {
      _isDirty = isDirty;
      onDirtyChanged?.call(_isDirty);
    }
    notifyListeners();
  }

  void markSaved() {
    if (_isDirty) {
      _isDirty = false;
      onDirtyChanged?.call(false);
      notifyListeners();
    }
  }

  void setComposingRange(TextRange range) {
    _composingRange = range;
    notifyListeners();
  }

  void _startBlink() {
    _blinkTimer?.cancel();
    _cursorVisible = true;
    _blinkTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      _cursorVisible = !_cursorVisible;
      notifyListeners();
    });
  }

  void _resetBlink() {
    _cursorVisible = true;
    _startBlink();
    notifyListeners();
  }

  /// Sets the entire document text.
  void setText(String newText, {bool markDirty = false}) {
    _text = newText;
    _lines = newText.isEmpty ? [''] : newText.split('\n');
    _selection = EditorSelection.collapsed(_clampPosition(_selection.head));
    _preferredCol = _selection.head.col;
    if (markDirty && !_isDirty) {
      _isDirty = true;
      onDirtyChanged?.call(true);
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

    onTextChanged?.call(_text);
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
    onTextChanged?.call(_text);
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
    onTextChanged?.call(_text);
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
    onTextChanged?.call(_text);
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
    onTextChanged?.call(_text);
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
      onTextChanged?.call(_text);
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
      onTextChanged?.call(_text);
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
    super.dispose();
  }
}
