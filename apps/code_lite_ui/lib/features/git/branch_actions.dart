// 标题栏分支菜单里的操作:Update / Push / New Branch / Checkout / Merge / Rebase / Rename / Delete。
// 做事的是 BranchStore.run(后台跑 git、完成后重新加载并通知);这里只管弹对话框、问清楚、给提示。

import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';
import 'branch_store.dart';

const TextStyle _text = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

class BranchActions {
  BranchActions(this.store, {required this.showCommitWindow});

  final BranchStore store;

  /// Commit…:打开左侧的 Commit 工具窗。
  final VoidCallback showCommitWindow;

  void _toast(BuildContext context, String message, {bool error = false}) {
    if (!context.mounted) return;
    final messenger = ScaffoldMessenger.maybeOf(context);
    // 新提示直接顶掉还在显示的旧提示,不排队等它
    messenger?.hideCurrentSnackBar();
    messenger?.showSnackBar(SnackBar(
      content: Text(message),
      backgroundColor: error ? const Color(0xFF5E2B2E) : null,
      duration: Duration(seconds: error ? 8 : 3),
    ));
  }

  /// 跑一个操作,成功 / 失败都给提示。成功返回 true。
  Future<bool> _run(BuildContext context, String label, String method, Map<String, dynamic> params,
      {String? success, bool worktree = true}) async {
    final err = await store.run(label, method, params, worktree);
    if (!context.mounted) return err == null; // 窗口已经没了,不必再提示
    if (err != null) {
      _toast(context, '$label 失败: $err', error: true);
      return false;
    }
    if (success != null) _toast(context, success);
    return true;
  }

  Future<void> update(BuildContext context) async {
    final ok = await _run(context, 'Update', 'git.update', const {});
    if (!ok || !context.mounted) return;
    final out = ((store.lastResult['output'] as String?) ?? '').trim();
    _toast(context, out.isEmpty ? '已更新' : '已更新: ${out.split('\n').map((l) => l.trim()).where((l) => l.isNotEmpty).lastOrNull ?? out}');
  }

  Future<void> push(BuildContext context) async {
    final ok = await _run(context, 'Push', 'git.push', const {}, worktree: false);
    if (!ok || !context.mounted) return;
    final r = store.lastResult;
    _toast(context, '已推送 ${r['branch']} 到 ${r['remote']}${r['set_upstream'] == true ? '(并设为上游)' : ''}');
  }

  Future<void> checkout(BuildContext context, String revision) async {
    final ok = await _run(context, 'Checkout', 'git.checkout', {'name': revision});
    if (ok && context.mounted) _toast(context, '已切换到 ${store.lastResult['branch'] ?? revision}');
  }

  /// New Branch…:[from] 为空时从当前 HEAD 出发。
  Future<void> newBranch(BuildContext context, {String? from}) async {
    final result = await showDialog<(String, bool)>(
      context: context,
      builder: (_) => NewBranchDialog(startPoint: from),
    );
    if (result == null || !context.mounted) return;
    final (name, checkout) = result;
    await _run(context, 'New Branch', 'git.new_branch', {'name': name, 'hash': from ?? 'HEAD', 'checkout': checkout},
        success: checkout ? '已创建并切换到 $name' : '已创建分支 $name', worktree: checkout);
  }

  Future<void> checkoutRevision(BuildContext context) async {
    final rev = await _prompt(context, title: 'Checkout Tag or Revision', label: '输入标签、分支名或提交哈希', action: 'Checkout');
    if (rev == null || rev.trim().isEmpty || !context.mounted) return;
    final ok = await _run(context, 'Checkout', 'git.checkout_revision', {'hash': rev.trim()});
    if (ok && context.mounted) _toast(context, '已签出 ${rev.trim()}(游离 HEAD)');
  }

  Future<void> merge(BuildContext context, String revision) async {
    final into = store.current ?? 'HEAD';
    final ok = await _confirm(context, 'Merge', "把 '$revision' 合并进 '$into'?", action: 'Merge');
    if (!ok || !context.mounted) return;
    await _run(context, 'Merge', 'git.merge', {'name': revision}, success: "已把 '$revision' 合并进 '$into'");
  }

  Future<void> rebase(BuildContext context, String revision) async {
    final current = store.current;
    if (current == null) return;
    final ok = await _confirm(
      context,
      'Rebase',
      "把 '$current' 变基到 '$revision' 上?\n\n这会改写 '$current' 上的提交;如果已经推送过,之后需要强制推送。",
      action: 'Rebase',
    );
    if (!ok || !context.mounted) return;
    await _run(context, 'Rebase', 'git.rebase_onto', {'name': revision}, success: "已把 '$current' 变基到 '$revision'");
  }

  Future<void> rename(BuildContext context, String name) async {
    final next = await _prompt(context, title: "Rename Branch '$name'", label: '新的分支名', initial: name, action: 'Rename');
    if (next == null || next.trim() == name || !context.mounted) return;
    await _run(context, 'Rename', 'git.rename_branch', {'name': name, 'new_name': next},
        success: '已重命名为 ${next.trim()}', worktree: false);
  }

  Future<void> delete(BuildContext context, String name) async {
    final result = await showDialog<bool>(context: context, builder: (_) => _DeleteBranchDialog(name: name));
    if (result == null || !context.mounted) return;
    await _run(context, 'Delete', 'git.delete_branch', {'name': name, 'force': result},
        success: '已删除分支 $name', worktree: false);
  }

  Future<bool> _confirm(BuildContext context, String title, String message, {required String action}) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: Text(title, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
        content: SizedBox(width: 420, child: Text(message, style: _text)),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(action)),
        ],
      ),
    );
    return ok ?? false;
  }

  Future<String?> _prompt(BuildContext context, {required String title, required String label, String initial = '', String action = 'OK'}) {
    return showDialog<String>(
      context: context,
      builder: (_) => PromptDialog(title: title, label: label, initial: initial, action: action),
    );
  }
}

/// 单行输入对话框。输入框的控制器由对话框自己持有:关闭动画还在播的时候不能先释放它。
class PromptDialog extends StatefulWidget {
  const PromptDialog({super.key, required this.title, required this.label, this.initial = '', this.action = 'OK'});

  final String title;
  final String label;
  final String initial;
  final String action;

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
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(onPressed: () => Navigator.pop(context, _controller.text), child: Text(widget.action)),
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
      title: const Text('New Branch', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(widget.startPoint == null ? '从当前位置(HEAD)创建' : "从 '${widget.startPoint}' 创建", style: _muted),
            const SizedBox(height: 8),
            TextField(
              controller: _name,
              autofocus: true,
              style: _text,
              decoration: const InputDecoration(border: OutlineInputBorder(), isDense: true, hintText: '分支名,例如 feat/login'),
              onSubmitted: (_) => _submit(),
            ),
            const SizedBox(height: 4),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _checkout,
              onChanged: (v) => setState(() => _checkout = v ?? true),
              title: const Text('Checkout branch', style: _text),
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
      title: Text("Delete Branch '${widget.name}'", style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 420,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text('只删除这个本地分支;还没合并的提交会丢失(除非别处还引用着它们)。', style: _text),
            CheckboxListTile(
              dense: true,
              contentPadding: EdgeInsets.zero,
              controlAffinity: ListTileControlAffinity.leading,
              value: _force,
              onChanged: (v) => setState(() => _force = v ?? false),
              title: const Text('即使有未合并的提交也删除', style: _text),
            ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancel')),
        FilledButton(
          style: FilledButton.styleFrom(backgroundColor: IntelliJTheme.gitRed),
          onPressed: () => Navigator.pop(context, _force),
          child: const Text('Delete'),
        ),
      ],
    );
  }
}
