import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'blame.dart';
import 'context_menu_region.dart';
import 'editor_appearance.dart';
import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';
import 'code_editor_controller.dart';
import 'editor_session_manager.dart';
import 'ime_text_input_client.dart';
import 'lsp_overlay.dart';
import 'syntax_highlighter.dart';

/// 差异标签的 id 前缀:`diff:<相对仓库根的路径>`。
const String diffTabPrefix = 'diff:';

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

  /// 面包屑的根:当前项目目录名。没打开项目时为空,不显示根节点。
  final String projectName;

  /// 编辑器外观(行号 / 缩进参考线 / 面包屑 / blame 显示项),所有标签共用。
  final EditorAppearance? appearance;

  /// Blame 菜单的 Show in File History:打开 Git Log 并按文件筛选、选中该提交。
  final void Function(String hash, String path)? onShowInHistory;

  /// 非文件标签(比如 `diff:路径` 的「Commit: 文件名」差异视图)的内容。返回 null 表示按普通文件处理。
  final Widget? Function(String tabId)? specialTabBuilder;

  const EditorViewWidget({
    super.key,
    this.projectName = '',
    this.appearance,
    this.onShowInHistory,
    this.specialTabBuilder,
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

  /// 代码行的文字样式:渲染与测量必须用同一个,光标 / 选区 / 点击才能对齐字形。
  static const TextStyle _codeStyle = TextStyle(
    fontSize: IntelliJMetrics.codeFontSize,
    height: IntelliJMetrics.codeLineHeight,
    fontFamily: IntelliJMetrics.codeFontFamily,
    fontFamilyFallback: IntelliJMetrics.codeFontFallback,
  );

  /// 代码区内边距(点击坐标要先减掉它)。
  static const double _padH = 12, _padV = 8, _lineHeight = 20;

  /// 行文本 → 排好版的 TextPainter(LRU)。光标、选区、点击定位都按真实字形宽度测量,
  /// 中文等全角字符、Tab、回退字体都不会再让光标和插入点错位。
  final Map<String, TextPainter> _linePainters = {};

  List<GitLineDiff> _diffHunks = [];
  GitLineDiff? _activeHunkOverlay;

  late final EditorAppearance _appearance = widget.appearance ?? EditorAppearance();

  /// 打开了 blame 注释的编辑器(按 controller 区分:分屏两侧各自开关)。
  final Map<CodeEditorController, _BlameSession> _blame = {};

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

    _controller.addTextListener(_onControllerText);
  }

  void _onControllerText(String newText) {
    widget.onCodeChanged(newText);
    _imeBridge.syncState();
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
      text: const TextSpan(text: 'M', style: _codeStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    if (painter.width > 0) {
      _charWidth = painter.width;
    }
    painter.dispose();
  }

  static String _langOf(String filePath) => filePath.endsWith('.dart') ? 'dart' : 'rust';

  TextPainter _painterFor(String lineText, String lang) {
    final key = '$lang\u0000$lineText';
    final cached = _linePainters.remove(key);
    if (cached != null) return _linePainters[key] = cached; // 重新插入 = 标为最近使用
    if (_linePainters.length >= 512) {
      _linePainters.remove(_linePainters.keys.first)!.dispose();
    }
    return _linePainters[key] = TextPainter(
      text: TextSpan(style: _codeStyle, children: SyntaxHighlighter.highlightLine(lineText, language: lang)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
  }

  /// 第 [col] 列(字符偏移)左边缘的 x 坐标。
  double _xForCol(String lineText, int col, String lang) {
    if (col <= 0 || lineText.isEmpty) return 0;
    final c = math.min(col, lineText.length);
    return _painterFor(lineText, lang).getOffsetForCaret(TextPosition(offset: c), Rect.zero).dx;
  }

  /// 代码区内的点击坐标 → 行列(取离点击点最近的字符边界)。
  EditorPosition _positionAt(Offset local, List<String> lines, String lang) {
    if (lines.isEmpty) return const EditorPosition(0, 0);
    final line = ((local.dy - _padV) / _lineHeight).floor().clamp(0, lines.length - 1);
    final x = local.dx - _padH;
    final text = lines[line];
    if (x <= 0 || text.isEmpty) return EditorPosition(line, 0);
    final col = _painterFor(text, lang).getPositionForOffset(Offset(x, _lineHeight / 2)).offset;
    return EditorPosition(line, col);
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
      _controller.removeTextListener(_onControllerText);
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
    for (final p in _linePainters.values) {
      p.dispose();
    }
    _linePainters.clear();
    _imeBridge.detach();
    _secondaryImeBridge?.detach();
    _focusNode.dispose();
    _secondaryFocusNode.dispose();
    _controller.removeTextListener(_onControllerText);
    for (final entry in _blame.entries) {
      entry.value.dispose(entry.key);
    }
    if (widget.appearance == null) _appearance.dispose();
    if (_ownsController) _controller.dispose();
    if (_ownsVerticalScroll) _verticalScroll.dispose();
    if (_ownsHorizontalScroll) _horizontalScroll.dispose();
    super.dispose();
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
    final isCtrl = HardwareKeyboard.instance.isControlPressed;
    final isMeta = HardwareKeyboard.instance.isMetaPressed;

    // 书签:F3 开关、⌥F3 助记书签、⌃数字 跳到对应助记书签(与 IntelliJ 一致)。
    if (event.logicalKey == LogicalKeyboardKey.f3 && !isCmd && !isShift) {
      final line = controller.cursorPosition.line;
      if (isAlt) {
        _editMnemonic(controller, line);
      } else {
        controller.toggleBookmark(line);
      }
      return KeyEventResult.handled;
    }
    if (isCtrl && !isMeta && !isAlt && !isShift) {
      final label = event.logicalKey.keyLabel;
      if (label.length == 1 && RegExp(r'[0-9]').hasMatch(label)) {
        final target = controller.lineOfMnemonic(label);
        if (target != null) {
          _jumpToLine(controller, target);
          imeBridge?.syncState();
        }
        return KeyEventResult.handled;
      }
    }

    // Shortcuts: Close active tab (Cmd+W / Ctrl+W)
    if (isCmd && event.logicalKey == LogicalKeyboardKey.keyW) {
      if (widget.onCloseActiveTab != null) {
        widget.onCloseActiveTab!.call();
      } else {
        widget.onCloseTab(widget.activeFile);
      }
      return KeyEventResult.handled;
    }

    // Shortcuts: Escape closes MiniDiffOverlay
    if (event.logicalKey == LogicalKeyboardKey.escape) {
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
    // 撤销历史在 controller 里,直接作用于当前面板 —— 分屏的副面板也能撤销。
    if (isCmd && !isShift && event.logicalKey == LogicalKeyboardKey.keyZ) {
      controller.undo();
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }

    // Shortcuts: Redo
    if ((isCmd && isShift && event.logicalKey == LogicalKeyboardKey.keyZ) ||
        (isCmd && event.logicalKey == LogicalKeyboardKey.keyY)) {
      controller.redo();
      imeBridge?.syncState();
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
      controller.deleteBackward();
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }
    if (event.logicalKey == LogicalKeyboardKey.delete) {
      controller.deleteForward();
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }

    // Enter
    if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
      controller.insertNewline();
      imeBridge?.syncState();
      return KeyEventResult.handled;
    }

    // Tab / Shift+Tab
    if (event.logicalKey == LogicalKeyboardKey.tab) {
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
      _appearance,
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

                // 2. Editor Panes(非文件标签换成它自己的内容,比如差异视图)
                Expanded(
                  child: widget.specialTabBuilder?.call(widget.activeFile) ?? (isSplit
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
                        )),
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
                final isDiffTab = path.startsWith(diffTabPrefix);
                final fileName = isDiffTab ? 'Commit: ${path.split('/').last}' : path.split('/').last;
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
                          if (isDiffTab)
                            const Icon(Icons.compare_arrows, size: 14, color: IntelliJTheme.accentBlue)
                          else
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
    final guides = _appearance.showIndentGuides ? _indentLevels(lines) : null;

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
                          if (_blame.containsKey(controller) && widget.apiClient != null)
                            BlameColumn(
                              data: _blame[controller]!.data,
                              loading: _blame[controller]!.loading,
                              appearance: _appearance,
                              totalLines: lines.length,
                              menuBuilder: (line, commit) => blameMenu(
                                context: context,
                                commit: commit,
                                appearance: _appearance,
                                client: widget.apiClient!,
                                onClose: () => _toggleBlame(controller, filePath),
                                onShowInHistory: widget.onShowInHistory,
                              ),
                            ),
                          ContextMenuRegion(
                            menuBuilder: (pos) => _gutterMenu(
                              controller,
                              filePath,
                              ((pos.dy - 8) / 20).floor().clamp(0, lines.length - 1),
                            ),
                            child: _buildGutter(lines.length, diagnostics: diagnostics, controller: controller),
                          ),
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
                            child: LayoutBuilder(
                              builder: (context, viewport) => SingleChildScrollView(
                              controller: horizontalScroll,
                              scrollDirection: Axis.horizontal,
                              child: GestureDetector(
                                behavior: HitTestBehavior.opaque,
                                onTapDown: (details) {
                                  focusNode.requestFocus();
                                  imeBridge?.attach();
                                  final pos = _positionAt(details.localPosition, lines, _langOf(filePath));
                                  controller.setCursor(pos);
                                  imeBridge?.syncState();
                                },
                                onDoubleTapDown: (details) {
                                  final pos = _positionAt(details.localPosition, lines, _langOf(filePath));
                                  controller.selectWord(pos);
                                  imeBridge?.syncState();
                                },
                                onPanStart: (details) {
                                  focusNode.requestFocus();
                                  final pos = _positionAt(details.localPosition, lines, _langOf(filePath));
                                  controller.setCursor(pos);
                                  imeBridge?.syncState();
                                },
                                onPanUpdate: (details) {
                                  final pos = _positionAt(details.localPosition, lines, _langOf(filePath));
                                  controller.setCursor(pos, extendSelection: true);
                                  imeBridge?.syncState();
                                },
                                // 代码区至少铺满视口:点击最长行右侧的空白也能把光标放到该行末尾。
                                child: ConstrainedBox(
                                constraints: BoxConstraints(minWidth: viewport.maxWidth),
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(horizontal: _padH, vertical: _padV),
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      ...lines.asMap().entries.map((entry) {
                                        return _buildCodeLine(
                                          entry.key,
                                          entry.value,
                                          guideLevel: guides?[entry.key] ?? 0,
                                          controller: controller,
                                          filePath: filePath,
                                          diagnostics: diagnostics,
                                        );
                                      }),
                                    ],
                                  ),
                                ),
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
            child: !_appearance.showBreadcrumbs
                ? const SizedBox.shrink()
                : SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  if (widget.projectName.isNotEmpty) ...[
                    const Icon(Icons.folder_open, size: 12, color: IntelliJTheme.accentYellow),
                    const SizedBox(width: 4),
                    Text(widget.projectName, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11)),
                  ],
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

  Widget _buildGutter(
    int totalLines, {
    required List<EditorDiagnostic> diagnostics,
    required CodeEditorController controller,
  }) {
    final bookmarks = controller.bookmarks;
    final showNumbers = _appearance.showLineNumbers;
    return Container(
      // 关掉行号后仍留出书签 / 诊断标记的位置。
      width: showNumbers ? 58 : 30,
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: IntelliJTheme.editorBg,
      child: Column(
        children: List.generate(totalLines, (index) {
          final lineDiags = diagnostics.where((d) => d.line == index).toList();
          final hasError = lineDiags.any((d) => d.isError);
          final hasWarning = lineDiags.any((d) => d.isWarning);

          final hasBookmark = bookmarks.containsKey(index);
          final mnemonic = bookmarks[index];
          return SizedBox(
            height: 20,
            child: Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                const SizedBox(width: 2),
                SizedBox(
                  width: 14,
                  child: !hasBookmark
                      ? null
                      : mnemonic == null
                          ? const Icon(Icons.bookmark, size: 13, color: Color(0xFF8C9AB8))
                          : Container(
                              height: 14,
                              alignment: Alignment.center,
                              decoration: BoxDecoration(
                                color: const Color(0xFF3C4A63),
                                borderRadius: BorderRadius.circular(3),
                                border: Border.all(color: const Color(0xFF8C9AB8)),
                              ),
                              child: Text(
                                mnemonic,
                                style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 9, fontWeight: FontWeight.bold),
                              ),
                            ),
                ),
                const Spacer(),
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
                if (showNumbers)
                  Text(
                    '${index + 1}',
                    style: const TextStyle(
                      color: IntelliJTheme.textGutter,
                      fontSize: 11,
                      fontFamily: IntelliJMetrics.codeFontFamily,
                      fontFamilyFallback: IntelliJMetrics.codeFontFallback,
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

  static const int _indentUnit = 4;

  /// 每行的缩进层级(按 4 列一级,tab 记 4 列)。空行取上下非空行中较小的层级,
  /// 这样代码块中间的空行也有连续的参考线。
  static List<int> _indentLevels(List<String> lines) {
    int indentOf(String l) {
      var cols = 0;
      for (final c in l.codeUnits) {
        if (c == 0x20) {
          cols++;
        } else if (c == 0x09) {
          cols += _indentUnit;
        } else {
          break;
        }
      }
      return cols ~/ _indentUnit;
    }

    final levels = List<int?>.generate(lines.length, (i) => lines[i].trim().isEmpty ? null : indentOf(lines[i]));
    final result = List<int>.filled(lines.length, 0);
    int? prev;
    for (var i = 0; i < lines.length; i++) {
      final l = levels[i];
      if (l != null) {
        prev = l;
        result[i] = l;
        continue;
      }
      int? next;
      for (var j = i + 1; j < lines.length; j++) {
        if (levels[j] != null) {
          next = levels[j];
          break;
        }
      }
      result[i] = (prev == null || next == null) ? 0 : (prev < next ? prev : next);
    }
    return result;
  }

  /// 行号栏右键菜单。
  List<Widget> _gutterMenu(CodeEditorController controller, String filePath, int line) {
    final hasBookmark = controller.hasBookmark(line);
    final mnemonic = controller.bookmarks[line];
    final blameOn = _blame.containsKey(controller);
    return [
      MenuItemButton(
        onPressed: widget.apiClient == null ? null : () => _toggleBlame(controller, filePath),
        child: Text(blameOn ? 'Close Annotations' : 'Annotate with Git Blame'),
      ),
      const MenuDivider(),
      MenuItemButton(
        shortcut: const SingleActivator(LogicalKeyboardKey.f3),
        onPressed: () => controller.toggleBookmark(line),
        child: Text(hasBookmark ? 'Remove Bookmark' : 'Add Bookmark'),
      ),
      MenuItemButton(
        shortcut: const SingleActivator(LogicalKeyboardKey.f3, alt: true),
        onPressed: () => _editMnemonic(controller, line),
        child: Text(mnemonic == null ? 'Add Mnemonic Bookmark…' : 'Edit Mnemonic Bookmark…'),
      ),
      const MenuDivider(),
      SubmenuButton(
        menuChildren: [
          CheckboxMenuButton(
            value: _appearance.showLineNumbers,
            onChanged: (_) => _appearance.toggleLineNumbers(),
            child: const Text('Show Line Numbers'),
          ),
          CheckboxMenuButton(
            value: _appearance.showIndentGuides,
            onChanged: (_) => _appearance.toggleIndentGuides(),
            child: const Text('Show Indent Guides'),
          ),
          CheckboxMenuButton(
            value: _appearance.showBreadcrumbs,
            onChanged: (_) => _appearance.toggleBreadcrumbs(),
            child: const Text('Breadcrumbs'),
          ),
        ],
        child: const Text('Appearance'),
      ),
    ];
  }

  Future<void> _editMnemonic(CodeEditorController controller, int line) async {
    final current = controller.bookmarks[line];
    final taken = {for (final m in controller.bookmarks.values) if (m != null) m};
    final picked = await pickMnemonic(context, current: current, taken: taken);
    if (picked == null || !mounted) return;
    controller.setMnemonicBookmark(line, picked);
  }

  void _jumpToLine(CodeEditorController controller, int line) {
    controller.setCursor(EditorPosition(line, 0));
    final scroll = identical(controller, _controller) ? _verticalScroll : widget.secondaryTab?.verticalScroll;
    if (scroll == null || !scroll.hasClients) return;
    final target = (line * 20.0 - scroll.position.viewportDimension / 3).clamp(0.0, scroll.position.maxScrollExtent);
    scroll.jumpTo(target);
  }

  /// 打开 / 关闭 blame 注释。打开期间文本变化会防抖重算(带上未保存的内容),行号始终对得上。
  void _toggleBlame(CodeEditorController controller, String filePath) {
    final existing = _blame.remove(controller);
    if (existing != null) {
      existing.dispose(controller);
      setState(() {});
      return;
    }
    final session = _BlameSession();
    session.listener = (_) {
      session.timer?.cancel();
      session.timer = Timer(const Duration(milliseconds: 600), () => _loadBlame(controller, filePath, session));
    };
    controller.addTextListener(session.listener!);
    setState(() => _blame[controller] = session);
    _loadBlame(controller, filePath, session);
  }

  Future<void> _loadBlame(CodeEditorController controller, String filePath, _BlameSession session) async {
    final client = widget.apiClient;
    if (client == null) return;
    setState(() => session.loading = true);
    final data = await BlameData.load(client, filePath, contents: controller.isDirty ? controller.text : null);
    if (!mounted || _blame[controller] != session) return;
    setState(() {
      session.loading = false;
      session.data = data;
    });
    if (data == null) {
      ScaffoldMessenger.maybeOf(context)?.showSnackBar(
        SnackBar(content: Text('无法获取 $filePath 的 Git Blame(文件不在 Git 仓库中或尚未提交)')),
      );
      _blame.remove(controller)?.dispose(controller);
      setState(() {});
    }
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
    int guideLevel = 0,
  }) {
    final lang = _langOf(filePath);
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
          // 0. 缩进参考线:每个缩进层级一条细竖线(含空行,取上下文的层级)。
          for (var k = 0; k < guideLevel; k++)
            Positioned(
              left: k * _indentUnit * _charWidth,
              top: 0,
              bottom: 0,
              child: Container(width: 1, color: const Color(0xFF393B40)),
            ),

          // 1. Selection Highlight Box
          if (isLineSelected && selEndCol > selStartCol)
            Positioned(
              left: _xForCol(lineText, selStartCol, lang),
              width: _xForCol(lineText, selEndCol, lang) - _xForCol(lineText, selStartCol, lang),
              top: 0,
              bottom: 0,
              child: Container(
                color: const Color(0xFF214283),
              ),
            ),

          // 2. Syntax Token Text
          RichText(
            text: TextSpan(style: _codeStyle, children: spans),
            overflow: TextOverflow.clip,
          ),

          // 3. Caret (Blinking Cursor)
          if (isCaretLine && controller.cursorVisible)
            Positioned(
              left: _xForCol(lineText, caretCol, lang),
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

class _BlameSession {
  BlameData? data;
  bool loading = false;
  Timer? timer;
  void Function(String)? listener;

  void dispose(CodeEditorController controller) {
    timer?.cancel();
    final l = listener;
    if (l != null) controller.removeTextListener(l);
  }
}
