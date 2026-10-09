import 'dart:typed_data';

import 'package:flutter/material.dart';

import '../../core/platform/browsers.dart' as browsers;
import '../../core/theme/intellij_theme.dart';

/// 能在浏览器里预览的文件(按扩展名)。
bool isHtmlFile(String path) {
  final lower = path.toLowerCase();
  return lower.endsWith('.html') || lower.endsWith('.htm') || lower.endsWith('.xhtml');
}

/// 本机浏览器:检测一次(应用装了新浏览器要重启才看得到,和 IntelliJ 差不多),图标转换结果也缓存。
/// 三个操作可替换,测试里不碰真实的系统。
class BrowserService {
  BrowserService({
    Future<List<browsers.BrowserApp>> Function()? detect,
    Future<String?> Function(browsers.BrowserApp, String)? open,
    Future<Uint8List?> Function(browsers.BrowserApp)? icon,
  })  : _detect = detect ?? browsers.detectBrowsers,
        _open = open ?? browsers.openInBrowser,
        _icon = icon ?? browsers.browserIcon;

  final Future<List<browsers.BrowserApp>> Function() _detect;
  final Future<String?> Function(browsers.BrowserApp, String) _open;
  final Future<Uint8List?> Function(browsers.BrowserApp) _icon;

  Future<List<browsers.BrowserApp>>? _installed;
  final Map<String, Future<Uint8List?>> _icons = {};

  Future<List<browsers.BrowserApp>> installed() => _installed ??= _detect();

  Future<Uint8List?> iconOf(browsers.BrowserApp b) => _icons[b.id] ??= _icon(b);

  /// 用 [b] 打开 [file](绝对路径)。成功返回 null,失败返回原因。
  Future<String?> open(browsers.BrowserApp b, String file) => _open(b, file);
}

/// 编辑器右上角的浏览器图标(IntelliJ 打开 HTML 文件时的那排):点哪个就用哪个浏览器打开当前文件。
/// 一个浏览器都没找到时什么也不显示。
class OpenInBrowserBar extends StatelessWidget {
  const OpenInBrowserBar({super.key, required this.service, required this.file, this.beforeOpen});

  final BrowserService service;

  /// 要打开的文件(绝对路径)。
  final String file;

  /// 打开之前先做的事,通常是把编辑器里没落盘的改动存下来,浏览器才看得到最新内容。
  final Future<void> Function()? beforeOpen;

  Future<void> _open(BuildContext context, browsers.BrowserApp b) async {
    final messenger = ScaffoldMessenger.maybeOf(context);
    await beforeOpen?.call();
    final error = await service.open(b, file);
    if (error != null && error.isNotEmpty) {
      messenger?.showSnackBar(SnackBar(content: Text('无法用 ${b.name} 打开:$error')));
    }
  }

  @override
  Widget build(BuildContext context) {
    final name = file.split(RegExp(r'[/\\]')).last;
    return FutureBuilder<List<browsers.BrowserApp>>(
      future: service.installed(),
      builder: (context, snap) {
        final list = snap.data ?? const [];
        if (list.isEmpty) return const SizedBox.shrink();
        return Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 3),
          decoration: BoxDecoration(
            color: IntelliJTheme.panelBg.withValues(alpha: 0.92),
            borderRadius: BorderRadius.circular(6),
            border: Border.all(color: IntelliJTheme.borderSubtle),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              for (final b in list)
                Tooltip(
                  message: '在 ${b.name} 中打开 $name',
                  waitDuration: const Duration(milliseconds: 400),
                  child: InkWell(
                    key: ValueKey('open-in-${b.id}'),
                    onTap: () => _open(context, b),
                    borderRadius: BorderRadius.circular(4),
                    hoverColor: IntelliJTheme.hoverBg,
                    child: Padding(padding: const EdgeInsets.all(4), child: _BrowserIcon(service: service, browser: b)),
                  ),
                ),
            ],
          ),
        );
      },
    );
  }
}

/// 浏览器图标;转换不出来(非 macOS、读不到)时用字母徽标。
class _BrowserIcon extends StatelessWidget {
  const _BrowserIcon({required this.service, required this.browser});

  final BrowserService service;
  final browsers.BrowserApp browser;

  static const double size = 20;

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: service.iconOf(browser),
      builder: (context, snap) {
        final bytes = snap.data;
        if (bytes != null) {
          return Image.memory(bytes, width: size, height: size, filterQuality: FilterQuality.medium, errorBuilder: (_, __, ___) => _fallback());
        }
        // 还在转换时也先显示字母,免得图标一个个蹦出来
        return _fallback();
      },
    );
  }

  Widget _fallback() => Container(
        width: size,
        height: size,
        alignment: Alignment.center,
        decoration: BoxDecoration(color: IntelliJTheme.accentBlue.withValues(alpha: 0.35), borderRadius: BorderRadius.circular(5)),
        child: Text(browser.name.characters.first.toUpperCase(), style: const TextStyle(color: Colors.white, fontSize: 11, fontWeight: FontWeight.w700, height: 1)),
      );
}
