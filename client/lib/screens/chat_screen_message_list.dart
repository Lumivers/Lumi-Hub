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

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      final text = widget.activePersonaId.isNotEmpty
          ? '向 ${widget.activePersonaId} 发送第一条消息吧 ✨'
          : '请先在侧边栏选择一个人格';
      return Center(
        child: Text(text, style: TextStyle(color: widget.colors.subtext)),
      );
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
