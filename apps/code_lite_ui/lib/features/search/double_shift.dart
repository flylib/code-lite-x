import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 连按两下 Shift(IntelliJ 打开 Search Everywhere 的方式):两次单独按下又松开 Shift,
/// 中间没按别的键,间隔不超过 [interval]。打大写字母(Shift 按着打字)不算。全应用监听,不吃掉按键。
class DoubleShiftDetector extends StatefulWidget {
  const DoubleShiftDetector({super.key, required this.onDoubleShift, required this.child, this.interval = const Duration(milliseconds: 400)});

  final VoidCallback onDoubleShift;
  final Duration interval;
  final Widget child;

  @override
  State<DoubleShiftDetector> createState() => _DoubleShiftDetectorState();
}

class _DoubleShiftDetectorState extends State<DoubleShiftDetector> {
  final Stopwatch _clock = Stopwatch()..start();

  /// 这次按下 Shift 之后还没按过别的键。
  bool _clean = false;

  /// 上一次「单独按下又松开 Shift」松开的时刻。
  Duration? _lastTap;

  @override
  void initState() {
    super.initState();
    HardwareKeyboard.instance.addHandler(_onKey);
  }

  @override
  void dispose() {
    HardwareKeyboard.instance.removeHandler(_onKey);
    super.dispose();
  }

  static bool _isShift(LogicalKeyboardKey k) =>
      k == LogicalKeyboardKey.shiftLeft || k == LogicalKeyboardKey.shiftRight || k == LogicalKeyboardKey.shift;

  bool _onKey(KeyEvent e) {
    final shift = _isShift(e.logicalKey);
    if (e is KeyDownEvent) {
      if (!shift) {
        _clean = false;
        _lastTap = null;
        return false;
      }
      final last = _lastTap;
      if (last != null && _clock.elapsed - last <= widget.interval) {
        _lastTap = null;
        _clean = false;
        // 按键处理过程中不要弹窗:下一帧再开
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (mounted) widget.onDoubleShift();
        });
        WidgetsBinding.instance.scheduleFrame();
        return false;
      }
      _clean = true;
    } else if (e is KeyUpEvent && shift) {
      _lastTap = _clean ? _clock.elapsed : null;
      _clean = false;
    }
    return false;
  }

  @override
  Widget build(BuildContext context) => widget.child;
}
