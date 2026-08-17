import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ws_service.dart';

/// 技能中心 (Skill Center) 管理页面
class SkillScreen extends StatefulWidget {
  final bool showAsDialog;

  const SkillScreen({super.key, this.showAsDialog = false});

  /// 以模态对话框形式展示技能中心
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => const Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        child: SizedBox(
          width: 720,
          height: 640,
          child: SkillScreen(showAsDialog: true),
        ),
      ),
    );
  }

  @override
  State<SkillScreen> createState() => _SkillScreenState();
}

class _SkillScreenState extends State<SkillScreen> {
  List<Map<String, dynamic>> _skills = [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    _loadSkills();
  }

  Future<void> _loadSkills() async {
    setState(() => _loading = true);
    final ws = context.read<WsService>();
    final list = await ws.getSkills();
    if (!mounted) return;
    setState(() {
      _skills = list;
      _loading = false;
    });
  }

  IconData _getIconData(String iconName) {
    switch (iconName.toLowerCase()) {
      case 'code':
        return Icons.code;
      case 'today':
      case 'calendar':
        return Icons.calendar_today;
      case 'search':
        return Icons.search;
      case 'edit':
        return Icons.edit_note;
      case 'terminal':
        return Icons.terminal;
      default:
        return Icons.extension;
    }
  }

  void _showRunSkillDialog(Map<String, dynamic> skill) {
    final skillName = skill['name'] as String? ?? '';
    final paramsSchema = skill['params'] as List<dynamic>? ?? [];
    final paramControllers = <String, TextEditingController>{};

    for (final p in paramsSchema) {
      if (p is Map) {
        final pName = p['name'] as String? ?? '';
        paramControllers[pName] = TextEditingController();
      }
    }

    showDialog(
      context: context,
      builder: (ctx) => AlertDialog(
        title: Row(
          children: [
            Icon(_getIconData(skill['icon'] ?? ''), color: Theme.of(context).colorScheme.primary),
            const SizedBox(width: 8),
            Text('运行技能: $skillName'),
          ],
        ),
        content: SizedBox(
          width: 460,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  skill['description'] ?? '',
                  style: TextStyle(
                    fontSize: 13,
                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                  ),
                ),
                const SizedBox(height: 16),
                if (paramsSchema.isEmpty)
                  const Text('该技能无需参数，点击「立即执行」直接触发。')
                else
                  ...paramsSchema.map((p) {
                    if (p is! Map) return const SizedBox.shrink();
                    final pName = p['name'] as String? ?? '';
                    final desc = p['description'] as String? ?? '';
                    final required = p['required'] == true;
                    final ctrl = paramControllers[pName]!;

                    return Padding(
                      padding: const EdgeInsets.only(bottom: 14),
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(pName, style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 13)),
                              if (required)
                                const Text(' *', style: TextStyle(color: Colors.red, fontWeight: FontWeight.bold)),
                            ],
                          ),
                          const SizedBox(height: 4),
                          TextField(
                            controller: ctrl,
                            decoration: InputDecoration(
                              hintText: desc.isNotEmpty ? desc : '输入 $pName',
                              border: const OutlineInputBorder(),
                              contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
                            ),
                          ),
                        ],
                      ),
                    );
                  }),
              ],
            ),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton.icon(
            icon: const Icon(Icons.play_arrow, size: 18),
            label: const Text('立即执行'),
            onPressed: () {
              final params = <String, dynamic>{};
              for (final entry in paramControllers.entries) {
                final text = entry.value.text.trim();
                if (text.isNotEmpty) {
                  params[entry.key] = text;
                }
              }
              Navigator.pop(ctx); // 关闭弹窗
              Navigator.pop(context); // 返回主聊天界面

              // 触发带有技能的工作流消息
              final ws = context.read<WsService>();
              ws.sendMessage(
                '',
                skillName: skillName,
                skillParams: params,
              );
            },
          ),
        ],
      ),
    );
  }

  void _showInstallSkillDialog() {
    final urlCtrl = TextEditingController();
    bool installing = false;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.download_for_offline_outlined),
                SizedBox(width: 8),
                Text('安装新技能'),
              ],
            ),
            content: SizedBox(
              width: 440,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('输入包含 skill.yaml 的 Git 仓库地址：'),
                  const SizedBox(height: 12),
                  TextField(
                    controller: urlCtrl,
                    decoration: const InputDecoration(
                      hintText: 'https://github.com/user/my-lumi-skill.git',
                      border: OutlineInputBorder(),
                      prefixIcon: Icon(Icons.link),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: installing ? null : () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: installing
                    ? null
                    : () async {
                        final url = urlCtrl.text.trim();
                        if (url.isEmpty) return;
                        setDialogState(() => installing = true);
                        final ws = this.context.read<WsService>();
                        final messenger = ScaffoldMessenger.of(this.context);
                        final ok = await ws.installSkill(url);
                        if (!mounted) return;
                        if (ctx.mounted) {
                          Navigator.pop(ctx);
                        }
                        if (ok) {
                          messenger.showSnackBar(
                            const SnackBar(content: Text('技能安装成功！')),
                          );
                          _loadSkills();
                        } else {
                          messenger.showSnackBar(
                            const SnackBar(
                              content: Text('安装失败，请检查 Git 仓库地址及网络'),
                              backgroundColor: Colors.red,
                            ),
                          );
                        }
                      },
                child: installing
                    ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                    : const Text('安装'),
              ),
            ],
          );
        },
      ),
    );
  }

  Future<void> _uninstallSkill(String skillName) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('卸载技能'),
        content: Text('确认卸载技能「$skillName」？此操作将删除其本地模板文件。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('卸载'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final ws = context.read<WsService>();
      final ok = await ws.uninstallSkill(skillName);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已卸载 $skillName')),
        );
        _loadSkills();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.showAsDialog,
        leading: widget.showAsDialog
            ? const Padding(
                padding: EdgeInsets.only(left: 12.0),
                child: Icon(Icons.bolt_outlined),
              )
            : null,
        title: const Text('技能中心 (Skills)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loadSkills,
          ),
          IconButton(
            icon: const Icon(Icons.add_box_outlined),
            tooltip: '从 Git 安装技能',
            onPressed: _showInstallSkillDialog,
          ),
          if (widget.showAsDialog)
            IconButton(
              icon: const Icon(Icons.close),
              tooltip: '关闭',
              onPressed: () => Navigator.of(context).pop(),
            ),
          const SizedBox(width: 8),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _skills.isEmpty
              ? _buildEmptyState()
              : ListView.builder(
                  padding: const EdgeInsets.all(16),
                  itemCount: _skills.length,
                  itemBuilder: (context, index) {
                    final skill = _skills[index];
                    final name = (skill['name'] ?? '').toString();
                    final version = (skill['version'] ?? '1.0.0').toString();
                    final author = (skill['author'] ?? 'Lumi').toString();
                    final desc = (skill['description'] ?? '').toString();
                    final icon = (skill['icon'] ?? 'extension').toString();
                    final requiresTools = skill['requires_tools'] as List<dynamic>? ?? [];
                    final requiresMcp = skill['requires_mcp'] as List<dynamic>? ?? [];

                    return Card(
                      margin: const EdgeInsets.only(bottom: 12),
                      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
                      elevation: 1.5,
                      child: Padding(
                        padding: const EdgeInsets.all(16),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                CircleAvatar(
                                  radius: 22,
                                  backgroundColor: Theme.of(context).colorScheme.primaryContainer,
                                  child: Icon(_getIconData(icon), color: Theme.of(context).colorScheme.onPrimaryContainer),
                                ),
                                const SizedBox(width: 14),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            name,
                                            style: const TextStyle(fontWeight: FontWeight.bold, fontSize: 16),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                            decoration: BoxDecoration(
                                              color: Theme.of(context).colorScheme.surfaceContainerHighest,
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              'v$version',
                                              style: TextStyle(
                                                fontSize: 11,
                                                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.7),
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 4),
                                      Text(
                                        '作者: $author',
                                        style: TextStyle(
                                          fontSize: 12,
                                          color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                                FilledButton.tonalIcon(
                                  icon: const Icon(Icons.play_arrow, size: 16),
                                  label: const Text('运行'),
                                  onPressed: () => _showRunSkillDialog(skill),
                                ),
                                const SizedBox(width: 4),
                                PopupMenuButton<String>(
                                  icon: const Icon(Icons.more_vert),
                                  onSelected: (val) {
                                    if (val == 'uninstall') {
                                      _uninstallSkill(name);
                                    }
                                  },
                                  itemBuilder: (ctx) => [
                                    const PopupMenuItem(
                                      value: 'uninstall',
                                      child: Row(
                                        children: [
                                          Icon(Icons.delete_outline, color: Colors.red, size: 18),
                                          SizedBox(width: 8),
                                          Text('卸载技能', style: TextStyle(color: Colors.red)),
                                        ],
                                      ),
                                    ),
                                  ],
                                ),
                              ],
                            ),
                            const SizedBox(height: 12),
                            Text(
                              desc,
                              style: TextStyle(
                                fontSize: 13.5,
                                height: 1.4,
                                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.85),
                              ),
                            ),
                            if (requiresTools.isNotEmpty || requiresMcp.isNotEmpty) ...[
                              const SizedBox(height: 10),
                              Wrap(
                                spacing: 6,
                                runSpacing: 4,
                                children: [
                                  ...requiresTools.map(
                                    (t) => Chip(
                                      visualDensity: VisualDensity.compact,
                                      avatar: const Icon(Icons.build, size: 12),
                                      label: Text(t.toString(), style: const TextStyle(fontSize: 11)),
                                    ),
                                  ),
                                  ...requiresMcp.map(
                                    (m) => Chip(
                                      visualDensity: VisualDensity.compact,
                                      avatar: const Icon(Icons.hub_outlined, size: 12),
                                      label: Text('MCP: $m', style: const TextStyle(fontSize: 11)),
                                    ),
                                  ),
                                ],
                              ),
                            ],
                          ],
                        ),
                      ),
                    );
                  },
                ),
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.extension_off_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无安装的技能',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          const Text('点击右上角从 Git 仓库安装技能。'),
        ],
      ),
    );
  }
}
