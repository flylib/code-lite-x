// GitHub Pull Request 的数据模型(与平台无关;服务实现见 github_service.dart)。

/// gh 调用失败。[message] 是给用户看的文本(多为 gh 的 stderr)。
class GhException implements Exception {
  GhException(this.message, {this.notInstalled = false, this.notLoggedIn = false});

  final String message;

  /// 找不到 gh 可执行文件。
  final bool notInstalled;

  /// gh 未登录(`gh auth login`)。
  final bool notLoggedIn;

  @override
  String toString() => message;
}

// ---------------------------------------------------------------------------
// 数据模型
// ---------------------------------------------------------------------------

/// 检查(CI)的汇总状态。
enum ChecksState { none, success, pending, failure }

ChecksState checksStateOf(List<dynamic>? rollup) {
  if (rollup == null || rollup.isEmpty) return ChecksState.none;
  var pending = false;
  for (final raw in rollup) {
    final c = raw as Map;
    // CheckRun:status + conclusion;StatusContext:state。
    final conclusion = (c['conclusion'] ?? c['state'] ?? '').toString().toUpperCase();
    final status = (c['status'] ?? '').toString().toUpperCase();
    if (const {'FAILURE', 'ERROR', 'TIMED_OUT', 'CANCELLED', 'ACTION_REQUIRED', 'STARTUP_FAILURE'}.contains(conclusion)) {
      return ChecksState.failure;
    }
    if (conclusion == 'PENDING' || conclusion == 'EXPECTED' || (status.isNotEmpty && status != 'COMPLETED')) {
      pending = true;
    }
  }
  return pending ? ChecksState.pending : ChecksState.success;
}

class PrLabel {
  const PrLabel(this.name, this.color);
  final String name;

  /// 六位十六进制,无 #。
  final String color;
}

/// 列表里的一行。
class PullRequestSummary {
  PullRequestSummary({
    required this.number,
    required this.title,
    required this.author,
    required this.createdAt,
    required this.isDraft,
    required this.commentCount,
    required this.checks,
    required this.reviewDecision,
    required this.labels,
    required this.assignees,
    required this.state,
  });

  factory PullRequestSummary.fromJson(Map<String, dynamic> j) => PullRequestSummary(
        number: j['number'] as int,
        title: j['title'] as String? ?? '',
        author: _login(j['author']),
        createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '')?.toLocal(),
        isDraft: j['isDraft'] == true,
        commentCount: (j['comments'] as List?)?.length ?? 0,
        checks: checksStateOf(j['statusCheckRollup'] as List?),
        reviewDecision: j['reviewDecision'] as String? ?? '',
        labels: [for (final l in (j['labels'] as List? ?? const [])) PrLabel(l['name'] as String, l['color'] as String? ?? '888888')],
        assignees: [for (final a in (j['assignees'] as List? ?? const [])) _login(a)],
        state: j['state'] as String? ?? 'OPEN',
      );

  final int number;
  final String title;
  final String author;
  final DateTime? createdAt;
  final bool isDraft;
  final int commentCount;
  final ChecksState checks;

  /// APPROVED / CHANGES_REQUESTED / REVIEW_REQUIRED / ''。
  final String reviewDecision;
  final List<PrLabel> labels;
  final List<String> assignees;

  /// OPEN / CLOSED / MERGED。
  final String state;
}

class PrReview {
  const PrReview({required this.author, required this.state, required this.body, required this.submittedAt});
  final String author;

  /// APPROVED / CHANGES_REQUESTED / COMMENTED / DISMISSED / PENDING。
  final String state;
  final String body;
  final DateTime? submittedAt;
}

class PrCheck {
  const PrCheck({required this.name, required this.state, required this.url});
  final String name;
  final ChecksState state;
  final String? url;
}

class PrCommit {
  const PrCommit({required this.oid, required this.headline, required this.author, required this.date});
  final String oid;
  final String headline;
  final String author;
  final DateTime? date;
}

/// PR 改动的一个文件。[status] 取 GitHub 的 added / modified / removed / renamed / copied / changed。
class PrFile {
  const PrFile({
    required this.path,
    required this.status,
    required this.additions,
    required this.deletions,
    this.previousPath,
  });

  final String path;
  final String status;
  final int additions;
  final int deletions;
  final String? previousPath;

  /// 左侧(基线)里这个文件的路径:改名的文件取旧名。
  String get basePath => previousPath ?? path;
}

class PullRequestDetail {
  PullRequestDetail({
    required this.id,
    required this.number,
    required this.title,
    required this.body,
    required this.state,
    required this.isDraft,
    required this.author,
    required this.url,
    required this.createdAt,
    required this.headRef,
    required this.baseRef,
    required this.headSha,
    required this.baseSha,
    required this.reviewRequests,
    required this.reviews,
    required this.checks,
    required this.reviewDecision,
    required this.commits,
    required this.labels,
  });

  factory PullRequestDetail.fromJson(Map<String, dynamic> j) {
    final rollup = j['statusCheckRollup'] as List? ?? const [];
    return PullRequestDetail(
      id: j['id'] as String? ?? '',
      number: j['number'] as int,
      title: j['title'] as String? ?? '',
      body: j['body'] as String? ?? '',
      state: j['state'] as String? ?? 'OPEN',
      isDraft: j['isDraft'] == true,
      author: _login(j['author']),
      url: j['url'] as String? ?? '',
      createdAt: DateTime.tryParse(j['createdAt'] as String? ?? '')?.toLocal(),
      headRef: j['headRefName'] as String? ?? '',
      baseRef: j['baseRefName'] as String? ?? '',
      headSha: j['headRefOid'] as String? ?? '',
      baseSha: j['baseRefOid'] as String? ?? '',
      reviewRequests: [
        for (final r in (j['reviewRequests'] as List? ?? const []))
          (r['login'] ?? r['name'] ?? r['slug'] ?? '').toString(),
      ],
      reviews: [
        for (final r in (j['reviews'] as List? ?? const []))
          PrReview(
            author: _login(r['author']),
            state: r['state'] as String? ?? '',
            body: r['body'] as String? ?? '',
            submittedAt: DateTime.tryParse(r['submittedAt'] as String? ?? '')?.toLocal(),
          ),
      ],
      checks: [
        for (final raw in rollup)
          PrCheck(
            name: ((raw as Map)['name'] ?? raw['context'] ?? '').toString(),
            state: checksStateOf([raw]),
            url: (raw['detailsUrl'] ?? raw['targetUrl']) as String?,
          ),
      ],
      reviewDecision: j['reviewDecision'] as String? ?? '',
      commits: [
        for (final c in (j['commits'] as List? ?? const []))
          PrCommit(
            oid: c['oid'] as String? ?? '',
            headline: c['messageHeadline'] as String? ?? '',
            author: () {
              final authors = c['authors'] as List?;
              if (authors == null || authors.isEmpty) return '';
              final a = authors.first as Map;
              return (a['login'] as String?)?.isNotEmpty == true ? a['login'] as String : (a['name'] as String? ?? '');
            }(),
            date: DateTime.tryParse(c['committedDate'] as String? ?? '')?.toLocal(),
          ),
      ],
      labels: [for (final l in (j['labels'] as List? ?? const [])) PrLabel(l['name'] as String, l['color'] as String? ?? '888888')],
    );
  }

  /// GraphQL 节点 id(标记文件已查看要用)。
  final String id;
  final int number;
  final String title;
  final String body;
  final String state;
  final bool isDraft;
  final String author;
  final String url;
  final DateTime? createdAt;
  final String headRef;
  final String baseRef;
  final String headSha;
  final String baseSha;
  final List<String> reviewRequests;
  final List<PrReview> reviews;
  final List<PrCheck> checks;
  final String reviewDecision;
  final List<PrCommit> commits;
  final List<PrLabel> labels;

  ChecksState get checksState {
    if (checks.isEmpty) return ChecksState.none;
    if (checks.any((c) => c.state == ChecksState.failure)) return ChecksState.failure;
    if (checks.any((c) => c.state == ChecksState.pending)) return ChecksState.pending;
    return ChecksState.success;
  }
}

/// 行内评审评论(review comment)。[line] 为文件行号(1 起),评论所在代码已被后续提交改掉时为 null(outdated)。
class PrReviewComment {
  const PrReviewComment({
    required this.id,
    required this.path,
    required this.line,
    required this.startLine,
    required this.side,
    required this.inReplyTo,
    required this.author,
    required this.body,
    required this.createdAt,
    required this.originalLine,
  });

  factory PrReviewComment.fromJson(Map<String, dynamic> j) => PrReviewComment(
        id: j['id'] as int,
        path: j['path'] as String? ?? '',
        line: j['line'] as int?,
        startLine: j['start_line'] as int?,
        side: j['side'] as String? ?? 'RIGHT',
        inReplyTo: j['in_reply_to_id'] as int?,
        author: _login(j['user']),
        body: j['body'] as String? ?? '',
        createdAt: DateTime.tryParse(j['created_at'] as String? ?? '')?.toLocal(),
        originalLine: j['original_line'] as int?,
      );

  final int id;
  final String path;
  final int? line;
  final int? startLine;

  /// LEFT(基线)/ RIGHT(PR 版本)。
  final String side;
  final int? inReplyTo;
  final String author;
  final String body;
  final DateTime? createdAt;
  final int? originalLine;
}

/// Timeline 里的一条。[kind] 取 GitHub timeline 的 event 名:
/// commented / committed / reviewed / labeled / unlabeled / review_requested / merged / closed / reopened / head_ref_force_pushed …
class PrTimelineItem {
  const PrTimelineItem({required this.kind, required this.actor, required this.date, required this.body, this.state, this.extra});

  factory PrTimelineItem.fromJson(Map<String, dynamic> j) {
    final kind = j['event'] as String? ?? '';
    final actor = _login(j['actor']).isNotEmpty
        ? _login(j['actor'])
        : _login(j['user']).isNotEmpty
            ? _login(j['user'])
            : ((j['author'] as Map?)?['name'] as String? ?? '');
    final date = j['created_at'] ?? j['submitted_at'] ?? (j['author'] as Map?)?['date'] ?? (j['committer'] as Map?)?['date'];
    String? extra;
    if (kind == 'committed') {
      extra = (j['sha'] as String? ?? '').padRight(7).substring(0, 7);
    } else if (kind == 'labeled' || kind == 'unlabeled') {
      extra = (j['label'] as Map?)?['name'] as String?;
    } else if (kind == 'review_requested' || kind == 'review_request_removed') {
      extra = _login(j['requested_reviewer']).isNotEmpty ? _login(j['requested_reviewer']) : (j['requested_team'] as Map?)?['name'] as String?;
    } else if (kind == 'renamed') {
      extra = (j['rename'] as Map?)?['to'] as String?;
    } else if (kind == 'assigned' || kind == 'unassigned') {
      extra = _login(j['assignee']);
    }
    return PrTimelineItem(
      kind: kind,
      actor: actor,
      date: DateTime.tryParse(date as String? ?? '')?.toLocal(),
      body: (j['body'] ?? j['message'] ?? '') as String,
      state: j['state'] as String?,
      extra: extra,
    );
  }

  final String kind;
  final String actor;
  final DateTime? date;
  final String body;

  /// reviewed 的结果:approved / changes_requested / commented。
  final String? state;

  /// 事件附带信息:提交短哈希、标签名、被请求的评审人……
  final String? extra;
}

/// 一段 blame:[startLine]..[endLine](1 起,闭区间)出自同一个提交。
class PrBlameRange {
  const PrBlameRange({required this.startLine, required this.endLine, required this.shortSha, required this.author, required this.date, required this.summary});
  final int startLine;
  final int endLine;
  final String shortSha;
  final String author;
  final DateTime? date;
  final String summary;
}

String _login(dynamic user) {
  if (user is! Map) return '';
  return (user['login'] as String?) ?? (user['name'] as String?) ?? '';
}
