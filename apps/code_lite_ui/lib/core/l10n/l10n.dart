// 界面语言(设置 ▸ 语言和地区):中文 / English。
//
// 写法:界面上的字一律 `tr('中文', 'English')`,两种语言挨着写在用的地方。
// 换语言时整个界面立刻按新语言重画([L10n.language] 变了,应用根部重建所有元素),不用重启。
// 专有名词(Git、GitHub、Maven、make、HEAD、IntelliJ……)两边一样;
// 其余术语照 JetBrains 官方中文语言包(Commit 提交、Push 推送、Rollback 回滚、Problems 问题……)。


import 'package:flutter/foundation.dart';

enum AppLanguage {
  zh('中文'),
  en('English');

  const AppLanguage(this.label);

  /// 设置里显示的名字(用它自己的语言写)。
  final String label;

  static AppLanguage? parse(Object? code) => switch (code) {
        'zh' => AppLanguage.zh,
        'en' => AppLanguage.en,
        _ => null,
      };
}

abstract final class L10n {
  /// 当前的界面语言。没设置过时由 [SettingsStore.load] 按系统语言定。
  static final ValueNotifier<AppLanguage> language = ValueNotifier(AppLanguage.zh);

  static bool get isEnglish => language.value == AppLanguage.en;

  /// 系统语言:中文系统用中文,其余用英文。测试里换成固定值(test/flutter_test_config.dart)。
  static AppLanguage Function() systemLanguage =
      () => PlatformDispatcher.instance.locale.languageCode == 'zh' ? AppLanguage.zh : AppLanguage.en;
}

/// 按当前界面语言取字。
String tr(String zh, String en) => L10n.language.value == AppLanguage.en ? en : zh;

/// 菜单里的搜索两种语言都认(不分大小写):中文界面里打 `push` 也能找到「推送…」,英文界面里打「推送」也行。
bool matchesEitherLanguage(String query, String zh, String en) {
  final q = query.trim().toLowerCase();
  return q.isEmpty || zh.toLowerCase().contains(q) || en.toLowerCase().contains(q);
}
