import 'package:flutter/foundation.dart';

import '../../core/client/api_client.dart';
import '../../core/github/github_service.dart';
import '../editor/editor_view_widget.dart' show prDiffTabPrefix, prTimelineTabPrefix;

export '../editor/editor_view_widget.dart' show prDiffTabPrefix, prTimelineTabPrefix;


int? prNumberOfTab(String id) {
  if (id.startsWith(prDiffTabPrefix)) return int.tryParse(id.substring(prDiffTabPrefix.length));
  if (id.startsWith(prTimelineTabPrefix)) return int.tryParse(id.substring(prTimelineTabPrefix.length));
  return null;
}

/// Pull Requests 工具窗的状态:列表 + 筛选、工具窗里打开的 PR(标题栏上的「#1392 ×」)、
/// 以及每个 PR 的详情会话([PrSession],差异标签与 Timeline 标签共用)。
///
/// 放在工具窗之外:切到别的工具窗再切回来,列表、筛选和已打开的 PR 都还在。
class PullRequestsStore extends ChangeNotifier {
  PullRequestsStore(ApiClient client) : _ghOf = (() => client.github);

  /// 测试用:直接给出 GitHubService(可注入假的 gh)。
  PullRequestsStore.withService(this._ghOf);

  /// 取当前工作区的 GitHubService(切换项目后 ApiClient 会换一个新的)。
  final GitHubService Function() _ghOf;
  GitHubService get _gh => _ghOf();

  // ---- 列表与筛选 ----
  /// open / closed / merged / all。
  String stateFilter = 'open';
  String search = '';
  String? author;
  String? label;
  String? assignee;

  List<PullRequestSummary> items = const [];
  bool loading = false;
  bool _loaded = false;
  String? error;

  /// gh 没装 / 没登录:面板给出操作指引而不是一行报错。
  bool ghUnavailable = false;
  String repoName = '';
  String viewer = '';

  /// 列表里出现过的作者 / 标签 / 指派人(筛选下拉的候选)。
  final Set<String> knownAuthors = {};
  final Set<String> knownLabels = {};
  final Set<String> knownAssignees = {};

  // ---- 工具窗里打开的 PR ----
  final List<int> opened = [];

  /// 当前显示的 PR;null 显示列表。
  int? selected;

  final Map<int, PrSession> _sessions = {};
  int _generation = 0;

  /// 换了项目:之前的数据全部作废。
  void invalidate() {
    _generation++;
    items = const [];
    _loaded = false;
    error = null;
    ghUnavailable = false;
    repoName = '';
    viewer = '';
    knownAuthors.clear();
    knownLabels.clear();
    knownAssignees.clear();
    opened.clear();
    selected = null;
    for (final s in _sessions.values) {
      s.dispose();
    }
    _sessions.clear();
    notifyListeners();
  }

  void ensureLoaded() {
    if (!_loaded && !loading) refresh();
  }

  Future<void> refresh() async {
    final gen = ++_generation;
    loading = true;
    error = null;
    notifyListeners();
    try {
      if (repoName.isEmpty) repoName = await _gh.repo();
      if (viewer.isEmpty) {
        try {
          viewer = await _gh.viewer();
        } on GhException {
          // 拿不到登录名不影响列表
        }
      }
      final list = await _gh.list(
        state: stateFilter,
        search: search,
        author: author,
        label: label,
        assignee: assignee,
      );
      if (gen != _generation) return;
      items = list;
      for (final p in list) {
        knownAuthors.add(p.author);
        knownLabels.addAll(p.labels.map((l) => l.name));
        knownAssignees.addAll(p.assignees);
      }
      ghUnavailable = false;
    } on GhException catch (e) {
      if (gen != _generation) return;
      error = e.message;
      ghUnavailable = e.notInstalled || e.notLoggedIn;
      items = const [];
    }
    _loaded = true;
    loading = false;
    notifyListeners();
  }

  void setStateFilter(String v) {
    if (stateFilter == v) return;
    stateFilter = v;
    refresh();
  }

  void setSearch(String v) {
    if (search == v) return;
    search = v;
    refresh();
  }

  void setAuthor(String? v) {
    author = v;
    refresh();
  }

  void setLabel(String? v) {
    label = v;
    refresh();
  }

  void setAssignee(String? v) {
    assignee = v;
    refresh();
  }

  /// 在工具窗里打开一个 PR(标题栏多一个「#号 ×」)。
  void openPr(int number) {
    if (!opened.contains(number)) opened.add(number);
    selected = number;
    session(number).ensureLoaded();
    notifyListeners();
  }

  void closePr(int number) {
    opened.remove(number);
    if (selected == number) selected = null;
    notifyListeners();
  }

  void showList() {
    selected = null;
    notifyListeners();
  }

  PullRequestSummary? summaryOf(int number) {
    for (final p in items) {
      if (p.number == number) return p;
    }
    return null;
  }

  PrSession session(int number) => _sessions.putIfAbsent(number, () => PrSession(number, () => _gh, () => viewer));

  @override
  void dispose() {
    for (final s in _sessions.values) {
      s.dispose();
    }
    super.dispose();
  }
}

/// 一个 PR 的详情、改动文件、评审评论、已查看状态等。差异标签、Timeline 标签和工具窗详情页共用一份。
class PrSession extends ChangeNotifier {
  PrSession(this.number, this._ghOf, this._viewerOf);

  final int number;
  final GitHubService Function() _ghOf;
  final String Function() _viewerOf;
  GitHubService get _gh => _ghOf();
  String get viewer => _viewerOf();

  PullRequestDetail? detail;
  List<PrFile> files = const [];

  /// 差异左侧的基准提交(base 与 head 的 merge-base)。
  String? mergeBase;
  List<PrReviewComment> comments = const [];

  /// path → 已查看。拿不到(权限等)时为空,界面就不显示已查看标记。
  Map<String, bool> viewed = const {};
  List<PrTimelineItem>? timeline;

  bool loading = false;
  bool _loaded = false;
  String? error;

  /// 差异标签当前显示的文件。
  String? diffFile;

  final Map<String, Future<(String?, String?)>> _contents = {};
  final Map<String, Future<List<PrBlameRange>>> _blame = {};
  bool _disposed = false;

  void ensureLoaded() {
    if (!_loaded && !loading) reload();
  }

  Future<void> reload() async {
    loading = true;
    error = null;
    _notify();
    try {
      final results = await Future.wait([_gh.detail(number), _gh.files(number)]);
      final d = results[0] as PullRequestDetail;
      detail = d;
      files = results[1] as List<PrFile>;
      _contents.clear();
      _blame.clear();
      final extra = await Future.wait([
        _gh.mergeBase(d.baseSha, d.headSha),
        _gh.reviewComments(number),
        _gh.viewedStates(number).catchError((_) => <String, bool>{}),
      ]);
      mergeBase = extra[0] as String;
      comments = extra[1] as List<PrReviewComment>;
      viewed = extra[2] as Map<String, bool>;
      diffFile ??= files.isEmpty ? null : files.first.path;
    } on GhException catch (e) {
      error = e.message;
    }
    _loaded = true;
    loading = false;
    _notify();
  }

  PrFile? fileOf(String path) {
    for (final f in files) {
      if (f.path == path) return f;
    }
    return null;
  }

  /// (左 = merge-base 版本, 右 = PR head 版本);不存在的一侧为 null(新增 / 删除)。
  Future<(String?, String?)> contents(PrFile f) {
    final d = detail, base = mergeBase;
    if (d == null || base == null) return Future.value((null, null));
    return _contents.putIfAbsent(f.path, () async {
      final left = f.status == 'added' ? Future<String?>.value(null) : _gh.fileAt(base, f.basePath);
      final right = f.status == 'removed' ? Future<String?>.value(null) : _gh.fileAt(d.headSha, f.path);
      return (await left, await right);
    }).catchError((Object e) {
      _contents.remove(f.path);
      throw e;
    });
  }

  /// PR 版本(右侧)的 blame。
  Future<List<PrBlameRange>> blame(String path) {
    final d = detail;
    if (d == null) return Future.value(const []);
    return _blame.putIfAbsent(path, () => _gh.blame(d.headSha, path)).catchError((Object e) {
      _blame.remove(path);
      throw e;
    });
  }

  /// 该文件里仍能定位到行的评论(按根评论分组成会话,回复按时间排在后面)。
  List<List<PrReviewComment>> threadsFor(String path) {
    final roots = <int, List<PrReviewComment>>{};
    final byId = {for (final c in comments) c.id: c};
    for (final c in comments) {
      if (c.path != path) continue;
      var root = c;
      while (root.inReplyTo != null && byId[root.inReplyTo] != null) {
        root = byId[root.inReplyTo]!;
      }
      roots.putIfAbsent(root.id, () => []).add(c);
    }
    final threads = roots.values.toList();
    for (final t in threads) {
      t.sort((a, b) => (a.createdAt ?? DateTime(0)).compareTo(b.createdAt ?? DateTime(0)));
    }
    return threads;
  }

  int commentCount(String path) => comments.where((c) => c.path == path).length;

  /// 在某行发表评审评论。[line]/[startLine] 为 1 起的文件行号,[side] 为 LEFT / RIGHT。
  Future<void> addReviewComment({required String path, required int line, required String side, required String body, int? startLine}) async {
    final d = detail;
    if (d == null) return;
    final c = await _gh.addReviewComment(number, commitId: d.headSha, path: path, line: line, side: side, body: body, startLine: startLine);
    comments = [...comments, c];
    _notify();
  }

  Future<void> reply(int commentId, String body) async {
    final c = await _gh.replyToComment(number, commentId, body);
    comments = [...comments, c];
    _notify();
  }

  /// [event]:APPROVE / REQUEST_CHANGES / COMMENT。
  Future<void> submitReview(String event, String body) async {
    await _gh.submitReview(number, event, body);
    await reload();
    if (timeline != null) await loadTimeline();
  }

  Future<void> setViewed(String path, bool value) async {
    final d = detail;
    if (d == null) return;
    await _gh.setViewed(d.id, path, value);
    viewed = {...viewed, path: value};
    _notify();
  }

  Future<void> requestMyReview() async {
    final me = viewer.isNotEmpty ? viewer : await _gh.viewer();
    await _gh.requestReviewer(number, me);
    await reload();
  }

  Future<void> loadTimeline() async {
    timeline = await _gh.timeline(number);
    _notify();
  }

  Future<void> addComment(String body) async {
    await _gh.addComment(number, body);
    await loadTimeline();
  }

  void showFile(String path) {
    diffFile = path;
    _notify();
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
