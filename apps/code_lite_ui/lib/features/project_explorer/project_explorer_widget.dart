import 'package:flutter/material.dart';

import '../../core/theme/intellij_theme.dart';
import '../editor/syntax/languages.dart';
import '../tool_window/tool_window_actions.dart';

/// 左侧 Project 文件树。
///
/// - 展开状态按完整路径记(以前按目录名记,所有叫 `src` 的目录会一起展开);
/// - 初次扫描只到几层深,更深的目录(`loaded: false`)展开时再经 [onLoadChildren] 读取;
/// - Java / Kotlin 源码根(`src/main/java`)下只有一个子目录的包链压成一行,如 `com.acme.app`,与 IntelliJ 一致;
/// - 文件图标按语法引擎识别出的语言区分。
class ProjectExplorerWidget extends StatefulWidget {
  final Map<String, dynamic> treeData;
  final String activeFilePath;
  final ValueChanged<String> onSelectFile;

  /// 读取一个还没扫描的目录,返回该目录节点(含 children)。
  final Future<Map<String, dynamic>> Function(String path)? onLoadChildren;

  const ProjectExplorerWidget({
    super.key,
    required this.treeData,
    required this.activeFilePath,
    required this.onSelectFile,
    this.onLoadChildren,
  });

  @override
  State<ProjectExplorerWidget> createState() => _ProjectExplorerWidgetState();
}

class _ProjectExplorerWidgetState extends State<ProjectExplorerWidget> {
  final Set<String> _expanded = {};
  bool _rootCollapsed = false;

  /// 展开时按需读到的子节点(path → children)。
  final Map<String, List<Map<String, dynamic>>> _lazy = {};
  final Set<String> _loading = {};
  final Set<String> _failed = {};

  static const _sourceRoots = {'java', 'kotlin', 'scala', 'groovy'};

  @override
  void didUpdateWidget(ProjectExplorerWidget old) {
    super.didUpdateWidget(old);
    if (!identical(old.treeData, widget.treeData)) {
      // 重新扫描过(换项目或刷新):按需读的结果作废,展开状态在同一项目里保留。
      _lazy.clear();
      _failed.clear();
      if (old.treeData['path'] != widget.treeData['path']) {
        _expanded.clear();
        _rootCollapsed = false;
      }
    }
  }

  List<Map<String, dynamic>>? _childrenOf(Map<String, dynamic> node) {
    if (node['loaded'] == false) return _lazy[node['path'] as String? ?? ''];
    return (node['children'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? const [];
  }

  Future<void> _load(String path) async {
    final loader = widget.onLoadChildren;
    if (loader == null || _loading.contains(path) || _lazy.containsKey(path)) return;
    setState(() => _loading.add(path));
    try {
      final node = await loader(path);
      if (!mounted) return;
      setState(() {
        _lazy[path] = (node['children'] as List<dynamic>?)?.cast<Map<String, dynamic>>() ?? const [];
        _loading.remove(path);
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading.remove(path);
        _failed.add(path);
      });
    }
  }

  void _toggle(String path, Map<String, dynamic> node, {required bool isRoot}) {
    setState(() {
      if (isRoot) {
        _rootCollapsed = !_rootCollapsed;
      } else if (!_expanded.remove(path)) {
        _expanded.add(path);
      }
    });
    if (_isExpanded(path, isRoot: isRoot) && node['loaded'] == false) _load(path);
  }

  bool _isExpanded(String path, {required bool isRoot}) => isRoot ? !_rootCollapsed : _expanded.contains(path);

  @override
  Widget build(BuildContext context) {
    final rows = <Widget>[];
    if (widget.treeData.isNotEmpty) _addRows(rows, widget.treeData, 0, isRoot: true, inSourceRoot: false);
    // 宽度与右侧分隔线由外层统一给出(可拖动调整)。
    return Container(
      color: IntelliJTheme.panelBg,
      child: Column(
        children: [
          // Tool window header
          // IntelliJ 新 UI:标题栏和内容同一块底色,没有分隔线
          Container(
            height: 40,
            padding: const EdgeInsets.only(left: 12, right: 6),
            // 侧栏可拖窄到 160px:标题可省略,按钮用 InkWell 不占 Material 默认的大点击区。
            child: Row(
              children: [
                const Flexible(
                  child: Text(
                    'Project',
                    overflow: TextOverflow.ellipsis,
                    maxLines: 1,
                    style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600),
                  ),
                ),
                const SizedBox(width: 4),
                const Icon(Icons.arrow_drop_down, size: 16, color: IntelliJTheme.textMuted),
                const Spacer(),
                Tooltip(
                  message: 'Collapse All',
                  child: InkWell(
                    onTap: () => setState(_expanded.clear),
                    borderRadius: BorderRadius.circular(4),
                    child: const Padding(
                      padding: EdgeInsets.all(3),
                      child: Icon(Icons.unfold_less, size: 14, color: IntelliJTheme.textMuted),
                    ),
                  ),
                ),
                const ToolWindowActions(),
              ],
            ),
          ),

          // Tree contents:扁平的行列表,只构建看得见的行。
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(vertical: 4),
              children: rows,
            ),
          ),
        ],
      ),
    );
  }

  void _addRows(List<Widget> rows, Map<String, dynamic> node, int depth, {required bool isRoot, required bool inSourceRoot}) {
    final isDir = node['is_dir'] as bool? ?? false;
    if (!isDir) {
      rows.add(_fileRow(node, depth));
      return;
    }
    var name = node['name'] as String? ?? '';
    var dir = node;
    // 源码根下的包:只有一个子目录、没有文件的链压成 com.acme.app
    if (inSourceRoot) {
      while (true) {
        final kids = _childrenOf(dir);
        if (kids == null || kids.length != 1 || kids.first['is_dir'] != true) break;
        dir = kids.first;
        name = '$name.${dir['name']}';
      }
    }
    final path = dir['path'] as String? ?? name;
    final expanded = _isExpanded(path, isRoot: isRoot);
    rows.add(_dirRow(name, path, dir, depth, expanded: expanded, isRoot: isRoot, isPackage: inSourceRoot));
    if (!expanded) return;

    final kids = _childrenOf(dir);
    if (kids == null) {
      // 还没读(比如重新扫描后仍处于展开状态):补读一次
      if (!_loading.contains(path) && !_failed.contains(path)) {
        WidgetsBinding.instance.addPostFrameCallback((_) => _load(path));
      }
      rows.add(_hintRow(_failed.contains(path) ? '无法读取' : '加载中…', depth + 1));
      return;
    }
    final childInSource = inSourceRoot || _sourceRoots.contains(dir['name']);
    for (final child in kids) {
      _addRows(rows, child, depth + 1, isRoot: false, inSourceRoot: childInSource && child['is_dir'] == true);
    }
  }

  Widget _dirRow(
    String name,
    String path,
    Map<String, dynamic> node,
    int depth, {
    required bool expanded,
    required bool isRoot,
    required bool isPackage,
  }) {
    return InkWell(
      key: ValueKey('dir:$path'),
      onTap: () => _toggle(path, node, isRoot: isRoot),
      child: Container(
        padding: EdgeInsets.only(left: 8.0 + (depth * 12.0), top: 3, bottom: 3, right: 8),
        child: Row(
          children: [
            Icon(
              expanded ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
              size: 14,
              color: IntelliJTheme.textMuted,
            ),
            const SizedBox(width: 4),
            Icon(
              isPackage ? Icons.folder_special_outlined : Icons.folder,
              size: 14,
              color: isPackage ? const Color(0xFF8A9199) : IntelliJTheme.gitYellow,
            ),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.w500),
                overflow: TextOverflow.ellipsis,
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _hintRow(String text, int depth) => Padding(
        padding: EdgeInsets.only(left: 26.0 + (depth * 12.0), top: 3, bottom: 3),
        child: Text(text, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11.5)),
      );

  Widget _fileRow(Map<String, dynamic> node, int depth) {
    final name = node['name'] as String? ?? '';
    final path = node['path'] as String? ?? name;
    final isSelected = widget.activeFilePath == path;
    final (icon, color) = _fileIcon(name);
    return InkWell(
      key: ValueKey('file:$path'),
      onTap: () => widget.onSelectFile(path),
      child: Container(
        decoration: BoxDecoration(
          color: isSelected ? IntelliJTheme.selectionBg : Colors.transparent,
          borderRadius: BorderRadius.circular(4),
        ),
        padding: EdgeInsets.only(left: 26.0 + (depth * 12.0), top: 3, bottom: 3, right: 8),
        child: Row(
          children: [
            Icon(icon, size: 13, color: color),
            const SizedBox(width: 6),
            Expanded(
              child: Text(
                name,
                style: TextStyle(
                  color: isSelected ? const Color(0xFF6CB4F8) : IntelliJTheme.textPrimary,
                  fontSize: 12,
                ),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (isSelected)
              Container(
                width: 4,
                height: 4,
                decoration: const BoxDecoration(color: IntelliJTheme.gitGreen, shape: BoxShape.circle),
              ),
          ],
        ),
      ),
    );
  }

  /// 文件图标:按语法引擎识别的语言给图标与颜色。
  static (IconData, Color) _fileIcon(String name) {
    final lang = languages.detect(name);
    return switch (lang.id) {
      'java' => (Icons.coffee_outlined, const Color(0xFFE76F00)),
      'kotlin' => (Icons.change_history, const Color(0xFFA97BFF)),
      'scala' => (Icons.stacked_line_chart, const Color(0xFFDE3423)),
      'groovy' => (Icons.code, const Color(0xFF4298B8)),
      'dart' => (Icons.flutter_dash, const Color(0xFF40C4FF)),
      'rust' => (Icons.settings_suggest_outlined, const Color(0xFFD87642)),
      'go' => (Icons.code, const Color(0xFF00ADD8)),
      'c' || 'cpp' || 'csharp' => (Icons.code, const Color(0xFF659AD2)),
      'swift' => (Icons.code, const Color(0xFFF05138)),
      'javascript' => (Icons.javascript, const Color(0xFFE8D44D)),
      'typescript' => (Icons.code, const Color(0xFF3178C6)),
      'python' => (Icons.code, const Color(0xFF4B8BBE)),
      'ruby' => (Icons.diamond_outlined, const Color(0xFFCC342D)),
      'php' => (Icons.php, const Color(0xFF8892BF)),
      'shellscript' || 'powershell' => (Icons.terminal, const Color(0xFF89D185)),
      'sql' => (Icons.storage, const Color(0xFFCC7832)),
      'xml' || 'html' => (Icons.code, const Color(0xFFE8BF6A)),
      'css' => (Icons.css, const Color(0xFF42A5F5)),
      'json' => (Icons.data_object, const Color(0xFFCBCB41)),
      'markdown' => (Icons.description_outlined, const Color(0xFF6CB4F8)),
      'yaml' || 'toml' || 'ini' || 'properties' => (Icons.tune, IntelliJTheme.textMuted),
      'dockerfile' => (Icons.directions_boat_outlined, const Color(0xFF2496ED)),
      'ignore' => (Icons.visibility_off_outlined, IntelliJTheme.textMuted),
      _ => (Icons.insert_drive_file_outlined, IntelliJTheme.textMuted),
    };
  }
}
