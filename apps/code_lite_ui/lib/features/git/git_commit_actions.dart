import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/platform/workspace_io.dart' as io;
import '../../core/theme/intellij_theme.dart';
import 'diff_view.dart';
import 'git_log_store.dart';
import '../notifications/notifications.dart';

const TextStyle _kText = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12.5);
const TextStyle _kMuted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

/// Log 里对单个提交的所有操作:右键菜单 + 各自的对话框。
///
/// 无状态的一次性对象 —— 每次用时以当前 context / store 构造,
/// 状态都在 [GitLogStore] 里,操作完成后由 store 刷新列表。
class GitCommitActions {
  GitCommitActions(this.context, this.store, {this.onGoTo});

  final BuildContext context;
  final GitLogStore store;

  /// 选中并滚动到某个提交(Go to Child / Parent)。
  final Future<void> Function(String hash)? onGoTo;

  // ---------------------------------------------------------------------------
  // 右键菜单
  // ---------------------------------------------------------------------------

  Future<void> showContextMenu(Offset position, GitCommit commit) async {
    final inHead = _isInHead(commit.hash);
    final isHead = commit.hash == store.headHash;
    final idle = store.busy == null;
    final children = store.childrenOf(commit.hash);

    final entries = <PopupMenuEntry<VoidCallback>>[
      _item('Copy Revision Number', Icons.copy, () => copyHash(commit.hash), shortcut: '⌥⇧⌘C'),
      _item('Create Patch...', Icons.add, () => createPatch(commit)),
      _item('Cherry-Pick', Icons.local_florist_outlined, idle && !inHead ? () => cherryPick(commit.hash) : null),
      const PopupMenuDivider(height: 9),
      _item('Checkout Revision', null, idle ? () => checkoutRevision(commit) : null),
      _item('Show Repository at Revision', null, () => showRepositoryAt(commit)),
      _item('Compare with Local', null, () => compareWithLocal(commit)),
      const PopupMenuDivider(height: 9),
      _item('Reset Current Branch to Here...', Icons.undo, idle && !store.detached ? () => resetTo(commit) : null),
      _item('Revert Commit', null, idle && inHead ? () => revert(commit) : null),
      _item('Undo Commit...', null, idle && isHead && commit.parents.isNotEmpty ? () => undoCommit(commit) : null),
      const PopupMenuDivider(height: 9),
      _item('Edit Commit Message...', null, idle && inHead ? () => editMessage(commit.hash) : null, shortcut: 'F2'),
      _item('Fixup...', null, idle && inHead ? () => fixup(commit) : null),
      _item('Squash Into...', null, idle && inHead ? () => squashInto(commit) : null),
      _item('Drop Commit', null, idle && inHead ? () => drop(commit) : null),
      _item('Interactively Rebase from Here...', null, idle && inHead ? () => interactiveRebase(commit) : null),
      _item('Push All up to Here...', null, idle && inHead && !store.detached ? () => pushUpTo(commit) : null),
      const PopupMenuDivider(height: 9),
      _item('New Branch...', null, idle ? () => newBranch(commit) : null),
      _item('New Tag...', null, idle ? () => newTag(commit) : null),
      const PopupMenuDivider(height: 9),
      _item('Go to Child Commit', null, children.isEmpty ? null : () => onGoTo?.call(children.first), shortcut: '←'),
      _item(
        'Go to Parent Commit',
        null,
        commit.parents.isEmpty ? null : () => onGoTo?.call(commit.parents.first),
        shortcut: '→',
      ),
    ];
    final action = await showMenu<VoidCallback>(
      context: context,
      position: RelativeRect.fromLTRB(position.dx, position.dy, position.dx + 1, position.dy + 1),
      color: IntelliJTheme.panelBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(8),
        side: const BorderSide(color: IntelliJTheme.border),
      ),
      constraints: const BoxConstraints(minWidth: 300),
      items: entries,
    );
    action?.call();
  }

  PopupMenuItem<VoidCallback> _item(String label, IconData? icon, VoidCallback? onTap, {String? shortcut}) {
    final enabled = onTap != null;
    final color = enabled ? IntelliJTheme.textHigh : IntelliJTheme.textMuted.withValues(alpha: 0.6);
    return PopupMenuItem<VoidCallback>(
      value: onTap,
      enabled: enabled,
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      child: Row(
        children: [
          SizedBox(width: 20, child: icon == null ? null : Icon(icon, size: 14, color: color)),
          Expanded(child: Text(label, style: TextStyle(color: color, fontSize: 13))),
          if (shortcut != null) Text(shortcut, style: _kMuted),
        ],
      ),
    );
  }

  /// 提交是否在当前 HEAD 的历史里(只看已加载的提交)。改写历史类操作只对这些提交有意义;
  /// Rust 侧还会再用 `merge-base --is-ancestor` 校验一次。
  bool _isInHead(String hash) {
    final head = store.headHash;
    if (head.isEmpty) return false;
    final seen = <String>{};
    final stack = [head];
    while (stack.isNotEmpty) {
      final h = stack.removeLast();
      if (h == hash) return true;
      if (!seen.add(h)) continue;
      final c = store.commit(h);
      if (c != null) stack.addAll(c.parents);
    }
    return false;
  }

  // ---------------------------------------------------------------------------
  // 操作
  // ---------------------------------------------------------------------------

  void _toast(String message, {bool error = false}) {
    showNotice(context, message, error: error);
  }

  Future<void> _run(String label, String method, Map<String, dynamic> params, {String? success}) async {
    final err = await store.run(label, method, params);
    if (err != null) {
      _toast(err, error: true);
    } else if (success != null) {
      _toast(success);
    }
  }

  Future<void> copyHash(String hash) async {
    await Clipboard.setData(ClipboardData(text: hash));
    _toast('已复制 $hash');
  }

  Future<void> cherryPick(String hash) => _run('Cherry-Pick', 'git.cherry_pick', {'hash': hash}, success: 'Cherry-pick 完成');

  Future<void> checkoutRevision(GitCommit c) async {
    final ok = await _confirm(
      'Checkout Revision',
      '签出 ${c.short} 后会处于 detached HEAD 状态,之后的提交不属于任何分支。继续吗?',
      action: 'Checkout',
    );
    if (ok) await _run('Checkout', 'git.checkout_revision', {'hash': c.hash}, success: '已签出 ${c.short}');
  }

  Future<void> revert(GitCommit c) =>
      _run('Revert', 'git.revert', {'hash': c.hash}, success: '已生成撤销 ${c.short} 的提交');

  Future<void> undoCommit(GitCommit c) async {
    final ok = await _confirm(
      'Undo Commit',
      '撤销最近一次提交「${c.subject}」,其改动会保留为已暂存的修改。',
      action: 'Undo',
    );
    if (ok) await _run('Undo Commit', 'git.undo_commit', const {}, success: '已撤销提交');
  }

  Future<void> resetTo(GitCommit c) async {
    final mode = await showDialog<String>(context: context, builder: (_) => _ResetDialog(commit: c, branch: store.currentBranch));
    if (mode == null) return;
    await _run('Reset', 'git.reset', {'hash': c.hash, 'mode': mode}, success: '已 $mode reset 到 ${c.short}');
  }

  /// 改写历史前的提醒:提交已推送时,改写后需要强制推送。
  Future<bool> _guardRewrite(String hash, String what) async {
    final res = await store.call('git.is_pushed', {'hash': hash});
    if (res['pushed'] != true) return true;
    return _confirm(
      what,
      '这个提交已经推送到远程。改写历史后本地与远程分叉,需要强制推送,可能影响其他协作者。仍然继续吗?',
      action: '继续',
      danger: true,
    );
  }

  Future<void> editMessage(String hash) async {
    final res = await store.call('git.commit_details', {'hash': hash});
    if (res['status'] != 'ok') return _toast(res['error'] as String? ?? '读取提交失败', error: true);
    if (!await _guardRewrite(hash, 'Edit Commit Message')) return;
    final message = await promptText(
      title: 'Edit Commit Message',
      label: hash.substring(0, 8),
      initial: res['message'] as String? ?? '',
      multiline: true,
      action: 'OK',
    );
    if (message == null || message.trim().isEmpty) return;
    await _run('Edit Commit Message', 'git.reword', {'hash': hash, 'message': message.trim()}, success: '提交信息已修改');
  }

  Future<void> fixup(GitCommit c) async {
    if (!await _guardRewrite(c.hash, 'Fixup')) return;
    final ok = await _confirm(
      'Fixup',
      '把当前已暂存的修改合并进「${c.subject}」,保留它原来的提交信息。',
      action: 'Fixup',
    );
    if (ok) await _run('Fixup', 'git.fixup', {'hash': c.hash}, success: '已合并进 ${c.short}');
  }

  Future<void> squashInto(GitCommit c) async {
    if (!await _guardRewrite(c.hash, 'Squash Into')) return;
    final res = await store.call('git.commit_details', {'hash': c.hash});
    final message = await promptText(
      title: 'Squash Into ${c.short}',
      label: '把当前已暂存的修改合并进这个提交,并使用下面的提交信息',
      initial: res['message'] as String? ?? c.subject,
      multiline: true,
      action: 'Squash',
    );
    if (message == null || message.trim().isEmpty) return;
    await _run('Squash', 'git.squash_into', {'hash': c.hash, 'message': message.trim()}, success: '已合并进 ${c.short}');
  }

  Future<void> drop(GitCommit c) async {
    if (!await _guardRewrite(c.hash, 'Drop Commit')) return;
    final ok = await _confirm('Drop Commit', '从历史中删除提交「${c.subject}」?', action: 'Drop', danger: true);
    if (ok) await _run('Drop', 'git.drop', {'hash': c.hash}, success: '已删除 ${c.short}');
  }

  Future<void> interactiveRebase(GitCommit c) async {
    final plan = await store.call('git.rebase_plan', {'hash': c.hash});
    if (plan['status'] != 'ok') return _toast(plan['error'] as String? ?? '无法生成 rebase 计划', error: true);
    if (!await _guardRewrite(c.hash, 'Interactive Rebase')) return;
    if (!context.mounted) return;
    final entries = [
      for (final e in (plan['entries'] as List? ?? const []))
        _RebaseEntry(e['hash'] as String, e['subject'] as String? ?? '', e['message'] as String? ?? ''),
    ];
    final result = await showDialog<List<_RebaseEntry>>(
      context: context,
      builder: (_) => _InteractiveRebaseDialog(entries: entries, base: c),
    );
    if (result == null) return;
    await _run(
      'Rebase',
      'git.rebase_interactive',
      {
        'base': plan['base'],
        'entries': [
          for (final e in result)
            {
              'hash': e.hash,
              'action': e.action,
              if (e.editedMessage != null) 'message': e.editedMessage,
            },
        ],
      },
      success: 'Rebase 完成',
    );
  }

  Future<void> pushUpTo(GitCommit c) async {
    final local = store.localBranches.where((b) => b.current).firstOrNull;
    final target = local?.upstream ?? 'origin/${store.currentBranch}';
    final ok = await _confirm(
      'Push All up to Here',
      '把 ${c.short} 及之前的所有提交推送到 $target?',
      action: 'Push',
    );
    if (!ok) return;
    final err = await store.run('Push', 'git.push_up_to', {'hash': c.hash});
    _toast(err ?? '已推送到 $target', error: err != null);
  }

  Future<void> newBranch(GitCommit c) async {
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => _NewBranchDialog(commit: c),
    );
    if (result == null) return;
    final (name, checkout) = result;
    await _run('New Branch', 'git.new_branch', {'name': name, 'hash': c.hash, 'checkout': checkout},
        success: checkout ? '已创建并切换到 $name' : '已创建分支 $name');
  }

  Future<void> newTag(GitCommit c) async {
    final result = await showDialog<(String, String)>(context: context, builder: (_) => _NewTagDialog(commit: c));
    if (result == null) return;
    final (name, message) = result;
    await _run('New Tag', 'git.new_tag', {'name': name, 'hash': c.hash, if (message.isNotEmpty) 'message': message},
        success: '已创建标签 $name');
  }

  Future<void> goToRevision() async {
    final rev = await promptText(title: 'Go to Hash/Branch/Tag', label: '输入提交哈希、分支名或标签名');
    if (rev == null || rev.trim().isEmpty) return;
    // 任意修订名(哈希 / 分支 / 标签)都可以当 log 的起点,取第一条就是它本身。
    final res = await store.call('git.log', {'branch': rev.trim(), 'limit': 1});
    final commits = res['commits'] as List?;
    final hash = commits == null || commits.isEmpty ? null : commits.first['hash'] as String?;
    if (hash == null || !await store.reveal(hash)) {
      _toast('找不到 ${rev.trim()}(或它不在当前筛选结果中)', error: true);
    }
  }

  // --- 只读查看 -------------------------------------------------------------

  Future<void> showCommitFileDiff(String hash, GitFileChange change) async {
    final res = await store.call('git.commit_file_diff', {
      'hash': hash,
      'path': change.path,
      if (change.oldPath != null) 'old_path': change.oldPath,
    });
    if (res['status'] != 'ok') return _toast(res['error'] as String? ?? '读取 diff 失败', error: true);
    if (!context.mounted) return;
    await _showPanel(
      title: '${change.path}  (${hash.substring(0, 8)})',
      child: DiffView(diff: res['diff'] as String? ?? ''),
    );
  }

  Future<void> createPatch(GitCommit c) async {
    final res = await store.call('git.create_patch', {'hash': c.hash});
    if (res['status'] != 'ok') return _toast(res['error'] as String? ?? '生成 patch 失败', error: true);
    final patch = res['patch'] as String? ?? '';
    if (!context.mounted) return;
    await _showPanel(
      title: 'Create Patch — ${c.short}',
      child: DiffView(diff: patch),
      actions: [
        TextButton(
          onPressed: () async {
            await Clipboard.setData(ClipboardData(text: patch));
            _toast('Patch 已复制到剪贴板');
          },
          child: const Text('Copy to Clipboard'),
        ),
        TextButton(
          onPressed: () async {
            final name = '${c.short}-${c.subject.replaceAll(RegExp(r'[^\w一-鿿-]+'), '-')}';
            final path = await io.pickSavePath('${name.length > 60 ? name.substring(0, 60) : name}.patch');
            if (path == null) return;
            final err = await io.writeTextFile(path, patch);
            _toast(err == null ? '已保存到 $path' : '保存失败: $err', error: err != null);
          },
          child: const Text('Save...'),
        ),
      ],
    );
  }

  Future<void> compareWithLocal(GitCommit c) async {
    final res = await store.call('git.compare_local', {'hash': c.hash});
    if (res['status'] != 'ok') return _toast(res['error'] as String? ?? '比较失败', error: true);
    final files = [for (final f in (res['files'] as List? ?? const [])) GitFileChange.fromJson(f as Map<String, dynamic>)];
    if (!context.mounted) return;
    await _showPanel(
      title: 'Compare ${c.short} with Local — ${files.length} files',
      child: _FileBrowser(
        paths: [for (final f in files) f.path],
        statuses: {for (final f in files) f.path: f.status},
        load: (path) async {
          final d = await store.call('git.compare_local_diff', {'hash': c.hash, 'path': path});
          return DiffView(diff: d['diff'] as String? ?? (d['error'] as String? ?? ''));
        },
      ),
    );
  }

  Future<void> showRepositoryAt(GitCommit c) async {
    final res = await store.call('git.tree_at', {'hash': c.hash});
    if (res['status'] != 'ok') return _toast(res['error'] as String? ?? '读取文件树失败', error: true);
    final paths = [for (final p in (res['paths'] as List? ?? const [])) p as String];
    if (!context.mounted) return;
    await _showPanel(
      title: 'Repository at ${c.short} — ${c.subject}',
      child: _FileBrowser(
        paths: paths,
        load: (path) async {
          final f = await store.call('git.file_at', {'hash': c.hash, 'path': path});
          if (f['binary'] == true) return const Center(child: Text('二进制文件', style: _kMuted));
          return PlainTextView(text: f['content'] as String? ?? (f['error'] as String? ?? ''));
        },
      ),
    );
  }

  // --- 对话框基础件 ---------------------------------------------------------

  Future<void> _showPanel({required String title, required Widget child, List<Widget> actions = const []}) {
    final size = MediaQuery.sizeOf(context);
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: IntelliJTheme.panelBg,
        insetPadding: const EdgeInsets.all(32),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(8), side: const BorderSide(color: IntelliJTheme.border)),
        child: SizedBox(
          width: size.width * 0.8,
          height: size.height * 0.75,
          child: Column(
            children: [
              Container(
                height: 36,
                padding: const EdgeInsets.only(left: 14, right: 6),
                decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle))),
                child: Row(
                  children: [
                    Expanded(
                      child: Text(title, overflow: TextOverflow.ellipsis, style: _kText.copyWith(color: IntelliJTheme.textHigh)),
                    ),
                    ...actions,
                    IconButton(
                      icon: const Icon(Icons.close, size: 16, color: IntelliJTheme.textSecondary),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Expanded(child: child),
            ],
          ),
        ),
      ),
    );
  }

  Future<bool> _confirm(String title, String message, {required String action, bool danger = false}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: Text(title, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
        content: SizedBox(width: 420, child: Text(message, style: _kText)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: danger ? FilledButton.styleFrom(backgroundColor: IntelliJTheme.gitRed) : null,
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(action),
          ),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<String?> promptText({
    required String title,
    required String label,
    String initial = '',
    bool multiline = false,
    String action = 'OK',
  }) {
    final controller = TextEditingController(text: initial);
    return showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: Text(title, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
        content: SizedBox(
          width: 520,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(label, style: _kMuted),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                autofocus: true,
                minLines: multiline ? 6 : 1,
                maxLines: multiline ? 14 : 1,
                style: _kText.copyWith(fontFamily: multiline ? 'Menlo' : null),
                decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true),
                onSubmitted: multiline ? null : (v) => Navigator.pop(ctx, v),
              ),
            ],
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: Text(action)),
        ],
      ),
    ).whenComplete(controller.dispose);
  }
}

// ---------------------------------------------------------------------------
// 对话框
// ---------------------------------------------------------------------------

class _ResetDialog extends StatefulWidget {
  const _ResetDialog({required this.commit, required this.branch});

  final GitCommit commit;
  final String? branch;

  @override
  State<_ResetDialog> createState() => _ResetDialogState();
}

class _ResetDialogState extends State<_ResetDialog> {
  String _mode = 'mixed';

  static const _modes = [
    ('soft', 'Soft', '保留工作区和暂存区:被撤掉的提交的改动变为已暂存。'),
    ('mixed', 'Mixed', '保留工作区,重置暂存区:改动变为未暂存。'),
    ('hard', 'Hard', '丢弃工作区和暂存区的所有改动。不可恢复!'),
  ];

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text('Reset ${widget.branch ?? 'HEAD'} to ${widget.commit.short}',
          style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 460,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.commit.subject, style: _kMuted, overflow: TextOverflow.ellipsis),
            const SizedBox(height: 10),
            for (final (value, label, desc) in _modes)
              RadioListTile<String>(
                value: value,
                groupValue: _mode,
                dense: true,
                contentPadding: EdgeInsets.zero,
                onChanged: (v) => setState(() => _mode = v!),
                title: Text(label, style: _kText.copyWith(color: value == 'hard' ? IntelliJTheme.gitRed : null)),
                subtitle: Text(desc, style: _kMuted),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: _mode == 'hard' ? FilledButton.styleFrom(backgroundColor: IntelliJTheme.gitRed) : null,
          onPressed: () => Navigator.pop(context, _mode),
          child: const Text('Reset'),
        ),
      ],
    );
  }
}

class _NewBranchDialog extends StatefulWidget {
  const _NewBranchDialog({required this.commit});

  final GitCommit commit;

  @override
  State<_NewBranchDialog> createState() => _NewBranchDialogState();
}

class _NewBranchDialogState extends State<_NewBranchDialog> {
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
      title: Text('Create Branch from ${widget.commit.short}', style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              style: _kText,
              decoration: const InputDecoration(labelText: 'New branch name', border: OutlineInputBorder(), isDense: true),
              onSubmitted: (_) => _submit(),
            ),
            CheckboxListTile(
              value: _checkout,
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              title: const Text('Checkout branch', style: _kText),
              onChanged: (v) => setState(() => _checkout = v ?? true),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

class _NewTagDialog extends StatefulWidget {
  const _NewTagDialog({required this.commit});

  final GitCommit commit;

  @override
  State<_NewTagDialog> createState() => _NewTagDialogState();
}

class _NewTagDialogState extends State<_NewTagDialog> {
  final _name = TextEditingController();
  final _message = TextEditingController();

  @override
  void dispose() {
    _name.dispose();
    _message.dispose();
    super.dispose();
  }

  void _submit() {
    final name = _name.text.trim();
    if (name.isEmpty) return;
    Navigator.pop(context, (name, _message.text.trim()));
  }

  @override
  Widget build(BuildContext context) {
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text('Create Tag on ${widget.commit.short}', style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            TextField(
              controller: _name,
              autofocus: true,
              style: _kText,
              decoration: const InputDecoration(labelText: 'Tag name', border: OutlineInputBorder(), isDense: true),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _message,
              style: _kText,
              minLines: 2,
              maxLines: 5,
              decoration: const InputDecoration(
                labelText: 'Message(可选,填写则创建附注标签)',
                border: OutlineInputBorder(),
                isDense: true,
              ),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: _submit, child: const Text('Create')),
      ],
    );
  }
}

class _RebaseEntry {
  _RebaseEntry(this.hash, this.subject, this.message);

  final String hash;
  final String subject;
  final String message;
  String action = 'pick';

  /// reword / squash 时用户写的新信息;null 表示不改。
  String? editedMessage;
}

/// IntelliJ 的交互式 rebase 对话框:拖动排序,每条选 pick / reword / squash / fixup / drop。
class _InteractiveRebaseDialog extends StatefulWidget {
  const _InteractiveRebaseDialog({required this.entries, required this.base});

  final List<_RebaseEntry> entries;
  final GitCommit base;

  @override
  State<_InteractiveRebaseDialog> createState() => _InteractiveRebaseDialogState();
}

class _InteractiveRebaseDialogState extends State<_InteractiveRebaseDialog> {
  late final List<_RebaseEntry> _entries = [...widget.entries];

  static const _actions = ['pick', 'reword', 'squash', 'fixup', 'drop'];

  static Color _actionColor(String a) => switch (a) {
        'reword' => IntelliJTheme.accentBlue,
        'squash' || 'fixup' => IntelliJTheme.accentYellow,
        'drop' => IntelliJTheme.gitRed,
        _ => IntelliJTheme.textSecondary,
      };

  /// 第一条之前没有可以合并进去的提交。
  String? get _error {
    final kept = _entries.where((e) => e.action != 'drop').toList();
    if (kept.isEmpty) return null;
    if (kept.first.action == 'squash' || kept.first.action == 'fixup') {
      return '第一条保留的提交不能是 ${kept.first.action}(它之前没有可以合并进去的提交)';
    }
    return null;
  }

  Future<void> _editMessage(_RebaseEntry e) async {
    final controller = TextEditingController(text: e.editedMessage ?? e.message);
    final value = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: Text('Reword ${e.hash.substring(0, 8)}', style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
        content: SizedBox(
          width: 500,
          child: TextField(
            controller: controller,
            autofocus: true,
            minLines: 6,
            maxLines: 14,
            style: _kText.copyWith(fontFamily: 'Menlo'),
            decoration: const InputDecoration(border: OutlineInputBorder()),
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, controller.text), child: const Text('OK')),
        ],
      ),
    );
    controller.dispose();
    if (value == null || value.trim().isEmpty) return;
    setState(() {
      e.editedMessage = value.trim();
      if (e.action == 'pick') e.action = 'reword';
    });
  }

  @override
  Widget build(BuildContext context) {
    final error = _error;
    return AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: Text(
        'Rebasing ${_entries.length} commits from ${widget.base.short}',
        style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15),
      ),
      content: SizedBox(
        width: 640,
        height: 380,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            const Text('拖动调整顺序(上面的先应用);双击提交编辑信息。', style: _kMuted),
            const SizedBox(height: 8),
            Expanded(
              child: Container(
                decoration: BoxDecoration(border: Border.all(color: IntelliJTheme.border), borderRadius: BorderRadius.circular(4)),
                child: ReorderableListView.builder(
                  buildDefaultDragHandles: false,
                  itemCount: _entries.length,
                  onReorder: (from, to) => setState(() {
                    if (to > from) to--;
                    _entries.insert(to, _entries.removeAt(from));
                  }),
                  itemBuilder: (context, i) {
                    final e = _entries[i];
                    final dropped = e.action == 'drop';
                    return Container(
                      key: ValueKey(e.hash),
                      height: 32,
                      color: IntelliJTheme.editorBg,
                      child: Row(
                        children: [
                          ReorderableDragStartListener(
                            index: i,
                            child: const Padding(
                              padding: EdgeInsets.symmetric(horizontal: 6),
                              child: Icon(Icons.drag_indicator, size: 16, color: IntelliJTheme.textMuted),
                            ),
                          ),
                          SizedBox(
                            width: 92,
                            child: DropdownButton<String>(
                              value: e.action,
                              isDense: true,
                              underline: const SizedBox.shrink(),
                              dropdownColor: IntelliJTheme.panelBg,
                              items: [
                                for (final a in _actions)
                                  DropdownMenuItem(value: a, child: Text(a, style: _kText.copyWith(color: _actionColor(a)))),
                              ],
                              onChanged: (v) {
                                if (v == null) return;
                                if (v == 'reword' && e.editedMessage == null) {
                                  _editMessage(e);
                                } else {
                                  setState(() => e.action = v);
                                }
                              },
                            ),
                          ),
                          Text(e.hash.substring(0, 8), style: _kMuted.copyWith(fontFamily: 'Menlo')),
                          const SizedBox(width: 10),
                          Expanded(
                            child: GestureDetector(
                              onDoubleTap: () => _editMessage(e),
                              child: Text(
                                (e.editedMessage ?? e.subject).split('\n').first,
                                overflow: TextOverflow.ellipsis,
                                style: _kText.copyWith(
                                  decoration: dropped ? TextDecoration.lineThrough : null,
                                  color: dropped ? IntelliJTheme.textMuted : (e.editedMessage != null ? IntelliJTheme.accentBlue : null),
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            tooltip: '编辑信息',
                            icon: const Icon(Icons.edit_outlined, size: 14, color: IntelliJTheme.textMuted),
                            onPressed: () => _editMessage(e),
                          ),
                        ],
                      ),
                    );
                  },
                ),
              ),
            ),
            if (error != null) ...[
              const SizedBox(height: 6),
              Text(error, style: _kMuted.copyWith(color: IntelliJTheme.gitRed)),
            ],
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          onPressed: error == null ? () => Navigator.pop(context, _entries) : null,
          child: const Text('Start Rebasing'),
        ),
      ],
    );
  }
}

/// 左边文件列表、右边内容的浏览器(Compare with Local / Show Repository at Revision)。
class _FileBrowser extends StatefulWidget {
  const _FileBrowser({required this.paths, required this.load, this.statuses = const {}});

  final List<String> paths;
  final Map<String, String> statuses;
  final Future<Widget> Function(String path) load;

  @override
  State<_FileBrowser> createState() => _FileBrowserState();
}

class _FileBrowserState extends State<_FileBrowser> {
  String? _selected;
  final Map<String, Future<Widget>> _loaded = {};
  String _query = '';

  @override
  Widget build(BuildContext context) {
    final q = _query.toLowerCase();
    final visible = q.isEmpty ? widget.paths : widget.paths.where((p) => p.toLowerCase().contains(q)).toList();
    return Row(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        SizedBox(
          width: 320,
          child: Column(
            children: [
              Padding(
                padding: const EdgeInsets.all(6),
                child: TextField(
                  style: _kText,
                  decoration: const InputDecoration(
                    isDense: true,
                    prefixIcon: Icon(Icons.search, size: 14),
                    hintText: '筛选文件',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
              Expanded(
                child: visible.isEmpty
                    ? const Center(child: Text('没有文件', style: _kMuted))
                    : ListView.builder(
                        itemExtent: 24,
                        itemCount: visible.length,
                        itemBuilder: (context, i) {
                          final p = visible[i];
                          final status = widget.statuses[p];
                          return InkWell(
                            onTap: () => setState(() => _selected = p),
                            child: Container(
                              color: _selected == p ? IntelliJTheme.selectionBg : null,
                              padding: const EdgeInsets.symmetric(horizontal: 10),
                              alignment: Alignment.centerLeft,
                              child: Row(
                                children: [
                                  if (status != null)
                                    SizedBox(width: 16, child: Text(status, style: _kMuted.copyWith(fontFamily: 'Menlo'))),
                                  Expanded(child: Text(p, overflow: TextOverflow.ellipsis, style: _kText)),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
        const VerticalDivider(width: 1, color: IntelliJTheme.borderSubtle),
        Expanded(
          child: _selected == null
              ? const Center(child: Text('选择左侧文件', style: _kMuted))
              : FutureBuilder<Widget>(
                  key: ValueKey(_selected),
                  // 缓存:在筛选框里打字会重建本组件,不该每次都重新跑 git。
                  future: _loaded.putIfAbsent(_selected!, () => widget.load(_selected!)),
                  builder: (context, snap) => snap.data ?? const Center(child: Text('加载中…', style: _kMuted)),
                ),
        ),
      ],
    );
  }
}
