part of 'chat_screen.dart';

class _BubbleItem extends StatefulWidget {
  final ChatMessage msg;
  final LumiColors colors;
  final String activePersonaId;
  final VoidCallback onDeleteMessage;
  final bool enableAiVoiceOutput;
  final bool isTtsReady;
  final bool isTtsGenerating;
  final bool isTtsPlaying;
  final VoidCallback onReadAloudTap;
  final bool isLastUserMessage;
  final VoidCallback? onRecallMessage;
  final bool isEarlierUserMessage;
  final VoidCallback? onRewindToHere;

  const _BubbleItem({
    super.key,
    required this.msg,
    required this.colors,
    required this.activePersonaId,
    required this.onDeleteMessage,
    required this.enableAiVoiceOutput,
    required this.isTtsReady,
    required this.isTtsGenerating,
    required this.isTtsPlaying,
    required this.onReadAloudTap,
    this.isLastUserMessage = false,
    this.onRecallMessage,
    this.isEarlierUserMessage = false,
    this.onRewindToHere,
  });

  @override
  State<_BubbleItem> createState() => _BubbleItemState();
}

class _BubbleItemState extends State<_BubbleItem> {
  bool _isHovered = false;

  bool get _isAttachmentBubble => widget.msg.content.startsWith('[附件] ');
  bool get _isImageBubble => widget.msg.content.startsWith('[图片] ');

  // 协议格式：[图片]/[附件] path|||name
  String? _getAttachmentPath() {
    if (_isImageBubble || _isAttachmentBubble) {
      final parts = widget.msg.content
          .replaceFirst(RegExp(r'^\[(图片|附件)\] '), '')
          .split('|||');
      if (parts.length == 2 && parts[0].isNotEmpty) {
        return parts[0].trim();
      }
    }
    return null;
  }

  String _getAttachmentName() {
    if (_isImageBubble || _isAttachmentBubble) {
      final parts = widget.msg.content
          .replaceFirst(RegExp(r'^\[(图片|附件)\] '), '')
          .split('|||');
      if (parts.length == 2) {
        return parts[1].trim();
      }
      return parts[0].trim();
    }
    return '';
  }

  String _formatBytes(dynamic sizeValue) {
    final size = (sizeValue is num) ? sizeValue.toDouble() : 0.0;
    if (size <= 0) return 'Unknown size';
    const units = ['B', 'KB', 'MB', 'GB'];
    var value = size;
    var idx = 0;
    while (value >= 1024 && idx < units.length - 1) {
      value /= 1024;
      idx++;
    }
    final fixed = value >= 100
        ? value.toStringAsFixed(0)
        : value.toStringAsFixed(2);
    return '$fixed ${units[idx]}';
  }

  IconData _iconForFileName(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.pdf')) {
      return Icons.picture_as_pdf_rounded;
    }
    if (lower.endsWith('.doc') || lower.endsWith('.docx')) {
      return Icons.description_rounded;
    }
    if (lower.endsWith('.xls') ||
        lower.endsWith('.xlsx') ||
        lower.endsWith('.csv')) {
      return Icons.table_chart_rounded;
    }
    if (lower.endsWith('.zip') ||
        lower.endsWith('.rar') ||
        lower.endsWith('.7z')) {
      return Icons.archive_rounded;
    }
    return Icons.insert_drive_file_rounded;
  }

  Widget _buildFileBubble(Color textColor, String fileName, String? path) {
    final sizeText = _formatBytes(widget.msg.extra?['size_bytes']);
    final fileIcon = _iconForFileName(fileName);

    return MouseRegion(
      cursor: path != null
          ? SystemMouseCursors.click
          : SystemMouseCursors.basic,
      child: GestureDetector(
        onTap: () {
          if (path != null) {
            if (Platform.isWindows) {
              Process.run('explorer.exe', [path]);
            } else if (Platform.isMacOS) {
              Process.run('open', [path]);
            } else if (Platform.isLinux) {
              Process.run('xdg-open', [path]);
            }
          }
        },
        child: Container(
          constraints: const BoxConstraints(minWidth: 180, maxWidth: 320),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
          decoration: BoxDecoration(
            color: Colors.white.withValues(alpha: 0.08),
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: Colors.white.withValues(alpha: 0.08)),
          ),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      fileName,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: textColor,
                        fontSize: 13,
                        fontWeight: FontWeight.w700,
                        height: 1.2,
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      sizeText,
                      style: TextStyle(
                        color: textColor.withValues(alpha: 0.72),
                        fontSize: 10,
                        fontWeight: FontWeight.w500,
                        letterSpacing: 0.1,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              Container(
                width: 38,
                height: 38,
                decoration: BoxDecoration(
                  color: Colors.black.withValues(alpha: 0.22),
                  borderRadius: BorderRadius.circular(9),
                  border: Border.all(
                    color: Colors.white.withValues(alpha: 0.16),
                  ),
                ),
                child: Icon(
                  fileIcon,
                  color: textColor.withValues(alpha: 0.95),
                  size: 21,
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _buildMarkdownContent(Color textColor) {
    return MarkdownBody(
      data: widget.msg.content,
      // 文本选择统一交给列表层 SelectionArea，避免嵌套选择器造成跨空格/跨气泡拖选异常。
      selectable: false,
      styleSheet: MarkdownStyleSheet(
        p: TextStyle(
          color: textColor,
          fontSize: 14,
          height: 1.4,
          fontFamilyFallback: AppTheme.fallbackFonts,
        ),
        listBullet: TextStyle(
          color: textColor,
          fontSize: 14,
          fontFamilyFallback: AppTheme.fallbackFonts,
        ),
        code: const TextStyle(
          color: Color(0xFF79C0FF),
          fontFamilyFallback: AppTheme.monoFonts,
          fontSize: 13,
        ),
        codeblockDecoration: BoxDecoration(
          borderRadius: BorderRadius.circular(8),
          color: const Color(0xFF282C34),
        ),
        blockquoteDecoration: BoxDecoration(
          color: widget.colors.sidebar.withValues(alpha: 0.5),
          border: Border(
            left: BorderSide(color: widget.colors.accent, width: 4),
          ),
        ),
      ),
      builders: {'code': CodeElementBuilder()},
    );
  }

  Widget _buildBubbleContent(Color textColor) {
    final tracesRaw = widget.msg.extra?['traces'] as List?;
    final traces = tracesRaw
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    final filesRaw = widget.msg.extra?['files_changed'] ??
        widget.msg.extra?['trace_summary']?['files_changed'];
    final filesChanged = (filesRaw as List?)
        ?.map((e) => Map<String, dynamic>.from(e as Map))
        .toList();

    if (widget.msg.isTyping) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: [
          if (widget.msg.content.isNotEmpty)
            _buildMarkdownContent(textColor),
          TraceTimelineWidget(
            traces: traces ?? const [],
            colors: widget.colors,
            isGenerating: true,
          ),
          if (widget.msg.content.isNotEmpty)
            _TypingIndicator(color: textColor),
        ],
      );
    }

    if (_isImageBubble) {
      final path = _getAttachmentPath();
      final fileName = _getAttachmentName();
      if (path != null) {
        // 图片优先内嵌预览，失败时回退到文件卡片。
        return MouseRegion(
          cursor: SystemMouseCursors.click,
          child: GestureDetector(
            onTap: () {
              if (Platform.isWindows) {
                Process.run('explorer.exe', [path]);
              } else if (Platform.isMacOS) {
                Process.run('open', [path]);
              } else if (Platform.isLinux) {
                Process.run('xdg-open', [path]);
              }
            },
            child: ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: Image.file(
                File(path),
                width: 250,
                fit: BoxFit.cover,
                errorBuilder: (context, error, stackTrace) =>
                    _buildFileBubble(textColor, fileName, path),
              ),
            ),
          ),
        );
      } else {
        return _buildFileBubble(textColor, fileName, path);
      }
    }

    if (_isAttachmentBubble) {
      return _buildFileBubble(
        textColor,
        _getAttachmentName(),
        _getAttachmentPath(),
      );
    }

    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: [
        if (widget.msg.content.isNotEmpty)
          _buildMarkdownContent(textColor),
        if (traces != null && traces.isNotEmpty)
          TraceTimelineWidget(
            traces: traces,
            colors: widget.colors,
            isGenerating: false,
          ),
        if (filesChanged != null && filesChanged.isNotEmpty)
          FilesChangedWidget(
            files: filesChanged,
            colors: widget.colors,
          ),
      ],
    );
  }



  void _showDesktopMenu(BuildContext context, Offset position) async {
    if (widget.msg.isTyping) return;
    final isMe = widget.msg.sender == MessageSender.me;

    // 桌面端右键快捷菜单：复制 / 导出图片 / 删除
    final value = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'message_context_menu',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final size = MediaQuery.of(dialogContext).size;
        const menuWidth = 156.0;
        final menuHeight = isMe
            ? ((widget.isLastUserMessage || widget.isEarlierUserMessage)
                ? 136.0
                : 92.0)
            : 136.0;
        const screenPadding = 8.0;
        final left = position.dx
            .clamp(screenPadding, size.width - menuWidth - screenPadding)
            .toDouble();
        final top = position.dy
            .clamp(screenPadding, size.height - menuHeight - screenPadding)
            .toDouble();

        Widget menuItem({
          required String value,
          required IconData icon,
          required String text,
          Color? color,
          BorderRadius? radius,
        }) {
          final fg = color ?? Theme.of(context).iconTheme.color;
          return Material(
            color: Colors.transparent,
            child: InkWell(
              borderRadius: radius,
              onTap: () => Navigator.of(dialogContext).pop(value),
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                child: Row(
                  children: [
                    Icon(icon, color: fg, size: 18),
                    const SizedBox(width: 8),
                    Text(
                      text,
                      style: TextStyle(
                        color: fg,
                        fontSize: 14,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          );
        }

        return Stack(
          children: [
            Positioned.fill(
              child: GestureDetector(
                behavior: HitTestBehavior.translucent,
                onTap: () => Navigator.of(dialogContext).maybePop(),
              ),
            ),
            Positioned(
              left: left,
              top: top,
              width: menuWidth,
              child: Material(
                color: Colors.transparent,
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(14),
                  child: BackdropFilter(
                    filter: ui.ImageFilter.blur(sigmaX: 14, sigmaY: 14),
                    child: Container(
                      decoration: BoxDecoration(
                        color: widget.colors.sidebar.withValues(alpha: 0.72),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: Colors.white.withValues(alpha: 0.16),
                        ),
                      ),
                      child: Column(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          menuItem(
                            value: 'copy',
                            icon: Icons.copy_rounded,
                            text: '复制文本',
                            radius: const BorderRadius.only(
                              topLeft: Radius.circular(14),
                              topRight: Radius.circular(14),
                            ),
                          ),
                          if (isMe && widget.isLastUserMessage)
                            menuItem(
                              value: 'recall',
                              icon: Icons.undo_rounded,
                              text: '撤回提问',
                              color: widget.colors.accent,
                            ),
                          if (isMe && widget.isEarlierUserMessage)
                            menuItem(
                              value: 'rewind',
                              icon: Icons.history_rounded,
                              text: '回退到此节点',
                              color: const Color(0xFFE5C07B),
                            ),
                          if (!isMe)
                            menuItem(
                              value: 'export_image',
                              icon: Icons.image_outlined,
                              text: '导出为图片',
                            ),
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: Colors.white.withValues(alpha: 0.24),
                          ),
                          menuItem(
                            value: 'delete',
                            icon: Icons.delete_outline,
                            text: '删除消息',
                            color: Colors.redAccent,
                            radius: const BorderRadius.only(
                              bottomLeft: Radius.circular(14),
                              bottomRight: Radius.circular(14),
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
          ],
        );
      },
    );

    if (!context.mounted) return;

    if (value == 'recall') {
      widget.onRecallMessage?.call();
    } else if (value == 'rewind') {
      widget.onRewindToHere?.call();
    } else if (value == 'copy') {
      await Clipboard.setData(ClipboardData(text: widget.msg.content));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制到剪贴板'),
          duration: Duration(seconds: 1),
        ),
      );
    } else if (value == 'export_image') {
      MessageShareCardDialog.show(
        context,
        msg: widget.msg,
        personaName: widget.activePersonaId,
      );
    } else if (value == 'delete') {
      widget.onDeleteMessage();
    }
  }

  Widget _buildActionIcon({
    required IconData icon,
    required String tooltip,
    required VoidCallback? onPressed,
    Color? color,
  }) {
    return IconButton(
      tooltip: tooltip,
      onPressed: onPressed,
      icon: Icon(icon, size: 15, color: color ?? widget.colors.subtext),
      splashRadius: 14,
      padding: EdgeInsets.zero,
      constraints: const BoxConstraints(minWidth: 26, minHeight: 26),
      style: IconButton.styleFrom(
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }

  Widget _buildAiActionBar(String timeStr) {
    return Padding(
      padding: const EdgeInsets.only(left: 40, top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          _buildActionIcon(
            icon: Icons.copy_rounded,
            tooltip: '复制',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.msg.content));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制到剪贴板'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            },
          ),
          const SizedBox(width: 4),
          _buildActionIcon(
            icon: Icons.image_outlined,
            tooltip: '导出为图片',
            onPressed: () {
              MessageShareCardDialog.show(
                context,
                msg: widget.msg,
                personaName: widget.activePersonaId,
              );
            },
          ),
          if (widget.enableAiVoiceOutput && !widget.msg.isTyping) ...[
            const SizedBox(width: 4),
            _buildActionIcon(
              icon: widget.isTtsPlaying
                  ? Icons.stop_circle_outlined
                  : widget.isTtsGenerating
                  ? Icons.hourglass_top_rounded
                  : widget.isTtsReady
                  ? Icons.volume_up_rounded
                  : Icons.volume_up_outlined,
              tooltip: widget.isTtsPlaying
                  ? '停止朗读'
                  : widget.isTtsGenerating
                  ? '语音生成中'
                  : widget.isTtsReady
                  ? '朗读消息'
                  : '生成并朗读',
              onPressed: widget.isTtsGenerating ? null : widget.onReadAloudTap,
              color: widget.isTtsPlaying ? widget.colors.accent : null,
            ),
          ],
          const SizedBox(width: 4),
          _buildActionIcon(
            icon: Icons.delete_outline_rounded,
            tooltip: '删除',
            onPressed: widget.onDeleteMessage,
            color: Colors.redAccent.withValues(alpha: 0.8),
          ),
          const SizedBox(width: 8),
          Text(
            timeStr,
            style: TextStyle(
              fontSize: 11,
              color: widget.colors.subtext.withValues(alpha: 0.45),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildUserActionBar(String timeStr) {
    return Padding(
      padding: const EdgeInsets.only(right: 8, top: 2),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            timeStr,
            style: TextStyle(
              fontSize: 11,
              color: widget.colors.subtext.withValues(alpha: 0.45),
            ),
          ),
          const SizedBox(width: 8),
          if (widget.isLastUserMessage) ...[
            _buildActionIcon(
              icon: Icons.undo_rounded,
              tooltip: '撤回并重新编辑',
              onPressed: widget.onRecallMessage,
              color: widget.colors.accent,
            ),
            const SizedBox(width: 4),
          ] else if (widget.isEarlierUserMessage) ...[
            _buildActionIcon(
              icon: Icons.history_rounded,
              tooltip: '回退到此检查点',
              onPressed: widget.onRewindToHere,
              color: const Color(0xFFE5C07B),
            ),
            const SizedBox(width: 4),
          ],
          _buildActionIcon(
            icon: Icons.copy_rounded,
            tooltip: '复制',
            onPressed: () async {
              await Clipboard.setData(ClipboardData(text: widget.msg.content));
              if (mounted) {
                ScaffoldMessenger.of(context).showSnackBar(
                  const SnackBar(
                    content: Text('已复制到剪贴板'),
                    duration: Duration(seconds: 1),
                  ),
                );
              }
            },
          ),
          const SizedBox(width: 4),
          _buildActionIcon(
            icon: Icons.delete_outline_rounded,
            tooltip: '删除',
            onPressed: widget.onDeleteMessage,
            color: Colors.redAccent.withValues(alpha: 0.8),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isMe = widget.msg.sender == MessageSender.me;
    final bubbleColor = isMe
        ? widget.colors.bubbleMe
        : widget.colors.bubbleThem;
    final textColor = isMe
        ? widget.colors.onBubbleMe
        : widget.colors.onBubbleThem;
    final now = DateTime.now();
    final timeStr = widget.msg.time.year == now.year
        ? DateFormat('MM-dd HH:mm').format(widget.msg.time)
        : DateFormat('yyyy-MM-dd HH:mm').format(widget.msg.time);
    final isCompact = MediaQuery.of(context).size.width <= 640;

    return Padding(
      padding: const EdgeInsets.only(bottom: 10),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Column(
          crossAxisAlignment:
              isMe ? CrossAxisAlignment.end : CrossAxisAlignment.start,
          children: [
            Listener(
              onPointerDown: (event) {
                if (event.kind == PointerDeviceKind.mouse &&
                    event.buttons == kSecondaryMouseButton) {
                  _showDesktopMenu(context, event.position);
                }
              },
              child: Row(
                mainAxisAlignment:
                    isMe ? MainAxisAlignment.end : MainAxisAlignment.start,
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  if (!isMe) ...[
                    CircleAvatar(
                      radius: 16,
                      backgroundColor: widget.colors.accent,
                      child: Text(
                        widget.activePersonaId.isNotEmpty
                            ? widget.activePersonaId.characters.first
                            : '流',
                        style: const TextStyle(color: Colors.white, fontSize: 12),
                      ),
                    ),
                    const SizedBox(width: 8),
                  ],
                  Flexible(
                    child: Container(
                      constraints: BoxConstraints(
                        maxWidth: isCompact
                            ? MediaQuery.of(context).size.width * 0.82
                            : MediaQuery.of(context).size.width * 0.65,
                      ),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 10,
                      ),
                      decoration: BoxDecoration(
                        color: bubbleColor,
                        borderRadius: BorderRadius.only(
                          topLeft: const Radius.circular(16),
                          topRight: const Radius.circular(16),
                          bottomLeft: Radius.circular(isMe ? 16 : 4),
                          bottomRight: Radius.circular(isMe ? 4 : 16),
                        ),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.08),
                            blurRadius: 4,
                            offset: const Offset(0, 2),
                          ),
                        ],
                      ),
                      child: _buildBubbleContent(textColor),
                    ),
                  ),
                ],
              ),
            ),
            // 底部轻量动作栏
            AnimatedOpacity(
              opacity: (isCompact || _isHovered) ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 150),
              child: isMe
                  ? _buildUserActionBar(timeStr)
                  : _buildAiActionBar(timeStr),
            ),
          ],
        ),
      ),
    );
  }
}

/// 三点跳动的"正在输入"动画
class _TypingIndicator extends StatefulWidget {
  final Color color;
  const _TypingIndicator({required this.color});

  @override
  State<_TypingIndicator> createState() => _TypingIndicatorState();
}

class _TypingIndicatorState extends State<_TypingIndicator>
    with TickerProviderStateMixin {
  late final List<AnimationController> _controllers;
  late final List<Animation<double>> _anims;

  @override
  void initState() {
    super.initState();
    _controllers = List.generate(
      3,
      (i) => AnimationController(
        vsync: this,
        duration: const Duration(milliseconds: 600),
      )..repeat(reverse: true),
    );
    for (var i = 0; i < 3; i++) {
      Future.delayed(Duration(milliseconds: i * 150), () {
        if (mounted) _controllers[i].repeat(reverse: true);
      });
    }
    _anims = _controllers
        .map(
          (c) => Tween<double>(
            begin: 0,
            end: -6,
          ).animate(CurvedAnimation(parent: c, curve: Curves.easeInOut)),
        )
        .toList();
  }

  @override
  void dispose() {
    for (final c in _controllers) {
      c.dispose();
    }
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 20,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: List.generate(3, (i) {
          return AnimatedBuilder(
            animation: _anims[i],
            builder: (context, child) => Transform.translate(
              offset: Offset(0, _anims[i].value),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Container(
                  width: 6,
                  height: 6,
                  decoration: BoxDecoration(
                    color: widget.color.withValues(alpha: 0.7),
                    shape: BoxShape.circle,
                  ),
                ),
              ),
            ),
          );
        }),
      ),
    );
  }
}

// ─── 输入栏 ────────────────────────────────────────────────────────────────
