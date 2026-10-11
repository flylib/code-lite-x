import 'package:flutter/foundation.dart';

import 'syntax/color_schemes.dart';

/// Blame 注释栏的着色方式(View ▸ Colors)。
enum BlameColorMode { none, author, age }

/// Blame 注释栏里作者名的显示方式(View ▸ Names)。
enum BlameNameMode { full, first, last, initials, email }

/// Markdown 文件的显示方式(标签栏右边的三个按钮):只看源码、源码 | 预览、只看预览。
enum MarkdownViewMode { editor, split, preview }

/// 编辑器外观开关,所有标签页共用(与 IntelliJ 一样是编辑器级设置,不跟文件走)。
class EditorAppearance extends ChangeNotifier {
  /// 编辑区字号(行高随之按比例变化)。
  static const double defaultFontSize = 12;
  static const double minFontSize = 9;
  static const double maxFontSize = 28;
  double _fontSize = defaultFontSize;

  /// 代码配色方案 id(见 [builtinColorSchemes])。默认 Islands Dark,和 IDE 外框一致。
  String _colorSchemeId = 'islands';

  /// 设置文件里配色字段的版本。版本 2 起默认是 Islands Dark;更早的文件里的 darcula 只是当时的默认值,读入时换成新默认。
  static const int _schemeVersion = 2;

  bool _showLineNumbers = true;
  bool _showIndentGuides = true;
  bool _showBreadcrumbs = true;

  bool _blameRevision = false;
  bool _blameDate = true;
  bool _blameAuthor = true;
  BlameColorMode _blameColors = BlameColorMode.author;
  BlameNameMode _blameNames = BlameNameMode.full;
  MarkdownViewMode _markdownMode = MarkdownViewMode.split;

  double get fontSize => _fontSize;

  /// 每行的高度:字号的 1.65 倍取整(12 → 20,与原来的固定行高一致)。
  double get lineHeight => (_fontSize * 1.65).roundToDouble();

  String get colorSchemeId => _colorSchemeId;
  EditorColorScheme get colorScheme => colorSchemeById(_colorSchemeId);

  void setFontSize(double v) {
    final clamped = v.clamp(minFontSize, maxFontSize).roundToDouble();
    if (clamped == _fontSize) return;
    _set(() => _fontSize = clamped);
  }

  void setColorScheme(String id) {
    if (id == _colorSchemeId || !builtinColorSchemes.any((s) => s.id == id)) return;
    _set(() => _colorSchemeId = id);
  }

  bool get showLineNumbers => _showLineNumbers;
  bool get showIndentGuides => _showIndentGuides;
  bool get showBreadcrumbs => _showBreadcrumbs;
  bool get blameRevision => _blameRevision;
  bool get blameDate => _blameDate;
  bool get blameAuthor => _blameAuthor;
  BlameColorMode get blameColors => _blameColors;
  BlameNameMode get blameNames => _blameNames;

  MarkdownViewMode get markdownMode => _markdownMode;

  void setMarkdownMode(MarkdownViewMode mode) {
    if (mode == _markdownMode) return;
    _set(() => _markdownMode = mode);
  }

  void setShowLineNumbers(bool v) => _set(() => _showLineNumbers = v);
  void setShowIndentGuides(bool v) => _set(() => _showIndentGuides = v);
  void setShowBreadcrumbs(bool v) => _set(() => _showBreadcrumbs = v);

  /// 持久化用(设置文件里的 `editor.appearance`)。
  Map<String, dynamic> toJson() => {
        'fontSize': _fontSize,
        'colorScheme': _colorSchemeId,
        'schemeVersion': _schemeVersion,
        'lineNumbers': _showLineNumbers,
        'indentGuides': _showIndentGuides,
        'breadcrumbs': _showBreadcrumbs,
        'blameRevision': _blameRevision,
        'blameDate': _blameDate,
        'blameAuthor': _blameAuthor,
        'blameColors': _blameColors.name,
        'blameNames': _blameNames.name,
        'markdownMode': _markdownMode.name,
      };

  /// 读入设置文件里的值;缺的或类型不对的项保持当前值。
  void applyJson(Map<String, dynamic> j) {
    bool b(String k, bool current) => j[k] is bool ? j[k] as bool : current;
    final size = j['fontSize'];
    if (size is num && size >= minFontSize && size <= maxFontSize) _fontSize = size.toDouble().roundToDouble();
    final scheme = j['colorScheme'];
    final oldDefault = scheme == 'darcula' && j['schemeVersion'] == null;
    if (scheme is String && !oldDefault && builtinColorSchemes.any((s) => s.id == scheme)) _colorSchemeId = scheme;
    _showLineNumbers = b('lineNumbers', _showLineNumbers);
    _showIndentGuides = b('indentGuides', _showIndentGuides);
    _showBreadcrumbs = b('breadcrumbs', _showBreadcrumbs);
    final rev = b('blameRevision', _blameRevision), date = b('blameDate', _blameDate), author = b('blameAuthor', _blameAuthor);
    if (rev || date || author) {
      _blameRevision = rev;
      _blameDate = date;
      _blameAuthor = author;
    }
    _blameColors = BlameColorMode.values.firstWhere((m) => m.name == j['blameColors'], orElse: () => _blameColors);
    _blameNames = BlameNameMode.values.firstWhere((m) => m.name == j['blameNames'], orElse: () => _blameNames);
    _markdownMode = MarkdownViewMode.values.firstWhere((m) => m.name == j['markdownMode'], orElse: () => _markdownMode);
    notifyListeners();
  }

  void toggleLineNumbers() => _set(() => _showLineNumbers = !_showLineNumbers);
  void toggleIndentGuides() => _set(() => _showIndentGuides = !_showIndentGuides);
  void toggleBreadcrumbs() => _set(() => _showBreadcrumbs = !_showBreadcrumbs);

  /// 三项至少留一项,否则注释栏就是一条空白。
  void toggleBlameRevision() => _toggleBlameField(() => _blameRevision = !_blameRevision);
  void toggleBlameDate() => _toggleBlameField(() => _blameDate = !_blameDate);
  void toggleBlameAuthor() => _toggleBlameField(() => _blameAuthor = !_blameAuthor);

  void setBlameColors(BlameColorMode mode) => _set(() => _blameColors = mode);
  void setBlameNames(BlameNameMode mode) => _set(() => _blameNames = mode);

  void _toggleBlameField(VoidCallback flip) {
    flip();
    if (!_blameRevision && !_blameDate && !_blameAuthor) {
      flip(); // 撤回:不允许全部关掉
      return;
    }
    notifyListeners();
  }

  void _set(VoidCallback change) {
    change();
    notifyListeners();
  }
}
