import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/client/api_client.dart';
import '../../core/lsp/lsp_common.dart' show lspLanguageIdFor, lspServerGroupFor, lspServerCandidates;
import '../../core/platform/process_stats.dart';
import '../../core/theme/intellij_theme.dart';
import '../editor/code_editor_controller.dart';
import '../editor/editor_view_widget.dart' show isSpecialTabId;
import '../editor/lsp_overlay.dart';
import '../editor/syntax/languages.dart';

/// 底部状态栏。左侧是当前文件在工作区里的位置,右侧是光标位置与文件属性。
///
/// 之前这里显示的是 "Flutter Engine: Impeller (120 FPS)" / "Rust Core: Online" /
/// "SQLite WAL: Active" —— 那些是实现细节,不是使用者能操作或需要判断的东西。
/// 现在只留能据此做决定的信息:改到第几行、有几个错误、换行符和缩进是什么。
class StatusBarWidget extends StatelessWidget {
  const StatusBarWidget({
    super.key,
    required this.activeFile,
    required this.diagnostics,
    this.controller,
    this.client,
    this.isSaving = false,
  });

  final String activeFile;
  final List<EditorDiagnostic> diagnostics;
  final CodeEditorController? controller;

  /// 用来查询语言服务器状态;为 null 时不显示语言服务器。
  final ApiClient? client;
  final bool isSaving;

  @override
  Widget build(BuildContext context) {
    return Container(
      height: IntelliJMetrics.statusBar,
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: const BoxDecoration(
        color: IntelliJTheme.headerBg,
        border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Row(
        children: [
          Expanded(child: _buildBreadcrumb()),
          const SizedBox(width: 12),
          _buildDiagnostics(),
          _buildCaretPosition(),
          // 语法引擎识别出的文件类型(按扩展名 / 文件名 / #! 首行)
          if (activeFile.isNotEmpty && !isSpecialTabId(activeFile))
            _StatusText(languages.detect(activeFile, firstLine: controller?.lineAt(0)).name),
          const _StatusText('LF'),
          const _StatusText('UTF-8'),
          const _StatusText('4 spaces'),
          const SizedBox(width: 4),
          // 当前分支已在标题栏显示;这里改为 IDE 的内存 / CPU 占用
          const ResourceIndicator(),
        ],
      ),
    );
  }

  Widget _buildBreadcrumb() {
    if (activeFile.isEmpty) {
      return const Text(
        '打开一个文件开始编辑',
        style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10),
      );
    }

    final segments = activeFile.split('/');
    final fileName = segments.removeLast();
    final dir = segments.join('/');

    return Row(
      children: [
        const Icon(Icons.description_outlined, size: 12, color: IntelliJTheme.textMuted),
        const SizedBox(width: 5),
        if (dir.isNotEmpty) ...[
          Flexible(
            child: Text(
              dir,
              style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 3),
            child: Icon(Icons.chevron_right, size: 12, color: IntelliJTheme.textGutter),
          ),
        ],
        Text(
          fileName,
          style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 10),
        ),
        if (isSaving) ...[
          const SizedBox(width: 8),
          const Text('保存中…', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
        ],
      ],
    );
  }

  Widget _buildDiagnostics() {
    final errors = diagnostics.where((d) => d.isError).length;
    final warnings = diagnostics.where((d) => d.isWarning).length;

    if (errors > 0) {
      return _StatusChip(
        icon: Icons.error_outline,
        color: IntelliJTheme.diagError,
        label: '$errors 个错误',
        emphasize: true,
      );
    }
    if (warnings > 0) {
      return _StatusChip(
        icon: Icons.warning_amber_rounded,
        color: IntelliJTheme.diagWarning,
        label: '$warnings 个警告',
      );
    }
    // 没有错误 / 警告时显示当前文件所用的语言服务器(以前这里写死了 rust-analyzer)
    final c = client;
    if (c == null || activeFile.isEmpty || isSpecialTabId(activeFile)) return const SizedBox.shrink();
    final lang = lspLanguageIdFor(activeFile);
    final group = lang == null ? null : lspServerGroupFor(lang);
    if (group == null) return const SizedBox.shrink();
    return LspStatusChip(client: c, group: group);
  }

  Widget _buildCaretPosition() {
    final c = controller;
    if (c == null) return const SizedBox.shrink();

    return ListenableBuilder(
      listenable: c,
      builder: (context, _) {
        final pos = c.cursorPosition;
        return _StatusText('${pos.line + 1}:${pos.col + 1}');
      },
    );
  }
}

class _StatusText extends StatelessWidget {
  const _StatusText(this.label);
  final String label;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Text(
        label,
        style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10, fontFamily: 'monospace'),
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({
    required this.icon,
    required this.color,
    required this.label,
    this.emphasize = false,
  });

  final IconData icon;
  final Color color;
  final String label;
  final bool emphasize;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 6),
      child: Row(
        children: [
          Icon(icon, size: 12, color: color),
          const SizedBox(width: 4),
          Text(
            label,
            style: TextStyle(
              color: color,
              fontSize: 10,
              fontWeight: emphasize ? FontWeight.w600 : FontWeight.normal,
            ),
          ),
        ],
      ),
    );
  }
}

/// 状态栏右下角:IDE(含语言服务器等子进程)当前的内存与 CPU 占用,每 2 秒刷新。
/// 内存口径与「活动监视器」一致(phys_footprint);悬停显示每个进程的明细。
class ResourceIndicator extends StatefulWidget {
  const ResourceIndicator({super.key, this.interval = const Duration(seconds: 2), this.sampler});

  final Duration interval;

  /// 测试可注入。
  final ProcessStatsSampler? sampler;

  @override
  State<ResourceIndicator> createState() => _ResourceIndicatorState();
}

class _ResourceIndicatorState extends State<ResourceIndicator> {
  late final ProcessStatsSampler _sampler = widget.sampler ?? ProcessStatsSampler();
  ResourceSnapshot? _snap;
  Set<int> _prevPids = const {};
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _tick();
    _timer = Timer.periodic(widget.interval, (_) => _tick());
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  void _tick() {
    try {
      final raw = _sampler.sample();
      // 只算连续两次都在的子进程:git、gh 这类一闪而过的命令不该让数字跳动
      final pids = {for (final p in raw.processes) p.pid};
      final s = raw.processes.isEmpty
          ? raw
          : ResourceSnapshot([raw.processes.first, ...raw.processes.skip(1).where((p) => _prevPids.contains(p.pid))]);
      _prevPids = pids;
      if (mounted) setState(() => _snap = s);
    } catch (_) {
      // 采样失败不影响界面
    }
  }

  static String formatBytes(int bytes) {
    final mb = bytes / 1048576;
    return mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '${mb.round()} MB';
  }

  static String formatCpu(double? cpu) => cpu == null ? '—' : (cpu < 10 ? '${cpu.toStringAsFixed(1)}%' : '${cpu.round()}%');

  @override
  Widget build(BuildContext context) {
    final s = _snap;
    if (s == null || s.processes.isEmpty) return const SizedBox.shrink();
    final hasCpu = _sampler.detailed;
    // 标签只显示 IDE 本身;语言服务器(gopls、jdtls……)是独立进程,内存随它自己的 GC 起伏
    // 上百 MB,算进来数字会来回跳。它们和合计放在悬停提示里。
    final self = s.processes.first;
    final label = hasCpu ? 'Mem ${formatBytes(self.memoryBytes)} · CPU ${formatCpu(self.cpuPercent)}' : 'Mem ${formatBytes(self.memoryBytes)}';
    final details = [
      for (final p in s.processes)
        '${p.pid == self.pid ? 'CodeLiteX' : p.name}  ${formatBytes(p.memoryBytes)}${hasCpu ? ' · CPU ${formatCpu(p.cpuPercent)}' : ''}',
      if (s.processes.length > 1) '合计  ${formatBytes(s.totalMemoryBytes)}${hasCpu ? ' · CPU ${formatCpu(s.totalCpuPercent)}' : ''}',
    ].join('\n');
    return Tooltip(
      message: '${s.processes.length > 1 ? 'IDE 本身 + 子进程(语言服务器等)\n' : ''}$details',
      waitDuration: const Duration(milliseconds: 400),
      child: Padding(
        padding: const EdgeInsets.only(left: 6),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const Icon(Icons.memory, size: 12, color: IntelliJTheme.textMuted),
            const SizedBox(width: 4),
            Text(label, key: const ValueKey('resource-usage'), style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
          ],
        ),
      ),
    );
  }
}

/// 当前文件所用语言服务器的状态:运行中 / 启动中 / 未安装 / 已退出。每 2 秒查询一次(进程内,开销很小)。
class LspStatusChip extends StatefulWidget {
  const LspStatusChip({super.key, required this.client, required this.group, this.interval = const Duration(seconds: 2)});

  final ApiClient client;

  /// 服务端分组(java / go / rust / typescript ……)。
  final String group;
  final Duration interval;

  /// 状态栏里显示的服务端名字。
  static String displayName(String group, String command) {
    if (group == 'java') return 'jdtls';
    final exe = command.trim().split(' ').first;
    if (exe.isNotEmpty) {
      final base = exe.split(RegExp(r'[/\\]')).last;
      return base == 'dart' ? 'Dart Analysis Server' : base;
    }
    final candidates = lspServerCandidates[group];
    return candidates == null || candidates.isEmpty ? group : candidates.first.first;
  }

  @override
  State<LspStatusChip> createState() => _LspStatusChipState();
}

class _LspStatusChipState extends State<LspStatusChip> {
  Map<String, dynamic>? _server;
  Timer? _timer;

  @override
  void initState() {
    super.initState();
    _poll();
    _timer = Timer.periodic(widget.interval, (_) => _poll());
  }

  @override
  void didUpdateWidget(LspStatusChip old) {
    super.didUpdateWidget(old);
    if (old.group != widget.group) {
      _server = null;
      _poll();
    }
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  Future<void> _poll() async {
    try {
      final st = await widget.client.lspStatus();
      final servers = (st['servers'] as List? ?? const []).cast<Map>();
      Map<String, dynamic>? hit;
      for (final s in servers) {
        if (s['language'] == widget.group) hit = Map<String, dynamic>.from(s);
      }
      if (mounted) setState(() => _server = hit);
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    final s = _server;
    if (s == null) return const SizedBox.shrink(); // 这个分组还没启动过服务端
    final name = LspStatusChip.displayName(widget.group, s['command'] as String? ?? '');
    final error = s['error'] as String?;
    final (IconData icon, Color color, String label, String tip) = switch (s['state']) {
      'missing' => (Icons.extension_off_outlined, IntelliJTheme.textMuted, '未安装 $name', '没有找到 $name。可在 CodeLiteX ▸ Plugins… 安装对应的语言插件;目前只做括号配对检查。'),
      'crashed' => (Icons.error_outline, IntelliJTheme.diagError, '$name 已退出', '$name 反复崩溃,已停用,只做括号配对检查。${error == null ? '' : '\n$error'}'),
      _ when s['initialized'] != true => (Icons.sync, IntelliJTheme.textMuted, '$name 启动中…', '$name 正在启动(大项目首次打开需要建索引)'),
      _ => (Icons.check_circle_outline, IntelliJTheme.gitGreen, name, '$name 运行中${s['source'] != null ? '(插件 ${s['source']})' : ''}\n${s['command']}'),
    };
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: _StatusChip(icon: icon, color: color, label: label),
    );
  }
}
