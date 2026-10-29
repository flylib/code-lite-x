// 通知(同 IntelliJ):提示和错误在窗口右下角弹一张卡片(balloon),过一会儿自己收起;
// 错误和普通提示各记最近 [NotificationCenter.maxErrors] 条,在 Problems 工具窗(⌘6,按钮在右活动条最下面)里看:
// 「全部 / Errors / Notify」三个标签,全部是两类按时间排在一起(新的在前)。
// 全应用一份(不分项目),放在 MaterialApp 上面,对话框里也能找到。

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/l10n/l10n.dart';
import '../../core/theme/intellij_theme.dart';

/// 一条通知。[title] 是「xxx 失败」这样的短句,[body] 是原因(可能为空)。
class Notice {
  Notice({required this.id, required this.title, required this.body, required this.error, required this.time});

  final int id;
  final String title;
  final String body;
  final bool error;
  final DateTime time;

  String get text => body.isEmpty ? title : '$title: $body';
}

/// `Update 失败: 分支没有上游` → (`Update 失败`, `分支没有上游`)。前面一截不像标题(太长)就整条当正文的标题。
(String, String) splitNotice(String message) {
  final m = message.trim();
  final i = m.indexOf(RegExp(r'[:：]\s?'));
  if (i <= 0 || i > 40) return (m, '');
  final body = m.substring(i + 1).trim();
  return (m.substring(0, i).trim(), body);
}

/// Problems 工具窗的标签。
enum ProblemsFilter { all, errors, notify }

class NotificationCenter extends ChangeNotifier {
  /// 错误、普通提示各最多留几条(新的在前,多了丢最旧的)。
  static const int maxErrors = 10;

  /// 同时最多弹几张卡片(再来新的就顶掉最早的)。
  static const int maxBalloons = 3;

  int _nextId = 0;

  /// 最近的错误,新的在前。
  final List<Notice> errors = [];

  /// 最近的普通提示(已推送、已提交……),新的在前。
  final List<Notice> notifies = [];

  /// Problems 工具窗选中的标签(关了再开还是它)。
  ProblemsFilter filter = ProblemsFilter.all;

  /// 错误和提示按时间排在一起,新的在前。
  List<Notice> get all => [...errors, ...notifies]..sort((a, b) => b.id.compareTo(a.id));

  List<Notice> listFor(ProblemsFilter f) => switch (f) {
        ProblemsFilter.all => all,
        ProblemsFilter.errors => errors,
        ProblemsFilter.notify => notifies,
      };

  void setFilter(ProblemsFilter f) {
    if (filter == f) return;
    filter = f;
    notifyListeners();
  }

  /// 正在右下角弹着的卡片,旧的在前(新的在最下面,贴着状态栏)。
  final List<Notice> balloons = [];

  /// 有没看过的错误:Problems 按钮和铃铛上亮红点。
  bool unread = false;

  /// Problems 工具窗正开着(这时来的错误算看过了)。
  bool _viewing = false;

  void post(String message, {bool error = false}) {
    final (title, body) = splitNotice(message);
    if (title.isEmpty) return;
    final notice = Notice(id: _nextId++, title: title, body: body, error: error, time: DateTime.now());
    final log = error ? errors : notifies;
    log.insert(0, notice);
    if (log.length > maxErrors) log.removeRange(maxErrors, log.length);
    if (error && !_viewing) unread = true;
    balloons.add(notice);
    if (balloons.length > maxBalloons) balloons.removeRange(0, balloons.length - maxBalloons);
    notifyListeners();
  }

  void dismiss(int id) {
    final before = balloons.length;
    balloons.removeWhere((n) => n.id == id);
    if (balloons.length != before) notifyListeners();
  }

  /// Problems 工具窗打开 / 关上时调用:开着的时候错误不算没看过。
  void setViewing(bool viewing) {
    _viewing = viewing;
    if (viewing && unread) {
      unread = false;
      notifyListeners();
    }
  }

  /// 清空 [f] 标签里的(全部 = 两类都清)。
  void clear([ProblemsFilter f = ProblemsFilter.all]) {
    if (f != ProblemsFilter.notify) {
      errors.clear();
      unread = false;
    }
    if (f != ProblemsFilter.errors) notifies.clear();
    notifyListeners();
  }
}

class NotificationScope extends InheritedNotifier<NotificationCenter> {
  const NotificationScope({super.key, required NotificationCenter center, required super.child}) : super(notifier: center);

  /// 只取不订阅(发通知的地方用不着跟着重建)。
  static NotificationCenter? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<NotificationScope>()?.notifier;
}

/// 发一条提示 / 错误:有 [NotificationScope] 就进通知(右下角卡片,错误还记进日志),
/// 没有(单独测试一个面板时)退回 SnackBar。
void showNotice(BuildContext context, String message, {bool error = false}) {
  if (!context.mounted) return;
  final center = NotificationScope.maybeOf(context);
  if (center != null) {
    center.post(message, error: error);
    return;
  }
  final messenger = ScaffoldMessenger.maybeOf(context);
  messenger?.hideCurrentSnackBar();
  messenger?.showSnackBar(SnackBar(
    content: Text(message),
    backgroundColor: error ? const Color(0xFF5E2B2E) : null,
    duration: Duration(seconds: error ? 8 : 3),
  ));
}

/// 窗口右下角弹出的卡片。放在工作区上面的 Stack 里。
class NotificationOverlay extends StatelessWidget {
  const NotificationOverlay({super.key, required this.center});

  final NotificationCenter center;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.end,
          children: [
            for (final n in center.balloons)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: _Balloon(key: ValueKey('notice-${n.id}'), notice: n, onClose: () => center.dismiss(n.id)),
              ),
          ],
        );
      },
    );
  }
}

const double _cardWidth = 380;

BoxDecoration _cardDecoration() => BoxDecoration(
      color: IntelliJTheme.popupBg,
      borderRadius: BorderRadius.circular(8),
      border: Border.all(color: IntelliJTheme.border),
      boxShadow: const [BoxShadow(color: Color(0x66000000), blurRadius: 16, offset: Offset(0, 4))],
    );

Widget _levelIcon(bool error) => Icon(
      error ? Icons.error_outline : Icons.info_outline,
      size: 16,
      color: error ? IntelliJTheme.diagError : IntelliJTheme.link,
    );

String _clock(DateTime t) => '${t.hour.toString().padLeft(2, '0')}:${t.minute.toString().padLeft(2, '0')}:${t.second.toString().padLeft(2, '0')}';

/// 一张弹出的卡片:图标、标题、原因、×。错误停 10 秒,提示 4 秒;鼠标停在上面时不收。
class _Balloon extends StatefulWidget {
  const _Balloon({super.key, required this.notice, required this.onClose});

  final Notice notice;
  final VoidCallback onClose;

  @override
  State<_Balloon> createState() => _BalloonState();
}

class _BalloonState extends State<_Balloon> {
  Timer? _timer;
  bool _hover = false;

  Duration get _life => widget.notice.error ? const Duration(seconds: 10) : const Duration(seconds: 4);

  @override
  void initState() {
    super.initState();
    _arm();
  }

  void _arm() {
    _timer?.cancel();
    _timer = Timer(_life, () {
      if (mounted && !_hover) widget.onClose();
    });
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final n = widget.notice;
    return MouseRegion(
      onEnter: (_) {
        _hover = true;
        _timer?.cancel();
      },
      onExit: (_) {
        _hover = false;
        _arm();
      },
      child: Container(
        width: _cardWidth,
        padding: const EdgeInsets.fromLTRB(12, 10, 6, 12),
        decoration: _cardDecoration(),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: _levelIcon(n.error)),
            const SizedBox(width: 10),
            Expanded(child: _NoticeText(notice: n, maxBodyLines: 4)),
            _IconBtn(key: const ValueKey('notice-close'), icon: Icons.close, tooltip: tr('关闭', 'Close'), onTap: widget.onClose),
          ],
        ),
      ),
    );
  }
}

class _NoticeText extends StatelessWidget {
  const _NoticeText({required this.notice, this.maxBodyLines});

  final Notice notice;
  final int? maxBodyLines;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        Text(
          notice.title,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600),
        ),
        if (notice.body.isNotEmpty) ...[
          const SizedBox(height: 4),
          Text(
            notice.body,
            maxLines: maxBodyLines,
            overflow: maxBodyLines == null ? null : TextOverflow.ellipsis,
            style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12.5, height: 1.4),
          ),
        ],
      ],
    );
  }
}

/// 底部的 Problems 工具窗(同 IntelliJ 的 Problems,⌘6):标题栏 Problems + 「全部 / Errors / Notify」标签(带条数)、—;
/// 左边一列竖着的工具按钮(复制全部、清空,都只管当前标签);右边按时间列出(新的在前),每条可复制;空的时候居中一行灰字。
class ProblemsPanel extends StatefulWidget {
  const ProblemsPanel({super.key, required this.center, required this.onHide});

  final NotificationCenter center;
  final VoidCallback onHide;

  @override
  State<ProblemsPanel> createState() => _ProblemsPanelState();
}

class _ProblemsPanelState extends State<ProblemsPanel> {
  @override
  void initState() {
    super.initState();
    // 打开着就算看过了;build 里不能通知,等这一帧画完
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) widget.center.setViewing(true);
    });
  }

  @override
  void dispose() {
    widget.center.setViewing(false);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final center = widget.center;
    return ListenableBuilder(
      listenable: center,
      builder: (context, _) {
        final filter = center.filter;
        final items = center.listFor(filter);
        Widget tab(ProblemsFilter f, String label, int count) {
          final selected = f == filter;
          return Padding(
            padding: const EdgeInsets.only(right: 4),
            child: InkWell(
              key: ValueKey('problems-tab-${f.name}'),
              onTap: () => center.setFilter(f),
              borderRadius: BorderRadius.circular(6),
              child: Container(
                height: 28,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                decoration: selected ? BoxDecoration(color: IntelliJTheme.chipBg, borderRadius: BorderRadius.circular(6)) : null,
                alignment: Alignment.center,
                child: Text.rich(
                  TextSpan(children: [
                    TextSpan(text: label, style: TextStyle(color: selected ? IntelliJTheme.textHigh : IntelliJTheme.textPrimary)),
                    if (count > 0) TextSpan(text: '  $count', style: const TextStyle(color: IntelliJTheme.textMuted)),
                  ]),
                  style: const TextStyle(fontSize: 13),
                ),
              ),
            ),
          );
        }

        return Container(
          color: IntelliJTheme.panelBg,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              // 标题栏(同 Git / 终端):工具窗名、选中的标签是圆角块,右边 ⋮ —
              Container(
                height: 40,
                padding: const EdgeInsets.only(left: 12, right: 6),
                child: Row(
                  children: [
                    Text(tr('问题', 'Problems'), style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600)),
                    const SizedBox(width: 16),
                    tab(ProblemsFilter.all, tr('全部', 'All'), center.errors.length + center.notifies.length),
                    tab(ProblemsFilter.errors, tr('错误', 'Errors'), center.errors.length),
                    tab(ProblemsFilter.notify, tr('通知', 'Notify'), center.notifies.length),
                    const Spacer(),
                    _IconBtn(icon: Icons.remove, tooltip: tr('隐藏', 'Hide'), onTap: widget.onHide, size: 16),
                  ],
                ),
              ),
              Expanded(
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    // 左边竖着的工具按钮
                    Container(
                      width: 30,
                      padding: const EdgeInsets.only(top: 4),
                      alignment: Alignment.topCenter,
                      child: Column(
                        children: [
                          _IconBtn(
                            key: const ValueKey('problems-copy-all'),
                            icon: Icons.content_copy,
                            tooltip: tr('复制全部', 'Copy All'),
                            size: 16,
                            onTap: items.isEmpty ? null : () => Clipboard.setData(ClipboardData(text: [for (final n in items) '[${_clock(n.time)}] ${n.text}'].join('\n'))),
                          ),
                          const SizedBox(height: 4),
                          _IconBtn(
                            key: const ValueKey('problems-clear'),
                            icon: Icons.delete_outline,
                            tooltip: tr('清空', 'Clear'),
                            size: 16,
                            onTap: items.isEmpty ? null : () => center.clear(filter),
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: items.isEmpty
                          ? Center(
                              child: Text(
                                switch (filter) {
                                  ProblemsFilter.all => tr('没有错误或通知。', 'No errors or notifications.'),
                                  ProblemsFilter.errors => tr('没有错误。', 'No errors.'),
                                  ProblemsFilter.notify => tr('没有通知。', 'No notifications.'),
                                },
                                key: const ValueKey('problems-empty'),
                                style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 13),
                              ),
                            )
                          : ListView.builder(
                              padding: const EdgeInsets.only(right: 8, bottom: 8),
                              itemCount: items.length,
                              itemBuilder: (context, i) => _ProblemRow(notice: items[i]),
                            ),
                    ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

/// 一条错误:图标、标题(加粗)和原因、时间、复制。悬停有底色。
class _ProblemRow extends StatefulWidget {
  const _ProblemRow({required this.notice});

  final Notice notice;

  @override
  State<_ProblemRow> createState() => _ProblemRowState();
}

class _ProblemRowState extends State<_ProblemRow> {
  bool _hover = false;

  @override
  Widget build(BuildContext context) {
    final n = widget.notice;
    return MouseRegion(
      onEnter: (_) => setState(() => _hover = true),
      onExit: (_) => setState(() => _hover = false),
      child: Container(
        key: ValueKey('problem-${n.id}'),
        padding: const EdgeInsets.fromLTRB(8, 6, 4, 6),
        decoration: BoxDecoration(color: _hover ? IntelliJTheme.hoverBg : null, borderRadius: BorderRadius.circular(4)),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Padding(padding: const EdgeInsets.only(top: 1), child: _levelIcon(n.error)),
            const SizedBox(width: 8),
            Expanded(
              child: Text.rich(
                TextSpan(children: [
                  TextSpan(text: n.title, style: const TextStyle(color: IntelliJTheme.textHigh, fontWeight: FontWeight.w600)),
                  if (n.body.isNotEmpty) TextSpan(text: '  ${n.body}', style: const TextStyle(color: IntelliJTheme.textPrimary)),
                ]),
                style: const TextStyle(fontSize: 12.5, height: 1.4),
              ),
            ),
            const SizedBox(width: 12),
            Text(_clock(n.time), style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12)),
            const SizedBox(width: 4),
            _IconBtn(icon: Icons.content_copy, tooltip: tr('复制', 'Copy'), onTap: () => Clipboard.setData(ClipboardData(text: n.text))),
          ],
        ),
      ),
    );
  }
}

class _IconBtn extends StatelessWidget {
  const _IconBtn({super.key, required this.icon, required this.tooltip, required this.onTap, this.size = 14});

  final IconData icon;
  final String tooltip;
  final VoidCallback? onTap;
  final double size;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 500),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.all(4),
            child: Icon(icon, size: size, color: onTap == null ? IntelliJTheme.textMuted.withValues(alpha: 0.5) : IntelliJTheme.textSecondary),
          ),
        ),
      );
}
