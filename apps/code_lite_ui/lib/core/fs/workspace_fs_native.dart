import 'dart:convert';
import 'dart:io';
import 'dart:isolate';

import 'rust_search.dart';

/// 工作区文件树与全局搜索/替换的纯 Dart 实现(原 Rust `code-lite-fs` 的 tree / search)。
///
/// 返回的 JSON 形状与原来的 FFI 导出一致,UI 无需改动。扫描、搜索、替换都放进
/// 后台 isolate:大仓库里遍历文件要几百毫秒,原来同步 FFI 会卡住界面。

/// 文件树里不展示的目录 / 文件(与原 Rust `WorkspaceTree::is_ignored` 一致)。
const Set<String> _treeIgnored = {'.git', 'target', 'node_modules', '.DS_Store', '.codelite', '.idea', '.vscode'};

/// 搜索时跳过的目录(以 `.` 开头的一律跳过,另加这些构建产物目录)。
const Set<String> _searchIgnored = {'target', 'node_modules', 'build', '.dart_tool'};

const int _defaultMaxResults = 500;

/// 扫描工作区目录树。返回根节点:`{path, name, is_dir, size_bytes, modified_ms, children, loaded}`。
/// 只扫 [maxDepth] 层;更深的目录 `loaded: false`、`children: null`,展开时用 [listDirectory] 再取。
/// 只含一个子目录的链(Java 的 com/acme/app)会一直往下扫,文件树才能把包名压成一行。
Future<Map<String, dynamic>> scanTree(String root, {int maxDepth = 4}) =>
    Isolate.run(() => _scanDir(Directory(root), 0, maxDepth));

/// 展开一个还没扫描的目录:返回它的节点,下面再带一层(子目录能直接显示有没有内容)。
Future<Map<String, dynamic>> listDirectory(String path, {int depth = 2}) =>
    Isolate.run(() => _scanDir(Directory(path), 0, depth));

/// 全局搜索。返回 `{"status":"ok","query","total","matches":[{file_path,line_number,col_start,col_end,line_snippet}]}`,
/// 正则写错时返回 `{"status":"error","error":...}`。
Future<Map<String, dynamic>> searchWorkspace(String root, String query, [Map<String, dynamic>? options]) async {
  // 先交给 Rust(并行、快 2~3 倍);没有 Rust 库、或正则 Rust 不支持(环视、反向引用)时用下面这份 Dart 的
  // 只搜一个文件(单独打开的文件):Rust 那份会遍历整个目录,直接用 Dart 的
  if (options?['only_file'] == null) {
    final rust = await rustSearch({'op': 'search', 'root': root, 'query': query, 'options': options ?? const {}});
    if (rust != null && rust['status'] != 'unsupported') return rust;
  }
  return searchWorkspaceInDart(root, query, options);
}

/// Dart 实现的全局搜索:没有 Rust 库、或正则 Rust 不支持时用;测试里拿它和 Rust 的结果对照。
Future<Map<String, dynamic>> searchWorkspaceInDart(String root, String query, [Map<String, dynamic>? options]) =>
    Isolate.run(() {
      try {
        final matches = _search(root, query, _SearchOptions.fromJson(options));
        return {'status': 'ok', 'query': query, 'total': matches.length, 'matches': matches};
      } on FormatException catch (e) {
        return {'status': 'error', 'error': 'Search failed: ${e.message}'};
      } on FileSystemException catch (e) {
        return {'status': 'error', 'error': 'Search failed: ${e.message}'};
      }
    });

/// 全局替换。返回 `{"status":"ok","replaced_count":n}`。
/// [replacement] 支持 `$1` / `${1}` / `${name}` 捕获组引用和 `$$` 转义(与原 Rust regex 一致)。
Future<Map<String, dynamic>> replaceWorkspace(
  String root,
  String query,
  String replacement, [
  Map<String, dynamic>? options,
]) async {
  if (options?['only_file'] == null) {
    final rust = await rustSearch({'op': 'replace', 'root': root, 'query': query, 'replacement': replacement, 'options': options ?? const {}});
    if (rust != null && rust['status'] != 'unsupported') return rust;
  }
  return replaceWorkspaceInDart(root, query, replacement, options);
}

/// Dart 实现的全局替换(同上)。
Future<Map<String, dynamic>> replaceWorkspaceInDart(String root, String query, String replacement, [Map<String, dynamic>? options]) =>
    Isolate.run(() {
      try {
        return {'status': 'ok', 'replaced_count': _replaceAll(root, query, replacement, _SearchOptions.fromJson(options))};
      } on FormatException catch (e) {
        return {'status': 'error', 'error': 'Replace failed: ${e.message}'};
      } on FileSystemException catch (e) {
        return {'status': 'error', 'error': 'Replace failed: ${e.message}'};
      }
    });

// ---------------------------------------------------------------------------
// 打开 / 保存(原 Rust codelite_file_open / file_save)
// ---------------------------------------------------------------------------

/// 读取工作区内的文本文件。返回 `{"status":"ok","path","content","line_count"}`;
/// 二进制文件返回 `{"status":"error","error":...,"binary":true}`,不当文本打开。
Future<Map<String, dynamic>> readTextFile(String root, String relPath) async {
  final file = File(_join(root, relPath));
  List<int> bytes;
  try {
    bytes = await file.readAsBytes();
  } on FileSystemException catch (e) {
    return {'status': 'error', 'error': 'Open failed: ${e.osError?.message ?? e.message}'};
  }
  final head = bytes.length < 8000 ? bytes.length : 8000;
  for (var i = 0; i < head; i++) {
    if (bytes[i] == 0) return {'status': 'error', 'error': '二进制文件,无法以文本打开', 'binary': true};
  }
  final content = utf8.decode(bytes, allowMalformed: true);
  return {
    'status': 'ok',
    'path': relPath,
    'content': content,
    'line_count': content.isEmpty ? 1 : '\n'.allMatches(content).length + 1,
  };
}

/// 保存:先写同目录临时文件再 rename,写到一半崩溃也不会留下截断的源文件。
Future<Map<String, dynamic>> writeTextFile(String root, String relPath, String content) async {
  final target = File(_join(root, relPath));
  final tmp = File('${target.path}.codelite-save-${DateTime.now().microsecondsSinceEpoch}');
  try {
    await target.parent.create(recursive: true);
    await tmp.writeAsString(content, flush: true);
    // 保留原文件的权限位(比如可执行脚本),rename 会用临时文件的权限。
    if (await target.exists()) {
      final mode = (await target.stat()).mode & 0x1ff;
      await Process.run('chmod', [mode.toRadixString(8), tmp.path]);
    }
    await tmp.rename(target.path);
    return {'status': 'ok', 'path': relPath};
  } on FileSystemException catch (e) {
    try {
      if (await tmp.exists()) await tmp.delete();
    } catch (_) {}
    return {'status': 'error', 'error': 'Save failed: ${e.osError?.message ?? e.message}'};
  }
}

String _join(String root, String relPath) =>
    relPath.startsWith('/') ? relPath : '$root${Platform.pathSeparator}$relPath';

// ---------------------------------------------------------------------------
// 文件树
// ---------------------------------------------------------------------------

String _basename(String path) {
  final trimmed = path.endsWith(Platform.pathSeparator) && path.length > 1 ? path.substring(0, path.length - 1) : path;
  final i = trimmed.lastIndexOf(Platform.pathSeparator);
  return i < 0 ? trimmed : trimmed.substring(i + 1);
}

Map<String, dynamic> _scanDir(Directory dir, int depth, int maxDepth) {
  final children = <Map<String, dynamic>>[];
  final loaded = depth < maxDepth;
  if (loaded) {
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      entries = const [];
    }
    final kept = [
      for (final e in entries)
        if (!_treeIgnored.contains(_basename(e.path))) e,
    ];
    // 目录在前,同类按名字排序(与原实现一致,按字节序而非本地化排序)。
    kept.sort((a, b) {
      final ad = a is Directory, bd = b is Directory;
      if (ad != bd) return ad ? -1 : 1;
      return _basename(a.path).compareTo(_basename(b.path));
    });
    // 只有一个子目录、没有文件:沿着这条链继续往下扫(不占层数)。
    final chain = kept.length == 1 && kept.first is Directory;
    for (final e in kept) {
      if (e is Directory) {
        children.add(_scanDir(e, depth + 1, chain ? maxDepth + 1 : maxDepth));
      } else if (e is File) {
        FileStat stat;
        try {
          stat = e.statSync();
        } on FileSystemException {
          continue;
        }
        children.add({
          'path': e.path,
          'name': _basename(e.path),
          'is_dir': false,
          'size_bytes': stat.size,
          'modified_ms': stat.modified.millisecondsSinceEpoch,
          'children': null,
        });
      }
      // 符号链接(Link)不展开,也不展示:原实现按 metadata 判断时同样不会跟随它们进入循环。
    }
  }
  return {
    'path': dir.path,
    'name': _basename(dir.path),
    'is_dir': true,
    'size_bytes': 0,
    'modified_ms': 0,
    'children': loaded ? children : null,
    'loaded': loaded,
  };
}

// ---------------------------------------------------------------------------
// 搜索 / 替换
// ---------------------------------------------------------------------------

class _SearchOptions {
  const _SearchOptions({
    this.isRegex = false,
    this.caseSensitive = false,
    this.wholeWord = false,
    this.maxResults = _defaultMaxResults,
    this.fileExtension,
    this.onlyFile,
  });

  /// 只搜根目录下的这一个文件(单独打开的文件),不遍历目录。
  final String? onlyFile;

  final bool isRegex;
  final bool caseSensitive;
  final bool wholeWord;
  final int maxResults;
  final String? fileExtension;

  factory _SearchOptions.fromJson(Map<String, dynamic>? j) {
    if (j == null) return const _SearchOptions();
    return _SearchOptions(
      isRegex: j['is_regex'] == true,
      caseSensitive: j['case_sensitive'] == true,
      wholeWord: j['whole_word'] == true,
      maxResults: (j['max_results'] as num?)?.toInt() ?? _defaultMaxResults,
      fileExtension: j['file_extension'] as String?,
      onlyFile: j['only_file'] as String?,
    );
  }

  RegExp pattern(String query) {
    var p = isRegex ? query : RegExp.escape(query);
    if (wholeWord) p = '\\b$p\\b';
    return RegExp(p, caseSensitive: caseSensitive, unicode: true);
  }
}

List<String> _collectFiles(String root, _SearchOptions options) {
  if (options.onlyFile case final only?) {
    final path = '$root${Platform.pathSeparator}$only';
    return File(path).existsSync() ? [path] : const [];
  }
  final out = <String>[];
  void walk(Directory dir) {
    List<FileSystemEntity> entries;
    try {
      entries = dir.listSync(followLinks: false);
    } on FileSystemException {
      return;
    }
    for (final e in entries) {
      final name = _basename(e.path);
      if (name.startsWith('.') || _searchIgnored.contains(name)) continue;
      if (e is Directory) {
        walk(e);
      } else if (e is File) {
        final ext = options.fileExtension;
        if (ext == null || name.endsWith('.$ext')) out.add(e.path);
      }
    }
  }

  walk(Directory(root));
  return out;
}

/// 读成文本;前 512 字节含 NUL 视为二进制,跳过(与原实现一致)。
String? _readText(String path) {
  List<int> bytes;
  try {
    bytes = File(path).readAsBytesSync();
  } on FileSystemException {
    return null;
  }
  final head = bytes.length < 512 ? bytes.length : 512;
  for (var i = 0; i < head; i++) {
    if (bytes[i] == 0) return null;
  }
  return utf8.decode(bytes, allowMalformed: true);
}

String _relative(String root, String path) {
  final prefix = root.endsWith(Platform.pathSeparator) ? root : '$root${Platform.pathSeparator}';
  return path.startsWith(prefix) ? path.substring(prefix.length) : path;
}

List<Map<String, dynamic>> _search(String root, String query, _SearchOptions options) {
  if (query.isEmpty) return const [];
  final re = options.pattern(query);
  final results = <Map<String, dynamic>>[];
  for (final path in _collectFiles(root, options)) {
    if (results.length >= options.maxResults) break;
    final text = _readText(path);
    if (text == null) continue;
    final rel = _relative(root, path);
    final lines = const LineSplitter().convert(text);
    for (var i = 0; i < lines.length && results.length < options.maxResults; i++) {
      final line = lines[i];
      for (final m in re.allMatches(line)) {
        if (results.length >= options.maxResults) break;
        results.add({
          'file_path': rel,
          'line_number': i + 1,
          'col_start': m.start,
          'col_end': m.end,
          'line_snippet': line.trim(),
        });
      }
    }
  }
  return results;
}

int _replaceAll(String root, String query, String replacement, _SearchOptions options) {
  final matches = _search(root, query, options);
  if (matches.isEmpty) return 0;
  final re = options.pattern(query);
  final byFile = <String, int>{};
  for (final m in matches) {
    byFile.update(m['file_path'] as String, (n) => n + 1, ifAbsent: () => 1);
  }
  var replaced = 0;
  for (final entry in byFile.entries) {
    final file = File('$root${Platform.pathSeparator}${entry.key}');
    final content = file.readAsStringSync();
    final updated = content.replaceAllMapped(re, (m) => expandReplacement(replacement, m));
    if (updated != content) {
      file.writeAsStringSync(updated);
      replaced += entry.value;
    }
  }
  return replaced;
}

/// 按 Rust regex 的替换语法展开:`$$` → `$`,`$1` / `${1}` / `$name` / `${name}` → 捕获组(不存在则为空)。
String expandReplacement(String template, Match m) {
  final out = StringBuffer();
  var i = 0;
  while (i < template.length) {
    final c = template[i];
    if (c != r'$' || i + 1 >= template.length) {
      out.write(c);
      i++;
      continue;
    }
    final next = template[i + 1];
    if (next == r'$') {
      out.write(r'$');
      i += 2;
      continue;
    }
    String? ref;
    var end = i + 1;
    if (next == '{') {
      final close = template.indexOf('}', i + 2);
      if (close < 0) {
        out.write(c);
        i++;
        continue;
      }
      ref = template.substring(i + 2, close);
      end = close + 1;
    } else {
      final word = RegExp(r'[A-Za-z0-9_]+').matchAsPrefix(template, i + 1);
      if (word == null) {
        out.write(c);
        i++;
        continue;
      }
      ref = word.group(0);
      end = word.end;
    }
    out.write(_group(m, ref!) ?? '');
    i = end;
  }
  return out.toString();
}

String? _group(Match m, String ref) {
  final index = int.tryParse(ref);
  if (index != null) return index <= m.groupCount ? m.group(index) : null;
  if (m is RegExpMatch && m.groupNames.contains(ref)) return m.namedGroup(ref);
  return null;
}
