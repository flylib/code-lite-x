import 'package:flutter/material.dart';
import '../../core/theme/intellij_theme.dart';

class StructureWidget extends StatelessWidget {
  final String activeFile;
  final List<dynamic> outline;
  final ValueChanged<Map<String, dynamic>> onSelectSymbol;

  const StructureWidget({
    super.key,
    required this.activeFile,
    required this.outline,
    required this.onSelectSymbol,
  });

  @override
  Widget build(BuildContext context) {
    final fileName = activeFile.split('/').last;

    return Container(
      color: IntelliJTheme.sidebarBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Header
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 12),
            decoration: const BoxDecoration(
              color: IntelliJTheme.subHeaderBg,
              border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Row(
                  children: [
                    const Text('STRUCTURE', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10, fontWeight: FontWeight.bold)),
                    const SizedBox(width: 6),
                    Text(fileName, style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 11)),
                  ],
                ),
                Text('${outline.length} symbols', style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
              ],
            ),
          ),

          // Symbol Tree List
          Expanded(
            child: outline.isEmpty
                ? const Center(
                    child: Text(
                      'No symbols found in outline',
                      style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: outline.length,
                    itemBuilder: (context, index) {
                      final item = outline[index] as Map<String, dynamic>;
                      return _buildSymbolItem(item);
                    },
                  ),
          ),
        ],
      ),
    );
  }

  Widget _buildSymbolItem(Map<String, dynamic> item, [int depth = 0]) {
    final name = item['name'] as String? ?? 'anonymous';
    final kind = item['kind'] as String? ?? 'symbol';
    final lineStart = item['line_start'] as int? ?? 1;
    final children = (item['children'] as List<dynamic>?) ?? [];

    final iconData = _getSymbolIcon(kind);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        InkWell(
          onTap: () => onSelectSymbol(item),
          child: Padding(
            padding: EdgeInsets.only(left: 12.0 + depth * 14.0, right: 8.0, top: 4.0, bottom: 4.0),
            child: Row(
              children: [
                // Kind badge icon
                Container(
                  width: 14,
                  height: 14,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: iconData.color.withOpacity(0.2),
                    borderRadius: BorderRadius.circular(2),
                    border: Border.all(color: iconData.color, width: 0.8),
                  ),
                  child: Text(
                    iconData.letter,
                    style: TextStyle(
                      color: iconData.color,
                      fontSize: 8,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                ),
                const SizedBox(width: 8),

                // Symbol name
                Expanded(
                  child: Text(
                    name,
                    style: const TextStyle(
                      color: IntelliJTheme.textPrimary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),

                // Line number tag
                Text(
                  ':$lineStart',
                  style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10),
                ),
              ],
            ),
          ),
        ),

        // Nested children (fields / methods)
        if (children.isNotEmpty)
          ...children.map((child) => _buildSymbolItem(child as Map<String, dynamic>, depth + 1)),
      ],
    );
  }

  _SymbolBadge _getSymbolIcon(String kind) {
    switch (kind.toLowerCase()) {
      case 'struct':
      case 'class':
        return _SymbolBadge('S', const Color(0xFF6897BB));
      case 'enum':
        return _SymbolBadge('E', const Color(0xFFCC7832));
      case 'function':
        return _SymbolBadge('F', const Color(0xFFFFC66D));
      case 'method':
        return _SymbolBadge('M', const Color(0xFFFFC66D));
      case 'trait':
      case 'interface':
        return _SymbolBadge('T', const Color(0xFF6A8759));
      case 'impl':
        return _SymbolBadge('I', const Color(0xFF9876AA));
      case 'field':
        return _SymbolBadge('f', const Color(0xFFA9B7C6));
      case 'variant':
        return _SymbolBadge('v', const Color(0xFFCC7832));
      default:
        return _SymbolBadge('•', IntelliJTheme.textMuted);
    }
  }
}

class _SymbolBadge {
  final String letter;
  final Color color;

  _SymbolBadge(this.letter, this.color);
}
