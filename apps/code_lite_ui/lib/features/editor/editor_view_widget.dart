import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/gestures.dart' show kPrimaryButton;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'blame.dart';
import 'context_menu_region.dart';
import 'editor_appearance.dart';
import '../../core/client/api_client.dart';
import '../../core/theme/app_icons.dart';
import '../../core/theme/intellij_theme.dart';
import 'code_editor_controller.dart';
import 'editor_session_manager.dart';
import 'ime_text_input_client.dart';
import 'lsp_overlay.dart';
import 'markdown/markdown_links.dart';
import 'markdown/markdown_preview.dart';
import 'visible_lines.dart';
import 'syntax/document_highlighter.dart';
import 'syntax/language.dart';
import 'syntax/languages.dart';

/// 差异标签的 id 前缀:`diff:<相对仓库根的路径>`。
const String diffTabPrefix = 'diff:';

/// Pull Request 的差异标签(`prdiff:<号>`)与 Timeline 标签(`prtl:<号>`)。
const String prDiffTabPrefix = 'prdiff:';
const String prTimelineTabPrefix = 'prtl:';

/// 不对应文件的特殊标签(内容由 [EditorViewWidget.specialTabBuilder] 提供)。
bool isSpecialTabId(String id) =>
    id.startsWith(diffTabPrefix) || id.startsWith(prDiffTabPrefix) || id.startsWith(prTimelineTabPrefix);

class EditorViewWidget extends StatefulWidget {
  /// 测试用:标签栏构建次数(验证按键不重建标签栏)。
  @visibleForTesting
  static int debugTabBarBuilds = 0;

  final List<String> openTabs;
  final String activeFile;
  final String codeContent;
  final String? activeSymbol;
  final List<EditorDiagnostic> diagnostics;
  final ValueChanged<String> onSelectTab;
  final ValueChanged<String> onCloseTab;
  /// 文本变了。传了它就会在每次按键时拼一次全文,大文件里能不传就不传。
  final ValueChanged<String>? onCodeChanged;

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

  /// 特殊标签的标题(如 PR Timeline 显示「PR 标题 #号」);返回 null 用默认标题。
  final String? Function(String tabId)? specialTabTitle;

  /// 标签栏与编辑区之间的提示条(比如「安装 Java 插件」);只对普通文件标签显示。
  final Widget? Function(String filePath)? bannerBuilder;

  /// Markdown 预览里点了指向本地文件的链接:在编辑器里打开它(绝对路径)。
  final ValueChanged<String>? onOpenFile;

  /// 预览用到的系统能力(测试里替换)。
  final MarkdownEnv markdownEnv;

  /// 编辑区右上角浮着的按钮(HTML 文件的「用浏览器打开」);返回 null 不显示。每个面板按自己的文件问一次。
  final Widget? Function(String filePath)? paneActionsBuilder;

  const EditorViewWidget({
    super.key,
    this.projectName = '',
    this.appearance,
    this.onShowInHistory,
    this.specialTabBuilder,
    this.specialTabTitle,
    this.bannerBuilder,
    this.paneActionsBuilder,
    this.onOpenFile,
    this.markdownEnv = const MarkdownEnv(),
    required this.openTabs,
    required this.activeFile,
    required this.codeContent,
    this.activeSymbol,
    this.diagnostics = const [],
    required this.onSelectTab,
    required this.onCloseTab,
    this.onCodeChanged,
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

  /// 代码行的文字样式:渲染与测量必须用同一个,光标 / 选区 / 点击才能对齐字形。字号来自设置。
  TextStyle get _codeStyle => TextStyle(
        fontSize: _appearance.fontSize,
        height: IntelliJMetrics.codeLineHeight,
        fontFamily: IntelliJMetrics.codeFontFamily,
        fontFamilyFallback: IntelliJMetrics.codeFontFallback,
      );

  /// 代码区内边距(点击坐标要先减掉它)。
  static const double _padH = 12, _padV = 8;

  /// 行高:随字号变化(12 号字 → 20px)。
  double get _lineHeight => _appearance.lineHeight;

  /// 上次测量字宽时的字号;字号变了要重新测量,并作废按旧字号排好的行。
  double _measuredFontSize = 0;

  /// 当前是 Markdown 文件、而且选的是「只看预览」:编辑器不显示,也不能接收输入。
  bool get _previewOnly =>
      _appearance.markdownMode == MarkdownViewMode.preview &&
      isMarkdownFile(widget.activeFile) &&
      !isSpecialTabId(widget.activeFile) &&
      !(widget.splitDirection != SplitDirection.none && widget.secondaryTab != null);

  /// 预览模式下断开输入法(否则敲键盘会改到看不见的文档),切回来再接上。
  void _syncImeForMode() {
    if (_previewOnly) {
      _imeBridge.detach();
    } else if (_focusNode.hasFocus) {
      _imeBridge.attach();
    }
  }

  late MarkdownViewMode _lastMarkdownMode; // initState 里赋值:late 初始化器是第一次读取时才跑,那时已经是新值了

  void _onAppearanceChanged() {
    if (mounted && _lastMarkdownMode != _appearance.markdownMode) {
      _lastMarkdownMode = _appearance.markdownMode;
      setState(() {}); // Markdown 显示方式变了
      _syncImeForMode();
    }
    if (_appearance.fontSize == _measuredFontSize) return;
    _measureCharWidth();
    for (final p in _linePainters.values) {
      p.dispose();
    }
    _linePainters.clear();
  }

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
    _lastMarkdownMode = _appearance.markdownMode;
    _appearance.addListener(_onAppearanceChanged);

    _imeBridge = ImeTextInputBridge(
      controller: _controller,
      focusNode: _focusNode,
    );

    _focusNode.addListener(() {
      if (_focusNode.hasFocus) {
        if (!_previewOnly) _imeBridge.attach();
      } else {
        _imeBridge.detach();
      }
    });

    _initSecondaryBridge();
    _fetchDiffHunks();
    // 保存后行号栏的改动标记(相对 HEAD)要跟着更新。
    _savedSub = widget.apiClient?.onFileSaved.listen((path) {
      if (path == widget.activeFile) _fetchDiffHunks();
    });
  }

  StreamSubscription<String>? _savedSub;

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

  void _onControllerText() {
    widget.onCodeChanged?.call(_controller.text);
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
    _measuredFontSize = _appearance.fontSize;
    final painter = TextPainter(
      text: TextSpan(text: 'M', style: _codeStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    if (painter.width > 0) {
      _charWidth = painter.width;
    }
    painter.dispose();
    final digits = TextPainter(
      text: TextSpan(text: '0000000000', style: _gutterNumberStyle),
      textDirection: TextDirection.ltr,
    )..layout();
    if (digits.width > 0) _gutterDigitWidth = digits.width / 10;
    digits.dispose();
  }

  TextStyle get _gutterNumberStyle => TextStyle(
        color: _appearance.colorScheme.lineNumber,
        fontSize: _appearance.fontSize - 1,
        fontFamily: IntelliJMetrics.codeFontFamily,
        fontFamilyFallback: IntelliJMetrics.codeFontFallback,
      );
  double _gutterDigitWidth = 7;

  /// 代码区宽度(横向滚动长度):按最长一行估算 —— 全角字符算两格、Tab 算四格。
  /// 不逐行排版(那正是要避免的整文件开销);同一版文本只算一次。
  /// 内容宽度:最宽一行的列数由文本模型增量维护,这里只做换算(O(1))。
  double _contentWidth(CodeEditorController controller) => controller.maxColumns * _charWidth + 2 * _padH + 48;

  /// 关掉的文档(controller 已释放)不能再被缓存攥着:高亮缓存一个 2 万行的文件就有约 30 MB。
  /// 以前只有缓存里超过两个文档时才清理,关掉标签、甚至换了项目之后旧文档还一直留着。
  void _dropClosedDocuments() {
    _highlighters.removeWhere((controller, _) => controller.isDisposed);
    _blame.removeWhere((controller, session) {
      if (!controller.isDisposed) return false;
      session.dispose(controller);
      return true;
    });
  }

  /// 测试用:缓存里还挂着的文档。
  @visibleForTesting
  Set<CodeEditorController> get debugCachedDocuments => {..._highlighters.keys, ..._blame.keys};

  /// 每个文档(controller)一份高亮缓存;分屏两侧各自一份。
  final Map<CodeEditorController, DocumentHighlighter> _highlighters = {};

  /// 按文件名(无扩展名时看首行 #!)识别语言,并刷新该文档的高亮缓存。
  DocumentHighlighter _highlightFor(CodeEditorController controller, String filePath, List<String> lines) {
    final lang = languageOf(filePath, lines);
    // 按键只重建窗格、不走整个 build,所以这里也清一次(缓存里最多两三个文档,不费事)
    _dropClosedDocuments();
    // 只保留当前两侧在用的文档:关掉的标签不再占着缓存。
    if (_highlighters.length > 2 && !_highlighters.containsKey(controller)) {
      _highlighters.removeWhere((c, _) => c != _controller && c != widget.secondaryTab?.controller);
    }
    return _highlighters.putIfAbsent(controller, DocumentHighlighter.new)..update(lang, lines, scheme: _appearance.colorScheme);
  }

  static LanguageSpec languageOf(String filePath, List<String> lines) =>
      languages.detect(filePath, firstLine: lines.isEmpty ? null : lines.first);

  TextPainter _painterFor(DocumentHighlighter hl, int line, String lineText) {
    final key = '${hl.language?.id}\u0000${hl.startStateAt(line)}\u0000$lineText';
    final cached = _linePainters.remove(key);
    if (cached != null) return _linePainters[key] = cached; // 重新插入 = 标为最近使用
    if (_linePainters.length >= 512) {
      _linePainters.remove(_linePainters.keys.first)!.dispose();
    }
    return _linePainters[key] = TextPainter(
      text: TextSpan(style: _codeStyle, children: hl.spansAt(line)),
      textDirection: TextDirection.ltr,
      maxLines: 1,
    )..layout();
  }

  /// 第 [line] 行第 [col] 列(字符偏移)左边缘的 x 坐标。
  double _xForCol(DocumentHighlighter hl, int line, String lineText, int col) {
    if (col <= 0 || lineText.isEmpty) return 0;
    final c = math.min(col, lineText.length);
    return _painterFor(hl, line, lineText).getOffsetForCaret(TextPosition(offset: c), Rect.zero).dx;
  }

  /// 代码区内的点击坐标 → 行列(取离点击点最近的字符边界)。
  EditorPosition _positionAt(Offset local, List<String> lines, DocumentHighlighter hl) {
    if (lines.isEmpty) return const EditorPosition(0, 0);
    final line = ((local.dy - _padV) / _lineHeight).floor().clamp(0, lines.length - 1);
    final x = local.dx - _padH;
    final text = lines[line];
    if (x <= 0 || text.isEmpty) return EditorPosition(line, 0);
    final col = _painterFor(hl, line, text).getPositionForOffset(Offset(x, _lineHeight / 2)).offset;
    return EditorPosition(line, col);
  }

  @override
  void didUpdateWidget(EditorViewWidget oldWidget) {
    super.didUpdateWidget(oldWidget);

    if (widget.activeFile != oldWidget.activeFile) {
      _fetchDiffHunks();
      _activeHunkOverlay = null;
      _syncImeForMode();
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
    } else if (_ownsController &&
        widget.codeContent != oldWidget.codeContent &&
        widget.codeContent != _controller.text) {
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
    _appearance.removeListener(_onAppearanceChanged);
    _savedSub?.cancel();
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

    // 只看预览时编辑器不显示:除了关标签、保存,别的按键都不能落到看不见的文档上
    if (isPrimary && _previewOnly) {
      if (isCmd && event.logicalKey == LogicalKeyboardKey.keyW) {
        widget.onCloseActiveTab != null ? widget.onCloseActiveTab!.call() : widget.onCloseTab(widget.activeFile);
        return KeyEventResult.handled;
      }
      if (isCmd && event.logicalKey == LogicalKeyboardKey.keyS) {
        widget.onSave?.call();
        return KeyEventResult.handled;
      }
      return KeyEventResult.ignored;
    }

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

  /// 一个编辑面板:只订阅它自己的 controller 和外观设置。按键 / 光标移动只重建这一块,
  /// 标签栏等外层不动(标签上的「已修改」圆点随会话层的 dirty 变化刷新)。
  Widget _paneFor({
    required CodeEditorController controller,
    required ScrollController verticalScroll,
    required ScrollController horizontalScroll,
    required String filePath,
    required List<EditorDiagnostic> diagnostics,
    required FocusNode focusNode,
    required ImeTextInputBridge? imeBridge,
    required bool isPrimary,
  }) {
    return ListenableBuilder(
      listenable: Listenable.merge([_appearance, controller]),
      builder: (context, _) => _buildPane(
        controller: controller,
        verticalScroll: verticalScroll,
        horizontalScroll: horizontalScroll,
        filePath: filePath,
        diagnostics: diagnostics,
        focusNode: focusNode,
        imeBridge: imeBridge,
        isPrimary: isPrimary,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    _dropClosedDocuments();
    final isSplit = widget.splitDirection != SplitDirection.none && widget.secondaryTab != null;
    Widget primary() => _paneFor(
          controller: _controller,
          verticalScroll: _verticalScroll,
          horizontalScroll: _horizontalScroll,
          filePath: widget.activeFile,
          diagnostics: widget.diagnostics,
          focusNode: _focusNode,
          imeBridge: _imeBridge,
          isPrimary: true,
        );
    Widget secondary() => _paneFor(
          controller: widget.secondaryTab!.controller,
          verticalScroll: widget.secondaryTab!.verticalScroll,
          horizontalScroll: widget.secondaryTab!.horizontalScroll,
          filePath: widget.secondaryTab!.filePath,
          diagnostics: widget.secondaryTab!.diagnostics,
          focusNode: _secondaryFocusNode,
          imeBridge: _secondaryImeBridge,
          isPrimary: false,
        );

    // 没有外部提供的 dirty 查询时,标签栏的「已修改」圆点只能看 controller:这时才让它订阅 controller。
    final tabBar = widget.isTabDirty != null
        ? _buildTabBar()
        : ListenableBuilder(listenable: _controller, builder: (context, _) => _buildTabBar());

    return Focus(
      focusNode: _focusNode,
      autofocus: true,
      onKeyEvent: (node, event) => _handlePaneKeyEvent(_controller, _imeBridge, event, isPrimary: true),
      child: Container(
        color: IntelliJTheme.editorBg,
        child: Column(
          children: [
            // 1. Tab Bar
            tabBar,
            if (widget.activeFile.isNotEmpty && !isSpecialTabId(widget.activeFile))
              widget.bannerBuilder?.call(widget.activeFile) ?? const SizedBox.shrink(),

            // 2. Editor Panes(非文件标签换成它自己的内容,比如差异视图)
            Expanded(
              child: widget.specialTabBuilder?.call(widget.activeFile) ??
                  (!isSplit
                      ? _markdownAware(primary)
                      : widget.splitDirection == SplitDirection.horizontal
                          ? Row(
                              children: [
                                Expanded(child: primary()),
                                Container(width: 1, color: IntelliJTheme.borderSubtle),
                                Expanded(child: secondary()),
                              ],
                            )
                          : Column(
                              children: [
                                Expanded(child: primary()),
                                Container(height: 1, color: IntelliJTheme.borderSubtle),
                                Expanded(child: secondary()),
                              ],
                            )),
            ),
          ],
        ),
      ),
    );
  }

  /// Markdown 文件按选的显示方式摆:编辑器 / 编辑器 | 预览 / 预览。其它文件就是编辑器。
  Widget _markdownAware(Widget Function() editor) {
    final file = widget.activeFile;
    if (!isMarkdownFile(file) || isSpecialTabId(file)) return editor();
    Widget preview({required bool synced}) => MarkdownPreview(
          key: ValueKey('markdown-preview-$file'),
          controller: _controller,
          filePath: file,
          root: widget.apiClient?.rootPath ?? '',
          scheme: _appearance.colorScheme,
          syncWith: synced ? _verticalScroll : null,
          onOpenFile: widget.onOpenFile,
          env: widget.markdownEnv,
        );
    return switch (_appearance.markdownMode) {
      MarkdownViewMode.editor => editor(),
      MarkdownViewMode.preview => preview(synced: false),
      MarkdownViewMode.split => Row(
          children: [
            Expanded(child: editor()),
            Container(width: 1, color: IntelliJTheme.borderSubtle),
            Expanded(child: preview(synced: true)),
          ],
        ),
    };
  }

  /// 标签栏右边的三个按钮:Editor Only / Editor and Preview / Preview Only(只有 Markdown 文件才显示)。
  Widget _markdownModeButtons() {
    Widget button(MarkdownViewMode mode, IconData icon, String tip) {
      final active = _appearance.markdownMode == mode;
      return Tooltip(
        message: tip,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          key: ValueKey('markdown-mode-${mode.name}'),
          onTap: () => _appearance.setMarkdownMode(mode),
          borderRadius: BorderRadius.circular(5),
          child: Container(
            width: 26,
            height: 24,
            alignment: Alignment.center,
            decoration: active ? BoxDecoration(color: IntelliJTheme.hoverBg, borderRadius: BorderRadius.circular(5)) : null,
            child: Icon(icon, size: 16, color: active ? IntelliJTheme.textHigh : IntelliJTheme.textMuted),
          ),
        ),
      );
    }

    return Padding(
      padding: const EdgeInsets.only(right: 6),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          button(MarkdownViewMode.editor, Icons.notes, 'Editor Only'),
          button(MarkdownViewMode.split, Icons.chrome_reader_mode_outlined, 'Editor and Preview'),
          button(MarkdownViewMode.preview, Icons.visibility_outlined, 'Preview Only'),
          const SizedBox(width: 4),
          Container(width: 1, height: 16, color: IntelliJTheme.border),
        ],
      ),
    );
  }

  Widget _buildTabBar() {
    EditorViewWidget.debugTabBarBuilds++;
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
                final isDiffTab = path.startsWith(diffTabPrefix) || path.startsWith(prDiffTabPrefix);
                final isPrTimeline = path.startsWith(prTimelineTabPrefix);
                final fileName = widget.specialTabTitle?.call(path) ??
                    (path.startsWith(diffTabPrefix)
                        ? 'Commit: ${path.split('/').last}'
                        : path.startsWith(prDiffTabPrefix)
                            ? 'Diff for Pull Request #${path.substring(prDiffTabPrefix.length)}'
                            : isPrTimeline
                                ? 'Pull Request #${path.substring(prTimelineTabPrefix.length)}'
                                : path.split('/').last);
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
                          else if (isPrTimeline)
                            const PullRequestIcon(color: Color(0xFF5FB865), size: 14)
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
          if (isMarkdownFile(widget.activeFile) && !isSpecialTabId(widget.activeFile)) _markdownModeButtons(),
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
    final showGuides = _appearance.showIndentGuides;
    final highlighter = _highlightFor(controller, filePath, lines);
    // 按行号建好索引:行号栏 / 代码行每行直接查,不再各自把整张诊断列表扫一遍。
    final diagByLine = <int, List<EditorDiagnostic>>{};
    for (final d in diagnostics) {
      (diagByLine[d.line] ??= []).add(d);
    }

    Widget content = Column(
      children: [
        _buildSubHeader(
          lines.length,
          filePath: filePath,
          isPrimary: isPrimary,
          isDirty: controller.isDirty,
        ),
        Expanded(
          child: ColoredBox(
          // 代码区底色跟随配色方案
          color: _appearance.colorScheme.background,
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
                              lineHeight: _lineHeight,
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
                              ((pos.dy - 8) / _lineHeight).floor().clamp(0, lines.length - 1),
                            ),
                            child: _buildGutter(lines.length, diagByLine: diagByLine, controller: controller),
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
                                onDoubleTapDown: (details) {
                                  final pos = _positionAt(details.localPosition, lines, highlighter);
                                  controller.selectWord(pos);
                                  imeBridge?.syncState();
                                },
                                onPanStart: (details) {
                                  focusNode.requestFocus();
                                  final pos = _positionAt(details.localPosition, lines, highlighter);
                                  controller.setCursor(pos);
                                  imeBridge?.syncState();
                                },
                                onPanUpdate: (details) {
                                  final pos = _positionAt(details.localPosition, lines, highlighter);
                                  controller.setCursor(pos, extendSelection: true);
                                  imeBridge?.syncState();
                                },
                                // 光标在鼠标按下的那一刻就放过去(IntelliJ 如此)。用 Listener 而不是 onTapDown:
                                // 这里同时有双击(选词)和拖动(选区),单击要等手势竞争判定(约 100 ms)才触发,
                                // 点完光标「慢半拍」跟过来。Listener 放在手势识别的里层,先收到按下:
                                // 双击的第二下由双击识别随后选词,不会被这里放回光标。右键不动光标。
                                child: Listener(
                                behavior: HitTestBehavior.opaque,
                                onPointerDown: (event) {
                                  if (event.buttons != kPrimaryButton) return;
                                  focusNode.requestFocus();
                                  imeBridge?.attach();
                                  final pos = _positionAt(event.localPosition, lines, highlighter);
                                  controller.setCursor(pos);
                                  imeBridge?.syncState();
                                },
                                // 代码区至少铺满视口:点击最长行右侧的空白也能把光标放到该行末尾。
                                // 高度按全部行数给足(滚动条长度正确),里面只摆视口附近的行。
                                child: ConstrainedBox(
                                constraints: BoxConstraints(minWidth: viewport.maxWidth),
                                child: SizedBox(
                                  width: _contentWidth(controller),
                                  height: lines.length * _lineHeight + 2 * _padV,
                                  child: VisibleLines(
                                    lineCount: lines.length,
                                    lineHeight: _lineHeight,
                                    topPadding: _padV,
                                    builder: (context, first, last) {
                                      final guides = showGuides ? _indentLevelsRange(lines, first, last) : null;
                                      return Stack(
                                        clipBehavior: Clip.none,
                                        children: [
                                          for (var i = first; i <= last; i++)
                                            Positioned(
                                              key: ValueKey(i),
                                              top: _padV + i * _lineHeight,
                                              left: _padH,
                                              height: _lineHeight,
                                              child: _buildCodeLine(
                                                i,
                                                lines[i],
                                                guideLevel: guides?[i - first] ?? 0,
                                                controller: controller,
                                                highlighter: highlighter,
                                                diagnostics: diagByLine[i] ?? const [],
                                              ),
                                            ),
                                        ],
                                      );
                                    },
                                  ),
                                ),
                                ),
                              ),
                              ), // Listener
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
              // 右上角的浮动按钮:让开右边的错误条
              if (widget.paneActionsBuilder?.call(filePath) case final actions?)
                Positioned(top: 8, right: errorStripeWidth + 8, child: actions),
            ],
          ),
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

  /// 行号栏宽度:按最大行号的位数加宽(1000 行以上时四位数不再被截掉)。
  double _gutterWidthFor(int totalLines) {
    final digits = math.max(3, '$totalLines'.length);
    // 书签 14 + 左右留白 + 诊断圆点 10 + 数字
    return math.max(58, 2 + 14 + 10 + digits * _gutterDigitWidth + 8).ceilToDouble();
  }

  Widget _buildGutter(
    int totalLines, {
    required Map<int, List<EditorDiagnostic>> diagByLine,
    required CodeEditorController controller,
  }) {
    final bookmarks = controller.bookmarks;
    final showNumbers = _appearance.showLineNumbers;
    return Container(
      // 关掉行号后仍留出书签 / 诊断标记的位置。
      width: showNumbers ? _gutterWidthFor(totalLines) : 30,
      padding: const EdgeInsets.symmetric(vertical: 8),
      color: _appearance.colorScheme.background,
      child: SizedBox(
        height: totalLines * _lineHeight,
        child: VisibleLines(
          lineCount: totalLines,
          lineHeight: _lineHeight,
          topPadding: 8,
          builder: (context, first, last) => Stack(
            children: [
              for (var index = first; index <= last; index++)
                Positioned(
                  key: ValueKey(index),
                  top: index * _lineHeight,
                  left: 0,
                  right: 0,
                  height: _lineHeight,
                  child: _gutterRow(index, diagByLine[index] ?? const [], bookmarks, showNumbers),
                ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _gutterRow(int index, List<EditorDiagnostic> lineDiags, Map<int, String?> bookmarks, bool showNumbers) {
    final hasError = lineDiags.any((d) => d.isError);
    final hasWarning = lineDiags.any((d) => d.isWarning);
    final hasBookmark = bookmarks.containsKey(index);
    final mnemonic = bookmarks[index];
    return SizedBox(
      height: _lineHeight,
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
            Text('${index + 1}', style: _gutterNumberStyle),
          const SizedBox(width: 6),
        ],
      ),
    );
  }

  static const int _indentUnit = 4;

  /// [first]..[last] 每行的缩进层级(按 4 列一级,tab 记 4 列)。空行取上下非空行中较小的层级,
  /// 这样代码块中间的空行也有连续的参考线。只看可见行及其邻近的非空行,不扫整个文件。
  static List<int> _indentLevelsRange(List<String> lines, int first, int last) {
    if (last < first) return const [];
    int? levelOf(int i) => lines[i].trim().isEmpty ? null : _indentOf(lines[i]);
    final out = List<int>.filled(last - first + 1, 0);
    int? prev;
    for (var j = first - 1; j >= 0; j--) {
      final l = levelOf(j);
      if (l != null) {
        prev = l;
        break;
      }
    }
    int? next;
    var nextAt = -1; // 已找到的「下一个非空行」位置,连续空行共用
    for (var i = first; i <= last; i++) {
      final l = levelOf(i);
      if (l != null) {
        prev = l;
        out[i - first] = l;
        continue;
      }
      if (nextAt <= i) {
        next = null;
        for (var j = i + 1; j < lines.length; j++) {
          final n = levelOf(j);
          if (n != null) {
            next = n;
            nextAt = j;
            break;
          }
        }
        if (next == null) nextAt = lines.length;
      }
      out[i - first] = (prev == null || next == null) ? 0 : (prev < next ? prev : next);
    }
    return out;
  }

  static int _indentOf(String l) {
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
    final target = (line * _lineHeight - scroll.position.viewportDimension / 3).clamp(0.0, scroll.position.maxScrollExtent);
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
    session.listener = () {
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
    // 按行号(1 起)索引,每行直接查。
    final byLine = {for (final h in hunks) h.line: h};
    return Container(
      width: 5,
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: SizedBox(
        height: totalLines * _lineHeight,
        child: VisibleLines(
        lineCount: totalLines,
        lineHeight: _lineHeight,
        topPadding: 8,
        builder: (context, first, last) => Stack(
        children: [for (var index = first; index <= last; index++)
          if (byLine[index + 1] case final hunk?)
            Positioned(
              key: ValueKey(index),
              top: index * _lineHeight,
              left: 0,
              right: 0,
              height: _lineHeight,
              child: _stripeCell(hunk, onHunkTap),
            ),
        ],
        ),
        ),
      ),
    );
  }

  Widget _stripeCell(GitLineDiff hunk, ValueChanged<GitLineDiff> onHunkTap) {
    final color = switch (hunk.kind) {
      DiffHunkKind.added => const Color(0xFF59A869),
      DiffHunkKind.modified => const Color(0xFF3574F0),
      DiffHunkKind.deleted => const Color(0xFFDB5860),
    };
    return Tooltip(
      message: '${hunk.kind.name.toUpperCase()} (Line ${hunk.line}) - Click to inspect diff',
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: () => onHunkTap(hunk),
        child: Container(height: _lineHeight, color: color),
      ),
    );
  }

  Widget _buildMiniDiffOverlay() {
    if (_activeHunkOverlay == null) return const SizedBox.shrink();
    final hunk = _activeHunkOverlay!;
    final topOffset = ((hunk.line - 1) * _lineHeight).clamp(0.0, 450.0);

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
    required DocumentHighlighter highlighter,
    required List<EditorDiagnostic> diagnostics,
    int guideLevel = 0,
  }) {
    final hl = highlighter;

    final lineDiags = diagnostics.where((d) => d.line == lineIndex).toList();
    // 没用到的变量 / 字段 / import:文字变灰,不画下划线(IntelliJ 的做法)
    final spans = colorDiagnosticRanges(hl.spansAt(lineIndex), lineText, lineDiags, lineIndex);
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
      height: _lineHeight,
      child: Stack(
        clipBehavior: Clip.none,
        children: [
          // 0. 缩进参考线:每个缩进层级一条细竖线(含空行,取上下文的层级)。
          for (var k = 0; k < guideLevel; k++)
            Positioned(
              left: k * _indentUnit * _charWidth,
              top: 0,
              bottom: 0,
              child: Container(width: 1, color: _appearance.colorScheme.indentGuide),
            ),

          // 1. Selection Highlight Box
          if (isLineSelected && selEndCol > selStartCol)
            Positioned(
              left: _xForCol(hl, lineIndex, lineText, selStartCol),
              width: _xForCol(hl, lineIndex, lineText, selEndCol) - _xForCol(hl, lineIndex, lineText, selStartCol),
              top: 0,
              bottom: 0,
              child: Container(
                color: _appearance.colorScheme.selection,
              ),
            ),

          // 2. Syntax Token Text
          RichText(
            text: TextSpan(style: _codeStyle.copyWith(color: _appearance.colorScheme.foreground), children: spans),
            softWrap: false,
            overflow: TextOverflow.clip,
          ),

          // 3. Caret (Blinking Cursor)
          if (isCaretLine)
            Positioned(
              left: _xForCol(hl, lineIndex, lineText, caretCol),
              top: 2,
              bottom: 2,
              // 只有这一块随闪烁重绘
              child: ValueListenableBuilder<bool>(
                valueListenable: controller.caretBlink,
                builder: (context, visible, _) => Container(
                  width: 2,
                  color: visible ? _appearance.colorScheme.caret : Colors.transparent,
                ),
              ),
            ),

          // 4. Diagnostic Squiggle
          // 只有普通警告画下划线;错误是把出问题的词染红(见 colorDiagnosticRanges),没用到的符号是变灰
          if (hasWarning)
            Positioned(
              left: 0,
              right: 0,
              bottom: 2,
              child: Container(
                height: 2,
                decoration: const BoxDecoration(
                  border: Border(bottom: BorderSide(color: Color(0xFFE5C07B), width: 1.5)),
                ),
              ),
            ),
        ],
      ),
    );

    // 没用到的变量 / 字段 / import 只变灰,不弹提示(IntelliJ 也是这样);
    // 这一行里如果还有真正的错误 / 警告,提示显示它们的消息。
    final tipDiags = lineDiags.where((d) => !d.isUnnecessary);
    if (tipDiags.isNotEmpty) {
      final diag = tipDiags.first;
      return Tooltip(
        message: '[${diag.code ?? (diag.isError ? "Error" : "Warning")}] ${diag.message}',
        child: lineContent,
      );
    }

    return lineContent;
  }



  /// 编辑区最右边的错误条(IntelliJ 的 error stripe):错误 / 警告在整个文件里的位置。
  /// 用户要求窄一点:8px,标记条两边各留 1px。
  static const double errorStripeWidth = 8;

  Widget _buildRightErrorStripe(int totalLines, {required List<EditorDiagnostic> diagnostics}) {
    return Container(
      width: errorStripeWidth,
      decoration: const BoxDecoration(
        color: Color(0xFF26282E),
        border: Border(left: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: LayoutBuilder(
        builder: (context, constraints) {
          final height = constraints.maxHeight;
          return Stack(
            children: [
              ...diagnostics.where((d) => !d.isUnnecessary).map((d) {
                final topPos = totalLines > 0 ? (d.line / totalLines) * height : 0.0;
                return Positioned(
                  top: topPos.clamp(0.0, height - 4),
                  left: 1,
                  right: 1,
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
  VoidCallback? listener;

  void dispose(CodeEditorController controller) {
    timer?.cancel();
    final l = listener;
    if (l != null) controller.removeTextListener(l);
  }
}
