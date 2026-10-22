import 'package:flutter/material.dart';

import 'skill_screen.dart';
import 'mcp_settings_screen.dart';

/// 扩展与技能中心 (Extension & Skills Center)
/// 统一管理本地技能 (Skills) 与外挂 MCP 服务 (MCP Servers)
class ExtensionCenterDialog extends StatefulWidget {
  final int initialTab;

  const ExtensionCenterDialog({super.key, this.initialTab = 0});

  /// 以模态对话框形式展示扩展与技能中心
  static Future<void> show(BuildContext context, {int initialTab = 0}) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => Dialog(
        clipBehavior: Clip.antiAlias,
        shape: const RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        child: SizedBox(
          width: 780,
          height: 660,
          child: ExtensionCenterDialog(initialTab: initialTab),
        ),
      ),
    );
  }

  @override
  State<ExtensionCenterDialog> createState() => _ExtensionCenterDialogState();
}

class _ExtensionCenterDialogState extends State<ExtensionCenterDialog>
    with SingleTickerProviderStateMixin {
  late TabController _tabController;

  @override
  void initState() {
    super.initState();
    _tabController = TabController(
      length: 2,
      vsync: this,
      initialIndex: widget.initialTab.clamp(0, 1),
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
          child: Icon(Icons.auto_awesome),
        ),
        title: const Text('扩展与技能中心'),
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
            Tab(icon: Icon(Icons.bolt_outlined, size: 18), text: '技能与工具 (Skills)'),
            Tab(icon: Icon(Icons.hub_outlined, size: 18), text: 'MCP 服务 (MCP Servers)'),
          ],
        ),
      ),
      body: TabBarView(
        controller: _tabController,
        children: const [
          SkillScreen(embedded: true),
          McpSettingsScreen(embedded: true),
        ],
      ),
    );
  }
}
