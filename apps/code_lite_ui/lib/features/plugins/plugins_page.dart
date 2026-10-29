import 'package:flutter/material.dart';

import '../../core/plugins/plugin_manager.dart';
import '../../core/theme/intellij_theme.dart';
import 'plugin_banner.dart' show showPluginLog;
import '../../core/l10n/l10n.dart';

const TextStyle _title = TextStyle(color: IntelliJTheme.textHigh, fontSize: 13, fontWeight: FontWeight.w600);
const TextStyle _text = TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12.5);
const TextStyle _muted = TextStyle(color: IntelliJTheme.textMuted, fontSize: 12);

/// 设置 ▸ Plugins:插件列表(目前来自随 IDE 打包的目录,以后接插件市场),安装 / 卸载 / 启用 / 停用。
class PluginsPage extends StatefulWidget {
  const PluginsPage({super.key, required this.plugins});

  final PluginManager plugins;

  @override
  State<PluginsPage> createState() => _PluginsPageState();
}

class _PluginsPageState extends State<PluginsPage> {
  String _query = '';
  bool _installedOnly = false;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: widget.plugins,
      builder: (context, _) {
        final p = widget.plugins;
        final q = _query.trim().toLowerCase();
        final items = [
          for (final m in p.all)
            if ((q.isEmpty || '${m.name} ${m.description} ${m.extensions.join(' ')}'.toLowerCase().contains(q)) &&
                (!_installedOnly || const {PluginStatus.enabled, PluginStatus.disabled}.contains(p.statusOf(m.id))))
              m,
        ];
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            Row(
              children: [
                Expanded(
                  child: SizedBox(
                    height: 32,
                    child: TextField(
                      style: _text,
                      onChanged: (v) => setState(() => _query = v),
                      decoration: InputDecoration(
                        hintText: tr('搜索插件(名称、扩展名)', 'Search plugins (name, extension)'),
                        hintStyle: _muted,
                        isDense: true,
                        prefixIcon: const Icon(Icons.search, size: 16, color: IntelliJTheme.textSecondary),
                        prefixIconConstraints: const BoxConstraints(minWidth: 30),
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        border: const OutlineInputBorder(borderSide: BorderSide(color: IntelliJTheme.border)),
                        enabledBorder: const OutlineInputBorder(borderSide: BorderSide(color: IntelliJTheme.border)),
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                InkWell(
                  onTap: () => setState(() => _installedOnly = !_installedOnly),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(_installedOnly ? Icons.check_box : Icons.check_box_outline_blank, size: 16, color: IntelliJTheme.textSecondary),
                      const SizedBox(width: 4),
                      Text(tr('只看已安装', 'Installed only'), style: _text),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 10),
            if (items.isEmpty) Padding(padding: const EdgeInsets.all(16), child: Text(tr('没有匹配的插件', 'No matching plugins'), style: _muted)),
            for (final m in items) _PluginTile(plugins: p, manifest: m),
          ],
        );
      },
    );
  }
}

class _PluginTile extends StatelessWidget {
  const _PluginTile({required this.plugins, required this.manifest});

  final PluginManager plugins;
  final PluginManifest manifest;

  @override
  Widget build(BuildContext context) {
    final m = manifest;
    final status = plugins.statusOf(m.id);
    final task = plugins.taskOf(m.id);
    final unmet = plugins.unmetRequirements(m.id);
    final bundled = plugins.isBundled(m.id);
    final (chip, chipColor) = switch (status) {
      PluginStatus.enabled => (bundled ? tr('内置', 'Bundled') : tr('已安装', 'Installed'), const Color(0xFF5FB865)),
      PluginStatus.disabled => (tr('已停用', 'Disabled'), IntelliJTheme.textMuted),
      PluginStatus.system => (tr('系统已提供', 'Provided by system'), const Color(0xFF6897BB)),
      PluginStatus.installing => (tr('安装中', 'Installing'), IntelliJTheme.accentBlue),
      PluginStatus.available => ('', IntelliJTheme.textMuted),
    };
    final kind = m.buildTools.isNotEmpty
        ? tr('构建工具', 'Build Tool')
        : (m.languageServers.isNotEmpty ? tr('语言服务器', 'Language Server') : tr('语法高亮', 'Syntax Highlighting'));
    return Container(
      key: ValueKey('plugin-${m.id}'),
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: IntelliJTheme.editorBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: IntelliJTheme.borderSubtle),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              const Icon(Icons.extension_outlined, size: 18, color: IntelliJTheme.textSecondary),
              const SizedBox(width: 8),
              Flexible(child: Text(m.name, overflow: TextOverflow.ellipsis, style: _title)),
              const SizedBox(width: 8),
              Text('${m.version} · ${m.publisher} · $kind${(m.sizeMB ?? 0) > 0 ? tr(' · 约 ${m.sizeMB!.round()} MB', ' · about ${m.sizeMB!.round()} MB') : ''}', style: _muted),
              if (chip.isNotEmpty) ...[
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                  decoration: BoxDecoration(border: Border.all(color: chipColor), borderRadius: BorderRadius.circular(8)),
                  child: Text(chip, style: TextStyle(color: chipColor, fontSize: 11)),
                ),
              ],
            ],
          ),
          const SizedBox(height: 4),
          Padding(
            padding: const EdgeInsets.only(left: 26),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(m.description, style: _text),
                if (m.extensions.isNotEmpty) Text('${tr('文件类型:', 'File types: ')}${m.extensions.map((e) => '.$e').join(' ')}', style: _muted),
                if (m.buildTools.isNotEmpty) Text('${tr('检测文件:', 'Detected by: ')}${m.buildTools.expand((t) => t.markers).join(' ')}', style: _muted),
                if (status == PluginStatus.system) Text(tr('已在用系统里的 ${plugins.systemPathOf(m.id)}', 'Using the one on the system: ${plugins.systemPathOf(m.id)}'), style: _muted),
                if (unmet.isNotEmpty && status == PluginStatus.available)
                  Text(tr('需要 ${unmet.map((r) => r.label).join('、')}:${unmet.map((r) => r.hint ?? '').join(' ')}', 'Requires ${unmet.map((r) => r.label).join(', ')}: ${unmet.map((r) => r.hint ?? '').join(' ')}'), style: const TextStyle(color: Color(0xFFE5C07B), fontSize: 12)),
                if (task != null && task.running) ...[
                  const SizedBox(height: 4),
                  Text(task.message, style: _muted, overflow: TextOverflow.ellipsis),
                  const SizedBox(height: 4),
                  LinearProgressIndicator(value: task.fraction, minHeight: 3),
                ],
                if (task != null && !task.running && task.error != null)
                  Text(tr('安装失败:${task.error}', 'Installation failed: ${task.error}'), style: const TextStyle(color: Color(0xFFE5534B), fontSize: 12)),
              ],
            ),
          ),
          // 操作按钮放在卡片右下角,靠右对齐
          const SizedBox(height: 6),
          Row(mainAxisAlignment: MainAxisAlignment.end, children: _actions(context, status, task)),
        ],
      ),
    );
  }

  List<Widget> _actions(BuildContext context, PluginStatus status, PluginTask? task) {
    final id = manifest.id;
    if (plugins.isBundled(id)) {
      // 随 IDE 自带:不能卸载,只能停用
      return status == PluginStatus.enabled
          ? [_Btn(tr('停用', 'Disable'), () => plugins.setEnabled(id, false))]
          : [_Btn(tr('启用', 'Enable'), () => plugins.setEnabled(id, true), primary: true)];
    }
    return switch (status) {
      PluginStatus.installing => [_Btn(tr('取消', 'Cancel'), () => plugins.cancelInstall(id))],
      PluginStatus.enabled => [_Btn(tr('停用', 'Disable'), () => plugins.setEnabled(id, false)), _Btn(tr('卸载', 'Uninstall'), () => _confirmUninstall(context))],
      PluginStatus.disabled => [_Btn(tr('启用', 'Enable'), () => plugins.setEnabled(id, true), primary: true), _Btn(tr('卸载', 'Uninstall'), () => _confirmUninstall(context))],
      PluginStatus.system || PluginStatus.available => [
          if (task?.log.isNotEmpty == true) _Btn(tr('日志', 'Log'), () => showPluginLog(context, manifest, task!.log)),
          _Btn(task?.error != null ? tr('重试', 'Retry') : tr('安装', 'Install'), () => plugins.install(id), primary: true),
        ],
    };
  }

  Future<void> _confirmUninstall(BuildContext context) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: Text(tr('卸载「${manifest.name}」?', 'Uninstall "${manifest.name}"?'), style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 15)),
        content: Text(tr('会删除插件目录里下载的内容。之后可以随时重新安装。', 'Files downloaded into the plugin directory will be deleted. You can reinstall it at any time.'), style: _text),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: Text(tr('取消', 'Cancel'))),
          FilledButton(onPressed: () => Navigator.pop(ctx, true), child: Text(tr('卸载', 'Uninstall'))),
        ],
      ),
    );
    if (ok == true) await plugins.uninstall(manifest.id);
  }
}

class _Btn extends StatelessWidget {
  const _Btn(this.label, this.onTap, {this.primary = false});

  final String label;
  final VoidCallback onTap;
  final bool primary;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.only(left: 6),
        child: OutlinedButton(
          onPressed: onTap,
          style: OutlinedButton.styleFrom(
            visualDensity: VisualDensity.compact,
            minimumSize: const Size(0, 26),
            padding: const EdgeInsets.symmetric(horizontal: 10),
            side: BorderSide(color: primary ? IntelliJTheme.accentBlue : IntelliJTheme.border),
            foregroundColor: primary ? IntelliJTheme.accentBlue : IntelliJTheme.textHigh,
            textStyle: const TextStyle(fontSize: 12),
          ),
          child: Text(label),
        ),
      );
}
