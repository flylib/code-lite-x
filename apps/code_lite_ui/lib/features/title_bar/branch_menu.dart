import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';
import '../git/branch_actions.dart';
import '../git/branch_menu_model.dart';
import '../git/branch_store.dart';
import 'anchored_popup.dart';

/// 标题栏上的当前分支;点开是 IntelliJ 那种分支弹窗:搜索框、Update / Commit / Push / New Branch,
/// 以及 Recent / Local / Remote 三棵分支树,点分支展开它的操作子菜单。
class BranchChip extends StatelessWidget {
  const BranchChip({super.key, required this.store, required this.actions});

  final BranchStore store;
  final BranchActions actions;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        final op = store.operation;
        if (!store.isRepo || (store.label.isEmpty && op == null)) return const SizedBox.shrink();
        // 合并 / 变基进行中:「⚠ Merging kdev」;变基时 HEAD 是游离的,分支名取操作里的
        final label = op == null ? store.label : (op.kind == null ? op.verb : '${op.verb} ${op.branch ?? store.label}'.trim());
        return Builder(
          builder: (context) => Tooltip(
            message: store.busy != null ? '${store.busy}…' : (op == null ? 'Git Branch: ${store.label}' : '$label(有冲突要解决时点右边的按钮)'),
            waitDuration: const Duration(milliseconds: 600),
            child: InkWell(
              borderRadius: BorderRadius.circular(6),
              hoverColor: IntelliJTheme.hoverBg,
              onTap: () => _open(context),
              child: Container(
                height: 30,
                padding: const EdgeInsets.symmetric(horizontal: 8),
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (store.busy != null)
                      const SizedBox(width: 14, height: 14, child: CircularProgressIndicator(strokeWidth: 2, color: IntelliJTheme.accentBlue))
                    else if (op != null)
                      const Icon(Icons.warning_amber_rounded, size: 17, color: Color(0xFFE5A83A))
                    else
                      Icon(store.detached ? Icons.commit : Icons.fork_right, size: 16, color: IntelliJTheme.textSecondary),
                    const SizedBox(width: 6),
                    ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 260),
                      child: Text(label, overflow: TextOverflow.ellipsis, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13)),
                    ),
                    const SizedBox(width: 2),
                    const Icon(Icons.keyboard_arrow_down, size: 16, color: IntelliJTheme.textMuted),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }

  Future<void> _open(BuildContext context) async {
    store.load(); // 弹窗打开时分支列表可能已经过时,后台刷新,到了自己更新
    await showAnchoredPopup<void>(
      context,
      width: 440,
      maxHeight: 640,
      builder: (popup) => BranchPopup(store: store, actions: actions, anchor: context, closePopup: () => Navigator.pop(popup)),
    );
  }
}

class _Item {
  const _Item(this.icon, this.label, this.shortcut, this.run);

  final IconData? icon;
  final String label;
  final String? shortcut;
  final void Function(BuildContext anchor) run;
}

/// 弹窗内容。[anchor] 是标题栏上那个按钮的 context:操作用它弹对话框和提示,
/// 因为弹窗一关,弹窗自己的 context 就没了。
class BranchPopup extends StatefulWidget {
  const BranchPopup({super.key, required this.store, required this.actions, required this.anchor, required this.closePopup});

  final BranchStore store;
  final BranchActions actions;
  final BuildContext anchor;
  final VoidCallback closePopup;

  @override
  State<BranchPopup> createState() => _BranchPopupState();
}

class _BranchPopupState extends State<BranchPopup> {
  final TextEditingController _search = TextEditingController();
  final Set<String> _collapsed = {};

  BranchStore get store => widget.store;
  BranchActions get actions => widget.actions;

  @override
  void dispose() {
    _search.dispose();
    super.dispose();
  }

  List<_Item> get _items => [
        _Item(Icons.south_west, 'Update Project…', '⌘T', actions.update),
        _Item(Icons.commit, 'Commit…', '⌘K', (_) => actions.showCommitWindow()),
        _Item(Icons.north_east, 'Push…', '⇧⌘P', actions.push),
        _Item(Icons.add, 'New Branch…', '⌥⌘N', (c) => actions.newBranch(c)),
        _Item(null, 'Checkout Tag or Revision…', null, actions.checkoutRevision),
      ];

  void _do(void Function(BuildContext) run) {
    widget.closePopup();
    run(widget.anchor);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([store, _search]),
      builder: (context, _) {
        final query = _search.text.trim();
        final q = query.toLowerCase();
        final items = [for (final i in _items) if (q.isEmpty || i.label.toLowerCase().contains(q)) i];
        final tree = buildBranchMenuTree(local: store.local, remote: store.remote, recent: store.recent, query: query);
        final rows = flattenBranchTree(tree, _collapsed, expandAll: query.isNotEmpty);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Container(
              height: 40,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Row(children: [
                const Icon(Icons.search, size: 16, color: IntelliJTheme.textMuted),
                const SizedBox(width: 8),
                Expanded(
                  child: TextField(
                    controller: _search,
                    autofocus: true,
                    style: popupText,
                    cursorColor: IntelliJTheme.caret,
                    decoration: const InputDecoration(
                      isDense: true,
                      border: InputBorder.none,
                      hintText: 'Search for branches and actions',
                      hintStyle: TextStyle(color: IntelliJTheme.textMuted, fontSize: 13),
                    ),
                  ),
                ),
              ]),
            ),
            const Divider(height: 1, thickness: 1, color: IntelliJTheme.borderSubtle),
            Flexible(
              child: ListView(
                shrinkWrap: true,
                padding: const EdgeInsets.symmetric(vertical: 4),
                children: [
                  for (final item in items) _actionRow(item),
                  if (items.isNotEmpty && rows.isNotEmpty) const Divider(height: 9, thickness: 1, color: IntelliJTheme.borderSubtle, indent: 8, endIndent: 8),
                  for (final row in rows) _branchRow(row),
                  if (items.isEmpty && rows.isEmpty)
                    const Padding(padding: EdgeInsets.all(16), child: Text('没有匹配的分支或操作', style: popupMuted)),
                ],
              ),
            ),
          ],
        );
      },
    );
  }

  Widget _actionRow(_Item item) => PopupRow(
        onTap: () => _do(item.run),
        child: Row(children: [
          SizedBox(width: 22, child: item.icon == null ? null : Icon(item.icon, size: 16, color: IntelliJTheme.textSecondary)),
          Expanded(child: Text(item.label, style: popupText)),
          if (item.shortcut != null) Text(item.shortcut!, style: popupMuted),
        ]),
      );

  Widget _branchRow(BranchMenuRow row) {
    final node = row.node;
    final depth = row.depth;
    if (node.isGroup) {
      final section = depth == 0;
      return PopupRow(
        onTap: () => setState(() => row.expanded ? _collapsed.add(row.key) : _collapsed.remove(row.key)),
        padding: EdgeInsets.only(left: 8.0 + depth * 16, right: 12),
        child: Row(children: [
          SizedBox(
            width: 18,
            child: row.expandable ? Icon(row.expanded ? Icons.expand_more : Icons.chevron_right, size: 16, color: IntelliJTheme.textMuted) : null,
          ),
          if (!section) ...[
            const Icon(Icons.folder_outlined, size: 15, color: IntelliJTheme.textSecondary),
            const SizedBox(width: 6),
          ],
          Flexible(child: Text(node.label, overflow: TextOverflow.ellipsis, style: section ? popupHeader : popupText)),
        ]),
      );
    }
    final (IconData icon, Color color) = node.isCurrent
        ? (Icons.sell_outlined, IntelliJTheme.accentYellow)
        : node.isMain
            ? (Icons.star, IntelliJTheme.accentYellow)
            : (Icons.call_split, IntelliJTheme.textSecondary);
    return Builder(
      builder: (rowContext) => PopupRow(
        onTap: () => _showSubmenu(rowContext, node),
        padding: EdgeInsets.only(left: 8.0 + depth * 16, right: 8),
        child: Row(children: [
          const SizedBox(width: 18),
          Icon(icon, size: 15, color: color),
          const SizedBox(width: 6),
          Flexible(
            child: Text(
              node.label,
              overflow: TextOverflow.ellipsis,
              style: popupText.copyWith(fontWeight: node.isCurrent ? FontWeight.w600 : FontWeight.normal),
            ),
          ),
          if (node.upstream != null) ...[
            const SizedBox(width: 12),
            Expanded(child: Text(node.upstream!, textAlign: TextAlign.right, overflow: TextOverflow.ellipsis, style: popupMuted)),
          ] else
            const Spacer(),
          const Icon(Icons.chevron_right, size: 16, color: IntelliJTheme.textMuted),
        ]),
      ),
    );
  }

  /// 点分支:在它右边弹出这个分支的操作。
  Future<void> _showSubmenu(BuildContext rowContext, BranchNode node) async {
    final rev = node.revision!;
    final current = store.current;
    final isCurrent = node.isCurrent;
    final isLocal = !store.remote.any((b) => b.name == rev);
    final canCompare = !isCurrent && current != null;

    final box = rowContext.findRenderObject() as RenderBox;
    final overlay = Overlay.of(rowContext).context.findRenderObject() as RenderBox;
    final topRight = box.localToGlobal(Offset(box.size.width - 8, 0), ancestor: overlay);
    final position = RelativeRect.fromLTRB(topRight.dx, topRight.dy, overlay.size.width - topRight.dx, overlay.size.height - topRight.dy);

    PopupMenuItem<String> item(String value, String label, {bool enabled = true, bool danger = false}) => PopupMenuItem<String>(
          value: value,
          enabled: enabled,
          height: 30,
          child: Text(label, style: TextStyle(color: !enabled ? IntelliJTheme.textMuted : danger ? IntelliJTheme.gitRed : IntelliJTheme.textHigh, fontSize: 13)),
        );

    final choice = await showMenu<String>(
      context: rowContext,
      position: position,
      color: IntelliJTheme.panelBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(6), side: const BorderSide(color: IntelliJTheme.border)),
      items: [
        item('checkout', 'Checkout', enabled: !isCurrent),
        item('new', "New Branch from '$rev'…"),
        const PopupMenuDivider(height: 9),
        item('merge', "Merge '$rev' into '${current ?? 'HEAD'}'", enabled: canCompare),
        item('rebase', "Rebase '${current ?? 'HEAD'}' onto '$rev'", enabled: canCompare),
        if (isLocal) ...[
          const PopupMenuDivider(height: 9),
          item('rename', 'Rename…'),
          item('delete', 'Delete', enabled: !isCurrent, danger: true),
        ],
      ],
    );
    if (choice == null) return;
    _do((c) {
      switch (choice) {
        case 'checkout':
          actions.checkout(c, rev);
        case 'new':
          actions.newBranch(c, from: rev);
        case 'merge':
          actions.merge(c, rev);
        case 'rebase':
          actions.rebase(c, rev);
        case 'rename':
          actions.rename(c, rev);
        case 'delete':
          actions.delete(c, rev);
      }
    });
  }
}
