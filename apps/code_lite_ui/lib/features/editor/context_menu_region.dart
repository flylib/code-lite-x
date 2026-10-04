import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';

/// 右键弹出级联菜单的区域。用 [MenuAnchor] 而不是 showMenu:要支持子菜单
/// (Appearance ▸ / View ▸ Colors ▸)和勾选项,与 IntelliJ 的行号栏 / 注释栏菜单一致。
///
/// [menuBuilder] 拿到右键点在本区域内的位置,据此决定菜单内容(比如点的是第几行)。
class ContextMenuRegion extends StatefulWidget {
  const ContextMenuRegion({super.key, required this.menuBuilder, required this.child});

  final List<Widget> Function(Offset localPosition) menuBuilder;
  final Widget child;

  @override
  State<ContextMenuRegion> createState() => _ContextMenuRegionState();
}

class _ContextMenuRegionState extends State<ContextMenuRegion> {
  final MenuController _controller = MenuController();
  Offset? _position;

  void _open(Offset local) {
    setState(() => _position = local);
    // 菜单内容依赖点击位置:先按新位置重建,下一帧再打开。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _controller.open(position: local);
    });
  }

  @override
  Widget build(BuildContext context) {
    final pos = _position;
    return Theme(
      data: darculaMenuTheme(Theme.of(context)),
      child: MenuAnchor(
        controller: _controller,
        consumeOutsideTap: true,
        menuChildren: pos == null ? const [] : widget.menuBuilder(pos),
        child: GestureDetector(
          behavior: HitTestBehavior.opaque,
          onSecondaryTapDown: (d) => _open(d.localPosition),
          child: widget.child,
        ),
      ),
    );
  }
}

/// IntelliJ Darcula 风格的菜单主题:深灰底、圆角、细边框、紧凑行高。
ThemeData darculaMenuTheme(ThemeData base) {
  const text = TextStyle(color: IntelliJTheme.textHigh, fontSize: 13);
  final itemStyle = ButtonStyle(
    textStyle: const WidgetStatePropertyAll(text),
    foregroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.disabled) ? IntelliJTheme.textMuted : IntelliJTheme.textHigh,
    ),
    backgroundColor: WidgetStateProperty.resolveWith(
      (s) => s.contains(WidgetState.hovered) || s.contains(WidgetState.focused)
          ? const Color(0xFF2E436E)
          : Colors.transparent,
    ),
    iconColor: const WidgetStatePropertyAll(IntelliJTheme.textSecondary),
    minimumSize: const WidgetStatePropertyAll(Size(0, 30)),
    padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(horizontal: 12)),
    shape: WidgetStatePropertyAll(RoundedRectangleBorder(borderRadius: BorderRadius.circular(5))),
    visualDensity: VisualDensity.compact,
  );
  return base.copyWith(
    menuTheme: MenuThemeData(
      style: MenuStyle(
        backgroundColor: const WidgetStatePropertyAll(IntelliJTheme.panelBg),
        surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
        elevation: const WidgetStatePropertyAll(8),
        padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 6, horizontal: 6)),
        shape: WidgetStatePropertyAll(
          RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(8),
            side: const BorderSide(color: IntelliJTheme.border),
          ),
        ),
      ),
    ),
    menuButtonTheme: MenuButtonThemeData(style: itemStyle),
    checkboxTheme: const CheckboxThemeData(
      fillColor: WidgetStatePropertyAll(Colors.transparent),
      checkColor: WidgetStatePropertyAll(IntelliJTheme.textHigh),
      side: BorderSide.none,
    ),
    radioTheme: const RadioThemeData(fillColor: WidgetStatePropertyAll(IntelliJTheme.textHigh)),
    dividerTheme: const DividerThemeData(color: IntelliJTheme.border, space: 9, thickness: 1),
  );
}

/// 菜单里的分隔线。
class MenuDivider extends StatelessWidget {
  const MenuDivider({super.key});

  @override
  Widget build(BuildContext context) => const Divider(height: 9, indent: 8, endIndent: 8);
}
