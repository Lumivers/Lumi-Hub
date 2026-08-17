// ignore_for_file: deprecated_member_use
part of 'chat_screen.dart';

// 侧栏人格条目：展示状态、支持拖拽和快捷菜单。
class _PersonaTile extends StatefulWidget {
  final String personaId;
  final bool isSelected;
  final LumiColors colors;
  final WsStatus wsStatus;
  final Widget? dragHandle;
  final VoidCallback onTap;
  final VoidCallback onClearHistory;
  final VoidCallback onDelete;

  const _PersonaTile({
    super.key,
    required this.personaId,
    required this.isSelected,
    required this.colors,
    required this.wsStatus,
    this.dragHandle,
    required this.onTap,
    required this.onClearHistory,
    required this.onDelete,
  });

  @override
  State<_PersonaTile> createState() => _PersonaTileState();
}

class _PersonaTileState extends State<_PersonaTile> {
  bool _isHovered = false;

  String get _avatarChar {
    final id = widget.personaId;
    return id.isNotEmpty ? id[0].toUpperCase() : '?';
  }

  void _showMenu(BuildContext context) async {
    // 右上角菜单只暴露两个高频操作：清空历史、删除人格。
    final box = context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(box.size.width, 0));

    await showMenu(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      color: widget.colors.inputBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      items: [
        PopupMenuItem(
          onTap: widget.onClearHistory,
          child: Row(
            children: [
              Icon(
                Icons.delete_sweep_rounded,
                size: 18,
                color: widget.colors.subtext,
              ),
              const SizedBox(width: 10),
              const Text('清空聊天记录'),
            ],
          ),
        ),
        PopupMenuItem(
          onTap: widget.onDelete,
          child: const Row(
            children: [
              Icon(
                Icons.person_remove_rounded,
                size: 18,
                color: Colors.redAccent,
              ),
              SizedBox(width: 10),
              Text('删除人格', style: TextStyle(color: Colors.redAccent)),
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
        duration: const Duration(milliseconds: 120),
        color: isSelected
            ? colors.accent.withValues(alpha: 0.15)
            : _isHovered
            ? colors.accent.withValues(alpha: 0.06)
            : Colors.transparent,
        child: ListTile(
          contentPadding: const EdgeInsets.only(
            left: 12,
            right: 4,
            top: 2,
            bottom: 2,
          ),
          onTap: widget.onTap,
          leading: Stack(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: isSelected
                    ? colors.accent
                    : colors.accent.withValues(alpha: 0.5),
                child: Text(
                  _avatarChar,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              // 连接状态指示灯（仅激活人格显示）
              if (isSelected)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _statusColor(widget.wsStatus),
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.sidebar, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          title: Text(
            widget.personaId,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 14,
            ),
          ),
          subtitle: Text(
            isSelected ? '当前激活' : '点击切换',
            style: TextStyle(fontSize: 11, color: colors.subtext),
          ),
          trailing: AnimatedOpacity(
            opacity: _isHovered || isSelected ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.dragHandle != null) widget.dragHandle!,
                Builder(
                  builder: (ctx) => IconButton(
                    icon: Icon(
                      Icons.more_vert_rounded,
                      size: 18,
                      color: colors.subtext,
                    ),
                    tooltip: '更多操作',
                    onPressed: () => _showMenu(ctx),
                    splashRadius: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _statusColor(WsStatus s) => switch (s) {
    WsStatus.connected => const Color(0xFF4CAF50),
    WsStatus.connecting => const Color(0xFFFFC107),
    WsStatus.disconnected => const Color(0xFF9E9E9E),
  };
}


// ─── 顶部栏 ─────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final LumiColors colors;
  final WsService ws;
  final String activePersonaId;
  final bool isSelectionMode;
  final int selectedCount;
  final VoidCallback onCancelSelection;
  final VoidCallback onDeleteSelected;
  final VoidCallback? onOpenSidebar;
  final VoidCallback? onToggleLive2d;
  final bool isLive2dOpen;
  final VoidCallback? onOpenCompanion;

  const _TopBar({
    required this.colors,
    required this.ws,
    required this.activePersonaId,
    this.isSelectionMode = false,
    this.selectedCount = 0,
    required this.onCancelSelection,
    required this.onDeleteSelected,
    this.onOpenSidebar,
    this.onToggleLive2d,
    this.isLive2dOpen = false,
    this.onOpenCompanion,
  });

  @override
  Widget build(BuildContext context) {
    if (isSelectionMode) {
      return SafeArea(
        bottom: false,
        child: Container(
          height: 56,
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
                  fontSize: 16,
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

    final statusText = switch (ws.status) {
      WsStatus.connected => '在线',
      WsStatus.connecting => '连接中...',
      WsStatus.disconnected => '未连接',
    };
    final statusColor = switch (ws.status) {
      WsStatus.connected => const Color(0xFF4CAF50),
      WsStatus.connecting => const Color(0xFFFFC107),
      WsStatus.disconnected => const Color(0xFF9E9E9E),
    };

    return SafeArea(
      bottom: false,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            if (onOpenSidebar != null) ...[
              IconButton(
                icon: Icon(Icons.menu_rounded, color: colors.subtext),
                onPressed: onOpenSidebar,
                tooltip: '打开侧边栏',
              ),
              const SizedBox(width: 4),
            ],
            CircleAvatar(
              radius: 18,
              backgroundColor: colors.accent,
              child: Text(
                activePersonaId.isNotEmpty
                    ? activePersonaId[0].toUpperCase()
                    : '?',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activePersonaId.isNotEmpty ? activePersonaId : '未选择人格',
                  style: TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Text(
                      statusText,
                      style: TextStyle(fontSize: 12, color: colors.subtext),
                    ),
                  ],
                ),
              ],
            ),
            const Spacer(),
            if (onToggleLive2d != null)
              IconButton(
                icon: Icon(
                  Icons.face_retouching_natural,
                  color: isLive2dOpen ? colors.accent : colors.subtext,
                ),
                onPressed: onToggleLive2d,
                tooltip: isLive2dOpen ? '收起角色展台' : '展开角色展台',
              ),
          ],
        ),
      ),
    );
  }
}

// ─── 消息列表 ────────────────────────────────────────────────────────────────
