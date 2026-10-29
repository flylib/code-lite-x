import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform/paths.dart';
import '../../core/theme/intellij_theme.dart';
import '../../core/l10n/l10n.dart';

/// 文件树 ▸ Rename(⇧F6)的对话框,照 IntelliJ:`Rename file 'Foo.java' to:` + 输入框,
/// 打开时选中扩展名前面的部分(目录选中整个名字)。回车确定、Esc 取消。
/// [onRename] 真去改名,返回失败原因(null 成功);失败时对话框不关,原因显示在输入框下面。
/// 改成功返回新名字,取消返回 null。
Future<String?> showRenameDialog(
  BuildContext context, {
  required String name,
  required bool isDir,
  required Future<String?> Function(String newName) onRename,
}) =>
    showDialog<String>(
      context: context,
      builder: (_) => RenameDialog(name: name, isDir: isDir, onRename: onRename),
    );

class RenameDialog extends StatefulWidget {
  const RenameDialog({super.key, required this.name, required this.isDir, required this.onRename});

  final String name;
  final bool isDir;
  final Future<String?> Function(String newName) onRename;

  @override
  State<RenameDialog> createState() => _RenameDialogState();
}

class _RenameDialogState extends State<RenameDialog> {
  late final TextEditingController _text = TextEditingController(text: widget.name);
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    // 选中扩展名前的部分(`.gitignore` 这种点开头的整个选中)
    final dot = widget.isDir ? -1 : widget.name.lastIndexOf('.');
    _text.selection = TextSelection(baseOffset: 0, extentOffset: dot > 0 ? dot : widget.name.length);
    _text.addListener(() {
      if (_error != null) setState(() => _error = null);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  bool get _unchanged => _text.text.trim() == widget.name;

  Future<void> _submit() async {
    if (_busy) return;
    final name = _text.text.trim();
    if (_unchanged) {
      Navigator.pop(context);
      return;
    }
    final bad = renameNameError(name);
    if (bad != null) {
      setState(() => _error = bad);
      return;
    }
    setState(() => _busy = true);
    final err = await widget.onRename(name);
    if (!mounted) return;
    if (err == null) {
      Navigator.pop(context, name);
    } else {
      setState(() {
        _busy = false;
        _error = err;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text(tr('重命名', 'Rename'), style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Text(
              widget.isDir
                  ? tr("将目录 '${widget.name}' 重命名为:", "Rename directory '${widget.name}' to:")
                  : tr("将文件 '${widget.name}' 重命名为:", "Rename file '${widget.name}' to:"),
              overflow: TextOverflow.ellipsis,
              maxLines: 2,
              style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12),
            ),
            const SizedBox(height: 8),
            CallbackShortcuts(
              bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context)},
              child: TextField(
                key: const ValueKey('rename-field'),
                controller: _text,
                autofocus: true,
                enabled: !_busy,
                style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13),
                cursorColor: IntelliJTheme.caret,
                decoration: InputDecoration(
                  isDense: true,
                  contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                  filled: true,
                  fillColor: IntelliJTheme.editorBg,
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(5),
                    borderSide: BorderSide(color: error != null ? IntelliJTheme.diagError : IntelliJTheme.border),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(5),
                    borderSide: BorderSide(color: error != null ? IntelliJTheme.diagError : IntelliJTheme.accentBlue, width: 1.5),
                  ),
                  disabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(5),
                    borderSide: const BorderSide(color: IntelliJTheme.border),
                  ),
                ),
                onSubmitted: (_) => _submit(),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 6),
              Text(error, key: const ValueKey('rename-error'), style: const TextStyle(color: IntelliJTheme.diagError, fontSize: 12)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消', 'Cancel'))),
        FilledButton(
          key: const ValueKey('rename-confirm'),
          onPressed: _busy ? null : _submit,
          child: Text(tr('重命名', 'Rename')),
        ),
      ],
    );
  }
}
