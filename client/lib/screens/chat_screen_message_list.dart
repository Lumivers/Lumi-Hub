part of 'chat_screen.dart';

class _MessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  final String activePersonaId;
  final ScrollController scroll;
  final LumiColors colors;
  final bool isSelectionMode;
  final Set<String> selectedMessageIds;
  final Function(String) onToggleSelection;
  final ValueChanged<Set<String>> onSetSelection;
  final VoidCallback onEnterSelectionMode;
  final Function(String) onDeleteMessage;
  final bool enableAiVoiceOutput;
  final Set<String> ttsReadyMessageIds;
  final Set<String> ttsGeneratingMessageIds;
  final String? playingTtsMessageId;
  final bool isTtsPlaying;
  final ValueChanged<ChatMessage> onReadAloudTap;

  const _MessageList({
    required this.messages,
    required this.activePersonaId,
    required this.scroll,
    required this.colors,
    required this.isSelectionMode,
    required this.selectedMessageIds,
    required this.onToggleSelection,
    required this.onSetSelection,
    required this.onEnterSelectionMode,
    required this.onDeleteMessage,
    required this.enableAiVoiceOutput,
    required this.ttsReadyMessageIds,
    required this.ttsGeneratingMessageIds,
    required this.playingTtsMessageId,
    required this.isTtsPlaying,
    required this.onReadAloudTap,
  });

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  bool _hasGlobalSelection = false;
  final GlobalKey _gestureSurfaceKey = GlobalKey();
  final Map<String, Rect> _messageRowRects = {};
  final Map<String, Rect> _messageBubbleRects = {};
  String? _activeTextActionMessageId;

  Offset? _dragStartLocal;
  Offset? _dragCurrentLocal;
  bool _dragArmed = false;
  bool _isBoxSelecting = false;

  // 判断鼠标是否落在气泡内容区：普通模式下优先给文本选择逻辑处理。
  bool _pointInAnyBubble(Offset globalPoint) {
    for (final rect in _messageBubbleRects.values) {
      if (rect.contains(globalPoint)) return true;
    }
    return false;
  }

  Rect? _currentDragRectLocal() {
    if (_dragStartLocal == null || _dragCurrentLocal == null) return null;
    return Rect.fromPoints(_dragStartLocal!, _dragCurrentLocal!);
  }

  Rect? _localRectToGlobal(Rect? localRect) {
    if (localRect == null) return null;
    final ctx = _gestureSurfaceKey.currentContext;
    if (ctx == null) return null;
    final box = ctx.findRenderObject() as RenderBox?;
    if (box == null) return null;
    final origin = box.localToGlobal(Offset.zero);
    return localRect.shift(origin);
  }

  void _finishBoxSelection() {
    // 框选命中规则：以“整行矩形与选区重叠”为准。
    final localRect = _currentDragRectLocal();
    final globalRect = _localRectToGlobal(localRect);
    final selected = <String>{};

    if (globalRect != null) {
      _messageRowRects.forEach((id, rowRect) {
        if (rowRect.overlaps(globalRect)) {
          selected.add(id);
        }
      });
    }

    if (selected.isNotEmpty) {
      widget.onSetSelection(selected);
    }

    setState(() {
      _dragStartLocal = null;
      _dragCurrentLocal = null;
      _dragArmed = false;
      _isBoxSelecting = false;
    });
  }

  void _cancelBoxSelection() {
    if (!_dragArmed && !_isBoxSelecting) return;
    setState(() {
      _dragStartLocal = null;
      _dragCurrentLocal = null;
      _dragArmed = false;
      _isBoxSelecting = false;
    });
  }

  Widget _buildListView() {
    // 每次重建时同步清理失效矩形缓存，避免命中已删除消息。
    final aliveIds = widget.messages.map((m) => m.id).toSet();
    _messageRowRects.removeWhere((id, _) => !aliveIds.contains(id));
    _messageBubbleRects.removeWhere((id, _) => !aliveIds.contains(id));

    return ListView.builder(
      key: const PageStorageKey<String>('chat_message_list'),
      controller: widget.scroll,
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      itemCount: widget.messages.length,
      itemBuilder: (_, i) {
        final msg = widget.messages[i];
        return _BubbleItem(
          key: ValueKey<String>('msg_${msg.id}'),
          msg: msg,
          colors: widget.colors,
          isSelected: widget.selectedMessageIds.contains(msg.id),
          isSelectionMode: widget.isSelectionMode,
          hasGlobalSelection: () => _hasGlobalSelection,
          onToggleSelection: () => widget.onToggleSelection(msg.id),
          onEnterSelectionMode: widget.onEnterSelectionMode,
          onDeleteMessage: () => widget.onDeleteMessage(msg.id),
          onActivateForTextActions: () {
            _activeTextActionMessageId = msg.id;
          },
          onRowRectChanged: (rect) {
            _messageRowRects[msg.id] = rect;
          },
          onBubbleRectChanged: (rect) {
            _messageBubbleRects[msg.id] = rect;
          },
          enableAiVoiceOutput: widget.enableAiVoiceOutput,
          isTtsReady: widget.ttsReadyMessageIds.contains(msg.id),
          isTtsGenerating: widget.ttsGeneratingMessageIds.contains(msg.id),
          isTtsPlaying:
              widget.isTtsPlaying && widget.playingTtsMessageId == msg.id,
          onReadAloudTap: () => widget.onReadAloudTap(msg),
        );
      },
    );
  }

  Widget _buildPromptChip(
    BuildContext context, {
    required IconData icon,
    required String title,
    required String desc,
    required String prompt,
  }) {
    final colors = widget.colors;
    final ws = context.read<WsService>();

    return InkWell(
      borderRadius: BorderRadius.circular(12),
      hoverColor: colors.accent.withValues(alpha: 0.08),
      onTap: () {
        if (ws.status == WsStatus.connected && !ws.isGenerating) {
          ws.sendMessage(prompt);
        }
      },
      child: Container(
        width: 245,
        padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
        decoration: BoxDecoration(
          color: colors.inputBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: colors.divider.withValues(alpha: 0.35)),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: [
            Row(
              children: [
                Icon(icon, size: 16, color: colors.accent),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    title,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Theme.of(context).colorScheme.onSurface,
                    ),
                  ),
                ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              desc,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 11.5,
                color: colors.subtext.withValues(alpha: 0.7),
              ),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildEmptyState(BuildContext context) {
    final ws = context.watch<WsService>();
    final colors = widget.colors;
    final wsPath = ws.activeWorkspacePath;
    final wsName = wsPath.isNotEmpty
        ? wsPath.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last
        : '默认工作区';
    final persona = widget.activePersonaId.isNotEmpty ? widget.activePersonaId : '流萤';

    final String greetingTitle = persona.contains('流萤')
        ? '开拓者，今天有什么想法？'
        : '今天想构建点什么？';

    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // ── 现代国际化友好问候语 ──
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Icon(Icons.auto_awesome, size: 24, color: colors.accent),
                const SizedBox(width: 10),
                Text(
                  greetingTitle,
                  style: TextStyle(
                    fontSize: 22,
                    fontWeight: FontWeight.w600,
                    letterSpacing: 0.3,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Text(
              '在下方输入问题，或从快捷建议中开始探索',
              style: TextStyle(
                fontSize: 13,
                color: colors.subtext.withValues(alpha: 0.75),
              ),
            ),
            const SizedBox(height: 20),

            // ── 双胶囊展示：[ 📁 工作区 ] [ ✨ 人格 ] ──
            Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: colors.inputBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: colors.divider.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.folder_rounded, size: 14, color: colors.accent),
                      const SizedBox(width: 6),
                      Text(
                        wsName,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                  decoration: BoxDecoration(
                    color: colors.inputBg,
                    borderRadius: BorderRadius.circular(16),
                    border: Border.all(color: colors.divider.withValues(alpha: 0.4)),
                  ),
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(Icons.auto_awesome, size: 13, color: colors.accent),
                      const SizedBox(width: 6),
                      Text(
                        persona,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w600,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
            const SizedBox(height: 32),

            // ── 快捷建议引导卡片 ──
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 520),
              child: Wrap(
                spacing: 10,
                runSpacing: 10,
                alignment: WrapAlignment.center,
                children: [
                  _buildPromptChip(
                    context,
                    icon: Icons.architecture_rounded,
                    title: '代码库架构分析',
                    desc: '分析当前项目文件架构与模块划分',
                    prompt: '请分析当前工作区代码库的文件结构、核心架构与模块调用关系。',
                  ),
                  _buildPromptChip(
                    context,
                    icon: Icons.bolt_rounded,
                    title: '性能调优与诊断',
                    desc: '排查 CPU / 渲染帧率与内存瓶颈',
                    prompt: '请帮我检查当前工程可能存在的性能瓶颈、资源泄漏或冗余渲染问题，并给出优化方案。',
                  ),
                  _buildPromptChip(
                    context,
                    icon: Icons.bug_report_outlined,
                    title: '单元测试与测试覆盖',
                    desc: '编写核心模块测试用例',
                    prompt: '请为项目核心逻辑设计并编写测试用例，覆盖正常流与异常边界。',
                  ),
                  _buildPromptChip(
                    context,
                    icon: Icons.chat_bubble_outline_rounded,
                    title: '畅聊与随心问答',
                    desc: '与 $persona 自由交流',
                    prompt: '你好呀 $persona！',
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return _buildEmptyState(context);
    }

    final listContent = widget.isSelectionMode
        ? _buildListView()
        : SelectionArea(
            onSelectionChanged: (content) {
              _hasGlobalSelection =
                  content != null && content.plainText.isNotEmpty;
            },
            contextMenuBuilder: (context, selectableRegionState) {
              final hasCopy = selectableRegionState.contextMenuButtonItems.any(
                (b) => b.type == ContextMenuButtonType.copy,
              );

              if (!hasCopy) {
                return const SizedBox.shrink();
              }

              final copyItem = selectableRegionState.contextMenuButtonItems
                  .firstWhere((b) => b.type == ContextMenuButtonType.copy);
              final isMobile =
                  !kIsWeb && (Platform.isAndroid || Platform.isIOS);
              final targetMessageId = _activeTextActionMessageId;

              // 桌面保留复制；移动端额外提供删除/多选快捷操作。
              return AdaptiveTextSelectionToolbar.buttonItems(
                anchors: selectableRegionState.contextMenuAnchors,
                buttonItems: [
                  ContextMenuButtonItem(
                    onPressed: copyItem.onPressed,
                    type: ContextMenuButtonType.copy,
                    label: '复制',
                  ),
                  if (isMobile && targetMessageId != null)
                    ContextMenuButtonItem(
                      onPressed: () {
                        ContextMenuController.removeAny();
                        widget.onDeleteMessage(targetMessageId);
                      },
                      label: '删除',
                    ),
                  if (isMobile && targetMessageId != null)
                    ContextMenuButtonItem(
                      onPressed: () {
                        ContextMenuController.removeAny();
                        widget.onEnterSelectionMode();
                        widget.onSetSelection({targetMessageId});
                      },
                      label: '多选',
                    ),
                ],
              );
            },
            child: _buildListView(),
          );

    final messageList = Listener(
      key: _gestureSurfaceKey,
      behavior: HitTestBehavior.translucent,
      onPointerDown: (event) {
        if (event.kind != PointerDeviceKind.mouse) return;
        if (event.buttons != kPrimaryMouseButton) return;

        // 普通模式下：气泡内拖动专用于文字选择，不触发消息框选。
        if (!widget.isSelectionMode && _pointInAnyBubble(event.position)) {
          _cancelBoxSelection();
          return;
        }

        setState(() {
          _dragStartLocal = event.localPosition;
          _dragCurrentLocal = event.localPosition;
          _dragArmed = true;
          _isBoxSelecting = false;
        });
      },
      onPointerMove: (event) {
        if (!_dragArmed) return;
        if (event.kind != PointerDeviceKind.mouse) return;
        if (event.buttons != kPrimaryMouseButton) return;

        final start = _dragStartLocal;
        if (start == null) return;

        final dx = (event.localPosition.dx - start.dx).abs();
        final dy = (event.localPosition.dy - start.dy).abs();
        final shouldStart = dx > 4 || dy > 4;

        setState(() {
          _dragCurrentLocal = event.localPosition;
          if (shouldStart) {
            _isBoxSelecting = true;
          }
        });
      },
      onPointerUp: (event) {
        if (!_dragArmed) return;
        if (_isBoxSelecting) {
          _finishBoxSelection();
        } else {
          _cancelBoxSelection();
        }
      },
      onPointerCancel: (_) => _cancelBoxSelection(),
      child: Stack(
        children: [
          listContent,
          if (_isBoxSelecting && _currentDragRectLocal() != null)
            Positioned.fill(
              child: IgnorePointer(
                child: CustomPaint(
                  painter: _SelectionMarqueePainter(_currentDragRectLocal()!),
                ),
              ),
            ),
        ],
      ),
    );

    return messageList;
  }
}
