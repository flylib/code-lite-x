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


  // Agent step states (Phase 9 — StepStatus 的 7 态)
  static const Color stepSuccess = gitGreen;
  static const Color stepRunning = accentBlue;
  static const Color stepAwaiting = accentYellow;
  static const Color stepFailed = gitRed;
  static const Color stepRolledBack = Color(0xFF8E6BC4);
  static const Color stepPending = textMuted;

  // Editor overlays (与 editor_view_widget 里的字面量对齐)
  static const Color ghostText = Color(0xFF6E7681);
  static const Color caret = Color(0xFF589DF6);
  static const Color diagError = Color(0xFFF97A7A);
  static const Color diagWarning = Color(0xFFE5C07B);

  // Traffic lights
  static const Color trafficRed = Color(0xFFEC6A5E);
  static const Color trafficYellow = Color(0xFFF4BF4F);
  static const Color trafficGreen = Color(0xFF62C554);

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

/// 面板与行距的固定几何。数值取自 design/ 下的六张设计稿,
/// 此前散落在各 widget 里作字面量。
class IntelliJMetrics {
  const IntelliJMetrics._();

  static const double titleBar = 40;
  static const double projectTabs = 28;
  static const double activityStripe = 44;
  static const double stripeItem = 32;
  static const double stripeIcon = 18;
  static const double toolWindowHeader = 34;
  static const double sidePanel = 250;
  static const double tabStrip = 34;
  static const double breadcrumb = 24;
  static const double gutter = 48;
  static const double gitStripe = 3;
  static const double codeLine = 20;
  static const double codeFontSize = 12;
  static const double codeLineHeight = 1.4;
  static const double charWidth = 7.2;
  static const double aiPanel = 310;
  static const double agentPanel = 420;
  static const double cargoPanel = 250;
  static const double contextSources = 300;
  static const double contextDetail = 340;
  static const double reviewFileList = 280;
  static const double bottomTools = 220;
  static const double statusBar = 22;
  static const double dialogWidth = 620;
  static const double treeRow = 22;
}
