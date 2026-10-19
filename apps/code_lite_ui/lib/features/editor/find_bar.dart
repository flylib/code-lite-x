import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/intellij_theme.dart';

/// 当前文件里的一处匹配(只在一行之内,列是 UTF-16)。
class FindMatch {
  const FindMatch(this.line, this.start, this.end);
  final int line;
  final int start;
  final int end;

  @override
  bool operator ==(Object other) => other is FindMatch && other.line == line && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(line, start, end);

  @override
  String toString() => 'FindMatch($line:$start-$end)';
}

bool _isWordChar(int c) =>
    (c >= 48 && c <= 57) || (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95 || c > 127;

/// 在 [lines] 里找 [query]。[words] 只要整词(前后不是字母数字下划线);[regex] 按正则(写错时抛 [FormatException])。
/// 匹配不跨行;空匹配(比如正则 `a*`)跳过。
List<FindMatch> findMatches(List<String> lines, String query, {bool matchCase = false, bool words = false, bool regex = false}) {
  if (query.isEmpty) return const [];
  final pattern = RegExp(regex ? query : RegExp.escape(query), caseSensitive: matchCase);
  final out = <FindMatch>[];
  for (var i = 0; i < lines.length; i++) {
    final line = lines[i];
    if (line.isEmpty) continue;
    for (final m in pattern.allMatches(line)) {
      if (m.end == m.start) continue;
      if (words) {
        if (m.start > 0 && _isWordChar(line.codeUnitAt(m.start - 1))) continue;
        if (m.end < line.length && _isWordChar(line.codeUnitAt(m.end))) continue;
      }
      out.add(FindMatch(i, m.start, m.end));
    }
  }
  return out;
}

/// 一个编辑器窗格的查找状态(IntelliJ 的 Find,⌘F)。查找条关了也留着查询,⌘G 还能接着找。
class FindState extends ChangeNotifier {
  bool open = false;
  String query = '';
  bool matchCase = false;
  bool words = false;
  bool regex = false;

  /// 正则写错了。
  bool invalid = false;
  List<FindMatch> matches = const [];

  /// 当前匹配在 [matches] 里的下标;没有为 -1。
  int current = -1;

  /// 按行索引的匹配(画高亮用)。
  Map<int, List<FindMatch>> byLine = const {};

  int _version = -1;
  List<String>? _lines;

  final TextEditingController text = TextEditingController();
  final FocusNode focus = FocusNode(debugLabel: 'find-field');

  /// 文本或查询变了就重新找;[version] 是编辑器文本的版本号,没变就不重算。
  void refresh(List<String> lines, int version, {bool force = false}) {
    if (!force && version == _version && identical(lines, _lines)) return;
    _version = version;
    _lines = lines;
    try {
      matches = findMatches(lines, query, matchCase: matchCase, words: words, regex: regex);
      invalid = false;
    } on FormatException {
      matches = const [];
      invalid = true;
    }
    final map = <int, List<FindMatch>>{};
    for (final m in matches) {
      (map[m.line] ??= []).add(m);
    }
    byLine = map;
    if (current >= matches.length) current = matches.isEmpty ? -1 : 0;
  }

  /// 光标处或之后的第一个匹配(到底绕回开头)。
  int indexAtOrAfter(int line, int col) {
    for (var i = 0; i < matches.length; i++) {
      final m = matches[i];
      if (m.line > line || (m.line == line && m.start >= col)) return i;
    }
    return matches.isEmpty ? -1 : 0;
  }

  void changed() => notifyListeners();

  @override
  void dispose() {
    text.dispose();
    focus.dispose();
    super.dispose();
  }
}

/// 编辑区顶上的查找条(照 IntelliJ):输入框、清空、Cc / W / .*、`当前/总数`、↑ ↓、关闭。
/// 回车下一个、⇧回车上一个、Esc 关;[onKey] 让 ⌘G 之类的快捷键在输入框里也能用。
class FindBar extends StatelessWidget {
  const FindBar({
    super.key,
    required this.state,
    required this.onQueryChanged,
    required this.onNext,
    required this.onPrevious,
    required this.onClose,
    this.onKey,
  });

  final FindState state;
  final VoidCallback onQueryChanged;
  final VoidCallback onNext;
  final VoidCallback onPrevious;
  final VoidCallback onClose;
  final KeyEventResult Function(KeyEvent event)? onKey;

  static const _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: state,
      builder: (context, _) {
        final none = state.query.isNotEmpty && state.matches.isEmpty;
        final count = state.query.isEmpty
            ? ''
            : state.invalid
                ? '正则有误'
                : state.matches.isEmpty
                    ? '0 results'
                    : '${state.current + 1}/${state.matches.length}';
        return Container(
          key: const ValueKey('find-bar'),
          height: 38,
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: const BoxDecoration(
            color: IntelliJTheme.islandBg,
            border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
          ),
          child: Row(
            children: [
              Flexible(
                child: Container(
                  constraints: const BoxConstraints(maxWidth: 420),
                  padding: const EdgeInsets.only(left: 8, right: 4),
                  decoration: BoxDecoration(
                    color: IntelliJTheme.editorBg,
                    borderRadius: BorderRadius.circular(5),
                    border: Border.all(
                      color: state.invalid || none ? IntelliJTheme.diagError : IntelliJTheme.accentBlue,
                      width: 1.5,
                    ),
                  ),
                  child: Row(
                    children: [
                      const Icon(Icons.search, size: 15, color: IntelliJTheme.textSecondary),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Focus(
                          // 回车 / ⇧回车 / Esc / ⌘G 在输入框里先处理
                          onKeyEvent: (node, event) {
                            if (event is! KeyDownEvent && event is! KeyRepeatEvent) return KeyEventResult.ignored;
                            final shift = HardwareKeyboard.instance.isShiftPressed;
                            if (event.logicalKey == LogicalKeyboardKey.enter || event.logicalKey == LogicalKeyboardKey.numpadEnter) {
                              shift ? onPrevious() : onNext();
                              return KeyEventResult.handled;
                            }
                            if (event.logicalKey == LogicalKeyboardKey.escape) {
                              onClose();
                              return KeyEventResult.handled;
                            }
                            return onKey?.call(event) ?? KeyEventResult.ignored;
                          },
                          child: TextField(
                            key: const ValueKey('find-field'),
                            controller: state.text,
                            focusNode: state.focus,
                            autofocus: true,
                            style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13),
                            cursorColor: IntelliJTheme.caret,
                            decoration: const InputDecoration(isDense: true, border: InputBorder.none, contentPadding: EdgeInsets.symmetric(vertical: 7)),
                            onChanged: (v) {
                              state.query = v;
                              onQueryChanged();
                            },
                          ),
                        ),
                      ),
                      if (state.query.isNotEmpty)
                        _FindButton(
                          key: const ValueKey('find-clear'),
                          icon: Icons.close,
                          tooltip: '清空',
                          onTap: () {
                            state.text.clear();
                            state.query = '';
                            onQueryChanged();
                            state.focus.requestFocus();
                          },
                        ),
                      _FindToggle(label: 'Cc', tooltip: '区分大小写', value: state.matchCase, onTap: () {
                        state.matchCase = !state.matchCase;
                        onQueryChanged();
                      }),
                      _FindToggle(label: 'W', tooltip: '整词', value: state.words, onTap: () {
                        state.words = !state.words;
                        onQueryChanged();
                      }),
                      _FindToggle(label: '.*', tooltip: '正则表达式', value: state.regex, onTap: () {
                        state.regex = !state.regex;
                        onQueryChanged();
                      }),
                    ],
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Text(count, key: const ValueKey('find-count'), style: none || state.invalid ? _muted.copyWith(color: IntelliJTheme.diagError) : _muted),
              const SizedBox(width: 8),
              _FindButton(key: const ValueKey('find-prev'), icon: Icons.arrow_upward, tooltip: '上一个 (⇧回车)', onTap: state.matches.isEmpty ? null : onPrevious),
              _FindButton(key: const ValueKey('find-next'), icon: Icons.arrow_downward, tooltip: '下一个 (回车)', onTap: state.matches.isEmpty ? null : onNext),
              const Spacer(),
              _FindButton(key: const ValueKey('find-close'), icon: Icons.close, tooltip: '关闭 (Esc)', onTap: onClose),
            ],
          ),
        );
      },
    );
  }
}

class _FindButton extends StatelessWidget {
  const _FindButton({super.key, required this.icon, required this.tooltip, this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: 16, color: onTap == null ? IntelliJTheme.textMuted.withValues(alpha: 0.5) : IntelliJTheme.textSecondary),
          ),
        ),
      );
}

class _FindToggle extends StatelessWidget {
  const _FindToggle({required this.label, required this.tooltip, required this.value, required this.onTap});

  final String label;
  final String tooltip;
  final bool value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          key: ValueKey('find-toggle-$label'),
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
            decoration: value ? BoxDecoration(color: IntelliJTheme.accentBlue.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(4)) : null,
            child: Text(
              label,
              style: TextStyle(color: value ? IntelliJTheme.textHigh : IntelliJTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w600),
            ),
          ),
        ),
      );
}
