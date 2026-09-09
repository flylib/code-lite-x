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

  void _syncFromController() {
    final text = controller.text;
    final cur = controller.cursorPosition;

    // Convert line/col to 1D index
    int offset = 0;
    for (int i = 0; i < cur.line && i < controller.lines.length; i++) {
      offset += controller.lines[i].length + 1; // +1 for '\n'
    }
    if (cur.line < controller.lines.length) {
      offset += cur.col.clamp(0, controller.lines[cur.line].length);
    }
    offset = offset.clamp(0, text.length);

    int anchorOffset = offset;
    if (controller.hasSelection) {
      final anchor = controller.selection.anchor;
      anchorOffset = 0;
      for (int i = 0; i < anchor.line && i < controller.lines.length; i++) {
        anchorOffset += controller.lines[i].length + 1;
      }
      if (anchor.line < controller.lines.length) {
        anchorOffset += anchor.col.clamp(0, controller.lines[anchor.line].length);
      }
      anchorOffset = anchorOffset.clamp(0, text.length);
    }

    _currentValue = TextEditingValue(
      text: text,
      selection: TextSelection(baseOffset: anchorOffset, extentOffset: offset),
      composing: controller.composingRange,
    );

    _connection?.setEditingState(_currentValue);
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

    // If text changed, detect insertion or replacement from IME
    if (value.text != _currentValue.text) {
      // If previous had selection and now replaced
      if (_currentValue.selection.isValid && !_currentValue.selection.isCollapsed) {
        final start = _currentValue.selection.start;
        final end = _currentValue.selection.end;
        final inserted = value.text.length >= (start + (value.text.length - (_currentValue.text.length - (end - start))))
            ? value.text.substring(start, value.text.length - (_currentValue.text.length - end))
            : '';
        if (inserted.isNotEmpty) {
          controller.insertText(inserted);
        } else {
          controller.setText(value.text, markDirty: true);
        }
      } else {
        // Delta text diff
        final oldText = _currentValue.text;
        final newText = value.text;

        int prefixLen = 0;
        while (prefixLen < oldText.length &&
            prefixLen < newText.length &&
            oldText.codeUnitAt(prefixLen) == newText.codeUnitAt(prefixLen)) {
          prefixLen++;
        }

        int suffixLen = 0;
        while (suffixLen < (oldText.length - prefixLen) &&
            suffixLen < (newText.length - prefixLen) &&
            oldText.codeUnitAt(oldText.length - 1 - suffixLen) ==
                newText.codeUnitAt(newText.length - 1 - suffixLen)) {
          suffixLen++;
        }

        final inserted = newText.substring(prefixLen, newText.length - suffixLen);
        final deletedCount = oldText.length - prefixLen - suffixLen;

        if (deletedCount > 0) {
          for (int i = 0; i < deletedCount; i++) {
            controller.deleteBackward();
          }
        }
        if (inserted.isNotEmpty) {
          controller.insertText(inserted);
        }
      }
    }

    _currentValue = value;
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
