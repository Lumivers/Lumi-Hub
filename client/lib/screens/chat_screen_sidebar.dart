part of 'chat_screen.dart';

class _Sidebar extends StatefulWidget {
  final LumiColors colors;
  final WsService ws;
  final VoidCallback? onPersonaSelected;

  const _Sidebar({
    required this.colors,
    required this.ws,
    this.onPersonaSelected,
  });

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  StreamSubscription? _personaSub;
  List<String> _personaOrder = [];

  // 以 user_id 隔离侧栏排序配置，避免多账号互相覆盖。
  String _personaOrderStorageKey() {
    final uid = widget.ws.user?['id']?.toString() ?? 'guest';
    return 'persona_order_$uid';
  }

  Future<void> _loadPersonaOrder() async {
    final prefs = await SharedPreferences.getInstance();
    _personaOrder = prefs.getStringList(_personaOrderStorageKey()) ?? [];
    if (mounted) setState(() {});
  }

  Future<void> _savePersonaOrder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_personaOrderStorageKey(), _personaOrder);
  }

  List<Map<String, dynamic>> _orderedPersonas(
    List<Map<String, dynamic>> personas,
  ) {
    if (personas.isEmpty) return personas;

    final byId = {for (final p in personas) (p['id'] as String? ?? ''): p};

    // 先按本地顺序回放，再补齐新增人格。
    final ordered = <Map<String, dynamic>>[];
    final used = <String>{};

    for (final id in _personaOrder) {
      final p = byId[id];
      if (p != null) {
        ordered.add(p);
        used.add(id);
      }
    }

    for (final p in personas) {
      final id = p['id'] as String? ?? '';
      if (!used.contains(id)) {
        ordered.add(p);
      }
    }

    final newOrder = ordered
        .map((p) => p['id'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    if (newOrder.join('|') != _personaOrder.join('|')) {
      // 列表结构变更后自动回写，保持下次启动顺序一致。
      _personaOrder = newOrder;
      unawaited(_savePersonaOrder());
    }

    return ordered;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadPersonaOrder());
    // 监听人格操作响应，执行本地 UI 收口并按需刷新列表。
    _personaSub = widget.ws.personaResponses.listen((data) {
      final type = data['type'] as String? ?? '';
      final payload = data['payload'] as Map<String, dynamic>? ?? {};
      final status = payload['status'] as String? ?? '';

      if (!mounted) return;
      if (type == 'PERSONA_DELETE_RESPONSE' && status == 'success') {
        widget.ws.requestPersonaList();
      } else if (type == 'PERSONA_CLEAR_HISTORY_RESPONSE' &&
          status == 'success') {
        widget.ws.clearLocalMessages();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('聊天记录已清空')));
      } else if (type == 'PERSONA_DELETE_RESPONSE' && status == 'error') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('删除失败: ${payload['message'] ?? ''}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _personaSub?.cancel();
    super.dispose();
  }

  Future<void> _confirmClearHistory(String personaId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空聊天记录'),
        content: Text('确认清空与「$personaId」的所有聊天记录？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      widget.ws.clearPersonaHistory();
    }
  }

  Future<void> _confirmDelete(String personaId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除人格'),
        content: Text('确认删除人格「$personaId」？\n此操作不可恢复。'),
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
    if (ok == true) {
      widget.ws.deletePersona(personaId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final ws = widget.ws;
    final personas = _orderedPersonas(ws.personas);

    return Container(
      width: 260,
      color: colors.sidebar,
      child: Column(
        children: [
          // 顶部标题栏
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    'Lumi Hub',
                    style: TextStyle(
                      fontSize: 17,
                      fontWeight: FontWeight.bold,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.face_retouching_natural, color: colors.accent),
                  tooltip: '打开 Live2D 桌宠伴侣',
                  onPressed: () => Live2dCompanionScreen.open(context),
                ),
              ],
            ),
          ),
          Divider(height: 1, color: colors.divider),

          // ── 人格列表 ──
          Expanded(
            child: personas.isEmpty
                ? Center(
                    child: Text(
                      ws.status == WsStatus.connected ? '加载人格中...' : '未连接',
                      style: TextStyle(color: colors.subtext, fontSize: 12),
                    ),
                  )
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex -= 1;
                      if (oldIndex < 0 || oldIndex >= personas.length) return;
                      if (newIndex < 0 || newIndex >= personas.length) return;

                      final reordered = [...personas];
                      final item = reordered.removeAt(oldIndex);
                      reordered.insert(newIndex, item);

                      setState(() {
                        _personaOrder = reordered
                            .map((p) => p['id'] as String? ?? '')
                            .where((id) => id.isNotEmpty)
                            .toList();
                      });
                      unawaited(_savePersonaOrder());
                    },
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: personas.length,
                    itemBuilder: (context, i) {
                      final p = personas[i];
                      final id = p['id'] as String? ?? '';
                      final isActive = id == ws.activePersonaId;
                      return _PersonaTile(
                        key: ValueKey('persona_$id'),
                        personaId: id,
                        isSelected: isActive,
                        colors: colors,
                        wsStatus: ws.status,
                        dragHandle: ReorderableDragStartListener(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(
                              Icons.drag_indicator_rounded,
                              size: 18,
                              color: colors.subtext,
                            ),
                          ),
                        ),
                        onTap: () {
                          ws.switchPersona(id);
                          widget.onPersonaSelected?.call();
                        },
                        onClearHistory: () => _confirmClearHistory(id),
                        onDelete: () => _confirmDelete(id),
                      );
                    },
                  ),
          ),

          Divider(height: 1, color: colors.divider),
          const SizedBox(height: 8),

          // ── 记忆档案 + 技能中心 双格胶囊按钮 ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: Row(
              children: [
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    hoverColor: colors.accent.withValues(alpha: 0.08),
                    onTap: () => MemoryScreen.show(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                      decoration: BoxDecoration(
                        color: colors.inputBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: colors.divider.withValues(alpha: 0.15),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.psychology_outlined,
                            size: 16,
                            color: colors.accent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '记忆档案',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: InkWell(
                    borderRadius: BorderRadius.circular(10),
                    hoverColor: colors.accent.withValues(alpha: 0.08),
                    onTap: () => SkillScreen.show(context),
                    child: Container(
                      padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 8),
                      decoration: BoxDecoration(
                        color: colors.inputBg,
                        borderRadius: BorderRadius.circular(10),
                        border: Border.all(
                          color: colors.divider.withValues(alpha: 0.15),
                        ),
                      ),
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.center,
                        children: [
                          Icon(
                            Icons.bolt_outlined,
                            size: 16,
                            color: colors.accent,
                          ),
                          const SizedBox(width: 6),
                          Text(
                            '技能中心',
                            style: TextStyle(
                              fontSize: 12.5,
                              fontWeight: FontWeight.w600,
                              color: Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 6),

          // ── 统一设置中心入口 (包含 通用设置 / AI模型 / MCP扩展 / 资源包) ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
            child: ListTile(
              dense: true,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              hoverColor: colors.accent.withValues(alpha: 0.1),
              contentPadding: const EdgeInsets.symmetric(horizontal: 14),
              leading: Icon(
                Icons.settings_outlined,
                color: colors.subtext,
                size: 20,
              ),
              title: Text(
                '设置中心',
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                ),
              ),
              trailing: Icon(
                Icons.chevron_right,
                color: colors.subtext.withValues(alpha: 0.5),
                size: 18,
              ),
              onTap: () {
                SettingsHubDialog.show(
                  context,
                  ws: ws,
                  colors: colors,
                );
              },
            ),
          ),
          const SizedBox(height: 6),
        ],
      ),
    );
  }
}

// ─── 人格瓦片 ────────────────────────────────────────────────────────────────
