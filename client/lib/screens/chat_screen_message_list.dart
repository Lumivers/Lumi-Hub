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
  });

  @override
  State<_MessageList> createState() => _MessageListState();
}

class _MessageListState extends State<_MessageList> {
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

  @override
  Widget build(BuildContext context) {
    if (widget.messages.isEmpty) {
      return _buildEmptyState(context);
    }

    return SelectionArea(
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
      child: ListView.builder(
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
            activePersonaId: widget.activePersonaId,
            onDeleteMessage: () => widget.onDeleteMessage(msg.id),
            enableAiVoiceOutput: widget.enableAiVoiceOutput,
            isTtsReady: widget.ttsReadyMessageIds.contains(msg.id),
            isTtsGenerating: widget.ttsGeneratingMessageIds.contains(msg.id),
            isTtsPlaying:
                widget.isTtsPlaying && widget.playingTtsMessageId == msg.id,
            onReadAloudTap: () => widget.onReadAloudTap(msg),
          );
        },
      ),
    );
  }
}
