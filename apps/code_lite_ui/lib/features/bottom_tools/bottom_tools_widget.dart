import 'package:flutter/material.dart';
import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';

enum BottomToolTab { git, sqlite, codegraph, terminal }

class BottomToolsWidget extends StatefulWidget {
  final BottomToolTab activeTab;
  final ValueChanged<BottomToolTab> onSelectTab;
  final VoidCallback onRevertTask;
  final ApiClient? client;

  const BottomToolsWidget({
    super.key,
    required this.activeTab,
    required this.onSelectTab,
    required this.onRevertTask,
    this.client,
  });

  @override
  State<BottomToolsWidget> createState() => _BottomToolsWidgetState();
}

class _BottomToolsWidgetState extends State<BottomToolsWidget> {
  late final ApiClient _client;
  bool _reverted = false;
  final TextEditingController _terminalController = TextEditingController();
  final ScrollController _terminalScrollController = ScrollController();
  final TextEditingController _commitController = TextEditingController();
  final List<String> _terminalLines = [
    'CodeLiteX Embedded PTY (zsh) — Session 1 [Rust Core C-ABI Connected]',
    'dev@mac:~/rust/code-lite-x % ready',
  ];
  bool _isRunningCmd = false;
  String _currentBranch = 'main';
  List<Map<String, dynamic>> _gitChanges = [];
  bool _isCommitting = false;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? ApiClient();
    _refreshGit();
  }

  Future<void> _refreshGit() async {
    final status = await _client.getGitStatus();
    if (mounted) {
      setState(() {
        _currentBranch = status['branch'] as String? ?? 'main';
        final raw = status['changes'] as List<dynamic>? ?? [];
        _gitChanges = raw.map((c) => Map<String, dynamic>.from(c as Map)).toList();
      });
    }
  }

  Future<void> _stageFile(String path) async {
    await _client.gitStage(path);
    await _refreshGit();
  }

  Future<void> _unstageFile(String path) async {
    await _client.gitUnstage(path);
    await _refreshGit();
  }

  Future<void> _commitChanges() async {
    final msg = _commitController.text.trim();
    if (msg.isEmpty || _isCommitting) return;
    setState(() => _isCommitting = true);
    await _client.gitCommit(msg);
    _commitController.clear();
    await _refreshGit();
    if (mounted) setState(() => _isCommitting = false);
  }

  @override
  void dispose() {
    _terminalController.dispose();
    _terminalScrollController.dispose();
    _commitController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 220,
      decoration: const BoxDecoration(
        color: IntelliJTheme.panelBg,
        border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Column(
        children: [
          // Tab Header
          Container(
            height: 30,
            padding: const EdgeInsets.symmetric(horizontal: 8),
            decoration: const BoxDecoration(
              color: IntelliJTheme.subHeaderBg,
              border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  _buildTab('Git Log: HEAD', BottomToolTab.git),
                  _buildTab('SQLite State & Rollback', BottomToolTab.sqlite),
                  _buildTab('CodeGraph Explorer', BottomToolTab.codegraph),
                  _buildTab('Terminal', BottomToolTab.terminal),
                ],
              ),
            ),
          ),

          // Content Panels
          Expanded(
            child: switch (widget.activeTab) {
              BottomToolTab.git => _buildGitPanel(),
              BottomToolTab.sqlite => _buildSqlitePanel(),
              BottomToolTab.codegraph => _buildCodeGraphPanel(),
              BottomToolTab.terminal => _buildTerminalPanel(),
            },
          ),
        ],
      ),
    );
  }

  Widget _buildTab(String label, BottomToolTab tab) {
    final isActive = widget.activeTab == tab;

    return InkWell(
      onTap: () => widget.onSelectTab(tab),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        alignment: Alignment.center,
        decoration: BoxDecoration(
          color: isActive ? IntelliJTheme.panelBg : Colors.transparent,
          border: Border(
            top: BorderSide(
              color: isActive ? IntelliJTheme.accentBlue : Colors.transparent,
              width: 2,
            ),
          ),
        ),
        child: Text(
          label,
          style: TextStyle(
            color: isActive ? IntelliJTheme.textHigh : IntelliJTheme.textMuted,
            fontSize: 11,
            fontWeight: isActive ? FontWeight.w600 : FontWeight.normal,
          ),
        ),
      ),
    );
  }

  // 1. Git Version Control Panel
  Widget _buildGitPanel() {
    return Row(
      children: [
        // Branches list
        Container(
          width: 140,
          decoration: const BoxDecoration(
            border: Border(right: BorderSide(color: IntelliJTheme.borderSubtle)),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  const Expanded(
                    child: Text(
                      'BRANCH (HEAD)',
                      style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 11, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  InkWell(
                    onTap: _refreshGit,
                    child: const Padding(
                      padding: EdgeInsets.all(2),
                      child: Icon(Icons.refresh, size: 13, color: IntelliJTheme.textMuted),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 6),
              Row(
                children: [
                  const Icon(Icons.circle, size: 6, color: IntelliJTheme.gitGreen),
                  const SizedBox(width: 6),
                  Expanded(
                    child: Text(
                      _currentBranch,
                      style: const TextStyle(color: Color(0xFF6CB4F8), fontSize: 11, fontFamily: 'monospace', fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                '${_gitChanges.length} changed files',
                style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10),
              ),
            ],
          ),
        ),

        // Commit Message & Action Box
        Expanded(
          child: Padding(
            padding: const EdgeInsets.all(8),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  mainAxisAlignment: MainAxisAlignment.spaceBetween,
                  children: [
                    const Expanded(
                      child: Text(
                        'COMMIT CHANGES',
                        style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 11, fontWeight: FontWeight.bold),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    InkWell(
                      onTap: _isCommitting ? null : _commitChanges,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
                        decoration: BoxDecoration(
                          color: IntelliJTheme.gitGreen,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            if (_isCommitting)
                              const SizedBox(width: 10, height: 10, child: CircularProgressIndicator(strokeWidth: 1.5, color: Colors.white))
                            else
                              const Icon(Icons.check, size: 12, color: Colors.white),
                            const SizedBox(width: 4),
                            const Text('Commit', style: TextStyle(color: Colors.white, fontSize: 10.5, fontWeight: FontWeight.w600)),
                          ],
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 8),
                Expanded(
                  child: Container(
                    decoration: BoxDecoration(
                      color: IntelliJTheme.cardBg,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: IntelliJTheme.border),
                    ),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    child: TextField(
                      controller: _commitController,
                      maxLines: null,
                      style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 11, fontFamily: 'monospace'),
                      decoration: const InputDecoration(
                        hintText: 'Enter commit message (e.g. feat: update git engine)...',
                        hintStyle: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
                        border: InputBorder.none,
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),

        // Changed Files List
        Container(
          width: 210,
          decoration: const BoxDecoration(
            border: Border(left: BorderSide(color: IntelliJTheme.borderSubtle)),
          ),
          padding: const EdgeInsets.all(8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Expanded(
                    child: Text(
                      'Changed Files (${_gitChanges.length})',
                      style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 11, fontWeight: FontWeight.bold),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                  if (_gitChanges.isNotEmpty) ...[
                    const SizedBox(width: 4),
                    InkWell(
                      onTap: () async {
                        for (final c in _gitChanges) {
                          await _client.gitStage(c['path'] as String);
                        }
                        await _refreshGit();
                      },
                      child: const Text('Stage All', style: TextStyle(color: IntelliJTheme.accentBlue, fontSize: 10)),
                    ),
                  ],
                ],
              ),
              const SizedBox(height: 6),
              Expanded(
                child: _gitChanges.isEmpty
                    ? const Center(
                        child: Text(
                          '✓ Working tree clean',
                          style: TextStyle(color: IntelliJTheme.gitGreen, fontSize: 11),
                        ),
                      )
                    : ListView.builder(
                        itemCount: _gitChanges.length,
                        itemBuilder: (ctx, i) {
                          final c = _gitChanges[i];
                          final path = c['path'] as String? ?? '';
                          final isStaged = c['is_staged'] as bool? ?? false;
                          final status = c['status'] as String? ?? 'modified';

                          Color statusColor;
                          String badge;
                          switch (status) {
                            case 'added':
                              statusColor = IntelliJTheme.gitGreen;
                              badge = 'A';
                              break;
                            case 'deleted':
                              statusColor = IntelliJTheme.gitRed;
                              badge = 'D';
                              break;
                            case 'untracked':
                              statusColor = IntelliJTheme.syntaxType;
                              badge = '?';
                              break;
                            default:
                              statusColor = IntelliJTheme.gitBlue;
                              badge = 'M';
                          }

                          return Padding(
                            padding: const EdgeInsets.symmetric(vertical: 2),
                            child: Row(
                              children: [
                                InkWell(
                                  onTap: () => isStaged ? _unstageFile(path) : _stageFile(path),
                                  child: Icon(
                                    isStaged ? Icons.check_box : Icons.check_box_outline_blank,
                                    size: 14,
                                    color: isStaged ? IntelliJTheme.gitGreen : IntelliJTheme.textMuted,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                                  decoration: BoxDecoration(
                                    color: statusColor.withOpacity(0.15),
                                    borderRadius: BorderRadius.circular(2),
                                  ),
                                  child: Text(
                                    badge,
                                    style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.bold),
                                  ),
                                ),
                                const SizedBox(width: 6),
                                Expanded(
                                  child: Text(
                                    path,
                                    style: const TextStyle(
                                      color: IntelliJTheme.textPrimary,
                                      fontSize: 10.5,
                                      fontFamily: 'monospace',
                                    ),
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                              ],
                            ),
                          );
                        },
                      ),
              ),
            ],
          ),
        ),
      ],
    );
  }

  // 2. SQLite State & Rollback Panel
  Widget _buildSqlitePanel() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Row(
                children: [
                  Icon(Icons.circle, size: 8, color: IntelliJTheme.gitGreen),
                  SizedBox(width: 6),
                  Text('SQLite Operations Audit (.codelite/project.db)', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.bold)),
                ],
              ),
              ElevatedButton.icon(
                style: ElevatedButton.styleFrom(
                  backgroundColor: _reverted ? IntelliJTheme.gitGreen : IntelliJTheme.gitRed.withOpacity(0.2),
                  foregroundColor: _reverted ? Colors.white : const Color(0xFFF27474),
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                  elevation: 0,
                  side: BorderSide(color: _reverted ? IntelliJTheme.gitGreen : IntelliJTheme.gitRed.withOpacity(0.4)),
                ),
                icon: Icon(_reverted ? Icons.check : Icons.undo, size: 14),
                label: Text(
                  _reverted ? 'Reverted Task #104 (Files Restored)' : 'Undo Task #104 (Revert All Agent Edits)',
                  style: const TextStyle(fontSize: 11),
                ),
                onPressed: () {
                  setState(() => _reverted = true);
                  widget.onRevertTask();
                },
              ),
            ],
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              children: [
                _buildOpCard(
                  id: '#op-201',
                  file: 'crates/code-lite-storage/src/op_store.rs',
                  status: _reverted ? 'REVERTED' : 'APPLIED',
                  statusColor: _reverted ? IntelliJTheme.gitYellow : IntelliJTheme.gitGreen,
                  diff: 'Unified Patch (+42 lines revert/revert_task)',
                ),
                const SizedBox(height: 6),
                _buildOpCard(
                  id: '#op-200',
                  file: 'crates/code-lite-storage/src/graph_store.rs',
                  status: _reverted ? 'REVERTED' : 'APPLIED',
                  statusColor: _reverted ? IntelliJTheme.gitYellow : IntelliJTheme.gitGreen,
                  diff: 'CallGraph query index insertion',
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildOpCard({
    required String id,
    required String file,
    required String status,
    required Color statusColor,
    required String diff,
  }) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: IntelliJTheme.cardBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: IntelliJTheme.border),
      ),
      child: Row(
        mainAxisAlignment: MainAxisAlignment.spaceBetween,
        children: [
          Row(
            children: [
              Text(id, style: const TextStyle(color: Color(0xFF6CB4F8), fontSize: 11, fontFamily: 'monospace')),
              const SizedBox(width: 8),
              Text(file, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 11, fontWeight: FontWeight.w600)),
              const SizedBox(width: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                decoration: BoxDecoration(
                  color: statusColor.withOpacity(0.15),
                  borderRadius: BorderRadius.circular(3),
                ),
                child: Text(status, style: TextStyle(color: statusColor, fontSize: 9, fontWeight: FontWeight.bold)),
              ),
            ],
          ),
          Text(diff, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11, fontFamily: 'monospace')),
        ],
      ),
    );
  }

  // 3. CodeGraph Explorer Panel
  Widget _buildCodeGraphPanel() {
    return Padding(
      padding: const EdgeInsets.all(12),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text('CodeGraph Dependency & Call Topology', style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.bold)),
          const SizedBox(height: 12),
          Row(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              _buildGraphNode('CALLER', 'revert_task()', 'op_store.rs:188', IntelliJTheme.gitGreen),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('─────▶', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 14)),
              ),
              _buildGraphNode('TARGET', 'revert()', 'op_store.rs:136', IntelliJTheme.accentBlue),
              const Padding(
                padding: EdgeInsets.symmetric(horizontal: 12),
                child: Text('─────▶', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 14)),
              ),
              _buildGraphNode('CALLEE', 'fs::write()', 'std::fs', IntelliJTheme.syntaxType),
            ],
          ),
        ],
      ),
    );
  }

  Widget _buildGraphNode(String role, String symbol, String loc, Color color) {
    return Container(
      width: 140,
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: IntelliJTheme.cardBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: color.withOpacity(0.7)),
      ),
      child: Column(
        children: [
          Text(role, style: TextStyle(color: color, fontSize: 9, fontWeight: FontWeight.bold)),
          const SizedBox(height: 4),
          Text(symbol, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12, fontWeight: FontWeight.bold, fontFamily: 'monospace')),
          const SizedBox(height: 2),
          Text(loc, style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
        ],
      ),
    );
  }

  Future<void> _executeCommand(String input) async {
    final cmdLine = input.trim();
    if (cmdLine.isEmpty) return;
    _terminalController.clear();

    setState(() {
      _terminalLines.add('dev@mac:~/rust/code-lite-x % $cmdLine');
      _isRunningCmd = true;
    });

    if (cmdLine == 'clear') {
      setState(() {
        _terminalLines.clear();
        _terminalLines.add('CodeLiteX Embedded PTY (zsh) — Session 1');
        _isRunningCmd = false;
      });
      return;
    }

    if (widget.client != null) {
      final parts = cmdLine.split(RegExp(r'\s+'));
      final bin = parts.first;
      final args = parts.skip(1).toList();

      final res = await widget.client!.terminalExec(bin, args);
      setState(() {
        _isRunningCmd = false;
        if (res['status'] == 'ok') {
          final stdout = (res['stdout'] as String?)?.trim();
          final stderr = (res['stderr'] as String?)?.trim();
          final code = (res['exit_code'] as int?) ?? 0;
          if (stdout != null && stdout.isNotEmpty) {
            _terminalLines.addAll(stdout.split('\n'));
          }
          if (stderr != null && stderr.isNotEmpty) {
            _terminalLines.addAll(stderr.split('\n'));
          }
          if (code != 0) {
            _terminalLines.add('[Process exited with code $code]');
          }
        } else {
          _terminalLines.add('Error: ${res['error'] ?? 'Execution failed'}');
        }
      });
    } else {
      setState(() {
        _isRunningCmd = false;
        _terminalLines.add('[Executed: $cmdLine]');
      });
    }

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_terminalScrollController.hasClients) {
        _terminalScrollController.jumpTo(_terminalScrollController.position.maxScrollExtent);
      }
    });
  }

  // 4. Terminal Panel (Interactive PTY execution)
  Widget _buildTerminalPanel() {
    return Container(
      color: IntelliJTheme.cardBg,
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          // Quick Action Bar
          Row(
            children: [
              const Text('Quick Actions: ', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 10)),
              _buildQuickChip('cargo test', () => _executeCommand('cargo test --offline --workspace')),
              const SizedBox(width: 4),
              _buildQuickChip('git status', () => _executeCommand('git status -s')),
              const SizedBox(width: 4),
              _buildQuickChip('ls -la', () => _executeCommand('ls -la')),
              const SizedBox(width: 4),
              _buildQuickChip('clear', () => _executeCommand('clear')),
              const Spacer(),
              if (_isRunningCmd)
                const SizedBox(
                  width: 12,
                  height: 12,
                  child: CircularProgressIndicator(strokeWidth: 1.5, color: IntelliJTheme.accentBlue),
                ),
            ],
          ),
          const SizedBox(height: 4),
          const Divider(height: 1, color: IntelliJTheme.borderSubtle),
          const SizedBox(height: 4),

          // Output Console Log
          Expanded(
            child: ListView.builder(
              controller: _terminalScrollController,
              itemCount: _terminalLines.length,
              itemBuilder: (context, index) {
                final line = _terminalLines[index];
                final isPrompt = line.startsWith('dev@mac:');
                final isSuccess = line.contains('ok') || line.contains('passed');
                final isError = line.contains('Error') || line.contains('FAILED') || line.contains('exit');

                final color = isPrompt
                    ? IntelliJTheme.gitGreen
                    : isSuccess
                        ? IntelliJTheme.gitGreen
                        : isError
                            ? IntelliJTheme.gitRed
                            : IntelliJTheme.textPrimary;

                return Padding(
                  padding: const EdgeInsets.symmetric(vertical: 1),
                  child: Text(
                    line,
                    style: TextStyle(
                      color: color,
                      fontSize: 11,
                      fontFamily: 'monospace',
                      fontWeight: isPrompt ? FontWeight.bold : FontWeight.normal,
                    ),
                  ),
                );
              },
            ),
          ),

          // Interactive Command Input Line
          Container(
            height: 28,
            margin: const EdgeInsets.only(top: 4),
            decoration: BoxDecoration(
              color: IntelliJTheme.editorBg,
              borderRadius: BorderRadius.circular(3),
              border: Border.all(color: IntelliJTheme.borderSubtle),
            ),
            child: Row(
              children: [
                const Padding(
                  padding: EdgeInsets.symmetric(horizontal: 6),
                  child: Text(
                    '\$',
                    style: TextStyle(
                      color: IntelliJTheme.gitGreen,
                      fontSize: 12,
                      fontWeight: FontWeight.bold,
                      fontFamily: 'monospace',
                    ),
                  ),
                ),
                Expanded(
                  child: TextField(
                    controller: _terminalController,
                    style: const TextStyle(
                      color: IntelliJTheme.textPrimary,
                      fontSize: 11,
                      fontFamily: 'monospace',
                    ),
                    decoration: const InputDecoration(
                      hintText: 'Type shell command (e.g. echo hello, cargo test)...',
                      hintStyle: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
                      border: InputBorder.none,
                      isDense: true,
                      contentPadding: EdgeInsets.symmetric(vertical: 6),
                    ),
                    onSubmitted: _executeCommand,
                  ),
                ),
                IconButton(
                  icon: const Icon(Icons.arrow_forward, size: 14, color: IntelliJTheme.accentBlue),
                  padding: const EdgeInsets.symmetric(horizontal: 6),
                  constraints: const BoxConstraints(),
                  onPressed: () => _executeCommand(_terminalController.text),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildQuickChip(String label, VoidCallback onTap) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(3),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
        decoration: BoxDecoration(
          color: IntelliJTheme.subHeaderBg,
          borderRadius: BorderRadius.circular(3),
          border: Border.all(color: IntelliJTheme.borderSubtle),
        ),
        child: Text(
          label,
          style: const TextStyle(
            color: IntelliJTheme.textSecondary,
            fontSize: 10,
            fontFamily: 'monospace',
          ),
        ),
      ),
    );
  }
}
