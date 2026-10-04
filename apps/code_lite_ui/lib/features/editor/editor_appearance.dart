import 'package:flutter/foundation.dart';

/// Blame 注释栏的着色方式(View ▸ Colors)。
enum BlameColorMode { none, author, age }

/// Blame 注释栏里作者名的显示方式(View ▸ Names)。
enum BlameNameMode { full, first, last, initials, email }

/// 编辑器外观开关,所有标签页共用(与 IntelliJ 一样是编辑器级设置,不跟文件走)。
class EditorAppearance extends ChangeNotifier {
  bool _showLineNumbers = true;
  bool _showIndentGuides = true;
  bool _showBreadcrumbs = true;

  bool _blameRevision = false;
  bool _blameDate = true;
  bool _blameAuthor = true;
  BlameColorMode _blameColors = BlameColorMode.author;
  BlameNameMode _blameNames = BlameNameMode.full;

  bool get showLineNumbers => _showLineNumbers;
  bool get showIndentGuides => _showIndentGuides;
  bool get showBreadcrumbs => _showBreadcrumbs;
  bool get blameRevision => _blameRevision;
  bool get blameDate => _blameDate;
  bool get blameAuthor => _blameAuthor;
  BlameColorMode get blameColors => _blameColors;
  BlameNameMode get blameNames => _blameNames;

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
