// 标题栏分支菜单里的操作:Update / Push / New Branch / Checkout / Merge / Rebase / Rename / Delete。
// 做事的是 BranchStore.run(后台跑 git、完成后重新加载并通知);这里只管弹对话框、问清楚、给提示。

import 'package:flutter/material.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';
import '../editor/blame.dart';
import 'branch_store.dart';
import 'conflicts_dialog.dart';
import 'merge_model.dart' show MergeSide;
import 'merge_window.dart';
import 'push_pull_dialogs.dart';
import 'repo_operation.dart';
import '../notifications/notifications.dart';

const TextStyle _text = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

class BranchActions {
  BranchActions(this.store, {required this.showCommitWindow});

  final BranchStore store;

  /// Commit…:打开左侧的 Commit 工具窗。
  final VoidCallback showCommitWindow;

  void _toast(BuildContext context, String message, {bool error = false}) {
    // 右下角弹卡片;错误还记进 Problems 工具窗
    showNotice(context, message, error: error);
  }

  /// 跑一个操作,成功 / 失败都给提示。成功返回 true。
  Future<bool> _run(BuildContext context, String label, String method, Map<String, dynamic> params,
      {String? success, bool worktree = true}) async {
    final err = await store.run(label, method, params, worktree);
    if (!context.mounted) return err == null; // 窗口已经没了,不必再提示
    if (err != null) {
      _toast(context, tr('$label失败: $err', '$label failed: $err'), error: true);
      return false;
    }
    if (success != null) _toast(context, success);
    return true;
  }

  /// Update(Pull):本地有没提交的改动时先问(Stash 后更新 / 直接更新 / 取消),同 IntelliJ。
  Future<void> update(BuildContext context) async {
    var stash = false;
    final local = await store.call('git.local_changes');
    final changes = [for (final c in (local['changes'] as List? ?? const [])) if (c is Map<String, dynamic>) c];
    if (!context.mounted) return;
    if (changes.isNotEmpty) {
      final choice = await showLocalChangesDialog(context, changes);
      if (choice == null || !context.mounted) return;
      stash = choice == UpdateWithChanges.stash;
    }
    final ok = await _run(context, BranchStore.updateLabel, 'git.update', {'stash': stash});
    if (!ok || !context.mounted) return;
    if (store.lastResult['stash_conflict'] == true) {
      _toast(
          context,
          tr('已更新,但恢复本地改动时有冲突:改动还在 stash 里(git stash list),解决冲突后再恢复',
              'Updated, but restoring local changes caused conflicts: the changes are still in the stash (git stash list). Resolve the conflicts, then restore them'),
          error: true);
      return;
    }
    final out = ((store.lastResult['output'] as String?) ?? '').trim();
    final last = out.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).lastOrNull ?? out;
    _toast(context, out.isEmpty ? tr('已更新', 'Updated') : tr('已更新: $last', 'Updated: $last'));
  }

  /// Push:先列出要推到远程的提交,确认后才推(同 IntelliJ 的 Push Commits)。
  Future<void> push(BuildContext context) async {
    final res = await store.call('git.outgoing');
    if (!context.mounted) return;
    if (res['status'] != 'ok') {
      _toast(context, tr('推送失败: ${res['error'] ?? '无法读取要推送的提交'}', 'Push failed: ${res['error'] ?? 'Cannot read the commits to push'}'), error: true);
      return;
    }
    final confirmed = await showPushDialog(
      context,
      branch: res['branch'] as String? ?? '',
      remote: res['remote'] as String? ?? '',
      targetBranch: res['target_branch'] as String? ?? '',
      setUpstream: res['set_upstream'] == true,
      commits: [for (final c in (res['commits'] as List? ?? const [])) if (c is Map<String, dynamic>) OutgoingCommit.fromJson(c)],
    );
    if (!confirmed || !context.mounted) return;
    final ok = await _run(context, BranchStore.pushLabel, 'git.push', const {}, worktree: false);
    if (!ok || !context.mounted) return;
    final r = store.lastResult;
    final upstream = r['set_upstream'] == true;
    _toast(context, tr('已推送 ${r['branch']} 到 ${r['remote']}${upstream ? '(并设为上游)' : ''}',
        'Pushed ${r['branch']} to ${r['remote']}${upstream ? ' (and set as upstream)' : ''}'));
  }

  Future<void> checkout(BuildContext context, String revision) async {
    final ok = await _run(context, tr('签出', 'Checkout'), 'git.checkout', {'name': revision});
    final branch = store.lastResult['branch'] ?? revision;
    if (ok && context.mounted) _toast(context, tr('已切换到 $branch', 'Checked out $branch'));
  }

  /// New Branch…:[from] 为空时从当前 HEAD 出发。
  Future<void> newBranch(BuildContext context, {String? from}) async {
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => NewBranchDialog(startPoint: from),
    );
    if (result == null || !context.mounted) return;
    final (name, checkout) = result;
    await _run(context, tr('新建分支', 'New Branch'), 'git.new_branch', {'name': name, 'hash': from ?? 'HEAD', 'checkout': checkout},
        success: checkout ? tr('已创建并切换到 $name', 'Created and checked out $name') : tr('已创建分支 $name', 'Created branch $name'),
        worktree: checkout);
  }

  Future<void> checkoutRevision(BuildContext context) async {
    final rev = await _prompt(context,
        title: tr('签出标签或修订', 'Checkout Tag or Revision'),
        label: tr('输入标签、分支名或提交哈希', 'Enter a tag, branch name or commit hash'),
        action: tr('签出', 'Checkout'));
    if (rev == null || rev.trim().isEmpty || !context.mounted) return;
    final ok = await _run(context, tr('签出', 'Checkout'), 'git.checkout_revision', {'hash': rev.trim()});
    if (ok && context.mounted) _toast(context, tr('已签出 ${rev.trim()}(游离 HEAD)', 'Checked out ${rev.trim()} (detached HEAD)'));
  }

  Future<void> merge(BuildContext context, String revision) async {
    final into = store.current ?? 'HEAD';
    final ok = await _confirm(context, tr('合并', 'Merge'), tr("把 '$revision' 合并进 '$into'?", "Merge '$revision' into '$into'?"),
        action: tr('合并', 'Merge'));
    if (!ok || !context.mounted) return;
    await _run(context, tr('合并', 'Merge'), 'git.merge', {'name': revision},
        success: tr("已把 '$revision' 合并进 '$into'", "Merged '$revision' into '$into'"));
  }

  Future<void> rebase(BuildContext context, String revision) async {
    final current = store.current;
    if (current == null) return;
    final ok = await _confirm(
      context,
      tr('变基', 'Rebase'),
      tr("把 '$current' 变基到 '$revision' 上?\n\n这会改写 '$current' 上的提交;如果已经推送过,之后需要强制推送。",
          "Rebase '$current' onto '$revision'?\n\nThis rewrites the commits on '$current'; if they have already been pushed, you will need to force-push afterwards."),
      action: tr('变基', 'Rebase'),
    );
    if (!ok || !context.mounted) return;
    await _run(context, tr('变基', 'Rebase'), 'git.rebase_onto', {'name': revision},
        success: tr("已把 '$current' 变基到 '$revision'", "Rebased '$current' onto '$revision'"));
  }

  Future<void> rename(BuildContext context, String name) async {
    final next = await _prompt(context,
        title: tr("重命名分支 '$name'", "Rename Branch '$name'"),
        label: tr('新的分支名', 'New branch name'),
        initial: name,
        action: tr('重命名', 'Rename'));
    if (next == null || next.trim() == name || !context.mounted) return;
    await _run(context, tr('重命名', 'Rename'), 'git.rename_branch', {'name': name, 'new_name': next},
        success: tr('已重命名为 ${next.trim()}', 'Renamed to ${next.trim()}'), worktree: false);
  }

  Future<void> delete(BuildContext context, String name) async {
    final result = await showDialog<bool>(context: context, builder: (_) => _DeleteBranchDialog(name: name));
    if (result == null || !context.mounted) return;
    await _run(context, tr('删除', 'Delete'), 'git.delete_branch', {'name': name, 'force': result},
        success: tr('已删除分支 $name', 'Deleted branch $name'), worktree: false);
  }

  /// 标题栏的冲突按钮:列出有冲突的文件,可以整个采用一侧、打开文件,或者(没有冲突了)完成合并。
  Future<void> showConflicts(BuildContext context) async {
    await showDialog<void>(
      context: context,
      builder: (_) => ConflictsDialog(
        store: store,
        accept: acceptSide,
        merge: mergeFile,
        finish: continueOperation,
        abort: abortOperation,
      ),
    );
  }

  /// 采用 [files] 里每个文件的 [side]('yours' / 'theirs')。有一个失败就停下并提示。
  Future<void> acceptSide(BuildContext context, List<ConflictFile> files, String side) async {
    final label = side == 'yours' ? tr('接受你的', 'Accept Yours') : tr('接受他们的', 'Accept Theirs');
    for (final f in files) {
      final err = await store.run(label, 'git.accept_side', {'path': f.path, 'side': side});
      if (err != null) {
        if (context.mounted) _toast(context, tr('$label失败(${f.path}): $err', '$label failed (${f.path}): $err'), error: true);
        return;
      }
    }
  }

  /// 冲突窗口的 Merge:打开三方合并窗口;Apply 写回结果并标记已解决,Accept Left / Right 整个采用一侧。
  Future<void> mergeFile(BuildContext context, ConflictFile file) async {
    final v = await store.call('git.merge_versions', {'path': file.path});
    if (!context.mounted) return;
    if (v['status'] != 'ok') {
      _toast(context, tr('读取 ${file.path} 的各个版本失败: ${v['error']}', 'Failed to read the versions of ${file.path}: ${v['error']}'), error: true);
      return;
    }
    final op = store.operation;
    final outcome = await showMergeWindow(
      context,
      path: file.path,
      base: v['base'] as String? ?? '',
      yours: v['yours'] as String? ?? '',
      theirs: v['theirs'] as String? ?? '',
      yoursTitle: op?.branch ?? store.current ?? tr('你的', 'Yours'),
      theirsTitle: (op?.kind == 'rebase' ? op?.onto : op?.incoming) ?? tr('他们的', 'Theirs'),
      // 右键行号 ▸ Annotate:那一侧来自的提交的逐行修改记录(时间、作者)
      loadBlame: (side) async => BlameData.fromResult(
        await store.call('git.merge_blame', {'path': file.path, 'side': side == MergeSide.left ? 'yours' : 'theirs'}),
        file.path,
      ),
    );
    if (outcome == null || !context.mounted) return;
    switch (outcome.kind) {
      case MergeOutcomeKind.apply:
        final err = await store.run(tr('合并', 'Merge'), 'git.resolve_with', {'path': file.path, 'content': outcome.content ?? ''});
        if (err != null && context.mounted) _toast(context, tr('保存 ${file.path} 失败: $err', 'Failed to save ${file.path}: $err'), error: true);
      case MergeOutcomeKind.acceptLeft:
        await acceptSide(context, [file], 'yours');
      case MergeOutcomeKind.acceptRight:
        await acceptSide(context, [file], 'theirs');
    }
  }

  /// 放弃进行中的合并 / 变基(标题栏的红色 ×)。会丢掉已经做的解决,所以先问一句。
  Future<bool> abortOperation(BuildContext context) async {
    final op = store.operation;
    if (op == null || !op.canAbort) return false;
    final ok = await _confirm(
      context,
      tr('中止${op.noun}', 'Abort ${op.noun}'),
      tr('放弃这次${_zh(op.kind)}?\n\n会执行 git ${op.kind} --abort:已经解决的冲突都会丢掉,工作区回到操作之前的状态。',
          'Abort this ${op.noun.toLowerCase()}?\n\nThis runs git ${op.kind} --abort: conflicts you have already resolved are lost and the working tree goes back to how it was before the operation.'),
      action: tr('中止${op.noun}', 'Abort ${op.noun}'),
    );
    if (!ok || !context.mounted) return false;
    return _run(context, tr('中止${op.noun}', 'Abort ${op.noun}'), 'git.abort_operation', const {},
        success: tr('已放弃${_zh(op.kind)}', '${op.noun} aborted'));
  }

  /// 冲突都解决后完成:合并 → 提交合并结果,变基 → 继续。
  Future<bool> continueOperation(BuildContext context) async {
    final op = store.operation;
    if (op == null || !op.canAbort) return false;
    return _run(context, tr('继续${op.noun}', 'Continue ${op.noun}'), 'git.continue_operation', const {},
        success: tr('${_zh(op.kind)}已完成', '${op.noun} completed'));
  }

  static String _zh(String? kind) => switch (kind) {
        'merge' => '合并',
        'rebase' => '变基',
        'cherry-pick' => '拣选',
        'revert' => '还原',
        _ => '操作',
      };

  Future<bool> _confirm(BuildContext context, String title, String message, {required String action}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: Text(title, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
        content: SizedBox(width: 420, child: Text(message, style: _text)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('取消', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<String?> _prompt(BuildContext context, {required String title, required String label, String initial = '', String? action}) {
    return showDialog<String>(
      context: context,
      builder: (_) => PromptDialog(title: title, label: label, initial: initial, action: action),
    );
  }
}

/// 单行输入对话框。输入框的控制器由对话框自己持有:关闭动画还在播的时候不能先释放它。
class PromptDialog extends StatefulWidget {
  const PromptDialog({super.key, required this.title, required this.label, this.initial = '', this.action});

  final String title;
  final String label;
  final String initial;

  /// 确定按钮上的字;为空时是「确定 / OK」。
  final String? action;

  @override
  State<PromptDialog> createState() => _PromptDialogState();
}

class _PromptDialogState extends State<PromptDialog> {
  late final TextEditingController _controller = TextEditingController(text: widget.initial);

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text(widget.title, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.label, style: _muted),
            const SizedBox(height: 8),
            TextField(
              controller: _controller,
              autofocus: true,
              style: _text,
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
              onSubmitted: (v) => Navigator.pop(context, v),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消', 'Cancel'))),
        FilledButton(onPressed: () => Navigator.pop(context, _controller.text), child: Text(widget.action ?? tr('确定', 'OK'))),
      ],
    );
  }
}

/// New Branch 对话框:分支名 + 是否马上切过去。
class NewBranchDialog extends StatefulWidget {
  const NewBranchDialog({super.key, this.startPoint});

  /// 从哪个分支出发;为空表示当前 HEAD。
  final String? startPoint;

  @override
  State<NewBranchDialog> createState() => _NewBranchDialogState();
}

class _NewBranchDialogState extends State<NewBranchDialog> {
  final _name = TextEditingController();
  bool _checkout = true;

  @override
  void dispose() {
    _name.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (name, _checkout));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text(tr('新建分支', 'New Branch'), style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
                widget.startPoint == null
                    ? tr('从当前位置(HEAD)创建', 'Create from the current position (HEAD)')
                    : tr("从 '${widget.startPoint}' 创建", "Create from '${widget.startPoint}'"),
                style: _muted),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              autofocus: true,
              style: _text,
              decoration: InputDecoration(border: const OutlineInputBorder(), isDense: true, hintText: tr('分支名,例如 feat/login', 'Branch name, e.g. feat/login')),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 4),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _checkout,
              onChanged: (v) => setState(() => _checkout = v ?? true),
              title: Text(tr('签出分支', 'Checkout branch'), style: _text),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消', 'Cancel'))),
        FilledButton(onPressed: _submit, child: Text(tr('创建', 'Create'))),
      ],
    );
  }
}

class _DeleteBranchDialog extends StatefulWidget {
  const _DeleteBranchDialog({required this.name});

  final String name;

  @override
  State<_DeleteBranchDialog> createState() => _DeleteBranchDialogState();
}

class _DeleteBranchDialogState extends State<_DeleteBranchDialog> {
  bool _force = false;

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text(tr("删除分支 '${widget.name}'", "Delete Branch '${widget.name}'"), style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(tr('只删除这个本地分支;还没合并的提交会丢失(除非别处还引用着它们)。', 'Deletes only this local branch; unmerged commits will be lost (unless something else still references them).'), style: _text),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _force,
              onChanged: (v) => setState(() => _force = v ?? false),
              title: Text(tr('即使有未合并的提交也删除', 'Delete even if it has unmerged commits'), style: _text),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: Text(tr('取消', 'Cancel'))),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: IntelliJTheme.gitRed),
          onPressed: () => Navigator.pop(context, _force),
          child: Text(tr('删除', 'Delete')),
        ),
      ],
    );
  }
}
