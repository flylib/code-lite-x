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
import '../../core/l10n/l10n.dart';

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
      padding: const EdgeInsets.symmetric(horizontal: 14),
      color: IntelliJTheme.frameBg,
      // 右边那组(诊断、行列号、编码、资源占用)最多占 3/4 宽:窗口很窄时它在自己的格子里横向滚动,不会撑爆状态栏
      child: LayoutBuilder(
        builder: (context, constraints) => Row(
        children: [
          Expanded(child: _buildBreadcrumb()),
          const SizedBox(width: 12),
          ConstrainedBox(
            constraints: BoxConstraints(maxWidth: constraints.maxWidth * 0.75),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              reverse: true,
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: [
          _buildDiagnostics(),
          _buildCaretPosition(),
          // 语法引擎识别出的文件类型(按扩展名 / 文件名 / #! 首行)
          if (activeFile.isNotEmpty && !isSpecialTabId(activeFile))
            _StatusText(languages.detect(activeFile, firstLine: controller?.lineAt(0)).name),
          const _StatusText('LF'),
          const _StatusText('UTF-8'),
          _StatusText(tr('4 个空格', '4 spaces')),
          const SizedBox(width: 4),
          // 当前分支已在标题栏显示;这里改为 IDE 的内存 / CPU 占用
          const ResourceIndicator(),
                ],
              ),
            ),
          ),
        ],
      ),
      ),
    );
  }

  Widget _buildBreadcrumb() {
    if (activeFile.isEmpty) {
      return Text(
        tr('打开一个文件开始编辑', 'Open a file to start editing'),
        style: const TextStyle(color: IntelliJTheme.textStatus, fontSize: 12.5),
      );
    }

    final segments = activeFile.split('/');
    final fileName = segments.removeLast();
    final dir = segments.join('/');

    return Row(
      children: [
        const Icon(Icons.description_outlined, size: 14, color: IntelliJTheme.textStatus),
        const SizedBox(width: 5),
        if (dir.isNotEmpty) ...[
          Flexible(
            child: Text(
              dir,
              style: const TextStyle(color: IntelliJTheme.textStatus, fontSize: 12.5),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const Padding(
            padding: EdgeInsets.symmetric(horizontal: 3),
            child: Icon(Icons.chevron_right, size: 14, color: IntelliJTheme.textStatus),
          ),
        ],
        Flexible(
          child: Text(
            fileName,
            style: const TextStyle(color: Color(0xFFC9CCD1), fontSize: 12.5),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        if (isSaving) ...[
          const SizedBox(width: 8),
          Text(tr('保存中…', 'Saving…'), style: const TextStyle(color: IntelliJTheme.textStatus, fontSize: 12.5)),
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
        label: tr('$errors 个错误', errors == 1 ? '1 error' : '$errors errors'),
        emphasize: true,
      );
    }
    if (warnings > 0) {
      return _StatusChip(
        icon: Icons.warning_amber_rounded,
        color: IntelliJTheme.diagWarning,
        label: tr('$warnings 个警告', warnings == 1 ? '1 warning' : '$warnings warnings'),
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
        style: const TextStyle(color: IntelliJTheme.textStatus, fontSize: 12.5),
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
              fontSize: 12.5,
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
  String? _label;
  Timer? _timer;

  /// IDE 本身最近 [_peakWindow] 次采样的内存。界面每画一帧,渲染器(Impeller)都要临时分配
  /// 整窗大小的 GPU 帧缓冲(Retina 全屏约 80 MB),停止绘制约一秒后释放 —— 瞬时值因此
  /// 在两档之间来回跳。标签显示近期峰值,即 IDE 正常绘制时真正需要的量。
  final List<int> _selfHistory = [];
  static const int _peakWindow = 15;

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
      if (s.processes.isNotEmpty) {
        _selfHistory.add(s.processes.first.memoryBytes);
        if (_selfHistory.length > _peakWindow) _selfHistory.removeAt(0);
      }
      _snap = s;
      // 文字没变就不重建:每次重建都会让整个窗口重画一帧(以及上面说的帧缓冲分配)
      final label = _labelFor(s);
      if (label != _label && mounted) setState(() => _label = label);
    } catch (_) {
      // 采样失败不影响界面
    }
  }

  static String formatBytes(int bytes) {
    final mb = bytes / 1048576;
    return mb >= 1024 ? '${(mb / 1024).toStringAsFixed(1)} GB' : '${mb.round()} MB';
  }

  static String formatCpu(double? cpu) => cpu == null ? '—' : (cpu < 10 ? '${cpu.toStringAsFixed(1)}%' : '${cpu.round()}%');

  int get _selfPeak => _selfHistory.fold(0, (a, b) => a > b ? a : b);

  String? _labelFor(ResourceSnapshot s) {
    if (s.processes.isEmpty) return null;
    final mem = tr('内存 ${formatBytes(_selfPeak)}', 'Mem ${formatBytes(_selfPeak)}');
    return _sampler.detailed ? '$mem · CPU ${formatCpu(s.processes.first.cpuPercent)}' : mem;
  }

  @override
  Widget build(BuildContext context) {
    final s = _snap;
    final label = _label;
    if (s == null || label == null) return const SizedBox.shrink();
    final hasCpu = _sampler.detailed;
    // 标签只显示 IDE 本身;语言服务器(gopls、jdtls……)是独立进程,内存随它自己的 GC 起伏
    // 上百 MB,算进来数字会来回跳。它们和合计放在悬停提示里。
    final self = s.processes.first;
    final peak = _selfPeak;
    final details = [
      for (final p in s.processes)
        '${p.pid == self.pid ? 'CodeLiteX' : p.name}  ${formatBytes(p.memoryBytes)}${hasCpu ? ' · CPU ${formatCpu(p.cpuPercent)}' : ''}',
      if (s.processes.length > 1) '${tr('合计', 'Total')}  ${formatBytes(s.totalMemoryBytes)}${hasCpu ? ' · CPU ${formatCpu(s.totalCpuPercent)}' : ''}',
      if (peak > self.memoryBytes)
        tr('CodeLiteX 近 30 秒峰值 ${formatBytes(peak)}(界面绘制时的 GPU 帧缓冲,停止绘制后释放)',
            'CodeLiteX peak in the last 30 s: ${formatBytes(peak)} (GPU frame buffers while the UI draws; released when drawing stops)'),
    ].join('\n');
    // 悬停时刷新一次,提示里的数字不会停在上次重建时
    return MouseRegion(
      onEnter: (_) => setState(() {}),
      child: Tooltip(
        message: s.processes.length > 1
            ? tr('IDE 本身 + 子进程(语言服务器等)\n当前占用:\n$details', 'IDE itself + child processes (language servers etc.)\nCurrent usage:\n$details')
            : tr('当前占用:\n$details', 'Current usage:\n$details'),
        waitDuration: const Duration(milliseconds: 400),
        child: Padding(
          padding: const EdgeInsets.only(left: 6),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Icon(Icons.memory, size: 14, color: IntelliJTheme.textStatus),
              const SizedBox(width: 4),
              Text(label, key: const ValueKey('resource-usage'), style: const TextStyle(color: IntelliJTheme.textStatus, fontSize: 12.5)),
            ],
          ),
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
      // 状态没变就不重建(每次重建都会重画整个窗口)
      if (mounted && !_sameServer(hit, _server)) setState(() => _server = hit);
    } catch (_) {}
  }

  static bool _sameServer(Map<String, dynamic>? a, Map<String, dynamic>? b) {
    if (a == null || b == null) return a == b;
    for (final k in const ['state', 'initialized', 'command', 'error', 'source', 'projects', 'shared']) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  @override
  Widget build(BuildContext context) {
    final s = _server;
    if (s == null) return const SizedBox.shrink(); // 这个分组还没启动过服务端
    final name = LspStatusChip.displayName(widget.group, s['command'] as String? ?? '');
    final error = s['error'] as String?;
    final (IconData icon, Color color, String label, String tip) = switch (s['state']) {
      'missing' => (Icons.extension_off_outlined, IntelliJTheme.textMuted, tr('未安装 $name', '$name not installed'),
          tr('没有找到 $name。可在 CodeLiteX ▸ 插件… 安装对应的语言插件;目前只做括号配对检查。', '$name was not found. Install the language plugin in CodeLiteX ▸ Plugins…; only bracket matching is checked for now.')),
      'crashed' => (Icons.error_outline, IntelliJTheme.diagError, tr('$name 已退出', '$name exited'),
          '${tr('$name 反复崩溃,已停用,只做括号配对检查。', '$name kept crashing and was disabled; only bracket matching is checked.')}${error == null ? '' : '\n$error'}'),
      'suspended' => (Icons.pause_circle_outline, IntelliJTheme.textMuted, tr('$name 已暂停', '$name paused'),
          tr('项目在后台太久,$name 已停下省内存;打开文件或切回来时会重新启动', 'The project was in the background too long, so $name was stopped to save memory; it restarts when you open a file or switch back')),
      _ when s['initialized'] != true => (Icons.sync, IntelliJTheme.textMuted, tr('$name 启动中…', '$name starting…'),
          tr('$name 正在启动(大项目首次打开需要建索引)', '$name is starting (large projects need indexing the first time)')),
      _ => (
          Icons.check_circle_outline,
          IntelliJTheme.gitGreen,
          name,
          '${tr('$name 运行中', '$name running')}${s['source'] != null ? tr('(插件 ${s['source']})', ' (plugin ${s['source']})') : ''}'
              '${s['shared'] != null && (s['projects'] as int? ?? 1) > 1 ? tr('\n和项目组里的 ${s['projects']} 个项目共用一个进程', '\nShared by ${s['projects']} projects in the project group') : ''}'
              '\n${s['command']}'
        ),
    };
    return Tooltip(
      message: tip,
      waitDuration: const Duration(milliseconds: 400),
      child: _StatusChip(icon: icon, color: color, label: label),
    );
  }
}
