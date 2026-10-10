import 'package:code_lite_ui/features/editor/editor_appearance.dart';
import 'package:code_lite_ui/features/editor/markdown/markdown_links.dart';
import 'package:flutter_test/flutter_test.dart';

/// Markdown 预览里的链接 / 图片地址解释,以及三种显示方式的持久化。
const root = '/work/app';

void main() {
  test('markdown files are recognised by extension only', () {
    for (final p in ['README.md', 'docs/a.MD', '/x/y/notes.markdown', 'a.mdown', 'a.mkd', r'C:\docs\a.md']) {
      expect(isMarkdownFile(p), isTrue, reason: p);
    }
    for (final p in ['md', '.md', 'a.mdx', 'a.md.bak', 'README', 'a.txt', 'dir.md/file']) {
      expect(isMarkdownFile(p), isFalse, reason: p);
    }
  });

  test('normalizePath handles . .. and repeated slashes without escaping the root', () {
    expect(normalizePath('/a/b/../c/./d//e'), '/a/c/d/e');
    expect(normalizePath('/../../x'), '/x');
    expect(normalizePath('a/../../b'), '../b');
    expect(normalizePath('/'), '/');
  });

  group('links', () {
    LinkTarget link(String? href, {String from = 'docs/guide/intro.md'}) => resolveMarkdownLink(href, fromFile: from, root: root);

    test('web and mail links go to the system; scripts and unknown schemes are ignored', () {
      expect(link('https://example.com/a?b=1#c').kind, LinkKind.external);
      expect(link('https://example.com/a?b=1#c').url, 'https://example.com/a?b=1#c');
      expect(link('http://x.y').kind, LinkKind.external);
      expect(link('mailto:me@x.y').kind, LinkKind.external);
      expect(link('javascript:alert(1)').kind, LinkKind.none);
      expect(link('vscode://open?x=1').kind, LinkKind.none);
      expect(link('').kind, LinkKind.none);
      expect(link(null).kind, LinkKind.none);
      expect(link('   ').kind, LinkKind.none);
    });

    test('anchors', () {
      expect(link('#install').kind, LinkKind.anchor);
      expect(link('#%E5%AE%89%E8%A3%85').fragment, '安装', reason: '中文锚点解码');
      expect(link('#').kind, LinkKind.anchor);
    });

    test('relative links resolve against the document directory; the tab path may be absolute or project-relative', () {
      expect(link('other.md').candidates, ['/work/app/docs/guide/other.md']);
      expect(link('../design/a.md#x').candidates, ['/work/app/docs/design/a.md']);
      expect(link('../design/a.md#x').fragment, 'x');
      expect(link('./sub/b.md?plain=1').candidates, ['/work/app/docs/guide/sub/b.md']);
      expect(link('b.md', from: '/work/app/docs/guide/intro.md').candidates, ['/work/app/docs/guide/b.md'], reason: '文件树给的绝对路径');
      expect(link('b.md', from: 'README.md').candidates, ['/work/app/b.md']);
      expect(link('with%20space.md').candidates, ['/work/app/docs/guide/with space.md']);
      expect(link('100%.md').candidates, ['/work/app/docs/guide/100%.md'], reason: '没编码好的 % 原样留着');
      expect(link('other.md#').kind, LinkKind.file);
      expect(link('#').kind, LinkKind.anchor);
    });

    test('a leading slash is project-relative first, then a system path; file: urls are system paths', () {
      expect(link('/docs/a.md').candidates, ['/work/app/docs/a.md', '/docs/a.md']);
      expect(link('file:///etc/hosts').candidates, ['/etc/hosts']);
      expect(link('file:///a%20b/c.md#top').candidates, ['/a b/c.md']);
      expect(link('file:///a%20b/c.md#top').fragment, 'top');
    });

    test('a Windows drive path is not mistaken for a url scheme', () {
      expect(link(r'C:\docs\a.md').kind, LinkKind.file);
    });
  });

  group('images', () {
    ImageSource image(String src, {String from = 'docs/readme.md'}) => resolveMarkdownImage(src, fromFile: from, root: root);

    test('network, data and local images', () {
      expect(image('https://x.y/a.png').kind, ImageKind.network);
      expect(image('HTTP://x.y/a.png').kind, ImageKind.network);
      expect(image('data:image/png;base64,AAAA').kind, ImageKind.data);
      expect(image('img/a.png').kind, ImageKind.file);
      expect(image('img/a.png').candidates, ['/work/app/docs/img/a.png']);
      expect(image('../a%20b.png').candidates, ['/work/app/a b.png']);
      expect(image('').kind, ImageKind.none);
      expect(image('javascript:x').kind, ImageKind.none);
    });
  });

  test('the view mode is persisted and defaults to editor + preview; garbage falls back', () {
    final a = EditorAppearance();
    expect(a.markdownMode, MarkdownViewMode.split);
    var notified = 0;
    a.addListener(() => notified++);
    a.setMarkdownMode(MarkdownViewMode.preview);
    a.setMarkdownMode(MarkdownViewMode.preview);
    expect(notified, 1, reason: '没变不通知');
    expect(a.toJson()['markdownMode'], 'preview');

    final b = EditorAppearance()..applyJson(a.toJson());
    expect(b.markdownMode, MarkdownViewMode.preview);
    final c = EditorAppearance()..applyJson({'markdownMode': 'sideways'});
    expect(c.markdownMode, MarkdownViewMode.split);
    final d = EditorAppearance()..applyJson({'fontSize': 14});
    expect(d.markdownMode, MarkdownViewMode.split, reason: '旧设置文件里没有这一项');
  });
}
