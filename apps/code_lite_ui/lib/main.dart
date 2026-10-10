import 'package:flutter/material.dart';
import 'app.dart';
import 'core/platform/window_chrome.dart';

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  WindowChrome.init(); // 接收全屏通知;不用等它,标题栏先按没全屏画
  runApp(const CodeLiteApp());
}
