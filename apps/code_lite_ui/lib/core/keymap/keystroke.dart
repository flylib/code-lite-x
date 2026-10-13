import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';

/// 一个按键组合,文字格式和 IntelliJ 的快捷键配置一样(`meta shift F12`、`alt 1`),
/// 这样从 IntelliJ 导入、存进设置文件都不用转换。
@immutable
class KeyStroke {
  const KeyStroke(this.key, {this.meta = false, this.ctrl = false, this.alt = false, this.shift = false});

  /// IntelliJ 的键名:`A`..`Z`、`0`..`9`、`F1`..`F20`、`ESCAPE`、`LEFT`、`BACK_QUOTE`……
  final String key;
  final bool meta;
  final bool ctrl;
  final bool alt;
  final bool shift;

  /// 解析 `meta shift F12` 这样的文字;认不出来返回 null。
  static KeyStroke? parse(String text) {
    final parts = text.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return null;
    var meta = false, ctrl = false, alt = false, shift = false;
    for (final m in parts.take(parts.length - 1)) {
      switch (m.toLowerCase()) {
        case 'meta':
          meta = true;
        case 'ctrl' || 'control':
          ctrl = true;
        case 'alt':
          alt = true;
        case 'shift':
          shift = true;
        default:
          return null; // altGraph 之类不支持
      }
    }
    final key = parts.last.toUpperCase();
    if (!_keys.containsKey(key)) return null;
    return KeyStroke(key, meta: meta, ctrl: ctrl, alt: alt, shift: shift);
  }

  /// 存进设置文件的文字(修饰键按固定顺序)。
  String get text => [if (ctrl) 'ctrl', if (alt) 'alt', if (shift) 'shift', if (meta) 'meta', key].join(' ');

  ShortcutActivator get activator => SingleActivator(_keys[key]!, meta: meta, control: ctrl, alt: alt, shift: shift);

  /// 显示用:macOS `⇧⌘F12`,其它平台 `Ctrl+Shift+F12`。
  String label({bool? mac}) {
    final isMac = mac ?? isMacPlatform;
    final name = (isMac ? _macNames[key] : _names[key]) ?? key;
    if (isMac) return '${ctrl ? '⌃' : ''}${alt ? '⌥' : ''}${shift ? '⇧' : ''}${meta ? '⌘' : ''}$name';
    return [if (ctrl) 'Ctrl', if (alt) 'Alt', if (shift) 'Shift', if (meta) 'Meta', name].join('+');
  }

  /// 按下的键(录快捷键用):单按修饰键、认不出来的键返回 null。
  static KeyStroke? fromEvent(KeyEvent event, HardwareKeyboard keyboard) {
    final key = _byLogical[event.logicalKey];
    if (key == null) return null;
    return KeyStroke(
      key,
      meta: keyboard.isMetaPressed,
      ctrl: keyboard.isControlPressed,
      alt: keyboard.isAltPressed,
      shift: keyboard.isShiftPressed,
    );
  }

  @override
  bool operator ==(Object other) =>
      other is KeyStroke && other.key == key && other.meta == meta && other.ctrl == ctrl && other.alt == alt && other.shift == shift;

  @override
  int get hashCode => Object.hash(key, meta, ctrl, alt, shift);

  @override
  String toString() => text;
}

/// 快捷键按 macOS 的习惯来(默认键位、⌘ 符号)。
bool get isMacPlatform => defaultTargetPlatform == TargetPlatform.macOS || defaultTargetPlatform == TargetPlatform.iOS;

final Map<String, LogicalKeyboardKey> _keys = {
  for (var i = 0; i < 26; i++) String.fromCharCode(0x41 + i): LogicalKeyboardKey(LogicalKeyboardKey.keyA.keyId + i),
  for (var i = 0; i < 10; i++) '$i': LogicalKeyboardKey(LogicalKeyboardKey.digit0.keyId + i),
  'F1': LogicalKeyboardKey.f1, 'F2': LogicalKeyboardKey.f2, 'F3': LogicalKeyboardKey.f3, 'F4': LogicalKeyboardKey.f4,
  'F5': LogicalKeyboardKey.f5, 'F6': LogicalKeyboardKey.f6, 'F7': LogicalKeyboardKey.f7, 'F8': LogicalKeyboardKey.f8,
  'F9': LogicalKeyboardKey.f9, 'F10': LogicalKeyboardKey.f10, 'F11': LogicalKeyboardKey.f11, 'F12': LogicalKeyboardKey.f12,
  'F13': LogicalKeyboardKey.f13, 'F14': LogicalKeyboardKey.f14, 'F15': LogicalKeyboardKey.f15, 'F16': LogicalKeyboardKey.f16,
  'F17': LogicalKeyboardKey.f17, 'F18': LogicalKeyboardKey.f18, 'F19': LogicalKeyboardKey.f19, 'F20': LogicalKeyboardKey.f20,
  'ESCAPE': LogicalKeyboardKey.escape,
  'ENTER': LogicalKeyboardKey.enter,
  'TAB': LogicalKeyboardKey.tab,
  'SPACE': LogicalKeyboardKey.space,
  'BACK_SPACE': LogicalKeyboardKey.backspace,
  'DELETE': LogicalKeyboardKey.delete,
  'HOME': LogicalKeyboardKey.home,
  'END': LogicalKeyboardKey.end,
  'PAGE_UP': LogicalKeyboardKey.pageUp,
  'PAGE_DOWN': LogicalKeyboardKey.pageDown,
  'LEFT': LogicalKeyboardKey.arrowLeft,
  'RIGHT': LogicalKeyboardKey.arrowRight,
  'UP': LogicalKeyboardKey.arrowUp,
  'DOWN': LogicalKeyboardKey.arrowDown,
  'COMMA': LogicalKeyboardKey.comma,
  'PERIOD': LogicalKeyboardKey.period,
  'SLASH': LogicalKeyboardKey.slash,
  'BACK_SLASH': LogicalKeyboardKey.backslash,
  'SEMICOLON': LogicalKeyboardKey.semicolon,
  'QUOTE': LogicalKeyboardKey.quoteSingle,
  'BACK_QUOTE': LogicalKeyboardKey.backquote,
  'EQUALS': LogicalKeyboardKey.equal,
  'MINUS': LogicalKeyboardKey.minus,
  'OPEN_BRACKET': LogicalKeyboardKey.bracketLeft,
  'CLOSE_BRACKET': LogicalKeyboardKey.bracketRight,
};

final Map<LogicalKeyboardKey, String> _byLogical = {for (final e in _keys.entries) e.value: e.key};

const Map<String, String> _names = {
  'ESCAPE': 'Esc', 'ENTER': 'Enter', 'TAB': 'Tab', 'SPACE': 'Space', 'BACK_SPACE': 'Backspace', 'DELETE': 'Delete',
  'HOME': 'Home', 'END': 'End', 'PAGE_UP': 'PageUp', 'PAGE_DOWN': 'PageDown',
  'LEFT': 'Left', 'RIGHT': 'Right', 'UP': 'Up', 'DOWN': 'Down',
  'COMMA': ',', 'PERIOD': '.', 'SLASH': '/', 'BACK_SLASH': '\\', 'SEMICOLON': ';', 'QUOTE': "'", 'BACK_QUOTE': '`',
  'EQUALS': '=', 'MINUS': '-', 'OPEN_BRACKET': '[', 'CLOSE_BRACKET': ']',
};

final Map<String, String> _macNames = {
  ..._names,
  'ESCAPE': '⎋', 'ENTER': '↩', 'TAB': '⇥', 'BACK_SPACE': '⌫', 'DELETE': '⌦', 'HOME': '↖', 'END': '↘',
  'PAGE_UP': '⇞', 'PAGE_DOWN': '⇟', 'LEFT': '←', 'RIGHT': '→', 'UP': '↑', 'DOWN': '↓',
};
