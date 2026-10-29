import 'package:flutter/foundation.dart';

import '../build_tools/xml_lite.dart';
import '../l10n/l10n.dart';
import 'keystroke.dart';

export 'keystroke.dart';

/// 快捷键操作的分类(设置 ▸ Keymap 里按它分组)。
enum KeymapGroup {
  toolWindows('工具窗', 'Tool Windows'),
  navigation('导航', 'Navigation'),
  folding('代码折叠', 'Folding'),
  editing('编辑', 'Editing'),
  refactoring('重构', 'Refactoring');

  const KeymapGroup(this.zh, this.en);

  final String zh;
  final String en;

  /// 按当前界面语言显示的名字。
  String get label => tr(zh, en);
}

/// 一个可以绑快捷键的操作。[id] 用 IntelliJ 的 action id,这样能直接从 IntelliJ 的快捷键配置导入。
class KeymapAction {
  const KeymapAction({
    required this.id,
    required this.titleZh,
    required this.titleEn,
    required this.keymapGroup,
    this.mac = const [],
    this.other = const [],
    this.intellijIds = const [],
    this.inIntelliJ = true,
  });

  final String id;
  final String titleZh;
  final String titleEn;
  final KeymapGroup keymapGroup;

  /// 按当前界面语言显示的名字。
  String get title => tr(titleZh, titleEn);

  /// 按当前界面语言显示的分类名(同一分类的操作在同一种语言下总是同一个字符串)。
  String get group => keymapGroup.label;

  /// 默认快捷键(IntelliJ「Mac OS X 10.5+」/ 其它平台「Default」键位里的),IntelliJ 的文字格式。
  final List<String> mac;
  final List<String> other;

  /// IntelliJ 里同一个操作的其它 id(导入时一起认)。
  final List<String> intellijIds;

  /// IntelliJ 里有这个操作;没有的(CodeLiteX 自己的)导入时不动它。
  final bool inIntelliJ;

  List<String> defaults({bool? mac}) => (mac ?? isMacPlatform) ? this.mac : other;
}

/// 快捷键操作的 id(IntelliJ 的)。
abstract final class KeymapIds {
  static const project = 'ActivateProjectToolWindow';
  static const commit = 'ActivateCommitToolWindow';
  static const pullRequests = 'ActivatePullRequestsToolWindow';
  static const structure = 'ActivateStructureToolWindow';
  static const openProjects = 'ActivateOpeningProjectsToolWindow';
  static const build = 'ActivateMavenToolWindow';
  static const terminal = 'ActivateTerminalToolWindow';
  static const git = 'ActivateVersionControlToolWindow';
  static const problems = 'ActivateProblemsViewToolWindow';
  static const hideAll = 'HideAllWindows';
  static const gotoFile = 'GotoFile';
  static const make = 'ActivateMakeToolWindow';
  static const collapseRegion = 'CollapseRegion';
  static const expandRegion = 'ExpandRegion';
  static const collapseAll = 'CollapseAllRegions';
  static const expandAll = 'ExpandAllRegions';
  static const duplicate = 'EditorDuplicate';
  static const find = 'Find';
  static const findNext = 'FindNext';
  static const findPrevious = 'FindPrevious';
  static const rename = 'RenameElement';
}

/// 目前支持配置的操作:打开 / 收起各个工具窗、Go to File、代码折叠、编辑(复制行、查找)。默认键位取自 IntelliJ。
const List<KeymapAction> keymapActions = [
  KeymapAction(id: KeymapIds.project, titleZh: '项目', titleEn: 'Project', keymapGroup: KeymapGroup.toolWindows, mac: ['meta 1'], other: ['alt 1']),
  KeymapAction(id: KeymapIds.commit, titleZh: '提交', titleEn: 'Commit', keymapGroup: KeymapGroup.toolWindows, mac: ['meta 0'], other: ['alt 0']),
  KeymapAction(id: KeymapIds.pullRequests, titleZh: '拉取请求', titleEn: 'Pull Requests', keymapGroup: KeymapGroup.toolWindows, intellijIds: ['ActivatePull RequestsToolWindow']),
  KeymapAction(id: KeymapIds.structure, titleZh: '结构', titleEn: 'Structure', keymapGroup: KeymapGroup.toolWindows, mac: ['meta 7'], other: ['alt 7']),
  KeymapAction(id: KeymapIds.openProjects, titleZh: '打开的项目', titleEn: 'Opening Projects', keymapGroup: KeymapGroup.toolWindows, inIntelliJ: false),
  KeymapAction(id: KeymapIds.build, titleZh: '构建工具(Maven)', titleEn: 'Build Tools (Maven)', keymapGroup: KeymapGroup.toolWindows, intellijIds: ['ActivateGradleToolWindow']),
  KeymapAction(id: KeymapIds.terminal, titleZh: '终端', titleEn: 'Terminal', keymapGroup: KeymapGroup.toolWindows, mac: ['alt F12'], other: ['alt F12']),
  KeymapAction(id: KeymapIds.git, titleZh: 'Git 提交与日志', titleEn: 'Git (Commits and Log)', keymapGroup: KeymapGroup.toolWindows, mac: ['meta 9'], other: ['alt 9']),
  KeymapAction(id: KeymapIds.problems, titleZh: '问题', titleEn: 'Problems', keymapGroup: KeymapGroup.toolWindows, mac: ['meta 6'], other: ['alt 6']),
  KeymapAction(id: KeymapIds.hideAll, titleZh: '隐藏 / 恢复所有工具窗', titleEn: 'Hide / Restore All Tool Windows', keymapGroup: KeymapGroup.toolWindows, mac: ['shift meta F12'], other: ['ctrl shift F12']),
  KeymapAction(id: KeymapIds.make, titleZh: 'make', titleEn: 'make', keymapGroup: KeymapGroup.toolWindows, intellijIds: ['ActivatemakeToolWindow']),
  KeymapAction(id: KeymapIds.gotoFile, titleZh: '转到文件', titleEn: 'Go to File', keymapGroup: KeymapGroup.navigation, mac: ['shift meta O'], other: ['ctrl shift N']),
  KeymapAction(id: KeymapIds.collapseRegion, titleZh: '折叠', titleEn: 'Collapse', keymapGroup: KeymapGroup.folding, mac: ['meta MINUS'], other: ['ctrl MINUS']),
  KeymapAction(id: KeymapIds.expandRegion, titleZh: '展开', titleEn: 'Expand', keymapGroup: KeymapGroup.folding, mac: ['meta EQUALS'], other: ['ctrl EQUALS']),
  KeymapAction(id: KeymapIds.collapseAll, titleZh: '全部折叠', titleEn: 'Collapse All', keymapGroup: KeymapGroup.folding, mac: ['shift meta MINUS'], other: ['ctrl shift MINUS']),
  KeymapAction(id: KeymapIds.expandAll, titleZh: '全部展开', titleEn: 'Expand All', keymapGroup: KeymapGroup.folding, mac: ['shift meta EQUALS'], other: ['ctrl shift EQUALS']),
  KeymapAction(id: KeymapIds.duplicate, titleZh: '复制行或所选内容', titleEn: 'Duplicate Line or Selection', keymapGroup: KeymapGroup.editing, mac: ['meta D'], other: ['ctrl D']),
  KeymapAction(id: KeymapIds.find, titleZh: '在当前文件中查找', titleEn: 'Find', keymapGroup: KeymapGroup.editing, mac: ['meta F'], other: ['ctrl F']),
  KeymapAction(id: KeymapIds.findNext, titleZh: '查找下一个', titleEn: 'Find Next', keymapGroup: KeymapGroup.editing, mac: ['meta G'], other: ['F3']),
  KeymapAction(id: KeymapIds.findPrevious, titleZh: '查找上一个', titleEn: 'Find Previous', keymapGroup: KeymapGroup.editing, mac: ['shift meta G'], other: ['shift F3']),
  KeymapAction(id: KeymapIds.rename, titleZh: '重命名', titleEn: 'Rename', keymapGroup: KeymapGroup.refactoring, mac: ['shift F6'], other: ['shift F6']),
];

KeymapAction? keymapActionById(String id) => keymapActions.where((a) => a.id == id).firstOrNull;

/// 当前的快捷键:默认键位加上用户改过的(只存改过的)。
class KeymapStore extends ChangeNotifier {
  KeymapStore({bool? mac}) : _mac = mac;

  final bool? _mac;
  bool get mac => _mac ?? isMacPlatform;

  /// 改过的操作 → 它的全部快捷键(空列表 = 去掉了所有快捷键)。
  final Map<String, List<KeyStroke>> _overrides = {};

  /// 最近一次从 IntelliJ 导入的配置名(设置页上显示)。
  String? importedFrom;

  List<KeyStroke> shortcutsOf(String id) {
    final o = _overrides[id];
    if (o != null) return List.unmodifiable(o);
    return [
      for (final t in keymapActionById(id)?.defaults(mac: mac) ?? const <String>[])
        if (KeyStroke.parse(t) case final k?) k,
    ];
  }

  /// 显示用的第一个快捷键(工具窗按钮的提示);没有为 null。
  String? labelOf(String id) => shortcutsOf(id).firstOrNull?.label(mac: mac);

  bool isCustomized(String id) => _overrides.containsKey(id);

  /// 正在用 [k] 的操作(除了 [except])。
  String? actionUsing(KeyStroke k, {String? except}) {
    for (final a in keymapActions) {
      if (a.id != except && shortcutsOf(a.id).contains(k)) return a.id;
    }
    return null;
  }

  /// 给 [id] 加一个快捷键;别的操作在用它的话从那边去掉(同一个键只能做一件事)。
  void add(String id, KeyStroke k) {
    final other = actionUsing(k, except: id);
    if (other != null) _set(other, shortcutsOf(other).where((s) => s != k).toList());
    final current = shortcutsOf(id);
    if (!current.contains(k)) _set(id, [...current, k]);
    notifyListeners();
  }

  void remove(String id, KeyStroke k) {
    _set(id, shortcutsOf(id).where((s) => s != k).toList());
    notifyListeners();
  }

  void reset(String id) {
    if (_overrides.remove(id) != null) notifyListeners();
  }

  void resetAll() {
    _overrides.clear();
    importedFrom = null;
    notifyListeners();
  }

  /// 和默认一样就不算改过。
  void _set(String id, List<KeyStroke> list) {
    final defaults = [
      for (final t in keymapActionById(id)?.defaults(mac: mac) ?? const <String>[])
        if (KeyStroke.parse(t) case final k?) k,
    ];
    if (listEquals(defaults, list)) {
      _overrides.remove(id);
    } else {
      _overrides[id] = list;
    }
  }

  /// 套用从 IntelliJ 读出来的快捷键([shortcuts]:操作 → 快捷键文字;没出现的操作保持现状)。
  void applyIntelliJ(String name, Map<String, List<String>> shortcuts) {
    for (final e in shortcuts.entries) {
      if (keymapActionById(e.key) == null) continue;
      _set(e.key, [for (final t in e.value) if (KeyStroke.parse(t) case final k?) k]);
    }
    importedFrom = name;
    notifyListeners();
  }

  /// 存进设置文件:只存改过的。
  Map<String, dynamic> toJson() => {
        if (importedFrom != null) 'importedFrom': importedFrom,
        'overrides': {for (final e in _overrides.entries) e.key: [for (final k in e.value) k.text]},
      };

  void applyJson(Map<String, dynamic> j) {
    _overrides.clear();
    final o = j['overrides'];
    if (o is Map) {
      for (final e in o.entries) {
        if (keymapActionById('${e.key}') == null || e.value is! List) continue;
        _overrides['${e.key}'] = [for (final t in e.value as List) if (KeyStroke.parse('$t') case final k?) k];
      }
    }
    importedFrom = j['importedFrom'] as String?;
    notifyListeners();
  }
}

// -----------------------------------------------------------------------------
// 从 IntelliJ 的快捷键配置里读
// -----------------------------------------------------------------------------

/// 一份 IntelliJ 快捷键配置(一个 keymap XML):名字、父配置、每个操作的快捷键。
class IntelliJKeymapFile {
  IntelliJKeymapFile({required this.name, required this.parent, required this.actions});

  final String name;
  final String? parent;

  /// 操作 → 快捷键文字。出现在这里的操作完全取代父配置里的(空列表 = 去掉了快捷键)。
  final Map<String, List<String>> actions;

  /// 解析 keymap XML;只取单键快捷键(两段式的 second-keystroke 跳过)。
  static IntelliJKeymapFile? parse(String xml) {
    final XmlElement root;
    try {
      root = parseXml(xml);
    } on FormatException {
      return null;
    }
    if (root.name != 'keymap') return null;
    final name = root.attributes['name'];
    if (name == null) return null;
    return IntelliJKeymapFile(
      name: name,
      parent: root.attributes['parent'],
      actions: {
        for (final a in root.childrenNamed('action'))
          if (a.attributes['id'] case final id?)
            id: [
              for (final k in a.childrenNamed('keyboard-shortcut'))
                if (k.attributes['second-keystroke'] == null && k.attributes['first-keystroke'] != null) k.attributes['first-keystroke']!,
            ],
      },
    );
  }
}

/// IntelliJ 自带的 macOS 键位(它们以 `$default` 为父,继承来的 Ctrl 会被换成 ⌘)。
const Set<String> _macBuiltinKeymaps = {'Mac OS X', 'Mac OS X 10.5+'};

/// 沿着父配置一路找,算出我们这些操作在 IntelliJ 里的快捷键。
/// [files]:能拿到的配置(按名字);链上缺的配置跳过(用户的配置还是生效)。
/// 链上缺了自带的配置时,那部分操作不出现在结果里,保持我们自己的默认(本来就和 IntelliJ 一样)。
Map<String, List<String>> resolveIntelliJKeymap(String active, Map<String, IntelliJKeymapFile> files) {
  final chain = <IntelliJKeymapFile>[];
  final seen = <String>{};
  String? name = active;
  var missingBuiltin = false;
  while (name != null && seen.add(name)) {
    final f = files[name];
    if (f == null) {
      missingBuiltin = true;
      break;
    }
    chain.add(f);
    name = f.parent;
  }
  final out = <String, List<String>>{};
  for (final action in keymapActions) {
    if (!action.inIntelliJ) continue;
    for (final id in [action.id, ...action.intellijIds]) {
      var macChain = false;
      List<String>? found;
      for (final f in chain) {
        if (_macBuiltinKeymaps.contains(f.name)) macChain = true;
        final s = f.actions[id];
        if (s != null) {
          // macOS 键位继承 $default 的快捷键时,Ctrl 换成 ⌘(IntelliJ 自己也这么换)
          found = macChain && f.name == r'$default' ? [for (final t in s) _ctrlToMeta(t)] : s;
          break;
        }
      }
      if (found != null) {
        out[action.id] = found;
        break;
      }
    }
    // 整条链都看过了(没有缺自带配置)还没找到:IntelliJ 里这个操作没有快捷键
    if (!out.containsKey(action.id) && !missingBuiltin && chain.isNotEmpty) {
      out[action.id] = const [];
    }
  }
  return out;
}

String _ctrlToMeta(String stroke) =>
    stroke.split(RegExp(r'\s+')).map((p) => p == 'control' || p == 'ctrl' ? 'meta' : p).join(' ');
