import 'dart:async';
import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';

class AiAssistantPanel extends StatefulWidget {
  final String activeFile;
  final VoidCallback onClose;
  final ApiClient? client;

  const AiAssistantPanel({
    super.key,
    required this.activeFile,
    required this.onClose,
    this.client,
  });

  @override
  State<AiAssistantPanel> createState() => _AiAssistantPanelState();
}

class _AiChatMessage {
  final String sender;
  String text;
  final bool isUser;
  final String? badge;
  String? thought;
  bool isThinkingExpanded;
  bool isStreaming;

  _AiChatMessage({
    required this.sender,
    required this.text,
    required this.isUser,
    this.badge,
    this.thought,
    this.isThinkingExpanded = false,
    this.isStreaming = false,
  });
}

class _AiAssistantPanelState extends State<AiAssistantPanel> {
  late final ApiClient _client;
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  final List<_AiChatMessage> _messages = [];
  final String _sessionId = 'codelite-chat-main';
  bool _isLoading = false;

  Map<String, dynamic>? _currentPlan;
  List<dynamic> _pendingApprovals = [];
  String? _diffContent;
  int _diffOperationsCount = 0;

  Map<String, dynamic>? _contextInsights;
  bool _showInsights = false;
  List<dynamic> _skillsList = [];
  List<dynamic> _mcpToolsList = [];

  Timer? _insightsDebounce;

  @override
  void initState() {
    super.initState();
    _client = widget.client ?? ApiClient();
    _loadPersistedMessages();
    _refreshApprovals();
    // Context Insights 默认折叠,不在挂载时拉取 —— 见 _scheduleInsightsRefresh。
  }

  @override
  void didUpdateWidget(AiAssistantPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.activeFile != widget.activeFile) {
      _scheduleInsightsRefresh();
    }
  }

  /// Context Insights 要走三次 FFI 往返(buildTaskPrompt + listSkills + listMcpTools),
  /// 其中 buildTaskPrompt 还要拼指令文件全文。切文件是编辑器里最高频的操作之一,
  /// 所以这里只在该区域真的展开时才拉,并且防抖 —— 快速连续切文件只发最后一次。
  void _scheduleInsightsRefresh() {
    _insightsDebounce?.cancel();
    if (!_showInsights) return;
    _insightsDebounce = Timer(const Duration(milliseconds: 400), () {
      if (mounted) _refreshContextInsights();
    });
  }

  Future<void> _refreshContextInsights() async {
    try {
      final promptRes = await _client.buildTaskPrompt(
        'active context query',
        focusFile: widget.activeFile.isNotEmpty ? widget.activeFile : null,
      );
      final skills = await _client.listSkills();
      final mcp = await _client.listMcpTools();
      if (mounted) {
        setState(() {
          if (promptRes['status'] == 'ok' && promptRes['insights'] != null) {
            _contextInsights = promptRes['insights'] as Map<String, dynamic>?;
          }
          _skillsList = skills;
          _mcpToolsList = mcp;
        });
      }
    } catch (_) {}
  }

  Future<void> _loadPersistedMessages() async {
    final msgs = await _client.listMessages(_sessionId);
    if (mounted && msgs.isNotEmpty) {
      setState(() {
        _messages.clear();
        for (final m in msgs) {
          final isUser = m['role'] == 'user';
          _messages.add(_AiChatMessage(
            sender: isUser ? 'User' : 'CodeLite Assistant',
            text: m['content'] as String? ?? '',
            isUser: isUser,
            thought: m['thought'] as String?,
            isThinkingExpanded: false,
            badge: m['plan_id'] != null ? 'Plan: ${m['plan_id']}' : null,
          ));
        }
      });
    } else {
      if (mounted && _messages.isEmpty) {
        setState(() {
          _messages.add(
            _AiChatMessage(
              sender: 'CodeLite Assistant',
              text: 'CodeLiteX AI Assistant ready. DeepSeek/OpenAI streaming & CodeGraph context enabled.',
              isUser: false,
              thought: 'Initialized CodeGraph AST index, Three-Tier gateway, and SQLite persistence.',
              badge: '✓ Ready',
            ),
          );
        });
      }
    }
  }

  Future<void> _clearChat() async {
    await _client.clearMessages(_sessionId);
    if (mounted) {
      setState(() {
        _messages.clear();
        _currentPlan = null;
      });
    }
  }

  @override
  void dispose() {
    _insightsDebounce?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  Future<void> _refreshApprovals() async {
    final approvals = await _client.agentGetPendingApprovals();
    if (mounted) {
      setState(() {
        _pendingApprovals = approvals;
      });
    }
  }

  Future<void> _refreshDiff() async {
    final res = await _client.agentGetDiffReview();
    if (mounted && res['status'] == 'ok') {
      setState(() {
        _diffContent = res['unified_diff'] as String? ?? '';
        _diffOperationsCount = res['operations_count'] as int? ?? 0;
      });
    }
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scrollController.hasClients) {
        _scrollController.animateTo(
          _scrollController.position.maxScrollExtent,
          duration: const Duration(milliseconds: 80),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _sendMessage() async {
    final text = _controller.text.trim();
    if (text.isEmpty || _isLoading) return;

    _controller.clear();
    final userMsg = _AiChatMessage(sender: 'User', text: text, isUser: true);
    final assistantMsg = _AiChatMessage(
      sender: 'CodeLite Assistant',
      text: '',
      isUser: false,
      thought: '',
      isThinkingExpanded: true,
      isStreaming: true,
    );

    setState(() {
      _messages.add(userMsg);
      _messages.add(assistantMsg);
      _isLoading = true;
    });

    _scrollToBottom();

    // Start streaming from Rust LLM Engine
    final startRes = await _client.sendPromptStream(_sessionId, text);
    if (startRes['status'] == 'started') {
      bool streamDone = false;
      int pollAttempts = 0;

      while (!streamDone && pollAttempts < 300 && mounted) {
        await Future.delayed(const Duration(milliseconds: 25));
        pollAttempts++;

        final events = await _client.pollStreamEvents(_sessionId);
        for (final ev in events) {
          final type = ev['event_type'] as String?;
          final chunk = ev['text'] as String? ?? '';

          if (type == 'thinking') {
            assistantMsg.thought = (assistantMsg.thought ?? '') + chunk;
          } else if (type == 'content') {
            assistantMsg.text += chunk;
          } else if (type == 'plan_ready') {
            final planJson = ev['plan_json'] as String?;
            if (planJson != null) {
              try {
                _currentPlan = jsonDecode(planJson) as Map<String, dynamic>;
              } catch (_) {}
            }
          } else if (type == 'done') {
            streamDone = true;
            assistantMsg.isStreaming = false;
            assistantMsg.isThinkingExpanded = false;
            break;
          } else if (type == 'error') {
            streamDone = true;
            assistantMsg.isStreaming = false;
            assistantMsg.text += '\n[Error: $chunk]';
            break;
          }
        }
        if (mounted) setState(() {});
        _scrollToBottom();
      }
    } else {
      // Fallback
      final res = await _client.sendAgentPrompt(text);
      assistantMsg.text = res['reply'] as String? ?? 'Agent processed prompt.';
      assistantMsg.isStreaming = false;
    }

    if (mounted) {
      setState(() {
        _isLoading = false;
      });
      await _refreshApprovals();
      await _refreshDiff();
      _scrollToBottom();
    }
  }

  Future<void> _executeNextStep() async {
    if (_currentPlan == null) return;
    final planId = _currentPlan!['id'] as String;

    setState(() {
      _isLoading = true;
    });

    final res = await _client.agentExecuteNextStep(planId);
    await _refreshApprovals();
    await _refreshDiff();

    if (mounted) {
      setState(() {
        _isLoading = false;
        if (res['status'] == 'ok') {
          if (res.containsKey('plan')) {
            _currentPlan = res['plan'] as Map<String, dynamic>;
          }
          final execResult = res['result'] as Map<String, dynamic>?;
          final type = execResult?['type'] as String?;

          if (type == 'SuspendedForApproval') {
            final payload = execResult!['payload'] as Map<String, dynamic>;
            _messages.add(
              _AiChatMessage(
                sender: 'Security Gateway',
                text: '【高危操作挂起】工具 ${payload['tool_name']} 属于 Critical 风险级别，已生成请求 ${payload['request_id']}，等待您的审批。',
                isUser: false,
                badge: '⚠ Hard Suspend',
              ),
            );
          } else if (type == 'Completed') {
            final payload = execResult!['payload'] as Map<String, dynamic>;
            _messages.add(
              _AiChatMessage(
                sender: 'CodeLite Agent',
                text: '步骤 ${payload['step_id']} 执行成功。\n${payload['output']}',
                isUser: false,
                badge: payload['op_id'] != null ? 'OpID: ${payload['op_id']} (Reversible)' : null,
              ),
            );
          } else if (type == 'AllCompleted') {
            _messages.add(
              _AiChatMessage(
                sender: 'CodeLite Agent',
                text: '🎉 整个计划已顺利完成并通过验证！',
                isUser: false,
                badge: '100% Completed',
              ),
            );
          } else if (type == 'FailedAndRolledBack') {
            final payload = execResult!['payload'] as Map<String, dynamic>;
            _messages.add(
              _AiChatMessage(
                sender: 'Cognitive Loop',
                text: '❌ 自愈重试失败已自动回滚：${payload['reason']}（恢复了 ${payload['rolled_back_count']} 个操作）',
                isUser: false,
                badge: 'Atomic Rollback',
              ),
            );
          }
        }
      });
    }
  }

  Future<void> _approveStep(String requestId, bool approved) async {
    setState(() => _isLoading = true);
    await _client.agentApproveStep(requestId, approved);
    await _refreshApprovals();
    setState(() => _isLoading = false);

    if (approved && _currentPlan != null) {
      await _executeNextStep();
    }
  }

  void _showDiffReviewDialog() {
    _refreshDiff();
    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: Row(
          children: [
            const Icon(Icons.difference, size: 16, color: IntelliJTheme.accentBlue),
            const SizedBox(width: 8),
            Text(
              'Session Diff Review ($_diffOperationsCount Operations)',
              style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 13),
            ),
          ],
        ),
        content: SizedBox(
          width: 550,
          height: 380,
          child: _diffContent == null || _diffContent!.trim().isEmpty
              ? const Center(
                  child: Text(
                    'No active diff in this session.',
                    style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 12),
                  ),
                )
              : Container(
                  padding: const EdgeInsets.all(10),
                  decoration: BoxDecoration(
                    color: IntelliJTheme.editorBg,
                    borderRadius: BorderRadius.circular(4),
                    border: Border.all(color: IntelliJTheme.border),
                  ),
                  child: SingleChildScrollView(
                    child: Text(
                      _diffContent!,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 11,
                        color: IntelliJTheme.textPrimary,
                      ),
                    ),
                  ),
                ),
        ),
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final res = await _client.revertTask('default-session');
              if (res) {
                await _refreshDiff();
                if (mounted) {
                  ScaffoldMessenger.of(context).showSnackBar(
                    const SnackBar(content: Text('Workspace restored to session start!')),
                  );
                }
              }
            },
            child: const Text('Restore Session Start', style: TextStyle(color: IntelliJTheme.gitRed, fontSize: 12)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: IntelliJTheme.accentBlue),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close', style: TextStyle(color: Colors.white, fontSize: 12)),
          ),
        ],
      ),
    );
  }

  Future<void> _rollbackStep(String stepId) async {
    if (_currentPlan == null) return;
    final planId = _currentPlan!['id'] as String;
    setState(() => _isLoading = true);
    final res = await _client.agentRollbackStep(planId, stepId);
    setState(() => _isLoading = false);

    if (res['status'] == 'ok' && res['rolled_back'] == true) {
      setState(() {
        if (res['plan'] != null && res['plan'] is Map<String, dynamic>) {
          _currentPlan = res['plan'] as Map<String, dynamic>;
        } else {
          final steps = (_currentPlan!['steps'] as List<dynamic>?) ?? [];
          for (final s in steps) {
            if (s is Map<String, dynamic> && s['id'] == stepId) {
              s['status'] = 'rolled_back';
            }
          }
        }
        _messages.add(
          _AiChatMessage(
            sender: 'ToolRuntime',
            text: '单步已精准回滚：步骤 $stepId 的操作已原子逆向撤销。',
            isUser: false,
            badge: 'Step Rollback',
          ),
        );
      });
      _refreshDiff();
    } else {
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('Rollback failed: ${res['error'] ?? 'Unknown error'}')),
        );
      }
    }
  }

  void _showMultiFileReviewDialog() {
    if (_currentPlan == null) return;
    final steps = (_currentPlan!['steps'] as List<dynamic>?) ?? [];
    final fileSteps = <Map<String, dynamic>>[];
    for (final s in steps) {
      if (s is Map<String, dynamic>) {
        fileSteps.add(s);
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        backgroundColor: IntelliJTheme.panelBg,
        title: const Row(
          children: [
            Icon(Icons.account_tree, size: 16, color: IntelliJTheme.accentYellow),
            SizedBox(width: 8),
            Text(
              'Multi-File Plan & Worktree Review',
              style: TextStyle(color: IntelliJTheme.textHigh, fontSize: 13),
            ),
          ],
        ),
        content: SizedBox(
          width: 550,
          height: 380,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              const Text(
                'Topological Execution Order (Dependency Graph):',
                style: TextStyle(color: IntelliJTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 8),
              Expanded(
                child: ListView.separated(
                  itemCount: fileSteps.length,
                  separatorBuilder: (_, __) => const SizedBox(height: 6),
                  itemBuilder: (_, i) {
                    final st = fileSteps[i];
                    final args = st['args'] as Map<String, dynamic>? ?? {};
                    final path = args['path'] as String? ?? 'workspace';
                    final tool = st['tool_name'] as String? ?? '';
                    return Container(
                      padding: const EdgeInsets.all(8),
                      decoration: BoxDecoration(
                        color: IntelliJTheme.cardBg,
                        borderRadius: BorderRadius.circular(4),
                        border: Border.all(color: IntelliJTheme.border),
                      ),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Container(
                                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                                decoration: BoxDecoration(
                                  color: IntelliJTheme.accentBlue.withOpacity(0.2),
                                  borderRadius: BorderRadius.circular(2),
                                ),
                                child: Text(
                                  '#${i + 1} $tool',
                                  style: const TextStyle(color: IntelliJTheme.accentBlue, fontSize: 10, fontWeight: FontWeight.bold),
                                ),
                              ),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  path,
                                  style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 11, fontFamily: 'monospace'),
                                  overflow: TextOverflow.ellipsis,
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            st['description'] as String? ?? '',
                            style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 10),
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
        actions: [
          TextButton(
            onPressed: () async {
              Navigator.of(ctx).pop();
              final taskId = _currentPlan?['task_id'] as String? ?? 'task-wt';
              final res = await _client.worktreeCreate(taskId);
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  SnackBar(content: Text(res['status'] == 'ok' ? 'Worktree sandbox initialized: agent/$taskId' : 'Worktree error')),
                );
              }
            },
            child: const Text('Create Worktree Sandbox', style: TextStyle(color: IntelliJTheme.accentBlue, fontSize: 11)),
          ),
          ElevatedButton(
            style: ElevatedButton.styleFrom(backgroundColor: IntelliJTheme.accentBlue),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Close', style: TextStyle(color: Colors.white, fontSize: 11)),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 310,
      decoration: const BoxDecoration(
        color: IntelliJTheme.panelBg,
        border: Border(left: BorderSide(color: IntelliJTheme.borderSubtle)),
      ),
      child: Column(
        children: [
          // Header
          Container(
            height: 34,
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: const BoxDecoration(
              border: Border(bottom: BorderSide(color: IntelliJTheme.borderSubtle)),
            ),
            child: Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                const Expanded(
                  child: Row(
                    children: [
                      Icon(Icons.auto_awesome, size: 14, color: Color(0xFF6CB4F8)),
                      SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          'CodeLite AI Assistant',
                          style: TextStyle(
                            color: IntelliJTheme.textHigh,
                            fontSize: 12,
                            fontWeight: FontWeight.bold,
                          ),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                Row(
                  children: [
                    IconButton(
                      icon: const Icon(Icons.delete_outline, size: 14, color: IntelliJTheme.textMuted),
                      tooltip: 'Clear Chat History',
                      onPressed: _clearChat,
                      splashRadius: 12,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.difference, size: 14, color: IntelliJTheme.gitBlue),
                      tooltip: 'Diff Review',
                      onPressed: _showDiffReviewDialog,
                      splashRadius: 12,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                    ),
                    const SizedBox(width: 4),
                    IconButton(
                      icon: const Icon(Icons.close, size: 14, color: IntelliJTheme.textMuted),
                      onPressed: widget.onClose,
                      splashRadius: 12,
                      padding: EdgeInsets.zero,
                      constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                    ),
                  ],
                ),
              ],
            ),
          ),

          // Content body
          Expanded(
            child: ListView(
              controller: _scrollController,
              padding: const EdgeInsets.all(10),
              children: [
                // Context Engine Insights Card (Phase 10)
                _buildContextInsightsCard(),
                const SizedBox(height: 10),

                // Context Chip Card
                Container(
                  padding: const EdgeInsets.all(8),
                  decoration: BoxDecoration(
                    color: IntelliJTheme.cardBg,
                    borderRadius: BorderRadius.circular(6),
                    border: Border.all(color: IntelliJTheme.border),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const Text(
                        'GATEWAY: TOOL RUNTIME (3-TIER RISKS)',
                        style: TextStyle(
                          color: IntelliJTheme.textMuted,
                          fontSize: 9,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 6),
                      Wrap(
                        spacing: 4,
                        runSpacing: 4,
                        children: [
                          _buildChip('LOW: Auto-read', const Color(0xFF7FD98F)),
                          _buildChip('MED: Undo-patch', const Color(0xFF6CB4F8)),
                          _buildChip('CRITICAL: Gated', const Color(0xFFDB5860)),
                        ],
                      ),
                    ],
                  ),
                ),

                const SizedBox(height: 10),

                // Pending Approvals Card (if any)
                if (_pendingApprovals.isNotEmpty) ...[
                  _buildPendingApprovalsCard(),
                  const SizedBox(height: 10),
                ],

                // Active Plan Tree Card (if any)
                if (_currentPlan != null) ...[
                  _buildPlanTreeCard(),
                  const SizedBox(height: 10),
                ],

                // Chat Messages
                for (final msg in _messages) ...[
                  _buildMessageBubble(msg),
                  const SizedBox(height: 10),
                ],

                if (_isLoading)
                  Container(
                    padding: const EdgeInsets.all(8),
                    alignment: Alignment.centerLeft,
                    child: const Row(
                      children: [
                        SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(strokeWidth: 2, color: IntelliJTheme.accentBlue),
                        ),
                        SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Agent executing via ToolRuntime...',
                            style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),

          // Chat Input bar
          Container(
            padding: const EdgeInsets.all(8),
            decoration: const BoxDecoration(
              color: IntelliJTheme.subHeaderBg,
              border: Border(top: BorderSide(color: IntelliJTheme.borderSubtle)),
            ),
            child: Row(
              children: [
                Expanded(
                  child: Container(
                    height: 30,
                    padding: const EdgeInsets.symmetric(horizontal: 8),
                    decoration: BoxDecoration(
                      color: IntelliJTheme.cardBg,
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: IntelliJTheme.border),
                    ),
                    alignment: Alignment.centerLeft,
                    child: TextField(
                      controller: _controller,
                      style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12),
                      decoration: const InputDecoration(
                        isDense: true,
                        contentPadding: EdgeInsets.zero,
                        hintText: 'Ask Agent or command ToolRuntime...',
                        hintStyle: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
                        border: InputBorder.none,
                      ),
                      onSubmitted: (_) => _sendMessage(),
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                IconButton(
                  icon: const Icon(Icons.send, size: 16, color: IntelliJTheme.accentBlue),
                  onPressed: _sendMessage,
                  splashRadius: 14,
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(minWidth: 24, minHeight: 24),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildPendingApprovalsCard() {
    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: const Color(0xFF3B2023),
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: IntelliJTheme.gitRed),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.warning_amber_rounded, size: 14, color: IntelliJTheme.gitRed),
              SizedBox(width: 6),
              Expanded(
                child: Text(
                  'APPROVAL REQUIRED (CRITICAL RISK)',
                  style: TextStyle(
                    color: IntelliJTheme.gitRed,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (final req in _pendingApprovals) ...[
            Text(
              '${req['tool_name']}: ${req['args_json']}',
              style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 11, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 6),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                OutlinedButton(
                  style: OutlinedButton.styleFrom(
                    foregroundColor: IntelliJTheme.gitRed,
                    side: const BorderSide(color: IntelliJTheme.gitRed),
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
                    minimumSize: const Size(50, 24),
                  ),
                  onPressed: () => _approveStep(req['id'] as String, false),
                  child: const Text('Reject', style: TextStyle(fontSize: 11)),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  style: ElevatedButton.styleFrom(
                    backgroundColor: IntelliJTheme.gitGreen,
                    foregroundColor: Colors.white,
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
                    minimumSize: const Size(60, 24),
                  ),
                  onPressed: () => _approveStep(req['id'] as String, true),
                  child: const Text('Approve', style: TextStyle(fontSize: 11)),
                ),
              ],
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildPlanTreeCard() {
    final steps = (_currentPlan!['steps'] as List<dynamic>?) ?? [];
    final currentIdx = _currentPlan!['current_step_index'] as int? ?? 0;
    final isCompleted = _currentPlan!['is_completed'] as bool? ?? false;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: IntelliJTheme.cardBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: IntelliJTheme.accentBlue.withOpacity(0.4)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              Expanded(
                child: Text(
                  'EXECUTION PLAN (${steps.length} STEPS)',
                  style: const TextStyle(
                    color: IntelliJTheme.accentBlue,
                    fontSize: 10,
                    fontWeight: FontWeight.bold,
                  ),
                  overflow: TextOverflow.ellipsis,
                ),
              ),
              const SizedBox(width: 4),
              Row(
                mainAxisSize: MainAxisSize.min,
                children: [
                  InkWell(
                    onTap: _showMultiFileReviewDialog,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 2),
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: IntelliJTheme.accentYellow.withOpacity(0.2),
                        borderRadius: BorderRadius.circular(3),
                        border: Border.all(color: IntelliJTheme.accentYellow.withOpacity(0.5)),
                      ),
                      child: const Text('Review', style: TextStyle(color: IntelliJTheme.accentYellow, fontSize: 9)),
                    ),
                  ),
                  if (!isCompleted)
                    InkWell(
                      onTap: _isLoading ? null : _executeNextStep,
                      child: Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                        decoration: BoxDecoration(
                          color: IntelliJTheme.accentBlue,
                          borderRadius: BorderRadius.circular(3),
                        ),
                        child: const Text('Step >', style: TextStyle(color: Colors.white, fontSize: 10)),
                      ),
                    ),
                ],
              ),
            ],
          ),
          const SizedBox(height: 6),
          for (int i = 0; i < steps.length; i++) ...[
            _buildStepRow(steps[i] as Map<String, dynamic>, i, currentIdx),
            if (i < steps.length - 1) const SizedBox(height: 4),
          ],
        ],
      ),
    );
  }

  Widget _buildStepRow(Map<String, dynamic> step, int index, int currentIndex) {
    final status = step['status'] as String? ?? 'pending';
    final risk = (step['risk_level'] as String? ?? 'low').toLowerCase();

    IconData icon;
    Color iconColor;

    switch (status) {
      case 'success':
      case 'Completed':
        icon = Icons.check_circle;
        iconColor = IntelliJTheme.gitGreen;
        break;
      case 'running':
      case 'Running':
        icon = Icons.sync;
        iconColor = IntelliJTheme.accentBlue;
        break;
      case 'awaiting_approval':
      case 'SuspendedForApproval':
        icon = Icons.warning_rounded;
        iconColor = IntelliJTheme.accentYellow;
        break;
      case 'failed':
      case 'Failed':
      case 'rolled_back':
        icon = Icons.error_rounded;
        iconColor = IntelliJTheme.gitRed;
        break;
      default:
        icon = Icons.radio_button_unchecked;
        iconColor = IntelliJTheme.textMuted;
    }

    Color riskColor;
    switch (risk) {
      case 'critical':
        riskColor = IntelliJTheme.gitRed;
        break;
      case 'medium':
        riskColor = IntelliJTheme.accentBlue;
        break;
      default:
        riskColor = IntelliJTheme.gitGreen;
    }

    final isDone = status == 'success' || status == 'Completed';

    return Row(
      children: [
        Icon(icon, size: 12, color: iconColor),
        const SizedBox(width: 6),
        Expanded(
          child: Text(
            '${step['description']}',
            style: TextStyle(
              color: index == currentIndex ? IntelliJTheme.textHigh : IntelliJTheme.textPrimary,
              fontSize: 11,
              fontWeight: index == currentIndex ? FontWeight.w600 : FontWeight.normal,
            ),
            overflow: TextOverflow.ellipsis,
          ),
        ),
        const SizedBox(width: 4),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
          decoration: BoxDecoration(
            color: riskColor.withOpacity(0.15),
            borderRadius: BorderRadius.circular(2),
          ),
          child: Text(
            risk.toUpperCase(),
            style: TextStyle(color: riskColor, fontSize: 8, fontWeight: FontWeight.bold),
          ),
        ),
        if (isDone && step['id'] != null) ...[
          const SizedBox(width: 4),
          InkWell(
            onTap: _isLoading ? null : () => _rollbackStep(step['id'] as String),
            child: Container(
              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
              decoration: BoxDecoration(
                color: IntelliJTheme.gitRed.withOpacity(0.15),
                borderRadius: BorderRadius.circular(2),
                border: Border.all(color: IntelliJTheme.gitRed.withOpacity(0.4)),
              ),
              child: const Text(
                'REVERT',
                style: TextStyle(color: IntelliJTheme.gitRed, fontSize: 8, fontWeight: FontWeight.bold),
              ),
            ),
          ),
        ],
      ],
    );
  }

  Widget _buildMessageBubble(_AiChatMessage msg) {
    if (msg.isUser) {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: IntelliJTheme.accentBlue.withOpacity(0.12),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: IntelliJTheme.accentBlue.withOpacity(0.3)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            const Text(
              'User',
              style: TextStyle(color: Color(0xFF6CB4F8), fontSize: 10, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 4),
            Text(msg.text, style: const TextStyle(color: IntelliJTheme.textHigh, fontSize: 12)),
          ],
        ),
      );
    } else {
      return Container(
        padding: const EdgeInsets.all(10),
        decoration: BoxDecoration(
          color: IntelliJTheme.cardBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: IntelliJTheme.border),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Row(
              mainAxisAlignment: MainAxisAlignment.spaceBetween,
              children: [
                Expanded(
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      const Icon(Icons.auto_awesome, size: 12, color: Color(0xFF6CB4F8)),
                      const SizedBox(width: 4),
                      Flexible(
                        child: Text(
                          msg.sender.isNotEmpty ? msg.sender : 'CodeLite Assistant',
                          style: const TextStyle(color: IntelliJTheme.gitGreen, fontSize: 10, fontWeight: FontWeight.bold),
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 4),
                Text(
                  msg.isStreaming ? 'Streaming...' : 'Audited',
                  style: TextStyle(
                    color: msg.isStreaming ? IntelliJTheme.accentBlue : IntelliJTheme.gitGreen,
                    fontSize: 9,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),

            // Collapsible Thinking Chain (<think>...</think>)
            if (msg.thought != null && msg.thought!.isNotEmpty) ...[
              Container(
                margin: const EdgeInsets.only(bottom: 8),
                decoration: BoxDecoration(
                  color: const Color(0xFF1E1F22),
                  borderRadius: BorderRadius.circular(4),
                  border: Border.all(color: IntelliJTheme.borderSubtle),
                ),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    InkWell(
                      onTap: () {
                        setState(() {
                          msg.isThinkingExpanded = !msg.isThinkingExpanded;
                        });
                      },
                      child: Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                        child: Row(
                          children: [
                            const Icon(Icons.psychology, size: 12, color: IntelliJTheme.syntaxType),
                            const SizedBox(width: 6),
                            Expanded(
                              child: Text(
                                msg.isStreaming && msg.text.isEmpty ? 'Thinking in progress...' : 'Thinking Process',
                                style: const TextStyle(
                                  color: IntelliJTheme.syntaxType,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                ),
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                            const SizedBox(width: 4),
                            Icon(
                              msg.isThinkingExpanded ? Icons.expand_less : Icons.expand_more,
                              size: 14,
                              color: IntelliJTheme.textMuted,
                            ),
                          ],
                        ),
                      ),
                    ),
                    if (msg.isThinkingExpanded)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(8, 0, 8, 8),
                        child: Text(
                          msg.thought!,
                          style: const TextStyle(
                            fontFamily: 'monospace',
                            fontSize: 10.5,
                            color: Color(0xFFBCBEC4),
                            height: 1.3,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ],

            // Content text with typewriter pulsing cursor
            Text.rich(
              TextSpan(
                children: [
                  TextSpan(
                    text: msg.text.isNotEmpty ? msg.text : (msg.isStreaming ? 'Processing...' : ''),
                    style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12, height: 1.35),
                  ),
                  if (msg.isStreaming)
                    const TextSpan(
                      text: ' ▋',
                      style: TextStyle(color: IntelliJTheme.accentBlue, fontSize: 12, fontWeight: FontWeight.bold),
                    ),
                ],
              ),
            ),

            if (msg.badge != null) ...[
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3),
                decoration: BoxDecoration(
                  color: const Color(0xFF252830),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Text(
                  msg.badge!,
                  style: const TextStyle(
                    color: IntelliJTheme.gitGreen,
                    fontSize: 10,
                    fontFamily: 'monospace',
                  ),
                ),
              ),
            ],
          ],
        ),
      );
    }
  }

  Widget _buildChip(String label, Color color) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: color.withOpacity(0.15),
        borderRadius: BorderRadius.circular(3),
      ),
      child: Text(label, style: TextStyle(color: color, fontSize: 9, fontFamily: 'monospace')),
    );
  }

  Widget _buildContextInsightsCard() {
    final ins = _contextInsights;
    final insFiles = (ins?['instruction_files'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? ['AGENTS.md'];
    final activeSkills = (ins?['active_skills'] as List<dynamic>?)?.map((e) => e.toString()).toList() ?? [];
    final decCount = ins?['recalled_decisions'] as int? ?? 0;
    final errCount = ins?['recalled_errors'] as int? ?? 0;
    final hasCodeGraph = ins?['has_codegraph'] as bool? ?? false;
    final hasLsp = ins?['has_lsp_diagnostics'] as bool? ?? false;

    return Container(
      padding: const EdgeInsets.all(8),
      decoration: BoxDecoration(
        color: IntelliJTheme.cardBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(color: const Color(0xFF3C3F41)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              const Expanded(
                child: Row(
                  children: [
                    Icon(Icons.hub_outlined, size: 13, color: Color(0xFF6CB4F8)),
                    SizedBox(width: 5),
                    Flexible(
                      child: Text(
                        'CONTEXT ENGINE (PHASE 10)',
                        style: TextStyle(
                          color: Color(0xFF6CB4F8),
                          fontSize: 9.5,
                          fontWeight: FontWeight.bold,
                          letterSpacing: 0.3,
                        ),
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                  ],
                ),
              ),
              InkWell(
                onTap: () {
                  setState(() {
                    _showInsights = !_showInsights;
                  });
                  // 展开时才去取数据,且仅在还没有数据时取。
                  if (_showInsights && _contextInsights == null) {
                    _refreshContextInsights();
                  }
                },
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        _showInsights ? 'Collapse' : 'Inspect',
                        style: const TextStyle(
                          color: IntelliJTheme.textSecondary,
                          fontSize: 9,
                        ),
                      ),
                      Icon(
                        _showInsights ? Icons.expand_less : Icons.expand_more,
                        size: 12,
                        color: IntelliJTheme.textSecondary,
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Wrap(
            spacing: 4,
            runSpacing: 4,
            children: [
              _buildChip(
                '📘 ${insFiles.isNotEmpty ? insFiles.first : "Rules"}',
                const Color(0xFF6CB4F8),
              ),
              _buildChip(
                '⚡ ${_skillsList.length} skills',
                const Color(0xFFE5C07B),
              ),
              _buildChip(
                '🧠 ${decCount + errCount} memories',
                const Color(0xFF98C379),
              ),
              _buildChip(
                '🌐 CodeGraph: ${hasCodeGraph ? "AST" : "Idle"}',
                const Color(0xFFC678DD),
              ),
              if (_mcpToolsList.isNotEmpty)
                _buildChip(
                  '🔌 ${_mcpToolsList.length} MCP',
                  const Color(0xFF56B6C2),
                ),
            ],
          ),
          if (_showInsights) ...[
            const SizedBox(height: 8),
            const Divider(color: IntelliJTheme.borderSubtle, height: 1),
            const SizedBox(height: 6),
            const Text(
              'PROMPT SYNTHESIS BREAKDOWN',
              style: TextStyle(
                color: IntelliJTheme.textMuted,
                fontSize: 8.5,
                fontWeight: FontWeight.bold,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '• Instructions: ${insFiles.join(', ')} (${ins?['instruction_bytes'] ?? 0} B)',
              style: const TextStyle(color: IntelliJTheme.textSecondary, fontSize: 10, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 2),
            Text(
              '• Active Skills: ${activeSkills.isNotEmpty ? activeSkills.join(', ') : (_skillsList.map((s) => s['name'] ?? '').join(', '))}',
              style: const TextStyle(color: IntelliJTheme.textSecondary, fontSize: 10, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 2),
            Text(
              '• Memory Recalled: $decCount decisions, $errCount error lessons',
              style: const TextStyle(color: IntelliJTheme.textSecondary, fontSize: 10, fontFamily: 'monospace'),
            ),
            const SizedBox(height: 2),
            Text(
              '• Realtime LSP: ${hasLsp ? "Diagnostics Attached" : "Clean"}',
              style: const TextStyle(color: IntelliJTheme.textSecondary, fontSize: 10, fontFamily: 'monospace'),
            ),
          ],
        ],
      ),
    );
  }
}
