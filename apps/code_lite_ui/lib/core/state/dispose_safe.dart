import 'package:flutter/foundation.dart';

/// 释放之后再 [notifyListeners] 不报错(直接忽略)。
///
/// 这些 store 里有不少异步操作(读文件、问语言服务器、跑 git……),项目关闭时 store 被释放,
/// 而操作还在途中:它们回来之后照常通知,对已释放的 ChangeNotifier 会触发断言。
/// 项目可以随时关闭以后,这就不是「退出应用时才会发生」的事了。
mixin DisposeSafeNotifier on ChangeNotifier {
  bool _isDisposed = false;

  /// 已经释放:异步操作回来后看到它就该放弃,别再动状态。
  bool get isDisposed => _isDisposed;

  @override
  void notifyListeners() {
    if (!_isDisposed) super.notifyListeners();
  }

  @override
  void dispose() {
    _isDisposed = true;
    super.dispose();
  }
}
