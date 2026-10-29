import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/platform/workspace_io.dart' as io;
import '../../core/plugins/plugin_manager.dart';
import '../../core/state/settings_store.dart';
import '../../core/theme/intellij_theme.dart';
import '../editor/editor_appearance.dart';
import '../editor/syntax/color_schemes.dart';
import '../editor/syntax/languages.dart';
import '../editor/syntax/tokenizer.dart';
import '../plugins/plugins_page.dart';
import 'keymap_page.dart';

const TextStyle _text = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 13);
const TextStyle _hint = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);
const TextStyle _section = TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600);

/// 打开设置(CodeLiteX ▸ Settings…,⌘,)。改动立即生效并写入 ~/.codelitex/settings.json。
/// [openBuildTools]:直接打开 Build Tools 页(make 工具窗的设置按钮)。
Future<void> showSettingsDialog(BuildContext context, SettingsStore settings, {PluginManager? plugins, bool openPlugins = false, bool openBuildTools = false}) =>
    showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(settings: settings, plugins: plugins, openPlugins: openPlugins, openBuildTools: openBuildTools),
    );

enum _Page { general, appearance, language, keymap, buildTools, plugins }

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.settings, this.plugins, this.openPlugins = false, this.openBuildTools = false});

  final SettingsStore settings;
  final PluginManager? plugins;

  /// 直接打开 Plugins 页(菜单 CodeLiteX ▸ Plugins…)。
  final bool openPlugins;

  /// 直接打开 Build Tools 页。
  final bool openBuildTools;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late _Page _page = widget.openPlugins && widget.plugins != null
      ? _Page.plugins
      : (widget.openBuildTools ? _Page.buildTools : _Page.general);

  @override
  Widget build(BuildContext context) {
    final size = MediaQuery.sizeOf(context);
    return Dialog(
      backgroundColor: IntelliJTheme.panelBg,
      insetPadding: const EdgeInsets.all(40),
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: IntelliJTheme.border)),
      child: SizedBox(
        width: size.width < 760 ? size.width - 80 : 720,
        height: size.height < 560 ? size.height - 80 : 480,
        child: ListenableBuilder(
          listenable: Listenable.merge([widget.settings, widget.settings.appearance]),
          builder: (context, _) => Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 44,
                padding: const EdgeInsets.only(left: 16, right: 8),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle))),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(tr('设置', 'Settings'), style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      tooltip: tr('关闭', 'Close'),
                      icon: const Icon(Icons.close, size: 18, color: IntelliJTheme.textSecondary),
                      onPressed: () => Navigator.pop(context),
                    ),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    Container(
                      width: 190,
                      color: IntelliJTheme.headerBg,
                      padding: const EdgeInsets.symmetric(vertical: 8),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: [
                          // 同 IntelliJ:「外观与行为 ▸ 语言和地区」放在最上面
                          _NavItem(
                            key: const ValueKey('settings-nav-language'),
                            label: tr('语言和地区', 'Language and Region'),
                            selected: _page == _Page.language,
                            onTap: () => setState(() => _page = _Page.language),
                          ),
                          const SizedBox(height: 10),
                          Padding(
                            padding: const EdgeInsets.fromLTRB(14, 4, 8, 6),
                            child: Text(tr('编辑器', 'Editor'), style: _hint),
                          ),
                          _NavItem(label: tr('常规', 'General'), selected: _page == _Page.general, onTap: () => setState(() => _page = _Page.general)),
                          _NavItem(label: tr('外观', 'Appearance'), selected: _page == _Page.appearance, onTap: () => setState(() => _page = _Page.appearance)),
                          if (widget.settings.keymap != null) ...[
                            const SizedBox(height: 10),
                            _NavItem(label: tr('按键映射', 'Keymap'), selected: _page == _Page.keymap, onTap: () => setState(() => _page = _Page.keymap)),
                          ],
                          const SizedBox(height: 10),
                          _NavItem(label: tr('构建工具', 'Build Tools'), selected: _page == _Page.buildTools, onTap: () => setState(() => _page = _Page.buildTools)),
                          if (widget.plugins != null) ...[
                            const SizedBox(height: 10),
                            _NavItem(label: tr('插件', 'Plugins'), selected: _page == _Page.plugins, onTap: () => setState(() => _page = _Page.plugins)),
                          ],
                        ],
                      ),
                    ),
                    const VerticalDivider(width: 1, color: IntelliJTheme.borderSubtle),
                    Expanded(
                      child: ListView(
                        padding: const EdgeInsets.fromLTRB(24, 18, 24, 18),
                        children: switch (_page) {
                          _Page.general => _general(),
                          _Page.appearance => _appearance(),
                          _Page.language => _languagePage(),
                          _Page.keymap => [KeymapPage(keymap: widget.settings.keymap!)],
                          _Page.buildTools => [MakeSettings(settings: widget.settings)],
                          _Page.plugins => [PluginsPage(plugins: widget.plugins!)],
                        },
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  /// 语言和地区:界面语言(中文 / English),换了立刻生效。
  List<Widget> _languagePage() {
    final s = widget.settings;
    return [
      Text(tr('界面语言', 'Language'), style: _section),
      const SizedBox(height: 10),
      Row(
        children: [
          for (final lang in AppLanguage.values)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: _Chip(
                key: ValueKey('language-${lang.name}'),
                label: lang.label,
                selected: s.language == lang,
                onTap: () => s.setLanguage(lang),
              ),
            ),
        ],
      ),
      const SizedBox(height: 8),
      Text(tr('菜单、工具窗、对话框和提示都按这个语言显示,切换后立即生效。', 'Menus, tool windows, dialogs and notifications use this language. Takes effect immediately.'), style: _hint),
    ];
  }

  List<Widget> _general() {
    final s = widget.settings;
    return [
      Text(tr('自动保存', 'Autosave'), style: _section),
      const SizedBox(height: 10),
      _Toggle(
        label: tr('自动保存文件', 'Save files automatically'),
        hint: tr('停止输入后自动写回磁盘;切换标签、关闭标签或应用失去焦点时也会立即保存。关闭后需按 ⌘S 保存。',
            'Writes changes to disk when you stop typing, and right away when you switch or close a tab or leave the app. When off, press ⌘S to save.'),
        value: s.autosave,
        onChanged: s.setAutosave,
      ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.only(left: 44),
        child: Row(
          children: [
            Text(tr('停止输入后', 'Save'), style: s.autosave ? _text : _hint),
            const SizedBox(width: 10),
            DropdownButton<Duration>(
              value: SettingsStore.autosaveDelays.contains(s.autosaveDelay) ? s.autosaveDelay : null,
              hint: Text('${s.autosaveDelay.inMilliseconds} ms', style: _text),
              isDense: true,
              dropdownColor: IntelliJTheme.panelBg,
              style: _text,
              underline: Container(height: 1, color: IntelliJTheme.border),
              onChanged: s.autosave ? (v) => v == null ? null : s.setAutosaveDelay(v) : null,
              items: [
                for (final d in SettingsStore.autosaveDelays)
                  DropdownMenuItem(value: d, child: Text(_label(d), style: _text)),
              ],
            ),
            const SizedBox(width: 10),
            Text(tr('保存', 'after typing stops'), style: s.autosave ? _text : _hint),
          ],
        ),
      ),
    ];
  }

  static String _label(Duration d) =>
      d.inMilliseconds < 1000 ? '${(d.inMilliseconds / 1000).toStringAsFixed(1)} ${tr('秒', 's')}' : '${d.inSeconds} ${tr('秒', 's')}';

  List<Widget> _appearance() {
    final a = widget.settings.appearance;
    return [
      Text(tr('字体', 'Font'), style: _section),
      const SizedBox(height: 10),
      Row(
        children: [
          Text(tr('编辑器字号', 'Editor font size'), style: _text),
          const SizedBox(width: 14),
          _StepButton(
            icon: Icons.remove,
            tooltip: tr('减小', 'Smaller'),
            onTap: a.fontSize > EditorAppearance.minFontSize ? () => a.setFontSize(a.fontSize - 1) : null,
          ),
          Container(
            width: 52,
            alignment: Alignment.center,
            child: Text('${a.fontSize.round()}', key: const ValueKey('font-size-value'), style: _section),
          ),
          _StepButton(
            icon: Icons.add,
            tooltip: tr('增大', 'Larger'),
            onTap: a.fontSize < EditorAppearance.maxFontSize ? () => a.setFontSize(a.fontSize + 1) : null,
          ),
          const SizedBox(width: 12),
          for (final size in const [12, 14, 16, 18])
            Padding(
              padding: const EdgeInsets.only(right: 6),
              child: _Chip(label: '$size', selected: a.fontSize.round() == size, onTap: () => a.setFontSize(size.toDouble())),
            ),
          const Spacer(),
          if (a.fontSize != EditorAppearance.defaultFontSize)
            TextButton(onPressed: () => a.setFontSize(EditorAppearance.defaultFontSize), child: Text(tr('恢复默认', 'Reset'))),
        ],
      ),
      const SizedBox(height: 22),
      Text(tr('配色方案', 'Color Scheme'), style: _section),
      const SizedBox(height: 4),
      Text(tr('只改变代码区的配色;IDE 外框保持 Darcula。', 'Only changes the code area; the IDE frame stays Darcula.'), style: _hint),
      const SizedBox(height: 10),
      Wrap(
        spacing: 10,
        runSpacing: 10,
        children: [
          for (final scheme in builtinColorSchemes)
            _SchemeCard(
              scheme: scheme,
              fontSize: a.fontSize,
              selected: a.colorSchemeId == scheme.id,
              onTap: () => a.setColorScheme(scheme.id),
            ),
        ],
      ),
      const SizedBox(height: 22),
      Text(tr('编辑器外观', 'Editor Appearance'), style: _section),
      const SizedBox(height: 10),
      _Toggle(label: tr('显示行号', 'Show line numbers'), value: a.showLineNumbers, onChanged: a.setShowLineNumbers),
      _Toggle(label: tr('显示缩进参考线', 'Show indent guides'), value: a.showIndentGuides, onChanged: a.setShowIndentGuides),
      _Toggle(label: tr('显示面包屑', 'Show breadcrumbs'), value: a.showBreadcrumbs, onChanged: a.setShowBreadcrumbs),
      const SizedBox(height: 12),
      Text(tr('这些开关也可以在行号栏右键 ▸ 外观 里切换。', 'You can also switch these from the gutter: right-click ▸ Appearance.'), style: _hint),
    ];
  }

}

class _NavItem extends StatelessWidget {
  const _NavItem({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        child: Container(
          height: 28,
          margin: const EdgeInsets.symmetric(horizontal: 6),
          padding: const EdgeInsets.only(left: 18),
          alignment: Alignment.centerLeft,
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2E436E) : null,
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label, overflow: TextOverflow.ellipsis, style: _text),
        ),
      );
}

class _Toggle extends StatelessWidget {
  const _Toggle({required this.label, required this.value, required this.onChanged, this.hint});

  final String label;
  final String? hint;
  final bool value;
  final ValueChanged<bool> onChanged;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: () => onChanged(!value),
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 6),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 36,
                height: 20,
                child: FittedBox(
                  child: Switch(value: value, onChanged: onChanged, materialTapTargetSize: MaterialTapTargetSize.shrinkWrap),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(label, style: _text),
                    if (hint != null) ...[const SizedBox(height: 3), Text(hint!, style: _hint)],
                  ],
                ),
              ),
            ],
          ),
        ),
      );
}

class _StepButton extends StatelessWidget {
  const _StepButton({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.all(4),
            decoration: BoxDecoration(border: Border.all(color: IntelliJTheme.border), borderRadius: BorderRadius.circular(4)),
            child: Icon(icon, size: 14, color: onTap == null ? IntelliJTheme.textMuted : IntelliJTheme.textHigh),
          ),
        ),
      );
}

class _Chip extends StatelessWidget {
  const _Chip({super.key, required this.label, required this.selected, required this.onTap});

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(
            color: selected ? const Color(0xFF2E436E) : null,
            border: Border.all(color: selected ? IntelliJTheme.accentBlue : IntelliJTheme.border),
            borderRadius: BorderRadius.circular(4),
          ),
          child: Text(label, style: _text),
        ),
      );
}

/// 配色方案卡片:用该方案给一小段真实代码着色,所见即所得。
class _SchemeCard extends StatelessWidget {
  const _SchemeCard({required this.scheme, required this.fontSize, required this.selected, required this.onTap});

  final EditorColorScheme scheme;
  final double fontSize;
  final bool selected;
  final VoidCallback onTap;

  static List<String> get _sample => [
    tr('/** 计算总奖池 */', '/** Total prize pool */'),
    '@Override',
    'public int total(List<Item> items) {',
    '    return items.size() * 42;',
    '}',
  ];

  @override
  Widget build(BuildContext context) {
    final java = languages.byId('java')!;
    var state = 0;
    final lines = <Widget>[];
    for (final line in _sample) {
      final r = tokenizeLine(java, line, state);
      state = r.endState;
      lines.add(RichText(
        maxLines: 1,
        overflow: TextOverflow.clip,
        text: TextSpan(
          style: TextStyle(
            color: scheme.foreground,
            fontSize: 11,
            height: 1.45,
            fontFamily: IntelliJMetrics.codeFontFamily,
            fontFamilyFallback: IntelliJMetrics.codeFontFallback,
          ),
          children: [
            for (final t in r.tokens) TextSpan(text: line.substring(t.start, t.end), style: scheme.styleOf(t.kind)),
          ],
        ),
      ));
    }
    return InkWell(
      key: ValueKey('scheme-${scheme.id}'),
      onTap: onTap,
      borderRadius: BorderRadius.circular(6),
      child: Container(
        width: 232,
        decoration: BoxDecoration(
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: selected ? IntelliJTheme.accentBlue : IntelliJTheme.border, width: selected ? 2 : 1),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              color: scheme.background,
              padding: const EdgeInsets.fromLTRB(10, 8, 6, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: lines),
            ),
            Container(
              color: IntelliJTheme.headerBg,
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
              child: Row(
                children: [
                  Expanded(child: Text(scheme.name, overflow: TextOverflow.ellipsis, style: _text)),
                  if (selected) const Icon(Icons.check, size: 14, color: IntelliJTheme.accentBlue),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// 设置 ▸ Build Tools ▸ Make(同 IntelliJ 的 Path to Make executable):make 可执行文件的路径,
/// 留空用 PATH 里的 make。「检测」跑一次 `make --version` 看能不能用。
class MakeSettings extends StatefulWidget {
  const MakeSettings({super.key, required this.settings});

  final SettingsStore settings;

  @override
  State<MakeSettings> createState() => _MakeSettingsState();
}

class _MakeSettingsState extends State<MakeSettings> {
  late final TextEditingController _path = TextEditingController(text: widget.settings.makePath);
  String? _version;
  String? _error;
  bool _checking = false;

  @override
  void dispose() {
    _path.dispose();
    super.dispose();
  }

  Future<void> _browse() async {
    final current = _path.text.trim();
    final dir = current.contains('/') ? current.substring(0, current.lastIndexOf('/')) : '/usr/bin';
    final picked = await io.pickFile(message: tr('选择 make 可执行文件', 'Choose the make executable'), directory: dir);
    if (picked == null || !mounted) return;
    _path.text = picked;
    widget.settings.setMakePath(picked);
    await _check();
  }

  Future<void> _check() async {
    setState(() {
      _checking = true;
      _version = _error = null;
    });
    final (version, error) = await io.detectMake(_path.text);
    if (!mounted) return;
    setState(() {
      _checking = false;
      _version = version;
      _error = error;
    });
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        const Text('Make', style: _section),
        const SizedBox(height: 4),
        Text(tr('make 工具窗和 Makefile 行号栏的 ▶ 都用它运行目标;留空用 PATH 里的 make。', 'The make tool window and the ▶ in a Makefile gutter run targets with it. Leave empty to use make from PATH.'), style: _hint),
        const SizedBox(height: 12),
        Row(
          children: [
            Text(tr('make 可执行文件', 'Path to make executable'), style: _text),
            const SizedBox(width: 12),
            Expanded(
              child: TextField(
                key: const ValueKey('make-path-field'),
                controller: _path,
                style: _text,
                decoration: const InputDecoration(
                  isDense: true,
                  hintText: 'make',
                  hintStyle: _hint,
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(horizontal: 8, vertical: 8),
                ),
                onChanged: widget.settings.setMakePath,
                onSubmitted: (_) => _check(),
              ),
            ),
            const SizedBox(width: 8),
            OutlinedButton(onPressed: _browse, child: Text(tr('浏览…', 'Browse…'))),
            const SizedBox(width: 8),
            OutlinedButton(key: const ValueKey('make-detect'), onPressed: _checking ? null : _check, child: Text(tr('检测', 'Test'))),
          ],
        ),
        const SizedBox(height: 8),
        if (_checking)
          Text(tr('正在检测…', 'Testing…'), style: _hint)
        else if (_version != null)
          Row(children: [
            const Icon(Icons.check_circle_outline, size: 14, color: IntelliJTheme.gitGreen),
            const SizedBox(width: 6),
            Flexible(child: Text(_version!, style: _text, overflow: TextOverflow.ellipsis)),
          ])
        else if (_error != null)
          Row(children: [
            const Icon(Icons.error_outline, size: 14, color: IntelliJTheme.diagError),
            const SizedBox(width: 6),
            Flexible(child: Text(_error!, style: const TextStyle(color: IntelliJTheme.diagError, fontSize: 12), overflow: TextOverflow.ellipsis)),
          ]),
      ],
    );
  }
}
