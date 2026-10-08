import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../features/editor/editor_appearance.dart';
import '../../features/editor/editor_session_manager.dart';
import '../platform/workspace_io.dart' as io;
import 'layout_store.dart';

/// 应用设置:自动保存与编辑器外观,存在 `~/.codelitex/settings.json`,启动时读回。
///
/// 外观开关仍由 [EditorAppearance] 持有(行号栏右键菜单也会改它),这里监听它的变化一起落盘。
/// 工具窗的位置(哪些放在左下方、拆分比例)由 [LayoutStore] 持有,同样监听落盘。
class SettingsStore extends ChangeNotifier {
  SettingsStore({
    required this.sessions,
    this.layout,
    Future<Map<String, dynamic>> Function()? load,
    Future<void> Function(Map<String, dynamic>)? save,
  })  : _load = load ?? io.loadSettings,
        _save = save ?? io.saveSettings {
    sessions.appearance.addListener(_persist);
    layout?.addListener(_onLayoutChanged);
  }

  final LayoutStore? layout;

  /// 上次写盘时的布局;布局的通知很频繁(选工具窗、拖宽度),只有要记住的部分变了才写。
  String _savedLayout = '';

  /// 读写设置文件;测试里换成内存实现,不碰用户的 ~/.codelitex。
  final Future<Map<String, dynamic>> Function() _load;
  final Future<void> Function(Map<String, dynamic>) _save;

  final EditorSessionManager sessions;
  EditorAppearance get appearance => sessions.appearance;

  /// 可选的自动保存延迟(停止输入后多久写盘)。
  static const List<Duration> autosaveDelays = [
    Duration(milliseconds: 300),
    Duration(milliseconds: 600),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];

  bool get autosave => sessions.autosave;
  Duration get autosaveDelay => sessions.autosaveDelay;

  bool _loading = false;

  Future<void> load() async {
    final j = await _load();
    _loading = true;
    final editor = j['editor'] is Map ? Map<String, dynamic>.from(j['editor'] as Map) : const <String, dynamic>{};
    if (editor['autosave'] is bool) sessions.autosave = editor['autosave'] as bool;
    final ms = editor['autosaveDelayMs'];
    if (ms is int && ms >= 100 && ms <= 60000) sessions.autosaveDelay = Duration(milliseconds: ms);
    if (editor['appearance'] is Map) appearance.applyJson(Map<String, dynamic>.from(editor['appearance'] as Map));
    if (j['layout'] is Map) layout?.applyJson(Map<String, dynamic>.from(j['layout'] as Map));
    _savedLayout = _layoutSignature();
    _loading = false;
    notifyListeners();
  }

  void setAutosave(bool value) {
    if (sessions.autosave == value) return;
    sessions.autosave = value;
    // 刚打开自动保存:已有的未保存改动立即写掉。
    if (value) sessions.saveAll();
    _changed();
  }

  void setAutosaveDelay(Duration value) {
    if (sessions.autosaveDelay == value) return;
    sessions.autosaveDelay = value;
    _changed();
  }

  void _changed() {
    notifyListeners();
    _persist();
  }

  Map<String, dynamic> toJson() => {
        'editor': {
          'autosave': sessions.autosave,
          'autosaveDelayMs': sessions.autosaveDelay.inMilliseconds,
          'appearance': appearance.toJson(),
        },
        if (layout != null) 'layout': layout!.toJson(),
      };

  String _layoutSignature() => layout == null ? '' : jsonEncode(layout!.toJson());

  void _onLayoutChanged() {
    final sig = _layoutSignature();
    if (sig == _savedLayout) return;
    _savedLayout = sig;
    _persist();
  }

  void _persist() {
    if (_loading) return;
    _save(toJson());
  }

  @override
  void dispose() {
    sessions.appearance.removeListener(_persist);
    layout?.removeListener(_onLayoutChanged);
    super.dispose();
  }
}
