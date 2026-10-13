import 'package:flutter/material.dart';

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
Future<void> showSettingsDialog(BuildContext context, SettingsStore settings, {PluginManager? plugins, bool openPlugins = false}) =>
    showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(settings: settings, plugins: plugins, openPlugins: openPlugins),
    );

enum _Page { general, appearance, keymap, plugins }

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.settings, this.plugins, this.openPlugins = false});

  final SettingsStore settings;
  final PluginManager? plugins;

  /// 直接打开 Plugins 页(菜单 CodeLiteX ▸ Plugins…)。
  final bool openPlugins;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  late _Page _page = widget.openPlugins && widget.plugins != null ? _Page.plugins : _Page.general;

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
                    const Expanded(
                      child: Text('Settings', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                    IconButton(
                      tooltip: '关闭',
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
                          const Padding(
                            padding: EdgeInsets.fromLTRB(14, 4, 8, 6),
                            child: Text('Editor', style: _hint),
                          ),
                          _NavItem(label: 'General', selected: _page == _Page.general, onTap: () => setState(() => _page = _Page.general)),
                          _NavItem(label: 'Appearance', selected: _page == _Page.appearance, onTap: () => setState(() => _page = _Page.appearance)),
                          if (widget.settings.keymap != null) ...[
                            const SizedBox(height: 10),
                            _NavItem(label: 'Keymap', selected: _page == _Page.keymap, onTap: () => setState(() => _page = _Page.keymap)),
                          ],
                          if (widget.plugins != null) ...[
                            const SizedBox(height: 10),
                            _NavItem(label: 'Plugins', selected: _page == _Page.plugins, onTap: () => setState(() => _page = _Page.plugins)),
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
                          _Page.keymap => [KeymapPage(keymap: widget.settings.keymap!)],
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

  List<Widget> _general() {
    final s = widget.settings;
    return [
      const Text('Autosave', style: _section),
      const SizedBox(height: 10),
      _Toggle(
        label: '自动保存文件',
        hint: '停止输入后自动写回磁盘;切换标签、关闭标签或应用失去焦点时也会立即保存。关闭后需按 ⌘S 保存。',
        value: s.autosave,
        onChanged: s.setAutosave,
      ),
      const SizedBox(height: 8),
      Padding(
        padding: const EdgeInsets.only(left: 44),
        child: Row(
          children: [
            Text('停止输入后', style: s.autosave ? _text : _hint),
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
            Text('保存', style: s.autosave ? _text : _hint),
          ],
        ),
      ),
    ];
  }

  static String _label(Duration d) =>
      d.inMilliseconds < 1000 ? '${(d.inMilliseconds / 1000).toStringAsFixed(1)} 秒' : '${d.inSeconds} 秒';

  List<Widget> _appearance() {
    final a = widget.settings.appearance;
    return [
      const Text('Font', style: _section),
      const SizedBox(height: 10),
      Row(
        children: [
          const Text('编辑器字号', style: _text),
          const SizedBox(width: 14),
          _StepButton(
            icon: Icons.remove,
            tooltip: '减小',
            onTap: a.fontSize > EditorAppearance.minFontSize ? () => a.setFontSize(a.fontSize - 1) : null,
          ),
          Container(
            width: 52,
            alignment: Alignment.center,
            child: Text('${a.fontSize.round()}', key: const ValueKey('font-size-value'), style: _section),
          ),
          _StepButton(
            icon: Icons.add,
            tooltip: '增大',
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
            TextButton(onPressed: () => a.setFontSize(EditorAppearance.defaultFontSize), child: const Text('恢复默认')),
        ],
      ),
      const SizedBox(height: 22),
      const Text('Color Scheme', style: _section),
      const SizedBox(height: 4),
      const Text('只改变代码区的配色;IDE 外框保持 Darcula。', style: _hint),
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
      const Text('Editor Appearance', style: _section),
      const SizedBox(height: 10),
      _Toggle(label: '显示行号', value: a.showLineNumbers, onChanged: a.setShowLineNumbers),
      _Toggle(label: '显示缩进参考线', value: a.showIndentGuides, onChanged: a.setShowIndentGuides),
      _Toggle(label: '显示面包屑', value: a.showBreadcrumbs, onChanged: a.setShowBreadcrumbs),
      const SizedBox(height: 12),
      const Text('这些开关也可以在行号栏右键 ▸ Appearance 里切换。', style: _hint),
    ];
  }

}

class _NavItem extends StatelessWidget {
  const _NavItem({required this.label, required this.selected, required this.onTap});

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
  const _Chip({required this.label, required this.selected, required this.onTap});

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

  static const _sample = [
    '/** 计算总奖池 */',
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
