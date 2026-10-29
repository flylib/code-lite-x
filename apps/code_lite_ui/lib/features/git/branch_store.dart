// 标题栏的分支状态:当前分支、本地 / 远程分支、最近用过的分支,以及对它们的操作。
//
// 和 GitLogStore 分开:标题栏一直在,只要当前分支和一份分支列表,不该为此去加载整段提交历史。
// 在终端里 `git switch` 也要反映出来:每隔一会儿读一次 HEAD 文件(不起 git 进程),变了才重新加载。

import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../core/client/api_client.dart';
import '../../core/l10n/l10n.dart';
import 'git_log_store.dart' show GitLocalBranch, GitRemoteBranch;
import 'repo_operation.dart';

class BranchStore extends ChangeNotifier {
  BranchStore(this._client, {this.pollInterval = const Duration(seconds: 2)});

  final ApiClient _client;
  final Duration pollInterval;

  /// 仓库被改动之后调用:做过某个操作,或者发现别处切了分支。参数表示工作区里的文件是否变了
  /// (切换 / 更新 / 合并 / 变基会,推送、只建分支不会)。接上去的人负责刷新日志窗;
  /// 文件变了的话还有文件树和已打开的标签。
  void Function(bool worktreeChanged)? onChanged;

  /// 项目是不是 Git 仓库;不是的话标题栏不显示分支。
  bool isRepo = false;
  String? current;
  bool detached = false;
  String _head = '';
  List<GitLocalBranch> local = const [];
  List<GitRemoteBranch> remote = const [];

  /// 最近切换过的本地分支,最新的在前,不含当前分支。
  List<String> recent = const [];

  /// 进行中的合并 / 变基 / cherry-pick / revert(含冲突文件);没有时为 null。
  RepoOperation? operation;

  /// 正在执行的操作名(给界面显示进度),空闲时为 null。
  String? busy;

  /// Update / Push 跑着时 [busy] 的值;日志窗的 Pull / Push 按钮据此转圈。
  static String get updateLabel => tr('更新', 'Update');
  static String get pushLabel => tr('推送', 'Push');

  /// 最近一次 [run] 的返回(比如 `git.update` 的输出)。
  Map<String, dynamic> lastResult = const {};

  Timer? _timer;
  String _fingerprint = '';
  int _token = 0;
  bool _loading = false;
  bool _disposed = false;

  /// 标题栏上显示的名字:分支名;游离 HEAD 显示短哈希。
  String get label => current ?? (detached ? _head.substring(0, _head.length.clamp(0, 7)) : '');

  /// 开始关注当前项目。切换项目后再调一次([reset] 之后)。
  void start() {
    _timer ??= Timer.periodic(pollInterval, (_) => _poll());
    load();
  }

  /// 没有项目了(关闭项目):不再轮询。
  void stop() {
    _timer?.cancel();
    _timer = null;
  }

  /// 项目换了:先清空,免得闪出旧项目的分支。
  void reset() {
    _token++;
    _loading = false;
    isRepo = false;
    current = null;
    detached = false;
    _head = '';
    local = const [];
    remote = const [];
    recent = const [];
    operation = null;
    _fingerprint = '';
    _notify();
  }

  Future<void> load() async {
    final token = ++_token;
    _loading = true;
    final res = await _client.gitCall('git.branches');
    final recentRes = res['status'] == 'ok' ? await _client.gitCall('git.recent_branches', {'limit': 5}) : const <String, dynamic>{};
    final fingerprint = await _client.gitHeadFingerprint();
    // 指纹里带「|」说明有合并 / 变基在进行:才去读冲突(要起好几个 git 进程,平时不必)
    final opRes = res['status'] == 'ok' && fingerprint.contains('|') ? await _client.gitCall('git.operation_state') : const <String, dynamic>{};
    if (token != _token || _disposed) return; // 期间项目换了或又加载了一次
    _loading = false;
    _fingerprint = fingerprint;
    isRepo = res['status'] == 'ok';
    operation = opRes['status'] == 'ok' ? RepoOperation.fromJson(opRes) : null;
    if (isRepo) {
      current = res['current'] as String?;
      detached = res['detached'] == true;
      _head = (res['head'] as String?) ?? '';
      local = [
        for (final b in (res['local'] as List? ?? const []))
          GitLocalBranch(b['name'] as String, b['hash'] as String, b['upstream'] as String?, b['current'] == true),
      ];
      remote = [
        for (final b in (res['remote'] as List? ?? const []))
          GitRemoteBranch(b['name'] as String, b['remote'] as String, b['short'] as String, b['hash'] as String),
      ];
      recent = [for (final b in (recentRes['branches'] as List? ?? const [])) b as String];
    } else {
      current = null;
      detached = false;
      local = const [];
      remote = const [];
      recent = const [];
      operation = null;
    }
    _notify();
  }

  Future<void> _poll() async {
    // 加载还没回来时不能再发起一次:新的加载会让旧的作废,慢仓库上就永远加载不完
    if (busy != null || _loading || _disposed) return;
    final fingerprint = await _client.gitHeadFingerprint();
    if (fingerprint == _fingerprint || busy != null || _loading || _disposed) return;
    // 空串 → 非空(刚 git init)和反过来都算变化
    await load();
    onChanged?.call(true); // 外面切的分支,工作区文件多半也跟着变了
  }

  /// 执行一个会改动仓库的操作:显示进度、完成后重新加载并通知 [onChanged]。
  /// 成功返回 null,失败返回错误信息。[worktree] 说明这个操作会不会动工作区文件。
  Future<String?> run(String label, String method, [Map<String, dynamic> params = const {}, bool worktree = true]) async {
    if (busy != null) return tr('有操作正在进行: $busy', 'Another operation is in progress: $busy');
    busy = label;
    _notify();
    final res = await _client.gitCall(method, params);
    busy = null;
    lastResult = res;
    await load();
    onChanged?.call(worktree);
    return res['status'] == 'ok' ? null : (res['error'] as String? ?? tr('$label失败', '$label failed'));
  }

  /// 读类调用(不改仓库),比如 `git.log`;不显示进度。
  Future<Map<String, dynamic>> call(String method, [Map<String, dynamic> params = const {}]) =>
      _client.gitCall(method, params);

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    _timer?.cancel();
    super.dispose();
  }
}
