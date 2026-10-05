import 'package:flutter/material.dart';

import '../../core/github/github_service.dart';
import '../../core/theme/intellij_theme.dart';
import 'pr_diff_tab.dart' show prFileColor;
import 'pr_store.dart';
import 'pr_widgets.dart';

/// 左侧「Pull Requests」工具窗:上方是仓库 / 已打开 PR 的标签;
/// 仓库标签下是带搜索与筛选的 PR 列表,PR 标签下是该 PR 的详情(改动文件、检查、评审)。
class PullRequestsPanel extends StatefulWidget {
  const PullRequestsPanel({super.key, required this.store, required this.onOpenDiff, required this.onOpenTimeline});

  final PullRequestsStore store;

  /// 在编辑区打开 PR 的差异标签并显示 [path]。
  final void Function(int number, String path) onOpenDiff;
  final void Function(int number) onOpenTimeline;

  @override
  State<PullRequestsPanel> createState() => _PullRequestsPanelState();
}

class _PullRequestsPanelState extends State<PullRequestsPanel> {
  late final TextEditingController _search = TextEditingController(text: widget.store.search);

  PullRequestsStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _store.ensureLoaded();
  }

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _store,
      builder: (context, _) {
        final selected = _store.selected;
        return Container(
          color: IntelliJTheme.panelBg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              _tabs(),
              const Divider(height: 1, color: IntelliJTheme.borderSubtle),
              Expanded(
                child: selected == null
                    ? _listView()
                    : _PrDetailView(
                        key: ValueKey(selected),
                        session: _store.session(selected),
                        onOpenDiff: (path) => widget.onOpenDiff(selected, path),
                        onOpenTimeline: () => widget.onOpenTimeline(selected),
                      ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _tabs() {
    return SizedBox(
      height: 38,
      child: Row(
        children: [
          Expanded(
            child: ListView(
              scrollDirection: Axis.horizontal,
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              children: [
                _Chip(
                  label: _store.repoName.isEmpty ? 'Pull Requests' : _store.repoName.split('/').last,
                  tooltip: _store.repoName,
                  active: _store.selected == null,
                  onTap: _store.showList,
                ),
                for (final n in _store.opened)
                  _Chip(
                    label: '#$n',
                    tooltip: _store.session(n).detail?.title ?? _store.summaryOf(n)?.title ?? '',
                    active: _store.selected == n,
                    onTap: () => _store.openPr(n),
                    onClose: () => _store.closePr(n),
                  ),
              ],
            ),
          ),
          _IconBtn(
            icon: Icons.refresh,
            tooltip: '刷新',
            onTap: () {
              final s = _store.selected;
              s == null ? _store.refresh() : _store.session(s).reload();
            },
          ),
          const SizedBox(width: 4),
        ],
      ),
    );
  }

  // ---------------------------------------------------------------------------
  // 列表
  // ---------------------------------------------------------------------------

  Widget _listView() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(10, 10, 10, 4),
          child: SizedBox(
            height: 32,
            child: TextField(
              controller: _search,
              style: prText,
              onSubmitted: _store.setSearch,
              decoration: InputDecoration(
                hintText: '搜索(GitHub 语法,如 is:open fix)',
                hintStyle: prMuted,
                isDense: true,
                prefixIcon: const Icon(Icons.search, size: 16, color: IntelliJTheme.textSecondary),
                prefixIconConstraints: const BoxConstraints(minWidth: 30),
                suffixIcon: _search.text.isEmpty
                    ? null
                    : InkWell(
                        onTap: () {
                          _search.clear();
                          _store.setSearch('');
                        },
                        child: const Icon(Icons.close, size: 14, color: IntelliJTheme.textMuted),
                      ),
                suffixIconConstraints: const BoxConstraints(minWidth: 26),
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
                border: const OutlineInputBorder(borderSide: BorderSide(color: IntelliJTheme.border)),
                enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: IntelliJTheme.border)),
                focusedBorder: const OutlineInputBorder(borderSide: BorderSide(color: IntelliJTheme.accentBlue)),
              ),
            ),
          ),
        ),
        SizedBox(
          height: 32,
          child: ListView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 6),
            children: [
              _FilterChip(
                label: switch (_store.stateFilter) { 'closed' => 'Closed', 'merged' => 'Merged', 'all' => 'State', _ => 'Open' },
                isSet: _store.stateFilter != 'all',
                options: const [('open', 'Open'), ('closed', 'Closed'), ('merged', 'Merged'), ('all', 'All')],
                onSelected: (v) => _store.setStateFilter(v ?? 'all'),
              ),
              _FilterChip(
                label: _store.author ?? 'Author',
                isSet: _store.author != null,
                options: _peopleOptions(_store.knownAuthors),
                onSelected: _store.setAuthor,
              ),
              _FilterChip(
                label: _store.label ?? 'Label',
                isSet: _store.label != null,
                options: [for (final l in _store.knownLabels.toList()..sort()) (l, l)],
                onSelected: _store.setLabel,
              ),
              _FilterChip(
                label: _store.assignee ?? 'Assignee',
                isSet: _store.assignee != null,
                options: _peopleOptions(_store.knownAssignees),
                onSelected: _store.setAssignee,
              ),
            ],
          ),
        ),
        const SizedBox(height: 4),
        Expanded(child: _listBody()),
      ],
    );
  }

  List<(String, String)> _peopleOptions(Set<String> known) => [
        if (_store.viewer.isNotEmpty) ('@me', 'Me (${_store.viewer})'),
        for (final p in known.toList()..sort())
          if (p.isNotEmpty) (p, p),
      ];

  Widget _listBody() {
    if (_store.ghUnavailable) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.info_outline, size: 20, color: IntelliJTheme.textSecondary),
            const SizedBox(height: 8),
            Text(_store.error ?? '', style: prText),
            const SizedBox(height: 12),
            TextButton(onPressed: _store.refresh, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_store.loading && _store.items.isEmpty) {
      return const Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)));
    }
    if (_store.error != null) {
      return Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SelectableText(_store.error!, style: prMuted),
            TextButton(onPressed: _store.refresh, child: const Text('重试')),
          ],
        ),
      );
    }
    if (_store.items.isEmpty) return const Center(child: Text('没有符合条件的 Pull Request', style: prMuted));
    return Stack(
      children: [
        ListView.builder(
          itemCount: _store.items.length,
          itemBuilder: (context, i) => _PrRow(pr: _store.items[i], onTap: () => _store.openPr(_store.items[i].number)),
        ),
        if (_store.loading) const Positioned(top: 0, left: 0, right: 0, child: LinearProgressIndicator(minHeight: 2)),
      ],
    );
  }
}

class _PrRow extends StatelessWidget {
  const _PrRow({required this.pr, required this.onTap});

  final PullRequestSummary pr;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return InkWell(
      onTap: onTap,
      hoverColor: IntelliJTheme.hoverBg,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 8, 12, 8),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: Text(
                    pr.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13),
                  ),
                ),
                if (pr.isDraft) ...[
                  const SizedBox(width: 6),
                  Container(
                    padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1),
                    decoration: BoxDecoration(color: const Color(0xFF3C3F44), borderRadius: BorderRadius.circular(3)),
                    child: const Text('DRAFT', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10.5)),
                  ),
                ],
                if (pr.checks == ChecksState.failure || pr.checks == ChecksState.pending) ...[
                  const SizedBox(width: 6),
                  checksIcon(pr.checks),
                ],
                if (pr.reviewDecision == 'APPROVED') ...[
                  const SizedBox(width: 6),
                  const Tooltip(message: 'Approved', child: Icon(Icons.verified_outlined, size: 16, color: Color(0xFF5FB865))),
                ],
                const SizedBox(width: 8),
                const Icon(Icons.chat_bubble_outline, size: 14, color: IntelliJTheme.textSecondary),
                const SizedBox(width: 4),
                Text('${pr.commentCount}', style: const TextStyle(color: IntelliJTheme.textSecondary, fontSize: 12)),
              ],
            ),
            const SizedBox(height: 3),
            Text(
              '#${pr.number} · created ${prDate(pr.createdAt)}, by ${pr.author}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: prMuted,
            ),
          ],
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 详情
// ---------------------------------------------------------------------------

class _PrDetailView extends StatefulWidget {
  const _PrDetailView({super.key, required this.session, required this.onOpenDiff, required this.onOpenTimeline});

  final PrSession session;
  final void Function(String path) onOpenDiff;
  final VoidCallback onOpenTimeline;

  @override
  State<_PrDetailView> createState() => _PrDetailViewState();
}

class _PrDetailViewState extends State<_PrDetailView> {
  final Set<String> _collapsed = {};
  bool _showDetails = false;
  bool _busy = false;

  PrSession get _s => widget.session;

  @override
  void initState() {
    super.initState();
    _s.ensureLoaded();
  }

  Future<void> _setMeAsReviewer() async {
    setState(() => _busy = true);
    try {
      await _s.requestMyReview();
    } on GhException catch (e) {
      if (mounted) prSnack(context, e.message, error: true);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: _s,
      builder: (context, _) {
        final d = _s.detail;
        if (d == null) {
          if (_s.error != null) {
            return Padding(padding: const EdgeInsets.all(16), child: SelectableText(_s.error!, style: prMuted));
          }
          return const Center(child: SizedBox.square(dimension: 18, child: CircularProgressIndicator(strokeWidth: 2)));
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            if (_s.loading) const LinearProgressIndicator(minHeight: 2),
            Expanded(
              child: ListView(
                padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
                children: [
                  Text.rich(
                    TextSpan(children: [
                      TextSpan(text: d.title, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15, fontWeight: FontWeight.w600)),
                      TextSpan(text: '  #${d.number}', style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 15)),
                    ]),
                  ),
                  const SizedBox(height: 4),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: InkWell(onTap: widget.onOpenTimeline, child: const Text('View Timeline', style: prLink)),
                  ),
                  const SizedBox(height: 12),
                  Row(
                    children: [
                      const Text('Changes', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600)),
                      const SizedBox(width: 8),
                      const Icon(Icons.call_split, size: 14, color: IntelliJTheme.textSecondary),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Tooltip(
                          message: '${d.headRef} → ${d.baseRef}',
                          child: Text('${d.headRef} → ${d.baseRef}', overflow: TextOverflow.ellipsis, style: prLink),
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 6),
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          d.commits.isEmpty ? d.title : d.commits.last.headline,
                          overflow: TextOverflow.ellipsis,
                          style: prText,
                        ),
                      ),
                      InkWell(
                        onTap: () => setState(() => _showDetails = !_showDetails),
                        child: Text(_showDetails ? 'Hide details' : 'Show details', style: prLink),
                      ),
                    ],
                  ),
                  if (_showDetails)
                    Container(
                      margin: const EdgeInsets.only(top: 6),
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(color: IntelliJTheme.editorBg, borderRadius: BorderRadius.circular(4)),
                      child: SelectableText(d.body.trim().isEmpty ? '(没有描述)' : d.body.trim(), style: prText.copyWith(height: 1.4)),
                    ),
                  const SizedBox(height: 8),
                  ..._fileTree(),
                ],
              ),
            ),
            const Divider(height: 1, color: IntelliJTheme.borderSubtle),
            _footer(d),
          ],
        );
      },
    );
  }

  // ---- 文件树:单子目录链压成一行(main/resources/mapper/mtt),与 IntelliJ 一致 ----

  List<Widget> _fileTree() {
    final root = _DirNode('');
    for (final f in _s.files) {
      final parts = f.path.split('/');
      var node = root;
      for (var i = 0; i < parts.length - 1; i++) {
        node = node.dirs.putIfAbsent(parts[i], () => _DirNode(parts[i]));
      }
      node.files.add(f);
    }
    final out = <Widget>[];
    void walk(_DirNode dir, String path, int depth) {
      for (final sub in dir.dirs.values) {
        // 压缩只有一个子目录且没有文件的链;顶层目录(通常是模块)单独成行,与 IntelliJ 一致。
        var name = sub.name, node = sub;
        while (depth > 0 && node.files.isEmpty && node.dirs.length == 1) {
          node = node.dirs.values.first;
          name = '$name/${node.name}';
        }
        final key = '$path/$name';
        final open = !_collapsed.contains(key);
        out.add(_TreeRow(
          depth: depth,
          expanded: open,
          icon: Icons.folder_outlined,
          label: name,
          trailing: '${node.fileCount} ${node.fileCount == 1 ? 'file' : 'files'}',
          onTap: () => setState(() => open ? _collapsed.add(key) : _collapsed.remove(key)),
        ));
        if (open) walk(node, key, depth + 1);
      }
      for (final f in dir.files) {
        final viewed = _s.viewed.isEmpty ? null : (_s.viewed[f.path] ?? false);
        final comments = _s.commentCount(f.path);
        out.add(_TreeRow(
          depth: depth,
          icon: Icons.description_outlined,
          label: f.path.split('/').last,
          labelColor: prFileColor(f.status),
          tooltip: f.previousPath == null ? f.path : '${f.previousPath} → ${f.path}',
          selected: _s.diffFile == f.path,
          comments: comments,
          unviewed: viewed == false,
          onTap: () => widget.onOpenDiff(f.path),
        ));
      }
    }

    walk(root, '', 0);
    return out;
  }

  Widget _footer(PullRequestDetail d) {
    final checks = d.checksState;
    final failed = d.checks.where((c) => c.state == ChecksState.failure).length;
    final pending = d.checks.where((c) => c.state == ChecksState.pending).length;
    final checksText = switch (checks) {
      ChecksState.none => 'No checks',
      ChecksState.success => 'All checks have passed',
      ChecksState.pending => '$pending ${pending == 1 ? 'check is' : 'checks are'} pending',
      ChecksState.failure => '$failed ${failed == 1 ? 'check has' : 'checks have'} failed',
    };
    final me = _s.viewer;
    final isAuthor = me.isNotEmpty && d.author == me;
    final requested = d.reviewRequests.contains(me) || d.reviews.any((r) => r.author == me);
    final (reviewIcon, reviewColor, reviewText) = switch (d.reviewDecision) {
      'APPROVED' => (Icons.check_circle, const Color(0xFF5FB865), 'Approved'),
      'CHANGES_REQUESTED' => (Icons.error, const Color(0xFFE5534B), 'Changes requested'),
      _ when d.reviewRequests.isEmpty && d.reviews.isEmpty => (Icons.warning_amber_rounded, const Color(0xFFE5C07B), 'Missing reviewer'),
      _ => (
          Icons.schedule,
          IntelliJTheme.textSecondary,
          d.reviewRequests.isEmpty ? 'Review required' : 'Waiting for ${d.reviewRequests.join(', ')}',
        ),
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 10, 10, 12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              checks == ChecksState.none ? const Icon(Icons.remove_circle_outline, size: 16, color: IntelliJTheme.textMuted) : checksIcon(checks),
              const SizedBox(width: 8),
              Expanded(child: Text(checksText, overflow: TextOverflow.ellipsis, style: prText)),
              if (d.checks.isNotEmpty)
                InkWell(onTap: () => GitHubService.openInBrowser('${d.url}/checks'), child: const Text('Details', style: prLink)),
            ],
          ),
          const SizedBox(height: 8),
          Row(
            children: [
              Icon(reviewIcon, size: 16, color: reviewColor),
              const SizedBox(width: 8),
              Expanded(child: Text(reviewText, overflow: TextOverflow.ellipsis, style: prText)),
            ],
          ),
          const SizedBox(height: 12),
          Row(
            children: [
              if (!isAuthor && !requested && d.state == 'OPEN') ...[
                Flexible(
                  child: OutlinedButton(
                    onPressed: _busy ? null : _setMeAsReviewer,
                    style: _btnStyle,
                    child: const Text('Set Myself as Reviewer', overflow: TextOverflow.ellipsis),
                  ),
                ),
                const SizedBox(width: 8),
              ],
              Flexible(
                child: OutlinedButton(
                  onPressed: () => showSubmitReviewDialog(context, _s),
                  style: _btnStyle,
                  child: const Text('Submit Review…', overflow: TextOverflow.ellipsis),
                ),
              ),
              const Spacer(),
              PopupMenuButton<String>(
                tooltip: '更多',
                color: IntelliJTheme.panelBg,
                icon: const Icon(Icons.more_vert, size: 18, color: IntelliJTheme.textSecondary),
                onSelected: (v) {
                  if (v == 'web') GitHubService.openInBrowser(d.url);
                  if (v == 'timeline') widget.onOpenTimeline();
                  if (v == 'refresh') _s.reload();
                },
                itemBuilder: (_) => const [
                  PopupMenuItem(value: 'timeline', height: 30, child: Text('View Timeline', style: prText)),
                  PopupMenuItem(value: 'web', height: 30, child: Text('Open on GitHub', style: prText)),
                  PopupMenuItem(value: 'refresh', height: 30, child: Text('Refresh', style: prText)),
                ],
              ),
            ],
          ),
        ],
      ),
    );
  }

  static final ButtonStyle _btnStyle = OutlinedButton.styleFrom(
    foregroundColor: IntelliJTheme.textHigh,
    side: const BorderSide(color: IntelliJTheme.border),
    visualDensity: VisualDensity.compact,
    padding: const EdgeInsets.symmetric(horizontal: 12),
    textStyle: const TextStyle(fontSize: 12.5),
  );
}

class _DirNode {
  _DirNode(this.name);
  final String name;
  final Map<String, _DirNode> dirs = {};
  final List<PrFile> files = [];
  int get fileCount => files.length + dirs.values.fold(0, (a, d) => a + d.fileCount);
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.depth,
    required this.icon,
    required this.label,
    required this.onTap,
    this.expanded,
    this.labelColor,
    this.trailing,
    this.tooltip,
    this.selected = false,
    this.comments = 0,
    this.unviewed = false,
  });

  final int depth;
  final IconData icon;
  final String label;
  final VoidCallback onTap;

  /// 目录:展开 / 折叠;文件为 null。
  final bool? expanded;
  final Color? labelColor;
  final String? trailing;
  final String? tooltip;
  final bool selected;
  final int comments;
  final bool unviewed;

  @override
  Widget build(BuildContext context) {
    final row = InkWell(
      onTap: onTap,
      child: Container(
        height: 26,
        color: selected ? const Color(0xFF2E436E) : null,
        padding: EdgeInsets.only(left: depth * 16.0),
        child: Row(
          children: [
            SizedBox(
              width: 16,
              child: expanded == null
                  ? null
                  : Icon(expanded! ? Icons.expand_more : Icons.chevron_right, size: 16, color: IntelliJTheme.textSecondary),
            ),
            const SizedBox(width: 2),
            Icon(icon, size: 15, color: IntelliJTheme.textSecondary),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: labelColor ?? IntelliJTheme.textPrimary, fontSize: 12.5),
              ),
            ),
            if (trailing != null) ...[
              const SizedBox(width: 6),
              Text(trailing!, style: prMuted),
            ],
            if (comments > 0) ...[
              const SizedBox(width: 6),
              const Icon(Icons.chat_bubble_outline, size: 12, color: IntelliJTheme.textSecondary),
              const SizedBox(width: 2),
              Text('$comments', style: prMuted),
            ],
            if (unviewed) ...[
              const SizedBox(width: 6),
              const Tooltip(
                message: '未查看',
                child: CircleAvatar(radius: 3, backgroundColor: IntelliJTheme.accentBlue),
              ),
            ],
            const SizedBox(width: 6),
          ],
        ),
      ),
    );
    return tooltip == null ? row : Tooltip(message: tooltip!, waitDuration: const Duration(milliseconds: 600), child: row);
  }
}

/// 标题栏上的标签(仓库 / 已打开的 PR)。
class _Chip extends StatelessWidget {
  const _Chip({required this.label, required this.active, required this.onTap, this.onClose, this.tooltip = ''});

  final String label;
  final bool active;
  final VoidCallback onTap;
  final VoidCallback? onClose;
  final String tooltip;

  @override
  Widget build(BuildContext context) {
    final chip = Padding(
      padding: const EdgeInsets.only(right: 6),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(5),
        child: Container(
          padding: EdgeInsets.only(left: 9, right: onClose == null ? 9 : 4),
          decoration: BoxDecoration(
            color: active ? const Color(0xFF2E436E) : null,
            borderRadius: BorderRadius.circular(5),
            border: Border.all(color: active ? IntelliJTheme.accentBlue : IntelliJTheme.border),
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 140),
                child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5)),
              ),
              if (onClose != null) ...[
                const SizedBox(width: 4),
                InkWell(
                  onTap: onClose,
                  borderRadius: BorderRadius.circular(8),
                  child: const Padding(
                    padding: EdgeInsets.all(2),
                    child: Icon(Icons.close, size: 12, color: IntelliJTheme.textSecondary),
                  ),
                ),
              ],
            ],
          ),
        ),
      ),
    );
    return tooltip.isEmpty ? chip : Tooltip(message: tooltip, waitDuration: const Duration(milliseconds: 500), child: chip);
  }
}

/// 筛选下拉:「Author ▾」;已设置时显示值并带 × 清除。
class _FilterChip extends StatelessWidget {
  const _FilterChip({required this.label, required this.isSet, required this.options, required this.onSelected});

  final String label;
  final bool isSet;
  final List<(String, String)> options;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 2, vertical: 3),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          PopupMenuButton<String>(
            tooltip: '',
            color: IntelliJTheme.panelBg,
            enabled: options.isNotEmpty,
            onSelected: onSelected,
            itemBuilder: (_) => [
              for (final (value, text) in options) PopupMenuItem(value: value, height: 30, child: Text(text, style: prText)),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  ConstrainedBox(
                    constraints: const BoxConstraints(maxWidth: 120),
                    child: Text(
                      label,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(color: isSet ? IntelliJTheme.textHigh : IntelliJTheme.textSecondary, fontSize: 12.5),
                    ),
                  ),
                  if (!isSet) const Icon(Icons.keyboard_arrow_down, size: 15, color: IntelliJTheme.textSecondary),
                ],
              ),
            ),
          ),
          if (isSet)
            InkWell(
              onTap: () => onSelected(null),
              borderRadius: BorderRadius.circular(8),
              child: const Padding(
                padding: EdgeInsets.all(2),
                child: Icon(Icons.close, size: 13, color: IntelliJTheme.textSecondary),
              ),
            ),
        ],
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(padding: const EdgeInsets.all(5), child: Icon(icon, size: 16, color: IntelliJTheme.textSecondary)),
        ),
      );
}
