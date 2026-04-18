part of 'chat_screen.dart';

class _InputBar extends StatefulWidget {
  final TextEditingController controller;
  final FocusNode focusNode;
  final LumiColors colors;
  final String activePersonaId;
  final VoidCallback onSend;
  final VoidCallback onAttach;
  final bool enabled;
  final bool isGenerating;

  const _InputBar({
    required this.controller,
    required this.focusNode,
    required this.colors,
    required this.activePersonaId,
    required this.onSend,
    required this.onAttach,
    required this.enabled,
    required this.isGenerating,
  });

  @override
  State<_InputBar> createState() => _InputBarState();
}

class _InputBarState extends State<_InputBar> {
  /// Enter 发送，Shift+Enter 换行
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
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

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.of(context).size.width <= 640;
    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 10 : 12,
        vertical: isCompact ? 10 : 8,
      ),
      child: Row(
        children: [
          Expanded(
            child: Container(
              decoration: BoxDecoration(
                color: widget.colors.inputBg,
                borderRadius: BorderRadius.circular(isCompact ? 24 : 20),
                border: Border.all(color: widget.colors.divider),
              ),
              child: Focus(
                focusNode: widget.focusNode,
                onKeyEvent: _handleKey,
                child: TextField(
                  controller: widget.controller,
                  enabled: true, // Always keep input enabled
                  maxLines: null,
                  keyboardType: TextInputType.multiline,
                  textInputAction: TextInputAction.newline,
                  style: TextStyle(
                    color: Theme.of(context).colorScheme.onSurface,
                    fontSize: 14,
                  ),
                  decoration: InputDecoration(
                    hintText: widget.isGenerating
                        ? 'AI 回复中... (可继续输入，不可发送)'
                        : widget.enabled
                        ? (isCompact
                              ? '发送消息...'
                              : '发送消息... (Enter 发送，Shift+Enter 换行)')
                        : '等待连接中...',
                    hintStyle: TextStyle(
                      color: widget.colors.subtext,
                      fontSize: isCompact ? 12 : 13,
                    ),
                    contentPadding: EdgeInsets.symmetric(
                      horizontal: isCompact ? 16 : 16,
                      vertical: isCompact ? 13 : 10,
                    ),
                    border: InputBorder.none,
                  ),
                ),
              ),
            ),
          ),
          SizedBox(width: isCompact ? 6 : 8),
          IconButton(
            onPressed: widget.onAttach,
            icon: Icon(
              Icons.attach_file_rounded,
              color: widget.enabled
                  ? widget.colors.accent
                  : widget.colors.subtext,
            ),
            style: IconButton.styleFrom(
              backgroundColor: widget.enabled
                  ? widget.colors.accent.withValues(alpha: 0.15)
                  : Colors.transparent,
              shape: const CircleBorder(),
              minimumSize: Size(isCompact ? 44 : 40, isCompact ? 44 : 40),
            ),
          ),
          SizedBox(width: isCompact ? 2 : 4),
          IconButton(
            onPressed: widget.enabled && !widget.isGenerating
                ? widget.onSend
                : null,
            icon: widget.isGenerating
                ? SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      valueColor: AlwaysStoppedAnimation<Color>(
                        widget.colors.subtext,
                      ),
                    ),
                  )
                : Icon(
                    Icons.send_rounded,
                    color: widget.enabled
                        ? widget.colors.accent
                        : widget.colors.subtext,
                  ),
            style: IconButton.styleFrom(
              backgroundColor: widget.enabled
                  ? widget.colors.accent.withValues(alpha: 0.15)
                  : Colors.transparent,
              shape: const CircleBorder(),
              minimumSize: Size(isCompact ? 48 : 40, isCompact ? 48 : 40),
            ),
          ),
        ],
      ),
    );
  }
}

class CodeElementBuilder extends MarkdownElementBuilder {
  @override
  Widget? visitElementAfter(md.Element element, TextStyle? preferredStyle) {
    if (!element.textContent.endsWith('\n')) {
      return null;
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
              fontFamily: 'monospace',
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
