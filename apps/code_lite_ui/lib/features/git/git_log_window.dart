import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../core/theme/intellij_theme.dart';
import 'commit_graph.dart';
import 'git_commit_actions.dart';
import 'git_log_store.dart';

const double _kRowHeight = 24;
const TextStyle _kText = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12);
const TextStyle _kMuted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

/// 日志详情栏里变更文件的颜色(与 IntelliJ 一致):新增绿色,删除灰色,
/// 修改 / 重命名 / 复制是亮蓝色。
Color gitChangeColor(String status) => switch (status) {
      'A' => IntelliJTheme.gitGreen,
      'D' => IntelliJTheme.textMuted,
      _ => IntelliJTheme.gitModified,
    };

/// 变更文件前面的图标颜色。文件类型图标有自己的颜色(`{}` 是紫色),不随变更状态变;
/// 没有专属颜色的类型,图标跟着文件名的状态色走。
Color gitFileIconColor(String fileName, String status) {
  final ext = fileName.contains('.') ? fileName.split('.').last.toLowerCase() : '';
  return switch (ext) {
    'json' || 'yaml' || 'yml' || 'toml' => IntelliJTheme.dataFileIcon,
    _ => gitChangeColor(status),
  };
}

String formatGitDate(DateTime t) {
  String two(int v) => v.toString().padLeft(2, '0');
  return '${t.year}/${t.month}/${t.day}, ${two(t.hour)}:${two(t.minute)}';
}

/// IntelliJ 的 Git 工具窗(Log 标签):分支树 | 提交图与列表 | 变更文件与提交信息。
class GitLogWindow extends StatefulWidget {
  const GitLogWindow({super.key, required this.store, required this.repoName, required this.onHide, this.onPull, this.onPush});

  final GitLogStore store;

  /// 筛选栏最右边的 Pull(更新当前分支)/ Push(先确认要推的提交)。为 null 时不显示。
  final void Function(BuildContext context)? onPull;
  final void Function(BuildContext context)? onPush;

  /// 详情面板文件树的根节点名(项目目录名)。
  final String repoName;
  final VoidCallback onHide;

  @override
  State<GitLogWindow> createState() => _GitLogWindowState();
}

class _GitLogWindowState extends State<GitLogWindow> {
  final FocusNode _searchFocus = FocusNode(debugLabel: 'git-log-search');

  @override
  void initState() {
    super.initState();
    widget.store.ensureLoaded();
  }

  @override
  void dispose() {
    _searchFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final store = widget.store;
    return ListenableBuilder(
      listenable: store,
      builder: (context, _) {
        return Container(
          color: IntelliJTheme.panelBg,
          child: Column(
            children: [
              _Header(onHide: widget.onHide, onRefresh: store.refresh),
              Expanded(
                child: !store.isAvailable
                    ? const Center(child: Text('Git 在 web 预览中不可用', style: _kMuted))
                    : LayoutBuilder(builder: (context, constraints) {
                        // 窗口太窄时先让出详情栏、再让出分支栏,提交列表至少留 460px。
                        // 只影响这次布局,不改用户的开关状态。
                        var room = constraints.maxWidth - 30 - 460;
                        final details = store.showDetails && room >= 321;
                        if (details) room -= 321;
                        final branches = store.showBranches && room >= 231;
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.stretch,
                          children: [
                            _SideToolbar(store: store, onSearch: _searchFocus.requestFocus),
                            if (branches) SizedBox(width: 230, child: _BranchesPane(store: store)),
                            if (branches) const VerticalDivider(width: 1, color: IntelliJTheme.borderSubtle),
                            Expanded(child: _LogPane(store: store, searchFocus: _searchFocus, onPull: widget.onPull, onPush: widget.onPush)),
                            if (details) const VerticalDivider(width: 1, color: IntelliJTheme.borderSubtle),
                            if (details) SizedBox(width: 320, child: _DetailsPane(store: store, repoName: widget.repoName)),
                          ],
                        );
                      }),
              ),
            ],
          ),
        );
      },
    );
  }
}

// ---------------------------------------------------------------------------
// 标题栏
// ---------------------------------------------------------------------------

class _Header extends StatelessWidget {
  const _Header({required this.onHide, required this.onRefresh});

  final VoidCallback onHide;
  final VoidCallback onRefresh;

  @override
  Widget build(BuildContext context) {
    // IntelliJ 新 UI:标题栏和内容同一块底色;选中的标签是圆角块(同终端的会话标签)
    return Container(
      height: 40,
      padding: const EdgeInsets.only(left: 12, right: 6),
      child: Row(
        children: [
          const Text('Git', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600)),
          const SizedBox(width: 16),
          // 目前只有 Log 一个标签
          Container(
            height: 28,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(color: IntelliJTheme.chipBg, borderRadius: BorderRadius.circular(6)),
            alignment: Alignment.center,
            child: const Text('Log', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 13)),
          ),
          const Spacer(),
          GitIconButton(icon: Icons.more_vert, tooltip: '刷新', onTap: onRefresh),
          GitIconButton(icon: Icons.remove, tooltip: '隐藏', onTap: onHide),
        ],
      ),
    );
  }
}

class GitIconButton extends StatelessWidget {
  const GitIconButton({super.key, required this.icon, required this.tooltip, this.onTap, this.active = false, this.label});

  final IconData? icon;
  final String? label;
  final String tooltip;
  final VoidCallback? onTap;
  final bool active;

  @override
  Widget build(BuildContext context) {
    final color = onTap == null
        ? IntelliJTheme.textMuted.withValues(alpha: 0.5)
        : active
            ? IntelliJTheme.accentBlue
            : IntelliJTheme.textSecondary;
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Container(
          padding: const EdgeInsets.all(4),
          decoration: active
              ? BoxDecoration(color: IntelliJTheme.accentBlue.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4))
              : null,
          child: label != null
              ? Text(label!, style: TextStyle(color: color, fontSize: 12, fontWeight: FontWeight.w600))
              : Icon(icon, size: 15, color: color),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 左侧竖工具条 + 分支树
// ---------------------------------------------------------------------------

class _SideToolbar extends StatelessWidget {
  const _SideToolbar({required this.store, required this.onSearch});

  final GitLogStore store;
  final VoidCallback onSearch;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 30,
      decoration: const BoxDecoration(
        border: Border(right: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Column(
        children: [
          GitIconButton(
            icon: store.showBranches ? Icons.chevron_left : Icons.chevron_right,
            tooltip: store.showBranches ? '隐藏分支' : '显示分支',
            onTap: store.toggleBranches,
          ),
          const SizedBox(height: 6),
          GitIconButton(icon: Icons.search, tooltip: '搜索提交 (Text or hash)', onTap: onSearch),
          const SizedBox(height: 6),
          GitIconButton(icon: Icons.refresh, tooltip: '刷新', onTap: store.refresh),
        ],
      ),
    );
  }
}

/// 分支树节点:分组(Local / Remote / origin / feat/ 前缀)或分支本身。
class _BranchNode {
  _BranchNode(this.label, {this.revision, this.icon, this.iconColor, this.isCurrent = false});

  final String label;

  /// 点击后作为 Branch 筛选的修订名;分组节点为 null。
  final String? revision;
  final IconData? icon;
  final Color? iconColor;
  final bool isCurrent;
  final List<_BranchNode> children = [];

  bool get isGroup => revision == null;
}

class _BranchesPane extends StatefulWidget {
  const _BranchesPane({required this.store});

  final GitLogStore store;

  @override
  State<_BranchesPane> createState() => _BranchesPaneState();
}

class _BranchesPaneState extends State<_BranchesPane> {
  final Set<String> _collapsed = {};
  String _query = '';

  /// 按 `/` 拆成文件夹,与 IntelliJ 把 feat/xxx 归到 feat 文件夹一致。
  void _insert(_BranchNode root, List<String> parts, _BranchNode leaf) {
    var node = root;
    for (final part in parts.take(parts.length - 1)) {
      var next = node.children.where((c) => c.isGroup && c.label == part).firstOrNull;
      if (next == null) {
        next = _BranchNode(part, icon: Icons.folder_outlined);
        node.children.add(next);
      }
      node = next;
    }
    node.children.add(leaf);
  }

  List<_BranchNode> _buildTree() {
    final store = widget.store;
    final q = _query.toLowerCase();
    bool keep(String name) => q.isEmpty || name.toLowerCase().contains(q);

    final local = _BranchNode('Local');
    final sortedLocal = [...store.localBranches]..sort((a, b) {
        if (a.current != b.current) return a.current ? -1 : 1;
        return a.name.compareTo(b.name);
      });
    for (final b in sortedLocal.where((b) => keep(b.name))) {
      final parts = b.name.split('/');
      _insert(
        local,
        parts,
        _BranchNode(
          parts.last,
          revision: b.name,
          icon: b.current ? Icons.sell_outlined : _isMain(b.name) ? Icons.star : Icons.call_split,
          iconColor: b.current || _isMain(b.name) ? IntelliJTheme.accentYellow : IntelliJTheme.textSecondary,
          isCurrent: b.current,
        ),
      );
    }

    final remote = _BranchNode('Remote');
    final byRemote = <String, _BranchNode>{};
    for (final b in store.remoteBranches.where((b) => keep(b.name))) {
      final group = byRemote.putIfAbsent(b.remote, () {
        final n = _BranchNode(b.remote, icon: Icons.folder_outlined);
        remote.children.add(n);
        return n;
      });
      final parts = b.short.split('/');
      _insert(
        group,
        parts,
        _BranchNode(
          parts.last,
          revision: b.name,
          icon: _isMain(b.short) ? Icons.star : Icons.call_split,
          iconColor: _isMain(b.short) ? IntelliJTheme.accentYellow : IntelliJTheme.textSecondary,
        ),
      );
    }

    return [
      _BranchNode('HEAD (Current Branch)', revision: 'HEAD'),
      if (local.children.isNotEmpty || q.isEmpty) local,
      if (remote.children.isNotEmpty) remote,
    ];
  }

  static bool _isMain(String name) => name == 'main' || name == 'master';

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    void walk(_BranchNode node, int depth, String path) {
      final key = '$path/${node.label}';
      final collapsed = _collapsed.contains(key);
      final selected = node.revision != null && widget.store.branch == node.revision;
      rows.add(_TreeRow(
        depth: depth,
        expandable: node.isGroup && node.children.isNotEmpty,
        expanded: !collapsed,
        icon: node.icon,
        iconColor: node.iconColor,
        label: node.label,
        selected: selected,
        bold: node.isCurrent,
        onTap: () {
          if (node.isGroup) {
            setState(() => collapsed ? _collapsed.remove(key) : _collapsed.add(key));
          } else {
            // 再点一次已选中的分支 = 取消筛选。
            widget.store.setBranch(selected ? null : node.revision);
          }
        },
      ));
      if (node.isGroup && !collapsed) {
        for (final c in node.children) {
          walk(c, depth + 1, key);
        }
      }
    }

    for (final n in _buildTree()) {
      walk(n, 0, '');
    }

    return Column(
      children: [
        Container(
          height: 32,
          padding: const EdgeInsets.symmetric(horizontal: 8),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle))),
          child: Row(
            children: [
              const Icon(Icons.search, size: 14, color: IntelliJTheme.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: TextField(
                  style: _kText,
                  decoration: const InputDecoration(
                    isDense: true,
                    border: InputBorder.none,
                    hintText: '',
                    contentPadding: EdgeInsets.symmetric(vertical: 6),
                  ),
                  onChanged: (v) => setState(() => _query = v),
                ),
              ),
            ],
          ),
        ),
        Expanded(child: ListView(padding: const EdgeInsets.symmetric(vertical: 4), children: rows)),
      ],
    );
  }
}

class _TreeRow extends StatelessWidget {
  const _TreeRow({
    required this.depth,
    required this.expandable,
    required this.expanded,
    required this.label,
    required this.onTap,
    this.icon,
    this.iconColor,
    this.selected = false,
    this.bold = false,
    this.trailing,
    this.labelColor,
    this.onDoubleTap,
  });

  final int depth;
  final bool expandable;
  final bool expanded;
  final IconData? icon;
  final Color? iconColor;
  final String label;
  final Color? labelColor;
  final String? trailing;
  final bool selected;
  final bool bold;
  final VoidCallback onTap;
  final VoidCallback? onDoubleTap;

  @override
  Widget build(BuildContext context) {
    return GestureDetector(
      onDoubleTap: onDoubleTap,
      child: InkWell(
        onTap: onTap,
        child: Container(
          height: 24,
          color: selected ? IntelliJTheme.selectionBg : null,
          padding: EdgeInsets.only(left: 8.0 + depth * 16),
          child: Row(
            children: [
              SizedBox(
                width: 16,
                child: expandable
                    ? Icon(expanded ? Icons.expand_more : Icons.chevron_right, size: 14, color: IntelliJTheme.textMuted)
                    : null,
              ),
              if (icon != null) ...[
                Icon(icon, size: 14, color: iconColor ?? IntelliJTheme.textSecondary),
                const SizedBox(width: 6),
              ],
              Flexible(
                child: Text(
                  label,
                  overflow: TextOverflow.ellipsis,
                  style: _kText.copyWith(
                    color: labelColor ?? (selected ? IntelliJTheme.textHigh : IntelliJTheme.textPrimary),
                    fontWeight: bold ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
              if (trailing != null) ...[
                const SizedBox(width: 6),
                Text(trailing!, style: _kMuted),
              ],
            ],
          ),
        ),
      ),
    );
  }
}

// ---------------------------------------------------------------------------
// 中间:筛选栏 + 提交表
// ---------------------------------------------------------------------------

class _LogPane extends StatefulWidget {
  const _LogPane({required this.store, required this.searchFocus, this.onPull, this.onPush});

  final void Function(BuildContext context)? onPull;
  final void Function(BuildContext context)? onPush;

  final GitLogStore store;
  final FocusNode searchFocus;

  @override
  State<_LogPane> createState() => _LogPaneState();
}

class _LogPaneState extends State<_LogPane> {
  final ScrollController _scroll = ScrollController();
  final FocusNode _listFocus = FocusNode(debugLabel: 'git-log-list');
  late final TextEditingController _search = TextEditingController(text: widget.store.text);

  GitLogStore get store => widget.store;

  @override
  void initState() {
    super.initState();
    _scroll.addListener(() {
      if (_scroll.position.pixels > _scroll.position.maxScrollExtent - 400) store.loadMore();
    });
  }

  @override
  void dispose() {
    _scroll.dispose();
    _listFocus.dispose();
    _search.dispose();
    super.dispose();
  }

  void _ensureVisible(int index) {
    if (!_scroll.hasClients) return;
    final top = index * _kRowHeight;
    final viewport = _scroll.position.viewportDimension;
    if (top < _scroll.offset) {
      _scroll.jumpTo(top);
    } else if (top + _kRowHeight > _scroll.offset + viewport) {
      _scroll.jumpTo(top + _kRowHeight - viewport);
    }
  }

  void _selectAt(int index) {
    if (index < 0 || index >= store.commits.length) return;
    store.selectCommit(store.commits[index].hash);
    _ensureVisible(index);
  }

  Future<void> _goTo(String hash) async {
    if (await store.reveal(hash)) {
      final i = store.indexOf(hash);
      if (i != null) _ensureVisible(i);
    }
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final i = store.selected == null ? -1 : (store.indexOf(store.selected!) ?? -1);
    final key = event.logicalKey;
    if (key == LogicalKeyboardKey.arrowDown) {
      _selectAt(i + 1);
    } else if (key == LogicalKeyboardKey.arrowUp) {
      _selectAt(i - 1);
    } else if (key == LogicalKeyboardKey.arrowRight || key == LogicalKeyboardKey.arrowLeft) {
      // ← 子提交 / → 父提交,与右键菜单的 Go to Child / Parent 一致。
      final c = store.selected == null ? null : store.commit(store.selected!);
      if (c == null) return KeyEventResult.handled;
      final target = key == LogicalKeyboardKey.arrowRight
          ? c.parents.firstOrNull
          : store.childrenOf(c.hash).firstOrNull;
      if (target != null) _goTo(target);
    } else if (key == LogicalKeyboardKey.f2 && store.selected != null) {
      GitCommitActions(context, store).editMessage(store.selected!);
    } else {
      return KeyEventResult.ignored;
    }
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: [
        _FilterBar(store: store, controller: _search, focus: widget.searchFocus, onPull: widget.onPull, onPush: widget.onPush),
        if (store.warning != null) _WarningBanner(message: store.warning!),
        if (store.busy != null)
          const LinearProgressIndicator(
            minHeight: 2,
            color: IntelliJTheme.accentBlue,
            backgroundColor: IntelliJTheme.panelBg,
          ),
        Expanded(
          child: Container(
            color: IntelliJTheme.editorBg,
            child: store.error != null
                ? Center(child: Text(store.error!, style: _kMuted, textAlign: TextAlign.center))
                : store.commits.isEmpty
                    ? Center(child: Text(store.loading ? '加载中…' : '没有匹配的提交', style: _kMuted))
                    : Focus(
                        focusNode: _listFocus,
                        onKeyEvent: _onKey,
                        child: ListView.builder(
                          controller: _scroll,
                          itemExtent: _kRowHeight,
                          itemCount: store.commits.length,
                          itemBuilder: (context, i) => _CommitRow(
                            commit: store.commits[i],
                            graph: store.graph[i],
                            isHead: store.commits[i].hash == store.headHash,
                            selected: store.commits[i].hash == store.selected,
                            onTap: () {
                              _listFocus.requestFocus();
                              store.selectCommit(store.commits[i].hash);
                            },
                            onSecondaryTap: (pos) {
                              _listFocus.requestFocus();
                              store.selectCommit(store.commits[i].hash);
                              GitCommitActions(context, store, onGoTo: _goTo).showContextMenu(pos, store.commits[i]);
                            },
                          ),
                        ),
                      ),
          ),
        ),
      ],
    );
  }
}

/// 仓库部分损坏时的提示:列表照常显示读得到的提交,这里给出 git 的原始报错。
class _WarningBanner extends StatelessWidget {
  const _WarningBanner({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: message,
      child: Container(
        width: double.infinity,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        color: IntelliJTheme.accentYellow.withValues(alpha: 0.14),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Icon(Icons.warning_amber_rounded, size: 15, color: IntelliJTheme.accentYellow),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                '仓库历史有损坏,只显示损坏点之前的提交(可运行 git fsck 检查)。$message',
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.store, required this.controller, required this.focus, this.onPull, this.onPush});

  final GitLogStore store;
  final TextEditingController controller;
  final FocusNode focus;
  final void Function(BuildContext context)? onPull;
  final void Function(BuildContext context)? onPush;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 36,
      padding: const EdgeInsets.symmetric(horizontal: 6),
      decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle))),
      // 右边固定放 Pull / Push,左边是搜索框、筛选和工具按钮
      child: Row(
        children: [
          Expanded(child: _filters(context)),
          if (onPull != null) _SyncButton(key: const ValueKey('git-pull'), icon: Icons.south_west, label: 'Pull', color: IntelliJTheme.accentBlue, tooltip: '更新当前分支(拉取并合并上游)', onTap: () => onPull!(context)),
          if (onPush != null) _SyncButton(key: const ValueKey('git-push'), icon: Icons.north_east, label: 'Push', color: const Color(0xFF5FB865), tooltip: '推送当前分支(先确认要推的提交)', onTap: () => onPush!(context)),
        ],
      ),
    );
  }

  Widget _filters(BuildContext context) {
    return Row(
        children: [
          // 搜索框:Text or hash,带 .* 正则 与 Cc 区分大小写 两个开关。窄时可收缩。
          Flexible(
            flex: 3,
            child: Container(
              constraints: const BoxConstraints(maxWidth: 280),
              height: 26,
              padding: const EdgeInsets.only(left: 6, right: 2),
              decoration: BoxDecoration(
                color: IntelliJTheme.editorBg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: focus.hasFocus ? IntelliJTheme.accentBlue : IntelliJTheme.border),
              ),
              child: Row(
                children: [
                  const Icon(Icons.search, size: 14, color: IntelliJTheme.textMuted),
                  const SizedBox(width: 4),
                  Expanded(
                    child: TextField(
                      controller: controller,
                      focusNode: focus,
                      style: _kText,
                      decoration: const InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        hintText: 'Text or hash',
                        hintStyle: _kMuted,
                        contentPadding: EdgeInsets.symmetric(vertical: 6),
                      ),
                      onChanged: store.setText,
                    ),
                  ),
                  GitIconButton(icon: null, label: '.*', tooltip: '正则表达式', active: store.regex, onTap: store.toggleRegex),
                  GitIconButton(icon: null, label: 'Cc', tooltip: '区分大小写', active: store.matchCase, onTap: store.toggleMatchCase),
                ],
              ),
            ),
          ),
          const SizedBox(width: 6),
          Flexible(
            flex: 4,
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _FilterDropdown(
                    label: 'Branch',
                    value: store.branch,
                    options: () => [
                      'HEAD',
                      for (final b in store.localBranches) b.name,
                      for (final b in store.remoteBranches) b.name,
                    ],
                    onSelected: store.setBranch,
                  ),
                  _FilterDropdown(
                    label: 'User',
                    value: store.author,
                    options: () async {
                      if (store.authors.isEmpty) await store.loadAuthors();
                      return store.authors;
                    },
                    onSelected: store.setAuthor,
                  ),
                  _FilterDropdown(
                    label: 'Date',
                    value: store.date == DateFilter.all ? null : store.date.label,
                    options: () => [for (final d in DateFilter.values.skip(1)) d.label],
                    onSelected: (v) => store.setDate(
                      DateFilter.values.firstWhere((d) => d.label == v, orElse: () => DateFilter.all),
                    ),
                  ),
                  _PathsFilter(store: store),
                ],
              ),
            ),
          ),
          GitIconButton(icon: Icons.sync, tooltip: '刷新', onTap: store.refresh),
          GitIconButton(
            icon: Icons.local_florist_outlined,
            tooltip: 'Cherry-Pick',
            onTap: store.selected == null || store.busy != null
                ? null
                : () => GitCommitActions(context, store).cherryPick(store.selected!),
          ),
          GitIconButton(
            icon: Icons.visibility_outlined,
            tooltip: '显示详情',
            active: store.showDetails,
            onTap: store.toggleDetails,
          ),
          GitIconButton(
            icon: Icons.manage_search,
            tooltip: '跳转到哈希 / 分支 / 标签',
            onTap: () => GitCommitActions(context, store).goToRevision(),
          ),
        ],
    );
  }
}

/// 筛选栏右边的 Pull / Push:带颜色的箭头加文字(IntelliJ 工具栏里更新是蓝箭头、推送是绿箭头)。
class _SyncButton extends StatelessWidget {
  const _SyncButton({super.key, required this.icon, required this.label, required this.color, required this.tooltip, required this.onTap});

  final IconData icon;
  final String label;
  final Color color;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Tooltip(
        message: tooltip,
        waitDuration: const Duration(milliseconds: 400),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          hoverColor: IntelliJTheme.hoverBg,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(icon, size: 14, color: color),
              const SizedBox(width: 3),
              Text(label, style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12)),
            ]),
          ),
        ),
      );
}

/// IntelliJ 式筛选下拉:未设置时显示灰色标签,设置后显示值和 ×。
class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({required this.label, required this.value, required this.options, required this.onSelected});

  final String label;
  final String? value;
  final FutureOr<List<String>> Function() options;
  final ValueChanged<String?> onSelected;

  @override
  Widget build(BuildContext context) {
    final active = value != null;
    return Padding(
      padding: const EdgeInsets.only(right: 2),
      child: InkWell(
        borderRadius: BorderRadius.circular(4),
        onTap: () async {
          final box = context.findRenderObject() as RenderBox;
          final origin = box.localToGlobal(Offset(0, box.size.height));
          final items = await options();
          if (!context.mounted) return;
          final picked = await showMenu<String>(
            context: context,
            position: RelativeRect.fromLTRB(origin.dx, origin.dy, origin.dx + 1, origin.dy + 1),
            color: IntelliJTheme.panelBg,
            constraints: const BoxConstraints(maxHeight: 360, minWidth: 180),
            items: [
              if (active) const PopupMenuItem(value: '\u0000', height: 26, child: Text('All', style: _kText)),
              for (final o in items)
                PopupMenuItem(
                  value: o,
                  height: 26,
                  child: Text(o, style: _kText.copyWith(color: o == value ? IntelliJTheme.accentBlue : null)),
                ),
            ],
          );
          if (picked == null) return;
          onSelected(picked == '\u0000' ? null : picked);
        },
        child: Container(
          height: 26,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: active
              ? BoxDecoration(color: IntelliJTheme.accentBlue.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4))
              : null,
          child: Row(
            children: [
              Text(
                active ? '$label: $value' : label,
                style: TextStyle(color: active ? IntelliJTheme.textHigh : IntelliJTheme.textSecondary, fontSize: 12),
              ),
              const SizedBox(width: 2),
              if (active)
                InkWell(
                  onTap: () => onSelected(null),
                  child: const Icon(Icons.close, size: 12, color: IntelliJTheme.textMuted),
                )
              else
                const Icon(Icons.expand_more, size: 14, color: IntelliJTheme.textMuted),
            ],
          ),
        ),
      ),
    );
  }
}

class _PathsFilter extends StatelessWidget {
  const _PathsFilter({required this.store});

  final GitLogStore store;

  @override
  Widget build(BuildContext context) {
    final active = store.paths.isNotEmpty;
    return InkWell(
      borderRadius: BorderRadius.circular(4),
      onTap: () async {
        final value = await GitCommitActions(context, store).promptText(
          title: 'Paths',
          label: '只看涉及这些路径的提交(相对项目根目录,多个用逗号分隔)',
          initial: store.paths.join(', '),
        );
        if (value == null) return;
        store.setPaths([for (final p in value.split(',')) if (p.trim().isNotEmpty) p.trim()]);
      },
      child: Container(
        height: 26,
        padding: const EdgeInsets.symmetric(horizontal: 6),
        decoration: active
            ? BoxDecoration(color: IntelliJTheme.accentBlue.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(4))
            : null,
        child: Row(
          children: [
            Text(
              active ? 'Paths: ${store.paths.join(', ')}' : 'Paths',
              style: TextStyle(color: active ? IntelliJTheme.textHigh : IntelliJTheme.textSecondary, fontSize: 12),
            ),
            const SizedBox(width: 2),
            if (active)
              InkWell(onTap: () => store.setPaths(const []), child: const Icon(Icons.close, size: 12, color: IntelliJTheme.textMuted))
            else
              const Icon(Icons.expand_more, size: 14, color: IntelliJTheme.textMuted),
          ],
        ),
      ),
    );
  }
}

class _CommitRow extends StatelessWidget {
  const _CommitRow({
    required this.commit,
    required this.graph,
    required this.isHead,
    required this.selected,
    required this.onTap,
    required this.onSecondaryTap,
  });

  final GitCommit commit;
  final GraphRow graph;
  final bool isHead;
  final bool selected;
  final VoidCallback onTap;
  final ValueChanged<Offset> onSecondaryTap;

  @override
  Widget build(BuildContext context) {
    final graphWidth = graph.width * kLaneWidth + 8;
    return GestureDetector(
      behavior: HitTestBehavior.opaque,
      onTap: onTap,
      onSecondaryTapDown: (d) => onSecondaryTap(d.globalPosition),
      child: Container(
        color: selected ? const Color(0xFF2E436E) : null,
        child: Row(
          children: [
            SizedBox(
              width: graphWidth,
              height: _kRowHeight,
              child: CustomPaint(painter: CommitGraphPainter(graph, isHead: isHead)),
            ),
            Expanded(
              child: Row(
                children: [
                  Flexible(
                    child: Text(
                      commit.subject,
                      overflow: TextOverflow.ellipsis,
                      maxLines: 1,
                      style: _kText.copyWith(color: selected ? IntelliJTheme.textHigh : null),
                    ),
                  ),
                  if (commit.refs.isNotEmpty) ...[
                    const SizedBox(width: 8),
                    _RefLabels(refs: commit.refs),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 120,
              child: Text(
                commit.author,
                overflow: TextOverflow.ellipsis,
                style: _kText.copyWith(fontWeight: isHead ? FontWeight.w600 : null),
              ),
            ),
            SizedBox(
              width: 128,
              child: Text(formatGitDate(commit.time), overflow: TextOverflow.ellipsis, style: _kText),
            ),
          ],
        ),
      ),
    );
  }
}

/// 提交上的分支 / 标签标记,合并成 "origin & dev" 这样的一段,与 IntelliJ 相同。
class _RefLabels extends StatelessWidget {
  const _RefLabels({required this.refs});

  final List<GitRef> refs;

  @override
  Widget build(BuildContext context) {
    final names = <String>[];
    for (final r in refs) {
      if (r.kind == 'head') continue;
      names.add(r.kind == 'tag' ? r.name : r.name);
    }
    if (names.isEmpty) return const SizedBox.shrink();
    final hasTag = refs.any((r) => r.kind == 'tag');
    final hasHead = refs.any((r) => r.kind == 'head');
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: [
        Icon(
          hasTag ? Icons.local_offer_outlined : Icons.sell_outlined,
          size: 13,
          color: hasHead ? IntelliJTheme.accentYellow : IntelliJTheme.gitGreen,
        ),
        const SizedBox(width: 3),
        ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 220),
          child: Text(
            names.join(' & '),
            overflow: TextOverflow.ellipsis,
            style: _kMuted,
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------------------
// 右侧:变更文件树 + 提交信息
// ---------------------------------------------------------------------------

class _FileNode {
  _FileNode(this.name, {this.change});

  final String name;
  final GitFileChange? change;
  final Map<String, _FileNode> dirs = {};
  final List<_FileNode> files = [];

  int get count => files.length + dirs.values.fold(0, (s, d) => s + d.count);
}

class _DetailsPane extends StatefulWidget {
  const _DetailsPane({required this.store, required this.repoName});

  final GitLogStore store;
  final String repoName;

  @override
  State<_DetailsPane> createState() => _DetailsPaneState();
}

class _DetailsPaneState extends State<_DetailsPane> {
  final Set<String> _collapsed = {};
  String? _selectedFile;

  static IconData fileIcon(String name) {
    final ext = name.contains('.') ? name.split('.').last.toLowerCase() : '';
    return switch (ext) {
      'sh' || 'bash' || 'zsh' => Icons.terminal,
      'md' => Icons.description_outlined,
      'json' || 'yaml' || 'yml' || 'toml' => Icons.data_object,
      'png' || 'jpg' || 'jpeg' || 'gif' || 'svg' || 'webp' => Icons.image_outlined,
      _ => Icons.insert_drive_file_outlined,
    };
  }

  _FileNode _buildTree(List<GitFileChange> files) {
    final root = _FileNode(widget.repoName.isEmpty ? 'repository' : widget.repoName);
    for (final f in files) {
      final parts = f.path.split('/');
      var node = root;
      for (final dir in parts.take(parts.length - 1)) {
        node = node.dirs.putIfAbsent(dir, () => _FileNode(dir));
      }
      node.files.add(_FileNode(parts.last, change: f));
    }
    return root;
  }

  @override
  Widget build(BuildContext context) {
    final d = widget.store.details;
    if (d == null) {
      return const Center(child: Text('选择一个提交查看详情', style: _kMuted));
    }
    final tree = _buildTree(d.files);
    final rows = <Widget>[];

    void walk(_FileNode node, int depth, String path) {
      final key = '$path/${node.name}';
      final collapsed = _collapsed.contains(key);
      rows.add(_TreeRow(
        depth: depth,
        expandable: true,
        expanded: !collapsed,
        icon: Icons.folder_outlined,
        label: node.name,
        trailing: '${node.count} ${node.count == 1 ? 'file' : 'files'}',
        onTap: () => setState(() => collapsed ? _collapsed.remove(key) : _collapsed.add(key)),
      ));
      if (collapsed) return;
      final dirs = node.dirs.values.toList()..sort((a, b) => a.name.compareTo(b.name));
      for (final dir in dirs) {
        walk(dir, depth + 1, key);
      }
      final files = [...node.files]..sort((a, b) => a.name.compareTo(b.name));
      for (final f in files) {
        final change = f.change!;
        rows.add(_TreeRow(
          depth: depth + 1,
          expandable: false,
          expanded: false,
          icon: fileIcon(f.name),
          iconColor: gitFileIconColor(f.name, change.status),
          label: f.name,
          labelColor: gitChangeColor(change.status),
          trailing: change.oldPath != null && change.status == 'R' ? '← ${change.oldPath!.split('/').last}' : null,
          selected: _selectedFile == change.path,
          onTap: () => setState(() => _selectedFile = change.path),
          onDoubleTap: () => GitCommitActions(context, widget.store).showCommitFileDiff(d.hash, change),
        ));
      }
    }

    walk(tree, 0, '');

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Container(
          height: 36,
          padding: const EdgeInsets.symmetric(horizontal: 6),
          decoration: const BoxDecoration(border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle))),
          child: Row(
            children: [
              GitIconButton(
                icon: Icons.difference_outlined,
                tooltip: '显示 Diff (双击文件)',
                onTap: _selectedFile == null
                    ? null
                    : () => GitCommitActions(context, widget.store).showCommitFileDiff(
                          d.hash,
                          d.files.firstWhere((f) => f.path == _selectedFile),
                        ),
              ),
              const Spacer(),
              GitIconButton(icon: Icons.unfold_more, tooltip: '全部展开', onTap: () => setState(_collapsed.clear)),
              GitIconButton(
                icon: Icons.unfold_less,
                tooltip: '全部折叠',
                onTap: () => setState(() {
                  void collect(_FileNode n, String path) {
                    final key = '$path/${n.name}';
                    _collapsed.add(key);
                    for (final c in n.dirs.values) {
                      collect(c, key);
                    }
                  }

                  collect(tree, '');
                  _collapsed.remove('/${tree.name}');
                }),
              ),
            ],
          ),
        ),
        Expanded(
          flex: 3,
          child: Container(
            color: IntelliJTheme.accentYellow.withValues(alpha: 0.06),
            child: d.files.isEmpty
                ? const Center(child: Text('没有文件变更', style: _kMuted))
                : ListView(padding: const EdgeInsets.symmetric(vertical: 4), children: rows),
          ),
        ),
        const Divider(height: 1, color: IntelliJTheme.borderSubtle),
        Expanded(
          flex: 2,
          child: SingleChildScrollView(
            padding: const EdgeInsets.all(12),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    d.message,
                    style: const TextStyle(
                      color: IntelliJTheme.textHigh,
                      fontSize: 12.5,
                      fontFamily: 'Menlo',
                      fontWeight: FontWeight.w600,
                      height: 1.45,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    '${d.hash.substring(0, 8)} ${d.author} <${d.email}> on ${formatGitDate(d.authorTime)}',
                    style: _kMuted,
                  ),
                  if (d.committer.isNotEmpty && d.committer != d.author)
                    Text('committed by ${d.committer} on ${formatGitDate(d.commitTime)}', style: _kMuted),
                  if (d.refs.any((r) => r.kind != 'head')) ...[
                    const SizedBox(height: 6),
                    Text(
                      d.refs.where((r) => r.kind != 'head').map((r) => r.name).join(', '),
                      style: _kMuted.copyWith(color: IntelliJTheme.gitGreen),
                    ),
                  ],
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }
}
