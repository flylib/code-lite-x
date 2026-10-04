import 'package:flutter/material.dart';

import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';

const TextStyle _kText = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12);
const TextStyle _kMuted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

/// IntelliJ 的 Commit 工具窗(左侧):勾选即暂存,下方写提交信息并提交。
///
/// 原先挤在底部 Git 面板里;Git 工具窗改成 Log 视图后搬到这里,与 IntelliJ 的分工一致。
class CommitPanel extends StatefulWidget {
  const CommitPanel({super.key, required this.client, required this.onOpenFile, required this.onCommitted});

  final ApiClient client;
  final ValueChanged<String> onOpenFile;

  /// 提交成功后通知 Git Log 刷新。
  final VoidCallback onCommitted;

  @override
  State<CommitPanel> createState() => _CommitPanelState();
}

class _CommitPanelState extends State<CommitPanel> {
  final TextEditingController _message = TextEditingController();
  List<Map<String, dynamic>> _changes = const [];
  String _branch = '';
  bool _committing = false;
  bool _changesExpanded = true;
  bool _unversionedExpanded = true;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _message.dispose();
    super.dispose();
  }

  Future<void> _refresh() async {
    final status = await widget.client.getGitStatus();
    if (!mounted) return;
    setState(() {
      _branch = status['branch'] as String? ?? '';
      _changes = [for (final c in (status['changes'] as List? ?? const [])) Map<String, dynamic>.from(c as Map)];
    });
  }

  Future<void> _toggle(Map<String, dynamic> c) async {
    final path = c['path'] as String;
    if (c['is_staged'] == true) {
      await widget.client.gitUnstage(path);
    } else {
      await widget.client.gitStage(path);
    }
    await _refresh();
  }

  Future<void> _setAll(List<Map<String, dynamic>> group, bool staged) async {
    for (final c in group) {
      if ((c['is_staged'] == true) == staged) continue;
      final path = c['path'] as String;
      staged ? await widget.client.gitStage(path) : await widget.client.gitUnstage(path);
    }
    await _refresh();
  }

  bool get _hasStaged => _changes.any((c) => c['is_staged'] == true);

  Future<void> _commit() async {
    final msg = _message.text.trim();
    if (msg.isEmpty || !_hasStaged || _committing) return;
    setState(() => _committing = true);
    final res = await widget.client.gitCommit(msg);
    if (!mounted) return;
    setState(() => _committing = false);
    final ok = res['status'] == 'ok' || res['success'] == true;
    if (ok) {
      _message.clear();
      widget.onCommitted();
    }
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(ok ? '已提交' : '提交失败: ${res['error'] ?? res}'),
    ));
    await _refresh();
  }

  static (String, Color) _badge(String status) => switch (status) {
        'added' => ('A', IntelliJTheme.gitGreen),
        'deleted' => ('D', IntelliJTheme.textMuted),
        'renamed' => ('R', const Color(0xFF6897BB)),
        'untracked' => ('?', IntelliJTheme.gitRed),
        _ => ('M', const Color(0xFF6897BB)),
      };

  @override
  Widget build(BuildContext context) {
    final tracked = _changes.where((c) => c['status'] != 'untracked').toList();
    final untracked = _changes.where((c) => c['status'] == 'untracked').toList();
    final canCommit = _hasStaged && _message.text.trim().isNotEmpty && !_committing;

    return Container(
      width: IntelliJMetrics.sidePanel + 30,
      decoration: const BoxDecoration(
        color: IntelliJTheme.panelBg,
        border: Border(right: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Container(
            height: IntelliJMetrics.toolWindowHeader,
            padding: const EdgeInsets.only(left: 12, right: 4),
            child: Row(
              children: [
                const Text('Commit', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.w600)),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(_branch, overflow: TextOverflow.ellipsis, style: _kMuted),
                ),
                _IconBtn(icon: Icons.refresh, tooltip: '刷新', onTap: _refresh),
              ],
            ),
          ),
          const Divider(height: 1, color: IntelliJTheme.borderSubtle),
          Expanded(
            child: _changes.isEmpty
                ? const Center(child: Text('没有本地修改', style: _kMuted))
                : ListView(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    children: [
                      if (tracked.isNotEmpty)
                        ..._group('Changes', tracked, _changesExpanded, () => setState(() => _changesExpanded = !_changesExpanded)),
                      if (untracked.isNotEmpty)
                        ..._group('Unversioned Files', untracked, _unversionedExpanded,
                            () => setState(() => _unversionedExpanded = !_unversionedExpanded)),
                    ],
                  ),
          ),
          const Divider(height: 1, color: IntelliJTheme.borderSubtle),
          Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                Container(
                  height: 110,
                  decoration: BoxDecoration(
                    color: IntelliJTheme.editorBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: IntelliJTheme.border),
                  ),
                  padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
                  child: TextField(
                    controller: _message,
                    maxLines: null,
                    expands: true,
                    onChanged: (_) => setState(() {}),
                    style: _kText.copyWith(color: IntelliJTheme.textHigh),
                    decoration: const InputDecoration(
                      hintText: 'Commit Message',
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
                    FilledButton(
                      style: FilledButton.styleFrom(
                        backgroundColor: IntelliJTheme.accentBlue,
                        minimumSize: const Size(0, 28),
                        padding: const EdgeInsets.symmetric(horizontal: 14),
                      ),
                      onPressed: canCommit ? _commit : null,
                      child: _committing
                          ? const SizedBox(width: 12, height: 12, child: CircularProgressIndicator(strokeWidth: 1.5))
                          : const Text('Commit', style: TextStyle(fontSize: 12)),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        _hasStaged ? '' : '勾选要提交的文件',
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
      ),
    );
  }

  List<Widget> _group(String title, List<Map<String, dynamic>> items, bool expanded, VoidCallback onToggle) {
    final stagedCount = items.where((c) => c['is_staged'] == true).length;
    final allStaged = stagedCount == items.length;
    return [
      InkWell(
        onTap: onToggle,
        child: SizedBox(
          height: 24,
          child: Row(
            children: [
              const SizedBox(width: 4),
              Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 14, color: IntelliJTheme.textMuted),
              _Check(
                value: allStaged ? true : (stagedCount == 0 ? false : null),
                onTap: () => _setAll(items, !allStaged),
              ),
              const SizedBox(width: 4),
              Expanded(
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: title, style: _kText.copyWith(color: IntelliJTheme.textHigh)),
                    TextSpan(text: '  ${items.length} ${items.length == 1 ? 'file' : 'files'}', style: _kMuted),
                  ]),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
        ),
      ),
      if (expanded)
        for (final c in items) _fileRow(c),
    ];
  }

  Widget _fileRow(Map<String, dynamic> c) {
    final path = c['path'] as String? ?? '';
    final (badge, color) = _badge(c['status'] as String? ?? 'modified');
    final name = path.split('/').last;
    final dir = path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';
    return GestureDetector(
      onDoubleTap: () => widget.onOpenFile(path),
      child: SizedBox(
        height: 24,
        child: Row(
          children: [
            const SizedBox(width: 22),
            _Check(value: c['is_staged'] == true, onTap: () => _toggle(c)),
            const SizedBox(width: 4),
            Tooltip(
              message: c['status'] as String? ?? '',
              child: SizedBox(width: 12, child: Text(badge, style: TextStyle(color: color, fontSize: 11, fontWeight: FontWeight.bold))),
            ),
            const SizedBox(width: 4),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: name, style: _kText.copyWith(color: color)),
                  if (dir.isNotEmpty) TextSpan(text: '  $dir', style: _kMuted),
                ]),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
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
    final icon = value == null
        ? Icons.indeterminate_check_box
        : value!
            ? Icons.check_box
            : Icons.check_box_outline_blank;
    return InkWell(
      onTap: onTap,
      child: Icon(icon, size: 15, color: value == false ? IntelliJTheme.textMuted : IntelliJTheme.accentBlue),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(padding: const EdgeInsets.all(4), child: Icon(icon, size: 15, color: IntelliJTheme.textSecondary)),
      ),
    );
  }
}
