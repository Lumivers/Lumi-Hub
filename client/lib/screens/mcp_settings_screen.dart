import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ws_service.dart';
import '../theme/app_theme.dart';

class McpSettingsScreen extends StatefulWidget {
  const McpSettingsScreen({super.key});

  @override
  State<McpSettingsScreen> createState() => _McpSettingsScreenState();
}

class _McpSettingsScreenState extends State<McpSettingsScreen> {
  bool _isLoading = true;
  Map<String, dynamic>? _config;
  StreamSubscription? _sub;

  // Controllers for Notion
  final TextEditingController _notionTokenController = TextEditingController();

  @override
  void initState() {
    super.initState();
    final ws = context.read<WsService>();
    _sub = ws.mcpConfigResponses.listen(_handleResponse);
    if (ws.status == WsStatus.connected) {
      ws.getMcpConfig();
    } else {
      setState(() => _isLoading = false);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('WebSocket 未连接，请稍后再试'),
            backgroundColor: Colors.orange,
          ),
        );
      });
    }
  }

  void _handleResponse(Map<String, dynamic> response) {
    if (!mounted) return;
    final type = response['type'];
    final payload = response['payload'] ?? {};
    final status = payload['status'];

    if (type == 'MCP_CONFIG_RESPONSE') {
      setState(() => _isLoading = false);
      if (status == 'success') {
        setState(() {
          _config = payload['config'];
          _populateControllers();
        });
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('获取配置失败: ${payload['message'] ?? '未知错误'}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    } else if (type == 'MCP_CONFIG_UPDATE_RESPONSE') {
      setState(() => _isLoading = false);
      if (status == 'success') {
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('MCP 配置已更新并热重载成功！')));
        Navigator.pop(context);
      } else {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('更新失败: ${payload['message']}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    }
  }

  void _populateControllers() {
    if (_config == null) return;
    final servers = _config!['mcpServers'] as Map<String, dynamic>? ?? {};

    // Notion
    if (servers.containsKey('notion')) {
      final notionEnv = servers['notion']['env'] as Map<String, dynamic>? ?? {};
      _notionTokenController.text = notionEnv['NOTION_API_TOKEN'] ?? '';
    }
  }

  void _saveConfig() {
    if (_config == null) return;
    setState(() => _isLoading = true);

    // Construct new config to keep other servers intact
    final newConfig = Map<String, dynamic>.from(_config!);
    final servers = Map<String, dynamic>.from(newConfig['mcpServers'] ?? {});

    // Update Notion
    if (servers.containsKey('notion')) {
      final notionConf = Map<String, dynamic>.from(servers['notion']);
      final notionEnv = Map<String, dynamic>.from(notionConf['env'] ?? {});
      notionEnv['NOTION_API_TOKEN'] = _notionTokenController.text.trim();
      notionConf['env'] = notionEnv;
      servers['notion'] = notionConf;
    }

    newConfig['mcpServers'] = servers;
    context.read<WsService>().updateMcpConfig(newConfig);
  }

  @override
  void dispose() {
    _sub?.cancel();
    _notionTokenController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>()!;
    final colorScheme = Theme.of(context).colorScheme;
    final scaffoldBg = Theme.of(context).scaffoldBackgroundColor;

    return Scaffold(
      backgroundColor: scaffoldBg,
      appBar: AppBar(
        backgroundColor: colors.sidebar,
        elevation: 0,
        iconTheme: IconThemeData(color: colorScheme.onSurface),
        title: Text(
          '扩展生态 (MCP)',
          style: TextStyle(
            color: colorScheme.onSurface,
            fontSize: 16,
            fontWeight: FontWeight.w600,
          ),
        ),
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : SingleChildScrollView(
              padding: const EdgeInsets.all(24.0),
              child: Center(
                child: ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 800),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        'Model Context Protocol 配置',
                        style: TextStyle(
                          color: colorScheme.onSurface,
                          fontSize: 24,
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        '配置第三方服务器的访问凭证。保存后将自动热重载相关服务，无需重启。',
                        style: TextStyle(color: colors.subtext),
                      ),
                      const SizedBox(height: 32),

                      // Notion Server Card
                      _buildServerCard(
                        colors: colors,
                        colorScheme: colorScheme,
                        title: 'Notion',
                        description: '允许 Lumi-Hub 读取和写入你的 Notion 页面与数据库。',
                        icon: Icons.article_rounded,
                        children: [
                          _buildTextField(
                            context: context,
                            colors: colors,
                            colorScheme: colorScheme,
                            label:
                                'Notion API Token (Internal Integration Secret)',
                            controller: _notionTokenController,
                            obscureText: true,
                          ),
                        ],
                      ),

                      const SizedBox(height: 32),

                      // Save action
                      Row(
                        mainAxisAlignment: MainAxisAlignment.end,
                        children: [
                          ElevatedButton(
                            onPressed: _saveConfig,
                            style: ElevatedButton.styleFrom(
                              backgroundColor: colors.accent,
                              foregroundColor: Colors.white,
                              padding: const EdgeInsets.symmetric(
                                horizontal: 24,
                                vertical: 16,
                              ),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(8),
                              ),
                            ),
                            child: const Text('保存并热重载'),
                          ),
                        ],
                      ),
                    ],
                  ),
                ),
              ),
            ),
    );
  }

  Widget _buildServerCard({
    required LumiColors colors,
    required ColorScheme colorScheme,
    required String title,
    required String description,
    required IconData icon,
    required List<Widget> children,
  }) {
    return Container(
      decoration: BoxDecoration(
        color: colors.inputBg,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: colors.divider),
      ),
      padding: const EdgeInsets.all(24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Container(
                padding: const EdgeInsets.all(8),
                decoration: BoxDecoration(
                  color: colors.accent.withValues(alpha: 0.1),
                  borderRadius: BorderRadius.circular(8),
                ),
                child: Icon(icon, color: colors.accent),
              ),
              const SizedBox(width: 16),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: TextStyle(
                        color: colorScheme.onSurface,
                        fontSize: 18,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      description,
                      style: TextStyle(color: colors.subtext, fontSize: 13),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 24),
          ...children,
        ],
      ),
    );
  }

  Widget _buildTextField({
    required BuildContext context,
    required LumiColors colors,
    required ColorScheme colorScheme,
    required String label,
    required TextEditingController controller,
    bool obscureText = false,
  }) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Text(
          label,
          style: TextStyle(
            color: colorScheme.onSurface,
            fontSize: 13,
            fontWeight: FontWeight.w500,
          ),
        ),
        const SizedBox(height: 8),
        TextField(
          controller: controller,
          obscureText: obscureText,
          style: TextStyle(color: colorScheme.onSurface, fontSize: 14),
          decoration: InputDecoration(
            filled: true,
            fillColor: Theme.of(context).scaffoldBackgroundColor,
            border: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: colors.divider),
            ),
            enabledBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: colors.divider),
            ),
            focusedBorder: OutlineInputBorder(
              borderRadius: BorderRadius.circular(8),
              borderSide: BorderSide(color: colors.accent),
            ),
            contentPadding: const EdgeInsets.symmetric(
              horizontal: 16,
              vertical: 12,
            ),
          ),
        ),
      ],
    );
  }
}
