import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ws_service.dart';

/// 记忆档案管理页面
class MemoryScreen extends StatefulWidget {
  final bool showAsDialog;

  const MemoryScreen({super.key, this.showAsDialog = false});

  /// 以模态对话框形式展示记忆档案
  static Future<void> show(BuildContext context) {
    return showDialog<void>(
      context: context,
      builder: (ctx) => const Dialog(
        clipBehavior: Clip.antiAlias,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.all(Radius.circular(16)),
        ),
        child: SizedBox(
          width: 680,
          height: 620,
          child: MemoryScreen(showAsDialog: true),
        ),
      ),
    );
  }

  @override
  State<MemoryScreen> createState() => _MemoryScreenState();
}

class _MemoryScreenState extends State<MemoryScreen> {
  String? _selectedCategory; // null = 全部
  List<Map<String, dynamic>> _memories = [];
  bool _loading = true;
  String _activePersona = 'default';

  @override
  void initState() {
    super.initState();
    _loadMemories();
  }

  Future<void> _loadMemories() async {
    setState(() => _loading = true);
    final ws = context.read<WsService>();
    _activePersona = ws.activePersonaId.isNotEmpty ? ws.activePersonaId : 'default';
    final list = await ws.getMemories(
      personaId: _activePersona,
      category: _selectedCategory,
    );
    if (!mounted) return;
    setState(() {
      _memories = list;
      _loading = false;
    });
  }

  Color _getCategoryColor(String category) {
    switch (category.toLowerCase()) {
      case 'preference':
        return Colors.blue.shade600;
      case 'fact':
        return Colors.teal.shade600;
      case 'correction':
        return Colors.amber.shade800;
      case 'summary':
        return Colors.purple.shade600;
      default:
        return Colors.indigo.shade600;
    }
  }

  String _getCategoryLabel(String category) {
    switch (category.toLowerCase()) {
      case 'preference':
        return '偏好';
      case 'fact':
        return '事实';
      case 'correction':
        return '纠错';
      case 'summary':
        return '总结';
      default:
        return category;
    }
  }

  IconData _getCategoryIcon(String category) {
    switch (category.toLowerCase()) {
      case 'preference':
        return Icons.favorite_border;
      case 'fact':
        return Icons.lightbulb_outline;
      case 'correction':
        return Icons.build_circle_outlined;
      case 'summary':
        return Icons.notes;
      default:
        return Icons.bookmark_border;
    }
  }

  Future<void> _deleteMemory(dynamic id) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除记忆'),
        content: const Text('确认删除这条记忆？删除后 Agent 将不再参考此信息。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final ws = context.read<WsService>();
      final ok = await ws.deleteMemory(id);
      if (ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('已删除该条记忆')),
        );
        _loadMemories();
      }
    }
  }

  Future<void> _clearAllMemories() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空所有记忆'),
        content: Text('确认清空「$_activePersona」人格下的所有记忆？\n此操作不可恢复。'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(ctx, false), child: const Text('取消')),
          FilledButton(
            style: FilledButton.styleFrom(backgroundColor: Colors.red),
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('全部清空'),
          ),
        ],
      ),
    );

    if (confirmed == true && mounted) {
      final ws = context.read<WsService>();
      final count = await ws.clearMemories(_activePersona);
      if (mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text('已清空 $count 条记忆')),
        );
        _loadMemories();
      }
    }
  }

  void _showAddMemoryDialog() {
    String category = 'fact';
    final contentCtrl = TextEditingController();

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          return AlertDialog(
            title: const Row(
              children: [
                Icon(Icons.add_circle_outline, size: 24),
                SizedBox(width: 8),
                Text('录入新记忆'),
              ],
            ),
            content: SizedBox(
              width: 420,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('选择记忆类别：', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 8,
                    children: [
                      _buildDialogChoiceChip('fact', '事实', category, (val) {
                        setDialogState(() => category = val);
                      }),
                      _buildDialogChoiceChip('preference', '偏好', category, (val) {
                        setDialogState(() => category = val);
                      }),
                      _buildDialogChoiceChip('correction', '纠错', category, (val) {
                        setDialogState(() => category = val);
                      }),
                      _buildDialogChoiceChip('summary', '总结', category, (val) {
                        setDialogState(() => category = val);
                      }),
                    ],
                  ),
                  const SizedBox(height: 16),
                  const Text('记忆内容：', style: TextStyle(fontWeight: FontWeight.w600)),
                  const SizedBox(height: 8),
                  TextField(
                    controller: contentCtrl,
                    maxLines: 4,
                    decoration: const InputDecoration(
                      hintText: '如：用户习惯使用 Python 3.12 并偏好以中文回复',
                      border: OutlineInputBorder(),
                    ),
                  ),
                ],
              ),
            ),
            actions: [
              TextButton(
                onPressed: () => Navigator.pop(ctx),
                child: const Text('取消'),
              ),
              FilledButton(
                onPressed: () async {
                  final text = contentCtrl.text.trim();
                  if (text.isEmpty) return;
                  final ws = this.context.read<WsService>();
                  Navigator.pop(ctx);
                  final ok = await ws.addMemory(
                    personaId: _activePersona,
                    category: category,
                    content: text,
                  );
                  if (ok && mounted) {
                    ScaffoldMessenger.of(this.context).showSnackBar(
                      const SnackBar(content: Text('记忆已添加')),
                    );
                    _loadMemories();
                  }
                },
                child: const Text('保存'),
              ),
            ],
          );
        },
      ),
    );
  }

  Widget _buildDialogChoiceChip(
    String value,
    String label,
    String current,
    ValueChanged<String> onSelected,
  ) {
    final selected = value == current;
    return ChoiceChip(
      label: Text(label),
      selected: selected,
      onSelected: (val) {
        if (val) onSelected(value);
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(
        automaticallyImplyLeading: !widget.showAsDialog,
        leading: widget.showAsDialog
            ? const Padding(
                padding: EdgeInsets.only(left: 12.0),
                child: Icon(Icons.psychology_outlined),
              )
            : null,
        title: Text('记忆档案 ($_activePersona)'),
        actions: [
          IconButton(
            icon: const Icon(Icons.refresh),
            tooltip: '刷新',
            onPressed: _loadMemories,
          ),
          IconButton(
            icon: const Icon(Icons.delete_sweep_outlined),
            tooltip: '清空此人格记忆',
            onPressed: _memories.isEmpty ? null : _clearAllMemories,
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
      body: Column(
        children: [
          // 顶部筛选 Chips
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              border: Border(
                bottom: BorderSide(
                  color: Theme.of(context).dividerColor.withValues(alpha: 0.3),
                ),
              ),
            ),
            child: SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(
                children: [
                  FilterChip(
                    label: const Text('全部'),
                    selected: _selectedCategory == null,
                    onSelected: (val) {
                      setState(() => _selectedCategory = null);
                      _loadMemories();
                    },
                  ),
                  const SizedBox(width: 8),
                  _buildFilterChip('preference', '偏好'),
                  const SizedBox(width: 8),
                  _buildFilterChip('fact', '事实'),
                  const SizedBox(width: 8),
                  _buildFilterChip('correction', '纠错'),
                  const SizedBox(width: 8),
                  _buildFilterChip('summary', '总结'),
                ],
              ),
            ),
          ),

          // 记忆列表
          Expanded(
            child: _loading
                ? const Center(child: CircularProgressIndicator())
                : _memories.isEmpty
                    ? _buildEmptyState()
                    : ListView.builder(
                        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
                        itemCount: _memories.length,
                        itemBuilder: (context, index) {
                          final mem = _memories[index];
                          final cat = (mem['category'] ?? 'fact').toString();
                          final content = (mem['content'] ?? '').toString();
                          final color = _getCategoryColor(cat);
                          final accessCount = mem['access_count'] ?? 0;

                          return Card(
                            margin: const EdgeInsets.only(bottom: 10),
                            shape: RoundedRectangleBorder(
                              borderRadius: BorderRadius.circular(10),
                              side: BorderSide(
                                color: color.withValues(alpha: 0.2),
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(14),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: [
                                  Container(
                                    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                                    decoration: BoxDecoration(
                                      color: color.withValues(alpha: 0.15),
                                      borderRadius: BorderRadius.circular(6),
                                    ),
                                    child: Row(
                                      mainAxisSize: MainAxisSize.min,
                                      children: [
                                        Icon(_getCategoryIcon(cat), size: 14, color: color),
                                        const SizedBox(width: 4),
                                        Text(
                                          _getCategoryLabel(cat),
                                          style: TextStyle(
                                            fontSize: 12,
                                            fontWeight: FontWeight.bold,
                                            color: color,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  const SizedBox(width: 12),
                                  Expanded(
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Text(
                                          content,
                                          style: const TextStyle(fontSize: 14, height: 1.4),
                                        ),
                                        const SizedBox(height: 6),
                                        Text(
                                          '调用次数: $accessCount',
                                          style: TextStyle(
                                            fontSize: 11,
                                            color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.5),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 18),
                                    tooltip: '删除',
                                    onPressed: () => _deleteMemory(mem['id']),
                                    visualDensity: VisualDensity.compact,
                                  ),
                                ],
                              ),
                            ),
                          );
                        },
                      ),
          ),
        ],
      ),
      floatingActionButton: FloatingActionButton.extended(
        onPressed: _showAddMemoryDialog,
        icon: const Icon(Icons.add),
        label: const Text('录入记忆'),
      ),
    );
  }

  Widget _buildFilterChip(String cat, String label) {
    final selected = _selectedCategory == cat;
    return FilterChip(
      label: Text(label),
      selected: selected,
      onSelected: (val) {
        setState(() => _selectedCategory = val ? cat : null);
        _loadMemories();
      },
    );
  }

  Widget _buildEmptyState() {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Icon(
            Icons.psychology_alt_outlined,
            size: 64,
            color: Theme.of(context).colorScheme.primary.withValues(alpha: 0.5),
          ),
          const SizedBox(height: 16),
          Text(
            '暂无相关记忆',
            style: Theme.of(context).textTheme.titleMedium?.copyWith(
                  fontWeight: FontWeight.bold,
                ),
          ),
          const SizedBox(height: 8),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 40),
            child: Text(
              'Agent 会在多轮对话中自动提炼你的偏好与重要事实，\n你也可以点击右下角按钮主动录入。',
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6),
              ),
            ),
          ),
        ],
      ),
    );
  }
}
