import 'dart:async';

import 'package:code_lite_ui/core/l10n/l10n.dart';

/// 所有测试默认按中文界面跑(不随跑测试的机器的系统语言变);要测英文的自己切 [L10n.language]。
Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  L10n.systemLanguage = () => AppLanguage.zh;
  L10n.language.value = AppLanguage.zh;
  await testMain();
}
