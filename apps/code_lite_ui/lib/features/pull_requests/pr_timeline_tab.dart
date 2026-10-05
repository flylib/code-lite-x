import 'package:flutter/material.dart';

import '../../core/github/github_service.dart';
import '../../core/theme/intellij_theme.dart';
import 'pr_store.dart';
import 'pr_widgets.dart';

/// 「标题 #号」Timeline 标签:描述、评论、评审、提交与各类事件按时间排列,底部可发评论。
class PrTimelineTab extends StatefulWidget {
  const PrTimelineTab({super.key, required this.session});

  final PrSession session;

  @override
  State<PrTimelineTab> createState() => _PrTimelineTabState();
}

class _PrTimelineTabState extends State<PrTimelineTab> {
  String? _error;

  PrSession get _s => widget.session;

  @override
  void initState() {
    super.initState();
    _s.addListener(_changed);
    _s.ensureLoaded();
    if (_s.timeline == null) _load();
  }

  @override
  void didUpdateWidget(PrTimelineTab old) {
    super.didUpdateWidget(old);
    if (old.session != widget.session) {
      old.session.removeListener(_changed);
      widget.session.addListener(_changed);
      if (_s.timeline == null) _load();
    }
  }

  @override
  void dispose() {
    _s.removeListener(_changed);
    super.dispose();
  }

  void _changed() {
    if (mounted) setState(() {});
  }

  Future<void> _load() async {
    setState(() => _error = null);
    try {
      await _s.loadTimeline();
    } on GhException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
  }

  Future<void> _refresh() async {
    await Future.wait([_s.reload(), _load()]);
  }

  @override
  Widget build(BuildContext context) {
    final d = _s.detail;
    if (d == null) {
      return Center(child: Text(_s.error ?? '加载中…', style: prMuted));
    }
    final items = _s.timeline;
    return Container(
      color: IntelliJTheme.editorBg,
      child: ListView(
        padding: const EdgeInsets.fromLTRB(28, 20, 28, 28),
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 920),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _header(d),
                  const SizedBox(height: 16),
                  _card(PrCommentView(
                    author: d.author,
                    date: d.createdAt,
                    body: d.body.trim().isEmpty ? '(没有描述)' : d.body,
                  )),
                  const SizedBox(height: 8),
                  if (_error != null)
                    Padding(padding: const EdgeInsets.all(12), child: Text(_error!, style: prMuted))
                  else if (items == null)
                    const Padding(padding: EdgeInsets.all(12), child: Text('加载 Timeline…', style: prMuted))
                  else
                    ..._timeline(items),
                  const SizedBox(height: 18),
                  _card(Padding(
                    padding: const EdgeInsets.all(12),
                    child: PrCommentComposer(
                      autofocus: false,
                      hint: '发表评论(⌘↩ 提交)',
                      onSubmit: _s.addComment,
                    ),
                  )),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _header(PullRequestDetail d) {
    final stateLabel = d.isDraft ? 'Draft' : switch (d.state) { 'MERGED' => 'Merged', 'CLOSED' => 'Closed', _ => 'Open' };
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: d.title, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 20, fontWeight: FontWeight.w600)),
                  TextSpan(text: '  #${d.number}', style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 20)),
                ]),
              ),
            ),
            IconButton(
              tooltip: '刷新',
              icon: const Icon(Icons.refresh, size: 18, color: IntelliJTheme.textSecondary),
              onPressed: _refresh,
            ),
            IconButton(
              tooltip: '在 GitHub 打开',
              icon: const Icon(Icons.open_in_new, size: 18, color: IntelliJTheme.textSecondary),
              onPressed: () => GitHubService.openInBrowser(d.url),
            ),
          ],
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
              decoration: BoxDecoration(color: prStateColor(d.state, draft: d.isDraft), borderRadius: BorderRadius.circular(10)),
              child: Text(stateLabel, style: const TextStyle(color: Colors.white, fontSize: 11.5, fontWeight: FontWeight.w600)),
            ),
            const SizedBox(width: 10),
            Flexible(
              child: Text(
                '${d.author} 想把 ${d.commits.length} 个提交从 ${d.headRef} 合入 ${d.baseRef}',
                overflow: TextOverflow.ellipsis,
                style: prMuted,
              ),
            ),
          ],
        ),
      ],
    );
  }

  Widget _card(Widget child) => Container(
        decoration: BoxDecoration(
          color: IntelliJTheme.panelBg,
          borderRadius: BorderRadius.circular(6),
          border: Border.all(color: IntelliJTheme.borderSubtle),
        ),
        child: child,
      );

  List<Widget> _timeline(List<PrTimelineItem> items) {
    final out = <Widget>[];
    var i = 0;
    while (i < items.length) {
      final t = items[i];
      if (t.kind == 'committed') {
        // 连续的提交合成一组。
        final group = <PrTimelineItem>[];
        while (i < items.length && items[i].kind == 'committed') {
          group.add(items[i++]);
        }
        out.add(_event(
          Icons.commit,
          '${group.first.actor} 添加了 ${group.length} 个提交',
          group.first.date,
          children: [
            for (final c in group)
              Padding(
                padding: const EdgeInsets.only(left: 26, top: 3),
                child: Row(
                  children: [
                    Text(c.extra ?? '', style: const TextStyle(color: IntelliJTheme.accentBlue, fontSize: 12, fontFamily: IntelliJMetrics.codeFontFamily)),
                    const SizedBox(width: 8),
                    Expanded(child: Text(c.body.split('\n').first, overflow: TextOverflow.ellipsis, style: prText)),
                  ],
                ),
              ),
          ],
        ));
        continue;
      }
      i++;
      switch (t.kind) {
        case 'commented':
          out.add(Padding(padding: const EdgeInsets.only(top: 10), child: _card(PrCommentView(author: t.actor, date: t.date, body: t.body))));
        case 'reviewed':
          final (label, color) = switch (t.state) {
            'approved' => ('approved', const Color(0xFF5FB865)),
            'changes_requested' => ('requested changes', const Color(0xFFE5534B)),
            'dismissed' => ('review dismissed', IntelliJTheme.textMuted),
            _ => ('reviewed', IntelliJTheme.textSecondary),
          };
          final badge = Text(label, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600));
          if (t.body.trim().isEmpty) {
            out.add(_event(t.state == 'approved' ? Icons.check_circle_outline : Icons.rate_review_outlined, '${t.actor} $label', t.date, color: color));
          } else {
            out.add(Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _card(PrCommentView(author: t.actor, date: t.date, body: t.body, badge: badge)),
            ));
          }
        case 'labeled' || 'unlabeled':
          out.add(_event(Icons.label_outline, '${t.actor} ${t.kind == 'labeled' ? '添加了标签' : '移除了标签'} ${t.extra ?? ''}', t.date));
        case 'review_requested' || 'review_request_removed':
          out.add(_event(Icons.person_add_alt, '${t.actor} ${t.kind == 'review_requested' ? '请求' : '取消请求'} ${t.extra ?? ''} 评审', t.date));
        case 'assigned' || 'unassigned':
          out.add(_event(Icons.person_outline, '${t.actor} ${t.kind == 'assigned' ? '指派给' : '取消指派'} ${t.extra ?? ''}', t.date));
        case 'merged':
          out.add(_event(Icons.merge, '${t.actor} 合并了这个 PR', t.date, color: const Color(0xFFA371F7)));
        case 'closed':
          out.add(_event(Icons.block, '${t.actor} 关闭了这个 PR', t.date, color: const Color(0xFFE5534B)));
        case 'reopened':
          out.add(_event(Icons.replay, '${t.actor} 重新打开了这个 PR', t.date));
        case 'head_ref_force_pushed':
          out.add(_event(Icons.upload, '${t.actor} 强制推送了分支', t.date));
        case 'renamed':
          out.add(_event(Icons.edit_outlined, '${t.actor} 把标题改为 ${t.extra ?? ''}', t.date));
        case 'ready_for_review':
          out.add(_event(Icons.visibility_outlined, '${t.actor} 标记为可评审', t.date));
        case 'convert_to_draft':
          out.add(_event(Icons.edit_note, '${t.actor} 转为草稿', t.date));
        case 'cross-referenced':
          out.add(_event(Icons.link, '${t.actor} 在别处引用了这个 PR', t.date));
        default:
          break; // 订阅、提及等噪音事件不显示
      }
    }
    return out;
  }

  Widget _event(IconData icon, String text, DateTime? date, {Color? color, List<Widget> children = const []}) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: color ?? IntelliJTheme.textSecondary),
              const SizedBox(width: 10),
              Flexible(child: Text(text, overflow: TextOverflow.ellipsis, style: prText)),
              const SizedBox(width: 8),
              Text(prDateTime(date), style: prMuted),
            ],
          ),
          ...children,
        ],
      ),
    );
  }
}
