import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/github/github_service.dart';
import '../../core/theme/intellij_theme.dart';
import 'pr_store.dart';

const TextStyle prText = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12.5);
const TextStyle prMuted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);
const TextStyle prLink = TextStyle(color: IntelliJTheme.accentBlue, fontSize: 12.5);

String prDate(DateTime? d) => d == null ? '' : '${d.year}/${d.month}/${d.day}';

String prDateTime(DateTime? d) {
  if (d == null) return '';
  String two(int v) => v.toString().padLeft(2, '0');
  return '${prDate(d)} ${two(d.hour)}:${two(d.minute)}';
}

void prSnack(BuildContext context, String message, {bool error = false}) {
  ScaffoldMessenger.maybeOf(context)?.showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? const Color(0xFF5E2B2E) : null,
  ));
}

/// 检查状态的小图标:失败红叉、进行中黄点、通过绿勾。
Widget checksIcon(ChecksState s, {double size = 16}) => switch (s) {
      ChecksState.none => const SizedBox.shrink(),
      ChecksState.success => Icon(Icons.check_circle, size: size, color: const Color(0xFF5FB865)),
      ChecksState.pending => Icon(Icons.timelapse, size: size, color: const Color(0xFFE5C07B)),
      ChecksState.failure => Icon(Icons.cancel, size: size, color: const Color(0xFFE5534B)),
    };

/// 「git-pull-request」形状的状态色:Open 绿、Draft 灰、Merged 紫、Closed 红。
Color prStateColor(String state, {bool draft = false}) {
  if (draft) return IntelliJTheme.textMuted;
  return switch (state) {
    'MERGED' => const Color(0xFFA371F7),
    'CLOSED' => const Color(0xFFE5534B),
    _ => const Color(0xFF5FB865),
  };
}

/// 一段评审评论会话(根评论 + 回复),下方可回复。
class PrCommentThread extends StatefulWidget {
  const PrCommentThread({super.key, required this.session, required this.thread});

  final PrSession session;
  final List<PrReviewComment> thread;

  @override
  State<PrCommentThread> createState() => _PrCommentThreadState();
}

class _PrCommentThreadState extends State<PrCommentThread> {
  bool _replying = false;

  @override
  Widget build(BuildContext context) {
    return Container(
      margin: const EdgeInsets.fromLTRB(40, 4, 40, 6),
      decoration: BoxDecoration(
        color: IntelliJTheme.panelBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: IntelliJTheme.border),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          for (final c in widget.thread) PrCommentView(author: c.author, date: c.createdAt, body: c.body),
          if (_replying)
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 10),
              child: PrCommentComposer(
                hint: '回复…',
                submitLabel: 'Reply',
                onCancel: () => setState(() => _replying = false),
                onSubmit: (text) async {
                  await widget.session.reply(widget.thread.first.id, text);
                  if (mounted) setState(() => _replying = false);
                },
              ),
            )
          else
            Align(
              alignment: Alignment.centerLeft,
              child: Padding(
                padding: const EdgeInsets.fromLTRB(6, 0, 6, 6),
                child: TextButton(
                  onPressed: () => setState(() => _replying = true),
                  child: const Text('Reply', style: prLink),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// 一条评论:作者 · 时间,下面是正文(可选中复制)。
class PrCommentView extends StatelessWidget {
  const PrCommentView({super.key, required this.author, required this.date, required this.body, this.badge});

  final String author;
  final DateTime? date;
  final String body;

  /// 作者后面的附加说明,如「approved」。
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(Icons.account_circle, size: 18, color: IntelliJTheme.textSecondary),
              const SizedBox(width: 6),
              Flexible(
                child: Text(
                  author,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5, fontWeight: FontWeight.w600),
                ),
              ),
              if (badge != null) ...[const SizedBox(width: 6), badge!],
              const SizedBox(width: 8),
              Text(prDateTime(date), style: prMuted),
            ],
          ),
          if (body.trim().isNotEmpty) ...[
            const SizedBox(height: 6),
            Padding(
              padding: const EdgeInsets.only(left: 24),
              child: SelectableText(body.trim(), style: prText.copyWith(height: 1.45)),
            ),
          ],
        ],
      ),
    );
  }
}

/// 多行评论输入框:⌘↩ 提交,Esc 取消。提交出错时在框下显示原因,内容保留。
class PrCommentComposer extends StatefulWidget {
  const PrCommentComposer({
    super.key,
    required this.onSubmit,
    this.onCancel,
    this.hint = '写评论…',
    this.submitLabel = 'Comment',
    this.autofocus = true,
  });

  final Future<void> Function(String text) onSubmit;
  final VoidCallback? onCancel;
  final String hint;
  final String submitLabel;
  final bool autofocus;

  @override
  State<PrCommentComposer> createState() => _PrCommentComposerState();
}

class _PrCommentComposerState extends State<PrCommentComposer> {
  final TextEditingController _text = TextEditingController();
  bool _busy = false;
  String? _error;

  @override
  void dispose() {
    _text.dispose();
    super.dispose();
  }

  Future<void> _submit() async {
    final value = _text.text.trim();
    if (value.isEmpty || _busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.onSubmit(value);
      if (!mounted) return;
      _text.clear();
    } on GhException catch (e) {
      if (mounted) setState(() => _error = e.message);
    }
    if (mounted) setState(() => _busy = false);
  }

  @override
  Widget build(BuildContext context) {
    return CallbackShortcuts(
      bindings: {
        const SingleActivator(LogicalKeyboardKey.enter, meta: true): _submit,
        const SingleActivator(LogicalKeyboardKey.enter, control: true): _submit,
        if (widget.onCancel != null) const SingleActivator(LogicalKeyboardKey.escape): widget.onCancel!,
      },
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          TextField(
            controller: _text,
            autofocus: widget.autofocus,
            minLines: 3,
            maxLines: 10,
            style: prText,
            decoration: InputDecoration(
              hintText: widget.hint,
              hintStyle: prMuted,
              isDense: true,
              filled: true,
              fillColor: IntelliJTheme.editorBg,
              border: const OutlineInputBorder(borderSide: BorderSide(color: IntelliJTheme.border)),
              enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: IntelliJTheme.border)),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(_error!, style: const TextStyle(color: Color(0xFFE5534B), fontSize: 12)),
            ),
          const SizedBox(height: 8),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              if (widget.onCancel != null)
                TextButton(onPressed: _busy ? null : widget.onCancel, child: const Text('Cancel')),
              const SizedBox(width: 6),
              FilledButton(
                onPressed: _busy ? null : _submit,
                style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
                child: Text(_busy ? '提交中…' : widget.submitLabel),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

/// 提交评审:写总评,选 Approve / Request Changes / Comment。PR 作者不能批准或要求修改自己的 PR。
Future<void> showSubmitReviewDialog(BuildContext context, PrSession session) async {
  final text = TextEditingController();
  final isAuthor = session.detail?.author == session.viewer && session.viewer.isNotEmpty;
  String? error;
  var busy = false;
  await showDialog<void>(
    context: context,
    builder: (ctx) => StatefulBuilder(
      builder: (ctx, setD) {
        Future<void> submit(String event) async {
          if (event != 'APPROVE' && text.text.trim().isEmpty) {
            setD(() => error = event == 'COMMENT' ? '评论内容不能为空' : '要求修改时请写明原因');
            return;
          }
          setD(() {
            busy = true;
            error = null;
          });
          try {
            await session.submitReview(event, text.text);
            if (ctx.mounted) Navigator.pop(ctx);
          } on GhException catch (e) {
            setD(() {
              busy = false;
              error = e.message;
            });
          }
        }

        return AlertDialog(
          backgroundColor: IntelliJTheme.panelBg,
          title: Text('Submit Review — #${session.number}', style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
          content: SizedBox(
            width: 460,
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                TextField(
                  controller: text,
                  autofocus: true,
                  minLines: 4,
                  maxLines: 10,
                  style: prText,
                  decoration: const InputDecoration(hintText: '评审意见(可选)', border: OutlineInputBorder(), isDense: true),
                ),
                if (isAuthor)
                  const Padding(
                    padding: EdgeInsets.only(top: 8),
                    child: Text('这是你自己的 PR:GitHub 只允许评论,不能批准或要求修改。', style: prMuted),
                  ),
                if (error != null)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Text(error!, style: const TextStyle(color: Color(0xFFE5534B), fontSize: 12)),
                  ),
              ],
            ),
          ),
          actions: [
            TextButton(onPressed: busy ? null : () => Navigator.pop(ctx), child: const Text('Cancel')),
            OutlinedButton(onPressed: busy ? null : () => submit('COMMENT'), child: const Text('Comment')),
            OutlinedButton(
              onPressed: busy || isAuthor ? null : () => submit('REQUEST_CHANGES'),
              child: const Text('Request Changes'),
            ),
            FilledButton(
              onPressed: busy || isAuthor ? null : () => submit('APPROVE'),
              style: FilledButton.styleFrom(backgroundColor: const Color(0xFF3F8F4A)),
              child: const Text('Approve'),
            ),
          ],
        );
      },
    ),
  );
  text.dispose();
}
