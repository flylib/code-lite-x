import 'package:flutter/foundation.dart';

import '../../features/bottom_tools/bottom_tools_widget.dart';

/// 左侧工具窗(活动条上半段选择的那一栏)。
enum LeftTool { project, commit, pullRequests, structure, build }

/// 左侧工具窗放在哪一块(IntelliJ 的 Move To ▸ Left Top / Left Bottom):
/// 上下两块各开一个时,左栏上下拆分同时显示。
enum ToolSlot { top, bottom }

/// 面板显隐与选中项。只放"哪个面板开着、选中了什么",
/// 不放文件内容 —— 那些在 [WorkspaceStore] 与 EditorSessionManager 里。
///
/// 拆成独立 store 的原因:敲一个字符不应该重建项目树和底部日志。
/// 布局变化和编辑变化各自通知各自的订阅者。
class LayoutStore extends ChangeNotifier {
  LeftTool _leftTool = LeftTool.project;
  BottomToolTab _bottomTab = BottomToolTab.git;
  bool _isLeftOpen = true;
  // 底部工具窗默认收起:打开 Git 窗口会立刻跑 git log,不该为用户还没要看的面板付这个代价。
  bool _isBottomOpen = false;
  double _bottomHeight = 300;
  double _leftWidth = 250;

  /// 放到左下方的工具窗;不在里面的都在左上方。
  final Set<LeftTool> _bottomSlot = {};
  LeftTool? _leftBottomTool;
  bool _isLeftBottomOpen = false;

  /// 上下拆分时上半块占的比例。
  double _leftSplit = 0.5;

  /// 左侧工具窗(项目 / Commit / 结构)共用一个宽度,拖动分隔线调整;切换工具窗时不跳变。
  static const double minLeftWidth = 160;

  /// 底部工具窗高度,拖动分隔条调整。Git Log 这类视图在 220 高度下只看得到几行。
  static const double minBottomHeight = 140;

  /// 上下拆分时每块至少占的比例。
  static const double minLeftSplit = 0.15;

  /// 左上方最近选中的工具窗([isLeftOpen] 为假时不显示)。
  LeftTool get leftTool => _leftTool;
  BottomToolTab get bottomTab => _bottomTab;

  /// 左上方那块开着。
  bool get isLeftOpen => _isLeftOpen;

  LeftTool? get leftBottomTool => _leftBottomTool;
  bool get isLeftBottomOpen => _isLeftBottomOpen && _leftBottomTool != null;
  double get leftSplit => _leftSplit;

  ToolSlot slotOf(LeftTool tool) => _bottomSlot.contains(tool) ? ToolSlot.bottom : ToolSlot.top;

  /// 左上方正在显示的工具窗。
  LeftTool? get visibleTopTool => _isLeftOpen && slotOf(_leftTool) == ToolSlot.top ? _leftTool : null;

  /// 左下方正在显示的工具窗。
  LeftTool? get visibleBottomTool => isLeftBottomOpen && slotOf(_leftBottomTool!) == ToolSlot.bottom ? _leftBottomTool : null;

  /// 正在显示的左侧工具窗(上下拆分时两个)。
  Set<LeftTool> get visibleLeftTools => {
        if (visibleTopTool case final t?) t,
        if (visibleBottomTool case final t?) t,
      };

  bool isLeftToolVisible(LeftTool tool) => visibleTopTool == tool || visibleBottomTool == tool;

  /// 左栏有东西显示(上、下任一块)。
  bool get isAnyLeftOpen => visibleTopTool != null || visibleBottomTool != null;
  bool get isBottomOpen => _isBottomOpen;
  double get bottomHeight => _bottomHeight;
  double get leftWidth => _leftWidth;

  /// [maxWidth] 由调用方按窗口宽度给出,保证编辑区始终留有空间。
  void resizeLeft(double width, {required double maxWidth}) {
    final clamped = width.clamp(minLeftWidth, maxWidth < minLeftWidth ? minLeftWidth : maxWidth);
    if (clamped == _leftWidth) return;
    _leftWidth = clamped;
    notifyListeners();
  }

  /// 再点一次当前工具会收起它所在的那块 —— 与 IntelliJ 的行为一致。
  void selectLeftTool(LeftTool tool) {
    if (isLeftToolVisible(tool)) {
      _hide(tool);
    } else {
      _show(tool);
    }
    notifyListeners();
  }

  /// 打开左侧的某个工具窗;已经开着就保持开着(菜单项「Commit…」用,不像点图标那样会收起)。
  void showLeftTool(LeftTool tool) {
    if (isLeftToolVisible(tool)) return;
    _show(tool);
    notifyListeners();
  }

  /// 收起这个工具窗(标题栏的「—」)。
  void hideLeftTool(LeftTool tool) {
    if (!isLeftToolVisible(tool)) return;
    _hide(tool);
    notifyListeners();
  }

  /// 把工具窗移到左上方 / 左下方。开着的话在新位置接着显示(顶替那块原来的工具窗)。
  void moveLeftTool(LeftTool tool, ToolSlot slot) {
    if (slotOf(tool) == slot) return;
    final wasVisible = isLeftToolVisible(tool);
    if (wasVisible) _hide(tool);
    slot == ToolSlot.bottom ? _bottomSlot.add(tool) : _bottomSlot.remove(tool);
    if (wasVisible) _show(tool);
    notifyListeners();
  }

  /// 拖动上下两块之间的分隔条。
  void resizeLeftSplit(double fraction) {
    final clamped = fraction.clamp(minLeftSplit, 1 - minLeftSplit);
    if (clamped == _leftSplit) return;
    _leftSplit = clamped;
    notifyListeners();
  }

  void _show(LeftTool tool) {
    if (slotOf(tool) == ToolSlot.bottom) {
      _leftBottomTool = tool;
      _isLeftBottomOpen = true;
    } else {
      _leftTool = tool;
      _isLeftOpen = true;
    }
  }

  void _hide(LeftTool tool) {
    if (visibleTopTool == tool) _isLeftOpen = false;
    if (visibleBottomTool == tool) _isLeftBottomOpen = false;
  }

  /// 要记住的布局(放在左下方的工具窗、拆分比例),存进设置文件。
  Map<String, dynamic> toJson() => {
        'leftBottomTools': [for (final t in LeftTool.values) if (_bottomSlot.contains(t)) t.name],
        'leftSplit': (_leftSplit * 100).round() / 100,
      };

  void applyJson(Map<String, dynamic> j) {
    _bottomSlot
      ..clear()
      ..addAll([
        for (final n in (j['leftBottomTools'] as List? ?? const []))
          if (LeftTool.values.where((t) => t.name == n).firstOrNull case final t?) t,
      ]);
    final split = j['leftSplit'];
    if (split is num) _leftSplit = split.toDouble().clamp(minLeftSplit, 1 - minLeftSplit);
    // 默认打开的项目视图被移到了左下方:在下面打开它,上面空着
    if (slotOf(_leftTool) == ToolSlot.bottom && _isLeftOpen) {
      _isLeftOpen = false;
      _leftBottomTool = _leftTool;
      _isLeftBottomOpen = true;
    }
    notifyListeners();
  }

  /// 点底部工具窗的图标:切到那个标签,若已选中则收起整条底栏。
  void selectBottomTab(BottomToolTab tab) {
    if (_bottomTab == tab && _isBottomOpen) {
      _isBottomOpen = false;
    } else {
      _bottomTab = tab;
      _isBottomOpen = true;
    }
    notifyListeners();
  }

  /// 打开底部工具窗并切到 [tab];已经开着就保持开着(构建任务运行时切到终端用)。
  void showBottomTab(BottomToolTab tab) {
    if (_bottomTab == tab && _isBottomOpen) return;
    _bottomTab = tab;
    _isBottomOpen = true;
    notifyListeners();
  }

  /// [maxHeight] 由调用方按窗口大小给出,保证编辑区始终留有空间。
  void resizeBottom(double height, {required double maxHeight}) {
    final clamped = height.clamp(minBottomHeight, maxHeight < minBottomHeight ? minBottomHeight : maxHeight);
    if (clamped == _bottomHeight) return;
    _bottomHeight = clamped;
    notifyListeners();
  }

  void toggleBottom() {
    _isBottomOpen = !_isBottomOpen;
    notifyListeners();
  }
}
