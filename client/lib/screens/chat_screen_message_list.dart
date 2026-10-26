part of 'chat_screen.dart';

class _MessageList extends StatefulWidget {
  final List<ChatMessage> messages;
  final String activePersonaId;
  final ScrollController scroll;
  final LumiColors colors;
  final Function(String) onDeleteMessage;
  final bool enableAiVoiceOutput;
  final Set<String> ttsReadyMessageIds;
  final Set<String> ttsGeneratingMessageIds;
  final String? playingTtsMessageId;
  final bool isTtsPlaying;
  final ValueChanged<ChatMessage> onReadAloudTap;
  final ValueChanged<ChatMessage>? onRecallMessage;
  final ValueChanged<ChatMessage>? onRewindToHere;

  const _MessageList({
    required this.messages,
    required this.activePersonaId,
    required this.scroll,
    required this.colors,
    required this.onDeleteMessage,
    required this.enableAiVoiceOutput,
    required this.ttsReadyMessageIds,
    required this.ttsGeneratingMessageIds,
    required this.playingTtsMessageId,
    required this.isTtsPlaying,
    required this.onReadAloudTap,
    this.onRecallMessage,
    this.onRewindToHere,
  });

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
  final GlobalKey _listContainerKey = GlobalKey();
  final Map<String, GlobalKey> _userKeys = {};
  final Map<String, double> _userTopOffsets = {};
  final Map<String, double> _userHeights = {};
  ChatMessage? _stickyMessage;

  @override
  void initState() {
    super.initState();
    widget.scroll.addListener(_onScroll);
    WidgetsBinding.instance.addPostFrameCallback((_) => _checkStickyScroll());
  }

  @override
  void didUpdateWidget(covariant _MessageList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.scroll != widget.scroll) {
      oldWidget.scroll.removeListener(_onScroll);
      widget.scroll.addListener(_onScroll);
    }
    final validIds = widget.messages.map((m) => m.id).toSet();
    _userKeys.removeWhere((id, _) => !validIds.contains(id));
    _userTopOffsets.removeWhere((id, _) => !validIds.contains(id));
    _userHeights.removeWhere((id, _) => !validIds.contains(id));

    WidgetsBinding.instance.addPostFrameCallback((_) => _checkStickyScroll());
  }

  @override
  void dispose() {
    widget.scroll.removeListener(_onScroll);
    super.dispose();
  }

  void _onScroll() {
    _checkStickyScroll();
  }

  void _checkStickyScroll() {
    if (!mounted || widget.messages.isEmpty || !widget.scroll.hasClients) return;
    final listBox =
        _listContainerKey.currentContext?.findRenderObject() as RenderBox?;
    if (listBox == null || !listBox.hasSize) return;

    final scrollOffset = widget.scroll.offset;

    // 1. 扫描当前挂载在 Widget 树中的用户消息，记录/更新位置
    for (final msg in widget.messages) {
      if (msg.sender == MessageSender.me) {
        final key = _userKeys[msg.id];
        final box = key?.currentContext?.findRenderObject() as RenderBox?;
        if (box != null && box.hasSize) {
          final pos = box.localToGlobal(Offset.zero, ancestor: listBox);
          _userTopOffsets[msg.id] = scrollOffset + pos.dy;
          _userHeights[msg.id] = box.size.height;
        }
      }
    }

    // 2. 判定哪个用户提问滑出了顶部
    ChatMessage? newSticky;
    for (final msg in widget.messages) {
      if (msg.sender == MessageSender.me) {
        final key = _userKeys[msg.id];
        final box = key?.currentContext?.findRenderObject() as RenderBox?;
        bool isAboveTop = false;

        if (box != null && box.hasSize) {
          final pos = box.localToGlobal(Offset.zero, ancestor: listBox);
          // 当消息底端完全滑出视口顶部（留 8px 缓冲）
          isAboveTop = (pos.dy + box.size.height) <= 8;
        } else {
          final cachedTop = _userTopOffsets[msg.id];
          final cachedHeight = _userHeights[msg.id] ?? 40.0;
          if (cachedTop != null) {
            isAboveTop = scrollOffset >= (cachedTop + cachedHeight - 8);
          }
        }

        if (isAboveTop) {
          newSticky = msg;
        } else {
          // 当前消息仍在视口内或在视口下方，停止向后寻找
          break;
        }
      }
    }

    if (newSticky?.id != _stickyMessage?.id) {
      setState(() {
        _stickyMessage = newSticky;
      });
    }
  }

  void _scrollToMessage(String id) {
    final top = _userTopOffsets[id];
    if (top != null && widget.scroll.hasClients) {
      widget.scroll.animateTo(
        math.max(0.0, top - 12),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
      return;
    }
    final idx = widget.messages.indexWhere((m) => m.id == id);
    if (idx != -1 && widget.scroll.hasClients) {
      widget.scroll.animateTo(
        math.max(0.0, idx * 120.0),
        duration: const Duration(milliseconds: 320),
        curve: Curves.easeOutCubic,
      );
    }
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
            // 现代国际化友好问候语
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

            // 双胶囊展示：[ 📁 工作区 ] [ ✨ 人格 ]
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

            // 快捷建议引导卡片
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

  Widget _buildStickyHeader(ChatMessage msg) {
    String title = msg.content.trim();
    if (msg.content.startsWith('[图片] ')) {
      title = '📷 图片';
    } else if (msg.content.startsWith('[附件] ')) {
      final name = msg.content
          .replaceFirst(RegExp(r'^\[(图片|附件)\] '), '')
          .split('|||')
          .last;
      title = '📎 附件: $name';
    }
    final firstLine = title.split('\n').first;

    return Container(
      margin: const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(10),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 10,
            offset: const Offset(0, 3),
          ),
        ],
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(10),
        child: BackdropFilter(
          filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
          child: Material(
            color: widget.colors.sidebar.withValues(alpha: 0.88),
            child: InkWell(
              onTap: () => _scrollToMessage(msg.id),
              borderRadius: BorderRadius.circular(10),
              hoverColor: widget.colors.accent.withValues(alpha: 0.10),
              child: Container(
                height: 38,
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  borderRadius: BorderRadius.circular(10),
                  border: Border.all(
                    color: widget.colors.divider.withValues(alpha: 0.6),
                    width: 1,
                  ),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.history_edu_rounded,
                      size: 16,
                      color: widget.colors.accent,
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: widget.colors.accent.withValues(alpha: 0.16),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        '当前提问',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w600,
                          color: widget.colors.accent,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        firstLine,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 12.5,
                          fontWeight: FontWeight.w500,
                          color: Theme.of(context).colorScheme.onSurface,
                        ),
                      ),
                    ),
                    const SizedBox(width: 8),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2.5,
                      ),
                      decoration: BoxDecoration(
                        color: Colors.white.withValues(alpha: 0.08),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.arrow_upward_rounded,
                            size: 12,
                            color: widget.colors.subtext,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '回到提问',
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w500,
                              color: widget.colors.subtext,
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
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return _buildEmptyState(context);
    }

    return Stack(
      key: _listContainerKey,
      children: [
        SelectionArea(
          contextMenuBuilder: (context, selectableRegionState) {
            final hasCopy = selectableRegionState.contextMenuButtonItems.any(
              (b) => b.type == ContextMenuButtonType.copy,
            );

            if (!hasCopy) {
              return const SizedBox.shrink();
            }

            final copyItem = selectableRegionState.contextMenuButtonItems
                .firstWhere((b) => b.type == ContextMenuButtonType.copy);

            return AdaptiveTextSelectionToolbar.buttonItems(
              anchors: selectableRegionState.contextMenuAnchors,
              buttonItems: [
                ContextMenuButtonItem(
                  onPressed: copyItem.onPressed,
                  type: ContextMenuButtonType.copy,
                  label: '复制',
                ),
              ],
            );
          },
          child: NotificationListener<ScrollNotification>(
            onNotification: (notification) {
              _checkStickyScroll();
              return false;
            },
            child: ListView.builder(
              key: const PageStorageKey<String>('chat_message_list'),
              controller: widget.scroll,
              scrollCacheExtent: const ScrollCacheExtent.pixels(3000.0),
              padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
              itemCount: widget.messages.length,
              itemBuilder: (_, i) {
                final msg = widget.messages[i];
                final isUser = msg.sender == MessageSender.me;
                final ws = context.read<WsService>();
                final isLastUser = isUser && ws.isLastUserMessage(msg.id);
                final isEarlierUser = isUser && ws.isEarlierUserMessage(msg.id);
                final userKey = isUser
                    ? _userKeys.putIfAbsent(msg.id, () => GlobalKey())
                    : null;

                return _BubbleItem(
                  key: userKey ?? ValueKey<String>('msg_${msg.id}'),
                  msg: msg,
                  colors: widget.colors,
                  activePersonaId: widget.activePersonaId,
                  onDeleteMessage: () => widget.onDeleteMessage(msg.id),
                  enableAiVoiceOutput: widget.enableAiVoiceOutput,
                  isTtsReady: widget.ttsReadyMessageIds.contains(msg.id),
                  isTtsGenerating:
                      widget.ttsGeneratingMessageIds.contains(msg.id),
                  isTtsPlaying: widget.isTtsPlaying &&
                      widget.playingTtsMessageId == msg.id,
                  onReadAloudTap: () => widget.onReadAloudTap(msg),
                  isLastUserMessage: isLastUser,
                  onRecallMessage: widget.onRecallMessage != null
                      ? () => widget.onRecallMessage!(msg)
                      : null,
                  isEarlierUserMessage: isEarlierUser,
                  onRewindToHere: widget.onRewindToHere != null
                      ? () => widget.onRewindToHere!(msg)
                      : null,
                );
              },
            ),
          ),
        ),
        // VS Code 风格 Sticky Scroll 吸顶标题栏
        Positioned(
          top: 0,
          left: 0,
          right: 0,
          child: AnimatedSwitcher(
            duration: const Duration(milliseconds: 200),
            transitionBuilder: (child, animation) {
              return SlideTransition(
                position: Tween<Offset>(
                  begin: const Offset(0, -0.3),
                  end: Offset.zero,
                ).animate(animation),
                child: FadeTransition(opacity: animation, child: child),
              );
            },
            child: _stickyMessage != null
                ? KeyedSubtree(
                    key: ValueKey<String>('sticky_${_stickyMessage!.id}'),
                    child: _buildStickyHeader(_stickyMessage!),
                  )
                : const SizedBox.shrink(),
          ),
        ),
      ],
    );
  }
}
