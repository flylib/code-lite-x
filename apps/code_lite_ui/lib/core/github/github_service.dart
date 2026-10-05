// GitHub Pull Request 能力:全部通过本机 `gh` 命令行(`gh pr ...` / `gh api ...`)完成,
// 应用自己不保存任何 token —— 和 Git 一样走 Process.run,认证交给 gh。
//
// 仓库由 gh 按工作区的 git remote 自动识别(支持 ~/.ssh/config 里的 Host 别名)。

import 'dart:convert';

import 'gh_runner.dart';
import 'github_models.dart';

export 'github_models.dart';

/// 执行一次 gh,返回 stdout 字节;失败抛 [GhException]。测试里可注入假的实现。
typedef GhRunner = Future<List<int>> Function(List<String> args, {String? stdin});

// ---------------------------------------------------------------------------
// 服务
// ---------------------------------------------------------------------------

class GitHubService {
  GitHubService(this.root, {GhRunner? runner})
      : _runner = runner ?? ((args, {stdin}) => runGh(root, args, stdin: stdin));

  final GhRunner _runner;

  /// 工作区根目录:gh 在这里按 git remote 识别仓库。
  final String root;

  String? _repo;
  String? _viewer;

  static const _listFields =
      'number,title,author,createdAt,isDraft,comments,statusCheckRollup,reviewDecision,labels,assignees,state';
  static const _viewFields =
      'id,number,title,body,state,isDraft,author,url,createdAt,headRefName,baseRefName,headRefOid,baseRefOid,'
      'reviewRequests,reviews,statusCheckRollup,reviewDecision,commits,labels';

  /// "owner/name"。
  Future<String> repo() async {
    final cached = _repo;
    if (cached != null) return cached;
    final out = await _gh(['repo', 'view', '--json', 'nameWithOwner', '--jq', '.nameWithOwner']);
    return _repo = out.trim();
  }

  /// 当前登录的 GitHub 账号。
  Future<String> viewer() async {
    final cached = _viewer;
    if (cached != null) return cached;
    final out = await _gh(['api', 'user', '--jq', '.login']);
    return _viewer = out.trim();
  }

  /// [state]:open / closed / merged / all。[search] 是 GitHub 搜索语法(可空)。
  Future<List<PullRequestSummary>> list({
    String state = 'open',
    String search = '',
    String? author,
    String? label,
    String? assignee,
    int limit = 100,
  }) async {
    final args = ['pr', 'list', '--state', state, '--limit', '$limit', '--json', _listFields];
    if (search.trim().isNotEmpty) args.addAll(['--search', search.trim()]);
    if (author != null && author.isNotEmpty) args.addAll(['--author', author]);
    if (label != null && label.isNotEmpty) args.addAll(['--label', label]);
    if (assignee != null && assignee.isNotEmpty) args.addAll(['--assignee', assignee]);
    final out = await _gh(args);
    return [for (final j in jsonDecode(out) as List) PullRequestSummary.fromJson(Map<String, dynamic>.from(j as Map))];
  }

  Future<PullRequestDetail> detail(int number) async {
    final out = await _gh(['pr', 'view', '$number', '--json', _viewFields]);
    return PullRequestDetail.fromJson(Map<String, dynamic>.from(jsonDecode(out) as Map));
  }

  Future<List<PrFile>> files(int number) async {
    final r = await repo();
    final rows = await _apiLines('repos/$r/pulls/$number/files?per_page=100');
    return [
      for (final j in rows)
        PrFile(
          path: j['filename'] as String,
          status: j['status'] as String? ?? 'modified',
          additions: j['additions'] as int? ?? 0,
          deletions: j['deletions'] as int? ?? 0,
          previousPath: j['previous_filename'] as String?,
        ),
    ];
  }

  /// PR 差异的左侧基准:base 与 head 的 merge-base(GitHub 的 PR diff 也是以它为基准)。
  Future<String> mergeBase(String baseSha, String headSha) async {
    final r = await repo();
    final out = await _gh(['api', 'repos/$r/compare/$baseSha...$headSha', '--jq', '.merge_base_commit.sha']);
    final sha = out.trim();
    return sha.isEmpty ? baseSha : sha;
  }

  /// 文件在某个提交里的内容;不存在(新增 / 删除的一侧)时返回 null。
  Future<String?> fileAt(String sha, String path) async {
    final r = await repo();
    try {
      final bytes = await _ghBytes([
        'api',
        '-H',
        'Accept: application/vnd.github.raw',
        'repos/$r/contents/${Uri.encodeComponent(path).replaceAll('%2F', '/')}?ref=$sha',
      ]);
      return utf8.decode(bytes, allowMalformed: true);
    } on GhException catch (e) {
      if (e.message.contains('404') || e.message.contains('Not Found')) return null;
      rethrow;
    }
  }

  Future<List<PrReviewComment>> reviewComments(int number) async {
    final r = await repo();
    final rows = await _apiLines('repos/$r/pulls/$number/comments?per_page=100');
    return [for (final j in rows) PrReviewComment.fromJson(j)];
  }

  /// 在 [path] 的第 [line] 行(1 起;[side] 为 LEFT/RIGHT)发表评审评论;[startLine] 给出时为多行评论。
  Future<PrReviewComment> addReviewComment(
    int number, {
    required String commitId,
    required String path,
    required int line,
    required String side,
    required String body,
    int? startLine,
  }) async {
    final r = await repo();
    final payload = <String, dynamic>{
      'body': body,
      'commit_id': commitId,
      'path': path,
      'line': line,
      'side': side,
      if (startLine != null && startLine < line) ...{'start_line': startLine, 'start_side': side},
    };
    final out = await _post('repos/$r/pulls/$number/comments', payload);
    return PrReviewComment.fromJson(Map<String, dynamic>.from(jsonDecode(out) as Map));
  }

  Future<PrReviewComment> replyToComment(int number, int commentId, String body) async {
    final r = await repo();
    final out = await _post('repos/$r/pulls/$number/comments/$commentId/replies', {'body': body});
    return PrReviewComment.fromJson(Map<String, dynamic>.from(jsonDecode(out) as Map));
  }

  /// [event]:APPROVE / REQUEST_CHANGES / COMMENT。
  Future<void> submitReview(int number, String event, String body) async {
    final r = await repo();
    await _post('repos/$r/pulls/$number/reviews', {'event': event, if (body.trim().isNotEmpty) 'body': body});
  }

  /// PR 下的普通评论(Timeline 底部的输入框)。
  Future<void> addComment(int number, String body) async {
    final r = await repo();
    await _post('repos/$r/issues/$number/comments', {'body': body});
  }

  Future<void> requestReviewer(int number, String login) async {
    final r = await repo();
    await _post('repos/$r/pulls/$number/requested_reviewers', {
      'reviewers': [login],
    });
  }

  Future<List<PrTimelineItem>> timeline(int number) async {
    final r = await repo();
    final rows = await _apiLines('repos/$r/issues/$number/timeline?per_page=100');
    return [for (final j in rows) PrTimelineItem.fromJson(j)];
  }

  /// 每个文件「已查看」的状态(path → true 表示已查看)。
  Future<Map<String, bool>> viewedStates(int number) async {
    final parts = (await repo()).split('/');
    final out = await _gh([
      'api',
      'graphql',
      '-f',
      'query=query(\$o:String!,\$r:String!,\$n:Int!){repository(owner:\$o,name:\$r){pullRequest(number:\$n){files(first:100){nodes{path viewerViewedState}}}}}',
      '-f',
      'o=${parts.first}',
      '-f',
      'r=${parts.last}',
      '-F',
      'n=$number',
      '--jq',
      '.data.repository.pullRequest.files.nodes',
    ]);
    final nodes = jsonDecode(out.trim().isEmpty ? '[]' : out) as List? ?? const [];
    return {for (final n in nodes) n['path'] as String: n['viewerViewedState'] == 'VIEWED'};
  }

  Future<void> setViewed(String pullRequestId, String path, bool viewed) async {
    final mutation = viewed ? 'markFileAsViewed' : 'unmarkFileAsViewed';
    await _gh([
      'api',
      'graphql',
      '-f',
      'query=mutation(\$id:ID!,\$p:String!){$mutation(input:{pullRequestId:\$id,path:\$p}){clientMutationId}}',
      '-f',
      'id=$pullRequestId',
      '-f',
      'p=$path',
    ]);
  }

  /// [sha] 版本里 [path] 的 blame(GitHub GraphQL,不要求本地有这个提交)。
  Future<List<PrBlameRange>> blame(String sha, String path) async {
    final parts = (await repo()).split('/');
    final out = await _gh([
      'api',
      'graphql',
      '-f',
      'query=query(\$o:String!,\$r:String!,\$e:String!,\$p:String!){repository(owner:\$o,name:\$r){object(expression:\$e){... on Commit{blame(path:\$p){ranges{startingLine endingLine commit{abbreviatedOid committedDate messageHeadline author{name user{login}}}}}}}}}',
      '-f',
      'o=${parts.first}',
      '-f',
      'r=${parts.last}',
      '-f',
      'e=$sha',
      '-f',
      'p=$path',
      '--jq',
      '.data.repository.object.blame.ranges',
    ]);
    final ranges = jsonDecode(out.trim().isEmpty ? '[]' : out) as List? ?? const [];
    return [
      for (final r in ranges)
        PrBlameRange(
          startLine: r['startingLine'] as int,
          endLine: r['endingLine'] as int,
          shortSha: r['commit']['abbreviatedOid'] as String? ?? '',
          author: (r['commit']['author']?['user']?['login'] ?? r['commit']['author']?['name'] ?? '') as String,
          date: DateTime.tryParse(r['commit']['committedDate'] as String? ?? '')?.toLocal(),
          summary: r['commit']['messageHeadline'] as String? ?? '',
        ),
    ];
  }

  /// 在系统浏览器里打开 PR / 检查详情。
  static Future<void> openInBrowser(String url) => openUrl(url);

  // -------------------------------------------------------------------------
  // gh 进程
  // -------------------------------------------------------------------------

  /// 分页 REST 列表:`--paginate --jq '.[]'` 每行一个 JSON 对象。
  Future<List<Map<String, dynamic>>> _apiLines(String path) async {
    final out = await _gh(['api', '--paginate', path, '--jq', '.[]']);
    return [
      for (final line in const LineSplitter().convert(out))
        if (line.trim().isNotEmpty) Map<String, dynamic>.from(jsonDecode(line) as Map),
    ];
  }

  /// POST 一个 JSON 请求体(经 stdin 传入,正文里的任何字符都不会被当成参数解析)。
  Future<String> _post(String path, Map<String, dynamic> body) =>
      _gh(['api', '-X', 'POST', path, '--input', '-'], stdin: jsonEncode(body));

  Future<String> _gh(List<String> args, {String? stdin}) async =>
      utf8.decode(await _ghBytes(args, stdin: stdin), allowMalformed: true);

  Future<List<int>> _ghBytes(List<String> args, {String? stdin}) => _runner(args, stdin: stdin);
}
