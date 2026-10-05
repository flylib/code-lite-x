import 'package:flutter/material.dart';

import '../../core/state/settings_store.dart';
import '../../core/theme/intellij_theme.dart';

const TextStyle _text = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 13);
const TextStyle _hint = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);
const TextStyle _section = TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600);

/// 打开设置(CodeLiteX ▸ Settings…,⌘,)。改动立即生效并写入 ~/.codelitex/settings.json。
Future<void> showSettingsDialog(BuildContext context, SettingsStore settings) => showDialog<void>(
      context: context,
      builder: (_) => SettingsDialog(settings: settings),
    );

enum _Page { general, appearance }

class SettingsDialog extends StatefulWidget {
  const SettingsDialog({super.key, required this.settings});

  final SettingsStore settings;

  @override
  State<SettingsDialog> createState() => _SettingsDialogState();
}

class _SettingsDialogState extends State<SettingsDialog> {
  _Page _page = _Page.general;

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
