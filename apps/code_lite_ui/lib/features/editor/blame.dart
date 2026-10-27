import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';
import '../git/diff_view.dart';
import 'context_menu_region.dart';
import 'editor_appearance.dart';
import 'visible_lines.dart';
import '../notifications/notifications.dart';

const String _uncommitted = '0000000000000000000000000000000000000000';
const double _lineHeight = 20;

class BlameCommit {
  const BlameCommit({
    required this.hash,
    required this.author,
    required this.email,
    required this.time,
    required this.summary,
    required this.path,
    this.previousHash,
    this.previousPath,
  });

  final String hash;
  final String author;
  final String email;
  final DateTime time;
  final String summary;

  /// 该提交里这个文件的路径(改名后与当前路径不同)。
  final String path;
  final String? previousHash;
  final String? previousPath;

  bool get isUncommitted => hash == _uncommitted;
  String get short => hash.substring(0, 8);

  factory BlameCommit.fromJson(Map<String, dynamic> j, String fallbackPath) => BlameCommit(
        hash: j['hash'] as String,
        author: j['author'] as String? ?? '',
        email: j['email'] as String? ?? '',
        time: DateTime.fromMillisecondsSinceEpoch(((j['time'] as num?) ?? 0).toInt() * 1000),
        summary: j['summary'] as String? ?? '',
        path: j['path'] as String? ?? fallbackPath,
        previousHash: j['previous_hash'] as String?,
        previousPath: j['previous_path'] as String?,
      );
}

/// 一个文件某个版本的逐行 blame。
class BlameData {
  BlameData(this.lines, this.commits) {
    var oldest = DateTime(9999), newest = DateTime(0);
    for (final c in commits.values) {
      if (c.isUncommitted) continue;
      if (c.time.isBefore(oldest)) oldest = c.time;
      if (c.time.isAfter(newest)) newest = c.time;
    }
    _oldest = oldest;
    _newest = newest;
  }

  final List<String> lines;
  final Map<String, BlameCommit> commits;
  late final DateTime _oldest;
  late final DateTime _newest;

  BlameCommit? at(int line) => line >= 0 && line < lines.length ? commits[lines[line]] : null;

  /// 0 = 最旧,1 = 最新(按 Age 着色用)。
  double age(BlameCommit c) {
    final span = _newest.difference(_oldest).inSeconds;
    if (span <= 0) return 1;
    return c.time.difference(_oldest).inSeconds / span;
  }

  /// 读取 blame。[contents] 传编辑器当前文本,未保存的改动也能对上行号。失败返回 null。
  static Future<BlameData?> load(ApiClient client, String path, {String? rev, String? contents}) async {
    final res = await client.gitCall('git.blame', {
      'path': path,
      if (rev != null) 'rev': rev,
      if (contents != null) 'contents': contents,
    });
    return fromResult(res, path);
  }

  /// `git.blame` 一类调用的返回(`{status, lines, commits}`);失败返回 null。
  static BlameData? fromResult(Map<String, dynamic> res, String path) {
    if (res['status'] != 'ok') return null;
    final raw = (res['commits'] as Map?) ?? const {};
    return BlameData(
      [for (final h in (res['lines'] as List? ?? const [])) h as String],
      {for (final e in raw.entries) e.key as String: BlameCommit.fromJson(Map<String, dynamic>.from(e.value as Map), path)},
    );
  }
}

/// 注释栏里的日期:今天的提交显示 Today(同 IntelliJ),其它按 年/月/日。按本地时间的日历日算。
String blameDate(DateTime t, {DateTime? now}) {
  final n = now ?? DateTime.now();
  final l = t.toLocal();
  if (l.year == n.year && l.month == n.month && l.day == n.day) return 'Today';
  return '${l.year}/${l.month}/${l.day}';
}

String _name(BlameCommit c, BlameNameMode mode) {
  final parts = c.author.trim().split(RegExp(r'\s+')).where((p) => p.isNotEmpty).toList();
  return switch (mode) {
    BlameNameMode.full => c.author,
    BlameNameMode.first => parts.isEmpty ? c.author : parts.first,
    BlameNameMode.last => parts.isEmpty ? c.author : parts.last,
    BlameNameMode.initials => parts.map((p) => p[0].toUpperCase()).join(),
    BlameNameMode.email => c.email,
  };
}

/// 注释栏里的名字最多显示几个字符,多的用 ... 省略(悬停看完整的,见 [blameTooltip])。
const int blameNameMaxChars = 6;

/// 名字超过 [blameNameMaxChars] 个字符时截断加 ...(按字符算,中文、emoji 不会截出半个)。
String blameShortName(String name) {
  final chars = name.runes.toList();
  return chars.length <= blameNameMaxChars ? name : '${String.fromCharCodes(chars.take(blameNameMaxChars))}...';
}

/// 注释栏一行显示的文字(未提交的行留空,与 IntelliJ 一致)。
String blameLabel(BlameCommit? c, EditorAppearance a, {DateTime? now}) {
  if (c == null || c.isUncommitted) return '';
  return [
    if (a.blameRevision) c.short,
    if (a.blameDate) blameDate(c.time, now: now),
    if (a.blameAuthor) blameShortName(_name(c, a.blameNames)),
  ].join('  ');
}

/// 鼠标停在注释上的小窗:第一行完整的作者名,第二行提交号 · 日期 · 提交说明。编辑器和 Merge 窗口共用。
String blameTooltip(BlameCommit c) => '${c.author}\n${c.short} · ${blameDate(c.time)} · ${c.summary}';

const List<Color> _authorPalette = [
  Color(0xFF3574F0),
  Color(0xFF59A869),
  Color(0xFFC77DBB),
  Color(0xFFE5A84B),
  Color(0xFF3FB4B4),
  Color(0xFFE07B53),
  Color(0xFFB4A0E5),
  Color(0xFFDB5860),
];

Color? blameBackground(BlameCommit? c, BlameData data, EditorAppearance a) {
  if (c == null || c.isUncommitted) return null;
  switch (a.blameColors) {
    case BlameColorMode.none:
      return null;
    case BlameColorMode.author:
      final i = c.author.codeUnits.fold<int>(0, (h, u) => (h * 31 + u) & 0x7fffffff) % _authorPalette.length;
      return _authorPalette[i].withValues(alpha: 0.13);
    case BlameColorMode.age:
      // 越新越亮。
      return IntelliJTheme.accentYellow.withValues(alpha: 0.04 + 0.22 * data.age(c));
  }
}

/// 行号左侧的 blame 注释栏。每行高度与代码行一致,右键弹出注释菜单。
class BlameColumn extends StatelessWidget {
  const BlameColumn({
    super.key,
    required this.data,
    required this.appearance,
    required this.totalLines,
    required this.menuBuilder,
    this.loading = false,
    this.lineHeight = _lineHeight,
    this.lineOfRow,
  });

  /// 第几个可见行是文档的第几行(代码折叠收起了几段时和编辑区对齐);null = 一一对应。
  final int Function(int row)? lineOfRow;

  /// 与编辑区一致的行高(随字号变化)。
  final double lineHeight;

  final BlameData? data;
  final EditorAppearance appearance;
  final int totalLines;
  final bool loading;
  final List<Widget> Function(int line, BlameCommit? commit) menuBuilder;

  static const _style = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 11.5);

  /// 一行注释;有提交的行悬停弹出完整作者名和提交信息。
  Widget _row(BlameData d, BlameCommit? c) {
    final row = Container(
      color: blameBackground(c, d, appearance),
      padding: const EdgeInsets.symmetric(horizontal: 8),
      alignment: Alignment.centerLeft,
      child: Text(blameLabel(c, appearance), maxLines: 1, overflow: TextOverflow.ellipsis, style: _style),
    );
    if (c == null || c.isUncommitted) return row;
    return Tooltip(message: blameTooltip(c), waitDuration: const Duration(milliseconds: 400), child: row);
  }

  @override
  Widget build(BuildContext context) {
    final d = data;
    var width = 60.0;
    if (d != null) {
      // 按像素最宽的一条定宽(比例字体下字符数最多的不一定最宽,比如 "2026/1/11" 比 "2026/6/23" 窄)。
      final style = DefaultTextStyle.of(context).style.merge(_style);
      final scaler = MediaQuery.textScalerOf(context);
      var widest = 0.0;
      for (final label in {for (final c in d.commits.values) blameLabel(c, appearance)}) {
        final tp = TextPainter(
          text: TextSpan(text: label, style: style),
          textDirection: TextDirection.ltr,
          textScaler: scaler,
        )..layout();
        if (tp.width > widest) widest = tp.width;
      }
      // 左右内边距各 8,再留 4 像素余量防取整误差。
      width = (widest + 20).ceilToDouble().clamp(60.0, 360.0);
    }
    return ContextMenuRegion(
      menuBuilder: (pos) {
        final row = ((pos.dy - 8) / lineHeight).floor().clamp(0, totalLines - 1);
        final line = lineOfRow?.call(row) ?? row;
        return menuBuilder(line, d?.at(line));
      },
      child: Container(
        width: width,
        padding: const EdgeInsets.symmetric(vertical: 8),
        decoration: const BoxDecoration(
          color: IntelliJTheme.editorBg,
          border: Border(right: BorderSide(color: IntelliJTheme.borderSubtle)),
        ),
        child: d == null
            ? SizedBox(
                height: totalLines * lineHeight,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: Text(loading ? 'blame…' : '', style: _style.copyWith(color: IntelliJTheme.textMuted)),
                ),
              )
            // 只构建视口附近的行(与编辑区共用同一个纵向滚动)。
            : SizedBox(
                height: totalLines * lineHeight,
                child: VisibleLines(
                  lineCount: totalLines,
                  lineHeight: lineHeight,
                  topPadding: 8,
                  builder: (context, first, last) => Stack(
                    children: [
                      for (var i = first; i <= last; i++)
                        Positioned(
                          key: ValueKey(i),
                          top: i * lineHeight,
                          left: 0,
                          right: 0,
                          height: lineHeight,
                          child: _row(d, d.at(lineOfRow?.call(i) ?? i)),
                        ),
                    ],
                  ),
                ),
              ),
      ),
    );
  }
}

/// Blame 注释栏的右键菜单(Close Annotations / Show Diff / View ▸ / Copy Revision Number /
/// Annotate Revision / Annotate Previous Revision / Show in File History)。
List<Widget> blameMenu({
  required BuildContext context,
  required BlameCommit? commit,
  required EditorAppearance appearance,
  required ApiClient client,
  required VoidCallback onClose,
  void Function(String hash, String path)? onShowInHistory,
}) {
  final c = commit;
  final committed = c != null && !c.isUncommitted;
  return [
    MenuItemButton(onPressed: onClose, child: const Text('Close Annotations')),
    MenuItemButton(
      leadingIcon: const Icon(Icons.compare_arrows, size: 16),
      onPressed: committed ? () => showBlameDiff(context, client, c) : null,
      child: const Text('Show Diff'),
    ),
    SubmenuButton(
      menuChildren: [
        CheckboxMenuButton(
          value: appearance.blameRevision,
          onChanged: (_) => appearance.toggleBlameRevision(),
          child: const Text('Revision'),
        ),
        CheckboxMenuButton(
          value: appearance.blameDate,
          onChanged: (_) => appearance.toggleBlameDate(),
          child: const Text('Date'),
        ),
        CheckboxMenuButton(
          value: appearance.blameAuthor,
          onChanged: (_) => appearance.toggleBlameAuthor(),
          child: const Text('Author'),
        ),
        const MenuDivider(),
        SubmenuButton(
          menuChildren: [
            for (final (mode, label) in const [
              (BlameColorMode.none, 'Hide'),
              (BlameColorMode.author, 'Color by Author'),
              (BlameColorMode.age, 'Color by Age'),
            ])
              RadioMenuButton<BlameColorMode>(
                value: mode,
                groupValue: appearance.blameColors,
                onChanged: (m) => appearance.setBlameColors(m!),
                child: Text(label),
              ),
          ],
          child: const Text('Colors'),
        ),
        SubmenuButton(
          menuChildren: [
            for (final (mode, label) in const [
              (BlameNameMode.full, 'Full Name'),
              (BlameNameMode.first, 'First Name'),
              (BlameNameMode.last, 'Last Name'),
              (BlameNameMode.initials, 'Initials'),
              (BlameNameMode.email, 'Email'),
            ])
              RadioMenuButton<BlameNameMode>(
                value: mode,
                groupValue: appearance.blameNames,
                onChanged: (m) => appearance.setBlameNames(m!),
                child: Text(label),
              ),
          ],
          child: const Text('Names'),
        ),
      ],
      child: const Text('View'),
    ),
    MenuItemButton(
      leadingIcon: const Icon(Icons.copy, size: 16),
      onPressed: committed ? () => Clipboard.setData(ClipboardData(text: c.hash)) : null,
      child: const Text('Copy Revision Number'),
    ),
    const MenuDivider(),
    MenuItemButton(
      leadingIcon: const Icon(Icons.article_outlined, size: 16),
      onPressed: committed ? () => showAnnotatedRevision(context, client, appearance, c.hash, c.path) : null,
      child: const Text('Annotate Revision'),
    ),
    MenuItemButton(
      leadingIcon: const Icon(Icons.article_outlined, size: 16),
      onPressed: committed && c.previousHash != null
          ? () => showAnnotatedRevision(context, client, appearance, c.previousHash!, c.previousPath ?? c.path)
          : null,
      child: const Text('Annotate Previous Revision'),
    ),
    MenuItemButton(
      onPressed: committed && onShowInHistory != null ? () => onShowInHistory(c.hash, c.path) : null,
      child: const Text('Show in File History'),
    ),
  ];
}

Future<void> showBlameDiff(BuildContext context, ApiClient client, BlameCommit c) async {
  final res = await client.gitCall('git.commit_file_diff', {'hash': c.hash, 'path': c.path});
  if (!context.mounted) return;
  await _showPanel(
    context,
    title: '${c.path}  (${c.short} — ${c.summary})',
    child: DiffView(diff: res['diff'] as String? ?? (res['error'] as String? ?? '')),
  );
}

/// Annotate Revision:只读查看 [rev] 时的文件内容,左侧带当时的 blame。
Future<void> showAnnotatedRevision(
  BuildContext context,
  ApiClient client,
  EditorAppearance appearance,
  String rev,
  String path,
) async {
  final file = await client.gitCall('git.file_at', {'hash': rev, 'path': path});
  final blame = await BlameData.load(client, path, rev: rev);
  if (!context.mounted) return;
  if (file['status'] != 'ok' || file['binary'] == true) {
    showNotice(context, '无法读取 $path @ ${rev.substring(0, 8)}', error: true);
    return;
  }
  final lines = (file['content'] as String? ?? '').split('\n');
  await _showPanel(
    context,
    title: '$path @ ${rev.substring(0, 8)}',
    child: Container(
      color: IntelliJTheme.editorBg,
      child: SingleChildScrollView(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            BlameColumn(
              data: blame,
              appearance: appearance,
              totalLines: lines.length,
              menuBuilder: (_, c) => [
                MenuItemButton(
                  onPressed: c == null || c.isUncommitted ? null : () => showBlameDiff(context, client, c),
                  child: const Text('Show Diff'),
                ),
                MenuItemButton(
                  onPressed: c == null || c.isUncommitted ? null : () => Clipboard.setData(ClipboardData(text: c.hash)),
                  child: const Text('Copy Revision Number'),
                ),
              ],
            ),
            Expanded(
              child: SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
                child: SelectionArea(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      for (final l in lines)
                        SizedBox(
                          height: _lineHeight,
                          child: Text(
                            l.isEmpty ? ' ' : l,
                            softWrap: false,
                            style: const TextStyle(
                              fontFamily: 'Menlo',
                              fontFamilyFallback: ['monospace'],
                              fontSize: 12,
                              height: 1.4,
                              color: IntelliJTheme.textPrimary,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    ),
  );
}

/// Add Mnemonic Bookmark:0-9 / A-Z 的选择网格。已被其他行占用的助记符标灰但仍可选(会挪过来)。
Future<String?> pickMnemonic(BuildContext context, {String? current, Set<String> taken = const {}}) {
  const keys = '1234567890ABCDEFGHIJKLMNOPQRSTUVWXYZ';
  return showDialog<String>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: IntelliJTheme.panelBg,
      title: const Text('Add Mnemonic Bookmark', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
      content: SizedBox(
        width: 360,
        child: Wrap(
          spacing: 6,
          runSpacing: 6,
          children: [
            for (final k in keys.split(''))
              InkWell(
                onTap: () => Navigator.pop(ctx, k),
                borderRadius: BorderRadius.circular(4),
                child: Container(
                  width: 30,
                  height: 30,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: k == current
                        ? IntelliJTheme.accentBlue.withValues(alpha: 0.35)
                        : taken.contains(k)
                            ? IntelliJTheme.hoverBg
                            : IntelliJTheme.editorBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: IntelliJTheme.border),
                  ),
                  child: Text(
                    k,
                    style: TextStyle(
                      color: taken.contains(k) && k != current ? IntelliJTheme.textMuted : IntelliJTheme.textHigh,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
      actions: [
        TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('Cancel')),
      ],
    ),
  );
}

Future<void> _showPanel(BuildContext context, {required String title, required Widget child}) {
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
                    child: Text(
                      title,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5),
                    ),
                  ),
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
