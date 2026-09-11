import 'dart:convert';
import 'package:flutter/material.dart';
import '../../core/client/api_client.dart';
import '../../core/theme/intellij_theme.dart';

/// Modal dialog for WASM Plugin Ecosystem & Sandboxed Runtime management (Phase 12).
class PluginsModal extends StatefulWidget {
  final ApiClient client;

  const PluginsModal({
    super.key,
    required this.client,
  });

  static Future<void> show(
    BuildContext context, {
    required ApiClient client,
  }) {
    return showDialog<void>(
      context: context,
      barrierColor: Colors.black.withOpacity(0.55),
      builder: (ctx) => PluginsModal(client: client),
    );
  }

  @override
  State<PluginsModal> createState() => _PluginsModalState();
}

class _PluginsModalState extends State<PluginsModal> {
  bool _isLoading = true;
  String _searchQuery = '';
  List<Map<String, dynamic>> _plugins = [];
  String? _errorMessage;

  // Selected tool test state
  Map<String, dynamic>? _testingToolPlugin;
  Map<String, dynamic>? _testingTool;
  final TextEditingController _testArgController = TextEditingController();
  bool _isExecutingTool = false;
  Map<String, dynamic>? _toolExecutionResult;

  @override
  void initState() {
    super.initState();
    _loadPlugins();
  }

  @override
  void dispose() {
    _testArgController.dispose();
    super.dispose();
  }

  Future<void> _loadPlugins() async {
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      final list = await widget.client.listPlugins();
      if (mounted) {
        setState(() {
          _plugins = list;
          _isLoading = false;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _errorMessage = '加载插件列表失败: $e';
          _isLoading = false;
        });
      }
    }
  }

  Future<void> _togglePlugin(String pluginId, bool enable) async {
    try {
      final res = await widget.client.togglePlugin(pluginId, enable);
      if (res['status'] == 'ok') {
        setState(() {
          final idx = _plugins.indexWhere((p) => p['id'] == pluginId);
          if (idx != -1) {
            _plugins[idx]['status'] = enable ? 'enabled' : 'disabled';
          }
        });
      } else {
        _showToast(res['error'] ?? '切换插件状态失败');
      }
    } catch (e) {
      _showToast('操作异常: $e');
    }
  }

  Future<void> _installDemoWasmPlugin() async {
    final manifest = {
      'id': 'org.codelitex.demo_wasm',
      'name': 'Regex Optimizer (WASM)',
      'version': '0.1.0',
      'author': 'WASM Contributor',
      'description': 'Sandboxed WebAssembly regular expression optimizer and analyzer',
      'entrypoint': 'plugin.wasm',
      'permissions': ['log'],
      'provided_tools': [
        {
          'name': 'optimize_regex',
          'description': 'Analyzes regex pattern and recommends performance improvements',
          'risk_level': 'low',
        }
      ],
    };

    // Standard valid WASM header bytes: \0asm 1.0.0.0
    final wasmBytes = [0x00, 0x61, 0x73, 0x6d, 0x01, 0x00, 0x00, 0x00];

    try {
      final res = await widget.client.loadPlugin(manifest: manifest, wasmBytes: wasmBytes);
      if (res['status'] == 'ok') {
        _showToast('成功加载 WASM 插件: ${manifest['name']}');
        await _loadPlugins();
      } else {
        _showToast(res['error'] ?? '加载插件失败');
      }
    } catch (e) {
      _showToast('安装失败: $e');
    }
  }

  void _showToast(String msg) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg, style: const TextStyle(fontSize: 12, color: Colors.white)),
        backgroundColor: IntelliJTheme.panelBg,
        duration: const Duration(seconds: 2),
      ),
    );
  }

  void _openToolTester(Map<String, dynamic> plugin, Map<String, dynamic> tool) {
    setState(() {
      _testingToolPlugin = plugin;
      _testingTool = tool;
      _toolExecutionResult = null;
      if (tool['name'] == 'inspect_sql') {
        _testArgController.text = jsonEncode({'query': 'SELECT * FROM users WHERE active = 1;'});
      } else if (tool['name'] == 'lint_code') {
        _testArgController.text = jsonEncode({'code': 'let x = 1;\n// TODO: clean up magic number'});
      } else {
        _testArgController.text = jsonEncode({});
      }
    });
  }

  Future<void> _executeTool() async {
    if (_testingToolPlugin == null || _testingTool == null) return;
    setState(() {
      _isExecutingTool = true;
      _toolExecutionResult = null;
    });

    try {
      Map<String, dynamic> args = {};
      try {
        final decoded = jsonDecode(_testArgController.text.trim());
        if (decoded is Map<String, dynamic>) args = decoded;
      } catch (_) {}

      final res = await widget.client.executePluginTool(
        pluginId: _testingToolPlugin!['id'] as String,
        toolName: _testingTool!['name'] as String,
        args: args,
      );

      if (mounted) {
        setState(() {
          _isExecutingTool = false;
          _toolExecutionResult = res;
        });
      }
    } catch (e) {
      if (mounted) {
        setState(() {
          _isExecutingTool = false;
          _toolExecutionResult = {'status': 'error', 'error': '$e'};
        });
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final filtered = _plugins.where((p) {
      final q = _searchQuery.toLowerCase();
      if (q.isEmpty) return true;
      final name = (p['name'] as String? ?? '').toLowerCase();
      final id = (p['id'] as String? ?? '').toLowerCase();
      final desc = (p['description'] as String? ?? '').toLowerCase();
      return name.contains(q) || id.contains(q) || desc.contains(q);
    }).toList();

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 48, vertical: 36),
      child: Container(
        width: 860,
        height: 640,
        decoration: BoxDecoration(
          color: IntelliJTheme.editorBg,
          borderRadius: BorderRadius.circular(8),
          border: Border.all(color: IntelliJTheme.borderSubtle),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withOpacity(0.4),
              blurRadius: 24,
              offset: const Offset(0, 8),
            ),
          ],
        ),
        child: Column(
          children: [
            _buildHeader(),
            const Divider(height: 1, color: IntelliJTheme.borderSubtle),
            _buildToolbar(),
            const Divider(height: 1, color: IntelliJTheme.borderSubtle),
            Expanded(
              child: _testingTool != null
                  ? _buildToolTestingView()
                  : _buildPluginsListView(filtered),
            ),
            const Divider(height: 1, color: IntelliJTheme.borderSubtle),
            _buildFooter(filtered.length),
          ],
        ),
      ),
    );
  }

  Widget _buildHeader() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: const BoxDecoration(
        color: IntelliJTheme.headerBg,
        borderRadius: BorderRadius.vertical(top: Radius.circular(8)),
      ),
      child: Row(
        children: [
          const Icon(
            Icons.extension,
            size: 16,
            color: IntelliJTheme.accentBlue,
          ),
          const SizedBox(width: 8),
          const Expanded(
            child: Text(
              'CodeLiteX 插件中心 (WASM Sandboxed Plugins)',
              style: TextStyle(
                color: IntelliJTheme.textHigh,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          InkWell(
            onTap: () => Navigator.of(context).pop(),
            borderRadius: BorderRadius.circular(4),
            child: const Padding(
              padding: EdgeInsets.all(4),
              child: Icon(
                Icons.close,
                size: 16,
                color: IntelliJTheme.textSecondary,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildToolbar() {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      color: IntelliJTheme.panelBg,
      child: Row(
        children: [
          Expanded(
            child: SizedBox(
              height: 30,
              child: TextField(
                style: const TextStyle(color: IntelliJTheme.textPrimary, fontSize: 12),
                decoration: InputDecoration(
                  hintText: '搜索插件名称、标识符或描述...',
                  hintStyle: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 12),
                  prefixIcon: const Icon(Icons.search, size: 16, color: IntelliJTheme.textMuted),
                  contentPadding: const EdgeInsets.symmetric(vertical: 6, horizontal: 8),
                  filled: true,
                  fillColor: IntelliJTheme.editorBg,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: IntelliJTheme.borderSubtle),
                  ),
                  enabledBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: IntelliJTheme.borderSubtle),
                  ),
                  focusedBorder: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(4),
                    borderSide: const BorderSide(color: IntelliJTheme.accentBlue),
                  ),
                ),
                onChanged: (val) {
                  setState(() {
                    _searchQuery = val;
                  });
                },
              ),
            ),
          ),
          const SizedBox(width: 12),
          OutlinedButton.icon(
            onPressed: _installDemoWasmPlugin,
            icon: const Icon(Icons.add, size: 14, color: IntelliJTheme.accentBlue),
            label: const Text(
              '安装示例 WASM 插件',
              style: TextStyle(fontSize: 12, color: IntelliJTheme.accentBlue),
            ),
            style: OutlinedButton.styleFrom(
              side: const BorderSide(color: IntelliJTheme.accentBlue),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
              visualDensity: VisualDensity.compact,
            ),
          ),
          const SizedBox(width: 8),
          IconButton(
            onPressed: _loadPlugins,
            icon: const Icon(Icons.refresh, size: 16, color: IntelliJTheme.textSecondary),
            tooltip: '刷新插件',
            visualDensity: VisualDensity.compact,
          ),
        ],
      ),
    );
  }

  Widget _buildPluginsListView(List<Map<String, dynamic>> plugins) {
    if (_isLoading) {
      return const Center(
        child: CircularProgressIndicator(color: IntelliJTheme.accentBlue, strokeWidth: 2),
      );
    }

    if (_errorMessage != null) {
      return Center(
        child: Text(_errorMessage!, style: const TextStyle(color: IntelliJTheme.gitRed, fontSize: 12)),
      );
    }

    if (plugins.isEmpty) {
      return const Center(
        child: Text('未找到匹配的插件', style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 12)),
      );
    }

    return ListView.separated(
      padding: const EdgeInsets.all(16),
      itemCount: plugins.length,
      separatorBuilder: (_, __) => const SizedBox(height: 12),
      itemBuilder: (ctx, index) {
        final plugin = plugins[index];
        return _buildPluginCard(plugin);
      },
    );
  }

  Widget _buildPluginCard(Map<String, dynamic> plugin) {
    final id = plugin['id'] as String? ?? '';
    final name = plugin['name'] as String? ?? id;
    final version = plugin['version'] as String? ?? '0.1.0';
    final author = plugin['author'] as String? ?? 'CodeLiteX';
    final description = plugin['description'] as String? ?? '';
    final status = plugin['status'] as String? ?? 'enabled';
    final isEnabled = status == 'enabled';
    final permissions = (plugin['permissions'] as List<dynamic>? ?? []).map((e) => e.toString()).toList();
    final tools = (plugin['tools'] as List<dynamic>? ?? []).map((e) => e as Map<String, dynamic>).toList();

    return Container(
      decoration: BoxDecoration(
        color: IntelliJTheme.panelBg,
        borderRadius: BorderRadius.circular(6),
        border: Border.all(
          color: isEnabled ? IntelliJTheme.borderSubtle : IntelliJTheme.borderSubtle.withOpacity(0.5),
        ),
      ),
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(6),
                decoration: BoxDecoration(
                  color: isEnabled
                      ? IntelliJTheme.accentBlue.withOpacity(0.12)
                      : Colors.white.withOpacity(0.04),
                  borderRadius: BorderRadius.circular(4),
                ),
                child: Icon(
                  Icons.extension_outlined,
                  size: 18,
                  color: isEnabled ? IntelliJTheme.accentBlue : IntelliJTheme.textMuted,
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Flexible(
                          child: Text(
                            name,
                            style: TextStyle(
                              color: isEnabled ? IntelliJTheme.textHigh : IntelliJTheme.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: Colors.white.withOpacity(0.06),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            'v$version',
                            style: const TextStyle(fontSize: 10, color: IntelliJTheme.textMuted),
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                          decoration: BoxDecoration(
                            color: (isEnabled ? IntelliJTheme.gitGreen : IntelliJTheme.textMuted).withOpacity(0.15),
                            borderRadius: BorderRadius.circular(3),
                          ),
                          child: Text(
                            isEnabled ? '已启用' : '已禁用',
                            style: TextStyle(
                              fontSize: 10,
                              color: isEnabled ? IntelliJTheme.gitGreen : IntelliJTheme.textMuted,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 2),
                    Text(
                      '$id • 作者: $author',
                      style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
              Switch(
                value: isEnabled,
                onChanged: (val) => _togglePlugin(id, val),
                activeColor: IntelliJTheme.accentBlue,
                materialTapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
            ],
          ),
          const SizedBox(height: 10),
          Text(
            description,
            style: const TextStyle(color: IntelliJTheme.textSecondary, fontSize: 12),
          ),
          const SizedBox(height: 10),
          // Permissions row
          Row(
            crossAxisAlignment: CrossAxisAlignment.center,
            children: [
              const Text(
                '沙箱权限: ',
                style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11, fontWeight: FontWeight.w500),
              ),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: permissions.map((p) {
                    return Container(
                      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                      decoration: BoxDecoration(
                        color: IntelliJTheme.accentBlue.withOpacity(0.08),
                        border: Border.all(color: IntelliJTheme.accentBlue.withOpacity(0.3)),
                        borderRadius: BorderRadius.circular(3),
                      ),
                      child: Text(
                        p,
                        style: const TextStyle(fontSize: 10, color: IntelliJTheme.accentBlue),
                      ),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
          if (tools.isNotEmpty) ...[
            const SizedBox(height: 10),
            const Divider(height: 1, color: IntelliJTheme.borderSubtle),
            const SizedBox(height: 8),
            const Row(
              children: [
                Icon(Icons.handyman_outlined, size: 14, color: IntelliJTheme.textMuted),
                SizedBox(width: 6),
                Expanded(
                  child: Text(
                    '对外注册的 ToolRuntime 工具:',
                    style: TextStyle(color: IntelliJTheme.textSecondary, fontSize: 11, fontWeight: FontWeight.w600),
                    overflow: TextOverflow.ellipsis,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            Wrap(
              spacing: 8,
              runSpacing: 6,
              children: tools.map((t) {
                final toolName = t['name'] as String? ?? 'tool';
                final risk = t['risk_level'] as String? ?? 'low';
                final riskColor = risk == 'critical'
                    ? IntelliJTheme.gitRed
                    : (risk == 'medium' ? Colors.orangeAccent : IntelliJTheme.gitGreen);

                return InkWell(
                  onTap: isEnabled ? () => _openToolTester(plugin, t) : null,
                  borderRadius: BorderRadius.circular(4),
                  child: Container(
                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                    decoration: BoxDecoration(
                      color: Colors.white.withOpacity(0.04),
                      borderRadius: BorderRadius.circular(4),
                      border: Border.all(color: IntelliJTheme.borderSubtle),
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          toolName,
                          style: TextStyle(
                            fontSize: 11,
                            color: isEnabled ? IntelliJTheme.textPrimary : IntelliJTheme.textMuted,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 1),
                          decoration: BoxDecoration(
                            color: riskColor.withOpacity(0.15),
                            borderRadius: BorderRadius.circular(2),
                          ),
                          child: Text(
                            risk.toUpperCase(),
                            style: TextStyle(fontSize: 9, color: riskColor, fontWeight: FontWeight.bold),
                          ),
                        ),
                        if (isEnabled) ...[
                          const SizedBox(width: 6),
                          const Icon(Icons.play_arrow, size: 12, color: IntelliJTheme.accentBlue),
                        ],
                      ],
                    ),
                  ),
                );
              }).toList(),
            ),
          ],
        ],
      ),
    );
  }

  Widget _buildToolTestingView() {
    final tool = _testingTool!;
    final plugin = _testingToolPlugin!;

    return Container(
      padding: const EdgeInsets.all(16),
      color: IntelliJTheme.editorBg,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              IconButton(
                onPressed: () {
                  setState(() {
                    _testingTool = null;
                    _testingToolPlugin = null;
                    _toolExecutionResult = null;
                  });
                },
                icon: const Icon(Icons.arrow_back, size: 16, color: IntelliJTheme.textSecondary),
                visualDensity: VisualDensity.compact,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      '测试插件工具: ${tool['name']}',
                      style: const TextStyle(
                        color: IntelliJTheme.textHigh,
                        fontSize: 13,
                        fontWeight: FontWeight.w600,
                      ),
                      overflow: TextOverflow.ellipsis,
                    ),
                    Text(
                      '插件: ${plugin['id']} (${plugin['name']})',
                      style: const TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
                      overflow: TextOverflow.ellipsis,
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '工具输入参数 (JSON):',
            style: TextStyle(color: IntelliJTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          Expanded(
            flex: 2,
            child: Container(
              decoration: BoxDecoration(
                color: IntelliJTheme.panelBg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: IntelliJTheme.borderSubtle),
              ),
              padding: const EdgeInsets.all(8),
              child: TextField(
                controller: _testArgController,
                maxLines: null,
                style: const TextStyle(
                  fontFamily: 'JetBrains Mono',
                  fontSize: 12,
                  color: IntelliJTheme.textPrimary,
                ),
                decoration: const InputDecoration(
                  border: InputBorder.none,
                  hintText: '{\n  "query": "SELECT * FROM ..."\n}',
                  hintStyle: TextStyle(color: IntelliJTheme.textMuted, fontSize: 12),
                ),
              ),
            ),
          ),
          const SizedBox(height: 10),
          Row(
            children: [
              ElevatedButton.icon(
                onPressed: _isExecutingTool ? null : _executeTool,
                icon: _isExecutingTool
                    ? const SizedBox(
                        width: 12,
                        height: 12,
                        child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                      )
                    : const Icon(Icons.play_arrow, size: 14),
                label: Text(_isExecutingTool ? '沙箱执行中...' : '在沙箱中执行工具'),
                style: ElevatedButton.styleFrom(
                  backgroundColor: IntelliJTheme.accentBlue,
                  foregroundColor: Colors.white,
                  padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
                  visualDensity: VisualDensity.compact,
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          const Text(
            '沙箱运行结果 (Sandbox Output):',
            style: TextStyle(color: IntelliJTheme.textSecondary, fontSize: 12, fontWeight: FontWeight.w500),
          ),
          const SizedBox(height: 6),
          Expanded(
            flex: 3,
            child: Container(
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: IntelliJTheme.panelBg,
                borderRadius: BorderRadius.circular(4),
                border: Border.all(color: IntelliJTheme.borderSubtle),
              ),
              child: SingleChildScrollView(
                child: _toolExecutionResult != null
                    ? SelectableText(
                        const JsonEncoder.withIndent('  ').convert(_toolExecutionResult),
                        style: TextStyle(
                          fontFamily: 'JetBrains Mono',
                          fontSize: 11,
                          color: _toolExecutionResult!['status'] == 'error'
                              ? IntelliJTheme.gitRed
                              : IntelliJTheme.gitGreen,
                        ),
                      )
                    : const Text(
                        '点击执行后在此查看沙箱返回值或安全拦截报告...',
                        style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 12),
                      ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildFooter(int count) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      color: IntelliJTheme.headerBg,
      child: Row(
        children: [
          const Icon(Icons.security, size: 14, color: IntelliJTheme.gitGreen),
          const SizedBox(width: 6),
          const Expanded(
            child: Text(
              '沙箱安全运行环境已激活 (Fuel Metering + Stack Limiting + Memory Bounds)',
              style: TextStyle(color: IntelliJTheme.textMuted, fontSize: 11),
              overflow: TextOverflow.ellipsis,
            ),
          ),
          Text(
            '共 $count 个插件已注册',
            style: const TextStyle(color: IntelliJTheme.textSecondary, fontSize: 11),
          ),
        ],
      ),
    );
  }
}
