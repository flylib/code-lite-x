import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter_markdown_plus/flutter_markdown_plus.dart';
import 'package:markdown/markdown.dart' as md;

import '../../../core/platform/browsers.dart' as browsers;
import '../../../core/platform/workspace_io.dart' as io;
import '../../../core/theme/intellij_theme.dart';
import '../code_editor_controller.dart';
import '../syntax/color_schemes.dart';
import '../syntax/document_highlighter.dart';
import '../syntax/language.dart';
import '../syntax/languages.dart';
import 'markdown_links.dart';

/// 预览用到的系统能力(文件是否存在、读图片、开网址)。测试里换成假的。
class MarkdownEnv {
  const MarkdownEnv({this.fileExists = io.fileExists, this.readBytes = _readBytes, this.openUrl = browsers.openExternalUrl});

  final Future<bool> Function(String path) fileExists;
  final Future<Uint8List?> Function(String path) readBytes;
  final Future<String?> Function(String url) openUrl;

  static Future<Uint8List?> _readBytes(String path) => io.readFileBytes(path);
}

/// Markdown 文件的预览:随编辑器里的文字实时刷新(停手 [debounce] 后重新渲染),
/// 代码块用编辑器同一套配色高亮,链接 / 图片按文件所在目录解析,
/// 分屏时和编辑器按比例同步滚动。
class MarkdownPreview extends StatefulWidget {
  const MarkdownPreview({
    super.key,
    required this.controller,
    required this.filePath,
    required this.root,
    required this.scheme,
    this.syncWith,
    this.onOpenFile,
    this.env = const MarkdownEnv(),
    this.debounce = const Duration(milliseconds: 200),
  });

  final CodeEditorController controller;

  /// 这篇文档的路径(绝对,或相对项目根)。
  final String filePath;
  final String root;
  final EditorColorScheme scheme;

  /// 分屏时编辑器的竖向滚动控制器:两边一起滚。
  final ScrollController? syncWith;

  /// 点了指向本地文件的链接:在编辑器里打开它(绝对路径)。
  final ValueChanged<String>? onOpenFile;
  final MarkdownEnv env;
  final Duration debounce;

  @override
  State<MarkdownPreview> createState() => _MarkdownPreviewState();
}

class _MarkdownPreviewState extends State<MarkdownPreview> {
  final ScrollController _scroll = ScrollController();
  late String _text = widget.controller.text;
  Timer? _timer;
  bool _syncing = false;

  @override
  void initState() {
    super.initState();
    widget.controller.addChangeListener(_onChange);
    widget.syncWith?.addListener(_onEditorScroll);
    _scroll.addListener(_onPreviewScroll);
  }

  @override
  void didUpdateWidget(MarkdownPreview old) {
    super.didUpdateWidget(old);
    if (old.controller != widget.controller) {
      old.controller.removeChangeListener(_onChange);
      widget.controller.addChangeListener(_onChange);
      _text = widget.controller.text;
    }
    if (old.syncWith != widget.syncWith) {
      old.syncWith?.removeListener(_onEditorScroll);
      widget.syncWith?.addListener(_onEditorScroll);
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    widget.controller.removeChangeListener(_onChange);
    widget.syncWith?.removeListener(_onEditorScroll);
    _scroll.dispose();
    super.dispose();
  }

  void _onChange(EditorTextChange _) {
    _timer?.cancel();
    _timer = Timer(widget.debounce, () {
      if (!mounted || widget.controller.isDisposed) return;
      final next = widget.controller.text;
      if (next != _text) setState(() => _text = next);
    });
  }

  void _onEditorScroll() {
    final editor = widget.syncWith;
    if (editor != null) _follow(editor, _scroll);
  }

  void _onPreviewScroll() {
    final editor = widget.syncWith;
    if (editor != null) _follow(_scroll, editor);
  }

  /// 按比例让 [to] 跟着 [from] 滚(两边内容高度不同,按文档的相对位置对齐)。
  void _follow(ScrollController from, ScrollController to) {
    if (_syncing || !from.hasClients || !to.hasClients) return;
    final fromMax = from.position.maxScrollExtent;
    if (fromMax <= 0) return;
    final fraction = (from.offset / fromMax).clamp(0.0, 1.0);
    final target = fraction * to.position.maxScrollExtent;
    if ((to.offset - target).abs() < 1) return;
    _syncing = true;
    try {
      to.jumpTo(target);
    } finally {
      _syncing = false;
    }
  }

  // ---------------------------------------------------------------------------
  // 链接与图片
  // ---------------------------------------------------------------------------

  void _toast(String message) {
    final messenger = ScaffoldMessenger.maybeOf(context);
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(content: Text(message)));
  }

  Future<void> _tapLink(String text, String? href, String title) async {
    final target = resolveMarkdownLink(href, fromFile: widget.filePath, root: widget.root);
    switch (target.kind) {
      case LinkKind.none || LinkKind.anchor:
        return;
      case LinkKind.external:
        final err = await widget.env.openUrl(target.url);
        if (err != null && err.isNotEmpty) _toast('无法打开 ${target.url}:$err');
      case LinkKind.file:
        for (final path in target.candidates) {
          if (await widget.env.fileExists(path)) {
            widget.onOpenFile?.call(path);
            return;
          }
        }
        _toast('找不到文件: ${target.candidates.first}');
    }
  }

  Widget _image(Uri uri, String? title, String? alt) {
    final src = uri.toString();
    final source = resolveMarkdownImage(Uri.decodeFull(src), fromFile: widget.filePath, root: widget.root);
    Widget broken() => _BrokenImage(alt: alt, src: src);
    switch (source.kind) {
      case ImageKind.network:
        return _fit(Image.network(source.url, errorBuilder: (_, __, ___) => broken()));
      case ImageKind.data:
        final bytes = UriData.parse(source.url).contentAsBytes();
        return _fit(Image.memory(bytes, errorBuilder: (_, __, ___) => broken()));
      case ImageKind.file:
        return _LocalImage(candidates: source.candidates, env: widget.env, broken: broken, fit: _fit);
      case ImageKind.none:
        return broken();
    }
  }

  static Widget _fit(Widget image) => Align(
        alignment: Alignment.centerLeft,
        child: ConstrainedBox(constraints: const BoxConstraints(maxWidth: 900), child: image),
      );

  @override
  Widget build(BuildContext context) {
    final style = markdownStyleSheet(Theme.of(context));
    return ColoredBox(
      color: widget.scheme.background,
      // 文字选中用 SelectionArea(能跨段落选);Markdown 自带的 selectable 模式走 SelectableText,画不了内嵌图片
      child: SelectionArea(
        child: Markdown(
          data: _text,
          controller: _scroll,
          styleSheet: style,
          extensionSet: md.ExtensionSet.gitHubFlavored,
          onTapLink: _tapLink,
          imageBuilder: _image,
          builders: {'pre': CodeBlockBuilder(widget.scheme)},
          padding: const EdgeInsets.fromLTRB(28, 18, 28, 48),
        ),
      ),
    );
  }
}

/// 预览的排版:IntelliJ Darcula 的暗色,标题加粗、行内代码有底色、引用左侧一条线。
MarkdownStyleSheet markdownStyleSheet(ThemeData theme) {
  const mono = TextStyle(fontFamily: IntelliJMetrics.codeFontFamily, fontFamilyFallback: IntelliJMetrics.codeFontFallback);
  const body = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 14, height: 1.6);
  TextStyle heading(double size) => TextStyle(color: IntelliJTheme.textHigh, fontSize: size, fontWeight: FontWeight.w700, height: 1.35);
  return MarkdownStyleSheet.fromTheme(theme).copyWith(
    p: body,
    pPadding: EdgeInsets.zero,
    a: const TextStyle(color: Color(0xFF589DF6), decoration: TextDecoration.none),
    h1: heading(30),
    h2: heading(24),
    h3: heading(19),
    h4: heading(16),
    h5: heading(14),
    h6: heading(14).copyWith(color: IntelliJTheme.textSecondary),
    h1Padding: const EdgeInsets.only(top: 8, bottom: 4),
    h2Padding: const EdgeInsets.only(top: 16, bottom: 4),
    h3Padding: const EdgeInsets.only(top: 12, bottom: 2),
    em: body.copyWith(fontStyle: FontStyle.italic),
    strong: body.copyWith(fontWeight: FontWeight.w700, color: IntelliJTheme.textHigh),
    del: body.copyWith(decoration: TextDecoration.lineThrough, color: IntelliJTheme.textMuted),
    code: mono.copyWith(fontSize: 13, color: IntelliJTheme.textPrimary, backgroundColor: const Color(0xFF2B2D30)),
    blockquote: body.copyWith(color: IntelliJTheme.textSecondary),
    blockquotePadding: const EdgeInsets.fromLTRB(14, 6, 8, 6),
    blockquoteDecoration: const BoxDecoration(border: Border(left: BorderSide(color: Color(0xFF4E5157), width: 4))),
    listBullet: body,
    listIndent: 24,
    blockSpacing: 14,
    horizontalRuleDecoration: const BoxDecoration(border: Border(top: BorderSide(color: IntelliJTheme.border))),
    tableHead: body.copyWith(fontWeight: FontWeight.w700, color: IntelliJTheme.textHigh),
    tableBody: body,
    tableBorder: TableBorder.all(color: IntelliJTheme.border, width: 1),
    tableCellsPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
    tableColumnWidth: const IntrinsicColumnWidth(),
    checkbox: body.copyWith(color: const Color(0xFF589DF6)),
  );
}

/// 围栏代码块(```java ...```):整块自己画,按语言用编辑器同一套配色高亮,可选中(SelectionArea)、横向滚动。
class CodeBlockBuilder extends MarkdownElementBuilder {
  CodeBlockBuilder(this.scheme);

  final EditorColorScheme scheme;

  @override
  bool isBlockElement() => true;

  @override
  Widget? visitElementAfterWithContext(BuildContext context, md.Element element, TextStyle? preferredStyle, TextStyle? parentStyle) {
    final code = element.children?.whereType<md.Element>().firstOrNull;
    final text = (code ?? element).textContent.replaceAll(RegExp(r'\n$'), '');
    final lang = _languageOf(code?.attributes['class']);
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(color: const Color(0xFF2B2D30), borderRadius: BorderRadius.circular(6)),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Text.rich(
          TextSpan(
            style: TextStyle(
              fontFamily: IntelliJMetrics.codeFontFamily,
              fontFamilyFallback: IntelliJMetrics.codeFontFallback,
              fontSize: 13,
              height: 1.5,
              color: scheme.foreground,
            ),
            children: highlightCode(text, lang, scheme),
          ),
        ),
      ),
    );
  }

  /// `language-java` → java 的语言定义;认不出来返回 null(不着色)。
  static LanguageSpec? _languageOf(String? cssClass) {
    if (cssClass == null || !cssClass.startsWith('language-')) return null;
    final name = cssClass.substring('language-'.length).trim().toLowerCase();
    if (name.isEmpty) return null;
    final spec = languages.byId(name) ?? languages.detect('x.$name');
    return spec.id == LanguageRegistry.plainText.id ? null : spec;
  }
}

/// 把 [code] 按 [lang] 着色成文字片段(含换行);[lang] 为 null 时原样。
List<InlineSpan> highlightCode(String code, LanguageSpec? lang, EditorColorScheme scheme) {
  if (lang == null) return [TextSpan(text: code)];
  final lines = code.split('\n');
  final h = DocumentHighlighter()..update(lang, lines, scheme: scheme);
  return [
    for (var i = 0; i < lines.length; i++) ...[
      ...h.spansAt(i),
      if (i < lines.length - 1) const TextSpan(text: '\n'),
    ],
  ];
}

class _LocalImage extends StatefulWidget {
  const _LocalImage({required this.candidates, required this.env, required this.broken, required this.fit});

  final List<String> candidates;
  final MarkdownEnv env;
  final Widget Function() broken;
  final Widget Function(Widget) fit;

  @override
  State<_LocalImage> createState() => _LocalImageState();
}

class _LocalImageState extends State<_LocalImage> {
  late final Future<Uint8List?> _bytes = _load();

  Future<Uint8List?> _load() async {
    for (final path in widget.candidates) {
      final bytes = await widget.env.readBytes(path);
      if (bytes != null) return bytes;
    }
    return null;
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<Uint8List?>(
      future: _bytes,
      builder: (context, snap) {
        if (snap.connectionState != ConnectionState.done) return const SizedBox(height: 24);
        final bytes = snap.data;
        if (bytes == null) return widget.broken();
        return widget.fit(Image.memory(bytes, errorBuilder: (_, __, ___) => widget.broken()));
      },
    );
  }
}

class _BrokenImage extends StatelessWidget {
  const _BrokenImage({required this.alt, required this.src});

  final String? alt;
  final String src;

  @override
  Widget build(BuildContext context) {
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        const Icon(Icons.broken_image_outlined, size: 16, color: IntelliJTheme.textMuted),
        const SizedBox(width: 6),
        Flexible(child: Text((alt ?? '').isEmpty ? src : alt!, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12), overflow: TextOverflow.ellipsis)),
      ],
    );
  }
}
