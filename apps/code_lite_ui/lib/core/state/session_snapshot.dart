import 'dart:convert';

import '../platform/workspace_io.dart' as io;

/// 一个标签的状态:文件(相对项目根)、光标、竖向滚动位置。
class TabSnapshot {
  const TabSnapshot({required this.path, this.line = 0, this.col = 0, this.scroll = 0});

  final String path;
  final int line;
  final int col;
  final double scroll;

  Map<String, dynamic> toJson() => {
        'path': path,
        if (line != 0) 'line': line,
        if (col != 0) 'col': col,
        if (scroll != 0) 'scroll': scroll.round(),
      };

  /// 字段缺了 / 类型不对就用默认值;没有 path 的返回 null。
  static TabSnapshot? fromJson(Object? j) {
    if (j is! Map) return null;
    final path = j['path'];
    if (path is! String || path.isEmpty) return null;
    int n(Object? v) => v is num && v >= 0 ? v.toInt() : 0;
    return TabSnapshot(path: path, line: n(j['line']), col: n(j['col']), scroll: n(j['scroll']).toDouble());
  }
}

/// 一个项目关掉(或应用退出)时的编辑区状态:打开的标签(按标签栏顺序)和当前标签。
/// 只记真实文件的标签 —— Commit 差异、PR 页面这类特殊标签不恢复。
class SessionSnapshot {
  const SessionSnapshot({this.tabs = const [], this.active});

  final List<TabSnapshot> tabs;

  /// 当前标签的文件;null 时恢复后停在最后一个标签。
  final String? active;

  bool get isEmpty => tabs.isEmpty;

  Map<String, dynamic> toJson() => {
        'tabs': [for (final t in tabs) t.toJson()],
        if (active != null) 'active': active,
      };

  static SessionSnapshot fromJson(Object? j) {
    if (j is! Map) return const SessionSnapshot();
    final seen = <String>{};
    final tabs = [
      for (final t in (j['tabs'] as List? ?? const []))
        if (TabSnapshot.fromJson(t) case final tab? when seen.add(tab.path)) tab,
    ];
    final active = j['active'];
    return SessionSnapshot(tabs: tabs, active: active is String && seen.contains(active) ? active : null);
  }

  /// 内容签名:没变就不必写盘。
  String get signature => jsonEncode(toJson());
}

/// 各项目的 [SessionSnapshot],存在 `~/.codelitex/sessions.json`,按项目根目录分开。
/// 只留最近用过的 [maxProjects] 个项目,免得文件越攒越大。读写串行,避免两次保存互相覆盖。
class SessionStore {
  SessionStore({Future<Map<String, dynamic>> Function()? load, Future<void> Function(Map<String, dynamic>)? save})
      : _load = load ?? io.loadSessions,
        _save = save ?? io.saveSessions;

  static const int maxProjects = 30;

  final Future<Map<String, dynamic>> Function() _load;
  final Future<void> Function(Map<String, dynamic>) _save;
  Future<void> _chain = Future.value();

  Future<SessionSnapshot> read(String root) async {
    final all = await _load();
    final entry = all[root];
    return entry is Map ? SessionSnapshot.fromJson(entry) : const SessionSnapshot();
  }

  /// 记下 [root] 项目的状态;空状态(关光了标签)也要记,否则下次又会恢复旧的。
  Future<void> write(String root, SessionSnapshot snapshot) {
    final next = _chain.then((_) async {
      final all = Map<String, dynamic>.from(await _load());
      // 删掉再放回去 = 排到最后(最近用过);超出上限从最旧的开始丢
      all.remove(root);
      all[root] = {...snapshot.toJson(), 'at': DateTime.now().millisecondsSinceEpoch};
      while (all.length > maxProjects) {
        all.remove(all.keys.first);
      }
      await _save(all);
    });
    _chain = next.catchError((_) {});
    return next;
  }
}
