import 'package:flutter/material.dart';
import '../../core/theme/intellij_theme.dart';

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
      message: json['message'] as String? ?? 'Diagnostic error',
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

/// 把 [diagnostics] 里「没用到」的范围在 [spans](一行的着色片段)里改成灰色。
/// 只改前景色,保留粗体 / 斜体等其它样式,也不改变文字,所以不影响宽度测量。
/// [lineText] 是这一行的文字;范围跨到后面的行时,灰到行尾。没有要变灰的就原样返回 [spans]。
List<TextSpan> fadeUnused(List<TextSpan> spans, String lineText, Iterable<EditorDiagnostic> diagnostics, int lineIndex) {
  final ranges = <(int, int)>[];
  for (final d in diagnostics) {
    if (!d.isUnnecessary || d.line != lineIndex) continue;
    final end = d.endLine > d.line ? lineText.length : d.colEnd.clamp(0, lineText.length);
    final start = d.colStart.clamp(0, lineText.length);
    if (end > start) ranges.add((start, end));
  }
  if (ranges.isEmpty) return spans;

  bool faded(int i) => ranges.any((r) => i >= r.$1 && i < r.$2);
  final out = <TextSpan>[];
  var pos = 0;
  for (final span in spans) {
    final text = span.text ?? '';
    // 在范围边界处把片段切开,每一段要么全灰要么全不灰
    final cuts = <int>{
      for (final r in ranges) ...[r.$1 - pos, r.$2 - pos],
    }.where((c) => c > 0 && c < text.length).toList()
      ..sort();
    var from = 0;
    for (final cut in [...cuts, text.length]) {
      if (cut == from && text.isNotEmpty) continue;
      final piece = text.substring(from, cut);
      out.add(faded(pos + from)
          ? TextSpan(text: piece, style: (span.style ?? const TextStyle()).copyWith(color: unusedTextColor))
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
                  child: const Text(
                    'Go to Definition (F12)',
                    style: TextStyle(color: IntelliJTheme.accentBlue, fontSize: 10),
                  ),
                ),
              const Spacer(),
              if (onFindReferences != null)
                InkWell(
                  onTap: onFindReferences,
                  child: const Text(
                    'Find Usages (Alt+F7)',
                    style: TextStyle(color: Color(0xFF9876AA), fontSize: 10),
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
            const Text(
              'Rename Refactoring (LSP Workspace Edit)',
              style: TextStyle(
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
              decoration: const InputDecoration(
                labelText: 'New Name',
                labelStyle: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
                enabledBorder: UnderlineInputBorder(
                  borderSide: BorderSide(color: Color(0xFF43454A)),
                ),
                focusedBorder: UnderlineInputBorder(
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
                  child: const Text('Cancel', style: TextStyle(color: IntelliJTheme.textMuted)),
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
                  child: const Text('Refactor'),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
