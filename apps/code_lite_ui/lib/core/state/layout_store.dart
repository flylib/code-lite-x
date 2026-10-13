import 'package:flutter/foundation.dart';

import '../../features/bottom_tools/bottom_tools_widget.dart';

/// 侧边工具窗(活动条上半段的那些按钮):可以放在左侧或右侧,每一侧再分上下两块。
enum SideTool { project, commit, pullRequests, structure, openProjects, build }

/// 工具窗停靠在哪一侧(IntelliJ 的 Move To ▸ Left / Right)。
enum ToolSide { left, right }

/// 工具窗放在一侧的哪一块(Top / Bottom):上下两块各开一个时,这一侧上下拆分同时显示。
enum ToolSlot { top, bottom }

/// 一侧的状态:上下两块各自最近选中的工具窗、开没开、拆分比例和宽度。
class _Dock {
  _Dock({required this.width});

  SideTool? top;
  bool topOpen = false;
  SideTool? bottom;
  bool bottomOpen = false;
  double split = 0.5;
  double width;
}

/// 面板显隐与选中项。只放"哪个面板开着、选中了什么",
/// 不放文件内容 —— 那些在 [WorkspaceStore] 与 EditorSessionManager 里。
///
/// 拆成独立 store 的原因:敲一个字符不应该重建项目树和底部日志。
/// 布局变化和编辑变化各自通知各自的订阅者。
class LayoutStore extends ChangeNotifier {
  BottomToolTab _bottomTab = BottomToolTab.git;
  // 底部工具窗默认收起:打开 Git 窗口会立刻跑 git log,不该为用户还没要看的面板付这个代价。
  bool _isBottomOpen = false;
  double _bottomHeight = 300;

  /// 左侧默认开着项目视图;右侧默认收着。
  final _Dock _left = _Dock(width: 250)
    ..top = SideTool.project
    ..topOpen = true;
  final _Dock _right = _Dock(width: 300);

  /// 不在左上方的工具窗放哪了。默认和 IntelliJ 一样:构建工具窗(Maven)在右侧。
  final Map<SideTool, (ToolSide, ToolSlot)> _placed = {..._defaultPlaced};
  static const Map<SideTool, (ToolSide, ToolSlot)> _defaultPlaced = {SideTool.build: (ToolSide.right, ToolSlot.top)};

  /// 侧边工具窗(项目 / Commit / 结构 ……)每一侧共用一个宽度,拖动分隔线调整;切换工具窗时不跳变。
  static const double minSideWidth = 160;

  /// 底部工具窗高度,拖动分隔条调整。Git Log 这类视图在 220 高度下只看得到几行。
  static const double minBottomHeight = 140;

  /// 上下拆分时每块至少占的比例。
  static const double minSplit = 0.15;

  _Dock _dock(ToolSide side) => side == ToolSide.left ? _left : _right;
  (ToolSide, ToolSlot) _placeOf(SideTool tool) => _placed[tool] ?? (ToolSide.left, ToolSlot.top);

  /// 左上方最近选中的工具窗([isLeftOpen] 为假时不显示)。
  SideTool get leftTool => _left.top ?? SideTool.project;
  BottomToolTab get bottomTab => _bottomTab;

  /// 左上方那块开着。
  bool get isLeftOpen => _left.topOpen;

  ToolSide sideOf(SideTool tool) => _placeOf(tool).$1;
  ToolSlot slotOf(SideTool tool) => _placeOf(tool).$2;

  /// [side] 一侧的 [slot] 那块正在显示的工具窗。
  SideTool? visibleTool(ToolSide side, ToolSlot slot) {
    final d = _dock(side);
    final (tool, open) = slot == ToolSlot.top ? (d.top, d.topOpen) : (d.bottom, d.bottomOpen);
    return open && tool != null && _placeOf(tool) == (side, slot) ? tool : null;
  }

  /// 正在显示的侧边工具窗(每块各一个,最多四个)。
  Set<SideTool> get visibleTools => {
        for (final side in ToolSide.values)
          for (final slot in ToolSlot.values)
            if (visibleTool(side, slot) case final t?) t,
      };

  bool isToolVisible(SideTool tool) => visibleTools.contains(tool);

  /// [side] 一侧有东西显示(上、下任一块)。
  bool isSideOpen(ToolSide side) => visibleTool(side, ToolSlot.top) != null || visibleTool(side, ToolSlot.bottom) != null;

  /// [side] 一侧有没有被放了工具窗(右侧活动条只在有的时候才出现)。
  bool hasToolsOn(ToolSide side) => SideTool.values.any((t) => sideOf(t) == side);

  double splitOf(ToolSide side) => _dock(side).split;
  double widthOf(ToolSide side) => _dock(side).width;

  bool get isBottomOpen => _isBottomOpen;
  double get bottomHeight => _bottomHeight;

  /// [maxWidth] 由调用方按窗口宽度给出,保证编辑区始终留有空间。
  void resizeSide(ToolSide side, double width, {required double maxWidth}) {
    final d = _dock(side);
    final clamped = width.clamp(minSideWidth, maxWidth < minSideWidth ? minSideWidth : maxWidth);
    if (clamped == d.width) return;
    d.width = clamped;
    notifyListeners();
  }

  /// 再点一次当前工具会收起它所在的那块 —— 与 IntelliJ 的行为一致。
  void selectTool(SideTool tool) {
    if (isToolVisible(tool)) {
      _hide(tool);
    } else {
      _show(tool);
    }
    notifyListeners();
  }

  /// 打开某个工具窗;已经开着就保持开着(菜单项「Commit…」用,不像点图标那样会收起)。
  void showTool(SideTool tool) {
    if (isToolVisible(tool)) return;
    _show(tool);
    notifyListeners();
  }

  /// 收起这个工具窗(标题栏的「—」)。
  void hideTool(SideTool tool) {
    if (!isToolVisible(tool)) return;
    _hide(tool);
    notifyListeners();
  }

  /// 把工具窗移到 [side] 一侧的 [slot] 那块。开着的话在新位置接着显示(顶替那块原来的工具窗)。
  void moveTool(SideTool tool, ToolSide side, ToolSlot slot) {
    if (_placeOf(tool) == (side, slot)) return;
    final wasVisible = isToolVisible(tool);
    if (wasVisible) _hide(tool);
    if ((side, slot) == (ToolSide.left, ToolSlot.top)) {
      _placed.remove(tool);
    } else {
      _placed[tool] = (side, slot);
    }
    if (wasVisible) _show(tool);
    notifyListeners();
  }

  /// 拖动 [side] 一侧上下两块之间的分隔条。
  void resizeSplit(ToolSide side, double fraction) {
    final d = _dock(side);
    final clamped = fraction.clamp(minSplit, 1 - minSplit);
    if (clamped == d.split) return;
    d.split = clamped;
    notifyListeners();
  }

  void _show(SideTool tool) {
    final (side, slot) = _placeOf(tool);
    final d = _dock(side);
    if (slot == ToolSlot.bottom) {
      d.bottom = tool;
      d.bottomOpen = true;
    } else {
      d.top = tool;
      d.topOpen = true;
    }
  }

  void _hide(SideTool tool) {
    for (final side in ToolSide.values) {
      final d = _dock(side);
      if (visibleTool(side, ToolSlot.top) == tool) d.topOpen = false;
      if (visibleTool(side, ToolSlot.bottom) == tool) d.bottomOpen = false;
    }
  }

  /// 要记住的布局(工具窗放在哪一侧哪一块、拆分比例),存进设置文件。
  Map<String, dynamic> toJson() {
    List<String> placedAt(ToolSide side, ToolSlot slot) => [
          for (final t in SideTool.values)
            if (_placeOf(t) == (side, slot)) t.name,
        ];
    return {
      // 不在这三个列表里的就在左上方
      'leftBottomTools': placedAt(ToolSide.left, ToolSlot.bottom),
      'leftSplit': (_left.split * 100).round() / 100,
      'rightTopTools': placedAt(ToolSide.right, ToolSlot.top),
      'rightBottomTools': placedAt(ToolSide.right, ToolSlot.bottom),
      'rightSplit': (_right.split * 100).round() / 100,
    };
  }

  void applyJson(Map<String, dynamic> j) {
    // 没存过位置(老版本 / 新装)就用默认位置;存过就完全按存的来
    const keys = ['leftBottomTools', 'rightTopTools', 'rightBottomTools'];
    _placed.clear();
    if (!keys.any(j.containsKey)) _placed.addAll(_defaultPlaced);
    void read(String key, ToolSide side, ToolSlot slot) {
      for (final n in (j[key] as List? ?? const [])) {
        if (SideTool.values.where((t) => t.name == n).firstOrNull case final t?) _placed[t] = (side, slot);
      }
    }

    read('leftBottomTools', ToolSide.left, ToolSlot.bottom);
    read('rightTopTools', ToolSide.right, ToolSlot.top);
    read('rightBottomTools', ToolSide.right, ToolSlot.bottom);
    for (final (key, dock) in [('leftSplit', _left), ('rightSplit', _right)]) {
      final split = j[key];
      if (split is num) dock.split = split.toDouble().clamp(minSplit, 1 - minSplit);
    }
    // 默认打开的项目视图被移走了:在新位置打开它,左上方空着
    final open = _left.top;
    if (open != null && _left.topOpen && _placeOf(open) != (ToolSide.left, ToolSlot.top)) {
      _left.topOpen = false;
      _show(open);
    }
    notifyListeners();
  }

  /// 「隐藏所有工具窗」之前开着的(再按一次恢复它们);null = 没在隐藏状态。
  ({Set<SideTool> tools, bool bottom})? _hiddenAll;

  /// IntelliJ 的 Hide All Tool Windows(⇧⌘F12):有开着的就全部收起并记下来;都收着时再按一次恢复刚才那些。
  void toggleHideAll() {
    final visible = visibleTools;
    if (visible.isNotEmpty || _isBottomOpen) {
      _hiddenAll = (tools: visible, bottom: _isBottomOpen);
      for (final t in visible) {
        _hide(t);
      }
      _isBottomOpen = false;
    } else if (_hiddenAll case final h?) {
      for (final t in h.tools) {
        _show(t);
      }
      _isBottomOpen = h.bottom;
      _hiddenAll = null;
    } else {
      return;
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
