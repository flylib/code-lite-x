import 'package:flutter/material.dart';

/// IntelliJ IDEA 新 UI 的「Islands Dark」配色(取自用户给的 IntelliJ 截图,逐像素取色):
/// 标题栏、活动条、状态栏和岛之间的缝是一种颜色([frameBg]),
/// 编辑区、工具窗、终端是一块块圆角「岛」([islandBg])。
class IntelliJTheme {
  // Islands
  /// 窗口底色:标题栏、两条活动条、状态栏、岛与岛之间的缝。
  static const Color frameBg = Color(0xFF24282C);

  /// 岛的底色:编辑区、侧边工具窗、底部工具窗。
  static const Color islandBg = Color(0xFF181A1C);

  /// 菜单、下拉、对话框(浮在岛上面的东西)。
  static const Color popupBg = Color(0xFF2B2D30);

  // Backgrounds
  static const Color headerBg = frameBg;
  static const Color stripeBg = frameBg;
  static const Color panelBg = islandBg;
  static const Color editorBg = islandBg;

  /// 选中的编辑器标签:蓝灰色圆角块(没有下划线)。
  static const Color tabActiveBg = Color(0xFF25334E);
  static const Color tabInactiveBg = islandBg;
  static const Color subHeaderBg = Color(0xFF1D1F22);
  static const Color cardBg = islandBg;

  /// 活动条上选中的按钮:实心灰色圆角块。
  static const Color stripeActiveBg = Color(0xFF45474B);

  /// 工具窗里选中的标签(终端的 Local)、代码块的底色。
  static const Color chipBg = Color(0xFF2B2C30);

  // Editor
  static const Color currentLineBg = Color(0xFF1F2125);
  static const Color textSelectionBg = Color(0xFF2A3B41);
  static const Color lineNumber = Color(0xFF515355);
  static const Color lineNumberCurrent = Color(0xFFA3A4A8);
  static const Color scrollbarThumb = Color(0xFF444648);

  // Borders
  static const Color border = Color(0xFF34363A);
  static const Color borderSubtle = Color(0xFF26282A);

  // Accents & Highlights
  static const Color accentBlue = Color(0xFF3574F0);
  static const Color accentYellow = Color(0xFFE5A84B);
  static const Color sidebarBg = islandBg;
  static const Color hoverBg = Color(0xFF2F3236);
  static const Color selectionBg = Color(0x333574F0);

  // Git Indicators (from IntelliJ New UI)
  static const Color gitGreen = Color(0xFF59A869);
  static const Color gitBlue = Color(0xFF3574F0);
  static const Color gitRed = Color(0xFFDB5860);
  static const Color gitYellow = Color(0xFFE5A84B);

  /// 修改过的文件(日志详情栏里的文件名),取自 IntelliJ 的截图。
  static const Color gitModified = Color(0xFF70AEFF);

  /// 数据文件(json / yaml / toml)的 `{}` 图标,同样取自 IntelliJ 的截图。
  static const Color dataFileIcon = Color(0xFFB589EC);

  // Text Colors
  static const Color textHigh = Color(0xFFDFE1E5);
  static const Color textPrimary = Color(0xFFBCBEC4);
  static const Color textSecondary = Color(0xFF9DA0A8);

  /// 没选中的编辑器标签、活动条图标。
  static const Color textTab = Color(0xFFB4B8BF);
  static const Color icon = Color(0xFFCED0D6);

  /// 状态栏文字。
  static const Color textStatus = Color(0xFF9FA2A8);
  static const Color link = Color(0xFF6CA3D9);
  static const Color textMuted = Color(0xFF707278);
  static const Color textGutter = Color(0xFF606366);

  // Code Syntax Colors (Darcula Modern)
  static const Color syntaxKeyword = Color(0xFFCF8E6D);
  static const Color syntaxType = Color(0xFFC886E5);
  static const Color syntaxFunction = Color(0xFF56A8F5);
  static const Color syntaxString = Color(0xFF6AAB73);
  static const Color syntaxComment = Color(0xFF7A7E85);
  static const Color syntaxNumber = Color(0xFF2AACB8);


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
      scaffoldBackgroundColor: frameBg,
      primaryColor: accentBlue,
      canvasColor: popupBg,
      dialogTheme: const DialogThemeData(backgroundColor: popupBg),
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
  static const double activityStripe = 40;

  /// 岛的圆角与岛之间的缝。
  static const double islandRadius = 8;
  static const double islandGap = 5;
  static const double stripeItem = 30;
  static const double stripeIcon = 18;
  static const double toolWindowHeader = 34;
  static const double sidePanel = 250;
  static const double tabStrip = 36;
  static const double breadcrumb = 24;
  static const double gutter = 48;
  static const double gitStripe = 3;
  static const double codeLine = 20;
  static const double codeFontSize = 12;
  static const double codeLineHeight = 1.4;
  static const double charWidth = 7.2;

  /// 编辑器等宽字体。macOS 上 Flutter 不认 'monospace' 这个通用名,会回退到比例字体
  /// (San Francisco),导致按列计算的光标位置和实际字形错位,所以显式指定 Menlo。
  static const String codeFontFamily = 'Menlo';
  static const List<String> codeFontFallback = [
    'SF Mono', 'Monaco', 'JetBrains Mono', 'Consolas', 'DejaVu Sans Mono', 'Liberation Mono',
    'PingFang SC', 'Noto Sans CJK SC', 'Microsoft YaHei', 'monospace',
  ];

  static const double contextSources = 300;
  static const double contextDetail = 340;
  static const double reviewFileList = 280;
  static const double bottomTools = 220;
  static const double statusBar = 30;
  static const double dialogWidth = 620;
  static const double treeRow = 22;
}
