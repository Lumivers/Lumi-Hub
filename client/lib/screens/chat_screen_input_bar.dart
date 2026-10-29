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
  String? _suggestionType; // 'action' for '/', 'mention' for '@'
  String _query = '';
  int _selectedIndex = 0;

  static const _allActions = [
    {
      'name': 'plan',
      'title': '/plan',
      'desc': '规划任务，分解目标，生成可执行步骤与子任务',
      'icon': Icons.splitscreen_rounded,
    },
    {
      'name': 'grill-me',
      'title': '/grill-me',
      'desc': '反问用户，帮助澄清需求，避免误解与偏差',
      'icon': Icons.help_outline_rounded,
    },
    {
      'name': 'compact',
      'title': '/compact',
      'desc': '压缩上下文，提炼历史记忆，释放空间',
      'icon': Icons.compress_rounded,
    },
    {
      'name': 'goal',
      'title': '/goal',
      'desc': '自主长程模式，自闭环运行直到目标达成',
      'icon': Icons.track_changes_rounded,
    },
    {
      'name': 'btw',
      'title': '/btw',
      'desc': '旁路提问：不打断当前主任务，快速查阅旁门信息',
      'icon': Icons.mark_unread_chat_alt_outlined,
    },
    {
      'name': 'teamwork',
      'title': '/teamwork',
      'desc': '多 Agent 协同：调动多角色专家并行处理复杂任务',
      'icon': Icons.hub_outlined,
    },
    {
      'name': 'browser',
      'title': '/browser',
      'desc': '调起浏览器：执行自动化网页操作与信息检索',
      'icon': Icons.language_rounded,
    },
    {
      'name': 'code-reviewer',
      'title': '/code-reviewer',
      'desc': '技能：自动化代码审查与质量漏洞排查',
      'icon': Icons.fact_check_outlined,
    },
    {
      'name': 'daily-summary',
      'title': '/daily-summary',
      'desc': '技能：汇总今日代码提交与任务进度简报',
      'icon': Icons.summarize_outlined,
    },
  ];

  static const _allMentions = [
    {
      'name': 'Files',
      'title': '@Files',
      'desc': '挂载并引用工作区代码文件',
      'icon': Icons.attach_file_rounded,
    },
    {
      'name': 'Folder',
      'title': '@Folder',
      'desc': '挂载并引用工作区目录树结构',
      'icon': Icons.folder_open_rounded,
    },
    {
      'name': 'Rules',
      'title': '@Rules',
      'desc': '注入项目编码规范与准则',
      'icon': Icons.menu_book_rounded,
    },
    {
      'name': 'Conversation',
      'title': '@Conversation',
      'desc': '引用历史会话或子任务上下文记忆',
      'icon': Icons.forum_outlined,
    },
    {
      'name': 'Git',
      'title': '@Git',
      'desc': '引用最近的 Git 提交记录与改动 Diff',
      'icon': Icons.commit_rounded,
    },
  ];

  @override
  void initState() {
    super.initState();
    widget.controller.addListener(_onTextChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(_onTextChanged);
    super.dispose();
  }

  void _onTextChanged() {
    final text = widget.controller.text;
    final sel = widget.controller.selection;
    if (sel.baseOffset < 0 || sel.baseOffset > text.length) {
      if (_suggestionType != null) setState(() => _suggestionType = null);
      return;
    }

    final textBeforeCursor = text.substring(0, sel.baseOffset);
    final lastSlash = textBeforeCursor.lastIndexOf('/');
    final lastAt = textBeforeCursor.lastIndexOf('@');

    // 检查 / 动作指令 (位于句首或空格后)
    if (lastSlash >= 0 && (lastSlash == 0 || textBeforeCursor[lastSlash - 1].trim().isEmpty)) {
      final q = textBeforeCursor.substring(lastSlash + 1);
      if (!q.contains(' ') && !q.contains('\n')) {
        if (_suggestionType != 'action' || _query != q.toLowerCase()) {
          setState(() {
            _suggestionType = 'action';
            _query = q.toLowerCase();
            _selectedIndex = 0;
          });
        }
        return;
      }
    }

    // 检查 @ 上下文引用 (位于句首或空格后)
    if (lastAt >= 0 && (lastAt == 0 || textBeforeCursor[lastAt - 1].trim().isEmpty)) {
      final q = textBeforeCursor.substring(lastAt + 1);
      if (!q.contains(' ') && !q.contains('\n')) {
        if (_suggestionType != 'mention' || _query != q.toLowerCase()) {
          setState(() {
            _suggestionType = 'mention';
            _query = q.toLowerCase();
            _selectedIndex = 0;
          });
        }
        return;
      }
    }

    if (_suggestionType != null) {
      setState(() {
        _suggestionType = null;
        _query = '';
      });
    }
  }

  List<Map<String, dynamic>> _filteredSuggestions() {
    if (_suggestionType == 'action') {
      if (_query.isEmpty) return _allActions;
      return _allActions.where((a) => (a['name'] as String).toLowerCase().contains(_query)).toList();
    } else if (_suggestionType == 'mention') {
      if (_query.isEmpty) return _allMentions;
      return _allMentions.where((m) => (m['name'] as String).toLowerCase().contains(_query)).toList();
    }
    return const [];
  }

  void _applySuggestion(Map<String, dynamic> item) {
    final text = widget.controller.text;
    final sel = widget.controller.selection;
    final offset = (sel.baseOffset >= 0 && sel.baseOffset <= text.length) ? sel.baseOffset : text.length;
    final textBeforeCursor = text.substring(0, offset);
    final textAfterCursor = text.substring(offset);

    if (_suggestionType == 'action') {
      final lastSlash = textBeforeCursor.lastIndexOf('/');
      if (lastSlash >= 0) {
        final prefix = textBeforeCursor.substring(0, lastSlash);
        final cmd = '/${item['name']} ';
        final newText = '$prefix$cmd$textAfterCursor';
        widget.controller.value = TextEditingValue(
          text: newText,
          selection: TextSelection.collapsed(offset: prefix.length + cmd.length),
        );
      }
    } else if (_suggestionType == 'mention') {
      final lastAt = textBeforeCursor.lastIndexOf('@');
      if (lastAt >= 0) {
        final name = item['name'] as String;
        if (name == 'Files') {
          final prefix = textBeforeCursor.substring(0, lastAt);
          final newText = '$prefix$textAfterCursor';
          widget.controller.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: prefix.length),
          );
          widget.onAttach();
        } else {
          final prefix = textBeforeCursor.substring(0, lastAt);
          final mention = '@$name ';
          final newText = '$prefix$mention$textAfterCursor';
          widget.controller.value = TextEditingValue(
            text: newText,
            selection: TextSelection.collapsed(offset: prefix.length + mention.length),
          );
        }
      }
    }

    setState(() {
      _suggestionType = null;
      _query = '';
    });
  }

  /// Enter 发送，Shift+Enter 换行，空输入框按向上键快速撤回上一次消息
  KeyEventResult _handleKey(FocusNode node, KeyEvent event) {
    if (event is! KeyDownEvent && event is! KeyRepeatEvent) {
      return KeyEventResult.ignored;
    }

    // 若有联想弹窗处于激活状态，优先处理导航与选中
    if (_suggestionType != null) {
      final suggestions = _filteredSuggestions();
      if (suggestions.isNotEmpty) {
        if (event.logicalKey == LogicalKeyboardKey.arrowDown) {
          setState(() {
            _selectedIndex = (_selectedIndex + 1) % suggestions.length;
          });
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.arrowUp) {
          setState(() {
            _selectedIndex = (_selectedIndex - 1 + suggestions.length) % suggestions.length;
          });
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.escape) {
          setState(() => _suggestionType = null);
          return KeyEventResult.handled;
        }
        if (event.logicalKey == LogicalKeyboardKey.tab ||
            event.logicalKey == LogicalKeyboardKey.enter ||
            event.logicalKey == LogicalKeyboardKey.numpadEnter) {
          final idx = _selectedIndex.clamp(0, suggestions.length - 1);
          _applySuggestion(suggestions[idx]);
          return KeyEventResult.handled;
        }
      }
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

  Widget _buildSuggestionCard(BuildContext context, List<Map<String, dynamic>> list) {
    final isAction = _suggestionType == 'action';
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Container(
        constraints: const BoxConstraints(maxHeight: 250),
        decoration: BoxDecoration(
          color: widget.colors.inputBg,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(
            color: widget.colors.divider.withValues(alpha: 0.7),
          ),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.25),
              blurRadius: 16,
              offset: const Offset(0, -4),
            ),
          ],
        ),
        child: ClipRRect(
          borderRadius: BorderRadius.circular(12),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
                color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.25),
                child: Row(
                  children: [
                    Text(
                      isAction ? 'ACTIONS / COMMANDS' : 'CONTEXT MENTIONS',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        letterSpacing: 0.6,
                        color: widget.colors.subtext,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '↑↓ 切换 · Tab/Enter 选定 · Esc 关闭',
                      style: TextStyle(
                        fontSize: 10,
                        color: widget.colors.subtext.withValues(alpha: 0.7),
                      ),
                    ),
                  ],
                ),
              ),
              Flexible(
                child: ListView.separated(
                  shrinkWrap: true,
                  padding: const EdgeInsets.symmetric(vertical: 4),
                  itemCount: list.length,
                  separatorBuilder: (ctx, i) => Divider(
                    height: 1,
                    color: widget.colors.divider.withValues(alpha: 0.15),
                  ),
                  itemBuilder: (ctx, i) {
                    final item = list[i];
                    final isSelected = i == _selectedIndex;
                    return InkWell(
                      onTap: () => _applySuggestion(item),
                      child: Container(
                        color: isSelected ? widget.colors.accent.withValues(alpha: 0.12) : Colors.transparent,
                        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7.5),
                        child: Row(
                          children: [
                            Icon(
                              item['icon'] as IconData,
                              size: 16,
                              color: isSelected ? widget.colors.accent : widget.colors.subtext,
                            ),
                            const SizedBox(width: 10),
                            Text(
                              item['title'] as String,
                              style: TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                                color: isSelected
                                    ? widget.colors.accent
                                    : Theme.of(context).colorScheme.onSurface,
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: Text(
                                item['desc'] as String,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: widget.colors.subtext,
                                ),
                              ),
                            ),
                          ],
                        ),
                      ),
                    );
                  },
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final isCompact = MediaQuery.of(context).size.width <= 640;
    final effortText = _formatReasoningEffort(widget.ws.reasoningEffort);
    final modelName = widget.ws.activeModelName.isNotEmpty ? widget.ws.activeModelName : '默认模型';
    final suggestions = _filteredSuggestions();

    return Padding(
      padding: EdgeInsets.symmetric(
        horizontal: isCompact ? 10 : 14,
        vertical: isCompact ? 8 : 8,
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          if (_suggestionType != null && suggestions.isNotEmpty)
            _buildSuggestionCard(context, suggestions),
          Container(
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
    ],
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
