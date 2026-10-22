part of 'chat_screen.dart';

class _Sidebar extends StatefulWidget {
  final LumiColors colors;
  final WsService ws;
  final VoidCallback? onPersonaSelected;
  final VoidCallback? onToggleCollapse;

  const _Sidebar({
    required this.colors,
    required this.ws,
    this.onPersonaSelected,
    this.onToggleCollapse,
  });

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  final Set<String> _expandedWorkspaces = {};
  String _lastActiveWs = '';

  @override
  void initState() {
    super.initState();
    // 默认展开当前激活工作区
    _lastActiveWs = widget.ws.activeWorkspacePath;
    if (_lastActiveWs.isNotEmpty) {
      _expandedWorkspaces.add(_lastActiveWs);
    }
  }

  String _getWorkspaceName(String path) {
    if (path.isEmpty) return '默认工作区';
    final parts = path.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).toList();
    return parts.isNotEmpty ? parts.last : path;
  }

  String _formatRelativeTime(dynamic timestamp) {
    if (timestamp == null) return '';
    final ms = timestamp is num ? timestamp.toInt() : int.tryParse(timestamp.toString()) ?? 0;
    if (ms <= 0) return '';
    final dt = DateTime.fromMillisecondsSinceEpoch(ms);
    final diff = DateTime.now().difference(dt);
    if (diff.inMinutes < 1) return '刚刚';
    if (diff.inMinutes < 60) return '${diff.inMinutes}m';
    if (diff.inHours < 24) return '${diff.inHours}h';
    if (diff.inDays < 30) return '${diff.inDays}d';
    return '${(diff.inDays / 30).floor()}mo';
  }

  Future<void> _pickAndAddWorkspace() async {
    final picked = await FilePicker.platform.getDirectoryPath(
      dialogTitle: '选择项目工作区文件夹',
    );
    if (picked != null && picked.isNotEmpty && mounted) {
      await widget.ws.addWorkspace(picked);
      setState(() {
        _expandedWorkspaces.add(picked);
      });
    }
  }

  Future<void> _confirmRemoveWorkspace(String path, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('移除工作区'),
        content: Text(
          '确定从列表中移除工作区「$name」？\n\n'
          '注意：这仅从快捷列表中移除记录，不会删除磁盘上的任何代码与工程文件。',
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: FilledButton.styleFrom(backgroundColor: Colors.redAccent),
            child: const Text('移除'),
          ),
        ],
      ),
    );
    if (ok == true && mounted) {
      await widget.ws.removeWorkspace(path);
      setState(() {
        _expandedWorkspaces.remove(path);
      });
    }
  }

  Future<void> _showRenameDialog(String sessionId, String currentTitle) async {
    final controller = TextEditingController(text: currentTitle);
    final newTitle = await showDialog<String>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('重命名会话'),
        content: TextField(
          controller: controller,
          autofocus: true,
          decoration: const InputDecoration(hintText: '输入新会话标题'),
          onSubmitted: (val) => Navigator.pop(ctx, val.trim()),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(ctx, controller.text.trim()),
            child: const Text('保存'),
          ),
        ],
      ),
    );
    if (newTitle != null && newTitle.isNotEmpty) {
      widget.ws.updateSessionTitle(sessionId, newTitle);
    }
  }

  Future<void> _confirmDeleteSession(String sessionId, String title) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除会话'),
        content: Text('确认删除会话「$title」？\n此操作将删除该会话下的所有聊天记录且不可恢复。'),
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
      widget.ws.deleteSession(sessionId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final ws = widget.ws;
    final recentWorkspaces = ws.recentWorkspaces;
    final activeWs = ws.activeWorkspacePath;

    // 当切换到新的工作区时，自动展开该新工作区（但不覆盖用户主动折叠当前工作区的操作）
    if (activeWs.isNotEmpty && activeWs != _lastActiveWs) {
      _lastActiveWs = activeWs;
      _expandedWorkspaces.add(activeWs);
    }

    return Container(
      width: 270,
      decoration: BoxDecoration(
        color: colors.sidebar,
        border: Border(
          right: BorderSide(color: colors.divider.withValues(alpha: 0.6)),
        ),
      ),
      child: Column(
        children: [
          // ── 顶部 Logo 与折叠按钮 (仿 Antigravity & DSH) ──
          Container(
            height: 52,
            padding: const EdgeInsets.symmetric(horizontal: 14),
            alignment: Alignment.centerLeft,
            child: Row(
              children: [
                Icon(Icons.auto_awesome, size: 20, color: colors.accent),
                const SizedBox(width: 8),
                Text(
                  'Lumi Hub',
                  style: TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.3,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                const SizedBox(width: 6),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                  decoration: BoxDecoration(
                    color: colors.accent.withValues(alpha: 0.15),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '预览版',
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 10,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                const Spacer(),
                if (widget.onToggleCollapse != null)
                  IconButton(
                    icon: Icon(
                      Icons.view_sidebar_outlined,
                      size: 19,
                      color: colors.subtext,
                    ),
                    tooltip: '收起侧边栏',
                    splashRadius: 16,
                    onPressed: widget.onToggleCollapse,
                  ),
              ],
            ),
          ),

          // ── + 新建对话 按钮 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 10),
            child: SizedBox(
              width: double.infinity,
              height: 38,
              child: FilledButton.icon(
                onPressed: ws.status == WsStatus.connected
                    ? () {
                        ws.createSession(workspacePath: ws.activeWorkspacePath);
                        widget.onPersonaSelected?.call();
                      }
                    : null,
                icon: const Icon(Icons.add_rounded, size: 18),
                label: const Text(
                  '新建对话',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
                ),
                style: FilledButton.styleFrom(
                  backgroundColor: colors.accent,
                  foregroundColor: Colors.white,
                  elevation: 0,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                ),
              ),
            ),
          ),

          Divider(height: 1, color: colors.divider),

          // ── 工作区项目标题栏 ──
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 8, 4),
            child: Row(
              children: [
                Text(
                  '工作区',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.bold,
                    letterSpacing: 0.5,
                    color: colors.subtext.withValues(alpha: 0.8),
                  ),
                ),
                const Spacer(),
                IconButton(
                  icon: const Icon(Icons.create_new_folder_outlined, size: 17),
                  tooltip: '打开项目工作区文件夹',
                  color: colors.subtext,
                  splashRadius: 14,
                  onPressed: _pickAndAddWorkspace,
                ),
              ],
            ),
          ),

          // ── 工作区与会话折叠树 ──
          Expanded(
            child: recentWorkspaces.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 20),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.folder_open_rounded,
                            size: 36,
                            color: colors.subtext.withValues(alpha: 0.5),
                          ),
                          const SizedBox(height: 8),
                          Text(
                            '暂无工作区',
                            style: TextStyle(color: colors.subtext, fontSize: 13),
                          ),
                          const SizedBox(height: 4),
                          TextButton(
                            onPressed: _pickAndAddWorkspace,
                            child: const Text('打开文件夹...', style: TextStyle(fontSize: 12)),
                          ),
                        ],
                      ),
                    ),
                  )
                : ListView.builder(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: recentWorkspaces.length,
                    itemBuilder: (context, wsIndex) {
                      final wsPath = recentWorkspaces[wsIndex];
                      final wsName = _getWorkspaceName(wsPath);
                      final isCurrentWs = wsPath == activeWs;
                      final isExpanded = _expandedWorkspaces.contains(wsPath);
                      final wsSessions = ws.sessions.where((s) {
                        final p = s['workspace_path'] as String? ?? '';
                        return p == wsPath || (p.isEmpty && isCurrentWs);
                      }).toList();

                      return Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          // 工作区标题行（悬浮菜单 + 平滑动画旋转箭头）
                          _WorkspaceTileHeader(
                            wsPath: wsPath,
                            wsName: wsName,
                            isCurrentWs: isCurrentWs,
                            isExpanded: isExpanded,
                            colors: colors,
                            onTap: () {
                              if (!isCurrentWs) {
                                ws.setActiveWorkspace(wsPath);
                                setState(() {
                                  _expandedWorkspaces.add(wsPath);
                                });
                              } else {
                                setState(() {
                                  if (isExpanded) {
                                    _expandedWorkspaces.remove(wsPath);
                                  } else {
                                    _expandedWorkspaces.add(wsPath);
                                  }
                                });
                              }
                            },
                            onToggleExpand: () {
                              setState(() {
                                if (isExpanded) {
                                  _expandedWorkspaces.remove(wsPath);
                                } else {
                                  _expandedWorkspaces.add(wsPath);
                                }
                              });
                            },
                            onCreateSession: () {
                              ws.setActiveWorkspace(wsPath);
                              ws.createSession(workspacePath: wsPath);
                              widget.onPersonaSelected?.call();
                            },
                            onRemoveWorkspace: () => _confirmRemoveWorkspace(wsPath, wsName),
                          ),

                          // 平滑高度过渡的展开会话列表 (AnimatedSize)
                          AnimatedSize(
                            duration: const Duration(milliseconds: 220),
                            curve: Curves.easeInOutCubic,
                            alignment: Alignment.topCenter,
                            child: isExpanded
                                ? (wsSessions.isEmpty
                                    ? Padding(
                                        padding: const EdgeInsets.only(left: 36, top: 4, bottom: 6),
                                        child: Text(
                                          '无活跃会话',
                                          style: TextStyle(
                                            color: colors.subtext.withValues(alpha: 0.6),
                                            fontSize: 11.5,
                                          ),
                                        ),
                                      )
                                    : Column(
                                        mainAxisSize: MainAxisSize.min,
                                        children: wsSessions.map((sess) {
                                          final sid = sess['id'] as String? ?? '';
                                          final stitle = sess['title'] as String? ?? '新对话';
                                          final isActive = sid == ws.activeSessionId;
                                          final timeStr = _formatRelativeTime(sess['updated_at']);

                                          return _SessionTileItem(
                                            sessionId: sid,
                                            title: stitle,
                                            timeTag: timeStr,
                                            isSelected: isActive,
                                            colors: colors,
                                            onTap: () {
                                              ws.switchSession(sid);
                                              widget.onPersonaSelected?.call();
                                            },
                                            onRename: () => _showRenameDialog(sid, stitle),
                                            onDelete: () => _confirmDeleteSession(sid, stitle),
                                          );
                                        }).toList(),
                                      ))
                                : const SizedBox.shrink(),
                          ),
                        ],
                      );
                    },
                  ),
          ),

          Divider(height: 1, color: colors.divider),
          const SizedBox(height: 8),

          // ── 扩展与技能中心入口 (Skills + MCP) ──
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            child: InkWell(
              borderRadius: BorderRadius.circular(10),
              hoverColor: colors.accent.withValues(alpha: 0.08),
              onTap: () => ExtensionCenterDialog.show(context),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 8, horizontal: 10),
                decoration: BoxDecoration(
                  color: colors.inputBg,
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: colors.divider.withValues(alpha: 0.15),
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.extension_outlined,
                      size: 17,
                      color: colors.accent,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      '扩展与技能',
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: Theme.of(context).colorScheme.onSurface,
                      ),
                    ),
                    const Spacer(),
                    Container(
                      padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 1.5),
                      decoration: BoxDecoration(
                        color: colors.accent.withValues(alpha: 0.1),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        'Skills & MCP',
                        style: TextStyle(
                          fontSize: 10,
                          fontWeight: FontWeight.w500,
                          color: colors.accent,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
          const SizedBox(height: 6),

          // ── 统一设置中心入口 ──
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

// ─── 工作区行组件（支持悬浮操作菜单与平滑旋转箭头） ─────────────────────────
class _WorkspaceTileHeader extends StatefulWidget {
  final String wsPath;
  final String wsName;
  final bool isCurrentWs;
  final bool isExpanded;
  final LumiColors colors;
  final VoidCallback onTap;
  final VoidCallback onToggleExpand;
  final VoidCallback onCreateSession;
  final VoidCallback onRemoveWorkspace;

  const _WorkspaceTileHeader({
    required this.wsPath,
    required this.wsName,
    required this.isCurrentWs,
    required this.isExpanded,
    required this.colors,
    required this.onTap,
    required this.onToggleExpand,
    required this.onCreateSession,
    required this.onRemoveWorkspace,
  });

  @override
  State<_WorkspaceTileHeader> createState() => _WorkspaceTileHeaderState();
}

class _WorkspaceTileHeaderState extends State<_WorkspaceTileHeader> {
  bool _isHovered = false;

  void _showMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(box.size.width, 0));

    await showMenu(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      color: widget.colors.inputBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: widget.colors.divider),
      ),
      items: [
        PopupMenuItem(
          onTap: widget.onCreateSession,
          child: Row(
            children: [
              Icon(Icons.add_comment_outlined, size: 16, color: widget.colors.subtext),
              const SizedBox(width: 8),
              const Text('新建此工作区对话'),
            ],
          ),
        ),
        PopupMenuItem(
          onTap: widget.onRemoveWorkspace,
          child: const Row(
            children: [
              Icon(Icons.folder_delete_outlined, size: 16, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('从列表中移除工作区', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final isCurrentWs = widget.isCurrentWs;
    final isExpanded = widget.isExpanded;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: Container(
        margin: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
        decoration: BoxDecoration(
          color: isCurrentWs && !isExpanded
              ? colors.accent.withValues(alpha: 0.08)
              : (_isHovered ? colors.accent.withValues(alpha: 0.04) : Colors.transparent),
          borderRadius: BorderRadius.circular(8),
        ),
        child: Row(
          children: [
            // ── 折叠/展开箭头图标 (专门可点击区域，旋转动画) ──
            InkWell(
              borderRadius: BorderRadius.circular(4),
              hoverColor: colors.accent.withValues(alpha: 0.12),
              onTap: widget.onToggleExpand,
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 5, vertical: 6),
                child: AnimatedRotation(
                  turns: isExpanded ? 0.25 : 0.0,
                  duration: const Duration(milliseconds: 200),
                  curve: Curves.easeInOutCubic,
                  child: Icon(
                    Icons.chevron_right_rounded,
                    size: 16,
                    color: isCurrentWs ? colors.accent : colors.subtext,
                  ),
                ),
              ),
            ),
            // ── 工作区图标与名称 (点击切换当前工作区 / 或在当前工作区时折叠展开) ──
            Expanded(
              child: InkWell(
                borderRadius: BorderRadius.circular(6),
                onTap: widget.onTap,
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 6, horizontal: 2),
                  child: Row(
                    children: [
                      Icon(
                        isExpanded ? Icons.folder_open_rounded : Icons.folder_rounded,
                        size: 16,
                        color: isCurrentWs ? colors.accent : colors.subtext,
                      ),
                      const SizedBox(width: 7),
                      Expanded(
                        child: Text(
                          widget.wsName,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            fontSize: 13,
                            fontWeight: isCurrentWs ? FontWeight.bold : FontWeight.w500,
                            color: isCurrentWs
                                ? Theme.of(context).colorScheme.onSurface
                                : colors.subtext,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            // ── 更多操作按钮 (···) ──
            AnimatedOpacity(
              duration: const Duration(milliseconds: 150),
              opacity: _isHovered ? 1.0 : 0.0,
              child: IgnorePointer(
                ignoring: !_isHovered,
                child: Builder(
                  builder: (btnCtx) => InkWell(
                    borderRadius: BorderRadius.circular(4),
                    onTap: () => _showMenu(btnCtx),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                      child: Icon(Icons.more_horiz_rounded, size: 16, color: colors.subtext),
                    ),
                  ),
                ),
              ),
            ),
            const SizedBox(width: 4),
          ],
        ),
      ),
    );
  }
}

// ─── 会话项目条目组件 ────────────────────────────────────────────────────────
class _SessionTileItem extends StatefulWidget {
  final String sessionId;
  final String title;
  final String timeTag;
  final bool isSelected;
  final LumiColors colors;
  final VoidCallback onTap;
  final VoidCallback onRename;
  final VoidCallback onDelete;

  const _SessionTileItem({
    required this.sessionId,
    required this.title,
    required this.timeTag,
    required this.isSelected,
    required this.colors,
    required this.onTap,
    required this.onRename,
    required this.onDelete,
  });

  @override
  State<_SessionTileItem> createState() => _SessionTileItemState();
}

class _SessionTileItemState extends State<_SessionTileItem> {
  bool _isHovered = false;

  void _showMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(box.size.width, 0));

    await showMenu(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      color: widget.colors.inputBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(10),
        side: BorderSide(color: widget.colors.divider),
      ),
      items: [
        PopupMenuItem(
          onTap: widget.onRename,
          child: Row(
            children: [
              Icon(Icons.edit_outlined, size: 16, color: widget.colors.subtext),
              const SizedBox(width: 8),
              const Text('重命名会话'),
            ],
          ),
        ),
        PopupMenuItem(
          onTap: widget.onDelete,
          child: const Row(
            children: [
              Icon(Icons.delete_outline_rounded, size: 16, color: Colors.redAccent),
              SizedBox(width: 8),
              Text('删除会话', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final isSelected = widget.isSelected;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 150),
        curve: Curves.easeOut,
        margin: const EdgeInsets.only(left: 18, right: 8, top: 1, bottom: 1),
        decoration: BoxDecoration(
          color: isSelected
              ? colors.accent.withValues(alpha: 0.15)
              : (_isHovered
                  ? colors.accent.withValues(alpha: 0.06)
                  : Colors.transparent),
          borderRadius: BorderRadius.circular(8),
          border: Border.all(
            color: isSelected
                ? colors.accent.withValues(alpha: 0.3)
                : Colors.transparent,
          ),
        ),
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: widget.onTap,
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
            child: Row(
              children: [
                Icon(
                  isSelected ? Icons.chat_bubble_rounded : Icons.chat_bubble_outline_rounded,
                  size: 13,
                  color: isSelected ? colors.accent : colors.subtext.withValues(alpha: 0.6),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    widget.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: isSelected ? FontWeight.w600 : FontWeight.w400,
                      color: isSelected
                          ? Theme.of(context).colorScheme.onSurface
                          : colors.subtext,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                SizedBox(
                  width: 38,
                  child: Stack(
                    alignment: Alignment.centerRight,
                    children: [
                      if (widget.timeTag.isNotEmpty)
                        AnimatedOpacity(
                          duration: const Duration(milliseconds: 150),
                          opacity: _isHovered ? 0.0 : 1.0,
                          child: Text(
                            widget.timeTag,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 11,
                              color: colors.subtext.withValues(alpha: 0.6),
                            ),
                          ),
                        ),
                      AnimatedOpacity(
                        duration: const Duration(milliseconds: 150),
                        opacity: _isHovered ? 1.0 : 0.0,
                        child: IgnorePointer(
                          ignoring: !_isHovered,
                          child: Builder(
                            builder: (btnCtx) => InkWell(
                              borderRadius: BorderRadius.circular(4),
                              onTap: () => _showMenu(btnCtx),
                              child: Padding(
                                padding: const EdgeInsets.all(2),
                                child: Icon(Icons.more_horiz_rounded, size: 16, color: colors.subtext),
                              ),
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
