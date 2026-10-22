import 'dart:async';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';
import '../services/bootstrap_service.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';
import 'llm_settings_screen.dart';
import 'memory_screen.dart';
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
      length: 3,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 2),
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
            Tab(icon: Icon(Icons.psychology_outlined, size: 18), text: '长期记忆'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: [
          _GeneralSettingsTab(ws: widget.ws, colors: widget.colors),
          const LlmSettingsScreen(embedded: true),
          const MemoryScreen(embedded: true),
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
                icon: const Icon(Icons.edit, size: 16),
                label: const Text('修改称呼'),
                onPressed: () => _showEditNicknameDialog(context, ws),
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

  void _showEditNicknameDialog(BuildContext context, WsService ws) {
    final ctrl = TextEditingController(text: ws.user?['username'] ?? '');
    showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改你的称呼'),
        content: TextField(
          controller: ctrl,
          decoration: const InputDecoration(
            labelText: '称呼 / 昵称',
            hintText: '告诉流萤该怎么称呼你',
            border: OutlineInputBorder(),
          ),
          autofocus: true,
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () {
              final newName = ctrl.text.trim();
              if (newName.isNotEmpty) {
                ws.updateNickname(newName);
              }
              Navigator.of(ctx).pop();
            },
            child: const Text('保存'),
          ),
        ],
      ),
    );
  }
}
