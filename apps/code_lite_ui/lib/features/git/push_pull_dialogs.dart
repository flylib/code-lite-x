// Push / Pull 前的确认框(同 IntelliJ):
// - Push Commits:列出这次要推到远程的提交,确认后才推;
// - 本地有没提交的改动时 Update(Pull):列出改动,选「Stash 后更新」/「直接更新」/ 取消。

import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';
import 'git_log_window.dart' show formatGitDate, gitChangeColor;

const TextStyle _text = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);
const TextStyle _title = TextStyle(color: IntelliJTheme.textHigh, fontSize: 15);

/// 一个要推送的提交(`git.outgoing` 的一项)。
class OutgoingCommit {
  const OutgoingCommit({required this.hash, required this.short, required this.author, required this.time, required this.subject});

  factory OutgoingCommit.fromJson(Map<String, dynamic> j) => OutgoingCommit(
        hash: j['hash'] as String? ?? '',
        short: j['short'] as String? ?? '',
        author: j['author'] as String? ?? '',
        time: DateTime.fromMillisecondsSinceEpoch(((j['time'] as num?) ?? 0).toInt() * 1000),
        subject: j['subject'] as String? ?? '',
      );

  final String hash;
  final String short;
  final String author;
  final DateTime time;
  final String subject;
}

/// Push Commits:当前分支 → 远程分支,下面是要推的提交(新的在前)。确认推送返回 true。
/// 没有要推的提交、分支也已经有上游时,「Push」按钮不可用。
Future<bool> showPushDialog(
  BuildContext context, {
  required String branch,
  required String remote,
  required String targetBranch,
  required bool setUpstream,
  required List<OutgoingCommit> commits,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (_) => PushDialog(branch: branch, remote: remote, targetBranch: targetBranch, setUpstream: setUpstream, commits: commits),
    ) ??
    false;

class PushDialog extends StatelessWidget {
  const PushDialog({
    super.key,
    required this.branch,
    required this.remote,
    required this.targetBranch,
    required this.setUpstream,
    required this.commits,
  });

  final String branch;
  final String remote;
  final String targetBranch;
  final bool setUpstream;
  final List<OutgoingCommit> commits;

  bool get canPush => commits.isNotEmpty || setUpstream;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text(tr('推送提交', 'Push Commits'), style: _title),
      content: SizedBox(
        width: 640,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // main → origin : main(第一次推的分支标「New」,推完设为上游)
            Row(
              children: [
                const Icon(Icons.call_split, size: 15, color: IntelliJTheme.textSecondary),
                const SizedBox(width: 6),
                Flexible(child: Text(branch, overflow: TextOverflow.ellipsis, style: _text.copyWith(fontWeight: FontWeight.w600))),
                const Padding(padding: EdgeInsets.symmetric(horizontal: 8), child: Text('→', style: _muted)),
                Flexible(
                  child: Text('$remote : $targetBranch', key: const ValueKey('push-target'), overflow: TextOverflow.ellipsis, style: _text),
                ),
                if (setUpstream) ...[
                  const SizedBox(width: 6),
                  Container(
                    key: const ValueKey('push-new-branch'),
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(border: Border.all(color: IntelliJTheme.accentBlue), borderRadius: BorderRadius.circular(4)),
                    child: Text(tr('新建', 'New'), style: const TextStyle(color: IntelliJTheme.accentBlue, fontSize: 11)),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 10),
            Container(
              constraints: const BoxConstraints(maxHeight: 360),
              decoration: BoxDecoration(
                color: IntelliJTheme.editorBg,
                border: Border.all(color: IntelliJTheme.borderSubtle),
                borderRadius: BorderRadius.circular(4),
              ),
              child: commits.isEmpty
                  ? Padding(
                      padding: const EdgeInsets.all(16),
                      child: Text(
                          setUpstream
                              ? tr('没有新的提交,推送会在远程上建出这个分支', 'No new commits; pushing will create this branch on the remote')
                              : tr('没有要推送的提交,已经和远程一致', 'No commits to push; the branch is up to date with the remote'),
                          style: _muted),
                    )
                  : ListView.builder(
                      shrinkWrap: true,
                      itemCount: commits.length,
                      itemBuilder: (context, i) => _CommitRow(commit: commits[i]),
                    ),
            ),
            const SizedBox(height: 8),
            Text(
              commits.isEmpty
                  ? ''
                  : tr('${commits.length} 个提交${setUpstream ? ',推送后设为上游分支' : ''}',
                      '${commits.length} commit${commits.length == 1 ? '' : 's'}${setUpstream ? ', the branch will be set as upstream after pushing' : ''}'),
              key: const ValueKey('push-count'),
              style: _muted,
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context, false), child: Text(tr('取消', 'Cancel'))),
        FilledButton(
          key: const ValueKey('push-confirm'),
          onPressed: canPush ? () => Navigator.pop(context, true) : null,
          child: Text(tr('推送', 'Push')),
        ),
      ],
    );
  }
}

class _CommitRow extends StatelessWidget {
  const _CommitRow({required this.commit});

  final OutgoingCommit commit;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: commit.hash,
      waitDuration: const Duration(milliseconds: 600),
      child: Container(
        height: 28,
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: [
            const Icon(Icons.circle, size: 7, color: IntelliJTheme.accentYellow),
            const SizedBox(width: 10),
            Expanded(child: Text(commit.subject, overflow: TextOverflow.ellipsis, maxLines: 1, style: _text)),
            const SizedBox(width: 10),
            Text(commit.short, style: _muted.copyWith(fontFamily: 'monospace', fontSize: 11)),
            const SizedBox(width: 12),
            SizedBox(width: 110, child: Text(commit.author, overflow: TextOverflow.ellipsis, maxLines: 1, style: _muted)),
            SizedBox(width: 120, child: Text(formatGitDate(commit.time), textAlign: TextAlign.right, style: _muted)),
          ],
        ),
      ),
    );
  }
}

/// 有没提交的改动时 Update 怎么做。
enum UpdateWithChanges { stash, plain }

/// 本地有没提交的改动:列出来,问 Stash 后更新(默认,更新完自动恢复)/ 直接更新 / 取消(返回 null)。
Future<UpdateWithChanges?> showLocalChangesDialog(BuildContext context, List<Map<String, dynamic>> changes) =>
    showDialog<UpdateWithChanges>(
      context: context,
      builder: (context) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: Text(tr('本地有未提交的改动', 'Uncommitted Local Changes'), style: _title),
        content: SizedBox(
          width: 560,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Text(
                  tr('这 ${changes.length} 个文件还没提交。更新时可能被拉下来的改动覆盖或产生冲突。',
                      '${changes.length} file${changes.length == 1 ? ' has' : 's have'} not been committed. Incoming changes may overwrite them or cause conflicts during the update.'),
                  style: _text),
              const SizedBox(height: 10),
              Container(
                constraints: const BoxConstraints(maxHeight: 260),
                decoration: BoxDecoration(
                  color: IntelliJTheme.editorBg,
                  border: Border.all(color: IntelliJTheme.borderSubtle),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: ListView(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    for (final c in changes)
                      Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
                        child: Text(
                          c['path'] as String? ?? '',
                          overflow: TextOverflow.ellipsis,
                          maxLines: 1,
                          style: _text.copyWith(color: gitChangeColor(c['status'] as String? ?? 'modified')),
                        ),
                      ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              Text(
                  tr('「Stash 后更新」会先把这些改动存起来(git stash),更新完再自动恢复。',
                      '"Stash and Update" saves these changes first (git stash) and restores them automatically after the update.'),
                  style: _muted),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消', 'Cancel'))),
          OutlinedButton(onPressed: () => Navigator.pop(context, UpdateWithChanges.plain), child: Text(tr('直接更新', 'Update Without Stash'))),
          FilledButton(
            key: const ValueKey('update-stash'),
            onPressed: () => Navigator.pop(context, UpdateWithChanges.stash),
            child: Text(tr('Stash 后更新', 'Stash and Update')),
          ),
        ],
      ),
    );
