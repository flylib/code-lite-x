import 'dart:async';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';
import 'code_editor_controller.dart';
import 'editor_session_manager.dart';
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
  final ApiClient? apiClient;

  // Phase 8.3 Additions: Split Pane & Tabs & Git Gutter
  final SplitDirection splitDirection;
  final EditorTabState? secondaryTab;
  final ValueChanged<SplitDirection>? onSplitChange;
  final VoidCallback? onCloseSplit;
  final void Function(int oldIndex, int newIndex)? onReorderTabs;
  final VoidCallback? onCloseActiveTab;
  final ValueChanged<String>? onSelectSecondaryTab;
  final ValueChanged<String>? onRevertFile;

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
    this.apiClient,
    this.splitDirection = SplitDirection.none,
    this.secondaryTab,
    this.onSplitChange,
    this.onCloseSplit,
    this.onReorderTabs,
    this.onCloseActiveTab,
    this.onSelectSecondaryTab,
    this.onRevertFile,
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

  final FocusNode _secondaryFocusNode = FocusNode();
  ImeTextInputBridge? _secondaryImeBridge;

  double _charWidth = 7.2;
  Timer? _fimDebounceTimer;

  List<GitLineDiff> _diffHunks = [];
  GitLineDiff? _activeHunkOverlay;

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

    _initSecondaryBridge();
    _fetchDiffHunks();
  }

  void _initSecondaryBridge() {
    if (widget.secondaryTab != null) {
      _secondaryImeBridge = ImeTextInputBridge(
        controller: widget.secondaryTab!.controller,
        focusNode: _secondaryFocusNode,
      );
      _secondaryFocusNode.addListener(() {
        if (_secondaryFocusNode.hasFocus) {
          _secondaryImeBridge?.attach();
        } else {
          _secondaryImeBridge?.detach();
        }
      });
    }
  }

  void _fetchDiffHunks() async {
    final client = widget.apiClient;
    if (client == null) return;
    try {
      final hunks = await client.getGitLineDiffs(widget.activeFile);
      if (mounted) {
        setState(() {
          _diffHunks = hunks;
        });
      }
    } catch (_) {}
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
      _scheduleFimQuery();
    };

    _controller.onCursorChanged = (pos) {
      if (_controller.hasGhostText && _controller.ghostPosition != pos) {
        _controller.clearGhostText();
      }
      _scheduleFimQuery();
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

    if (widget.activeFile != oldWidget.activeFile) {
      _fetchDiffHunks();
      _activeHunkOverlay = null;
    }

    if (widget.secondaryTab != oldWidget.secondaryTab) {
      _secondaryImeBridge?.detach();
      _initSecondaryBridge();
    }

    if (widget.controller != oldWidget.controller) {
      _fimDebounceTimer?.cancel();
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
    _fimDebounceTimer?.cancel();
    _imeBridge.detach();
    _secondaryImeBridge?.detach();
    _focusNode.dispose();
    _secondaryFocusNode.dispose();
    if (_ownsController) _controller.dispose();
    if (_ownsVerticalScroll) _verticalScroll.dispose();
    if (_ownsHorizontalScroll) _horizontalScroll.dispose();
    super.dispose();
  }

  void _scheduleFimQuery() {
    _fimDebounceTimer?.cancel();
    final client = widget.apiClient;
    if (client == null) return;

    _fimDebounceTimer = Timer(const Duration(milliseconds: 300), () async {
      if (!mounted) return;
      if (_controller.hasSelection) return;

      final reqPos = _controller.cursorPosition;
      final prefix = _controller.getPrefixForFim(1000);
      final suffix = _controller.getSuffixForFim(500);

      if (prefix.trim().isEmpty) return;

      final lang = widget.activeFile.endsWith('.dart')
          ? 'dart'
          : (widget.activeFile.endsWith('.rs')
              ? 'rust'
              : (widget.activeFile.endsWith('.ts') ? 'typescript' : 'go'));

      final suggestion = await client.fimComplete(
        widget.activeFile,
        prefix,
        suffix,
        lang,
      );

      if (!mounted) return;
      if (_controller.cursorPosition == reqPos && !_controller.hasSelection) {
        if (suggestion != null && suggestion.isNotEmpty) {
          _controller.setGhostText(suggestion, position: reqPos);
        } else {
          _controller.clearGhostText();
        }
      }
    });
  }

  KeyEventResult _handlePaneKeyEvent(
    CodeEditorController controller,
    ImeTextInputBridge? imeBridge,
    KeyEvent event, {
    required bool isPrimary,
  }) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    final isCmd = HardwareKeyboard.instance.isMetaPressed || HardwareKeyboard.instance.isControlPressed;
    final isShift = HardwareKeyboard.instance.isShiftPressed;
    final isAlt = HardwareKeyboard.instance.isAltPressed;

    // Shortcuts: Close active tab (Cmd+W / Ctrl+W)
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyW) {
      if (widget.onCloseActiveTab != null) {
        widget.onCloseActiveTab!.call();
      } else {
        widget.onCloseTab(widget.activeFile);
      }
      return KeyEventResult.handled;
    }

    // Shortcuts: Dismiss Ghost Text with Escape or close MiniDiffOverlay
    if (event.logicalKey == LogicalKeyboardKey.escape) {
      if (controller.hasGhostText) {
        controller.clearGhostText();
        return KeyEventResult.handled;
      }
      if (_activeHunkOverlay != null) {
        setState(() => _activeHunkOverlay = null);
        return KeyEventResult.handled;
      }
    }

    // Shortcuts: Save
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyS) {
      widget.onSave?.call();
      return KeyEventResult.handled;
    }

    // Shortcuts: Undo
    if (isCmd && !isShift && event.logicalKey == LogicalKeyboardKey.keyZ) {
      if (isPrimary && widget.onUndo != null) {
        widget.onUndo!.call();
      }
      return KeyEventResult.handled;
    }

    // Shortcuts: Redo
    if ((isCmd && isShift && event.logicalKey == LogicalKeyboardKey.keyZ) ||
        (isCmd && event.logicalKey == LogicalKeyboardKey.keyY)) {
      if (isPrimary && widget.onRedo != null) {
        widget.onRedo!.call();
      }
      return KeyEventResult.handled;
    }

    // Shortcuts: Select All
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyA) {
      controller.selectAll();
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }

    // Shortcuts: Copy
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyC) {
      controller.copy();
      return KeyEventResult.handled;
    }

    // Shortcuts: Cut
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyX) {
      controller.cut();
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }

    // Shortcuts: Paste
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyV) {
      controller.paste();
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }

    // Navigation: Arrows
    if (event.logicalKey == LogicalKeyboardKey.arrowLeft) {
      controller.moveCursor(
        direction: NavigationDirection.left,
        extendSelection: isShift,
        wordJump: isAlt,
        lineJump: isCmd,
      );
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowRight) {
      if (isCmd && controller.hasGhostText) {
        controller.acceptGhostTextWord();
        imeBridge?.syncState();
        return KeyEventResult.handled;
      }
      controller.moveCursor(
        direction: NavigationDirection.right,
        extendSelection: isShift,
        wordJump: isAlt,
        lineJump: isCmd,
      );
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
      controller.moveCursor(
        direction: NavigationDirection.up,
        extendSelection: isShift,
        documentJump: isCmd,
      );
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
      controller.moveCursor(
        direction: NavigationDirection.down,
        extendSelection: isShift,
        documentJump: isCmd,
      );
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }

    // Home / End
    if (event.logicalKey == LogicalKeyboardKey.home) {
      controller.moveCursor(direction: NavigationDirection.left, extendSelection: isShift, lineJump: true);
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.end) {
      controller.moveCursor(direction: NavigationDirection.right, extendSelection: isShift, lineJump: true);
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }

    // Backspace / Delete
    if (event.logicalKey == LogicalKeyboardKey.backspace) {
      controller.clearGhostText();
      controller.deleteBackward();
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      controller.clearGhostText();
      controller.deleteForward();
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }

    // Enter
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      controller.clearGhostText();
      controller.insertNewline();
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }

    // Tab / Shift+Tab
    if (event.logicalKey == LogicalKeyboardKey.tab) {
      if (!isShift && controller.hasGhostText) {
        controller.acceptGhostText();
        imeBridge?.syncState();
        return KeyEventResult.handled;
      }
      controller.clearGhostText();
      if (isShift) {
        controller.unindent();
      } else {
        controller.insertTab();
      }
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }

    // Printable character input
    if (!isCmd && event.character != null && event.character!.isNotEmpty) {
      final code = event.character!.codeUnitAt(0);
      if (code >= 32) {
        controller.clearGhostText();
        controller.insertText(event.character!);
        imeBridge?.syncState();
        return KeyEventResult.handled;
      }
    }

    return KeyEventResult.ignored;
  }

  Widget _buildFileTypeIcon(String filePath) {
    final ext = filePath.split('.').last.toLowerCase();
    switch (ext) {
      case 'rs':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
          decoration: BoxDecoration(
            color: const Color(0xFFD87642).withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: const Color(0xFFD87642), width: 0.8),
          ),
          child: const Text('rs', style: TextStyle(color: Color(0xFFD87642), fontSize: 9, fontWeight: FontWeight.bold)),
        );
      case 'dart':
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 3, vertical: 0.5),
          decoration: BoxDecoration(
            color: const Color(0xFF3574F0).withValues(alpha: 0.18),
            borderRadius: BorderRadius.circular(2),
            border: Border.all(color: const Color(0xFF3574F0), width: 0.8),
          ),
          child: const Text('dt', style: TextStyle(color: Color(0xFF3574F0), fontSize: 9, fontWeight: FontWeight.bold)),
        );
      case 'json':
      case 'toml':
      case 'yaml':
      case 'yml':
        return const Text('{ }', style: TextStyle(color: Color(0xFFE5C07B), fontSize: 10, fontWeight: FontWeight.bold));
      case 'md':
        return const Text('M↓', style: TextStyle(color: Color(0xFF6CB4F8), fontSize: 10, fontWeight: FontWeight.bold));
      default:
        return const Icon(Icons.insert_drive_file_outlined, size: 12, color: Color(0xFF8C8C8C));
    }
  }

  @override
  Widget build(BuildContext context) {
    final listenables = <Listenable>[
      _controller,
      if (widget.secondaryTab != null) widget.secondaryTab!.controller,
    ];

    return AnimatedBuilder(
      animation: Listenable.merge(listenables),
      builder: (context, _) {
        final isSplit = widget.splitDirection != SplitDirection.none && widget.secondaryTab != null;

        return Focus(
          focusNode: _focusNode,
          autofocus: true,
          onKeyEvent: (node, event) => _handlePaneKeyEvent(_controller, _imeBridge, event, isPrimary: true),
          child: Container(
            color: IntelliJTheme.editorBg,
            child: Column(
              children: [
                // 1. Tab Bar
                _buildTabBar(),

                // 2. Editor Panes
                Expanded(
                  child: isSplit
                      ? (widget.splitDirection == SplitDirection.horizontal
                          ? Row(
                              children: [
                                Expanded(
                                  child: _buildPane(
                                    controller: _controller,
                                    verticalScroll: _verticalScroll,
                                    horizontalScroll: _horizontalScroll,
                                    filePath: widget.activeFile,
                                    diagnostics: widget.diagnostics,
                                    focusNode: _focusNode,
                                    imeBridge: _imeBridge,
                                    isPrimary: true,
                                  ),
                                ),
                                Container(width: 1, color: IntelliJTheme.borderSubtle),
                                Expanded(
                                  child: _buildPane(
                                    controller: widget.secondaryTab!.controller,
                                    verticalScroll: widget.secondaryTab!.verticalScroll,
                                    horizontalScroll: widget.secondaryTab!.horizontalScroll,
                                    filePath: widget.secondaryTab!.filePath,
                                    diagnostics: widget.secondaryTab!.diagnostics,
                                    focusNode: _secondaryFocusNode,
                                    imeBridge: _secondaryImeBridge,
                                    isPrimary: false,
                                  ),
                                ),
                              ],
                            )
                          : Column(
                              children: [
                                Expanded(
                                  child: _buildPane(
                                    controller: _controller,
                                    verticalScroll: _verticalScroll,
                                    horizontalScroll: _horizontalScroll,
                                    filePath: widget.activeFile,
                                    diagnostics: widget.diagnostics,
                                    focusNode: _focusNode,
                                    imeBridge: _imeBridge,
                                    isPrimary: true,
                                  ),
                                ),
                                Container(height: 1, color: IntelliJTheme.borderSubtle),
                                Expanded(
                                  child: _buildPane(
                                    controller: widget.secondaryTab!.controller,
                                    verticalScroll: widget.secondaryTab!.verticalScroll,
                                    horizontalScroll: widget.secondaryTab!.horizontalScroll,
                                    filePath: widget.secondaryTab!.filePath,
                                    diagnostics: widget.secondaryTab!.diagnostics,
                                    focusNode: _secondaryFocusNode,
                                    imeBridge: _secondaryImeBridge,
                                    isPrimary: false,
                                  ),
                                ),
                              ],
                            ))
                      : _buildPane(
                          controller: _controller,
                          verticalScroll: _verticalScroll,
                          horizontalScroll: _horizontalScroll,
                          filePath: widget.activeFile,
                          diagnostics: widget.diagnostics,
                          focusNode: _focusNode,
                          imeBridge: _imeBridge,
                          isPrimary: true,
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
            child: ReorderableListView.builder(
              scrollDirection: Axis.horizontal,
              buildDefaultDragHandles: false,
              padding: EdgeInsets.zero,
              itemCount: widget.openTabs.length,
              onReorder: (oldIndex, newIndex) {
                widget.onReorderTabs?.call(oldIndex, newIndex);
              },
              itemBuilder: (context, index) {
                final path = widget.openTabs[index];
                final fileName = path.split('/').last;
                final isActive = path == widget.activeFile;
                final isDirty = widget.isTabDirty?.call(path) ?? (isActive && _controller.isDirty);

                return ReorderableDelayedDragStartListener(
                  key: ValueKey('tab_$path'),
                  index: index,
                  child: InkWell(
                    onTap: () => widget.onSelectTab(path),
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 10),
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
                          _buildFileTypeIcon(path),
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
                            const SizedBox(width: 5),
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
                  ),
                );
              },
            ),
          ),
          // Split Pane Action Icons
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Tooltip(
                message: 'Split Right (Horizontal)',
                child: InkWell(
                  onTap: () => widget.onSplitChange?.call(
                    widget.splitDirection == SplitDirection.horizontal
                        ? SplitDirection.none
                        : SplitDirection.horizontal,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    child: Icon(
                      Icons.vertical_split,
                      size: 14,
                      color: widget.splitDirection == SplitDirection.horizontal
                          ? IntelliJTheme.accentBlue
                          : IntelliJTheme.textMuted,
                    ),
                  ),
                ),
              ),
              Tooltip(
                message: 'Split Down (Vertical)',
                child: InkWell(
                  onTap: () => widget.onSplitChange?.call(
                    widget.splitDirection == SplitDirection.vertical
                        ? SplitDirection.none
                        : SplitDirection.vertical,
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                    child: Icon(
                      Icons.horizontal_split,
                      size: 14,
                      color: widget.splitDirection == SplitDirection.vertical
                          ? IntelliJTheme.accentBlue
                          : IntelliJTheme.textMuted,
                    ),
                  ),
                ),
              ),
              if (widget.splitDirection != SplitDirection.none)
                Tooltip(
                  message: 'Close Split',
                  child: InkWell(
                    onTap: () => widget.onCloseSplit?.call(),
                    child: const Padding(
                      padding: EdgeInsets.symmetric(horizontal: 6, vertical: 8),
                      child: Icon(
                        Icons.close_fullscreen,
                        size: 13,
                        color: IntelliJTheme.textMuted,
                      ),
                    ),
                  ),
                ),
              const SizedBox(width: 4),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildPane({
    required CodeEditorController controller,
    required ScrollController verticalScroll,
    required ScrollController horizontalScroll,
    required String filePath,
    required List<EditorDiagnostic> diagnostics,
    required FocusNode focusNode,
    required ImeTextInputBridge? imeBridge,
    required bool isPrimary,
  }) {
    final lines = controller.lines;

    Widget content = Column(
      children: [
        _buildSubHeader(
          lines.length,
          filePath: filePath,
          isPrimary: isPrimary,
          isDirty: controller.isDirty,
        ),
        Expanded(
          child: Stack(
            children: [
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Expanded(
                    child: SingleChildScrollView(
                      controller: verticalScroll,
                      child: Row(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          _buildGutter(lines.length, diagnostics: diagnostics),
                          _buildGitDiffStripe(
                            lines.length,
                            hunks: isPrimary ? _diffHunks : const [],
                            onHunkTap: (hunk) {
                              if (isPrimary) {
                                setState(() {
                                  if (_activeHunkOverlay?.line == hunk.line) {
                                    _activeHunkOverlay = null;
                                  } else {
                                    _activeHunkOverlay = hunk;
                                  }
                                });
                              }
                            },
                          ),
                          Expanded(
                            child: SingleChildScrollView(
                              controller: horizontalScroll,
                              scrollDirection: Axis.horizontal,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (details) {
                                  focusNode.requestFocus();
                                  imeBridge?.attach();
                                  final line = (details.localPosition.dy / 20.0).floor();
                                  final col = (details.localPosition.dx / _charWidth).round();
                                  controller.setCursor(EditorPosition(line, col));
                                  imeBridge?.syncState();
                                },
                                onDoubleTapDown: (details) {
                                  final line = (details.localPosition.dy / 20.0).floor();
                                  final col = (details.localPosition.dx / _charWidth).round();
                                  controller.selectWord(EditorPosition(line, col));
                                  imeBridge?.syncState();
                                },
                                onPanStart: (details) {
                                  focusNode.requestFocus();
                                  final line = (details.localPosition.dy / 20.0).floor();
                                  final col = (details.localPosition.dx / _charWidth).round();
                                  controller.setCursor(EditorPosition(line, col));
                                  imeBridge?.syncState();
                                },
                                onPanUpdate: (details) {
                                  final line = (details.localPosition.dy / 20.0).floor();
                                  final col = (details.localPosition.dx / _charWidth).round();
                                  controller.setCursor(EditorPosition(line, col), extendSelection: true);
                                  imeBridge?.syncState();
                                },
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      ...lines.asMap().entries.map((entry) {
                                        return _buildCodeLine(
                                          entry.key,
                                          entry.value,
                                          controller: controller,
                                          filePath: filePath,
                                          diagnostics: diagnostics,
                                          showGhost: isPrimary,
                                        );
                                      }),
                                      if (isPrimary) _buildAiGhostHint(),
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
                  _buildRightErrorStripe(lines.length, diagnostics: diagnostics),
                ],
              ),
              if (isPrimary) _buildMiniDiffOverlay(),
            ],
          ),
        ),
      ],
    );

    if (!isPrimary) {
      return Focus(
        focusNode: focusNode,
        onKeyEvent: (node, event) => _handlePaneKeyEvent(controller, imeBridge, event, isPrimary: false),
        child: content,
      );
    }

    return content;
  }

  Widget _buildSubHeader(
    int lineCount, {
    required String filePath,
    required bool isPrimary,
    required bool isDirty,
  }) {
    final segments = filePath.split('/').where((s) => s.isNotEmpty).toList();

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
                  if (isPrimary && widget.activeSymbol != null && widget.activeSymbol!.isNotEmpty) ...[
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
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                '$lineCount lines • UTF-8${isDirty ? ' • Modified' : ''}',
                style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10),
              ),
              if (!isPrimary) ...[
                const SizedBox(width: 8),
                InkWell(
                  onTap: () => widget.onCloseSplit?.call(),
                  child: const Tooltip(
                    message: 'Close Split Pane',
                    child: Icon(Icons.close, size: 13, color: IntelliJTheme.textMuted),
                  ),
                ),
              ],
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGutter(int totalLines, {required List<EditorDiagnostic> diagnostics}) {
    return Container(
      width: 48,
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: IntelliJTheme.editorBg,
      child: Column(
        children: List.generate(totalLines, (index) {
          final lineDiags = diagnostics.where((d) => d.line == index).toList();
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

  Widget _buildGitDiffStripe(
    int totalLines, {
    required List<GitLineDiff> hunks,
    required ValueChanged<GitLineDiff> onHunkTap,
  }) {
    return Container(
      width: 5,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(
        children: List.generate(totalLines, (index) {
          final lineNum = index + 1;
          final hunk = hunks.cast<GitLineDiff?>().firstWhere(
            (h) => h?.line == lineNum,
            orElse: () => null,
          );

          Color color = Colors.transparent;
          if (hunk != null) {
            switch (hunk.kind) {
              case DiffHunkKind.added:
                color = const Color(0xFF59A869);
                break;
              case DiffHunkKind.modified:
                color = const Color(0xFF3574F0);
                break;
              case DiffHunkKind.deleted:
                color = const Color(0xFFDB5860);
                break;
            }
          }

          Widget stripe = Container(height: 20, color: color);

          if (hunk != null) {
            return Tooltip(
              message: '${hunk.kind.name.toUpperCase()} (Line ${hunk.line}) - Click to inspect diff',
              child: GestureDetector(
                behavior: HitTestBehavior.opaque,
                onTap: () => onHunkTap(hunk),
                child: stripe,
              ),
            );
          }

          return stripe;
        }),
      ),
    );
  }

  Widget _buildMiniDiffOverlay() {
    if (_activeHunkOverlay == null) return const SizedBox.shrink();
    final hunk = _activeHunkOverlay!;
    final topOffset = ((hunk.line - 1) * 20.0).clamp(0.0, 450.0);

    Color badgeColor = const Color(0xFF3574F0);
    if (hunk.kind == DiffHunkKind.added) badgeColor = const Color(0xFF59A869);
    if (hunk.kind == DiffHunkKind.deleted) badgeColor = const Color(0xFFDB5860);

    return Positioned(
      top: topOffset,
      left: 56,
      right: 20,
      child: Material(
        elevation: 8,
        color: Colors.transparent,
        child: Container(
          decoration: BoxDecoration(
            color: const Color(0xFF2B2D30),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: badgeColor, width: 1.2),
            boxShadow: const [
              BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4)),
            ],
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                decoration: const BoxDecoration(
                  color: Color(0xFF1E1F22),
                  borderRadius: BorderRadius.vertical(top: Radius.circular(5)),
                  border: Border(bottom: BorderSide(color: Color(0xFF393B40))),
                ),
                child: Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.2),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: badgeColor, width: 0.8),
                      ),
                      child: Text(
                        hunk.kind.name.toUpperCase(),
                        style: TextStyle(color: badgeColor, fontSize: 10, fontWeight: FontWeight.bold),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Text(
                      'Line ${hunk.line}',
                      style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 11, fontWeight: FontWeight.w600),
                    ),
                    const Spacer(),
                    InkWell(
                      onTap: () async {
                        final client = widget.apiClient;
                        if (client != null) {
                          await client.gitRevertFile(widget.activeFile);
                        }
                        widget.onRevertFile?.call(widget.activeFile);
                        setState(() {
                          _activeHunkOverlay = null;
                        });
                        _fetchDiffHunks();
                      },
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: const Color(0xFF353B48),
                          borderRadius: BorderRadius.circular(4),
                          border: Border.all(color: const Color(0xFF4C5052), width: 0.8),
                        ),
                        child: const Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(Icons.undo, size: 11, color: Color(0xFF6CB4F8)),
                            SizedBox(width: 4),
                            Text('Revert', style: TextStyle(color: Color(0xFF6CB4F8), fontSize: 10, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    InkWell(
                      onTap: () => setState(() => _activeHunkOverlay = null),
                      child: const Icon(Icons.close, size: 14, color: IntelliJTheme.textMuted),
                    ),
                  ],
                ),
              ),
              Padding(
                padding: const EdgeInsets.all(8),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    if (hunk.originalContent.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        color: const Color(0xFF3C1F24),
                        child: Text(
                          '- ${hunk.originalContent}',
                          style: const TextStyle(
                            color: Color(0xFFFF8B8B),
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                    if (hunk.newContent.isNotEmpty)
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        color: const Color(0xFF1D3528),
                        child: Text(
                          '+ ${hunk.newContent}',
                          style: const TextStyle(
                            color: Color(0xFF70D28E),
                            fontFamily: 'monospace',
                            fontSize: 11,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildCodeLine(
    int lineIndex,
    String lineText, {
    required CodeEditorController controller,
    required String filePath,
    required List<EditorDiagnostic> diagnostics,
    required bool showGhost,
  }) {
    final lang = filePath.endsWith('.dart') ? 'dart' : 'rust';
    final spans = SyntaxHighlighter.highlightLine(lineText, language: lang);

    final lineDiags = diagnostics.where((d) => d.line == lineIndex).toList();
    final hasError = lineDiags.any((d) => d.isError);
    final hasWarning = lineDiags.any((d) => d.isWarning);

    final sel = controller.selection;
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

    final isCaretLine = lineIndex == controller.cursorPosition.line;
    final caretCol = controller.cursorPosition.col;

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

          // 2.5 AI Ghost Text (Inline at Caret)
          if (showGhost &&
              isCaretLine &&
              controller.hasGhostText &&
              controller.ghostPosition?.line == lineIndex &&
              controller.ghostPosition?.col == caretCol) ...[
            Positioned(
              left: (caretCol * _charWidth).clamp(0.0, 99999.0),
              top: 0,
              bottom: 0,
              child: IgnorePointer(
                child: Text(
                  controller.ghostText!.split('\n').first,
                  style: const TextStyle(
                    fontSize: 12,
                    fontFamily: 'monospace',
                    fontStyle: FontStyle.italic,
                    height: 1.4,
                    color: Color(0xFF6E7681),
                  ),
                ),
              ),
            ),
            if (controller.ghostText!.contains('\n'))
              Positioned(
                left: 0,
                top: 20,
                child: IgnorePointer(
                  child: Text(
                    controller.ghostText!.split('\n').skip(1).join('\n'),
                    style: const TextStyle(
                      fontSize: 12,
                      fontFamily: 'monospace',
                      fontStyle: FontStyle.italic,
                      height: 1.666667,
                      color: Color(0xFF6E7681),
                    ),
                  ),
                ),
              ),
          ],

          // 3. Caret (Blinking Cursor)
          if (isCaretLine && controller.cursorVisible)
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

  Widget _buildAiGhostHint() {
    if (!_controller.hasGhostText) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF1E222B),
        borderRadius: BorderRadius.circular(4),
        border: Border.all(color: const Color(0xFF353B47), width: 0.8),
      ),
      child: const Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.auto_awesome, size: 11, color: Color(0xFF6CB4F8)),
          SizedBox(width: 6),
          Text(
            'FIM Suggestion',
            style: TextStyle(color: Color(0xFF6CB4F8), fontSize: 10, fontWeight: FontWeight.w600),
          ),
          SizedBox(width: 8),
          Text(
            '[Tab] to accept  •  [Cmd/Ctrl+→] word  •  [Esc] dismiss',
            style: TextStyle(color: Color(0xFF8B949E), fontSize: 10, fontFamily: 'monospace'),
          ),
        ],
      ),
    );
  }

  Widget _buildRightErrorStripe(int totalLines, {required List<EditorDiagnostic> diagnostics}) {
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
              ...diagnostics.map((d) {
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
