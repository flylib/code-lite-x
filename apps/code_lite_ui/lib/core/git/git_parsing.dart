// GitService 的纯函数部分:git 命令行输出 → 与原 Rust FFI 一致的 JSON 结构(Map / List)。
// 这里不碰进程与文件系统,单测可以直接喂字符串。

/// 空树对象(SHA-1 仓库),用于根提交与「无父提交」之间的 diff。
const String emptyTree = '4b825dc642cb6eb9a060e54bf8d69288fbee4904';

/// 字段分隔用 \x1f、记录分隔用 \x1e:提交标题里出现 tab / 换行 / 任意 unicode 都不会串行。
const String logFormat = '--format=%x1e%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%D%x1f%s';

const int defaultLogLimit = 500;

// ---------------------------------------------------------------------------
// 字符串小工具:对齐 Rust 标准库的语义,保证解析结果与旧实现逐字一致
// ---------------------------------------------------------------------------

/// 等价于 Rust `str::lines()`:按 \n 切分、去掉行尾 \r、末尾换行不产生空行。
List<String> rustLines(String s) {
  if (s.isEmpty) return const [];
  final parts = s.split('\n');
  if (parts.last.isEmpty) parts.removeLast();
  return [for (final p in parts) p.endsWith('\r') ? p.substring(0, p.length - 1) : p];
}

/// 等价于 Rust `splitn(n, sep)`:最多切成 n 段,最后一段保留剩余全部内容。
List<String> splitN(String s, String sep, int n) {
  final out = <String>[];
  var start = 0;
  while (out.length < n - 1) {
    final i = s.indexOf(sep, start);
    if (i < 0) break;
    out.add(s.substring(start, i));
    start = i + sep.length;
  }
  out.add(s.substring(start));
  return out;
}

/// 等价于 Rust `split_whitespace()`。
List<String> splitWhitespace(String s) =>
    s.split(RegExp(r'\s+')).where((t) => t.isNotEmpty).toList();

/// 去掉末尾所有 \n(Rust `trim_end_matches('\n')`)。
String trimTrailingNewlines(String s) {
  var end = s.length;
  while (end > 0 && s.codeUnitAt(end - 1) == 0x0a) {
    end--;
  }
  return s.substring(0, end);
}

/// 去掉开头所有 `/`:pathspec / `<rev>:<path>` 都以仓库根为基准。
String trimLeadingSlashes(String s) {
  var i = 0;
  while (i < s.length && s.codeUnitAt(i) == 0x2f) {
    i++;
  }
  return s.substring(i);
}

String? nonEmpty(String s) => s.isEmpty ? null : s;

final RegExp _hexPrefix = RegExp(r'^[0-9a-fA-F]{4,40}$');

/// 搜索框里的文本像不像一个(可能缩写的)提交哈希。
bool isHexPrefix(String s) => _hexPrefix.hasMatch(s);

/// 转义为 POSIX ERE 字面量。
String ereEscape(String s) {
  const special = r'\.^$|?*+()[]{}';
  final out = StringBuffer();
  for (final ch in s.runes) {
    final c = String.fromCharCode(ch);
    if (special.contains(c)) out.write(r'\');
    out.write(c);
  }
  return out.toString();
}

/// 单引号包裹,供 GIT_SEQUENCE_EDITOR / exec 行这类经 sh 解释的命令使用。
String shQuote(String s) => "'${s.replaceAll("'", r"'\''")}'";

/// 统一使用以仓库根为基准、关闭通配的 pathspec:路径里的 `*` / `[` 不会被当成 glob。
String topPathspec(String p) => ':(top,literal)${trimLeadingSlashes(p)}';

/// 输出给 UI 解析的 unified diff:屏蔽 color / external diff / 前缀配置对格式的影响。
List<String> diffTextArgs() => ['diff', '--no-color', '--no-ext-diff', '--src-prefix=a/', '--dst-prefix=b/'];

String rangeSpec(String? base) => base == null ? 'HEAD' : '$base..HEAD';

/// 失败时的错误消息以 stderr 为主;冲突提示(CONFLICT ...)git 写在 stdout,一并带上便于用户定位。
String commandFailureDetail(String stdout, String stderr) {
  var msg = stderr.trim();
  final conflicts = rustLines(stdout).where((l) => l.startsWith('CONFLICT')).toList();
  if (conflicts.isNotEmpty) {
    if (msg.isNotEmpty) msg += '\n';
    msg += conflicts.join('\n');
  }
  if (msg.isEmpty) msg = stdout.trim();
  return msg;
}

// ---------------------------------------------------------------------------
// 工作区状态 / 编辑器 gutter
// ---------------------------------------------------------------------------

/// 解析 `git status --porcelain=v1 -b`。返回 (分支名, changes);没有 `##` 行时分支为空串。
(String, List<Map<String, dynamic>>) parseStatusPorcelain(String raw) {
  var branch = '';
  final changes = <Map<String, dynamic>>[];
  Map<String, dynamic> change(String path, String status, bool staged) =>
      {'path': path, 'status': status, 'is_staged': staged};

  for (final line in rustLines(raw)) {
    if (line.startsWith('##')) {
      var part = line;
      while (part.startsWith('##')) {
        part = part.substring(2);
      }
      part = part.trim();
      final dots = part.indexOf('...');
      branch = dots < 0 ? part : part.substring(0, dots);
      continue;
    }
    if (line.length < 4) continue;

    final indexCode = line[0];
    final workCode = line[1];
    var filePath = line.substring(3).trim();
    // 重命名显示为 "old -> new",取新路径
    final arrow = filePath.indexOf(' -> ');
    if (arrow >= 0) filePath = filePath.substring(arrow + 4);

    if (indexCode == '?' && workCode == '?') {
      changes.add(change(filePath, 'untracked', false));
      continue;
    }
    // 暂存区与工作区的改动分别成条,UI 按 is_staged 分栏
    if (indexCode != ' ' && indexCode != '?') {
      final kind = switch (indexCode) {
        'A' => 'added',
        'D' => 'deleted',
        'R' => 'renamed',
        _ => 'modified',
      };
      changes.add(change(filePath, kind, true));
    }
    if (workCode != ' ' && workCode != '?') {
      changes.add(change(filePath, workCode == 'D' ? 'deleted' : 'modified', false));
    }
  }
  return (branch, changes);
}

/// 解析 `@@ -a,b +c,d @@` → (oldStart, oldCount, newStart, newCount);省略的 count 视为 1。
(int, int, int, int)? parseHunkHeader(String line) {
  final parts = line.split('@@');
  if (parts.length < 3) return null;
  final tokens = splitWhitespace(parts[1].trim());
  if (tokens.length < 2) return null;

  (int, int)? token(String t, String prefix) {
    if (!t.startsWith(prefix)) return null;
    final clean = t.substring(1);
    final comma = clean.indexOf(',');
    if (comma >= 0) {
      final start = _parseUsize(clean.substring(0, comma));
      final count = _parseUsize(clean.substring(comma + 1));
      if (start == null || count == null) return null;
      return (start, count);
    }
    final start = _parseUsize(clean);
    return start == null ? null : (start, 1);
  }

  final old = token(tokens[0], '-');
  final neu = token(tokens[1], '+');
  if (old == null || neu == null) return null;
  return (old.$1, old.$2, neu.$1, neu.$2);
}

int? _parseUsize(String s) {
  if (!RegExp(r'^\+?[0-9]+$').hasMatch(s)) return null;
  return int.tryParse(s.startsWith('+') ? s.substring(1) : s);
}

/// `git diff -U0` → 编辑器 gutter 的逐行标记。`line` 为 0 基行号;
/// 纯删除挂在删除点所在行,修改块只在首行带 original_content(整块旧内容)。
List<Map<String, dynamic>> parseDiffHunks(String rawDiff) {
  final results = <Map<String, dynamic>>[];
  (int, int, int, int)? current;
  final oldLines = <String>[];
  final newLines = <String>[];

  void flush((int, int, int, int) hunk) {
    final (_, oldCount, newStart, newCount) = hunk;
    final start = newStart > 0 ? newStart - 1 : 0;
    if (oldCount == 0 && newCount > 0) {
      for (var i = 0; i < newLines.length; i++) {
        results.add({'line': start + i, 'kind': 'added', 'new_content': newLines[i]});
      }
    } else if (oldCount > 0 && newCount == 0) {
      results.add({'line': start, 'kind': 'deleted', 'original_content': oldLines.join('\n')});
    } else {
      final oldStr = oldLines.isEmpty ? null : oldLines.join('\n');
      final n = newLines.length > newCount ? newLines.length : newCount;
      for (var i = 0; i < n; i++) {
        results.add({
          'line': start + i,
          'kind': 'modified',
          if (i == 0 && oldStr != null) 'original_content': oldStr,
          if (i < newLines.length) 'new_content': newLines[i],
        });
      }
    }
  }

  for (final line in rustLines(rawDiff)) {
    if (line.startsWith('@@')) {
      final prev = current;
      if (prev != null) {
        flush(prev);
        oldLines.clear();
        newLines.clear();
      }
      current = parseHunkHeader(line);
    } else if (current != null) {
      if (line.startsWith('-')) {
        oldLines.add(line.substring(1));
      } else if (line.startsWith('+')) {
        newLines.add(line.substring(1));
      }
    }
  }
  final last = current;
  if (last != null) flush(last);
  return results;
}

// ---------------------------------------------------------------------------
// 历史 / 引用
// ---------------------------------------------------------------------------

Map<String, dynamic> gitRef(String name, String kind) => {'name': name, 'kind': kind};

/// 解析 `--decorate=full` 下的 `%D`,例如 `HEAD -> refs/heads/main, tag: refs/tags/v1, refs/remotes/origin/main`。
/// kind ∈ head / local / remote / tag;其他命名空间(refs/stash、refs/notes 等)不在图谱上展示。
List<Map<String, dynamic>> parseRefs(String decor) {
  final refs = <Map<String, dynamic>>[];
  for (final raw in decor.split(', ')) {
    var item = raw.trim();
    if (item.isEmpty) continue;
    if (item.startsWith('HEAD -> ')) {
      refs.add(gitRef('HEAD', 'head'));
      item = item.substring('HEAD -> '.length);
    }
    if (item.startsWith('tag: ')) item = item.substring('tag: '.length);
    if (item == 'HEAD') {
      refs.add(gitRef('HEAD', 'head'));
    } else if (item.startsWith('refs/heads/')) {
      refs.add(gitRef(item.substring('refs/heads/'.length), 'local'));
    } else if (item.startsWith('refs/remotes/')) {
      final n = item.substring('refs/remotes/'.length);
      // origin/HEAD 只是指向默认分支的符号引用
      if (!n.endsWith('/HEAD')) refs.add(gitRef(n, 'remote'));
    } else if (item.startsWith('refs/tags/')) {
      refs.add(gitRef(item.substring('refs/tags/'.length), 'tag'));
    }
  }
  return refs;
}

/// 解析 [logFormat] 输出的记录;字段不全的记录(被截断 / 损坏)直接丢弃。
List<Map<String, dynamic>> parseLogRecords(String raw) {
  final commits = <Map<String, dynamic>>[];
  for (final r in raw.split('\x1e')) {
    if (r.trim().isEmpty) continue;
    final f = splitN(trimTrailingNewlines(r), '\x1f', 7);
    if (f.length < 7) continue;
    commits.add({
      'hash': f[0].trim(),
      'parents': splitWhitespace(f[1]),
      'author': f[2],
      'email': f[3],
      'time': int.tryParse(f[4].trim()) ?? 0,
      'subject': f[6],
      'refs': parseRefs(f[5]),
    });
  }
  return commits;
}

/// 解析 `--name-status -z`:`M\0path\0`,重命名/复制为 `R100\0old\0new\0`(相似度分数去掉)。
List<Map<String, dynamic>> parseNameStatusZ(String raw) {
  final tokens = raw.split('\x00').where((t) => t.isNotEmpty).toList();
  final changes = <Map<String, dynamic>>[];
  var i = 0;
  while (i < tokens.length) {
    final status = tokens[i++].trim();
    final letter = status.isEmpty ? 'M' : String.fromCharCode(status.runes.first);
    if (letter == 'R' || letter == 'C') {
      if (i + 1 >= tokens.length) break;
      final old = tokens[i++];
      final neu = tokens[i++];
      changes.add({'path': neu, 'old_path': old, 'status': letter});
    } else {
      if (i >= tokens.length) break;
      changes.add({'path': tokens[i++], 'old_path': null, 'status': letter});
    }
  }
  return changes;
}

// ---------------------------------------------------------------------------
// 最近用过的分支(标题栏分支菜单的 Recent)
// ---------------------------------------------------------------------------

/// 从 `git reflog --format=%gs` 的主题行里挑出最近切换过的分支:最新的在前,
/// 只保留 [existing] 里还在的本地分支,去掉 [current] 和重复,最多 [limit] 个。
///
/// 切换记录形如 `checkout: moving from main to feat/x`:目标 `feat/x` 比来源 `main` 更近。
List<String> recentBranches(Iterable<String> reflogSubjects, Set<String> existing, String? current, int limit) {
  final out = <String>[];
  void add(String name) {
    if (name == current || !existing.contains(name) || out.contains(name)) return;
    out.add(name);
  }

  final moving = RegExp(r'^checkout: moving from (.+) to (.+)$');
  for (final subject in reflogSubjects) {
    final m = moving.firstMatch(subject.trim());
    if (m == null) continue;
    add(m.group(2)!);
    add(m.group(1)!);
    if (out.length >= limit) break;
  }
  return out.take(limit).toList();
}
