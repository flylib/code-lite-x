import 'package:flutter/material.dart';

import '../../core/plugins/plugin_manager.dart';
import '../../core/theme/intellij_theme.dart';

const TextStyle _text = TextStyle(color: IntelliJTheme.textHigh, fontSize: 12.5);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

/// 编辑区顶部的插件提示条(打开新语言的文件时):推荐安装 → 安装进度 → 失败原因。
/// 没有要说的就是空的。
class PluginBanner extends StatelessWidget {
  const PluginBanner({super.key, required this.plugins, required this.filePath});

  final PluginManager plugins;
  final String filePath;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: plugins,
      builder: (context, _) {
        final m = plugins.suggestionFor(filePath);
        if (m == null) {
          // 推荐条关掉后,安装失败的结果仍要能看到
          for (final t in _failedTasksFor(filePath)) {
            return _failed(context, plugins.manifestOf(t.pluginId)!, t);
          }
          return const SizedBox.shrink();
        }
        final task = plugins.taskOf(m.id);
        if (task != null && task.running) return _installing(m, task);
        if (task != null && task.error != null) return _failed(context, m, task);
        return _suggest(m);
      },
    );
  }

  Iterable<PluginTask> _failedTasksFor(String path) sync* {
    final ext = path.split('.').last.toLowerCase();
    for (final m in plugins.catalog) {
      final t = plugins.taskOf(m.id);
      if (t != null && !t.running && t.error != null && m.extensions.contains(ext)) yield t;
    }
  }

  Widget _bar({required Color color, required IconData icon, required List<Widget> children, Widget? bottom}) {
    return Container(
      key: const ValueKey('plugin-banner'),
      decoration: BoxDecoration(
        color: color,
        border: const Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      padding: const EdgeInsets.fromLTRB(12, 6, 8, 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(icon, size: 16, color: IntelliJTheme.textSecondary),
              const SizedBox(width: 8),
              ...children,
            ],
          ),
          if (bottom != null) ...[const SizedBox(height: 6), bottom],
        ],
      ),
    );
  }

  Widget _suggest(PluginManifest m) {
    final ext = filePath.split('.').last;
    final what = m.languageServers.isNotEmpty ? '错误检查、文件大纲' : '语法高亮';
    final size = (m.sizeMB ?? 0) > 0 ? '(约 ${m.sizeMB!.round()} MB)' : '';
    final unmet = plugins.unmetRequirements(m.id);
    return _bar(
      color: const Color(0xFF2B3544),
      icon: Icons.extension_outlined,
      children: [
        Expanded(
          child: Text.rich(
            TextSpan(children: [
              TextSpan(text: '「${m.name}」插件可以为 .$ext 文件提供$what$size', style: _text),
              if (unmet.isNotEmpty) TextSpan(text: '  需要 ${unmet.map((r) => r.label).join('、')}(未找到)', style: _muted),
            ]),
            overflow: TextOverflow.ellipsis,
            maxLines: 1,
          ),
        ),
        _Action('安装', () => plugins.install(m.id), primary: true),
        _Action('以后再说', () => plugins.snooze(m.id)),
        _Action('不再提示', () => plugins.dismiss(m.id)),
      ],
    );
  }

  Widget _installing(PluginManifest m, PluginTask task) {
    return _bar(
      color: const Color(0xFF2B3544),
      icon: Icons.downloading,
      children: [
        Expanded(
          child: Text('正在安装「${m.name}」:${task.message}', overflow: TextOverflow.ellipsis, maxLines: 1, style: _text),
        ),
        _Action('取消', () => plugins.cancelInstall(m.id)),
      ],
      bottom: ClipRRect(
        borderRadius: BorderRadius.circular(2),
        child: LinearProgressIndicator(value: task.fraction, minHeight: 3),
      ),
    );
  }

  Widget _failed(BuildContext context, PluginManifest m, PluginTask task) {
    return _bar(
      color: const Color(0xFF3E2A2C),
      icon: Icons.error_outline,
      children: [
        Expanded(
          child: Text('「${m.name}」插件安装失败:${task.error}', overflow: TextOverflow.ellipsis, maxLines: 2, style: _text),
        ),
        _Action('重试', () => plugins.install(m.id), primary: true),
        if (task.log.isNotEmpty) _Action('详情', () => showPluginLog(context, m, task.log)),
        _Action('关闭', () => plugins.clearTask(m.id)),
      ],
    );
  }
}

/// 安装命令输出的末尾。
Future<void> showPluginLog(BuildContext context, PluginManifest m, String log) => showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: Text('「${m.name}」安装日志', style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
        content: SizedBox(
          width: 640,
          height: 360,
          child: SingleChildScrollView(
            child: SelectableText(
              log,
              style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12, fontFamily: IntelliJMetrics.codeFontFamily),
            ),
          ),
        ),
        actions: [TextButton(onPressed: () => Navigator.pop(ctx), child: const Text('关闭'))],
      ),
    );

class _Action extends StatelessWidget {
  const _Action(this.label, this.onTap, {this.primary = false});

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 4),
        child: InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(4),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
            child: Text(
              label,
              style: TextStyle(color: primary ? IntelliJTheme.accentBlue : IntelliJTheme.textSecondary, fontSize: 12.5, fontWeight: primary ? FontWeight.w600 : FontWeight.normal),
            ),
          ),
        ),
      );
}
