part of 'chat_screen.dart';

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final LumiColors colors;
  final WsService ws;
  final String activePersonaId;
  final VoidCallback onSend;
  final VoidCallback? onStop;
  final VoidCallback onAttach;
  final bool enabled;
  final bool isGenerating;
  final VoidCallback? onRecallLastMessage;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.colors,
    required this.ws,
    required this.activePersonaId,
    required this.onSend,
    this.onStop,
    required this.onAttach,
    required this.enabled,
    required this.isGenerating,
    this.onRecallLastMessage,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  /// Enter 发送，Shift+Enter 换行，空输入框按向上键快速撤回上一次消息
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // 空输入框按向上键 → 快速撤回并重新编辑上一次发送的消息
    if (event.logicalKey == LogicalKeyboardKey.arrowUp &&
        widget.controller.text.isEmpty &&
        widget.onRecallLastMessage != null) {
      widget.onRecallLastMessage!();
      return KeyEventResult.handled;
    }

    final isEnter =
        event.logicalKey == LogicalKeyboardKey.enter ||
        event.logicalKey == LogicalKeyboardKey.numpadEnter;
    if (!isEnter) return KeyEventResult.ignored;

    final isShift = HardwareKeyboard.instance.isShiftPressed;
    if (isShift) {
      // Shift+Enter → 插入换行符
      final sel = widget.controller.selection;
      final text = widget.controller.text;
      final newText = text.replaceRange(sel.start, sel.end, '\n');
      widget.controller.value = TextEditingValue(
        text: newText,
        selection: TextSelection.collapsed(offset: sel.start + 1),
      );
      return KeyEventResult.handled;
    } else {
      // Enter → 发送
      if (widget.enabled) widget.onSend();
      return KeyEventResult.handled;
    }
  }

  String _formatReasoningEffort(String effort) {
    switch (effort.toLowerCase()) {
      case 'low':
        return 'Low';
      case 'medium':
        return 'Medium';
      case 'high':
      default:
        return 'High';
    }
  }

  List<Widget> _buildMenuChildren(BuildContext context) {
    final ws = widget.ws;
    final colors = widget.colors;
    final curEffort = _formatReasoningEffort(ws.reasoningEffort);
    final submenuStyle = MenuStyle(
      backgroundColor: WidgetStatePropertyAll(colors.inputBg),
      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
      shape: WidgetStatePropertyAll(
        RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(10),
          side: BorderSide(color: colors.divider.withValues(alpha: 0.6)),
        ),
      ),
      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
    );

    final children = <Widget>[
      // ── Model 标题 ──
      Padding(
        padding: const EdgeInsets.fromLTRB(12, 6, 12, 4),
        child: Text(
          'Model',
          style: TextStyle(
            fontSize: 11.5,
            fontWeight: FontWeight.w600,
            color: colors.subtext,
          ),
        ),
      ),
    ];

    for (final m in ws.configuredModels) {
      final id = m['id'] as String? ?? '';
      final name = (m['name'] as String?) ?? (m['model'] as String?) ?? '未命名';
      final isCur = id == ws.activeModelId;

      if (isCur) {
        // 当前激活模型带二级飞出菜单 (Cascading Submenu): Low / Medium / High
        children.add(
          SubmenuButton(
            menuStyle: submenuStyle,
            menuChildren: [
              for (final lvl in ['Low', 'Medium', 'High'])
                MenuItemButton(
                  onPressed: () => ws.setReasoningEffort(lvl.toLowerCase()),
                  trailingIcon: ws.reasoningEffort == lvl.toLowerCase()
                      ? Icon(Icons.check, size: 15, color: colors.subtext)
                      : null,
                  child: Text(
                    lvl,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: ws.reasoningEffort == lvl.toLowerCase()
                          ? FontWeight.w500
                          : FontWeight.w400,
                    ),
                  ),
                ),
            ],
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                ConstrainedBox(
                  constraints: const BoxConstraints(maxWidth: 180),
                  child: Text(
                    name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w500,
                    ),
                  ),
                ),
                const SizedBox(width: 6),
                Text(
                  curEffort,
                  style: TextStyle(
                    fontSize: 11,
                    fontWeight: FontWeight.w400,
                    color: colors.subtext,
                  ),
                ),
              ],
            ),
          ),
        );
      } else {
        children.add(
          MenuItemButton(
            onPressed: () => ws.switchModel(id),
            child: Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w400,
                color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.8),
              ),
            ),
          ),
        );
      }
    }

    children.add(
      Divider(
        height: 10,
        thickness: 0.8,
        color: colors.divider.withValues(alpha: 0.5),
      ),
    );

    children.add(
      MenuItemButton(
        leadingIcon: Icon(Icons.speed_rounded, size: 15, color: colors.subtext),
        onPressed: () {
          if (mounted) {
            SettingsHubDialog.show(context, ws: ws, colors: colors, initialTab: 1);
          }
        },
        child: Text(
          '管理模型配置...',
          style: TextStyle(fontSize: 12, color: colors.subtext),
        ),
      ),
    );

    return children;
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.of(context).size.width <= 640;
    final effortText = _formatReasoningEffort(widget.ws.reasoningEffort);
    final modelName = widget.ws.activeModelName.isNotEmpty ? widget.ws.activeModelName : '默认模型';

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 10 : 14,
        vertical: isCompact ? 8 : 8,
      ),
      child: Container(
        decoration: BoxDecoration(
          color: widget.colors.inputBg,
          borderRadius: BorderRadius.circular(16),
          border: Border.all(color: widget.colors.divider.withValues(alpha: 0.6)),
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: [
            // ── 文本输入区域 ──
            Focus(
              focusNode: widget.focusNode,
              onKeyEvent: _handleKey,
              child: TextField(
                controller: widget.controller,
                enabled: true,
                maxLines: null,
                minLines: 1,
                keyboardType: TextInputType.multiline,
                textInputAction: TextInputAction.newline,
                style: TextStyle(
                  color: Theme.of(context).colorScheme.onSurface,
                  fontSize: 14,
                ),
                decoration: InputDecoration(
                  hintText: widget.isGenerating
                      ? 'AI 回复中... (可继续输入，不可发送)'
                      : 'Ask anything, @ to mention, / for actions',
                  hintStyle: TextStyle(
                    color: widget.colors.subtext.withValues(alpha: 0.7),
                    fontSize: 13,
                  ),
                  contentPadding: const EdgeInsets.fromLTRB(16, 13, 16, 8),
                  border: InputBorder.none,
                ),
              ),
            ),

            // ── 底部操作栏: +  ModelName  Effort  ^  ......  -> ──
            Padding(
              padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
              child: Row(
                children: [
                  // + 按钮 (上下文挂载/附件)
                  IconButton(
                    tooltip: 'Add context or files',
                    onPressed: widget.onAttach,
                    icon: Icon(
                      Icons.add,
                      size: 18,
                      color: widget.colors.subtext,
                    ),
                    style: IconButton.styleFrom(
                      visualDensity: VisualDensity.compact,
                      padding: EdgeInsets.zero,
                      minimumSize: const Size(26, 26),
                    ),
                  ),
                  const SizedBox(width: 4),

                  // 模型与思考等级二级级联菜单 (MenuAnchor + SubmenuButton)
                  MenuAnchor(
                    alignmentOffset: const Offset(0, -6),
                    style: MenuStyle(
                      backgroundColor: WidgetStatePropertyAll(widget.colors.inputBg),
                      surfaceTintColor: const WidgetStatePropertyAll(Colors.transparent),
                      shape: WidgetStatePropertyAll(
                        RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(10),
                          side: BorderSide(color: widget.colors.divider.withValues(alpha: 0.6)),
                        ),
                      ),
                      padding: const WidgetStatePropertyAll(EdgeInsets.symmetric(vertical: 4)),
                    ),
                    menuChildren: _buildMenuChildren(context),
                    builder: (context, controller, child) {
                      return InkWell(
                        borderRadius: BorderRadius.circular(6),
                        hoverColor: Colors.white.withValues(alpha: 0.05),
                        onTap: () {
                          if (controller.isOpen) {
                            controller.close();
                          } else {
                            controller.open();
                          }
                        },
                        child: Padding(
                          padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 3.5),
                          child: Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              ConstrainedBox(
                                constraints: BoxConstraints(maxWidth: isCompact ? 130 : 260),
                                child: Text(
                                  modelName,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 13,
                                    fontWeight: FontWeight.w400,
                                    color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.88),
                                  ),
                                ),
                              ),
                              const SizedBox(width: 5),
                              Text(
                                effortText,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  fontWeight: FontWeight.w400,
                                  color: widget.colors.subtext,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                Icons.keyboard_arrow_up_rounded,
                                size: 14,
                                color: widget.colors.subtext,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),

                  const Spacer(),

                  // 发送 / 停止生成按钮 (简约圆形 ->)
                  IconButton(
                    tooltip: widget.isGenerating ? 'Stop generating' : 'Send message',
                    onPressed: widget.isGenerating
                        ? widget.onStop
                        : (widget.enabled ? widget.onSend : null),
                    icon: widget.isGenerating
                        ? Container(
                            width: 10,
                            height: 10,
                            decoration: BoxDecoration(
                              color: Colors.white,
                              borderRadius: BorderRadius.circular(1.5),
                            ),
                          )
                        : Icon(
                            Icons.arrow_forward_rounded,
                            size: 16,
                            color: widget.enabled
                                ? Colors.white
                                : widget.colors.subtext.withValues(alpha: 0.4),
                          ),
                    style: IconButton.styleFrom(
                      backgroundColor: widget.isGenerating
                          ? Colors.redAccent.withValues(alpha: 0.8)
                          : (widget.enabled
                              ? const Color(0xFF333538)
                              : Colors.transparent),
                      shape: const CircleBorder(),
                      minimumSize: const Size(28, 28),
                      padding: EdgeInsets.zero,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CodeElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    if (!element.textContent.endsWith('\n')) {
      return Container(
        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1.5),
        margin: const EdgeInsets.symmetric(horizontal: 2.5),
        decoration: BoxDecoration(
          color: const Color(0xFF1E232A),
          borderRadius: BorderRadius.circular(4),
          border: Border.all(
            color: const Color(0xFF38444D),
            width: 0.8,
          ),
        ),
        child: Text(
          element.textContent,
          style: const TextStyle(
            fontFamilyFallback: AppTheme.monoFonts,
            fontSize: 12.5,
            fontWeight: FontWeight.w600,
            color: Color(0xFF79C0FF),
          ),
        ),
      );
    }

    // 如果存在 language-xxx 类，仍可以用来扩展不同块的风格
    if (element.attributes['class'] != null) {
      String lg = element.attributes['class'] as String;
      if (lg.startsWith('language-')) {
        // language = lg.substring(9);
      }
    }

    return ClipRRect(
      borderRadius: BorderRadius.circular(8),
      child: SizedBox(
        width: double.infinity,
        child: Container(
          color: const Color(0xFF282C34),
          padding: const EdgeInsets.all(12),
          child: Text(
            element.textContent.substring(0, element.textContent.length - 1),
            style: const TextStyle(
              fontFamilyFallback: AppTheme.monoFonts,
              fontSize: 13,
              height: 1.5,
              color: Color(0xFFABB2BF), // 简单的原子灰回退以防止 Highlighter 兼容性报错
            ),
          ),
        ),
      ),
    );
  }
}
