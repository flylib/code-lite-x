import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';
import 'line_diff.dart';

/// 并排差异视图共用的行高、配色与单元格(Commit 差异标签与 PR 差异标签)。
const double diffRowHeight = 20;

const TextStyle diffCodeStyle = TextStyle(
  fontFamily: IntelliJMetrics.codeFontFamily,
  fontFamilyFallback: IntelliJMetrics.codeFontFallback,
  fontSize: 12,
  height: 1.4,
  color: IntelliJTheme.textPrimary,
);
const TextStyle diffSmallStyle = TextStyle(color: IntelliJTheme.textSecondary, fontSize: 12);

// IntelliJ Darcula 的差异底色:修改蓝、新增绿、删除灰;行内真正改动的部分再深一档。
const Color diffModBg = Color(0xFF293A4F);
const Color diffModWord = Color(0xFF385A82);
const Color diffInsBg = Color(0xFF294436);
const Color diffDelBg = Color(0xFF484A4A);
const Color diffGapBg = Color(0xFF232427);

/// 一行两侧的底色。
(Color?, Color?) diffRowColors(DiffRowKind kind) => switch (kind) {
      DiffRowKind.equal => (null, null),
      DiffRowKind.modify => (diffModBg, diffModBg),
      DiffRowKind.delete => (diffDelBg, diffGapBg),
      DiffRowKind.insert => (diffGapBg, diffInsBg),
    };

/// 行号(0 起的 [n] 显示为 n+1;null 显示空白)。
Widget diffLineNumber(int? n, {double width = 36}) => SizedBox(
      width: width,
      child: Text(
        n == null ? '' : '${n + 1}',
        textAlign: TextAlign.right,
        style: const TextStyle(color: IntelliJTheme.textGutter, fontSize: 11, fontFamily: IntelliJMetrics.codeFontFamily),
      ),
    );

/// 一侧的一格代码。[highlight] 是行内改动区间 (起, 止)。
Widget diffCell(String? text, Color? bg, (int, int)? highlight) {
  InlineSpan content;
  if (text == null) {
    content = const TextSpan(text: '');
  } else if (highlight == null || highlight.$1 >= highlight.$2) {
    content = TextSpan(text: text.isEmpty ? ' ' : text);
  } else {
    content = TextSpan(children: [
      TextSpan(text: text.substring(0, highlight.$1)),
      TextSpan(text: text.substring(highlight.$1, highlight.$2), style: const TextStyle(backgroundColor: diffModWord)),
      TextSpan(text: text.substring(highlight.$2)),
    ]);
  }
  return Container(
    color: bg,
    padding: const EdgeInsets.symmetric(horizontal: 10),
    alignment: Alignment.centerLeft,
    child: RichText(
      text: TextSpan(style: diffCodeStyle, children: [content]),
      maxLines: 1,
      softWrap: false,
      overflow: TextOverflow.clip,
    ),
  );
}

/// 文本拆行:末尾换行不算一行。
List<String> splitDiffLines(String text) {
  if (text.isEmpty) return const [];
  final lines = text.split('\n');
  if (lines.last.isEmpty) lines.removeLast();
  return lines;
}

/// 差异工具条上的小图标按钮。
class DiffToolIcon extends StatelessWidget {
  const DiffToolIcon({super.key, required this.icon, required this.tooltip, required this.onTap, this.active = false});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.all(5),
          decoration: active ? BoxDecoration(color: IntelliJTheme.hoverBg, borderRadius: BorderRadius.circular(4)) : null,
          child: Icon(icon, size: 15, color: onTap == null ? IntelliJTheme.textMuted : IntelliJTheme.textSecondary),
        ),
      ),
    );
  }
}
