import 'package:flutter/foundation.dart';

import '../../features/bottom_tools/bottom_tools_widget.dart';

/// 左侧工具窗(活动条上半段选择的那一栏)。
enum LeftTool { project, commit, pullRequests, structure }

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

  /// 左侧工具窗(项目 / Commit / 结构)共用一个宽度,拖动分隔线调整;切换工具窗时不跳变。
  static const double minLeftWidth = 160;

  /// 底部工具窗高度,拖动分隔条调整。Git Log 这类视图在 220 高度下只看得到几行。
  static const double minBottomHeight = 140;

  LeftTool get leftTool => _leftTool;
  BottomToolTab get bottomTab => _bottomTab;
  bool get isLeftOpen => _isLeftOpen;
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

  /// 再点一次当前工具会收起该栏 —— 与 IntelliJ 的行为一致。
  void selectLeftTool(LeftTool tool) {
    if (_leftTool == tool && _isLeftOpen) {
      _isLeftOpen = false;
    } else {
      _leftTool = tool;
      _isLeftOpen = true;
    }
    notifyListeners();
  }

  /// 打开左侧的某个工具窗;已经开着就保持开着(菜单项「Commit…」用,不像点图标那样会收起)。
  void showLeftTool(LeftTool tool) {
    if (_leftTool == tool && _isLeftOpen) return;
    _leftTool = tool;
    _isLeftOpen = true;
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
