import 'dart:async';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';
import '../services/bootstrap_service.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';
import 'auth_screen.dart';
import 'llm_settings_screen.dart';
import 'mcp_settings_screen.dart';
import 'resource_package_screen.dart';
import 'voice_settings_screen.dart';

/// 统一设置中心对话框 (Settings Hub Dialog)
class SettingsHubDialog extends StatefulWidget {
  final WsService ws;
  final LumiColors colors;
  final int initialTab;

  const SettingsHubDialog({
    super.key,
    required this.ws,
    required this.colors,
    this.initialTab = 0,
  });

  /// 弹出统一设置中心模态框
  static Future<void> show(
    BuildContext context, {
    required WsService ws,
    required LumiColors colors,
    int initialTab = 0,
  }) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        child: SizedBox(
          width: 760,
          height: 640,
          child: SettingsHubDialog(ws: ws, colors: colors, initialTab: initialTab),
        ),
      ),
    );
  }

  @override
  State<SettingsHubDialog> createState() => _SettingsHubDialogState();
}

class _SettingsHubDialogState extends State<SettingsHubDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 4,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 3),
    );
  }

  @override
  void dispose() {
    _tabController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);

    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: false,
        leading: const Padding(
          padding: EdgeInsets.only(left: 12.0),
          child: Icon(Icons.settings_outlined),
        ),
        title: const Text('设置中心'),
        actions: [
          IconButton(
            icon: const Icon(Icons.close),
            tooltip: '关闭',
            onPressed: () => Navigator.of(context).pop(),
          ),
          const SizedBox(width: 8),
        ],
        bottom: TabBar(
          controller: _tabController,
          labelColor: theme.colorScheme.primary,
          unselectedLabelColor: theme.colorScheme.onSurface.withValues(alpha: 0.6),
          indicatorColor: theme.colorScheme.primary,
          tabs: const [
            Tab(icon: Icon(Icons.tune, size: 18), text: '通用设置'),
            Tab(icon: Icon(Icons.smart_toy_outlined, size: 18), text: 'AI 模型'),
            Tab(icon: Icon(Icons.extension_outlined, size: 18), text: 'MCP 扩展'),
            Tab(icon: Icon(Icons.archive_outlined, size: 18), text: '资源包'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _GeneralSettingsTab(ws: widget.ws, colors: widget.colors),
          const LlmSettingsScreen(embedded: true),
          const McpSettingsScreen(embedded: true),
          const ResourcePackageScreen(embedded: true),
        ],
      ),
    );
  }
}

// ─────────────────────────────────────────────────────────────────────────────
// Tab 1: 通用设置
// ─────────────────────────────────────────────────────────────────────────────

class _GeneralSettingsTab extends StatelessWidget {
  final WsService ws;
  final LumiColors colors;

  const _GeneralSettingsTab({required this.ws, required this.colors});

  bool get _supportsLocalHostLifecycle => !kIsWeb && Platform.isWindows;

  bool _isLocalHostUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  Future<void> _applyConnectionMode(BuildContext context, ConnectionMode mode) async {
    final settings = context.read<AppSettings>();
    final currentUrl = ws.serverUrl;
    String nextUrl = currentUrl;
    final shouldUseRemote = mode != ConnectionMode.localOrUsb || !_supportsLocalHostLifecycle;

    switch (mode) {
      case ConnectionMode.localOrUsb:
        nextUrl = 'ws://127.0.0.1:8765';
        break;
      case ConnectionMode.lan:
        if (_isLocalHostUrl(currentUrl)) nextUrl = 'ws://192.168.1.10:8765';
        break;
      case ConnectionMode.publicTunnel:
        if (_isLocalHostUrl(currentUrl)) nextUrl = 'wss://your-domain.example.com/ws';
        break;
    }

    settings.setConnectionMode(mode);
    settings.setRemoteClientMode(shouldUseRemote);
    await ws.setServerUrl(nextUrl, reconnectIfConnected: false);
  }

  Future<void> _showConnectionModeSelector(BuildContext context) async {
    final settings = context.read<AppSettings>();
    var selected = settings.connectionMode;
    final localLabel = _supportsLocalHostLifecycle ? '本机/USB 调试 (127.0.0.1)' : 'USB 调试转发 (127.0.0.1)';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('连接方式'),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              RadioListTile<ConnectionMode>(
                value: ConnectionMode.localOrUsb,
                groupValue: selected,
                title: Text(localLabel),
                onChanged: (v) => setState(() => selected = v!),
              ),
              RadioListTile<ConnectionMode>(
                value: ConnectionMode.lan,
                groupValue: selected,
                title: const Text('局域网'),
                subtitle: const Text('ws://192.168.x.x:8765'),
                onChanged: (v) => setState(() => selected = v!),
              ),
              RadioListTile<ConnectionMode>(
                value: ConnectionMode.publicTunnel,
                groupValue: selected,
                title: const Text('公网/内网穿透'),
                subtitle: const Text('wss://your-domain.example.com/ws'),
                onChanged: (v) => setState(() => selected = v!),
              ),
            ],
          ),
          actions: [
            TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
            FilledButton(
              onPressed: () async {
                await _applyConnectionMode(dialogContext, selected);
                if (dialogContext.mounted) Navigator.pop(dialogContext);
              },
              child: const Text('应用'),
            ),
          ],
        ),
      ),
    );
  }

  Future<void> _showServerUrlEditor(BuildContext context) async {
    final controller = TextEditingController(text: ws.serverUrl);
    await showDialog<void>(
      context: context,
      builder: (dialogContext) => AlertDialog(
        title: const Text('Host 地址'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'WebSocket 地址',
            hintText: 'ws://127.0.0.1:8765 或 192.168.1.10:8765',
          ),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(dialogContext), child: const Text('取消')),
          FilledButton(
            onPressed: () async {
              final raw = controller.text.trim();
              await ws.setServerUrl(raw.isEmpty ? 'ws://127.0.0.1:8765' : raw);
              if (dialogContext.mounted) Navigator.pop(dialogContext);
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final bootstrap = context.watch<BootstrapService>();
    final user = ws.user;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 16),
      children: [
        // 用户信息卡片
        Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: colors.inputBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.divider.withValues(alpha: 0.1)),
          ),
          child: Row(
            children: [
              CircleAvatar(
                backgroundColor: colors.accent,
                child: const Icon(Icons.person, color: Colors.white),
              ),
              const SizedBox(width: 14),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      user?['username'] ?? '未知用户',
                      style: TextStyle(
                        color: Theme.of(context).colorScheme.onSurface,
                        fontWeight: FontWeight.bold,
                        fontSize: 15,
                      ),
                    ),
                    Text(
                      'ID: ${user?['id'] ?? '-'}',
                      style: TextStyle(color: colors.subtext, fontSize: 12),
                    ),
                  ],
                ),
              ),
              OutlinedButton.icon(
                icon: const Icon(Icons.logout, size: 16),
                label: const Text('退出登录'),
                style: OutlinedButton.styleFrom(foregroundColor: Colors.red),
                onPressed: () {
                  ws.logout();
                  Navigator.of(context).pop();
                  Navigator.of(context).pushAndRemoveUntil(
                    MaterialPageRoute(builder: (_) => const AuthScreen()),
                    (r) => false,
                  );
                },
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),

        // 设置选项组
        Container(
          decoration: BoxDecoration(
            color: colors.inputBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.divider.withValues(alpha: 0.1)),
          ),
          child: Column(
            children: [
              // 字体
              ListTile(
                leading: Icon(Icons.font_download_outlined, color: colors.subtext, size: 20),
                title: const Text('应用字体', style: TextStyle(fontSize: 14)),
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<String>(
                    value: settings.fontKey,
                    dropdownColor: colors.inputBg,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13),
                    items: kAvailableFonts.entries
                        .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) settings.setFontFamily(val);
                    },
                  ),
                ),
              ),
              Divider(height: 1, color: colors.divider.withValues(alpha: 0.2), indent: 48),

              // 退出行为
              ListTile(
                leading: Icon(Icons.close_fullscreen, color: colors.subtext, size: 20),
                title: const Text('关闭窗口动作', style: TextStyle(fontSize: 14)),
                subtitle: Text('点击系统关闭按钮时...', style: TextStyle(color: colors.subtext, fontSize: 12)),
                trailing: DropdownButtonHideUnderline(
                  child: DropdownButton<WindowCloseAction>(
                    value: settings.windowCloseAction,
                    dropdownColor: colors.inputBg,
                    style: TextStyle(color: Theme.of(context).colorScheme.onSurface, fontSize: 13),
                    items: kWindowCloseActionLabels.entries
                        .map((e) => DropdownMenuItem(value: e.key, child: Text(e.value)))
                        .toList(),
                    onChanged: (val) {
                      if (val != null) settings.setWindowCloseAction(val);
                    },
                  ),
                ),
              ),
              Divider(height: 1, color: colors.divider.withValues(alpha: 0.2), indent: 48),

              // 连接方式
              ListTile(
                leading: Icon(Icons.router_outlined, color: colors.subtext, size: 20),
                title: const Text('连接方式', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  kConnectionModeLabels[settings.connectionMode] ?? '未设置',
                  style: TextStyle(color: colors.subtext, fontSize: 12),
                ),
                trailing: Icon(Icons.edit, color: colors.subtext, size: 16),
                onTap: () => _showConnectionModeSelector(context),
              ),
              Divider(height: 1, color: colors.divider.withValues(alpha: 0.2), indent: 48),

              // Host 地址
              ListTile(
                leading: Icon(Icons.dns_outlined, color: colors.subtext, size: 20),
                title: const Text('Host 地址', style: TextStyle(fontSize: 14)),
                subtitle: Text(ws.serverUrl, style: TextStyle(color: colors.subtext, fontSize: 12)),
                trailing: Icon(Icons.edit, color: colors.subtext, size: 16),
                onTap: () => _showServerUrlEditor(context),
              ),
              Divider(height: 1, color: colors.divider.withValues(alpha: 0.2), indent: 48),

              // 语音配置
              ListTile(
                leading: Icon(Icons.tune, color: colors.subtext, size: 20),
                title: const Text('语音配置 (TTS)', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  settings.ttsVoiceId.isEmpty ? '未设置 voice_id' : settings.ttsVoiceId,
                  style: TextStyle(color: colors.subtext, fontSize: 12),
                ),
                trailing: Icon(Icons.open_in_new, color: colors.subtext, size: 16),
                onTap: () {
                  showDialog<void>(
                    context: context,
                    builder: (_) => const VoiceSettingsScreen(showAsDialog: true),
                  );
                },
              ),
              Divider(height: 1, color: colors.divider.withValues(alpha: 0.2), indent: 48),

              // 打开日志目录
              ListTile(
                leading: Icon(Icons.folder_open, color: colors.subtext, size: 20),
                title: const Text('打开日志目录', style: TextStyle(fontSize: 14)),
                subtitle: Text(
                  bootstrap.logDirectoryPath ?? '日志目录尚未初始化',
                  style: TextStyle(color: colors.subtext, fontSize: 12),
                ),
                trailing: Icon(Icons.open_in_new, color: colors.subtext, size: 16),
                onTap: bootstrap.openLogDirectory,
              ),
            ],
          ),
        ),
      ],
    );
  }
}
