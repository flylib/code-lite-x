// 纯 Dart 的 Git 引擎:替代原 Rust `code-lite-fs::git` / `git_history` 与 FFI `codelite_git_*` 导出。
//
// 全部基于系统 `git` CLI(`git -C <root> ...`)。返回值刻意保持与旧 FFI 的 JSON 逐字段一致,
// UI 侧(GitLogStore / 提交面板 / 编辑器 gutter)无需改动解析逻辑:
//   - [call]:`{"status":"ok", ...结果字段平铺}` / `{"status":"error","error":"..."}`;
//   - [status] 成功时直接是 `{"branch", "changes"}`(无 status 字段,与旧 codelite_git_status 一致)。
// 改写历史统一走「脚本化 rebase」:预先生成 todo,通过 GIT_SEQUENCE_EDITOR 覆盖 git 生成的 todo,
// 失败一律 `--abort`,绝不把仓库留在半途状态。

import 'dart:convert';
import 'dart:io';

import 'git_parsing.dart';

/// Git 操作失败。[message] 即面向用户的错误文本(与旧 Rust `GitError` 的 Display 一致)。
class GitException implements Exception {
  GitException(this.message);

  /// 对应 Rust `GitError::CommandFailed` 的展示格式。
  GitException.commandFailed(int code, String detail) : message = 'Git command failed (exit code $code): $detail';

  final String message;

  @override
  String toString() => message;
}

/// 参数反序列化失败(对应 serde 报错),由 [GitService.call] 包成 "参数无效: ..."。
class _ParamError implements Exception {
  _ParamError(this.message);
  final String message;
}

/// 一次 git 进程的原始结果。stdout 保留字节:`cat-file blob` 需要判断二进制。
class _GitOutput {
  _GitOutput(this.exitCode, this.stdoutBytes, this.stderr) : stdout = utf8.decode(stdoutBytes, allowMalformed: true);

  final int exitCode;
  final List<int> stdoutBytes;
  final String stdout;
  final String stderr;

  bool get success => exitCode == 0;

  /// 被信号杀死时 Dart 给负数,Rust 的 `code()` 为 None → -1,这里对齐。
  int get code => exitCode < 0 ? -1 : exitCode;

  String get detail => commandFailureDetail(stdout, stderr);

  GitException get failure => GitException.commandFailed(code, detail);
}

class GitService {
  GitService(this.root);

  /// 工作区根目录(也可以是仓库内的子目录,git 会自己向上找)。
  final String root;

  // =========================================================================
  // 对外 API:工作区状态(对应旧 codelite_git_status / diff / stage / ...)
  // =========================================================================

  /// 目录是否在某个 git 工作树内。
  Future<bool> isRepo() async {
    try {
      return (await _raw(['rev-parse', '--is-inside-work-tree'])).success;
    } on GitException {
      return false;
    }
  }

  /// 当前分支名(游离 HEAD 时为 "HEAD");命令失败返回 null。
  Future<String?> currentBranch() async {
    try {
      return (await _run(['rev-parse', '--abbrev-ref', 'HEAD'])).trim();
    } on GitException {
      return null;
    }
  }

  /// `{"branch": "...", "changes": [{"path","status","is_staged"}]}`;
  /// status ∈ modified / added / deleted / untracked / renamed。
  Future<Map<String, dynamic>> status() => _guard(() async {
        final raw = await _run(['status', '--porcelain=v1', '-b']);
        var (branch, changes) = parseStatusPorcelain(raw);
        if (branch.isEmpty) branch = await currentBranch() ?? 'HEAD';
        return {'branch': branch, 'changes': changes};
      });

  /// `{"status":"ok","diff": "..."}`;[staged] 为 true 时对比暂存区。空路径表示整个仓库。
  Future<Map<String, dynamic>> diff({String? path, bool staged = false}) => _guard(() async {
        final args = ['diff', if (staged) '--cached'];
        if (path != null && path.trim().isNotEmpty) args.addAll(['--', path]);
        return {'status': 'ok', 'diff': await _run(args)};
      });

  Future<Map<String, dynamic>> stage(String path) => _guard(() async {
        await _run(['add', path]);
        return {'status': 'ok'};
      });

  Future<Map<String, dynamic>> unstage(String path) => _guard(() async {
        await _run(['restore', '--staged', path]);
        return {'status': 'ok'};
      });

  /// `{"status":"ok","commit_hash": "<短哈希>"}`。
  Future<Map<String, dynamic>> commit(String message) => _guard(() async {
        await _run(['commit', '-m', message]);
        final hash = await _run(['rev-parse', '--short', 'HEAD']);
        return {'status': 'ok', 'commit_hash': hash.trim()};
      });

  /// 编辑器 gutter:`{"status":"ok","hunks":[{"line","kind","original_content"?,"new_content"?}]}`。
  /// gutter 只是装饰,git 出错时返回空列表而不是报错。
  Future<Map<String, dynamic>> fileDiffHunks(String path) => _guard(() async {
        return {'status': 'ok', 'hunks': await _diffHunks(path)};
      });

  /// 丢弃文件在工作区的修改(先 checkout HEAD,不行再 restore,兼容未提交过的新仓库)。
  Future<Map<String, dynamic>> revertFile(String path) => _guard(() async {
        final out = await _raw(['checkout', 'HEAD', '--', path]);
        if (!out.success) await _run(['restore', path]);
        return {'status': 'ok'};
      });

  // =========================================================================
  // 对外 API:Git Log 工具窗口(对应旧 codelite_git_call)
  // =========================================================================

  /// 按 [method](如 "git.log"、"git.cherry_pick")分派。永不抛异常,错误编码进返回的 Map。
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) async {
    final m = method.trim();
    if (m.isEmpty) return _error('method is required');
    try {
      final result = await _dispatch(m, _Params(params));
      return {...result, 'status': 'ok'};
    } on _ParamError catch (e) {
      return _error('参数无效: ${e.message}');
    } on GitException catch (e) {
      return _error(e.message);
    } catch (e) {
      return _error('git call panicked: $e');
    }
  }

  Future<Map<String, dynamic>> _dispatch(String method, _Params p) async {
    switch (method) {
      case 'git.branches':
        return _branches();
      case 'git.log':
        return _historyLog(_LogQuery.parse(p));
      case 'git.authors':
        return {'authors': await _historyAuthors()};
      case 'git.commit_details':
        return _commitDetails(p.str('hash'));
      case 'git.commit_file_diff':
        final (hash, path, oldPath) = (p.str('hash'), p.str('path'), p.optStr('old_path'));
        return {'diff': await _commitFileDiff(hash, path, oldPath)};
      case 'git.compare_local':
        return {'files': await _compareWithLocal(p.str('hash'))};
      case 'git.compare_local_diff':
        final (hash, path) = (p.str('hash'), p.str('path'));
        return {'diff': await _compareWithLocalDiff(hash, path)};
      case 'git.tree_at':
        return {'paths': await _treeAt(p.str('hash'))};
      case 'git.file_at':
        final (hash, path) = (p.str('hash'), p.str('path'));
        return _fileAt(hash, path);
      case 'git.blame':
        return _blame(p.str('path'), rev: p.optStr('rev'), contents: p.optStr('contents'));
      case 'git.create_patch':
        return {'patch': await _createPatch(p.str('hash'))};
      case 'git.cherry_pick':
        await _cherryPick(p.str('hash'));
        return {};
      case 'git.checkout_revision':
        await _checkoutRevision(p.str('hash'));
        return {};
      case 'git.revert':
        await _revertCommit(p.str('hash'));
        return {};
      case 'git.reset':
        final (hash, mode) = (p.str('hash'), p.str('mode'));
        // 先校验模式再解析提交,与旧实现的报错优先级一致
        final flag = switch (mode) {
          'soft' => '--soft',
          'mixed' => '--mixed',
          'hard' => '--hard',
          _ => throw GitException('不支持的 reset 模式: $mode'),
        };
        await _resetTo(hash, flag);
        return {};
      case 'git.undo_commit':
        await _undoCommit();
        return {};
      case 'git.new_branch':
        final (name, hash, checkout) = (p.str('name'), p.str('hash'), p.optBool('checkout'));
        await _newBranch(name, hash, checkout ?? false);
        return {};
      case 'git.new_tag':
        final (name, hash, message) = (p.str('name'), p.str('hash'), p.optStr('message'));
        await _newTag(name, hash, message);
        return {};
      case 'git.reword':
        final (hash, message) = (p.str('hash'), p.str('message'));
        await _reword(hash, message);
        return {};
      case 'git.fixup':
        await _foldStagedInto(p.str('hash'), null);
        return {};
      case 'git.squash_into':
        final (hash, message) = (p.str('hash'), p.str('message'));
        _requireMessage(message);
        await _foldStagedInto(hash, message);
        return {};
      case 'git.drop':
        await _dropCommit(p.str('hash'));
        return {};
      case 'git.rebase_plan':
        return _rebasePlan(p.str('hash'));
      case 'git.rebase_interactive':
        final base = p.optStr('base');
        final entries = p.entries('entries');
        await _rebaseInteractive(base, entries);
        return {};
      case 'git.push_up_to':
        return _pushUpTo(p.str('hash'));
      case 'git.is_pushed':
        return {'pushed': await _isPushed(p.str('hash'))};
      default:
        throw GitException('未知的 git 方法: $method');
    }
  }

  // =========================================================================
  // 读操作
  // =========================================================================

  /// 分支 / 远程分支 / 标签总览。
  Future<Map<String, dynamic>> _branches() async {
    final head = await _headHash();
    final current = await _currentBranchName();
    final raw = await _run([
      'for-each-ref',
      '--format=%(refname)%1f%(objectname)%1f%(upstream:short)%1f%(HEAD)%1f%(*objectname)%1f%(symref)',
      'refs/heads',
      'refs/remotes',
      'refs/tags',
    ]);
    final local = <Map<String, dynamic>>[];
    final remote = <Map<String, dynamic>>[];
    final tags = <Map<String, dynamic>>[];
    for (final line in rustLines(raw)) {
      final f = line.split('\x1f');
      if (f.length < 6) continue;
      final (refname, hash, upstream, isHead, peeled, symref) = (f[0], f[1], f[2], f[3], f[4], f[5]);
      if (refname.startsWith('refs/heads/')) {
        local.add({
          'name': refname.substring('refs/heads/'.length),
          'hash': hash,
          'upstream': nonEmpty(upstream),
          'current': isHead == '*',
        });
      } else if (refname.startsWith('refs/remotes/')) {
        final name = refname.substring('refs/remotes/'.length);
        // origin/HEAD 只是指向默认分支的符号引用,不是独立分支
        if (symref.isNotEmpty || name.endsWith('/HEAD')) continue;
        final slash = name.indexOf('/');
        remote.add({
          'name': name,
          'remote': slash < 0 ? name : name.substring(0, slash),
          'short': slash < 0 ? '' : name.substring(slash + 1),
          'hash': hash,
        });
      } else if (refname.startsWith('refs/tags/')) {
        // 附注标签要剥到提交本身,UI 才能在提交行上定位
        tags.add({'name': refname.substring('refs/tags/'.length), 'hash': peeled.isEmpty ? hash : peeled});
      }
    }
    return {
      'current': current,
      'head': head,
      'detached': current == null,
      'local': local,
      'remote': remote,
      'tags': tags,
    };
  }

  /// 提交历史(按 `--date-order`,子提交一定排在父提交之前,供图谱布局使用)。
  Future<Map<String, dynamic>> _historyLog(_LogQuery q) async {
    final head = await _headHash();
    final limit = (q.limit != null && q.limit! > 0) ? q.limit! : defaultLogLimit;
    final skip = (q.skip != null && q.skip! > 0) ? q.skip! : 0;
    final branch = (q.branch ?? '').trim();
    final text = q.text ?? '';
    final author = q.author ?? '';

    if (branch.startsWith('-')) throw GitException('无效的分支: $branch');
    // 空仓库:HEAD 指向尚未诞生的分支,`git log HEAD` 会报错,这里直接返回空列表
    if (branch.isNotEmpty && head.isEmpty && await _tryResolveCommit(branch) == null) {
      return {'commits': <Map<String, dynamic>>[], 'head': head, 'has_more': false};
    }

    final args = <String>[
      'log',
      '--date-order',
      '--decorate=full',
      '--no-color',
      '--no-show-signature',
      logFormat,
      '-n${limit + 1}', // 多取一条用来判断 has_more
      '--skip=$skip',
    ];
    // 路径过滤时开启父提交改写,图谱才能连成线而不是一堆孤点
    if (q.paths.isNotEmpty) args.add('--parents');
    // 用 ERE 统一处理:--fixed-strings 会连带作用到 --author,导致作者锚定失效
    if (text.isNotEmpty || author.isNotEmpty) args.add('--extended-regexp');
    if (text.isNotEmpty) {
      args.add('--grep=${q.regex ? text : ereEscape(text)}');
      if (!q.matchCase) args.add('--regexp-ignore-case');
    }
    // --author 匹配的是 "Name <email>",锚定首尾实现按姓名精确匹配
    if (author.isNotEmpty) args.add('--author=^${ereEscape(author)} <');
    if (q.since != null && q.since! > 0) args.add('--since=@${q.since}');
    if (branch.isEmpty) {
      // stash 也挂在 refs/ 下,混进历史图谱里只会是噪音
      args.addAll(['--exclude=refs/stash', '--all']);
    } else {
      args.add(branch);
    }
    args.add('--');
    for (final p in q.paths) {
      if (p.isNotEmpty) args.add(topPathspec(p));
    }

    bool nothing(_GitOutput o) => !o.success && parseLogRecords(o.stdout).isEmpty;
    var out = await _raw(args);
    var onlyHead = false;
    if (nothing(out)) {
      // 仓库有损坏对象时尽量把读得到的提交拿出来,逐级放宽:
      // 1. --date-order 要先走完整张图才输出,去掉它改成边走边输出;
      // 2. --all 会先预读所有分支的父提交,仍然一条都拿不到时退到只看 HEAD。
      final streaming = args.where((a) => a != '--date-order').toList();
      out = await _raw(streaming);
      if (nothing(out) && branch.isEmpty) {
        final headOnly = [
          for (final a in streaming)
            if (a != '--exclude=refs/stash') a == '--all' ? 'HEAD' : a,
        ];
        final retry = await _raw(headOnly);
        if (!nothing(retry)) {
          out = retry;
          onlyHead = true;
        }
      }
    }

    var commits = parseLogRecords(out.stdout);
    String? warning;
    if (!out.success) {
      if (commits.isEmpty) throw out.failure;
      // 损坏的对象之后的历史读不到,也就没有"下一页"
      warning = '${onlyHead ? '(其他分支无法读取,仅显示 HEAD)' : ''}${out.detail}';
    }
    final hasMore = warning == null && commits.length > limit;
    if (commits.length > limit) commits = commits.sublist(0, limit);

    // 搜索框里输入的是提交哈希:无论消息是否匹配都要把它带出来,且只放在第一页避免分页重复
    if (isHexPrefix(text)) {
      final full = await _tryResolveCommit(text);
      if (full != null) {
        if (skip == 0) {
          if (!commits.any((c) => c['hash'] == full)) {
            final c = await _logSingle(full);
            if (c != null) commits.insert(0, c);
          }
        } else {
          commits.removeWhere((c) => c['hash'] == full);
        }
      }
    }

    return {
      'commits': commits,
      'head': head,
      'has_more': hasMore,
      if (warning != null) 'warning': warning,
    };
  }

  /// 所有引用上出现过的作者,去重并按不区分大小写排序。
  Future<List<String>> _historyAuthors() async {
    final raw = await _run(['log', '--exclude=refs/stash', '--all', '--no-show-signature', '--format=%an']);
    final authors = rustLines(raw).where((l) => l.isNotEmpty).toSet().toList();
    authors.sort((a, b) {
      final c = a.toLowerCase().compareTo(b.toLowerCase());
      return c != 0 ? c : a.compareTo(b);
    });
    return authors;
  }

  Future<Map<String, dynamic>> _commitDetails(String rev) async {
    final full = await _resolveCommit(rev);
    final raw = await _run([
      'log',
      '-1',
      '--no-walk',
      '--decorate=full',
      '--no-color',
      '--no-show-signature',
      '--format=%H%x1f%P%x1f%an%x1f%ae%x1f%at%x1f%cn%x1f%ct%x1f%D%x1f%B',
      full,
    ]);
    final f = splitN(raw, '\x1f', 9);
    if (f.length < 9) throw GitException('无法解析提交信息: $full');
    final parents = splitWhitespace(f[1]);
    final files = await _commitFiles(full, parents.isEmpty ? null : parents.first);
    final pushed = await _isPushed(full);
    final isHead = await _headHash() == full;
    return {
      'hash': f[0],
      'parents': parents,
      'author': f[2],
      'email': f[3],
      'author_time': int.tryParse(f[4].trim()) ?? 0,
      'committer': f[5],
      'commit_time': int.tryParse(f[6].trim()) ?? 0,
      'message': trimTrailingNewlines(f[8]),
      'refs': parseRefs(f[7]),
      'files': files,
      'pushed': pushed,
      'is_head': isHead,
    };
  }

  /// 单个文件在该提交中的改动(相对第一父提交;根提交相对空树)。
  Future<String> _commitFileDiff(String rev, String path, String? oldPath) async {
    final full = await _resolveCommit(rev);
    _requirePath(path);
    final parents = await _parentsOf(full);
    final args = [
      ...diffTextArgs(),
      '-M',
      parents.isEmpty ? emptyTree : parents.first,
      full,
      '--',
      topPathspec(path),
      if (oldPath != null && oldPath.isNotEmpty && oldPath != path) topPathspec(oldPath),
    ];
    return _run(args);
  }

  /// 该提交与当前工作区之间的文件差异列表。
  Future<List<Map<String, dynamic>>> _compareWithLocal(String rev) async {
    final full = await _resolveCommit(rev);
    return parseNameStatusZ(await _run(['diff', '--no-color', '--name-status', '-M', '-z', full]));
  }

  Future<String> _compareWithLocalDiff(String rev, String path) async {
    final full = await _resolveCommit(rev);
    _requirePath(path);
    return _run([...diffTextArgs(), full, '--', topPathspec(path)]);
  }

  Future<List<String>> _treeAt(String rev) async {
    final full = await _resolveCommit(rev);
    final raw = await _run(['ls-tree', '-r', '--name-only', '-z', '--full-tree', full]);
    return raw.split('\x00').where((s) => s.isNotEmpty).toList();
  }

  /// `{"content","binary"}`;前 8000 字节里有 NUL 即视为二进制(与 git 自己的判定一致),不返回内容。
  Future<Map<String, dynamic>> _fileAt(String rev, String path) async {
    final full = await _resolveCommit(rev);
    _requirePath(path);
    final out = await _raw(['cat-file', 'blob', '$full:${trimLeadingSlashes(path)}']);
    if (!out.success) throw GitException('文件在该提交中不存在: $path');
    final bytes = out.stdoutBytes;
    final headLen = bytes.length < 8000 ? bytes.length : 8000;
    for (var i = 0; i < headLen; i++) {
      if (bytes[i] == 0) return {'content': '', 'binary': true};
    }
    return {'content': out.stdout, 'binary': false};
  }

  Future<String> _createPatch(String rev) async {
    final full = await _resolveCommit(rev);
    return _run(['format-patch', '-1', full, '--stdout']);
  }

  /// 是否已被任一远程跟踪分支包含。
  Future<bool> _isPushed(String rev) async {
    final full = await _resolveCommit(rev);
    final raw = await _run(['branch', '-r', '--contains', full]);
    return rustLines(raw).any((l) => l.trim().isNotEmpty);
  }

  /// 交互式 rebase 计划:从目标提交(含)到 HEAD,最老的在前。`base` 为 null 表示从根开始。
  Future<Map<String, dynamic>> _rebasePlan(String rev) async {
    final full = await _resolveCommit(rev);
    final (base, _) = await _linearRange(full);
    final raw = await _run([
      'log',
      '--reverse',
      '--no-color',
      '--no-show-signature',
      '--format=%x1e%H%x1f%s%x1f%B',
      rangeSpec(base),
    ]);
    final entries = <Map<String, dynamic>>[];
    for (final r in raw.split('\x1e')) {
      if (r.trim().isEmpty) continue;
      final f = splitN(r, '\x1f', 3);
      if (f.length != 3) continue;
      entries.add({'hash': f[0].trim(), 'subject': f[1], 'message': trimTrailingNewlines(f[2])});
    }
    return {'base': base, 'entries': entries};
  }

  Future<List<Map<String, dynamic>>> _diffHunks(String path) async {
    if (path.trim().isEmpty) return const [];
    // 优先对比 HEAD(含已暂存的修改);新仓库没有 HEAD 时退回对比暂存区
    var out = await _raw(['diff', '-U0', 'HEAD', '--', path]);
    if (!out.success || out.stdout.trim().isEmpty) {
      out = await _raw(['diff', '-U0', '--', path]);
      if (!out.success) return const [];
    }
    if (out.stdout.trim().isEmpty) return const [];
    return parseDiffHunks(out.stdout);
  }

  // =========================================================================
  // 写操作
  // =========================================================================

  Future<void> _cherryPick(String rev) async {
    await _ensureIdle();
    final full = await _resolveCommit(rev);
    final merge = (await _parentsOf(full)).length > 1;
    final out = await _raw(['cherry-pick', if (merge) ...['-m', '1'], full]);
    if (!out.success) {
      await _raw(['cherry-pick', '--abort']);
      throw GitException('Cherry-pick 冲突,已中止: ${out.detail}');
    }
  }

  Future<void> _checkoutRevision(String rev) async {
    final full = await _resolveCommit(rev);
    await _run(['checkout', '--detach', full]);
  }

  Future<void> _revertCommit(String rev) async {
    await _ensureIdle();
    final full = await _resolveCommit(rev);
    final merge = (await _parentsOf(full)).length > 1;
    final out = await _raw(['revert', '--no-edit', if (merge) ...['-m', '1'], full]);
    if (!out.success) {
      await _raw(['revert', '--abort']);
      throw GitException('Revert 冲突,已中止: ${out.detail}');
    }
  }

  Future<void> _resetTo(String rev, String flag) async {
    final full = await _resolveCommit(rev);
    await _run(['reset', flag, full]);
  }

  /// 撤销最近一次提交,改动保留在暂存区。
  Future<void> _undoCommit() async {
    if ((await _headHash()).isEmpty) throw GitException('仓库还没有任何提交');
    if (await _tryResolveCommit('HEAD^') == null) throw GitException('HEAD 没有父提交,无法撤销');
    await _run(['reset', '--soft', 'HEAD~1']);
  }

  Future<void> _newBranch(String rawName, String rev, bool checkout) async {
    final name = rawName.trim();
    final ok = name.isNotEmpty &&
        !name.startsWith('-') &&
        (await _raw(['check-ref-format', '--branch', name])).success;
    if (!ok) throw GitException('无效的分支名: $name');
    final full = await _resolveCommit(rev);
    await _run(checkout ? ['switch', '-c', name, full] : ['branch', name, full]);
  }

  Future<void> _newTag(String rawName, String rev, String? message) async {
    final name = rawName.trim();
    final ok = name.isNotEmpty &&
        !name.startsWith('-') &&
        (await _raw(['check-ref-format', 'refs/tags/$name'])).success;
    if (!ok) throw GitException('无效的标签名: $name');
    final full = await _resolveCommit(rev);
    if (message != null && message.trim().isNotEmpty) {
      await _run(['tag', '-a', name, '-m', message, full]);
    } else {
      await _run(['tag', name, full]);
    }
  }

  /// 修改提交信息。HEAD 直接 amend(只改消息,不带入暂存区);其余走脚本化 rebase。
  Future<void> _reword(String rev, String message) async {
    await _ensureIdle();
    _requireMessage(message);
    final full = await _resolveCommit(rev);
    await _withScratch((scratch) async {
      final msgFile = await scratch.write(message);
      if (full == await _headHash()) {
        await _run(['commit', '--amend', '--only', '--allow-empty', '-F', msgFile]);
        return;
      }
      final (base, commits) = await _linearRange(full);
      final todo = StringBuffer();
      for (final c in commits) {
        todo.write('pick $c\n');
        if (c == full) todo.write(_amendExecLine(msgFile));
      }
      await _scriptedRebase(scratch, base, todo.toString(), autosquash: false);
    });
  }

  Future<void> _dropCommit(String rev) async {
    await _ensureIdle();
    final full = await _resolveCommit(rev);
    final (base, commits) = await _linearRange(full);
    final todo = [for (final c in commits) '${c == full ? 'drop' : 'pick'} $c\n'].join();
    await _withScratch((scratch) => _scriptedRebase(scratch, base, todo, autosquash: false));
  }

  /// 按 UI 编辑好的计划执行交互式 rebase。条目必须恰好覆盖 base..HEAD,防止旧计划误删提交。
  Future<void> _rebaseInteractive(String? base, List<_RebaseEntry> entries) async {
    await _ensureIdle();
    if (entries.isEmpty) throw GitException('rebase 计划为空');
    for (final e in entries) {
      if (e.action == 'drop') continue;
      if (e.action == 'squash' || e.action == 'fixup') throw GitException('第一个提交不能是 squash / fixup');
      break;
    }
    final head = await _headHash();
    if (head.isEmpty) throw GitException('仓库还没有任何提交');
    String? baseFull;
    if (base != null && base.trim().isNotEmpty) {
      baseFull = await _resolveCommit(base);
      if (!await _isAncestor(baseFull, head)) throw GitException('rebase 基点不在当前分支的历史中');
    }
    final range = rangeSpec(baseFull);
    await _ensureNoMerges(range);
    final expected = rustLines(await _run(['rev-list', range])).map((l) => l.trim()).where((l) => l.isNotEmpty).toSet();

    final seen = <String>{};
    final resolved = <String>[];
    for (final e in entries) {
      final full = await _resolveCommit(e.hash);
      if (!seen.add(full)) throw GitException('rebase 计划中提交重复: ${e.hash}');
      resolved.add(full);
    }
    if (seen.length != expected.length || !seen.containsAll(expected)) {
      throw GitException('rebase 计划与当前分支历史不一致,请刷新后重试');
    }

    // 消息临时文件需要活到 rebase 结束:同一个 scratch 目录,结束后整体删除
    await _withScratch((scratch) async {
      final todo = StringBuffer();
      for (var i = 0; i < entries.length; i++) {
        final e = entries[i];
        final full = resolved[i];
        switch (e.action) {
          case 'pick':
          case 'drop':
          case 'fixup':
            todo.write('${e.action} $full\n');
          default: // reword / squash
            todo.write('${e.action == 'reword' ? 'pick' : 'squash'} $full\n');
            // 没给新消息时:reword 退化为 pick,squash 保留 git 默认的合并消息
            final m = e.message;
            if (m != null && m.trim().isNotEmpty) todo.write(_amendExecLine(await scratch.write(m)));
        }
      }
      await _scriptedRebase(scratch, baseFull, todo.toString(), autosquash: false);
    });
  }

  /// 把 `hash` 到 HEAD 的提交推送到上游分支(只推到该提交为止)。返回 `{"remote","branch"}`。
  Future<Map<String, dynamic>> _pushUpTo(String rev) async {
    final current = await _currentBranchName();
    if (current == null) throw GitException('当前处于游离 HEAD,无法推送');
    final full = await _resolveCommit(rev);
    if (!await _isAncestor(full, await _headHash())) throw GitException('该提交不在当前分支的历史中');
    final remote = await _configGet('branch.$current.remote');
    final merge = await _configGet('branch.$current.merge');
    var targetRemote = 'origin';
    var targetBranch = current;
    // remote 为 "." 表示上游是本地分支,推不出去,按无上游处理
    if (remote != null && merge != null && remote != '.') {
      targetRemote = remote;
      targetBranch = merge.startsWith('refs/heads/') ? merge.substring('refs/heads/'.length) : merge;
    }
    // 禁止交互式凭据提示:没有 TTY 时 git 会一直挂起
    await _run(['push', targetRemote, '$full:refs/heads/$targetBranch'], env: {'GIT_TERMINAL_PROMPT': '0'});
    return {'remote': targetRemote, 'branch': targetBranch};
  }

  /// fixup(message 为 null,保留目标原消息)/ squash(替换为 message):把已暂存的修改并入目标提交。
  Future<void> _foldStagedInto(String rev, String? message) async {
    await _ensureIdle();
    final full = await _resolveCommit(rev);
    if (!await _hasStagedChanges()) throw GitException('没有已暂存的修改');
    // 先校验范围再提交,避免校验失败时留下一个孤立的 fixup 提交
    final (base, commits) = await _linearRange(full);
    await _withScratch((scratch) async {
      final msgFile = message == null ? null : await scratch.write(message);
      await _run(['commit', '--fixup', full]);
      final fixupHash = await _headHash();

      // 自己生成 todo:不依赖 "fixup! <subject>" 的标题匹配,重名提交也不会并错
      final todo = StringBuffer();
      for (final c in commits) {
        todo.write('pick $c\n');
        if (c == full) {
          todo.write('fixup $fixupHash\n');
          if (msgFile != null) todo.write(_amendExecLine(msgFile));
        }
      }
      try {
        await _scriptedRebase(scratch, base, todo.toString(), autosquash: true);
      } on GitException {
        // 还原到操作前:撤掉 fixup 提交,修改回到暂存区
        if (await _headHash() == fixupHash) await _raw(['reset', '--soft', 'HEAD~1']);
        rethrow;
      }
    });
  }

  /// 用预生成的 todo 跑 `git rebase -i`;任何失败都 `--abort`,保证不留半途状态。
  Future<void> _scriptedRebase(_Scratch scratch, String? base, String todo, {required bool autosquash}) async {
    final todoFile = await scratch.write(todo, tag: 'todo');
    // git 会把自己的 todo 文件路径追加为参数:cp <预生成 todo> <git 的 todo>
    final seqEditor = 'cp ${shQuote(todoFile)}';
    final out = await _raw(
      ['rebase', '-i', '--autostash', if (autosquash) '--autosquash', base ?? '--root'],
      env: {'GIT_SEQUENCE_EDITOR': seqEditor, 'GIT_EDITOR': 'true'},
    );
    if (!out.success || await _rebaseInProgress()) {
      await _raw(['rebase', '--abort']);
      throw GitException('Rebase 失败,已中止: ${out.detail}');
    }
  }

  // =========================================================================
  // Blame(编辑器行号栏的 Annotate with Git Blame)
  // =========================================================================

  /// `git blame --porcelain`。[rev] 为空时注释工作区版本;[contents] 非空时把它当作文件当前内容
  /// (`--contents -`),这样编辑器里没保存的改动也能对上行号 —— 未提交的行哈希为全 0。
  ///
  /// 返回 `{"lines":[hash per line, 0-based],"commits":{hash:{author,email,time,summary,
  /// path,previous_hash?,previous_path?}}}`;提交信息只出现一次,按哈希去重。
  Future<Map<String, dynamic>> _blame(String path, {String? rev, String? contents}) async {
    final args = ['blame', '--porcelain'];
    if (contents != null) args.addAll(['--contents', '-']);
    if (rev != null && rev.isNotEmpty) {
      if (rev.startsWith('-')) throw _ParamError('invalid rev');
      args.add(rev);
    }
    args.addAll(['--', path]);
    final out = await _rawWithStdin(args, contents);
    if (!out.success) throw out.failure;

    final lines = <String>[];
    final commits = <String, Map<String, dynamic>>{};
    Map<String, dynamic>? current;
    for (final line in out.stdout.split('\n')) {
      if (line.isEmpty) continue;
      if (line.startsWith('\t')) continue; // 行内容本身,不需要
      final header = RegExp(r'^([0-9a-f]{40}) \d+ (\d+)').firstMatch(line);
      if (header != null) {
        final hash = header.group(1)!;
        final finalLine = int.parse(header.group(2)!) - 1;
        while (lines.length <= finalLine) {
          lines.add(hash);
        }
        lines[finalLine] = hash;
        current = commits.putIfAbsent(hash, () => {'hash': hash});
        continue;
      }
      final c = current;
      if (c == null) continue;
      final space = line.indexOf(' ');
      final key = space < 0 ? line : line.substring(0, space);
      final value = space < 0 ? '' : line.substring(space + 1);
      switch (key) {
        case 'author':
          c['author'] = value;
        case 'author-mail':
          c['email'] = value.replaceAll(RegExp(r'^<|>$'), '');
        case 'author-time':
          c['time'] = int.tryParse(value) ?? 0;
        case 'summary':
          c['summary'] = value;
        case 'filename':
          c['path'] = value;
        case 'previous':
          final sp = value.indexOf(' ');
          if (sp > 0) {
            c['previous_hash'] = value.substring(0, sp);
            c['previous_path'] = value.substring(sp + 1);
          }
      }
    }
    return {'lines': lines, 'commits': commits};
  }

  // =========================================================================
  // 内部工具
  // =========================================================================

  /// 与 [_raw] 相同,但可以往 stdin 写入 [input](blame --contents -)。
  Future<_GitOutput> _rawWithStdin(List<String> args, String? input) async {
    if (input == null) return _raw(args);
    try {
      final proc = await Process.start('git', ['-C', root, ...args]);
      final stdout = <int>[];
      final stderr = <int>[];
      final outDone = proc.stdout.listen(stdout.addAll).asFuture<void>();
      final errDone = proc.stderr.listen(stderr.addAll).asFuture<void>();
      proc.stdin.add(utf8.encode(input));
      await proc.stdin.close();
      final code = await proc.exitCode;
      await Future.wait([outDone, errDone]);
      return _GitOutput(code, stdout, utf8.decode(stderr, allowMalformed: true));
    } on ProcessException catch (e) {
      throw GitException('IO error: ${e.message} (os error ${e.errorCode})');
    }
  }

  /// 不检查退出码的原始调用。stdout 按 UTF-8 宽松解码(非法字节替换为 U+FFFD,与旧实现一致)。
  Future<_GitOutput> _raw(List<String> args, {Map<String, String>? env}) async {
    try {
      final r = await Process.run(
        'git',
        ['-C', root, ...args],
        environment: env,
        stdoutEncoding: null,
        stderrEncoding: null,
      );
      return _GitOutput(
        r.exitCode,
        r.stdout as List<int>,
        utf8.decode(r.stderr as List<int>, allowMalformed: true),
      );
    } on ProcessException catch (e) {
      throw GitException('IO error: ${e.message} (os error ${e.errorCode})');
    }
  }

  /// 成功返回 stdout,失败抛 [GitException.commandFailed]。
  Future<String> _run(List<String> args, {Map<String, String>? env}) async {
    final out = await _raw(args, env: env);
    if (!out.success) throw out.failure;
    return out.stdout;
  }

  Future<Map<String, dynamic>> _guard(Future<Map<String, dynamic>> Function() body) async {
    try {
      return await body();
    } on GitException catch (e) {
      return _error(e.message);
    } catch (e) {
      return _error(e.toString());
    }
  }

  static Map<String, dynamic> _error(String msg) => {'status': 'error', 'error': msg};

  /// HEAD 的完整哈希;空仓库返回 ""。
  Future<String> _headHash() async => await _tryResolveCommit('HEAD') ?? '';

  /// 当前分支短名;游离 HEAD 返回 null(空仓库仍返回未诞生的分支名)。
  Future<String?> _currentBranchName() async {
    final out = await _raw(['symbolic-ref', '--quiet', '--short', 'HEAD']);
    return out.success ? nonEmpty(out.stdout.trim()) : null;
  }

  Future<String?> _tryResolveCommit(String rev) async {
    final r = rev.trim();
    // 以 '-' 开头会被 git 当成选项
    if (r.isEmpty || r.startsWith('-')) return null;
    final out = await _raw(['rev-parse', '--verify', '--quiet', '$r^{commit}']);
    return out.success ? nonEmpty(out.stdout.trim()) : null;
  }

  Future<String> _resolveCommit(String rev) async {
    if (rev.trim().isEmpty) throw GitException('缺少提交哈希');
    return await _tryResolveCommit(rev) ?? (throw GitException('找不到提交: ${rev.trim()}'));
  }

  Future<List<String>> _parentsOf(String full) async =>
      splitWhitespace(await _run(['rev-list', '--parents', '-n', '1', full])).skip(1).toList();

  Future<bool> _isAncestor(String ancestor, String descendant) async {
    if (descendant.isEmpty) return false;
    final out = await _raw(['merge-base', '--is-ancestor', ancestor, descendant]);
    return switch (out.exitCode) {
      0 => true,
      1 => false,
      _ => throw out.failure,
    };
  }

  Future<void> _ensureNoMerges(String range) async {
    final merges = await _run(['rev-list', '--merges', range]);
    if (merges.trim().isNotEmpty) throw GitException('范围内包含合并提交,不支持交互式 rebase');
  }

  /// 目标提交到 HEAD 的线性区间:返回 (rebase 基点, 区间内提交 最老在前)。基点 null 表示从根开始。
  Future<(String?, List<String>)> _linearRange(String full) async {
    final head = await _headHash();
    if (!await _isAncestor(full, head)) throw GitException('该提交不在当前分支的历史中');
    final parents = await _parentsOf(full);
    final base = parents.isEmpty ? null : parents.first;
    final range = rangeSpec(base);
    await _ensureNoMerges(range);
    final commits =
        rustLines(await _run(['rev-list', '--reverse', range])).map((l) => l.trim()).where((l) => l.isNotEmpty).toList();
    return (base, commits);
  }

  Future<bool> _hasStagedChanges() async {
    final out = await _raw(['diff', '--cached', '--quiet']);
    return switch (out.exitCode) {
      0 => false,
      1 => true,
      _ => throw out.failure,
    };
  }

  /// `.git/<name>` 是否存在(经 `--git-path` 解析,兼容 worktree / 子模块的 gitdir)。
  Future<bool> _gitPathExists(String name) async {
    final out = await _raw(['rev-parse', '--git-path', name]);
    if (!out.success) return false;
    final p = out.stdout.trim();
    final full = File(p).isAbsolute ? p : '$root${Platform.pathSeparator}$p';
    return await FileSystemEntity.type(full) != FileSystemEntityType.notFound;
  }

  Future<bool> _rebaseInProgress() async =>
      await _gitPathExists('rebase-merge') || await _gitPathExists('rebase-apply');

  /// 写操作失败时会执行 `--abort`;若用户自己有进行中的操作,先拒绝,免得误中止别人的现场。
  Future<void> _ensureIdle() async {
    var busy = await _rebaseInProgress();
    for (final n in const ['CHERRY_PICK_HEAD', 'REVERT_HEAD', 'MERGE_HEAD']) {
      if (busy) break;
      busy = await _gitPathExists(n);
    }
    if (busy) throw GitException('仓库中有进行中的 rebase / merge / cherry-pick / revert,请先完成或中止');
  }

  Future<String?> _configGet(String key) async {
    final out = await _raw(['config', '--get', key]);
    return out.success ? nonEmpty(out.stdout.trim()) : null;
  }

  Future<Map<String, dynamic>?> _logSingle(String full) async {
    final raw = await _run(['log', '-1', '--no-walk', '--decorate=full', '--no-color', '--no-show-signature', logFormat, full]);
    final commits = parseLogRecords(raw);
    return commits.isEmpty ? null : commits.first;
  }

  Future<List<Map<String, dynamic>>> _commitFiles(String full, String? firstParent) async {
    final raw = firstParent != null
        ? await _run(['diff', '--no-color', '--name-status', '-M', '-z', firstParent, full])
        : await _run(['diff-tree', '--root', '--no-commit-id', '-r', '--name-status', '-M', '-z', full]);
    return parseNameStatusZ(raw);
  }

  /// 为一次写操作分配临时目录(消息文件 / todo),无论成败都整体删除。
  Future<T> _withScratch<T>(Future<T> Function(_Scratch scratch) body) async {
    final dir = await Directory.systemTemp.createTemp('codelite_git_');
    try {
      return await body(_Scratch(dir));
    } finally {
      try {
        await dir.delete(recursive: true);
      } on FileSystemException {
        // 清理失败不影响操作结果
      }
    }
  }

  static String _amendExecLine(String msgFile) =>
      'exec git commit --amend --only --allow-empty -F ${shQuote(msgFile)}\n';

  static void _requirePath(String path) {
    if (path.trim().isEmpty) throw GitException('缺少文件路径');
  }

  static void _requireMessage(String message) {
    if (message.trim().isEmpty) throw GitException('提交信息不能为空');
  }
}

/// 一次写操作的临时目录;[write] 返回给 sh / git 使用的路径(统一正斜杠,git 在 Windows 上也走 sh)。
class _Scratch {
  _Scratch(this.dir);

  final Directory dir;
  var _seq = 0;

  Future<String> write(String content, {String tag = 'msg'}) async {
    final f = File('${dir.path}${Platform.pathSeparator}${tag}_${_seq++}');
    await f.writeAsString(content, flush: true);
    return f.path.replaceAll(r'\', '/');
  }
}

// ---------------------------------------------------------------------------
// 参数解析:对齐旧 serde 反序列化语义(缺省 Option → null,类型不符 → "参数无效: ...")
// ---------------------------------------------------------------------------

class _Params {
  _Params(this._m);

  final Map<String, dynamic> _m;

  /// 必填字符串。
  String str(String key) {
    if (!_m.containsKey(key)) throw _ParamError('missing field `$key`');
    final v = _m[key];
    if (v is String) return v;
    throw _ParamError('invalid type: ${_describe(v)}, expected a string');
  }

  String? optStr(String key) {
    final v = _m[key];
    if (v == null || v is String) return v as String?;
    throw _ParamError('invalid type: ${_describe(v)}, expected a string');
  }

  bool? optBool(String key) {
    final v = _m[key];
    if (v == null || v is bool) return v as bool?;
    throw _ParamError('invalid type: ${_describe(v)}, expected a boolean');
  }

  int? optInt(String key) {
    final v = _m[key];
    if (v == null || v is int) return v as int?;
    throw _ParamError('invalid type: ${_describe(v)}, expected i64');
  }

  /// UI 侧可能显式传 null,与缺省同等对待。
  bool flag(String key) => optBool(key) ?? false;

  List<String> strList(String key) {
    final v = _m[key];
    if (v == null) return const [];
    if (v is! List) throw _ParamError('invalid type: ${_describe(v)}, expected a sequence');
    return [
      for (final e in v)
        if (e is String) e else throw _ParamError('invalid type: ${_describe(e)}, expected a string'),
    ];
  }

  List<_RebaseEntry> entries(String key) {
    if (!_m.containsKey(key)) throw _ParamError('missing field `$key`');
    final v = _m[key];
    if (v is! List) throw _ParamError('invalid type: ${_describe(v)}, expected a sequence');
    return [
      for (final e in v)
        if (e is Map) _RebaseEntry.parse(_Params(e.cast<String, dynamic>()))
        else throw _ParamError('invalid type: ${_describe(e)}, expected struct RebaseEntry'),
    ];
  }

  static String _describe(Object? v) => switch (v) {
        null => 'null',
        bool b => 'boolean `$b`',
        int i => 'integer `$i`',
        double d => 'floating point `$d`',
        String s => 'string "$s"',
        List _ => 'sequence',
        Map _ => 'map',
        _ => v.runtimeType.toString(),
      };
}

class _RebaseEntry {
  _RebaseEntry(this.hash, this.action, this.message);

  static const _actions = ['pick', 'reword', 'squash', 'fixup', 'drop'];

  final String hash;

  /// pick / reword / squash / fixup / drop
  final String action;
  final String? message;

  factory _RebaseEntry.parse(_Params p) {
    final hash = p.str('hash');
    final action = p.str('action');
    if (!_actions.contains(action)) {
      throw _ParamError('unknown variant `$action`, expected one of ${_actions.map((a) => '`$a`').join(', ')}');
    }
    return _RebaseEntry(hash, action, p.optStr('message'));
  }
}

/// `git.log` 的查询参数;缺省字段全部按「不过滤」处理。
class _LogQuery {
  _LogQuery({
    this.text,
    this.regex = false,
    this.matchCase = false,
    this.branch,
    this.author,
    this.since,
    this.paths = const [],
    this.limit,
    this.skip,
  });

  final String? text;
  final bool regex;
  final bool matchCase;
  final String? branch;
  final String? author;

  /// unix 秒;<= 0 视为不过滤
  final int? since;
  final List<String> paths;
  final int? limit;
  final int? skip;

  factory _LogQuery.parse(_Params p) => _LogQuery(
        text: p.optStr('text'),
        regex: p.flag('regex'),
        matchCase: p.flag('match_case'),
        branch: p.optStr('branch'),
        author: p.optStr('author'),
        since: p.optInt('since'),
        paths: p.strList('paths'),
        limit: p.optInt('limit'),
        skip: p.optInt('skip'),
      );
}
