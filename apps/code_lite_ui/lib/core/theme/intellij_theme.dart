import 'package:flutter/material.dart';

/// IntelliJ IDEA (New UI) Dark Design Tokens
class IntelliJTheme {
  // Backgrounds
  static const Color headerBg = Color(0xFF1E1F22);
  static const Color stripeBg = Color(0xFF1E1F22);
  static const Color panelBg = Color(0xFF2B2D30);
  static const Color editorBg = Color(0xFF1E1F22);
  static const Color tabActiveBg = Color(0xFF1E1F22);
  static const Color tabInactiveBg = Color(0xFF2B2D30);
  static const Color subHeaderBg = Color(0xFF232428);
  static const Color cardBg = Color(0xFF1E1F22);

  // Borders
  static const Color border = Color(0xFF393B40);
  static const Color borderSubtle = Color(0xFF2E3035);

  // Accents & Highlights
  static const Color accentBlue = Color(0xFF3574F0);
  static const Color accentYellow = Color(0xFFE5A84B);
  static const Color sidebarBg = Color(0xFF2B2D30);
  static const Color hoverBg = Color(0xFF35373C);
  static const Color selectionBg = Color(0x333574F0);

  // Git Indicators (from IntelliJ New UI)
  static const Color gitGreen = Color(0xFF59A869);
  static const Color gitBlue = Color(0xFF3574F0);
  static const Color gitRed = Color(0xFFDB5860);
  static const Color gitYellow = Color(0xFFE5A84B);

  // Text Colors
  static const Color textHigh = Color(0xFFDFE1E5);
  static const Color textPrimary = Color(0xFFBCBEC4);
  static const Color textSecondary = Color(0xFF9DA0A8);
  static const Color textMuted = Color(0xFF707278);
  static const Color textGutter = Color(0xFF606366);

  // Code Syntax Colors (Darcula Modern)
  static const Color syntaxKeyword = Color(0xFFCF8E6D);
  static const Color syntaxType = Color(0xFFC886E5);
  static const Color syntaxFunction = Color(0xFF56A8F5);
  static const Color syntaxString = Color(0xFF6AAB73);
  static const Color syntaxComment = Color(0xFF7A7E85);
  static const Color syntaxNumber = Color(0xFF2AACB8);

  // Global Flutter ThemeData
  static ThemeData get darkTheme {
    return ThemeData.dark(useMaterial3: true).copyWith(
      scaffoldBackgroundColor: editorBg,
      primaryColor: accentBlue,
      canvasColor: panelBg,
      cardColor: cardBg,
      dividerColor: borderSubtle,
      textTheme: const TextTheme(
        bodyMedium: TextStyle(color: textPrimary, fontSize: 13),
        bodySmall: TextStyle(color: textMuted, fontSize: 11),
        titleSmall: TextStyle(color: textHigh, fontSize: 12, fontWeight: FontWeight.w600),
      ),
    );
  }
}
