// ignore_for_file: deprecated_member_use
part of 'chat_screen.dart';

// ─── 顶部导航栏 (面包屑 + 人格胶囊选择器 + 展台开关) ─────────────────────────

class _TopBar extends StatelessWidget {
  final LumiColors colors;
  final WsService ws;
  final String activePersonaId;
  final bool isSelectionMode;
  final int selectedCount;
  final VoidCallback onCancelSelection;
  final VoidCallback onDeleteSelected;
  final VoidCallback? onOpenSidebar;
  final bool isSidebarOpen;
  final VoidCallback? onToggleLive2d;
  final bool isLive2dOpen;

  const _TopBar({
    required this.colors,
    required this.ws,
    required this.activePersonaId,
    this.isSelectionMode = false,
    this.selectedCount = 0,
    required this.onCancelSelection,
    required this.onDeleteSelected,
    this.onOpenSidebar,
    this.isSidebarOpen = false,
    this.onToggleLive2d,
    this.isLive2dOpen = false,
  });

  void _showPersonaMenu(BuildContext buttonContext, BuildContext context) async {
    final box = buttonContext.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(0, box.size.height + 6));
    final personas = ws.personas;

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 160, pos.dy + 200),
      color: colors.inputBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.divider),
      ),
      items: personas.map((p) {
        final id = p['id'] as String? ?? '';
        final isCur = id == activePersonaId;
        return PopupMenuItem<String>(
          value: id,
          child: Row(
            children: [
              Icon(
                isCur ? Icons.check_circle_rounded : Icons.radio_button_unchecked_rounded,
                size: 16,
                color: isCur ? colors.accent : colors.subtext,
              ),
              const SizedBox(width: 8),
              Text(
                id,
                style: TextStyle(
                  fontWeight: isCur ? FontWeight.w600 : FontWeight.normal,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
            ],
          ),
        );
      }).toList(),
    );

    if (selected != null && selected.isNotEmpty) {
      if (ws.activeSessionId != null) {
        ws.updateSessionPersona(ws.activeSessionId!, selected);
      } else {
        ws.switchPersona(selected);
      }
    }
  }

  void _showWorkspaceMenu(BuildContext buttonContext, BuildContext context) async {
    final box = buttonContext.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(0, box.size.height + 6));
    final workspaces = ws.recentWorkspaces;

    final items = <PopupMenuEntry<String>>[];
    for (final p in workspaces) {
      final name = p.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last;
      final isCur = p == ws.activeWorkspacePath;
      items.add(
        PopupMenuItem<String>(
          value: p,
          child: Row(
            children: [
              Icon(
                Icons.folder_rounded,
                size: 16,
                color: isCur ? colors.accent : colors.subtext,
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  name,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontWeight: isCur ? FontWeight.w600 : FontWeight.normal,
                    color: isCur ? colors.accent : Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ),
            ],
          ),
        ),
      );
    }

    if (items.isNotEmpty) {
      items.add(const PopupMenuDivider());
    }

    items.add(
      const PopupMenuItem<String>(
        value: '__pick_new__',
        child: Row(
          children: [
            Icon(Icons.create_new_folder_outlined, size: 16),
            SizedBox(width: 8),
            Text('打开其他项目文件夹...'),
          ],
        ),
      ),
    );

    final selected = await showMenu<String>(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 220, pos.dy + 300),
      color: colors.inputBg,
      shape: RoundedRectangleBorder(
        borderRadius: BorderRadius.circular(12),
        side: BorderSide(color: colors.divider),
      ),
      items: items,
    );

    if (selected == '__pick_new__') {
      final picked = await FilePicker.platform.getDirectoryPath(
        dialogTitle: '选择项目工作区文件夹',
      );
      if (picked != null && picked.isNotEmpty) {
        await ws.addWorkspace(picked);
      }
    } else if (selected != null && selected.isNotEmpty) {
      ws.setActiveWorkspace(selected);
    }
  }

  @override
  Widget build(BuildContext context) {
    if (isSelectionMode) {
      return SafeArea(
        bottom: false,
        child: Container(
          height: 52,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          color: colors.sidebar,
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.close, color: colors.subtext),
                onPressed: onCancelSelection,
                tooltip: '取消多选',
              ),
              const SizedBox(width: 8),
              Text(
                '已选择 $selectedCount 项',
                style: TextStyle(
                  fontSize: 15,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              if (selectedCount > 0)
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('删除消息'),
                        content: Text('确定要删除选中的 $selectedCount 条消息吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              onDeleteSelected();
                            },
                            child: const Text(
                              '删除',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  tooltip: '删除选中项',
                ),
            ],
          ),
        ),
      );
    }

    // 工作区与会话标题提取
    final wsPath = ws.activeWorkspacePath;
    final wsName = wsPath.isNotEmpty
        ? wsPath.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last
        : 'Lumi-Hub';

    final activeSession = ws.sessions.firstWhere(
      (s) => s['id'] == ws.activeSessionId,
      orElse: () => <String, dynamic>{},
    );
    final sessionTitle = (activeSession['title'] as String?)?.trim() ?? '新对话';

    return SafeArea(
      bottom: false,
      child: Container(
        height: 52,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            if (onOpenSidebar != null && !isSidebarOpen) ...[
              IconButton(
                icon: Icon(
                  Icons.view_sidebar_outlined,
                  color: colors.subtext,
                  size: 20,
                ),
                onPressed: onOpenSidebar,
                tooltip: '展开侧边栏',
                splashRadius: 18,
              ),
              const SizedBox(width: 4),
            ],

            // ── 工作区 / 会话 面包屑 ──
            Builder(
              builder: (btnCtx) => InkWell(
                borderRadius: BorderRadius.circular(8),
                hoverColor: colors.accent.withValues(alpha: 0.08),
                onTap: () => _showWorkspaceMenu(btnCtx, context),
                child: Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 4),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_rounded, size: 16, color: colors.accent),
                      const SizedBox(width: 6),
                      Text(
                        wsName,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 2),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 15,
                        color: colors.subtext,
                      ),
                    ],
                  ),
                ),
              ),
            ),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Text(
                '/',
                style: TextStyle(
                  fontSize: 13,
                  color: colors.subtext.withValues(alpha: 0.4),
                ),
              ),
            ),
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Text(
                sessionTitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w500,
                  color: colors.subtext,
                ),
              ),
            ),

            const Spacer(),

            // ── 人格切换胶囊按钮 (✨ 人格名 ▾) ──
            Builder(
              builder: (btnCtx) => InkWell(
                borderRadius: BorderRadius.circular(16),
                hoverColor: colors.accent.withValues(alpha: 0.08),
                onTap: () => _showPersonaMenu(btnCtx, context),
                child: Container(
                  padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
                  decoration: BoxDecoration(
                    color: colors.inputBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(
                      color: colors.divider.withValues(alpha: 0.5),
                    ),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 13, color: colors.accent),
                      const SizedBox(width: 6),
                      Text(
                        activePersonaId.isNotEmpty ? activePersonaId : '默认助手',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                      const SizedBox(width: 3),
                      Icon(
                        Icons.keyboard_arrow_down_rounded,
                        size: 15,
                        color: colors.subtext,
                      ),
                    ],
                  ),
                ),
              ),
            ),

            const SizedBox(width: 8),

            // ── 角色展台开关 ──
            if (onToggleLive2d != null)
              IconButton(
                icon: Icon(
                  Icons.face_retouching_natural,
                  size: 20,
                  color: isLive2dOpen ? colors.accent : colors.subtext,
                ),
                onPressed: onToggleLive2d,
                tooltip: isLive2dOpen ? '收起角色展台' : '展开角色展台',
                splashRadius: 18,
              ),
          ],
        ),
      ),
    );
  }
}
