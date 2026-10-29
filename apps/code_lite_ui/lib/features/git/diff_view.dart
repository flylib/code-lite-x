import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';

/// 统一 diff 文本的只读视图:增删行着色,hunk 头淡显。
class DiffView extends StatelessWidget {
  const DiffView({super.key, required this.diff});

  final String diff;

  static const _mono = TextStyle(fontFamily: 'Menlo', fontFamilyFallback: ['monospace'], fontSize: 12, height: 1.4);

  @override
  Widget build(BuildContext context) {
    final lines = diff.isEmpty ? [tr('(没有差异)', '(No differences)')] : diff.split('\n');
    return Container(
      color: IntelliJTheme.editorBg,
      child: SelectionArea(
        child: ListView.builder(
          padding: const EdgeInsets.symmetric(vertical: 6),
          itemCount: lines.length,
          itemBuilder: (context, i) {
            final line = lines[i];
            Color? bg;
            var fg = IntelliJTheme.textPrimary;
            if (line.startsWith('+++') || line.startsWith('---') || line.startsWith('diff ') || line.startsWith('index ')) {
              fg = IntelliJTheme.textMuted;
            } else if (line.startsWith('@@')) {
              fg = const Color(0xFF6897BB);
              bg = const Color(0xFF6897BB).withValues(alpha: 0.08);
            } else if (line.startsWith('+')) {
              bg = IntelliJTheme.gitGreen.withValues(alpha: 0.16);
              fg = IntelliJTheme.textHigh;
            } else if (line.startsWith('-')) {
              bg = IntelliJTheme.gitRed.withValues(alpha: 0.16);
              fg = IntelliJTheme.textHigh;
            }
            return Container(
              color: bg,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Text(line.isEmpty ? ' ' : line, style: _mono.copyWith(color: fg), softWrap: false),
            );
          },
        ),
      ),
    );
  }
}

/// 只读的纯文本(某个版本的文件内容)。
class PlainTextView extends StatelessWidget {
  const PlainTextView({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    return Container(
      color: IntelliJTheme.editorBg,
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: SelectableText(text, style: DiffView._mono.copyWith(color: IntelliJTheme.textPrimary)),
      ),
    );
  }
}
