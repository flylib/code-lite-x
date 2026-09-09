import 'package:flutter/material.dart';

/// IntelliJ IDEA (Darcula Modern) syntax highlighter for Rust & Dart.
class SyntaxHighlighter {
  // Darcula Color Palette
  static const Color keywordColor = Color(0xFFCC7832);
  static const Color stringColor = Color(0xFF6A8759);
  static const Color numberColor = Color(0xFF6897BB);
  static const Color commentColor = Color(0xFF808080);
  static const Color functionColor = Color(0xFFFFC66D);
  static const Color typeColor = Color(0xFF9876AA);
  static const Color attributeColor = Color(0xFFBBB529);
  static const Color defaultColor = Color(0xFFA9B7C6);

  static final Set<String> _keywords = {
    // Rust
    'as', 'async', 'await', 'break', 'const', 'continue', 'crate', 'dyn',
    'else', 'enum', 'extern', 'false', 'fn', 'for', 'if', 'impl', 'in',
    'let', 'loop', 'match', 'mod', 'move', 'mut', 'pub', 'ref', 'return',
    'self', 'Self', 'static', 'struct', 'super', 'trait', 'true', 'type',
    'unsafe', 'use', 'where', 'while',
    // Dart
    'abstract', 'class', 'extends', 'implements', 'with', 'mixin',
    'void', 'final', 'var', 'late', 'required', 'is', 'switch', 'case',
    'default', 'try', 'catch', 'finally', 'throw', 'rethrow', 'yield',
    'get', 'set', 'import', 'export', 'part', 'of', 'show', 'hide',
  };

  static final Set<String> _commonTypes = {
    'i8', 'i16', 'i32', 'i64', 'i128', 'isize',
    'u8', 'u16', 'u32', 'u64', 'u128', 'usize',
    'f32', 'f64', 'bool', 'char', 'str', 'String',
    'Option', 'Some', 'None', 'Result', 'Ok', 'Err',
    'Vec', 'HashMap', 'HashSet', 'Arc', 'Rc', 'Box', 'Mutex',
    'int', 'double', 'num', 'List', 'Map', 'Set', 'Future', 'Stream',
    'Widget', 'StatelessWidget', 'StatefulWidget', 'State', 'BuildContext',
  };

  /// Tokenizes a single line of source code into styled TextSpans.
  static List<TextSpan> highlightLine(String line, {String language = 'rust'}) {
    if (line.isEmpty) {
      return [const TextSpan(text: '')];
    }

    final trimmed = line.trimLeft();
    final int indentLen = line.length - trimmed.length;
    final leadingIndent = line.substring(0, indentLen);
    final spans = <TextSpan>[];

    if (leadingIndent.isNotEmpty) {
      spans.add(TextSpan(text: leadingIndent));
    }

    // Check full line comment
    if (trimmed.startsWith('//') || trimmed.startsWith('#')) {
      spans.add(TextSpan(
        text: trimmed,
        style: const TextStyle(color: commentColor, fontStyle: FontStyle.italic),
      ));
      return spans;
    }

    // Check attribute/annotation
    if (trimmed.startsWith('#[') || trimmed.startsWith('@')) {
      spans.add(TextSpan(
        text: trimmed,
        style: const TextStyle(color: attributeColor),
      ));
      return spans;
    }

    int index = 0;
    final chars = trimmed.runes.toList();
    final len = chars.length;

    while (index < len) {
      final ch = String.fromCharCode(chars[index]);

      // 1. Line comment remainder
      if (index + 1 < len && ch == '/' && String.fromCharCode(chars[index + 1]) == '/') {
        final commentText = String.fromCharCodes(chars.sublist(index));
        spans.add(TextSpan(
          text: commentText,
          style: const TextStyle(color: commentColor, fontStyle: FontStyle.italic),
        ));
        break;
      }

      // 2. String literal
      if (ch == '"' || ch == "'") {
        final quote = ch;
        int end = index + 1;
        while (end < len) {
          final c = String.fromCharCode(chars[end]);
          if (c == '\\') {
            end += 2;
            continue;
          }
          if (c == quote) {
            end++;
            break;
          }
          end++;
        }
        if (end > len) end = len;
        final strText = String.fromCharCodes(chars.sublist(index, end));
        spans.add(TextSpan(
          text: strText,
          style: const TextStyle(color: stringColor),
        ));
        index = end;
        continue;
      }

      // 3. Number literal
      if (_isDigit(ch) && (index == 0 || !_isIdentChar(String.fromCharCode(chars[index - 1])))) {
        int end = index;
        while (end < len && (_isDigit(String.fromCharCode(chars[end])) || ['x', 'b', 'o', '.', '_'].contains(String.fromCharCode(chars[end])))) {
          end++;
        }
        final numText = String.fromCharCodes(chars.sublist(index, end));
        spans.add(TextSpan(
          text: numText,
          style: const TextStyle(color: numberColor),
        ));
        index = end;
        continue;
      }

      // 4. Identifier (Keyword, Type, Function, or Variable)
      if (_isIdentStart(ch)) {
        int end = index;
        while (end < len && _isIdentChar(String.fromCharCode(chars[end]))) {
          end++;
        }
        final word = String.fromCharCodes(chars.sublist(index, end));

        // Check if followed by '(' -> function/method call
        int nextNonSpace = end;
        while (nextNonSpace < len && String.fromCharCode(chars[nextNonSpace]) == ' ') {
          nextNonSpace++;
        }
        final isFuncCall = nextNonSpace < len && String.fromCharCode(chars[nextNonSpace]) == '(';

        if (_keywords.contains(word)) {
          spans.add(TextSpan(
            text: word,
            style: const TextStyle(color: keywordColor, fontWeight: FontWeight.bold),
          ));
        } else if (_commonTypes.contains(word) || (word.isNotEmpty && word[0] == word[0].toUpperCase() && word.length > 1 && !_keywords.contains(word))) {
          spans.add(TextSpan(
            text: word,
            style: const TextStyle(color: typeColor),
          ));
        } else if (isFuncCall) {
          spans.add(TextSpan(
            text: word,
            style: const TextStyle(color: functionColor),
          ));
        } else {
          spans.add(TextSpan(
            text: word,
            style: const TextStyle(color: defaultColor),
          ));
        }

        index = end;
        continue;
      }

      // 5. Punctuation / Operator
      spans.add(TextSpan(
        text: ch,
        style: const TextStyle(color: defaultColor),
      ));
      index++;
    }

    return spans;
  }

  static bool _isDigit(String s) => s.isNotEmpty && s.codeUnitAt(0) >= 48 && s.codeUnitAt(0) <= 57;

  static bool _isIdentStart(String s) {
    if (s.isEmpty) return false;
    final c = s.codeUnitAt(0);
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || c == 95; // A-Z, a-z, _
  }

  static bool _isIdentChar(String s) {
    if (s.isEmpty) return false;
    final c = s.codeUnitAt(0);
    return (c >= 65 && c <= 90) || (c >= 97 && c <= 122) || (c >= 48 && c <= 57) || c == 95;
  }
}
