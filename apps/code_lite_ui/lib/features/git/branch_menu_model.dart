// 标题栏分支菜单里的三棵树(Recent / Local / Remote)。分支名按 `/` 折成文件夹,
// 与 IntelliJ 的 Branches 弹窗一致。纯数据,不碰界面,单测直接喂分支列表。

import 'git_log_store.dart';

/// 一个分支(叶子)或一个文件夹 / 分组。
class BranchNode {
  BranchNode.group(this.label, {this.hint}) : revision = null, upstream = null, isCurrent = false;

  BranchNode.leaf(this.label, {required this.revision, this.upstream, this.isCurrent = false, this.hint});

  final String label;

  /// 点击后操作的修订名(本地分支名或 `origin/x`);分组为 null。
  final String? revision;
  final String? upstream;
  final bool isCurrent;

  /// 分组右侧的灰字(比如分支数);叶子不用。
  final String? hint;
  final List<BranchNode> children = [];

  bool get isGroup => revision == null;
  bool get isMain => revision == 'main' || revision == 'master' || (revision?.endsWith('/main') ?? false) || (revision?.endsWith('/master') ?? false);
}

/// 菜单里的一行。
class BranchMenuRow {
  const BranchMenuRow({required this.key, required this.depth, required this.node, required this.expandable, required this.expanded});

  final String key;
  final int depth;
  final BranchNode node;
  final bool expandable;
  final bool expanded;
}

/// 把 [entries](修订名 → 叶子)放进文件夹:`feat/pay/refund` 变成 feat → pay → refund。
/// 文件夹按第一次出现的顺序排,所以调用方给的顺序(当前分支在前 / 最近的在前)会保留。
void _insert(BranchNode root, List<String> parts, BranchNode leaf) {
  var node = root;
  for (final part in parts.take(parts.length - 1)) {
    var next = node.children.where((c) => c.isGroup && c.label == part).firstOrNull;
    if (next == null) {
      next = BranchNode.group(part);
      node.children.add(next);
    }
    node = next;
  }
  node.children.add(leaf);
}

/// 弹窗里的内容:Recent、Local、Remote 三段。
///
/// [query] 按分支名过滤(不区分大小写),没有匹配的分段整段不显示;
/// [recent] 是最近切换过的本地分支名,最新的在前。
List<BranchNode> buildBranchMenuTree({
  required List<GitLocalBranch> local,
  required List<GitRemoteBranch> remote,
  List<String> recent = const [],
  String query = '',
}) {
  final q = query.trim().toLowerCase();
  bool keep(String name) => q.isEmpty || name.toLowerCase().contains(q);

  BranchNode leafOf(GitLocalBranch b) =>
      BranchNode.leaf(b.name.split('/').last, revision: b.name, upstream: b.upstream, isCurrent: b.current);

  final byName = {for (final b in local) b.name: b};

  final recentGroup = BranchNode.group('Recent');
  for (final name in recent) {
    final b = byName[name];
    if (b == null || !keep(name)) continue;
    _insert(recentGroup, name.split('/'), leafOf(b));
  }

  final localGroup = BranchNode.group('Local');
  final sorted = [...local]..sort((a, b) {
      if (a.current != b.current) return a.current ? -1 : 1;
      return a.name.compareTo(b.name);
    });
  for (final b in sorted.where((b) => keep(b.name))) {
    _insert(localGroup, b.name.split('/'), leafOf(b));
  }

  final remoteGroup = BranchNode.group('Remote');
  final byRemote = <String, BranchNode>{};
  final sortedRemote = [...remote]..sort((a, b) => a.name.compareTo(b.name));
  for (final b in sortedRemote.where((b) => keep(b.name))) {
    final group = byRemote.putIfAbsent(b.remote, () {
      final g = BranchNode.group(b.remote);
      remoteGroup.children.add(g);
      return g;
    });
    _insert(group, b.short.split('/'), BranchNode.leaf(b.short.split('/').last, revision: b.name));
  }

  return [
    if (recentGroup.children.isNotEmpty) recentGroup,
    // 没有搜索时,即使没有本地分支也留着 Local 这个标题
    if (localGroup.children.isNotEmpty || q.isEmpty) localGroup,
    if (remoteGroup.children.isNotEmpty) remoteGroup,
  ];
}

/// 把树摊成行。[collapsed] 是折叠着的分组的 key;[expandAll] 为 true(正在搜索)时无视折叠。
List<BranchMenuRow> flattenBranchTree(List<BranchNode> roots, Set<String> collapsed, {bool expandAll = false}) {
  final rows = <BranchMenuRow>[];
  void walk(BranchNode node, int depth, String path) {
    final key = '$path/${node.label}';
    final folded = !expandAll && collapsed.contains(key);
    rows.add(BranchMenuRow(
      key: key,
      depth: depth,
      node: node,
      expandable: node.isGroup && node.children.isNotEmpty,
      expanded: !folded,
    ));
    if (node.isGroup && !folded) {
      for (final c in node.children) {
        walk(c, depth + 1, key);
      }
    }
  }

  for (final r in roots) {
    walk(r, 0, '');
  }
  return rows;
}
