import 'package:flutter/material.dart';
import '../../core/theme/intellij_theme.dart';
import '../../core/l10n/l10n.dart';

/// Diagnostics display models for the editor.
class EditorDiagnostic {
  final int line;

  /// 范围的结束行;跨行时 [colEnd] 属于这一行,不是 [line]。
  final int endLine;
  final int colStart;
  final int colEnd;
  final int severity; // 1: Error, 2: Warning, 3: Info, 4: Hint
  final String message;
  final String? code;
  final String? source;

  /// LSP 的 DiagnosticTag:1 = Unnecessary(没用到的符号 / import),2 = Deprecated。
  final List<int> tags;

  const EditorDiagnostic({
    required this.line,
    int? endLine,
    required this.colStart,
    required this.colEnd,
    required this.severity,
    required this.message,
    this.code,
    this.source,
    this.tags = const [],
  }) : endLine = endLine ?? line;

  factory EditorDiagnostic.fromJson(Map<String, dynamic> json) {
    int line = 0;
    int? endLine;
    int colStart = 0;
    int colEnd = 0;
    if (json['range'] != null) {
      final range = json['range'] as Map<String, dynamic>;
      final start = range['start'] as Map<String, dynamic>?;
      final end = range['end'] as Map<String, dynamic>?;
      line = (start?['line'] as num?)?.toInt() ?? 0;
      colStart = (start?['character'] as num?)?.toInt() ?? 0;
      colEnd = (end?['character'] as num?)?.toInt() ?? (colStart + 5);
      endLine = (end?['line'] as num?)?.toInt();
    } else {
      line = (json['line_start'] as num?)?.toInt() ?? 0;
      colStart = (json['col_start'] as num?)?.toInt() ?? 0;
      colEnd = (json['col_end'] as num?)?.toInt() ?? (colStart + 5);
    }

    return EditorDiagnostic(
      line: line,
      endLine: endLine,
      colStart: colStart,
      colEnd: colEnd,
      severity: (json['severity'] as num?)?.toInt() ?? 1,
      message: json['message'] as String? ?? tr('诊断错误', 'Diagnostic error'),
      code: json['code']?.toString(),
      source: json['source'] as String?,
      tags: [for (final t in (json['tags'] as List? ?? const [])) if (t is num) t.toInt()],
    );
  }

  /// 「没用到」:IntelliJ 把变量 / 字段 / import 的文字变灰,不画下划线,也不算警告。
  bool get isUnnecessary => tags.contains(1);

  bool get isError => severity == 1 && !isUnnecessary;
  bool get isWarning => severity == 2 && !isUnnecessary;
}

/// 没用到的符号的文字颜色(灰)。
const Color unusedTextColor = Color(0xFF808385);

/// 错误的文字颜色(找不到定义的变量 / 方法、语法错误……出问题的那个词)。
const Color errorTextColor = Color(0xFFF97A7A);

/// 诊断在 [lineText] 这一行里占的列范围 [起, 止);不在这一行或没有可染的内容返回 null。
///
/// 范围跨到后面的行时染到行尾。空范围(服务端只给了一个位置)染那里的整个标识符,
/// 不在标识符上就染紧挨着的一个字符,免得错误没有任何标记。
(int, int)? _rangeOnLine(EditorDiagnostic d, String lineText, int lineIndex) {
  if (d.line != lineIndex || lineText.isEmpty) return null;
  final start = d.colStart.clamp(0, lineText.length);
  var end = d.endLine > d.line ? lineText.length : d.colEnd.clamp(0, lineText.length);
  if (end > start) return (start, end);

  bool word(int i) => RegExp(r'[A-Za-z0-9_$]').hasMatch(lineText[i]);
  var from = start, to = start;
  while (from > 0 && word(from - 1)) {
    from--;
  }
  while (to < lineText.length && word(to)) {
    to++;
  }
  if (to > from) return (from, to);
  return start < lineText.length ? (start, start + 1) : (lineText.length - 1, lineText.length);
}

/// 按 [diagnostics] 给 [spans](一行的着色片段)里的范围改前景色:
/// 错误 → 红色(IntelliJ 的做法:出问题的词变红,不画下划线),没用到的符号 → 灰色。两者重叠时错误优先。
/// 只改前景色,保留粗体 / 斜体等其它样式,也不改变文字,所以不影响宽度测量。
/// [lineText] 是这一行的文字;没有要染色的就原样返回 [spans]。
List<TextSpan> colorDiagnosticRanges(List<TextSpan> spans, String lineText, Iterable<EditorDiagnostic> diagnostics, int lineIndex) {
  // 按优先级排:靠前的优先(错误 > 没用到)
  final ranges = <(int, int, Color)>[];
  for (final d in diagnostics) {
    if (!d.isError) continue;
    if (_rangeOnLine(d, lineText, lineIndex) case (final a, final b)?) ranges.add((a, b, errorTextColor));
  }
  for (final d in diagnostics) {
    if (!d.isUnnecessary) continue;
    // 灰色只用来标「没用到」:空范围不去猜(没有东西可灰)
    final start = d.colStart.clamp(0, lineText.length);
    final end = d.line != lineIndex ? start : (d.endLine > d.line ? lineText.length : d.colEnd.clamp(0, lineText.length));
    if (d.line == lineIndex && end > start) ranges.add((start, end, unusedTextColor));
  }
  if (ranges.isEmpty) return spans;

  Color? colorAt(int i) {
    for (final r in ranges) {
      if (i >= r.$1 && i < r.$2) return r.$3;
    }
    return null;
  }

  final out = <TextSpan>[];
  var pos = 0;
  for (final span in spans) {
    final text = span.text ?? '';
    // 在范围边界处把片段切开,每一段的颜色是统一的
    final cuts = <int>{
      for (final r in ranges) ...[r.$1 - pos, r.$2 - pos],
    }.where((c) => c > 0 && c < text.length).toList()
      ..sort();
    var from = 0;
    for (final cut in [...cuts, text.length]) {
      if (cut == from && text.isNotEmpty) continue;
      final piece = text.substring(from, cut);
      final color = colorAt(pos + from);
      out.add(color != null
          ? TextSpan(text: piece, style: (span.style ?? const TextStyle()).copyWith(color: color))
          : TextSpan(text: piece, style: span.style));
      from = cut;
    }
    pos += text.length;
  }
  return out;
}

/// Floating Hover Tooltip Card in IntelliJ Darcula styling.
class LspHoverTooltip extends StatelessWidget {
  final String signature;
  final String? docComment;
  final VoidCallback? onGotoDefinition;
  final VoidCallback? onFindReferences;

  const LspHoverTooltip({
    super.key,
    required this.signature,
    this.docComment,
    this.onGotoDefinition,
    this.onFindReferences,
  });

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 420),
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D30),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: const Color(0xFF43454A), width: 1),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 8, offset: Offset(0, 4)),
        ],
      ),
      padding: const EdgeInsets.all(10),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header: Code Signature
          Container(
            width: double.infinity,
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
            decoration: BoxDecoration(
              color: const Color(0xFF1E1F22),
              borderRadius: BorderRadius.circular(3),
            ),
            child: Text(
              signature,
              style: const TextStyle(
                color: Color(0xFFFFC66D),
                fontSize: 11,
                fontFamily: 'monospace',
                fontWeight: FontWeight.w600,
              ),
            ),
          ),

          if (docComment != null && docComment!.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text(
              docComment!,
              style: const TextStyle(
                color: IntelliJTheme.textPrimary,
                fontSize: 11,
                height: 1.4,
              ),
            ),
          ],

          const SizedBox(height: 10),
          const Divider(color: Color(0xFF3C3F41), height: 1),
          const SizedBox(height: 6),

          // Actions: F12 Definition, Alt+F7 References
          Row(
            children: [
              if (onGotoDefinition != null)
                InkWell(
                  onTap: onGotoDefinition,
                  child: Text(
                    tr('转到定义 (F12)', 'Go to Definition (F12)'),
                    style: const TextStyle(color: IntelliJTheme.accentBlue, fontSize: 10),
                  ),
                ),
              const Spacer(),
              if (onFindReferences != null)
                InkWell(
                  onTap: onFindReferences,
                  child: Text(
                    tr('查找用法 (Alt+F7)', 'Find Usages (Alt+F7)'),
                    style: const TextStyle(color: Color(0xFF9876AA), fontSize: 10),
                  ),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

/// Completion Dropdown Popover in IntelliJ Darcula styling.
class LspCompletionPopover extends StatelessWidget {
  final List<dynamic> items;
  final int selectedIndex;
  final ValueChanged<int> onSelect;
  final ValueChanged<dynamic> onAccept;

  const LspCompletionPopover({
    super.key,
    required this.items,
    required this.selectedIndex,
    required this.onSelect,
    required this.onAccept,
  });

  @override
  Widget build(BuildContext context) {
    if (items.isEmpty) return const SizedBox.shrink();

    return Container(
      width: 320,
      height: 200,
      decoration: BoxDecoration(
        color: const Color(0xFF2B2D30),
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: const Color(0xFF43454A)),
        boxShadow: const [
          BoxShadow(color: Colors.black54, blurRadius: 10, offset: Offset(0, 4)),
        ],
      ),
      child: ListView.builder(
        itemCount: items.length,
        itemBuilder: (context, index) {
          final item = items[index];
          final label = item['label'] as String? ?? '';
          final kind = (item['kind'] as num?)?.toInt() ?? 1;
          final detail = item['detail'] as String? ?? '';
          final isSelected = index == selectedIndex;

          final (badge, badgeColor) = _badgeForKind(kind);

          return InkWell(
            onTap: () {
              onSelect(index);
              onAccept(item);
            },
            child: Container(
              color: isSelected ? const Color(0xFF214283) : Colors.transparent,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              child: Row(
                children: [
                  // Kind Badge
                  Container(
                    width: 16,
                    height: 16,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: badgeColor.withOpacity(0.2),
                      borderRadius: BorderRadius.circular(2),
                    ),
                    child: Text(
                      badge,
                      style: TextStyle(
                        color: badgeColor,
                        fontSize: 9,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                  const SizedBox(width: 8),

                  // Label
                  Expanded(
                    child: Text(
                      label,
                      style: TextStyle(
                        color: isSelected ? Colors.white : IntelliJTheme.textPrimary,
                        fontSize: 11,
                        fontFamily: 'monospace',
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),

                  // Detail / Type
                  if (detail.isNotEmpty)
                    Text(
                      detail,
                      style: TextStyle(
                        color: isSelected ? Colors.white70 : IntelliJTheme.textMuted,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                ],
              ),
            ),
          );
        },
      ),
    );
  }

  (String, Color) _badgeForKind(int kind) {
    switch (kind) {
      case 2:
      case 3:
        return ('m', const Color(0xFFFFC66D)); // Method / Function
      case 4:
      case 5:
        return ('f', const Color(0xFF9876AA)); // Field
      case 7:
      case 22:
        return ('c', const Color(0xFF6897BB)); // Class / Struct
      case 13:
        return ('e', const Color(0xFF499C54)); // Enum
      case 14:
        return ('k', const Color(0xFFCC7832)); // Keyword
      default:
        return ('v', const Color(0xFFA9B7C6)); // Variable
    }
  }
}

/// Rename Refactoring Dialog.
class LspRenameDialog extends StatefulWidget {
  final String currentName;
  final ValueChanged<String> onRename;

  const LspRenameDialog({
    super.key,
    required this.currentName,
    required this.onRename,
  });

  @override
  State<LspRenameDialog> createState() => _LspRenameDialogState();
}

class _LspRenameDialogState extends State<LspRenameDialog> {
  late TextEditingController _controller;

  @override
  void initState() {
    super.initState();
    _controller = TextEditingController(text: widget.currentName);
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Dialog(
      backgroundColor: const Color(0xFF2B2D30),
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(6),
        side: const BorderSide(color: Color(0xFF43454A)),
      ),
      child: Container(
        width: 360,
        padding: const EdgeInsets.all(16),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              tr('重命名重构 (LSP 工作区编辑)', 'Rename Refactoring (LSP Workspace Edit)'),
              style: const TextStyle(
                color: IntelliJTheme.textHigh,
                fontSize: 13,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: _controller,
              autofocus: true,
              style: const TextStyle(
                color: Colors.white,
                fontSize: 12,
                fontFamily: 'monospace',
              ),
              decoration: InputDecoration(
                labelText: tr('新名称', 'New Name'),
                labelStyle: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
                enabledBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF43454A)),
                ),
                focusedBorder: const UnderlineInputBorder(
                  borderSide: BorderSide(color: IntelliJTheme.accentBlue),
                ),
              ),
            ),
            const SizedBox(height: 20),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(context).pop(),
                  child: Text(tr('取消', 'Cancel'), style: const TextStyle(color: IntelliJTheme.textMuted)),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: IntelliJTheme.accentBlue,
                    foregroundColor: Colors.white,
                  ),
                  onPressed: () {
                    final newName = _controller.text.trim();
                    if (newName.isNotEmpty) {
                      widget.onRename(newName);
                      Navigator.of(context).pop();
                    }
                  },
                  child: Text(tr('重构', 'Refactor')),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
