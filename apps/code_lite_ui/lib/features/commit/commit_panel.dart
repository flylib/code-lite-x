import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/client/api_client.dart';
import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';
import 'stash_panel.dart';
import '../tool_window/tool_window_actions.dart';
import '../notifications/notifications.dart';

const TextStyle _kText =
    TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12.5);
const TextStyle _kMuted =
    TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

/// IntelliJ 的 Commit 工具窗(左侧):Commit | Stash 两个标签。
///
/// Commit 标签:勾选即暂存,点文件在编辑区打开「Commit: 文件名」差异,双击打开源文件;
/// 底部 Amend、提交信息历史、提交。路径一律相对仓库根(git status 的口径)。
class CommitPanel extends StatefulWidget {
  const CommitPanel({
    super.key,
    required this.client,
    required this.onOpenDiff,
    required this.onOpenFile,
    required this.onCommitted,
    this.onFilesReverted,
  });

  final ApiClient client;

  /// 点文件:打开差异标签。参数是相对仓库根的路径。
  final ValueChanged<String> onOpenDiff;

  /// 双击文件:打开源文件。参数是相对项目的路径。
  final ValueChanged<String> onOpenFile;

  /// 提交 / stash 等改动了仓库:通知 Git Log 刷新。
  final VoidCallback onCommitted;

  /// Rollback 之后,已在编辑器里打开的这些文件(相对项目路径)需要从磁盘重新载入。
  final ValueChanged<List<String>>? onFilesReverted;

  @override
  State<CommitPanel> createState() => _CommitPanelState();
}

class _CommitPanelState extends State<CommitPanel> {
  final TextEditingController _message = TextEditingController();
  int _tab = 0; // 0 = Commit, 1 = Stash
  List<Map<String, dynamic>> _changes = const [];
  String _prefix = '';
  final Set<String> _selected = {};
  final Set<String> _collapsed = {};
  bool _amend = false;
  bool _committing = false;

  StreamSubscription<String>? _savedSub;
  AppLifecycleListener? _lifecycle;
  Timer? _refreshDebounce;

  @override
  void initState() {
    super.initState();
    _refresh();
    // 文件保存 / 「>>」恢复后改动列表要跟着变;切回应用时也刷新一次(终端里改的文件)。
    _savedSub = widget.client.onFileSaved.listen((_) => _scheduleRefresh());
    _lifecycle = AppLifecycleListener(onResume: _scheduleRefresh);
  }

  @override
  void dispose() {
    _savedSub?.cancel();
    _lifecycle?.dispose();
    _refreshDebounce?.cancel();
    _message.dispose();
    super.dispose();
  }

  /// 连续保存多个文件时合并成一次 git status。
  void _scheduleRefresh() {
    _refreshDebounce?.cancel();
    _refreshDebounce = Timer(const Duration(milliseconds: 250), _refresh);
  }

  Future<void> _refresh() async {
    final status = await widget.client.getGitStatus();
    final info = await widget.client.gitCall('git.repo_info');
    if (!mounted) return;
    setState(() {
      _changes = [
        for (final c in (status['changes'] as List? ?? const []))
          Map<String, dynamic>.from(c as Map)
      ];
      _prefix = info['prefix'] as String? ?? '';
      _selected.removeWhere((p) => !_changes.any((c) => c['path'] == p));
    });
  }

  /// 仓库根路径 → 项目路径(项目是仓库子目录时去掉前缀;不在项目里的保持原样)。
  String _workspacePath(String repoPath) =>
      _prefix.isNotEmpty && repoPath.startsWith(_prefix)
          ? repoPath.substring(_prefix.length)
          : repoPath;

  Future<void> _toggleStage(Map<String, dynamic> c) async {
    final path = c['path'] as String;
    c['is_staged'] == true
        ? await widget.client.gitUnstage(path)
        : await widget.client.gitStage(path);
    await _refresh();
  }

  Future<void> _setAll(List<Map<String, dynamic>> group, bool staged) async {
    for (final c in group) {
      if ((c['is_staged'] == true) == staged) continue;
      final path = c['path'] as String;
      staged
          ? await widget.client.gitStage(path)
          : await widget.client.gitUnstage(path);
    }
    await _refresh();
  }

  String? _lastTapPath;
  DateTime _lastTapAt = DateTime(0);

  /// 单击立即打开差异;400ms 内对同一文件再点一次视为双击,打开源文件。
  /// 不用 GestureDetector.onDoubleTap:它会让每次单击都等 300ms 才生效。
  void _tapFile(String path, String status) {
    final now = DateTime.now();
    final isDouble = _lastTapPath == path &&
        now.difference(_lastTapAt) < const Duration(milliseconds: 400);
    _lastTapPath = path;
    _lastTapAt = now;
    if (isDouble) {
      if (status != 'deleted') widget.onOpenFile(_workspacePath(path));
      return;
    }
    final meta = HardwareKeyboard.instance.isMetaPressed ||
        HardwareKeyboard.instance.isControlPressed;
    setState(() {
      if (meta) {
        _selected.contains(path) ? _selected.remove(path) : _selected.add(path);
      } else {
        _selected
          ..clear()
          ..add(path);
      }
    });
    if (!meta) widget.onOpenDiff(path);
  }

  bool get _hasStaged => _changes.any((c) => c['is_staged'] == true);

  /// Rollback 对哪些文件:勾选了文件就是勾选的那些(勾上「Changes」就是全部),
  /// 一个都没勾才看选中(高亮)的行。没纳入版本管理的新文件不算(git 里没有它的旧版本可恢复)。
  List<String> get _rollbackTargets {
    final checked = _hasStaged;
    return [
      for (final c in _changes)
        if ((checked ? c['is_staged'] == true : _selected.contains(c['path'])) &&
            c['status'] != 'untracked')
          c['path'] as String,
    ];
  }

  Future<void> _rollback() async {
    final targets = _rollbackTargets;
    if (targets.isEmpty) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: Text(tr('回滚更改', 'Rollback Changes'),
            style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
        content: SizedBox(
          width: 440,
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                  tr('以下文件的本地修改将被丢弃,无法恢复。新增的文件会被删除。',
                      'Local changes to the following files will be discarded and cannot be recovered. Added files will be deleted.'),
                  style: _kText),
              const SizedBox(height: 8),
              for (final p in targets.take(12))
                Text('  $p', overflow: TextOverflow.ellipsis, style: _kMuted),
              if (targets.length > 12)
                Text(tr('  … 共 ${targets.length} 个文件', '  … ${targets.length} files in total'), style: _kMuted),
            ],
          ),
        ),
        actions: [
          TextButton(
              onPressed: () => Navigator.pop(ctx, false),
              child: Text(tr('取消', 'Cancel'))),
          FilledButton(
            style:
                FilledButton.styleFrom(backgroundColor: IntelliJTheme.gitRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: Text(tr('回滚', 'Rollback')),
          ),
        ],
      ),
    );
    if (ok != true) return;
    final res = await widget.client.gitCall('git.rollback', {'paths': targets});
    if (!mounted) return;
    if (res['status'] != 'ok') showNotice(context, tr('回滚失败: ${res['error']}', 'Rollback failed: ${res['error']}'), error: true);
    widget.onFilesReverted?.call([for (final p in targets) _workspacePath(p)]);
    await _refresh();
    widget.onCommitted();
  }

  Future<void> _toggleAmend(bool? v) async {
    final amend = v ?? false;
    setState(() => _amend = amend);
    // 勾上 Amend 且还没写信息:带出上一次提交的信息(与 IntelliJ 一致)。
    if (amend && _message.text.trim().isEmpty) {
      final head =
          await widget.client.gitCall('git.commit_details', {'hash': 'HEAD'});
      if (!mounted || !_amend) return;
      final msg = head['message'] as String?;
      if (msg != null && _message.text.trim().isEmpty) {
        setState(() => _message.text = msg);
      }
    }
  }

  Future<void> _pickRecentMessage(Offset at) async {
    final res =
        await widget.client.gitCall('git.recent_messages', {'limit': 20});
    final messages = [
      for (final m in (res['messages'] as List? ?? const [])) m as String
    ];
    if (!mounted || messages.isEmpty) return;
    final picked = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(at.dx, at.dy, at.dx + 1, at.dy + 1),
      color: IntelliJTheme.panelBg,
      constraints: const BoxConstraints(maxWidth: 420, maxHeight: 400),
      items: [
        for (final m in messages)
          PopupMenuItem(
            value: m,
            height: 28,
            child: Text(m.split('\n').first,
                overflow: TextOverflow.ellipsis, style: _kText),
          ),
      ],
    );
    if (picked != null) setState(() => _message.text = picked);
  }

  Future<void> _commit() async {
    final msg = _message.text.trim();
    if (msg.isEmpty || _committing || (!_hasStaged && !_amend)) return;
    setState(() => _committing = true);
    final res = await widget.client.gitCommit(msg, amend: _amend);
    if (!mounted) return;
    setState(() => _committing = false);
    final ok = res['status'] == 'ok';
    if (ok) {
      _message.clear();
      _amend = false;
      widget.onCommitted();
    }
    showNotice(
        context,
        ok
            ? tr('已提交 ${res['commit_hash'] ?? ''}', 'Committed ${res['commit_hash'] ?? ''}')
            : tr('提交失败: ${res['error'] ?? res}', 'Commit failed: ${res['error'] ?? res}'),
        error: !ok);
    await _refresh();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      color: IntelliJTheme.panelBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Commit | Stash
          Container(
            height: IntelliJMetrics.toolWindowHeader,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            // 侧栏拖窄时标签横向滚动,右侧的工具窗按钮始终放得下。
            child: Row(
              children: [
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        _HeaderTab(
                            label: tr('提交', 'Commit'),
                            active: _tab == 0,
                            onTap: () => setState(() => _tab = 0)),
                        const SizedBox(width: 4),
                        _HeaderTab(
                            label: tr('储藏', 'Stash'),
                            active: _tab == 1,
                            onTap: () => setState(() => _tab = 1)),
                      ],
                    ),
                  ),
                ),
                const ToolWindowActions(),
              ],
            ),
          ),
          const Divider(height: 1, color: IntelliJTheme.borderSubtle),
          Expanded(
            child: _tab == 1
                ? StashPanel(
                    client: widget.client,
                    onRepoChanged: () {
                      _refresh();
                      widget.onCommitted();
                    })
                : _buildCommitTab(),
          ),
        ],
      ),
    );
  }

  Widget _buildCommitTab() {
    final tracked = _changes.where((c) => c['status'] != 'untracked').toList();
    final untracked =
        _changes.where((c) => c['status'] == 'untracked').toList();
    final canCommit = _message.text.trim().isNotEmpty &&
        !_committing &&
        (_hasStaged || _amend);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        // 工具条:刷新 / Rollback / 展开 / 折叠
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              _ToolBtn(icon: Icons.sync, tooltip: tr('刷新', 'Refresh'), onTap: _refresh),
              _ToolBtn(
                  icon: Icons.undo,
                  tooltip: tr('回滚…', 'Rollback…'),
                  onTap: _rollbackTargets.isEmpty ? null : _rollback),
              _ToolBtn(
                  icon: Icons.unfold_more,
                  tooltip: tr('全部展开', 'Expand All'),
                  onTap: () => setState(_collapsed.clear)),
              _ToolBtn(
                icon: Icons.unfold_less,
                tooltip: tr('全部折叠', 'Collapse All'),
                onTap: () => setState(
                    () => _collapsed.addAll(['Changes', 'Unversioned Files'])),
              ),
            ],
          ),
        ),
        Expanded(
          child: _changes.isEmpty
              ? Center(child: Text(tr('没有本地修改', 'No local changes'), style: _kMuted))
              : ListView(
                  padding:
                      const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                  children: [
                    if (tracked.isNotEmpty)
                      ..._group('Changes', tr('更改', 'Changes'), tracked),
                    if (untracked.isNotEmpty)
                      ..._group('Unversioned Files',
                          tr('未进行版本管理的文件', 'Unversioned Files'), untracked),
                  ],
                ),
        ),
        const Divider(height: 1, color: IntelliJTheme.borderSubtle),
        // Amend + 提交信息历史
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 6, 8, 2),
          child: Row(
            children: [
              _Check(value: _amend, onTap: () => _toggleAmend(!_amend)),
              const SizedBox(width: 6),
              GestureDetector(
                  onTap: () => _toggleAmend(!_amend),
                  child: Text(tr('修改', 'Amend'), style: _kText)),
              const SizedBox(width: 10),
              Builder(
                builder: (ctx) => _ToolBtn(
                  icon: Icons.history,
                  tooltip: tr('最近的提交信息', 'Recent Commit Messages'),
                  onTap: () {
                    final box = ctx.findRenderObject() as RenderBox;
                    _pickRecentMessage(
                        box.localToGlobal(Offset(0, box.size.height)));
                  },
                ),
              ),
            ],
          ),
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 4, 8, 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                height: 120,
                decoration: BoxDecoration(
                  color: IntelliJTheme.editorBg,
                  borderRadius: BorderRadius.circular(5),
                  border: Border.all(color: IntelliJTheme.border),
                ),
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                child: TextField(
                  controller: _message,
                  maxLines: null,
                  expands: true,
                  onChanged: (_) => setState(() {}),
                  style: const TextStyle(
                      color: IntelliJTheme.textHigh,
                      fontSize: 12.5,
                      fontFamily: 'Menlo'),
                  decoration: InputDecoration(
                    hintText: tr('提交信息', 'Commit Message'),
                    hintStyle: _kMuted,
                    border: InputBorder.none,
                    isDense: true,
                    contentPadding: EdgeInsets.zero,
                  ),
                ),
              ),
              const SizedBox(height: 8),
              Row(
                children: [
                  OutlinedButton(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: IntelliJTheme.textHigh,
                      side: const BorderSide(color: IntelliJTheme.border),
                      minimumSize: const Size(0, 30),
                      padding: const EdgeInsets.symmetric(horizontal: 14),
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(5)),
                    ),
                    onPressed: canCommit ? _commit : null,
                    child: _committing
                        ? const SizedBox(
                            width: 12,
                            height: 12,
                            child: CircularProgressIndicator(strokeWidth: 1.5))
                        : Text(_amend ? tr('修改提交', 'Amend Commit') : tr('提交', 'Commit'),
                            style: const TextStyle(fontSize: 12.5)),
                  ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      _hasStaged || _amend ? '' : tr('勾选要提交的文件', 'Select files to commit'),
                      overflow: TextOverflow.ellipsis,
                      style: _kMuted,
                    ),
                  ),
                ],
              ),
            ],
          ),
        ),
      ],
    );
  }

  /// [key] 是折叠状态用的固定标识(不随界面语言变),[title] 是显示的名字。
  List<Widget> _group(
      String key, String title, List<Map<String, dynamic>> items) {
    final stagedCount = items.where((c) => c['is_staged'] == true).length;
    final allStaged = stagedCount == items.length;
    final collapsed = _collapsed.contains(key);
    return [
      InkWell(
        onTap: () => setState(
            () => collapsed ? _collapsed.remove(key) : _collapsed.add(key)),
        borderRadius: BorderRadius.circular(5),
        child: Container(
          height: 26,
          decoration: BoxDecoration(
              color: IntelliJTheme.hoverBg.withValues(alpha: 0.6),
              borderRadius: BorderRadius.circular(5)),
          child: Row(
            children: [
              const SizedBox(width: 4),
              Icon(collapsed ? Icons.chevron_right : Icons.expand_more,
                  size: 15, color: IntelliJTheme.textMuted),
              const SizedBox(width: 2),
              _Check(
                  value: allStaged ? true : (stagedCount == 0 ? false : null),
                  onTap: () => _setAll(items, !allStaged)),
              const SizedBox(width: 8),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(
                        text: title,
                        style: _kText.copyWith(
                            color: IntelliJTheme.textHigh,
                            fontWeight: FontWeight.w600)),
                    TextSpan(
                        text: tr('  ${items.length} 个文件',
                            '  ${items.length} ${items.length == 1 ? 'file' : 'files'}'),
                        style: _kMuted),
                  ]),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
      if (!collapsed)
        for (final c in items) _fileRow(c),
    ];
  }

  static Color _statusColor(String status) => switch (status) {
        'added' => const Color(0xFF629755),
        'untracked' => const Color(0xFFD1675A),
        'deleted' => IntelliJTheme.textMuted,
        _ => const Color(0xFF6897BB),
      };

  static (IconData, Color) _fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'java' || 'kt' => (Icons.copyright, const Color(0xFF3574F0)),
      'dart' => (Icons.flutter_dash, const Color(0xFF40C4FF)),
      'rs' => (Icons.settings_suggest_outlined, const Color(0xFFCF8E6D)),
      'go' => (Icons.code, const Color(0xFF3FB4B4)),
      'json' || 'yaml' || 'yml' || 'toml' || 'xml' => (
          Icons.data_object,
          IntelliJTheme.textSecondary
        ),
      'md' => (Icons.description_outlined, IntelliJTheme.textSecondary),
      'sh' => (Icons.terminal, IntelliJTheme.textSecondary),
      _ => (Icons.insert_drive_file_outlined, IntelliJTheme.textSecondary),
    };
  }

  Widget _fileRow(Map<String, dynamic> c) {
    final path = c['path'] as String? ?? '';
    final status = c['status'] as String? ?? 'modified';
    final name = path.split('/').last;
    final dir =
        path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
    final (icon, iconColor) = _fileIcon(name);
    final selected = _selected.contains(path);
    return InkWell(
      onTap: () => _tapFile(path, status),
      borderRadius: BorderRadius.circular(5),
      child: Container(
        height: 26,
        decoration: BoxDecoration(
          color: selected ? const Color(0xFF2E436E) : null,
          borderRadius: BorderRadius.circular(5),
        ),
        child: Row(
          children: [
            const SizedBox(width: 26),
            _Check(value: c['is_staged'] == true, onTap: () => _toggleStage(c)),
            const SizedBox(width: 8),
            Icon(icon, size: 15, color: iconColor),
            const SizedBox(width: 6),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(
                    text: name,
                    style: _kText.copyWith(
                      color: _statusColor(status),
                      decoration: status == 'deleted'
                          ? TextDecoration.lineThrough
                          : null,
                    ),
                  ),
                  if (dir.isNotEmpty) TextSpan(text: '  $dir', style: _kMuted),
                ]),
                overflow: TextOverflow.ellipsis,
                maxLines: 1,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderTab extends StatelessWidget {
  const _HeaderTab(
      {required this.label, required this.active, required this.onTap});

  final String label;
  final bool active;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(5),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
        decoration: BoxDecoration(
          color: active ? IntelliJTheme.hoverBg : null,
          borderRadius: BorderRadius.circular(5),
          border: Border.all(
              color: active ? IntelliJTheme.border : Colors.transparent),
        ),
        child: Text(
          label,
          style: TextStyle(
              color:
                  active ? IntelliJTheme.textHigh : IntelliJTheme.textSecondary,
              fontSize: 12.5),
        ),
      ),
    );
  }
}

class _Check extends StatelessWidget {
  const _Check({required this.value, required this.onTap});

  /// null = 部分选中
  final bool? value;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final on = value != false;
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        width: 15,
        height: 15,
        decoration: BoxDecoration(
          color: on ? IntelliJTheme.accentBlue : Colors.transparent,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(
              color: on ? IntelliJTheme.accentBlue : IntelliJTheme.textMuted),
        ),
        child: value == null
            ? const Icon(Icons.remove, size: 12, color: Colors.white)
            : value!
                ? const Icon(Icons.check, size: 12, color: Colors.white)
                : null,
      ),
    );
  }
}

class _ToolBtn extends StatelessWidget {
  const _ToolBtn(
      {required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(5),
            child: Icon(icon,
                size: 16,
                color: onTap == null
                    ? IntelliJTheme.textMuted
                    : IntelliJTheme.textSecondary),
          ),
        ),
      );
}
