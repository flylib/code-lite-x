import '../../core/keymap/keymap.dart';
import '../../core/l10n/l10n.dart';
import '../../core/lsp/java_reference.dart';
import '../../core/lsp/lsp.dart' show LspWorkspaceSymbol;
import '../../core/platform/paths.dart' show absoluteFilePath;
import '../project_explorer/project_explorer_widget.dart' show speedSearchMatch;
import 'goto_file_dialog.dart' show FileQuery, parseGotoQuery;
import 'search_everywhere_dialog.dart';

/// 按类名找文件时认的源文件(一个文件一个顶层类的语言)。
const _classFileExtensions = {'java', 'kt', 'groovy', 'scala'};

/// 也当「类」列出来的源文件(文件名和类名通常一样)。
const _codeExtensions = {..._classFileExtensions, 'dart', 'ts', 'tsx', 'swift', 'cs', 'go', 'rs', 'py'};

/// Search Everywhere 的数据来源:
/// - 文件:Rust 的文件索引([fileQuery]),支持 `Foo.java:120`;
/// - 类:语言服务器的 workspace/symbol 里的类型,加上文件名能对上的源文件(没有语言服务器时也能找);
/// - 符号:workspace/symbol 的全部结果;
/// - 操作:快捷键表里能执行的操作([actions]);
/// - 引用:`com.foo.Bar#baz(com.foo.Dto)`,按包路径找到 `Bar.java`,再在里面找 baz 的那个重载。
/// 结果里的路径都是绝对路径;[readText] 读文件内容(打开着的用编辑器里的)。
SearchSources buildSearchSources({
  required String root,
  required FileQuery fileQuery,
  required Future<List<LspWorkspaceSymbol>> Function(String query) workspaceSymbols,
  required Map<String, void Function()> actions,
  required Future<String?> Function(String absPath) readText,
  KeymapStore? keymap,
}) {
  String abs(String rel) => absoluteFilePath(root, rel);
  String rel(String path) => path.startsWith('$root/') ? path.substring(root.length + 1) : path;
  String nameOf(String path) => path.substring(path.lastIndexOf('/') + 1);
  String dirOf(String path) => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
  String extOf(String path) => nameOf(path).contains('.') ? nameOf(path).split('.').last.toLowerCase() : '';
  String stemOf(String path) => nameOf(path).contains('.') ? nameOf(path).substring(0, nameOf(path).lastIndexOf('.')) : nameOf(path);

  /// `game-service/src/main/java/com/foo/Bar.java` → 模块 `game-service`(第一层目录,同 IntelliJ 右边那列)。
  String? moduleOf(String relPath) => relPath.contains('/') ? relPath.split('/').first : null;

  /// Java / Kotlin 源文件的包名:`src/main/java/` 之后的目录。
  String? packageOf(String relPath) {
    final segs = dirOf(relPath).split('/');
    final i = segs.lastIndexWhere((s) => s == 'java' || s == 'kotlin' || s == 'groovy' || s == 'scala');
    if (i < 0 || i == segs.length - 1) return null;
    return segs.sublist(i + 1).join('.');
  }

  List<String> indexPaths(String q, int limit) {
    final r = fileQuery(q, limit);
    if (r['status'] != 'ok') return const [];
    return [for (final h in (r['results'] as List? ?? const [])) h['path'] as String];
  }

  SearchHit symbolHit(LspWorkspaceSymbol s) {
    final kind = switch (s.kind) {
      5 || 10 || 11 || 23 => SearchHitKind.classType,
      6 || 9 || 12 => SearchHitKind.method,
      7 || 8 || 13 || 14 || 22 => SearchHitKind.field,
      _ => SearchHitKind.symbol,
    };
    final r = rel(abs(s.location.path));
    final container = s.container;
    return SearchHit(
      kind: kind,
      title: s.name,
      detail: container == null || container.isEmpty ? null : tr('位于 $container', 'of $container'),
      location: moduleOf(r),
      path: abs(s.location.path),
      line: s.location.line,
      col: s.location.col,
    );
  }

  List<SearchHit> files(String query, int limit) {
    final (q, line, col) = parseGotoQuery(query);
    if (q.isEmpty) return const [];
    return [
      for (final p in indexPaths(q, limit))
        SearchHit(
          kind: SearchHitKind.file,
          title: nameOf(p),
          location: dirOf(p),
          path: abs(p),
          line: line == null ? null : line - 1,
          col: col == null ? null : col - 1,
        ),
    ];
  }

  Future<List<SearchHit>> classes(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    final out = <SearchHit>[];
    final seen = <String>{};
    for (final s in await workspaceSymbols(q)) {
      if (!s.isType) continue;
      final h = symbolHit(s);
      if (seen.add(h.path!)) out.add(h);
    }
    // 没有语言服务器(或它还在建索引)时:文件名就是类名
    for (final p in indexPaths(q, 50)) {
      if (!_codeExtensions.contains(extOf(p)) || speedSearchMatch(stemOf(p), q) == null) continue;
      if (!seen.add(abs(p))) continue;
      final pkg = packageOf(p);
      out.add(SearchHit(
        kind: SearchHitKind.classType,
        title: stemOf(p),
        detail: pkg == null ? null : tr('位于 $pkg', 'of $pkg'),
        location: moduleOf(p),
        path: abs(p),
        line: 0,
      ));
    }
    return out;
  }

  Future<List<SearchHit>> symbols(String query) async {
    final q = query.trim();
    if (q.isEmpty) return const [];
    return [for (final s in await workspaceSymbols(q)) symbolHit(s)];
  }

  List<SearchHit> actionHits(String query) {
    final q = query.trim();
    if (q.isEmpty) return const [];
    return [
      for (final a in keymapActions)
        if (actions.containsKey(a.id) && matchesEitherLanguage(q, a.titleZh, a.titleEn))
          SearchHit(kind: SearchHitKind.action, title: a.title, actionId: a.id, shortcut: (keymap ?? KeymapStore()).labelOf(a.id)),
    ];
  }

  Future<List<SearchHit>> reference(CodeReference ref) async {
    final parts = ref.className.split('.');
    // 第一段大写开头的是顶层类,前面是包,后面是嵌套类
    var top = parts.indexWhere((s) => s.isNotEmpty && s[0].toUpperCase() == s[0] && s[0].toLowerCase() != s[0]);
    if (top < 0) top = parts.length - 1;
    final pkgDirs = parts.sublist(0, top);
    final classPath = parts.sublist(top);
    final topName = parts[top];

    final named = [
      for (final p in indexPaths(topName, 200))
        if (stemOf(p) == topName && _classFileExtensions.contains(extOf(p))) p,
    ];
    final suffix = [...pkgDirs, topName].join('/');
    final matching = named.where((p) => dirOf(p).isEmpty ? pkgDirs.isEmpty : '${dirOf(p)}/$topName'.endsWith(suffix)).toList();
    final candidates = matching.isNotEmpty ? matching : named;

    final out = <SearchHit>[];
    for (final p in candidates.take(5)) {
      final path = abs(p);
      final text = await readText(path);
      final pkg = packageOf(p) ?? pkgDirs.join('.');
      final owner = [if (pkg.isNotEmpty) pkg, ...classPath.take(classPath.length - 1)].join('.');
      final cls = text == null ? null : findJavaMember(text, classPath);
      out.add(SearchHit(
        kind: SearchHitKind.classType,
        title: classPath.last,
        detail: owner.isEmpty ? null : tr('位于 $owner', 'of $owner'),
        location: moduleOf(p),
        path: path,
        line: ref.line != null ? ref.line! - 1 : cls?.line ?? 0,
        col: ref.line != null ? 0 : cls?.col ?? 0,
      ));
      final member = ref.member;
      if (member == null || text == null) continue;
      final m = findJavaMember(text, classPath, member: member, params: ref.params);
      if (m == null) continue;
      final params = ref.params;
      final lines = text.split('\n');
      final after = m.line < lines.length && m.col + member.length <= lines[m.line].length ? lines[m.line].substring(m.col + member.length).trimLeft() : '';
      out.add(SearchHit(
        kind: params != null || after.startsWith('(') ? SearchHitKind.method : SearchHitKind.field,
        title: params == null ? member : '$member(${params.map((t) => t.split('.').last).join(', ')})',
        detail: tr('位于 ${[if (pkg.isNotEmpty) pkg, ...classPath].join('.')}', 'of ${[if (pkg.isNotEmpty) pkg, ...classPath].join('.')}'),
        location: moduleOf(p),
        path: path,
        line: m.line,
        col: m.col,
      ));
    }
    // 方法排在类前面(引用指的就是它)
    out.sort((a, b) => (a.kind == SearchHitKind.classType ? 1 : 0) - (b.kind == SearchHitKind.classType ? 1 : 0));
    return out;
  }

  return SearchSources(files: files, classes: classes, symbols: symbols, actions: actionHits, reference: reference);
}
