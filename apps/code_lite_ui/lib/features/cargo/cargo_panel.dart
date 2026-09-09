import 'package:flutter/material.dart';

import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';

/// 一次 cargo 运行的结果。
class _RunResult {
  const _RunResult({
    required this.command,
    required this.success,
    required this.exitCode,
    required this.elapsed,
    required this.tail,
  });

  final String command;
  final bool success;
  final int exitCode;
  final Duration elapsed;
  final String tail;
}

class _CargoCommand {
  const _CargoCommand(this.name, this.args, this.hint);
  final String name;
  final List<String> args;
  final String hint;
}

/// 右侧 Cargo 工具窗:workspace 成员、标准命令、上一次运行的结果。
///
/// 成员列表来自真实的工作区扫描(`crates/` 下的目录),不写死。
/// 所有 cargo 调用都带 `--offline` —— AGENTS.md 的离线铁律。
class CargoPanel extends StatefulWidget {
  const CargoPanel({
    super.key,
    required this.client,
    required this.tree,
    required this.onClose,
  });

  final ApiClient client;
  final Map<String, dynamic> tree;
  final VoidCallback onClose;

  @override
  State<CargoPanel> createState() => _CargoPanelState();
}

class _CargoPanelState extends State<CargoPanel> {
  static const List<_CargoCommand> _commands = [
    _CargoCommand('build', ['build', '--offline'], '编译整个 workspace'),
    _CargoCommand('test', ['test', '--offline', '--workspace'], '运行全部测试'),
    _CargoCommand('check', ['check', '--offline'], '只做类型检查'),
    _CargoCommand('clippy', ['clippy', '--offline'], 'Lint 检查'),
    _CargoCommand('fmt', ['fmt'], '格式化'),
  ];

  String? _running;
  _RunResult? _last;
  bool _commandsOpen = true;
  bool _membersOpen = true;

  List<String> get _members {
    final children = widget.tree['children'];
    if (children is! List) return const [];
    for (final node in children) {
      if (node is Map && node['name'] == 'crates') {
        final crates = node['children'];
        if (crates is! List) return const [];
        return crates
            .whereType<Map>()
            .where((c) => c['is_dir'] == true)
            .map((c) => '${c['name']}')
            .toList()
          ..sort();
      }
    }
    return const [];
  }

  Future<void> _run(_CargoCommand cmd) async {
    if (_running != null) return;
    setState(() => _running = cmd.name);
    final started = DateTime.now();

    final res = await widget.client.terminalExec('cargo', cmd.args);

    if (!mounted) return;
    final stdout = '${res['stdout'] ?? ''}';
    final stderr = '${res['stderr'] ?? ''}';
    final output = stderr.trim().isNotEmpty ? stderr : stdout;
    final lines = output.trim().split('\n');

    setState(() {
      _running = null;
      _last = _RunResult(
        command: 'cargo ${cmd.args.join(' ')}',
        success: res['success'] == true,
        exitCode: (res['exit_code'] as int?) ?? -1,
        elapsed: DateTime.now().difference(started),
        tail: lines.isEmpty ? '' : lines.last.trim(),
      );
    });
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: IntelliJMetrics.cargoPanel,
      decoration: const BoxDecoration(
        color: IntelliJTheme.panelBg,
        border: Border(left: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Column(
        children: [
          _buildHeader(),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.only(top: 2, bottom: 6),
              children: [
                _buildRootRow(),
                _buildGroupRow(
                  label: '命令',
                  isOpen: _commandsOpen,
                  onTap: () => setState(() => _commandsOpen = !_commandsOpen),
                ),
                if (_commandsOpen)
                  for (final cmd in _commands) _buildCommandRow(cmd),
                _buildGroupRow(
                  label: '成员',
                  trailing: '${_members.length}',
                  isOpen: _membersOpen,
                  onTap: () => setState(() => _membersOpen = !_membersOpen),
                ),
                if (_membersOpen) ...[
                  if (_members.isEmpty)
                    const Padding(
                      padding: EdgeInsets.only(left: 48, top: 4, bottom: 4, right: 12),
                      child: Text(
                        '扫描工作区后显示成员',
                        style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
                      ),
                    )
                  else
                    for (final m in _members) _buildMemberRow(m),
                ],
              ],
            ),
          ),
          _buildLastRun(),
        ],
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      height: IntelliJMetrics.toolWindowHeader,
      padding: const EdgeInsets.only(left: 12, right: 6),
      decoration: const BoxDecoration(
        border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Row(
        children: [
          const Icon(Icons.inventory_2_outlined, size: 14, color: IntelliJTheme.syntaxKeyword),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              'Cargo',
              style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.w600),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          _HeaderAction(
            icon: Icons.refresh,
            tooltip: '重新扫描成员',
            onTap: () => setState(() {}),
          ),
          _HeaderAction(
            icon: Icons.remove,
            tooltip: '隐藏 Cargo',
            onTap: widget.onClose,
          ),
        ],
      ),
    );
  }

  Widget _buildRootRow() {
    return const SizedBox(
      height: IntelliJMetrics.treeRow,
      child: Row(
        children: [
          SizedBox(width: 8),
          Icon(Icons.keyboard_arrow_down, size: 12, color: IntelliJTheme.textSecondary),
          SizedBox(width: 4),
          Icon(Icons.inventory_2_outlined, size: 14, color: IntelliJTheme.syntaxKeyword),
          SizedBox(width: 5),
          Expanded(
            child: Text.rich(
              TextSpan(
                text: 'code-lite-x',
                style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.w600),
                children: [
                  TextSpan(
                    text: '  workspace',
                    style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10, fontWeight: FontWeight.normal),
                  ),
                ],
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildGroupRow({
    required String label,
    required bool isOpen,
    required VoidCallback onTap,
    String? trailing,
  }) {
    return InkWell(
      onTap: onTap,
      child: SizedBox(
        height: IntelliJMetrics.treeRow,
        child: Row(
          children: [
            const SizedBox(width: 26),
            Icon(
              isOpen ? Icons.keyboard_arrow_down : Icons.keyboard_arrow_right,
              size: 12,
              color: IntelliJTheme.textSecondary,
            ),
            const SizedBox(width: 4),
            const Icon(Icons.folder_outlined, size: 14, color: IntelliJTheme.accentYellow),
            const SizedBox(width: 5),
            Expanded(
              child: Text(
                label,
                style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12),
                overflow: TextOverflow.ellipsis,
              ),
            ),
            if (trailing != null)
              Text(trailing, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
            const SizedBox(width: 8),
          ],
        ),
      ),
    );
  }

  Widget _buildCommandRow(_CargoCommand cmd) {
    final isRunning = _running == cmd.name;
    final isLast = _last?.command.contains(' ${cmd.args.first} ') == true ||
        _last?.command.endsWith(' ${cmd.args.first}') == true;

    return Tooltip(
      message: cmd.hint,
      waitDuration: const Duration(milliseconds: 600),
      child: InkWell(
        onTap: _running == null ? () => _run(cmd) : null,
        child: Container(
          height: IntelliJMetrics.treeRow,
          color: isRunning ? IntelliJTheme.selectionBg : Colors.transparent,
          child: Row(
            children: [
              const SizedBox(width: 48),
              if (isRunning)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.6, color: IntelliJTheme.accentBlue),
                )
              else
                const Icon(Icons.play_arrow, size: 12, color: IntelliJTheme.textMuted),
              const SizedBox(width: 6),
              Expanded(
                child: Text(
                  cmd.name,
                  style: TextStyle(
                    color: isRunning ? IntelliJTheme.textHigh : IntelliJTheme.textPrimary,
                    fontSize: 12,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              if (isLast && !isRunning && _last != null) ...[
                Text(
                  _last!.success ? '通过' : '退出 ${_last!.exitCode}',
                  style: TextStyle(
                    color: _last!.success ? IntelliJTheme.gitGreen : IntelliJTheme.gitRed,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
                const SizedBox(width: 8),
              ],
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMemberRow(String name) {
    return SizedBox(
      height: IntelliJMetrics.treeRow,
      child: Row(
        children: [
          const SizedBox(width: 48),
          const Icon(Icons.circle_outlined, size: 11, color: IntelliJTheme.syntaxKeyword),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              name,
              style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          const SizedBox(width: 8),
        ],
      ),
    );
  }

  Widget _buildLastRun() {
    final last = _last;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: const BoxDecoration(
        border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: last == null
          ? const Text(
              '选一个命令运行,结果显示在这里。',
              style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10),
            )
          : Container(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              decoration: BoxDecoration(
                color: (last.success ? IntelliJTheme.gitGreen : IntelliJTheme.gitRed).withValues(alpha: 0.10),
                border: Border.all(
                  color: (last.success ? IntelliJTheme.gitGreen : IntelliJTheme.gitRed).withValues(alpha: 0.28),
                ),
                borderRadius: BorderRadius.circular(5),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Row(
                    children: [
                      Icon(
                        last.success ? Icons.check : Icons.close,
                        size: 12,
                        color: last.success ? IntelliJTheme.gitGreen : IntelliJTheme.gitRed,
                      ),
                      const SizedBox(width: 6),
                      Expanded(
                        child: Text(
                          last.command,
                          style: const TextStyle(
                            color: IntelliJTheme.textPrimary,
                            fontSize: 10,
                            fontFamily: 'monospace',
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                      Text(
                        '${(last.elapsed.inMilliseconds / 1000).toStringAsFixed(1)}s',
                        style: const TextStyle(
                          color: IntelliJTheme.textMuted,
                          fontSize: 10,
                          fontFamily: 'monospace',
                        ),
                      ),
                    ],
                  ),
                  if (last.tail.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      last.tail,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: const TextStyle(
                        color: IntelliJTheme.textMuted,
                        fontSize: 10,
                        fontFamily: 'monospace',
                      ),
                    ),
                  ],
                ],
              ),
            ),
    );
  }
}

class _HeaderAction extends StatelessWidget {
  const _HeaderAction({required this.icon, required this.tooltip, required this.onTap});

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: tooltip,
      waitDuration: const Duration(milliseconds: 500),
      child: InkWell(
        onTap: onTap,
        borderRadius: BorderRadius.circular(4),
        child: Padding(
          padding: const EdgeInsets.all(4),
          child: Icon(icon, size: 14, color: IntelliJTheme.textMuted),
        ),
      ),
    );
  }
}
