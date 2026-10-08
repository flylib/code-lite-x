import 'package:code_lite_ui/features/git/branch_menu_model.dart';
import 'package:code_lite_ui/features/git/git_log_store.dart';
import 'package:flutter_test/flutter_test.dart';

GitLocalBranch local(String name, {bool current = false, String? upstream}) => GitLocalBranch(name, 'h', upstream, current);
GitRemoteBranch remote(String name) {
  final i = name.indexOf('/');
  return GitRemoteBranch(name, name.substring(0, i), name.substring(i + 1), 'h');
}

List<String> labels(List<BranchMenuRow> rows) => [for (final r in rows) '${'  ' * r.depth}${r.node.label}'];

void main() {
  test('local branches: current first, folders by slash, main is marked', () {
    final tree = buildBranchMenuTree(local: [
      local('main'),
      local('feat/login'),
      local('feat/pay/refund'),
      local('dev', current: true, upstream: 'origin/dev'),
    ], remote: const []);
    final rows = flattenBranchTree(tree, {});
    expect(labels(rows), ['Local', '  dev', '  feat', '    login', '    pay', '      refund', '  main']);
    final dev = rows.firstWhere((r) => r.node.label == 'dev').node;
    expect(dev.isCurrent, isTrue);
    expect(dev.upstream, 'origin/dev');
    expect(rows.firstWhere((r) => r.node.label == 'login').node.revision, 'feat/login', reason: '点击用完整分支名');
    expect(rows.firstWhere((r) => r.node.label == 'main').node.isMain, isTrue);
    expect(rows.firstWhere((r) => r.node.label == 'feat').node.isGroup, isTrue);
  });

  test('remote branches are grouped by remote and then by slash', () {
    final tree = buildBranchMenuTree(
      local: [local('main', current: true)],
      remote: [remote('origin/main'), remote('origin/feat/x'), remote('upstream/dev')],
    );
    final rows = flattenBranchTree(tree, {});
    expect(labels(rows).skipWhile((l) => l != 'Remote').toList(), ['Remote', '  origin', '    feat', '      x', '    main', '  upstream', '    dev']);
    expect(rows.firstWhere((r) => r.node.label == 'x').node.revision, 'origin/feat/x');
    expect(rows.firstWhere((r) => r.node.label == 'main' && r.depth == 2).node.isMain, isTrue);
  });

  test('Recent keeps the order it is given and only lists local branches that exist', () {
    final tree = buildBranchMenuTree(
      local: [local('main', current: true), local('feat/a'), local('b')],
      remote: const [],
      recent: ['b', 'gone', 'feat/a'],
    );
    final rows = flattenBranchTree(tree, {});
    expect(labels(rows).takeWhile((l) => l != 'Local').toList(), ['Recent', '  b', '  feat', '    a']);
    expect(tree.first.label, 'Recent');
    // no recent branches: no Recent section
    expect(buildBranchMenuTree(local: [local('main')], remote: const []).map((n) => n.label), ['Local']);
  });

  test('collapsing a group hides its rows; searching ignores the folding', () {
    final all = buildBranchMenuTree(local: [local('a'), local('feat/b')], remote: const []);
    final folded = flattenBranchTree(all, {'/Local/feat'});
    expect(labels(folded), ['Local', '  a', '  feat']);
    expect(folded.last.expandable && !folded.last.expanded, isTrue);
    expect(labels(flattenBranchTree(all, {'/Local'})), ['Local']);
    expect(labels(flattenBranchTree(all, {'/Local'}, expandAll: true)), ['Local', '  a', '  feat', '    b']);
  });

  test('the search keeps matching branches (any case) and drops empty sections', () {
    final tree = buildBranchMenuTree(
      local: [local('main', current: true), local('feat/Login')],
      remote: [remote('origin/main')],
      recent: ['feat/Login'],
      query: 'LOGIN',
    );
    expect(labels(flattenBranchTree(tree, {})), ['Recent', '  feat', '    Login', 'Local', '  feat', '    Login']);
    expect(buildBranchMenuTree(local: [local('main')], remote: [remote('origin/main')], query: 'zzz'), isEmpty);
    // without a query the Local title stays even with no branches (a fresh repo)
    expect(buildBranchMenuTree(local: const [], remote: const []).map((n) => n.label), ['Local']);
  });
}
