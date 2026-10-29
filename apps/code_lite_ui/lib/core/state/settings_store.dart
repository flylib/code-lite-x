import 'dart:convert';

import 'package:flutter/foundation.dart';

import '../../features/editor/editor_appearance.dart';
import '../../features/editor/editor_session_manager.dart';
import '../l10n/l10n.dart';
import '../platform/workspace_io.dart' as io;
import '../keymap/keymap.dart';
import 'layout_store.dart';

/// 应用设置:自动保存与编辑器外观,存在 `~/.codelitex/settings.json`,启动时读回。
///
/// 外观开关仍由 [EditorAppearance] 持有(行号栏右键菜单也会改它),这里监听它的变化一起落盘。
/// 工具窗的位置(哪些放在左下方、拆分比例)由 [LayoutStore] 持有,同样监听落盘。
///
/// 自动保存的开关和延迟是全局设置,但要作用到每个项目各自的 [EditorSessionManager]:
/// 用 [bind] 把项目的会话管理器登记进来(新开的项目也会立刻套用当前值),改设置时对所有已登记的生效。
class SettingsStore extends ChangeNotifier {
  /// [appearance]:外观设置;不传时取 [sessions] 的,再没有就自己建一份。
  /// [sessions] 是方便单项目用法(和测试)的快捷方式,等同于 `bind(sessions)`。
  SettingsStore({
    EditorSessionManager? sessions,
    EditorAppearance? appearance,
    this.layout,
    this.keymap,
    Future<Map<String, dynamic>> Function()? load,
    Future<void> Function(Map<String, dynamic>)? save,
  })  : appearance = appearance ?? sessions?.appearance ?? EditorAppearance(),
        _autosave = sessions?.autosave ?? true,
        _autosaveDelay = sessions?.autosaveDelay ?? EditorSessionManager.defaultAutosaveDelay,
        _load = load ?? io.loadSettings,
        _save = save ?? io.saveSettings {
    this.appearance.addListener(_persist);
    layout?.addListener(_onLayoutChanged);
    keymap?.addListener(_persist);
    if (sessions != null) _bound.add(sessions);
  }

  final LayoutStore? layout;

  /// 快捷键(只存改过的)。
  final KeymapStore? keymap;

  /// 上次写盘时的布局;布局的通知很频繁(选工具窗、拖宽度),只有要记住的部分变了才写。
  String _savedLayout = '';

  /// 读写设置文件;测试里换成内存实现,不碰用户的 ~/.codelitex。
  final Future<Map<String, dynamic>> Function() _load;
  final Future<void> Function(Map<String, dynamic>) _save;

  final EditorAppearance appearance;

  final List<EditorSessionManager> _bound = [];
  bool _autosave;
  Duration _autosaveDelay;

  /// 登记一个项目的会话管理器:立刻套用当前的自动保存设置,之后改设置也会同步给它。
  void bind(EditorSessionManager sessions) {
    if (_bound.contains(sessions)) return;
    _bound.add(sessions);
    sessions
      ..autosave = _autosave
      ..autosaveDelay = _autosaveDelay;
  }

  void unbind(EditorSessionManager sessions) => _bound.remove(sessions);

  /// 可选的自动保存延迟(停止输入后多久写盘)。
  static const List<Duration> autosaveDelays = [
    Duration(milliseconds: 300),
    Duration(milliseconds: 600),
    Duration(seconds: 1),
    Duration(seconds: 2),
    Duration(seconds: 5),
  ];

  bool get autosave => _autosave;
  Duration get autosaveDelay => _autosaveDelay;

  /// make 可执行文件的路径(设置 ▸ Build Tools ▸ Make,同 IntelliJ);空 = 用 PATH 里的 `make`。
  /// make 工具窗和 Makefile 行号栏的 ▶ 都用它。
  String get makePath => _makePath;
  String _makePath = '';

  void setMakePath(String value) {
    final v = value.trim();
    if (v == _makePath) return;
    _makePath = v;
    _changed();
  }

  bool _loading = false;

  /// 用户选过的界面语言;null = 没选过,跟系统走([L10n.systemLanguage])。
  AppLanguage? _language;

  AppLanguage get language => L10n.language.value;

  /// 设置 ▸ 语言和地区:换了立刻生效(整个界面重画),并记下来。
  void setLanguage(AppLanguage value) {
    if (_language == value && L10n.language.value == value) return;
    _language = value;
    L10n.language.value = value;
    _changed();
  }

  Future<void> load() async {
    final j = await _load();
    _loading = true;
    _language = AppLanguage.parse(j['language']);
    L10n.language.value = _language ?? L10n.systemLanguage();
    final editor = j['editor'] is Map ? Map<String, dynamic>.from(j['editor'] as Map) : const <String, dynamic>{};
    if (editor['autosave'] is bool) _autosave = editor['autosave'] as bool;
    final ms = editor['autosaveDelayMs'];
    if (ms is int && ms >= 100 && ms <= 60000) _autosaveDelay = Duration(milliseconds: ms);
    for (final s in _bound) {
      s
        ..autosave = _autosave
        ..autosaveDelay = _autosaveDelay;
    }
    if (editor['appearance'] is Map) appearance.applyJson(Map<String, dynamic>.from(editor['appearance'] as Map));
    if (j['layout'] is Map) layout?.applyJson(Map<String, dynamic>.from(j['layout'] as Map));
    if (j['keymap'] is Map) keymap?.applyJson(Map<String, dynamic>.from(j['keymap'] as Map));
    final build = j['buildTools'];
    if (build is Map && build['makePath'] is String) _makePath = (build['makePath'] as String).trim();
    _savedLayout = _layoutSignature();
    _loading = false;
    notifyListeners();
  }

  void setAutosave(bool value) {
    if (_autosave == value) return;
    _autosave = value;
    for (final s in _bound) {
      s.autosave = value;
      // 刚打开自动保存:已有的未保存改动立即写掉。
      if (value) s.saveAll();
    }
    _changed();
  }

  void setAutosaveDelay(Duration value) {
    if (_autosaveDelay == value) return;
    _autosaveDelay = value;
    for (final s in _bound) {
      s.autosaveDelay = value;
    }
    _changed();
  }

  void _changed() {
    notifyListeners();
    _persist();
  }

  Map<String, dynamic> toJson() => {
        if (_language != null) 'language': _language!.name,
        'editor': {
          'autosave': _autosave,
          'autosaveDelayMs': _autosaveDelay.inMilliseconds,
          'appearance': appearance.toJson(),
        },
        if (layout != null) 'layout': layout!.toJson(),
        if (keymap != null) 'keymap': keymap!.toJson(),
        if (_makePath.isNotEmpty) 'buildTools': {'makePath': _makePath},
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
    appearance.removeListener(_persist);
    layout?.removeListener(_onLayoutChanged);
    keymap?.removeListener(_persist);
    super.dispose();
  }
}
