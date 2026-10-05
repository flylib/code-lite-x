import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'code_editor_controller.dart';

/// Bridges the CodeEditorController with Flutter's system TextInput pipeline,
/// enabling native CJK (Chinese, Japanese, Korean) IME composition and virtual keyboards.
class ImeTextInputBridge implements TextInputClient {
  final CodeEditorController controller;
  final FocusNode focusNode;

  TextInputConnection? _connection;
  TextEditingValue _currentValue = TextEditingValue.empty;

  ImeTextInputBridge({
    required this.controller,
    required this.focusNode,
  });

  bool get isAttached => _connection != null && _connection!.attached;

  /// Attaches to Flutter's TextInput manager.
  void attach() {
    if (isAttached) return;

    _connection = TextInput.attach(
      this,
      const TextInputConfiguration(
        inputType: TextInputType.multiline,
        readOnly: false,
        autocorrect: false,
        enableSuggestions: false,
        keyboardAppearance: Brightness.dark,
        inputAction: TextInputAction.newline,
      ),
    );

    _syncFromController();
    _connection?.show();
  }

  /// Detaches and closes active IME connection.
  void detach() {
    if (isAttached) {
      _connection?.close();
      _connection = null;
    }
  }

  /// Synchronizes local state to the system IME.
  void syncState() {
    if (!isAttached) return;
    _syncFromController();
  }

  /// 发给输入法的「窗口」:光标 / 选区所在的那几行(不是整个文件)。
  /// 以前每次按键都把全文作为编辑值发给系统输入法,大文件里这一步就要拼接并传输几 MB。
  int _windowStartLine = 0;

  void _syncFromController() {
    final sel = controller.selection;
    final first = sel.start.line;
    final last = sel.end.line;
    _windowStartLine = first;
    final text = first == last
        ? controller.lineAt(first)
        : [for (var i = first; i <= last; i++) controller.lineAt(i)].join('\n');

    int offsetOf(EditorPosition p) {
      var o = 0;
      for (var i = first; i < p.line; i++) {
        o += controller.lineAt(i).length + 1; // +1 for '\n'
      }
      return (o + p.col).clamp(0, text.length);
    }

    final composing = controller.composingRange;
    _currentValue = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: offsetOf(sel.anchor), extentOffset: offsetOf(sel.head)),
      composing: composing.isValid && composing.end <= text.length ? composing : TextRange.empty,
    );

    _connection?.setEditingState(_currentValue);
  }

  /// 窗口内偏移 → 文档位置。
  EditorPosition _positionInWindow(int offset) {
    var line = _windowStartLine;
    var rest = offset;
    while (line < controller.lineCount - 1 && rest > controller.lineAt(line).length) {
      rest -= controller.lineAt(line).length + 1;
      line++;
    }
    return EditorPosition(line, rest.clamp(0, controller.lineAt(line).length));
  }

  @override
  TextEditingValue? get currentTextEditingValue => _currentValue;

  @override
  void updateEditingValue(TextEditingValue value) {
    if (!focusNode.hasFocus && !isAttached) return;

    // Handle IME composition
    if (value.composing.isValid) {
      controller.setComposingRange(value.composing);
    } else if (controller.composingRange.isValid) {
      controller.setComposingRange(TextRange.empty);
    }

    final oldText = _currentValue.text;
    final newText = value.text;
    if (newText == oldText) {
      _currentValue = value;
      return;
    }

    // 输入法改动的是窗口里的一段:取公共前后缀,一次替换到文档里。
    var prefixLen = 0;
    while (prefixLen < oldText.length &&
        prefixLen < newText.length &&
        oldText.codeUnitAt(prefixLen) == newText.codeUnitAt(prefixLen)) {
      prefixLen++;
    }
    var suffixLen = 0;
    while (suffixLen < (oldText.length - prefixLen) &&
        suffixLen < (newText.length - prefixLen) &&
        oldText.codeUnitAt(oldText.length - 1 - suffixLen) == newText.codeUnitAt(newText.length - 1 - suffixLen)) {
      suffixLen++;
    }
    final start = _positionInWindow(prefixLen);
    final end = _positionInWindow(oldText.length - suffixLen);
    controller.replaceRange(start, end, newText.substring(prefixLen, newText.length - suffixLen));
    // 以文档为准重新生成窗口(换行后窗口会移到新行),保证下次比对的基准一致。
    _syncFromController();
  }

  @override
  void performAction(TextInputAction action) {
    if (action == TextInputAction.newline || action == TextInputAction.done) {
      controller.insertNewline();
    }
  }

  @override
  void connectionClosed() {
    _connection = null;
  }

  @override
  AutofillScope? get currentAutofillScope => null;

  @override
  void performPrivateCommand(String action, Map<String, dynamic> data) {}

  @override
  void showAutocorrectionPromptRect(int start, int end) {}

  /// Flutter 3.4x 新增:浏览器自动填充时平台把焦点交还输入框。桌面端不会调用,沿用默认实现。
  @override
  bool onFocusReceived() => false;

  @override
  void didChangeInputControl(TextInputControl? oldControl, TextInputControl? newControl) {}

  @override
  void insertTextPlaceholder(Size size) {}

  @override
  void removeTextPlaceholder() {}

  @override
  void updateFloatingCursor(RawFloatingCursorPoint point) {}

  @override
  void showToolbar() {}

  @override
  void insertContent(KeyboardInsertedContent content) {}

  @override
  void performSelector(String selectorName) {}
}
