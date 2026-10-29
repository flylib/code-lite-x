import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/client/api_client.dart';
import '../../core/l10n/l10n.dart';
import 'commit_graph.dart';
import '../../core/state/dispose_safe.dart';

class GitRef {
  const GitRef(this.name, this.kind);

  final String name;

  /// head | local | remote | tag
  final String kind;

  factory GitRef.fromJson(Map<String, dynamic> j) => GitRef(j['name'] as String, j['kind'] as String);
}

class GitCommit {
  const GitCommit({
    required this.hash,
    required this.parents,
    required this.author,
    required this.email,
    required this.time,
    required this.subject,
    required this.refs,
  });

  final String hash;
  final List<String> parents;
  final String author;
  final String email;
  final DateTime time;
  final String subject;
  final List<GitRef> refs;

  String get short => hash.length > 8 ? hash.substring(0, 8) : hash;

  factory GitCommit.fromJson(Map<String, dynamic> j) => GitCommit(
        hash: j['hash'] as String,
        parents: [for (final p in (j['parents'] as List? ?? const [])) p as String],
        author: j['author'] as String? ?? '',
        email: j['email'] as String? ?? '',
        time: DateTime.fromMillisecondsSinceEpoch(((j['time'] as num?) ?? 0).toInt() * 1000),
        subject: j['subject'] as String? ?? '',
        refs: [for (final r in (j['refs'] as List? ?? const [])) GitRef.fromJson(r as Map<String, dynamic>)],
      );
}

class GitFileChange {
  const GitFileChange(this.path, this.oldPath, this.status);

  final String path;
  final String? oldPath;

  /// A / M / D / R / C / T
  final String status;

  factory GitFileChange.fromJson(Map<String, dynamic> j) =>
      GitFileChange(j['path'] as String, j['old_path'] as String?, j['status'] as String? ?? 'M');
}

class GitCommitDetails {
  const GitCommitDetails({
    required this.hash,
    required this.parents,
    required this.author,
    required this.email,
    required this.authorTime,
    required this.committer,
    required this.commitTime,
    required this.message,
    required this.refs,
    required this.files,
    required this.pushed,
    required this.isHead,
  });

  final String hash;
  final List<String> parents;
  final String author;
  final String email;
  final DateTime authorTime;
  final String committer;
  final DateTime commitTime;
  final String message;
  final List<GitRef> refs;
  final List<GitFileChange> files;
  final bool pushed;
  final bool isHead;

  factory GitCommitDetails.fromJson(Map<String, dynamic> j) {
    DateTime t(String k) => DateTime.fromMillisecondsSinceEpoch(((j[k] as num?) ?? 0).toInt() * 1000);
    return GitCommitDetails(
      hash: j['hash'] as String,
      parents: [for (final p in (j['parents'] as List? ?? const [])) p as String],
      author: j['author'] as String? ?? '',
      email: j['email'] as String? ?? '',
      authorTime: t('author_time'),
      committer: j['committer'] as String? ?? '',
      commitTime: t('commit_time'),
      message: j['message'] as String? ?? '',
      refs: [for (final r in (j['refs'] as List? ?? const [])) GitRef.fromJson(r as Map<String, dynamic>)],
      files: [for (final f in (j['files'] as List? ?? const [])) GitFileChange.fromJson(f as Map<String, dynamic>)],
      pushed: j['pushed'] == true,
      isHead: j['is_head'] == true,
    );
  }
}

class GitLocalBranch {
  const GitLocalBranch(this.name, this.hash, this.upstream, this.current);

  final String name;
  final String hash;
  final String? upstream;
  final bool current;
}

class GitRemoteBranch {
  const GitRemoteBranch(this.name, this.remote, this.short, this.hash);

  final String name;
  final String remote;
  final String short;
  final String hash;
}

/// 日期筛选,对应 IntelliJ Date 下拉。
enum DateFilter {
  all('全部', 'All'),
  day('过去 24 小时', 'Last 24 Hours'),
  week('过去 7 天', 'Last 7 Days'),
  month('过去 30 天', 'Last 30 Days'),
  year('过去一年', 'Last Year');

  const DateFilter(this._zh, this._en);
  final String _zh;
  final String _en;

  /// 下拉里显示的名字(跟着界面语言)。
  String get label => tr(_zh, _en);

  int get sinceUnix {
    final now = DateTime.now();
    final d = switch (this) {
      DateFilter.all => null,
      DateFilter.day => const Duration(days: 1),
      DateFilter.week => const Duration(days: 7),
      DateFilter.month => const Duration(days: 30),
      DateFilter.year => const Duration(days: 365),
    };
    return d == null ? 0 : now.subtract(d).millisecondsSinceEpoch ~/ 1000;
  }
}

/// Git Log 工具窗的状态:分支、提交列表(含图)、筛选、选中提交的详情。
///
/// 和终端一样放在面板之外:底部工具窗收起再打开时,筛选条件和选中项都还在。
class GitLogStore extends ChangeNotifier with DisposeSafeNotifier {
  GitLogStore(this._client);

  final ApiClient _client;
  static const _pageSize = 500;

  // --- 分支 ---
  String? currentBranch;
  bool detached = false;
  List<GitLocalBranch> localBranches = const [];
  List<GitRemoteBranch> remoteBranches = const [];

  // --- 提交 ---
  List<GitCommit> commits = const [];
  List<GraphRow> graph = const [];
  Map<String, int> _index = const {};
  Map<String, List<String>> _children = const {};
  String headHash = '';
  bool hasMore = false;
  bool loading = false;
  String? error;

  /// 仓库部分损坏:列表只含损坏点之前读得到的提交,这里是 git 的报错原文。
  String? warning;

  // --- 筛选 ---
  String text = '';
  bool regex = false;
  bool matchCase = false;

  /// null = 所有分支。默认 HEAD(当前分支);打开 Git 窗口时没选分支也回到 HEAD,见 [defaultToHead]。
  String? branch = 'HEAD';

  /// null = 所有人
  String? author;
  DateFilter date = DateFilter.all;
  List<String> paths = const [];
  List<String> authors = const [];

  // --- 选中 / 详情 ---
  String? selected;
  GitCommitDetails? details;
  bool showDetails = true;
  bool showBranches = true;

  /// 正在执行的写操作名(显示进度用);null 表示空闲。
  String? busy;

  bool _loaded = false;
  Timer? _textDebounce;
  int _loadToken = 0;
  int _detailsToken = 0;

  /// Git 现在是纯 Dart 实现,只有 web 预览(没有 dart:io)用不了。
  bool get isAvailable => !kIsWeb;
  bool get hasFilters => text.isNotEmpty || branch != null || author != null || date != DateFilter.all || paths.isNotEmpty;

  GitCommit? commit(String hash) {
    final i = _index[hash];
    return i == null ? null : commits[i];
  }

  int? indexOf(String hash) => _index[hash];

  List<String> childrenOf(String hash) => _children[hash] ?? const [];

  /// 第一次显示工具窗时才去拉数据:启动阶段不为没打开的面板付 git 的开销。
  void ensureLoaded() {
    if (_loaded) return;
    _loaded = true;
    refresh();
  }

  Future<void> refresh() async {
    _loaded = true;
    await Future.wait([_loadBranches(), _loadCommits(reset: true)]);
  }

  Future<void> _loadBranches() async {
    final res = await _client.gitCall('git.branches');
    if (res['status'] != 'ok') return;
    currentBranch = res['current'] as String?;
    detached = res['detached'] == true;
    localBranches = [
      for (final b in (res['local'] as List? ?? const []))
        GitLocalBranch(b['name'] as String, b['hash'] as String, b['upstream'] as String?, b['current'] == true),
    ];
    remoteBranches = [
      for (final b in (res['remote'] as List? ?? const []))
        GitRemoteBranch(b['name'] as String, b['remote'] as String, b['short'] as String, b['hash'] as String),
    ];
  }

  Future<void> _loadCommits({required bool reset}) async {
    final token = ++_loadToken;
    loading = true;
    error = null;
    notifyListeners();

    final params = <String, dynamic>{
      'text': text,
      'regex': regex,
      'match_case': matchCase,
      'branch': branch ?? '',
      'author': author ?? '',
      'since': date.sinceUnix,
      'paths': paths,
      'limit': _pageSize,
      'skip': reset ? 0 : commits.length,
    };
    // 大仓库的 git log 可能要几百毫秒,放后台。
    final res = await _client.gitCall('git.log', params);
    if (token != _loadToken) return; // 期间筛选又变了,丢弃过期结果

    loading = false;
    warning = res['warning'] as String?;
    if (res['status'] != 'ok') {
      error = res['error'] as String? ?? tr('加载失败', 'Failed to load');
      if (reset) _setCommits(const []);
      notifyListeners();
      return;
    }
    final page = [for (final c in (res['commits'] as List? ?? const [])) GitCommit.fromJson(c as Map<String, dynamic>)];
    headHash = res['head'] as String? ?? '';
    hasMore = res['has_more'] == true;
    _setCommits(reset ? page : [...commits, ...page]);

    if (selected == null || _index[selected] == null) {
      // 默认选中第一条(与 IntelliJ 打开 Log 的行为一致)。
      await selectCommit(commits.isEmpty ? null : commits.first.hash);
    } else {
      notifyListeners();
    }
  }

  void _setCommits(List<GitCommit> list) {
    commits = list;
    _index = {for (var i = 0; i < list.length; i++) list[i].hash: i};
    final children = <String, List<String>>{};
    for (final c in list) {
      for (final p in c.parents) {
        (children[p] ??= []).add(c.hash);
      }
    }
    _children = children;
    graph = layoutCommitGraph([for (final c in list) c.hash], [for (final c in list) c.parents]);
  }

  Future<void> loadMore() async {
    if (!hasMore || loading) return;
    await _loadCommits(reset: false);
  }

  /// 先立刻高亮选中行,再异步加载详情;快速连点时只采用最后一次的结果。
  Future<void> selectCommit(String? hash) async {
    final token = ++_detailsToken;
    selected = hash;
    details = null;
    notifyListeners();
    if (hash == null) return;
    final res = await _client.gitCall('git.commit_details', {'hash': hash});
    if (token != _detailsToken) return;
    if (res['status'] == 'ok') details = GitCommitDetails.fromJson(res);
    notifyListeners();
  }

  /// 选中一个可能还没加载到的提交(Go to Parent 跨页时)。
  Future<bool> reveal(String hash) async {
    while (_index[hash] == null && hasMore) {
      await loadMore();
    }
    if (_index[hash] == null) return false;
    await selectCommit(hash);
    return true;
  }

  // --- 筛选 setter ---

  void setText(String value) {
    if (value == text) return;
    text = value;
    _textDebounce?.cancel();
    _textDebounce = Timer(const Duration(milliseconds: 300), () => _loadCommits(reset: true));
  }

  void toggleRegex() {
    regex = !regex;
    _refilterOrNotify();
  }

  void toggleMatchCase() {
    matchCase = !matchCase;
    _refilterOrNotify();
  }

  void _refilterOrNotify() {
    if (text.isNotEmpty) {
      _loadCommits(reset: true);
    } else {
      notifyListeners();
    }
  }

  /// 切换了项目:丢掉旧仓库的一切,下次显示时重新加载。
  void invalidate() {
    _loadToken++;
    _loaded = false;
    commits = const [];
    graph = const [];
    _index = const {};
    _children = const {};
    localBranches = const [];
    remoteBranches = const [];
    authors = const [];
    selected = null;
    details = null;
    warning = null;
    branch = 'HEAD';
    author = null;
    paths = const [];
    error = null;
    notifyListeners();
  }

  /// 打开 Git 窗口时:没选分支(之前点 × 清掉了)就选回 HEAD。
  void defaultToHead() {
    if (branch != null) return;
    branch = 'HEAD';
    if (_loaded) _loadCommits(reset: true); // 还没加载过的话,马上的第一次加载就按 HEAD
  }

  void setBranch(String? value) {
    branch = value;
    _loadCommits(reset: true);
  }

  void setAuthor(String? value) {
    author = value;
    _loadCommits(reset: true);
  }

  void setDate(DateFilter value) {
    date = value;
    _loadCommits(reset: true);
  }

  void setPaths(List<String> value) {
    paths = value;
    _loadCommits(reset: true);
  }

  Future<void> loadAuthors() async {
    final res = await _client.gitCall('git.authors');
    if (res['status'] == 'ok') {
      authors = [for (final a in (res['authors'] as List? ?? const [])) a as String];
      notifyListeners();
    }
  }

  void toggleDetails() {
    showDetails = !showDetails;
    notifyListeners();
  }

  void toggleBranches() {
    showBranches = !showBranches;
    notifyListeners();
  }

  // --- 读取类辅助(对话框用) ---

  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) =>
      _client.gitCall(method, params);

  /// 执行一个会改动仓库的操作:后台跑、显示进度、完成后刷新分支和日志。
  /// 成功返回 null,失败返回错误信息。
  Future<String?> run(String label, String method, [Map<String, dynamic> params = const {}]) async {
    if (busy != null) return tr('有操作正在进行: $busy', 'Another operation is in progress: $busy');
    busy = label;
    notifyListeners();
    final res = await _client.gitCall(method, params);
    busy = null;
    await refresh();
    return res['status'] == 'ok' ? null : (res['error'] as String? ?? tr('$label失败', '$label failed'));
  }

  @override
  void dispose() {
    _textDebounce?.cancel();
    super.dispose();
  }
}
