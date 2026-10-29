import 'package:flutter/foundation.dart';

import '../../core/client/api_client.dart';
import '../../core/state/dispose_safe.dart';
import '../../core/l10n/l10n.dart';

class TerminalSession {
  TerminalSession(this.id, this.title);

  final String id;
  final String title;
}

/// 终端会话列表(IntelliJ 的 Local / Local (2) 标签)。
///
/// 放在面板之外:底部工具窗收起时 widget 会被卸载,shell 不能跟着死。
/// 真正的 shell 活在 Rust 的 CodeLiteContext 里,切换项目会销毁上下文 ——
/// 那时 snapshot 会报会话不存在,视图调 [forget] 把它从列表里摘掉。
class TerminalStore extends ChangeNotifier with DisposeSafeNotifier {
  TerminalStore(this._client);

  final ApiClient _client;
  final List<TerminalSession> _sessions = [];
  int _active = 0;
  int _opened = 0;
  String? _error;

  List<TerminalSession> get sessions => List.unmodifiable(_sessions);
  TerminalSession? get current => _sessions.isEmpty ? null : _sessions[_active];
  int get activeIndex => _active;

  /// 最近一次打开失败的原因;成功打开后清空。
  String? get error => _error;

  bool get isAvailable => _client.isFfiAvailable;

  /// 以给定尺寸新开一个 shell 并切到它。失败时返回 null,原因见 [error]。
  /// [title] 缺省为 Local / Local (2) ……
  TerminalSession? open(int rows, int cols, {String? title}) {
    final res = _client.ptyOpen(rows, cols);
    final id = res['id'] as String?;
    if (res['status'] != 'ok' || id == null) {
      _error = (res['error'] as String?) ?? tr('无法启动终端', 'Cannot start the terminal');
      notifyListeners();
      return null;
    }
    if (title == null) _opened++;
    final session = TerminalSession(id, title ?? (_opened == 1 ? tr('本地', 'Local') : tr('本地 ($_opened)', 'Local ($_opened)')));
    _sessions.add(session);
    _active = _sessions.length - 1;
    _error = null;
    notifyListeners();
    return session;
  }

  /// 新开一个标签运行 [command](构建任务)。shell 在项目根目录启动,命令写进它的输入:
  /// 跑完回到提示符,可以接着在这个标签里敲命令。尺寸先按常见值开,视图显示时会同步成实际大小。
  TerminalSession? run(String title, String command) {
    final session = open(24, 120, title: title);
    if (session != null) _client.ptyWrite(session.id, '$command\r');
    return session;
  }

  void select(int index) {
    if (index < 0 || index >= _sessions.length || index == _active) return;
    _active = index;
    notifyListeners();
  }

  /// 用户关闭标签:杀掉 shell。
  void close(String id) {
    _client.ptyClose(id);
    forget(id);
  }

  /// shell 已经不在了(退出 / 上下文被重建),只更新列表。
  void forget(String id) {
    final index = _sessions.indexWhere((s) => s.id == id);
    if (index < 0) return;
    _sessions.removeAt(index);
    if (_sessions.isEmpty) {
      _active = 0;
      _opened = 0;
    } else if (_active >= index && _active > 0) {
      _active--;
    }
    notifyListeners();
  }

  @override
  void dispose() {
    for (final s in _sessions) {
      _client.ptyClose(s.id);
    }
    _sessions.clear();
    super.dispose();
  }
}
