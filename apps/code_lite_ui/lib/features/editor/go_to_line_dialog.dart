import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';

/// 「转到行:列」框里的输入 → 跳到哪(行、列都从 0 起)。和 IntelliJ 一样认:
/// `256`(那一行行首)、`256:5`(第 5 列)、`:5`(当前行第 5 列),也认 `256,5`;
/// 行超过文件末尾就到最后一行,列超过行尾就到行尾。写错了(字母、0、负数)返回 null。
/// [lineLengths] 是每行的长度(用来夹住行号和列号)。
({int line, int col})? parseLineColumn(String input, {required int currentLine, required List<int> lineLengths}) {
  final m = RegExp(r'^\s*(\d*)\s*(?:[:,]\s*(\d*)\s*)?$').firstMatch(input);
  if (m == null) return null;
  final l = m.group(1)!, c = m.group(2);
  if (l.isEmpty && (c == null || c.isEmpty)) return null;
  final lineNo = l.isEmpty ? currentLine + 1 : int.parse(l);
  final colNo = c == null || c.isEmpty ? 1 : int.parse(c);
  if (lineNo < 1 || colNo < 1) return null;
  final last = lineLengths.isEmpty ? 0 : lineLengths.length - 1;
  final line = (lineNo - 1).clamp(0, last);
  final len = lineLengths.isEmpty ? 0 : lineLengths[line];
  return (line: line, col: (colNo - 1).clamp(0, len));
}

/// ⌘L(IntelliJ 的 Go to Line:Column,其它平台 Ctrl+G)的对话框:`[Line] [:column]:` + 输入框,
/// 打开时填着当前的「行:列」(从 1 起)并全选;回车 / 确定跳过去,Esc / 取消关掉。输错了输入框标红、不关。
Future<({int line, int col})?> showGoToLineDialog(
  BuildContext context, {
  required int line,
  required int col,
  required List<int> lineLengths,
}) =>
    showDialog<({int line, int col})>(
      context: context,
      builder: (_) => GoToLineDialog(line: line, col: col, lineLengths: lineLengths),
    );

class GoToLineDialog extends StatefulWidget {
  const GoToLineDialog({super.key, required this.line, required this.col, required this.lineLengths});

  /// 当前光标(从 0 起)。
  final int line;
  final int col;
  final List<int> lineLengths;

  @override
  State<GoToLineDialog> createState() => _GoToLineDialogState();
}

class _GoToLineDialogState extends State<GoToLineDialog> {
  late final TextEditingController _text = TextEditingController(text: '${widget.line + 1}:${widget.col + 1}');
  bool _invalid = false;

  @override
  void initState() {
    super.initState();
    _text.selection = TextSelection(baseOffset: 0, extentOffset: _text.text.length);
    _text.addListener(() {
      if (_invalid) setState(() => _invalid = false);
    });
  }

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  void _submit() {
    final at = parseLineColumn(_text.text, currentLine: widget.line, lineLengths: widget.lineLengths);
    if (at == null) {
      setState(() => _invalid = true);
      return;
    }
    Navigator.pop(context, at);
  }

  @override
  Widget build(BuildContext context) {
    final border = _invalid ? IntelliJTheme.diagError : IntelliJTheme.border;
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text(tr('转到行:列', 'Go to Line:Column'), style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 360,
        child: Row(
          children: [
            Flexible(
              child: Text(
                tr('[行] [:列]:', '[Line] [:column]:'),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
                style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 13),
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 200,
              child: CallbackShortcuts(
                bindings: {const SingleActivator(LogicalKeyboardKey.escape): () => Navigator.pop(context)},
                child: TextField(
                  key: const ValueKey('goto-line-field'),
                  controller: _text,
                  autofocus: true,
                  style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13),
                  cursorColor: IntelliJTheme.caret,
                  decoration: InputDecoration(
                    isDense: true,
                    contentPadding: const EdgeInsets.symmetric(horizontal: 8, vertical: 9),
                    filled: true,
                    fillColor: IntelliJTheme.editorBg,
                    enabledBorder: OutlineInputBorder(borderRadius: BorderRadius.circular(5), borderSide: BorderSide(color: border)),
                    focusedBorder: OutlineInputBorder(
                      borderRadius: BorderRadius.circular(5),
                      borderSide: BorderSide(color: _invalid ? IntelliJTheme.diagError : IntelliJTheme.accentBlue, width: 1.5),
                    ),
                  ),
                  onSubmitted: (_) => _submit(),
                ),
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消', 'Cancel'))),
        FilledButton(key: const ValueKey('goto-line-ok'), onPressed: _submit, child: Text(tr('确定', 'OK'))),
      ],
    );
  }
}
