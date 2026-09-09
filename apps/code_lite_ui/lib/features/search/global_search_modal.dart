import 'package:flutter/material.dart';
import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';

class GlobalSearchModal extends StatefulWidget {
  final ApiClient client;
  final void Function(String filePath, int lineNumber) onNavigate;

  const GlobalSearchModal({
    super.key,
    required this.client,
    required this.onNavigate,
  });

  static Future<void> show(
    BuildContext context, {
    required ApiClient client,
    required void Function(String filePath, int lineNumber) onNavigate,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => GlobalSearchModal(
        client: client,
        onNavigate: onNavigate,
      ),
    );
  }

  @override
  State<GlobalSearchModal> createState() => _GlobalSearchModalState();
}

class _GlobalSearchModalState extends State<GlobalSearchModal> {
  final TextEditingController _searchController = TextEditingController();
  final TextEditingController _replaceController = TextEditingController();
  final FocusNode _searchFocusNode = FocusNode();

  bool _isReplaceMode = false;
  bool _caseSensitive = false;
  bool _wholeWord = false;
  bool _isRegex = false;
  bool _isSearching = false;
  String? _statusMessage;

  List<Map<String, dynamic>> _matches = [];
  int _replacedCount = 0;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _searchFocusNode.requestFocus();
    });
  }

  @override
  void dispose() {
    _searchController.dispose();
    _replaceController.dispose();
    _searchFocusNode.dispose();
    super.dispose();
  }

  Future<void> _performSearch() async {
    final query = _searchController.text.trim();
    if (query.isEmpty) {
      setState(() {
        _matches = [];
        _statusMessage = null;
      });
      return;
    }

    setState(() {
      _isSearching = true;
      _statusMessage = 'Searching workspace...';
    });

    final options = {
      'case_sensitive': _caseSensitive,
      'whole_word': _wholeWord,
      'is_regex': _isRegex,
      'max_results': 500,
    };

    final res = await widget.client.searchWorkspace(query, options);
    final rawMatches = (res['matches'] as List?) ?? [];
    final matches = rawMatches.map((m) => Map<String, dynamic>.from(m as Map)).toList();

    setState(() {
      _isSearching = false;
      _matches = matches;
      _statusMessage = matches.isEmpty
          ? 'No occurrences found for "$query"'
          : 'Found ${matches.length} occurrences across ${_uniqueFilesCount(matches)} files';
    });
  }

  int _uniqueFilesCount(List<Map<String, dynamic>> matches) {
    final set = <String>{};
    for (final m in matches) {
      final fp = m['file_path'] as String?;
      if (fp != null) set.add(fp);
    }
    return set.length;
  }

  Future<void> _performReplaceAll() async {
    final query = _searchController.text.trim();
    final replacement = _replaceController.text;
    if (query.isEmpty) return;

    final options = {
      'case_sensitive': _caseSensitive,
      'whole_word': _wholeWord,
      'is_regex': _isRegex,
    };

    final res = await widget.client.replaceWorkspace(query, replacement, options);
    final count = (res['replaced_count'] as int?) ?? 0;

    setState(() {
      _replacedCount = count;
      _statusMessage = 'Successfully replaced $count occurrences across workspace';
    });

    _performSearch();
  }

  @override
  Widget build(BuildContext context) {
    final groupedMatches = <String, List<Map<String, dynamic>>>{};
    for (final m in _matches) {
      final fp = (m['file_path'] as String?) ?? 'Unknown file';
      groupedMatches.putIfAbsent(fp, () => []).add(m);
    }

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 40, vertical: 24),
      child: Container(
        width: 720,
        height: 540,
        decoration: BoxDecoration(
          color: IntelliJTheme.panelBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: IntelliJTheme.borderSubtle, width: 1.5),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.6),
              blurRadius: 24,
              offset: const Offset(0, 10),
            ),
          ],
        ),
        child: Column(
          children: [
            // 1. Header Bar
            _buildHeaderBar(),

            // 2. Search & Replace Inputs
            _buildInputSection(),

            // 3. Status Bar
            if (_statusMessage != null) _buildStatusBar(),

            const Divider(height: 1, color: IntelliJTheme.borderSubtle),

            // 4. Results List
            Expanded(
              child: _isSearching
                  ? const Center(
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        color: IntelliJTheme.accentBlue,
                      ),
                    )
                  : groupedMatches.isEmpty
                      ? _buildEmptyState()
                      : _buildResultsList(groupedMatches),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHeaderBar() {
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 14),
      decoration: const BoxDecoration(
        color: IntelliJTheme.subHeaderBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(7)),
        border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Row(
        children: [
          const Icon(Icons.search, size: 16, color: IntelliJTheme.accentBlue),
          const SizedBox(width: 8),
          Text(
            _isReplaceMode ? 'Replace in Files' : 'Find in Files',
            style: const TextStyle(
              color: IntelliJTheme.textHigh,
              fontSize: 13,
              fontWeight: FontWeight.bold,
            ),
          ),
          const SizedBox(width: 8),
          const Text(
            '(Cmd+Shift+F)',
            style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
          ),
          const Spacer(),
          // Toggle Replace Mode Button
          InkWell(
            onTap: () => setState(() => _isReplaceMode = !_isReplaceMode),
            borderRadius: BorderRadius.circular(4),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
              decoration: BoxDecoration(
                color: _isReplaceMode ? IntelliJTheme.accentBlue.withOpacity(0.2) : Colors.transparent,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(
                  color: _isReplaceMode ? IntelliJTheme.accentBlue : IntelliJTheme.borderSubtle,
                ),
              ),
              child: Row(
                children: [
                  Icon(
                    _isReplaceMode ? Icons.expand_less : Icons.find_replace,
                    size: 13,
                    color: _isReplaceMode ? IntelliJTheme.accentBlue : IntelliJTheme.textSecondary,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    _isReplaceMode ? 'Hide Replace' : 'Replace Mode',
                    style: TextStyle(
                      color: _isReplaceMode ? IntelliJTheme.accentBlue : IntelliJTheme.textSecondary,
                      fontSize: 11,
                    ),
                  ),
                ],
              ),
            ),
          ),
          const SizedBox(width: 10),
          IconButton(
            icon: const Icon(Icons.close, size: 16, color: IntelliJTheme.textMuted),
            padding: EdgeInsets.zero,
            constraints: const BoxConstraints(),
            onPressed: () => Navigator.of(context).pop(),
          ),
        ],
      ),
    );
  }

  Widget _buildInputSection() {
    return Container(
      color: IntelliJTheme.cardBg,
      padding: const EdgeInsets.all(12),
      child: Column(
        children: [
          // Search Input Row
          Row(
            children: [
              Expanded(
                child: Container(
                  height: 32,
                  decoration: BoxDecoration(
                    color: IntelliJTheme.editorBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: IntelliJTheme.borderSubtle),
                  ),
                  child: Row(
                    children: [
                      const Padding(
                        padding: EdgeInsets.symmetric(horizontal: 8),
                        child: Icon(Icons.search, size: 14, color: IntelliJTheme.textMuted),
                      ),
                      Expanded(
                        child: TextField(
                          controller: _searchController,
                          focusNode: _searchFocusNode,
                          style: const TextStyle(
                            color: IntelliJTheme.textPrimary,
                            fontSize: 12,
                            fontFamily: 'monospace',
                          ),
                          decoration: const InputDecoration(
                            hintText: 'Search in workspace files...',
                            hintStyle: TextStyle(color: IntelliJTheme.textMuted, fontSize: 12),
                            border: InputBorder.none,
                            isDense: true,
                            contentPadding: EdgeInsets.symmetric(vertical: 8),
                          ),
                          onSubmitted: (_) => _performSearch(),
                        ),
                      ),
                      if (_searchController.text.isNotEmpty)
                        IconButton(
                          icon: const Icon(Icons.clear, size: 14, color: IntelliJTheme.textMuted),
                          padding: const EdgeInsets.symmetric(horizontal: 4),
                          constraints: const BoxConstraints(),
                          onPressed: () {
                            _searchController.clear();
                            _performSearch();
                          },
                        ),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 8),
              // Filter Toggle Buttons (Cc, W, .*)
              _buildOptionToggle('Cc', 'Match Case', _caseSensitive, () {
                setState(() => _caseSensitive = !_caseSensitive);
                _performSearch();
              }),
              const SizedBox(width: 4),
              _buildOptionToggle('W', 'Whole Words', _wholeWord, () {
                setState(() => _wholeWord = !_wholeWord);
                _performSearch();
              }),
              const SizedBox(width: 4),
              _buildOptionToggle('.*', 'Regular Expression', _isRegex, () {
                setState(() => _isRegex = !_isRegex);
                _performSearch();
              }),
              const SizedBox(width: 8),
              ElevatedButton(
                onPressed: _performSearch,
                style: ElevatedButton.styleFrom(
                  backgroundColor: IntelliJTheme.accentBlue,
                  foregroundColor: Colors.white,
                  minimumSize: const Size(64, 32),
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                ),
                child: const Text('Find', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
              ),
            ],
          ),

          // Replace Row (Conditional)
          if (_isReplaceMode) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Expanded(
                  child: Container(
                    height: 32,
                    decoration: BoxDecoration(
                      color: IntelliJTheme.editorBg,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: IntelliJTheme.borderSubtle),
                    ),
                    child: Row(
                      children: [
                        const Padding(
                          padding: EdgeInsets.symmetric(horizontal: 8),
                          child: Icon(Icons.find_replace, size: 14, color: IntelliJTheme.textMuted),
                        ),
                        Expanded(
                          child: TextField(
                            controller: _replaceController,
                            style: const TextStyle(
                              color: IntelliJTheme.textPrimary,
                              fontSize: 12,
                              fontFamily: 'monospace',
                            ),
                            decoration: const InputDecoration(
                              hintText: 'Replace with...',
                              hintStyle: TextStyle(color: IntelliJTheme.textMuted, fontSize: 12),
                              border: InputBorder.none,
                              isDense: true,
                              contentPadding: EdgeInsets.symmetric(vertical: 8),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _matches.isEmpty ? null : _performReplaceAll,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: IntelliJTheme.gitYellow,
                    foregroundColor: Colors.black,
                    minimumSize: const Size(100, 32),
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(4)),
                  ),
                  child: const Text('Replace All', style: TextStyle(fontSize: 12, fontWeight: FontWeight.bold)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildOptionToggle(String label, String tooltip, bool active, VoidCallback onTap) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          width: 28,
          height: 30,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: active ? IntelliJTheme.accentBlue.withOpacity(0.3) : Colors.transparent,
            borderRadius: BorderRadius.circular(4),
            border: Border.all(
              color: active ? IntelliJTheme.accentBlue : IntelliJTheme.borderSubtle,
            ),
          ),
          child: Text(
            label,
            style: TextStyle(
              color: active ? IntelliJTheme.accentBlue : IntelliJTheme.textSecondary,
              fontSize: 11,
              fontWeight: FontWeight.bold,
              fontFamily: 'monospace',
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildStatusBar() {
    return Container(
      width: double.infinity,
      color: IntelliJTheme.subHeaderBg,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
      child: Text(
        _statusMessage!,
        style: const TextStyle(color: IntelliJTheme.textSecondary, fontSize: 11),
      ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(Icons.manage_search, size: 48, color: IntelliJTheme.textMuted.withOpacity(0.5)),
          const SizedBox(height: 12),
          const Text(
            'Type a search term and press Find to scan the workspace',
            style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 12),
          ),
        ],
      ),
    );
  }

  Widget _buildResultsList(Map<String, List<Map<String, dynamic>>> groupedMatches) {
    final query = _searchController.text.trim();

    return ListView.builder(
      itemCount: groupedMatches.length,
      padding: const EdgeInsets.symmetric(vertical: 4),
      itemBuilder: (context, index) {
        final filePath = groupedMatches.keys.elementAt(index);
        final fileMatches = groupedMatches[filePath]!;

        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // File Header
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              color: IntelliJTheme.subHeaderBg.withOpacity(0.5),
              child: Row(
                children: [
                  const Icon(Icons.insert_drive_file_outlined, size: 14, color: IntelliJTheme.syntaxType),
                  const SizedBox(width: 6),
                  Text(
                    filePath,
                    style: const TextStyle(
                      color: IntelliJTheme.textHigh,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                    ),
                  ),
                  const SizedBox(width: 8),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                    decoration: BoxDecoration(
                      color: IntelliJTheme.borderSubtle,
                      borderRadius: BorderRadius.circular(10),
                    ),
                    child: Text(
                      '${fileMatches.length}',
                      style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10),
                    ),
                  ),
                ],
              ),
            ),

            // Matches
            ...fileMatches.map((m) {
              final lineNum = (m['line_number'] as int?) ?? 1;
              final snippet = (m['line_snippet'] as String?) ?? '';

              return InkWell(
                onTap: () {
                  Navigator.of(context).pop();
                  widget.onNavigate(filePath, lineNum);
                },
                hoverColor: IntelliJTheme.selectionBg.withOpacity(0.4),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 4),
                  decoration: const BoxDecoration(
                    border: Border(bottom: BorderSide(color: Color(0x11FFFFFF))),
                  ),
                  child: Row(
                    children: [
                      SizedBox(
                        width: 44,
                        child: Text(
                          '$lineNum:',
                          style: const TextStyle(
                            color: IntelliJTheme.textMuted,
                            fontSize: 11,
                            fontFamily: 'monospace',
                          ),
                        ),
                      ),
                      Expanded(
                        child: _buildHighlightedSnippet(snippet, query),
                      ),
                    ],
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }

  Widget _buildHighlightedSnippet(String snippet, String query) {
    if (query.isEmpty) {
      return Text(
        snippet,
        style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 11, fontFamily: 'monospace'),
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
      );
    }

    final lowerSnippet = snippet.toLowerCase();
    final lowerQuery = query.toLowerCase();
    final spans = <TextSpan>[];
    int start = 0;

    while (true) {
      final idx = lowerSnippet.indexOf(lowerQuery, start);
      if (idx == -1) {
        spans.add(TextSpan(text: snippet.substring(start)));
        break;
      }
      if (idx > start) {
        spans.add(TextSpan(text: snippet.substring(start, idx)));
      }
      spans.add(
        TextSpan(
          text: snippet.substring(idx, idx + query.length),
          style: const TextStyle(
            color: Colors.black,
            backgroundColor: Color(0xFFFED854), // IntelliJ search highlight yellow
            fontWeight: FontWeight.bold,
          ),
        ),
      );
      start = idx + query.length;
    }

    return RichText(
      text: TextSpan(
        style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 11, fontFamily: 'monospace'),
        children: spans,
      ),
      maxLines: 1,
      overflow: TextOverflow.ellipsis,
    );
  }
}
