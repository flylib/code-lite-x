import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/keymap/intellij_keymap_io.dart' as intellij;
import '../../core/keymap/keymap.dart';
import '../../core/theme/intellij_theme.dart';

const TextStyle _text = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 13);
const TextStyle _hint = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);
const TextStyle _section = TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600);

typedef IntelliJKeymapReader = Future<({String name, Map<String, List<String>> shortcuts, String source})?> Function();

/// 设置 ▸ Keymap:每个操作的快捷键,可以加、删、恢复默认,也可以从本机的 IntelliJ 导入。
class KeymapPage extends StatefulWidget {
  const KeymapPage({super.key, required this.keymap, this.readIntelliJ});

  final KeymapStore keymap;

  /// 读本机 IntelliJ 的快捷键配置;测试里换掉。
  final IntelliJKeymapReader? readIntelliJ;

  @override
  State<KeymapPage> createState() => _KeymapPageState();
}

class _KeymapPageState extends State<KeymapPage> {
  String? _message;
  bool _importing = false;

  KeymapStore get _keymap => widget.keymap;

  Future<void> _import() async {
    setState(() {
      _importing = true;
      _message = null;
    });
    final r = await (widget.readIntelliJ ?? intellij.readIntelliJKeymap)();
    if (!mounted) return;
    setState(() {
      _importing = false;
      if (r == null) {
        _message = '没有找到 IntelliJ IDEA 的配置。';
      } else {
        _keymap.applyIntelliJ(r.name, r.shortcuts);
        _message = '已从 ${r.source} 导入「${r.name}」。';
      }
    });
  }

  Future<void> _record(KeymapAction action) async {
    final k = await showDialog<KeyStroke>(
      context: context,
      builder: (_) => _RecordDialog(keymap: _keymap, action: action),
    );
    if (k != null) _keymap.add(action.id, k);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _keymap,
      builder: (context, _) {
        final groups = <String, List<KeymapAction>>{};
        for (final a in keymapActions) {
          groups.putIfAbsent(a.group, () => []).add(a);
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                const Expanded(child: Text('Keymap', style: _section)),
                TextButton.icon(
                  key: const ValueKey('keymap-import'),
                  onPressed: _importing ? null : _import,
                  icon: const Icon(Icons.download_outlined, size: 16),
                  label: const Text('从 IntelliJ 导入'),
                ),
                const SizedBox(width: 4),
                TextButton(onPressed: _keymap.resetAll, child: const Text('全部恢复默认')),
              ],
            ),
            Text(
              _message ??
                  (_keymap.importedFrom != null
                      ? '在用从 IntelliJ 导入的「${_keymap.importedFrom}」;默认键位同 IntelliJ。'
                      : '默认键位同 IntelliJ(${_keymap.mac ? 'macOS' : 'Default'})。点 + 按下新的组合键即可添加。'),
              style: _hint,
            ),
            const SizedBox(height: 14),
            for (final g in groups.entries) ...[
              Text(g.key, style: _section),
              const SizedBox(height: 6),
              for (final a in g.value) _row(a),
              const SizedBox(height: 14),
            ],
          ],
        );
      },
    );
  }

  Widget _row(KeymapAction a) {
    final shortcuts = _keymap.shortcutsOf(a.id);
    return Container(
      key: ValueKey('keymap-row-${a.id}'),
      height: 34,
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle))),
      child: Row(
        children: [
          Expanded(
            child: Text(
              a.title,
              overflow: TextOverflow.ellipsis,
              maxLines: 1,
              style: _text.copyWith(color: _keymap.isCustomized(a.id) ? IntelliJTheme.link : IntelliJTheme.textPrimary),
            ),
          ),
          for (final k in shortcuts)
            Padding(
              padding: const EdgeInsets.only(left: 6),
              child: _ShortcutChip(label: k.label(mac: _keymap.mac), onRemove: () => _keymap.remove(a.id, k)),
            ),
          if (shortcuts.isEmpty) const Text('无', style: _hint),
          _IconAction(icon: Icons.add, tooltip: '添加快捷键', onTap: () => _record(a), key: ValueKey('keymap-add-${a.id}')),
          SizedBox(
            width: 28,
            child: _keymap.isCustomized(a.id) ? _IconAction(icon: Icons.restart_alt, tooltip: '恢复默认', onTap: () => _keymap.reset(a.id)) : null,
          ),
        ],
      ),
    );
  }
}

class _ShortcutChip extends StatelessWidget {
  const _ShortcutChip({required this.label, required this.onRemove});

  final String label;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 24,
      padding: const EdgeInsets.only(left: 8, right: 2),
      decoration: BoxDecoration(
        color: IntelliJTheme.chipBg,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: IntelliJTheme.border),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(label, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5)),
          InkWell(
            onTap: onRemove,
            borderRadius: BorderRadius.circular(3),
            child: Tooltip(
              message: '去掉 $label',
              child: const Padding(padding: EdgeInsets.all(3), child: Icon(Icons.close, size: 12, color: IntelliJTheme.textMuted)),
            ),
          ),
        ],
      ),
    );
  }
}

class _IconAction extends StatelessWidget {
  const _IconAction({super.key, required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 400),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: SizedBox(width: 28, height: 28, child: Icon(icon, size: 16, color: IntelliJTheme.textSecondary)),
      ),
    );
  }
}

/// 「按下新的快捷键」:收下一个带普通键的组合;单按 Esc 取消。被别的操作用着时提示会从那边移走。
class _RecordDialog extends StatefulWidget {
  const _RecordDialog({required this.keymap, required this.action});

  final KeymapStore keymap;
  final KeymapAction action;

  @override
  State<_RecordDialog> createState() => _RecordDialogState();
}

class _RecordDialogState extends State<_RecordDialog> {
  KeyStroke? _stroke;

  KeyEventResult _onKey(FocusNode node, KeyEvent e) {
    if (e is! KeyDownEvent) return KeyEventResult.handled;
    final k = KeyStroke.fromEvent(e, HardwareKeyboard.instance);
    if (k == null) return KeyEventResult.handled; // 只按了修饰键:等下一个键
    if (k.key == 'ESCAPE' && !k.meta && !k.ctrl && !k.alt && !k.shift) {
      Navigator.pop(context);
      return KeyEventResult.handled;
    }
    setState(() => _stroke = k);
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    final k = _stroke;
    final usedBy = k == null ? null : widget.keymap.actionUsing(k, except: widget.action.id);
    final usedTitle = usedBy == null ? null : keymapActionById(usedBy)?.title;
    return AlertDialog(
      backgroundColor: IntelliJTheme.popupBg,
      title: Text('「${widget.action.title}」的快捷键', style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: Focus(
        autofocus: true,
        onKeyEvent: _onKey,
        child: SizedBox(
          width: 340,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Container(
                key: const ValueKey('keymap-recorded'),
                height: 40,
                alignment: Alignment.center,
                decoration: BoxDecoration(
                  color: IntelliJTheme.islandBg,
                  borderRadius: BorderRadius.circular(6),
                  border: Border.all(color: IntelliJTheme.accentBlue),
                ),
                child: Text(
                  k?.label(mac: widget.keymap.mac) ?? '按下组合键…',
                  style: TextStyle(color: k == null ? IntelliJTheme.textMuted : IntelliJTheme.textHigh, fontSize: 16),
                ),
              ),
              const SizedBox(height: 10),
              Text(
                usedTitle != null ? '这个组合已用于「$usedTitle」,确定后会从那里移走。' : '单按 Esc 取消。',
                style: TextStyle(color: usedTitle != null ? IntelliJTheme.accentYellow : IntelliJTheme.textMuted, fontSize: 12),
              ),
            ],
          ),
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('取消')),
        TextButton(onPressed: k == null ? null : () => Navigator.pop(context, k), child: const Text('确定')),
      ],
    );
  }
}
