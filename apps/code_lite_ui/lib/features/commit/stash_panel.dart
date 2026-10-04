import 'package:flutter/material.dart';

import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';
import '../git/diff_view.dart';

const TextStyle _kText = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12.5);
const TextStyle _kMuted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

/// Commit 工具窗的 Stash 标签:列出 git stash,新建 / Apply / Pop / Drop,
/// 选中某个 stash 看它改了哪些文件,点文件看差异。
class StashPanel extends StatefulWidget {
  const StashPanel({super.key, required this.client, required this.onRepoChanged});

  final ApiClient client;

  /// stash / apply / pop 改动了工作区:Commit 标签和 Git Log 需要刷新。
  final VoidCallback onRepoChanged;

  @override
  State<StashPanel> createState() => _StashPanelState();
}

class _StashPanelState extends State<StashPanel> {
  List<Map<String, dynamic>> _stashes = const [];
  String? _selected;
  List<Map<String, dynamic>> _files = const [];
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    final res = await widget.client.gitCall('git.stash_list');
    if (!mounted) return;
    setState(() {
      _stashes = [for (final s in (res['stashes'] as List? ?? const [])) Map<String, dynamic>.from(s as Map)];
      if (_selected != null && !_stashes.any((s) => s['ref'] == _selected)) {
        _selected = null;
        _files = const [];
      }
    });
    if (_selected != null) await _select(_selected!);
  }

  Future<void> _select(String ref) async {
    setState(() => _selected = ref);
    final res = await widget.client.gitCall('git.stash_files', {'ref': ref});
    if (!mounted || _selected != ref) return;
    setState(() => _files = [for (final f in (res['files'] as List? ?? const [])) Map<String, dynamic>.from(f as Map)]);
  }

  Future<void> _run(String method, Map<String, dynamic> params, String success) async {
    setState(() => _busy = true);
    final res = await widget.client.gitCall(method, params);
    if (!mounted) return;
    setState(() => _busy = false);
    final ok = res['status'] == 'ok';
    ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
      content: Text(ok ? success : '${res['error']}'),
      backgroundColor: ok ? null : const Color(0xFF5E2B2E),
    ));
    await _refresh();
    widget.onRepoChanged();
  }

  Future<void> _stashChanges() async {
    final message = TextEditingController();
    var keepIndex = false, untracked = false;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setD) => AlertDialog(
          backgroundColor: IntelliJTheme.panelBg,
          title: const Text('Stash Changes', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
          content: SizedBox(
            width: 420,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                TextField(
                  controller: message,
                  autofocus: true,
                  style: _kText,
                  decoration: const InputDecoration(labelText: 'Message', border: OutlineInputBorder(), isDense: true),
                ),
                CheckboxListTile(
                  value: keepIndex,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Keep index', style: _kText),
                  onChanged: (v) => setD(() => keepIndex = v ?? false),
                ),
                CheckboxListTile(
                  value: untracked,
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  controlAffinity: ListTileControlAffinity.leading,
                  title: const Text('Include untracked files', style: _kText),
                  onChanged: (v) => setD(() => untracked = v ?? false),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
            FilledButton(onPressed: () => Navigator.pop(ctx, true), child: const Text('Create Stash')),
          ],
        ),
      ),
    );
    final text = message.text;
    message.dispose();
    if (ok != true) return;
    await _run('git.stash_push', {'message': text, 'keep_index': keepIndex, 'include_untracked': untracked}, '已创建 stash');
  }

  Future<void> _drop(String ref) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: const Text('Drop Stash', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
        content: Text('删除 $ref?其中的改动将无法恢复。', style: _kText),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('Cancel')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: IntelliJTheme.gitRed),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('Drop'),
          ),
        ],
      ),
    );
    if (ok == true) await _run('git.stash_drop', {'ref': ref}, '已删除 $ref');
  }

  Future<void> _showFileDiff(String ref, String path) async {
    final res = await widget.client.gitCall('git.stash_file_diff', {'ref': ref, 'path': path});
    if (!mounted) return;
    final size = MediaQuery.sizeOf(context);
    await showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        backgroundColor: IntelliJTheme.panelBg,
        insetPadding: const EdgeInsets.all(32),
        child: SizedBox(
          width: size.width * 0.75,
          height: size.height * 0.7,
          child: Column(
            children: [
              Container(
                height: 36,
                padding: const EdgeInsets.only(left: 14, right: 6),
                child: Row(
                  children: [
                    Expanded(child: Text('$path  ($ref)', overflow: TextOverflow.ellipsis, style: _kText)),
                    IconButton(
                      icon: const Icon(Icons.close, size: 16, color: IntelliJTheme.textSecondary),
                      onPressed: () => Navigator.pop(ctx),
                    ),
                  ],
                ),
              ),
              Expanded(child: DiffView(diff: res['diff'] as String? ?? (res['error'] as String? ?? ''))),
            ],
          ),
        ),
      ),
    );
  }

  static String _title(Map<String, dynamic> s) {
    final m = s['message'] as String? ?? '';
    // "On main: msg" / "WIP on main: abc123 msg" → 只留 msg 部分
    final i = m.indexOf(': ');
    return i >= 0 ? m.substring(i + 2) : m;
  }

  @override
  Widget build(BuildContext context) {
    final sel = _selected;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          child: Row(
            children: [
              _Btn(icon: Icons.refresh, tooltip: '刷新', onTap: _refresh),
              _Btn(icon: Icons.add, tooltip: 'Stash Changes…', onTap: _busy ? null : _stashChanges),
              const SizedBox(width: 6),
              _TextBtn('Apply', sel == null || _busy ? null : () => _run('git.stash_apply', {'ref': sel}, '已应用 $sel')),
              _TextBtn('Pop', sel == null || _busy ? null : () => _run('git.stash_apply', {'ref': sel, 'pop': true}, '已应用并删除 $sel')),
              _TextBtn('Drop', sel == null || _busy ? null : () => _drop(sel)),
            ],
          ),
        ),
        const Divider(height: 1, color: IntelliJTheme.borderSubtle),
        Expanded(
          child: _stashes.isEmpty
              ? const Center(child: Text('没有 stash', style: _kMuted))
              : ListView(
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  children: [
                    for (final s in _stashes) ...[
                      InkWell(
                        onTap: () => _select(s['ref'] as String),
                        child: Container(
                          height: 26,
                          color: s['ref'] == sel ? const Color(0xFF2E436E) : null,
                          padding: const EdgeInsets.symmetric(horizontal: 10),
                          child: Row(
                            children: [
                              const Icon(Icons.inventory_2_outlined, size: 14, color: IntelliJTheme.textSecondary),
                              const SizedBox(width: 6),
                              Expanded(
                                child: Text(_title(s), overflow: TextOverflow.ellipsis, style: _kText),
                              ),
                              const SizedBox(width: 6),
                              Text(s['ref'] as String, style: _kMuted),
                            ],
                          ),
                        ),
                      ),
                      if (s['ref'] == sel)
                        for (final f in _files)
                          InkWell(
                            onTap: () => _showFileDiff(sel!, f['path'] as String),
                            child: Container(
                              height: 24,
                              padding: const EdgeInsets.only(left: 34, right: 10),
                              alignment: Alignment.centerLeft,
                              child: Text.rich(
                                TextSpan(children: [
                                  TextSpan(
                                    text: (f['path'] as String).split('/').last,
                                    style: _kText.copyWith(color: _statusColor(f['status'] as String)),
                                  ),
                                  TextSpan(text: '  ${_dir(f['path'] as String)}', style: _kMuted),
                                ]),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          ),
                    ],
                  ],
                ),
        ),
      ],
    );
  }

  static String _dir(String path) => path.contains('/') ? path.substring(0, path.lastIndexOf('/')) : '';

  static Color _statusColor(String s) => switch (s) {
        'A' || 'U' => const Color(0xFF629755),
        'D' => IntelliJTheme.textMuted,
        _ => const Color(0xFF6897BB),
      };
}

class _Btn extends StatelessWidget {
  const _Btn({required this.icon, required this.tooltip, required this.onTap});

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
            child: Icon(icon, size: 16, color: onTap == null ? IntelliJTheme.textMuted : IntelliJTheme.textSecondary),
          ),
        ),
      );
}

class _TextBtn extends StatelessWidget {
  const _TextBtn(this.label, this.onTap);

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) => InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 4),
          child: Text(
            label,
            style: TextStyle(color: onTap == null ? IntelliJTheme.textMuted : IntelliJTheme.textHigh, fontSize: 12),
          ),
        ),
      );
}
