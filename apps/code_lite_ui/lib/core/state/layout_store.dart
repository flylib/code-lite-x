import 'package:flutter/foundation.dart';

import '../../features/bottom_tools/bottom_tools_widget.dart';

/// 左侧工具窗(活动条上半段选择的那一栏)。
enum LeftTool { project, commit, structure }

/// 右侧工具窗(右侧活动条选择的那一栏)。
enum RightTool { none, cargo, assistant }

/// 面板显隐与选中项。只放"哪个面板开着、选中了什么",
/// 不放文件内容 —— 那些在 [WorkspaceStore] 与 EditorSessionManager 里。
///
/// 拆成独立 store 的原因:敲一个字符不应该重建项目树和底部日志。
/// 布局变化和编辑变化各自通知各自的订阅者。
class LayoutStore extends ChangeNotifier {
  LeftTool _leftTool = LeftTool.project;
  // 默认不打开右栏:助手面板挂载时会做 FFI 往返,启动阶段不该为一个
  // 用户还没要求看的面板付这个代价。用户点右活动条再开。
  RightTool _rightTool = RightTool.none;
  BottomToolTab _bottomTab = BottomToolTab.git;
  bool _isLeftOpen = true;
  bool _isBottomOpen = true;
  double _bottomHeight = 300;

  /// 底部工具窗高度,拖动分隔条调整。Git Log 这类视图在 220 高度下只看得到几行。
  static const double minBottomHeight = 140;

  LeftTool get leftTool => _leftTool;
  RightTool get rightTool => _rightTool;
  BottomToolTab get bottomTab => _bottomTab;
  bool get isLeftOpen => _isLeftOpen;
  bool get isBottomOpen => _isBottomOpen;
  double get bottomHeight => _bottomHeight;
  bool get isRightOpen => _rightTool != RightTool.none;

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

  void selectRightTool(RightTool tool) {
    _rightTool = _rightTool == tool ? RightTool.none : tool;
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

  void closeRight() {
    if (_rightTool == RightTool.none) return;
    _rightTool = RightTool.none;
    notifyListeners();
  }
}
