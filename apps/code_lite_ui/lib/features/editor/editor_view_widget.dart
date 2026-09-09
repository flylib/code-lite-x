import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/theme/intellij_theme.dart';
import 'code_editor_controller.dart';
import 'ime_text_input_client.dart';
import 'lsp_overlay.dart';
import 'syntax_highlighter.dart';

class EditorViewWidget extends StatefulWidget {
  final List<String> openTabs;
  final String activeFile;
  final String codeContent;
  final String? activeSymbol;
  final List<EditorDiagnostic> diagnostics;
  final ValueChanged<String> onSelectTab;
  final ValueChanged<String> onCloseTab;
  final ValueChanged<String> onCodeChanged;

  final CodeEditorController? controller;
  final ScrollController? verticalScroll;
  final ScrollController? horizontalScroll;
  final VoidCallback? onSave;
  final VoidCallback? onUndo;
  final VoidCallback? onRedo;
  final bool Function(String path)? isTabDirty;

  const EditorViewWidget({
    super.key,
    required this.openTabs,
    required this.activeFile,
    required this.codeContent,
    this.activeSymbol,
    this.diagnostics = const [],
    required this.onSelectTab,
    required this.onCloseTab,
    required this.onCodeChanged,
    this.controller,
    this.verticalScroll,
    this.horizontalScroll,
    this.onSave,
    this.onUndo,
    this.onRedo,
    this.isTabDirty,
  });

  @override
  State<EditorViewWidget> createState() => _EditorViewWidgetState();
}

class _EditorViewWidgetState extends State<EditorViewWidget> {
  late CodeEditorController _controller;
  bool _ownsController = false;

  late ScrollController _verticalScroll;
  bool _ownsVerticalScroll = false;

  late ScrollController _horizontalScroll;
  bool _ownsHorizontalScroll = false;

  final FocusNode _focusNode = FocusNode();
  late ImeTextInputBridge _imeBridge;

  double _charWidth = 7.2;

  @override
  void initState() {
    super.initState();
    _initController();
    _initScrollControllers();
    _measureCharWidth();

    _imeBridge = ImeTextInputBridge(
      controller: _controller,
      focusNode: _focusNode,
    );

    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        _imeBridge.attach();
      } else {
        _imeBridge.detach();
      }
    });
  }

  void _initController() {
    if (widget.controller != null) {
      _controller = widget.controller!;
      _ownsController = false;
    } else {
      _controller = CodeEditorController(initialText: widget.codeContent);
      _ownsController = true;
    }

    _controller.onTextChanged = (newText) {
      widget.onCodeChanged(newText);
      _imeBridge.syncState();
    };
  }

  void _initScrollControllers() {
    if (widget.verticalScroll != null) {
      _verticalScroll = widget.verticalScroll!;
      _ownsVerticalScroll = false;
    } else {
      _verticalScroll = ScrollController();
      _ownsVerticalScroll = true;
    }

    if (widget.horizontalScroll != null) {
      _horizontalScroll = widget.horizontalScroll!;
      _ownsHorizontalScroll = false;
    } else {
      _horizontalScroll = ScrollController();
      _ownsHorizontalScroll = true;
    }
  }

  void _measureCharWidth() {
    final painter = TextPainter(
      text: const TextSpan(
        text: 'M',
        style: TextStyle(
          fontSize: 12,
          fontFamily: 'monospace',
        ),
      ),
      textDirection: TextDirection.ltr,
    )..layout();
    if (painter.width > 0) {
      _charWidth = painter.width;
    }
  }

  @override
  void didUpdateWidget(EditorViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.controller != oldWidget.controller) {
      if (_ownsController) _controller.dispose();
      _initController();
      _imeBridge = ImeTextInputBridge(controller: _controller, focusNode: _focusNode);
    } else if (widget.codeContent != oldWidget.codeContent &&
        widget.codeContent != _controller.text &&
        _ownsController) {
      _controller.setText(widget.codeContent, markDirty: false);
    }

    if (widget.verticalScroll != oldWidget.verticalScroll) {
      if (_ownsVerticalScroll) _verticalScroll.dispose();
      _verticalScroll = widget.verticalScroll ?? ScrollController();
      _ownsVerticalScroll = widget.verticalScroll == null;
    }

    if (widget.horizontalScroll != oldWidget.horizontalScroll) {
      if (_ownsHorizontalScroll) _horizontalScroll.dispose();
      _horizontalScroll = widget.horizontalScroll ?? ScrollController();
      _ownsHorizontalScroll = widget.horizontalScroll == null;
    }
  }

  @override
  void dispose() {
    _imeBridge.detach();
    _focusNode.dispose();
    if (_ownsController) _controller.dispose();
    if (_ownsVerticalScroll) _verticalScroll.dispose();
    if (_ownsHorizontalScroll) _horizontalScroll.dispose();
    super.dispose();
  }

  KeyEventResult _handleKeyEvent(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final isCmd = HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;

    // Shortcuts: Save
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyS) {
      widget.onSave?.call();
      return KeyEventResult.handled;
    }

    // Shortcuts: Undo
    if (isCmd && !isShift && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (widget.onUndo != null) {
        widget.onUndo!.call();
      }
      return KeyEventResult.handled;
    }

    // Shortcuts: Redo
    if ((isCmd && isShift && event.logicalKey == LogicalKeyboardKey.keyZ) ||
        (isCmd && event.logicalKey == LogicalKeyboardKey.keyY)) {
      if (widget.onRedo != null) {
        widget.onRedo!.call();
      }
      return KeyEventResult.handled;
    }

    // Shortcuts: Select All
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyA) {
      _controller.selectAll();
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }

    // Shortcuts: Copy
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyC) {
      _controller.copy();
      return KeyEventResult.handled;
    }

    // Shortcuts: Cut
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyX) {
      _controller.cut();
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }

    // Shortcuts: Paste
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyV) {
      _controller.paste();
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }

    // Navigation: Arrows
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      _controller.moveCursor(
        direction: NavigationDirection.left,
        extendSelection: isShift,
        wordJump: isAlt,
        lineJump: isCmd,
      );
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      _controller.moveCursor(
        direction: NavigationDirection.right,
        extendSelection: isShift,
        wordJump: isAlt,
        lineJump: isCmd,
      );
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      _controller.moveCursor(
        direction: NavigationDirection.up,
        extendSelection: isShift,
        documentJump: isCmd,
      );
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      _controller.moveCursor(
        direction: NavigationDirection.down,
        extendSelection: isShift,
        documentJump: isCmd,
      );
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }

    // Home / End
    if (event.logicalKey == LogicalKeyboardKey.home) {
      _controller.moveCursor(direction: NavigationDirection.left, extendSelection: isShift, lineJump: true);
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.end) {
      _controller.moveCursor(direction: NavigationDirection.right, extendSelection: isShift, lineJump: true);
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }

    // Backspace / Delete
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      _controller.deleteBackward();
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      _controller.deleteForward();
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }

    // Enter
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      _controller.insertNewline();
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }

    // Tab / Shift+Tab
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (isShift) {
        _controller.unindent();
      } else {
        _controller.insertTab();
      }
      _imeBridge.syncState();
      return KeyEventResult.handled;
    }

    // Printable character input
    if (!isCmd && event.character != null && event.character!.isNotEmpty) {
      final code = event.character!.codeUnitAt(0);
      if (code >= 32) {
        _controller.insertText(event.character!);
        _imeBridge.syncState();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  @override
  Widget build(BuildContext context) {
    return AnimatedBuilder(
      animation: _controller,
      builder: (context, _) {
        final lines = _controller.lines;

        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: _handleKeyEvent,
          child: Container(
            color: IntelliJTheme.editorBg,
            child: Column(
              children: [
                // 1. Tab Bar
                _buildTabBar(),

                // 2. Editor Breadcrumb Sub-Header
                _buildSubHeader(lines.length),

                // 3. Main Text Area (Gutter + Code)
                Expanded(
                  child: Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Expanded(
                        child: SingleChildScrollView(
                          controller: _verticalScroll,
                          child: Row(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Line numbers gutter
                              _buildGutter(lines.length),

                              // Git Diff stripe
                              _buildGitDiffStripe(lines.length),

                              // Code View
                              Expanded(
                                child: SingleChildScrollView(
                                  controller: _horizontalScroll,
                                  scrollDirection: Axis.horizontal,
                                  child: GestureDetector(
                                    behavior: HitTestBehavior.opaque,
                                    onTapDown: (details) {
                                      _focusNode.requestFocus();
                                      _imeBridge.attach();
                                      final line = (details.localPosition.dy / 20.0).floor();
                                      final col = (details.localPosition.dx / _charWidth).round();
                                      _controller.setCursor(EditorPosition(line, col));
                                      _imeBridge.syncState();
                                    },
                                    onDoubleTapDown: (details) {
                                      final line = (details.localPosition.dy / 20.0).floor();
                                      final col = (details.localPosition.dx / _charWidth).round();
                                      _controller.selectWord(EditorPosition(line, col));
                                      _imeBridge.syncState();
                                    },
                                    onPanStart: (details) {
                                      _focusNode.requestFocus();
                                      final line = (details.localPosition.dy / 20.0).floor();
                                      final col = (details.localPosition.dx / _charWidth).round();
                                      _controller.setCursor(EditorPosition(line, col));
                                      _imeBridge.syncState();
                                    },
                                    onPanUpdate: (details) {
                                      final line = (details.localPosition.dy / 20.0).floor();
                                      final col = (details.localPosition.dx / _charWidth).round();
                                      _controller.setCursor(EditorPosition(line, col), extendSelection: true);
                                      _imeBridge.syncState();
                                    },
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                      child: Column(
                                        crossAxisAlignment: CrossAxisAlignment.start,
                                        children: [
                                          ...lines.asMap().entries.map((entry) {
                                            return _buildCodeLine(entry.key, entry.value);
                                          }),

                                          // AI Ghost-text inline suggestion
                                          const SizedBox(height: 12),
                                          _buildAiGhostText(),
                                        ],
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ),
                      ),

                      // Right error/change stripe
                      _buildRightErrorStripe(lines.length),
                    ],
                  ),
                ),
              ],
            ),
          ),
        );
      },
    );
  }

  Widget _buildTabBar() {
    return Container(
      height: 34,
      decoration: const BoxDecoration(
        color: IntelliJTheme.tabInactiveBg,
        border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(
            child: ListView.builder(
              scrollDirection: Axis.horizontal,
              itemCount: widget.openTabs.length,
              itemBuilder: (context, index) {
                final path = widget.openTabs[index];
                final fileName = path.split('/').last;
                final isActive = path == widget.activeFile;
                final isDirty = widget.isTabDirty?.call(path) ?? (isActive && _controller.isDirty);

                return InkWell(
                  onTap: () => widget.onSelectTab(path),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    decoration: BoxDecoration(
                      color: isActive ? IntelliJTheme.tabActiveBg : IntelliJTheme.tabInactiveBg,
                      border: Border(
                        bottom: BorderSide(
                          color: isActive ? IntelliJTheme.accentBlue : Colors.transparent,
                          width: 2,
                        ),
                        right: const BorderSide(color: IntelliJTheme.borderSubtle, width: 0.5),
                      ),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Text('⚙', style: TextStyle(color: Color(0xFFD87642), fontSize: 10)),
                        const SizedBox(width: 6),
                        Text(
                          fileName,
                          style: TextStyle(
                            color: isActive ? IntelliJTheme.textHigh : IntelliJTheme.textMuted,
                            fontSize: 12,
                            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
                          ),
                        ),
                        if (isDirty) ...[
                          const SizedBox(width: 4),
                          Container(
                            width: 6,
                            height: 6,
                            decoration: const BoxDecoration(
                              color: Color(0xFF6CB4F8),
                              shape: BoxShape.circle,
                            ),
                          ),
                        ],
                        const SizedBox(width: 8),
                        InkWell(
                          onTap: () => widget.onCloseTab(path),
                          child: const Icon(Icons.close, size: 12, color: IntelliJTheme.textMuted),
                        ),
                      ],
                    ),
                  ),
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildSubHeader(int lineCount) {
    final segments = widget.activeFile.split('/').where((s) => s.isNotEmpty).toList();
    final isDirty = _controller.isDirty;

    return Container(
      height: 24,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: IntelliJTheme.subHeaderBg,
        border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          // Breadcrumbs Bar
          Expanded(
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  const Icon(Icons.folder_open, size: 12, color: IntelliJTheme.accentYellow),
                  const SizedBox(width: 4),
                  const Text('code-lite-x', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11)),
                  ...segments.map((seg) {
                    final isLast = seg == segments.last;
                    return Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 4),
                          child: Icon(Icons.chevron_right, size: 11, color: IntelliJTheme.textMuted),
                        ),
                        Text(
                          seg,
                          style: TextStyle(
                            color: isLast ? IntelliJTheme.textPrimary : IntelliJTheme.textMuted,
                            fontSize: 11,
                            fontWeight: isLast ? FontWeight.w500 : FontWeight.normal,
                          ),
                        ),
                      ],
                    );
                  }),
                  if (widget.activeSymbol != null && widget.activeSymbol!.isNotEmpty) ...[
                    const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 4),
                      child: Icon(Icons.chevron_right, size: 11, color: IntelliJTheme.textMuted),
                    ),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                      decoration: BoxDecoration(
                        color: const Color(0xFF353B48),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Text('⌘', style: TextStyle(color: Color(0xFFFFC66D), fontSize: 10)),
                          const SizedBox(width: 3),
                          Text(
                            widget.activeSymbol!,
                            style: const TextStyle(color: Color(0xFFFFC66D), fontSize: 10, fontWeight: FontWeight.bold),
                          ),
                        ],
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            '$lineCount lines • UTF-8${isDirty ? ' • Modified' : ''}',
            style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10),
          ),
        ],
      ),
    );
  }

  Widget _buildGutter(int totalLines) {
    return Container(
      width: 48,
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: IntelliJTheme.editorBg,
      child: Column(
        children: List.generate(totalLines, (index) {
          final lineDiags = widget.diagnostics.where((d) => d.line == index).toList();
          final hasError = lineDiags.any((d) => d.isError);
          final hasWarning = lineDiags.any((d) => d.isWarning);

          return SizedBox(
            height: 20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                if (hasError)
                  Tooltip(
                    message: lineDiags.firstWhere((d) => d.isError).message,
                    child: Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: const BoxDecoration(
                        color: Color(0xFFF97A7A),
                        shape: BoxShape.circle,
                      ),
                    ),
                  )
                else if (hasWarning)
                  Tooltip(
                    message: lineDiags.firstWhere((d) => d.isWarning).message,
                    child: Container(
                      width: 6,
                      height: 6,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: const BoxDecoration(
                        color: Color(0xFFE5C07B),
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                Text(
                  '${index + 1}',
                  style: const TextStyle(
                    color: IntelliJTheme.textGutter,
                    fontSize: 11,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 6),
              ],
            ),
          );
        }),
      ),
    );
  }

  Widget _buildGitDiffStripe(int totalLines) {
    return Container(
      width: 3,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: List.generate(totalLines, (index) {
          Color color = Colors.transparent;
          if (index == 2 || index == 3) {
            color = IntelliJTheme.gitGreen;
          } else if (index == 5 || index == 6) {
            color = IntelliJTheme.gitBlue;
          }
          return Container(height: 20, color: color);
        }),
      ),
    );
  }

  Widget _buildCodeLine(int lineIndex, String lineText) {
    final lang = widget.activeFile.endsWith('.dart') ? 'dart' : 'rust';
    final spans = SyntaxHighlighter.highlightLine(lineText, language: lang);

    final lineDiags = widget.diagnostics.where((d) => d.line == lineIndex).toList();
    final hasError = lineDiags.any((d) => d.isError);
    final hasWarning = lineDiags.any((d) => d.isWarning);

    final sel = _controller.selection;
    final isLineSelected = !sel.isCollapsed && lineIndex >= sel.start.line && lineIndex <= sel.end.line;

    int selStartCol = 0;
    int selEndCol = 0;
    if (isLineSelected) {
      if (sel.start.line == sel.end.line) {
        selStartCol = sel.start.col;
        selEndCol = sel.end.col;
      } else if (lineIndex == sel.start.line) {
        selStartCol = sel.start.col;
        selEndCol = lineText.length;
      } else if (lineIndex == sel.end.line) {
        selStartCol = 0;
        selEndCol = sel.end.col;
      } else {
        selStartCol = 0;
        selEndCol = lineText.length;
      }
    }

    final isCaretLine = lineIndex == _controller.cursorPosition.line;
    final caretCol = _controller.cursorPosition.col;

    Widget lineContent = SizedBox(
      height: 20,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 1. Selection Highlight Box
          if (isLineSelected && selEndCol > selStartCol)
            Positioned(
              left: selStartCol * _charWidth,
              width: (selEndCol - selStartCol) * _charWidth,
              top: 0,
              bottom: 0,
              child: Container(
                color: const Color(0xFF214283),
              ),
            ),

          // 2. Syntax Token Text
          RichText(
            text: TextSpan(
              style: const TextStyle(
                fontSize: 12,
                fontFamily: 'monospace',
                height: 1.4,
              ),
              children: spans,
            ),
            overflow: TextOverflow.clip,
          ),

          // 3. Caret (Blinking Cursor)
          if (isCaretLine && _controller.cursorVisible)
            Positioned(
              left: (caretCol * _charWidth).clamp(0.0, 99999.0),
              top: 2,
              bottom: 2,
              child: Container(
                width: 2,
                color: const Color(0xFF589DF6),
              ),
            ),

          // 4. Diagnostic Squiggle
          if (hasError || hasWarning)
            Positioned(
              left: 0,
              right: 0,
              bottom: 2,
              child: Container(
                height: 2,
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: hasError ? const Color(0xFFF97A7A) : const Color(0xFFE5C07B),
                      width: 1.5,
                      style: BorderStyle.solid,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );

    if (lineDiags.isNotEmpty) {
      final diag = lineDiags.first;
      return Tooltip(
        message: '[${diag.code ?? (diag.isError ? "Error" : "Warning")}] ${diag.message}',
        child: lineContent,
      );
    }

    return lineContent;
  }

  Widget _buildAiGhostText() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF252830),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF353B47)),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text('AI GHOST TEXT', style: TextStyle(color: Color(0xFF6CB4F8), fontSize: 9, fontWeight: FontWeight.bold)),
          SizedBox(width: 8),
          Flexible(
            child: Text(
              '// Press [Tab] to accept: self.event_store.log(Some(&op.session_id), "OperationReverted", &payload)?;',
              style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11, fontFamily: 'monospace', fontStyle: FontStyle.italic),
              overflow: TextOverflow.ellipsis,
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildRightErrorStripe(int totalLines) {
    return Container(
      width: 12,
      decoration: const BoxDecoration(
        color: Color(0xFF26282E),
        border: Border(left: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          return Stack(
            children: [
              ...widget.diagnostics.map((d) {
                final topPos = totalLines > 0 ? (d.line / totalLines) * height : 0.0;
                return Positioned(
                  top: topPos.clamp(0.0, height - 4),
                  left: 2,
                  right: 2,
                  child: Container(
                    height: 3,
                    decoration: BoxDecoration(
                      color: d.isError ? const Color(0xFFF97A7A) : const Color(0xFFE5C07B),
                      borderRadius: BorderRadius.circular(1),
                    ),
                  ),
                );
              }),
            ],
          );
        },
      ),
    );
  }
}
