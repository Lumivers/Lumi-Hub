import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ws_service.dart';
import '../theme/app_theme.dart';

part 'mcp_settings_models.dart';
part 'mcp_settings_editor_dialog.dart';
part 'mcp_settings_widgets.dart';

// ── Main Screen ─────────────────────────────────────────────────────────────

class McpSettingsScreen extends StatefulWidget {
  const McpSettingsScreen({super.key});

  @override
  State<McpSettingsScreen> createState() => _McpSettingsScreenState();
}

class _McpSettingsScreenState extends State<McpSettingsScreen> {
  bool _isLoading = true;
  Map<String, dynamic> _rawServers = {};
  StreamSubscription? _sub;

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
        _showSnack('WebSocket 未连接，请稍后再试', isError: true);
      });
    }
  }

  void _handleResponse(Map<String, dynamic> response) {
    if (!mounted) return;
    final type = response['type'];
    final payload = response['payload'] ?? {};
    final status = payload['status'];

    if (type == 'MCP_CONFIG_RESPONSE') {
      setState(() {
        _isLoading = false;
        if (status == 'success') {
          final config = payload['config'] as Map<String, dynamic>? ?? {};
          _rawServers = Map<String, dynamic>.from(
            config['mcpServers'] as Map<String, dynamic>? ?? {},
          );
        }
      });
      if (status != 'success') {
        _showSnack('获取配置失败: ${payload['message'] ?? '未知错误'}', isError: true);
      }
    } else if (type == 'MCP_CONFIG_UPDATE_RESPONSE') {
      setState(() => _isLoading = false);
      if (status == 'success') {
        _showSnack('MCP 配置已更新并热重载成功！');
      } else {
        _showSnack('更新失败: ${payload['message']}', isError: true);
      }
    }
  }

  void _showSnack(String msg, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(msg),
        backgroundColor: isError ? Colors.red : null,
      ),
    );
  }

  void _saveAll() {
    setState(() => _isLoading = true);
    final fullConfig = {'mcpServers': _rawServers};
    context.read<WsService>().updateMcpConfig(fullConfig);
  }

  void _deleteServer(String name) {
    setState(() {
      _rawServers.remove(name);
    });
    _saveAll();
  }

  Future<void> _openEditor({String? existingName}) async {
    McpServerDraft initial;
    if (existingName != null && _rawServers.containsKey(existingName)) {
      initial = McpServerDraft.fromConfig(
        existingName,
        _rawServers[existingName] as Map<String, dynamic>,
      );
    } else {
      initial = McpServerDraft();
    }

    final result = await showDialog<McpServerDraft>(
      context: context,
      barrierDismissible: false,
      builder: (_) => _McpServerEditorDialog(
        draft: initial,
        existingNames: _rawServers.keys.where((k) => k != existingName).toSet(),
      ),
    );

    if (result == null) return;

    setState(() {
      if (existingName != null && existingName != result.name) {
        _rawServers.remove(existingName);
      }
      _rawServers[result.name] = result.toConfig();
    });
    _saveAll();
  }

  @override
  void dispose() {
    _sub?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>()!;
    final colorScheme = Theme.of(context).colorScheme;

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
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
        actions: [
          Padding(
            padding: const EdgeInsets.only(right: 12),
            child: TextButton.icon(
              onPressed: _isLoading ? null : () => _openEditor(),
              icon: Icon(Icons.add_rounded, color: colors.accent),
              label: Text(
                '添加 Server',
                style: TextStyle(color: colors.accent, fontSize: 13),
              ),
            ),
          ),
        ],
      ),
      body: _isLoading
          ? const Center(child: CircularProgressIndicator())
          : _buildBody(colors, colorScheme),
    );
  }

  Widget _buildBody(LumiColors colors, ColorScheme colorScheme) {
    if (_rawServers.isEmpty) {
      return Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.extension_off_rounded,
              size: 64,
              color: colors.subtext.withValues(alpha: 0.4),
            ),
            const SizedBox(height: 16),
            Text(
              '尚未配置任何 MCP Server',
              style: TextStyle(color: colors.subtext, fontSize: 15),
            ),
            const SizedBox(height: 24),
            ElevatedButton.icon(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add_rounded),
              label: const Text('添加第一个 Server'),
              style: ElevatedButton.styleFrom(
                backgroundColor: colors.accent,
                foregroundColor: Colors.white,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 14,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(10),
                ),
              ),
            ),
          ],
        ),
      );
    }

    return ListView(
      padding: const EdgeInsets.all(24),
      children: [
        ..._rawServers.entries.map(
          (entry) => Padding(
            padding: const EdgeInsets.only(bottom: 12),
            child: _ServerCard(
              name: entry.key,
              config: entry.value as Map<String, dynamic>,
              colors: colors,
              colorScheme: colorScheme,
              onEdit: () => _openEditor(existingName: entry.key),
              onDelete: () => _confirmDelete(entry.key),
            ),
          ),
        ),
        const SizedBox(height: 8),
        OutlinedButton.icon(
          onPressed: () => _openEditor(),
          icon: Icon(Icons.add_rounded, color: colors.accent),
          label: Text('添加 Server', style: TextStyle(color: colors.accent)),
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: colors.accent.withValues(alpha: 0.5)),
            padding: const EdgeInsets.symmetric(vertical: 14),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(10),
            ),
          ),
        ),
      ],
    );
  }

  Future<void> _confirmDelete(String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除 Server'),
        content: Text('确认删除 "$name"？此操作会立即热重载。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) _deleteServer(name);
  }
}

// ── Server Card ──────────────────────────────────────────────────────────────
