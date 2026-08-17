import 'dart:async';
import 'dart:io';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:flutter_markdown/flutter_markdown.dart';

import '../models/message.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';
import '../widgets/live2d_view.dart';

/// 窗口模式控制器：管理桌面桌宠与主工作台大窗口的无缝切换
class WindowModeController {
  static Size? _savedWorkspaceSize;
  static Offset? _savedWorkspacePosition;
  static bool _isPetMode = false;

  static bool get isPetMode => _isPetMode;

  /// 进入无边框沉浸桌面挂件模式
  static Future<void> enterPetMode({bool showChat = false}) async {
    if (kIsWeb || !Platform.isWindows) return;
    if (!_isPetMode) {
      _savedWorkspaceSize = await windowManager.getSize();
      _savedWorkspacePosition = await windowManager.getPosition();
      _isPetMode = true;
    }

    final targetSize = showChat ? const Size(740, 560) : const Size(320, 500);
    await windowManager.setTitleBarStyle(TitleBarStyle.hidden);
    await windowManager.setMinimumSize(const Size(260, 400));
    await windowManager.setBackgroundColor(Colors.transparent);
    await windowManager.setHasShadow(false);
    await windowManager.setAlwaysOnTop(true);
    await windowManager.setSize(targetSize);
  }

  /// 调整挂件模式下展开/收起聊天的窗口宽度
  static Future<void> updatePetChatExpanded(bool expanded) async {
    if (kIsWeb || !Platform.isWindows || !_isPetMode) return;
    final targetSize = expanded ? const Size(740, 560) : const Size(320, 500);
    await windowManager.setSize(targetSize);
  }

  /// 退出桌宠模式，还原为主工作台大窗口
  static Future<void> exitPetMode() async {
    if (kIsWeb || !Platform.isWindows) return;
    _isPetMode = false;
    await windowManager.setTitleBarStyle(TitleBarStyle.normal);
    await windowManager.setAlwaysOnTop(false);
    await windowManager.setHasShadow(true);
    await windowManager.setBackgroundColor(const Color(0xFF14181F));
    await windowManager.setMinimumSize(const Size(800, 600));
    if (_savedWorkspaceSize != null) {
      await windowManager.setSize(_savedWorkspaceSize!);
    } else {
      await windowManager.setSize(const Size(1200, 800));
    }
    if (_savedWorkspacePosition != null) {
      await windowManager.setPosition(_savedWorkspacePosition!);
    } else {
      await windowManager.center();
    }
  }
}

/// 完美对齐 Firefly 桌宠形态的 Live2D 桌面伴侣视窗 (无标题栏 + 纯净立绘)
class Live2dCompanionScreen extends StatefulWidget {
  const Live2dCompanionScreen({super.key});

  /// 打开桌宠伴侣视窗
  static void open(BuildContext context) {
    Navigator.of(context).push(
      PageRouteBuilder(
        pageBuilder: (ctx, anim1, anim2) => const Live2dCompanionScreen(),
        transitionsBuilder: (ctx, anim1, anim2, child) =>
            FadeTransition(opacity: anim1, child: child),
      ),
    );
  }

  @override
  State<Live2dCompanionScreen> createState() => _Live2dCompanionScreenState();
}

class _Live2dCompanionScreenState extends State<Live2dCompanionScreen> {
  final TextEditingController _inputController = TextEditingController();
  final ScrollController _chatScroll = ScrollController();
  final FocusNode _inputFocus = FocusNode();

  static const List<String> _greetings = [
    '你好！今天也要加油哦~ ✨',
    '有什么想和我聊聊的吗？',
    '随时都在这里陪着你呢~ 🌸',
    '累了的话就稍微休息一下吧！☕',
    '今天有什么新灵感吗？💡',
    '你好呀！准备好开始了吗？👋',
    '有什么需要帮助的吗？✨',
  ];

  bool _showChatPanel = false; // 默认纯净小人，点击小人呼出右侧对话卡片
  bool _isAlwaysOnTop = true;
  bool _showGreetingBubble = true;
  String _currentGreeting = '你好！有什么想聊的吗？';
  int _lastMsgCount = 0;
  String _lastMsgContent = '';
  Timer? _greetingTimer;
  final Random _random = Random();

  @override
  void initState() {
    super.initState();
    _showGreeting();
    WindowModeController.enterPetMode(showChat: _showChatPanel);
  }

  void _showGreeting() {
    setState(() {
      _currentGreeting = _greetings[_random.nextInt(_greetings.length)];
      _showGreetingBubble = true;
    });
    _greetingTimer?.cancel();
    _greetingTimer = Timer(const Duration(seconds: 5), () {
      if (mounted) {
        setState(() => _showGreetingBubble = false);
      }
    });
  }

  void _toggleChatPanel() {
    _showGreeting();
    setState(() {
      _showChatPanel = !_showChatPanel;
    });
    WindowModeController.updatePetChatExpanded(_showChatPanel);
    if (_showChatPanel) {
      _scrollToBottom();
    }
  }

  void _sendMessage(WsService ws) {
    final text = _inputController.text.trim();
    if (text.isEmpty) return;
    _inputController.clear();
    ws.sendMessage(text);
    _scrollToBottom();
  }

  void _scrollToBottom() {
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_chatScroll.hasClients) {
        _chatScroll.animateTo(
          _chatScroll.position.maxScrollExtent,
          duration: const Duration(milliseconds: 200),
          curve: Curves.easeOut,
        );
      }
    });
  }

  Future<void> _restoreToWorkspace() async {
    await WindowModeController.exitPetMode();
    if (mounted) {
      Navigator.of(context).pop();
    }
  }

  @override
  void dispose() {
    _greetingTimer?.cancel();
    _inputController.dispose();
    _chatScroll.dispose();
    _inputFocus.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>() ??
        (Theme.of(context).brightness == Brightness.dark ? LumiColors.dark() : LumiColors.light());
    final ws = context.watch<WsService>();
    final messages = ws.messages;

    // 监听消息变化并平滑自动滚屏
    if (messages.isNotEmpty) {
      final last = messages.last;
      if (messages.length != _lastMsgCount || last.content != _lastMsgContent) {
        _lastMsgCount = messages.length;
        _lastMsgContent = last.content;
        if (_showChatPanel) {
          _scrollToBottom();
        }
      }
    }

    return Scaffold(
      backgroundColor: Colors.transparent,
      body: DragToMoveArea(
        child: Stack(
          children: [
            // ── 左右主布局 (左侧 Live2D 小人 + 右侧 Firefly 弹出卡片) ──
            Positioned.fill(
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.end,
                children: [
                  // 1. 左侧：Live2D 角色与左上方斜侧打招呼小气泡 (弹性充满避免固定宽度溢出)
                  if (!_showChatPanel)
                    Expanded(
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          // 点击小人身体直接呼出/收起右侧卡片，并重新触发 5s 问候语
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _toggleChatPanel,
                              child: const Live2dView(),
                            ),
                          ),

                          // Firefly 风格斜上方打招呼小气泡 (拉高位置，显示 5s 后优雅淡出)
                          if (_showGreetingBubble)
                            Positioned(
                              top: 4,
                              left: 8,
                              child: GestureDetector(
                                onTap: _toggleChatPanel,
                                child: AnimatedOpacity(
                                  opacity: _showGreetingBubble ? 1.0 : 0.0,
                                  duration: const Duration(milliseconds: 300),
                                  child: _FireflySpeechBubble(text: _currentGreeting),
                                ),
                              ),
                            ),

                          // 小人右上方的微型隐形控制胶囊
                          Positioned(
                            top: 6,
                            right: 8,
                            child: Container(
                              padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 2),
                              decoration: BoxDecoration(
                                color: Colors.black.withValues(alpha: 0.35),
                                borderRadius: BorderRadius.circular(12),
                              ),
                              child: Row(
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  IconButton(
                                    icon: const Icon(Icons.fullscreen_exit, size: 14, color: Colors.white70),
                                    tooltip: '还原为主工作台大窗口',
                                    splashRadius: 10,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                                    onPressed: _restoreToWorkspace,
                                  ),
                                  const SizedBox(width: 2),
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 13, color: Colors.white60),
                                    tooltip: '退出桌宠',
                                    splashRadius: 10,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                                    onPressed: _restoreToWorkspace,
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ],
                      ),
                    )
                  else ...[
                    SizedBox(
                      width: 270,
                      child: Stack(
                        alignment: Alignment.bottomCenter,
                        children: [
                          Positioned.fill(
                            child: GestureDetector(
                              behavior: HitTestBehavior.opaque,
                              onTap: _toggleChatPanel,
                              child: const Live2dView(),
                            ),
                          ),
                          if (_showGreetingBubble)
                            Positioned(
                              top: 4,
                              left: 8,
                              child: GestureDetector(
                                onTap: _toggleChatPanel,
                                child: AnimatedOpacity(
                                  opacity: _showGreetingBubble ? 1.0 : 0.0,
                                  duration: const Duration(milliseconds: 300),
                                  child: _FireflySpeechBubble(text: _currentGreeting),
                                ),
                              ),
                            ),
                        ],
                      ),
                    ),
                  ],

                  // 2. 右侧：弹出式 Firefly 风格纯净深色对话卡片 (无多余标题，直接看内容)
                  if (_showChatPanel)
                    Expanded(
                      child: Container(
                        height: 520,
                        margin: const EdgeInsets.only(bottom: 12, right: 12, top: 12),
                        decoration: BoxDecoration(
                          color: const Color(0xFF1E232E).withValues(alpha: 0.96),
                          borderRadius: BorderRadius.circular(20),
                          border: Border.all(
                            color: Colors.white.withValues(alpha: 0.12),
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.45),
                              blurRadius: 22,
                              offset: const Offset(0, 8),
                            ),
                          ],
                        ),
                        child: Column(
                          children: [
                            // 顶部精简微按钮区 (还原大窗口 / 置顶 / 关闭)
                            Padding(
                              padding: const EdgeInsets.only(top: 8, right: 10, left: 14),
                              child: Row(
                                children: [
                                  Container(
                                    width: 7,
                                    height: 7,
                                    decoration: const BoxDecoration(
                                      color: Color(0xFF4CAF50),
                                      shape: BoxShape.circle,
                                    ),
                                  ),
                                  const Spacer(),
                                  // 置顶切换
                                  IconButton(
                                    icon: Icon(
                                      _isAlwaysOnTop ? Icons.push_pin : Icons.push_pin_outlined,
                                      size: 13,
                                      color: _isAlwaysOnTop ? colors.accent : Colors.white60,
                                    ),
                                    tooltip: _isAlwaysOnTop ? '取消置顶' : '窗口置顶',
                                    splashRadius: 10,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                                    onPressed: () async {
                                      setState(() => _isAlwaysOnTop = !_isAlwaysOnTop);
                                      if (!kIsWeb && Platform.isWindows) {
                                        await windowManager.setAlwaysOnTop(_isAlwaysOnTop);
                                      }
                                    },
                                  ),
                                  const SizedBox(width: 4),
                                  // 还原为主工作台大窗口
                                  IconButton(
                                    icon: const Icon(Icons.fullscreen_exit, size: 15, color: Colors.white70),
                                    tooltip: '还原为主工作台大窗口',
                                    splashRadius: 10,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                                    onPressed: _restoreToWorkspace,
                                  ),
                                  const SizedBox(width: 4),
                                  // 收起聊天面板
                                  IconButton(
                                    icon: const Icon(Icons.close, size: 15, color: Colors.white70),
                                    tooltip: '收起卡片',
                                    splashRadius: 10,
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(minWidth: 22, minHeight: 22),
                                    onPressed: _toggleChatPanel,
                                  ),
                                ],
                              ),
                            ),

                            // 完整的滚动聊天历史消息列表 (支持滚轮上下自由滚动)
                            Expanded(
                              child: messages.isEmpty
                                  ? Center(
                                      child: Padding(
                                        padding: const EdgeInsets.symmetric(horizontal: 20),
                                        child: Text(
                                          '你好！我是你的陪伴助手。有什么想和我聊聊的吗？',
                                          textAlign: TextAlign.center,
                                          style: TextStyle(
                                            color: Colors.white.withValues(alpha: 0.6),
                                            fontSize: 13,
                                            height: 1.4,
                                          ),
                                        ),
                                      ),
                                    )
                                  : ListView.builder(
                                      controller: _chatScroll,
                                      physics: const AlwaysScrollableScrollPhysics(
                                        parent: BouncingScrollPhysics(),
                                      ),
                                      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
                                      itemCount: messages.length,
                                      itemBuilder: (ctx, idx) {
                                        final msg = messages[idx];
                                        final isMe = msg.sender == MessageSender.me;
                                        return Padding(
                                          padding: const EdgeInsets.only(bottom: 12),
                                          child: Align(
                                            alignment: isMe ? Alignment.centerRight : Alignment.centerLeft,
                                            child: Container(
                                              padding: const EdgeInsets.symmetric(
                                                horizontal: 13,
                                                vertical: 10,
                                              ),
                                              constraints: const BoxConstraints(maxWidth: 320),
                                              decoration: BoxDecoration(
                                                color: isMe
                                                    ? colors.accent
                                                    : const Color(0xFF29303D),
                                                borderRadius: BorderRadius.circular(12),
                                              ),
                                              child: isMe
                                                  ? Text(
                                                      msg.content,
                                                      style: const TextStyle(fontSize: 13, color: Colors.white),
                                                    )
                                                : MarkdownBody(
                                                    data: msg.content.isEmpty && msg.isTyping
                                                        ? '正在思考...'
                                                        : msg.content,
                                                    styleSheet: MarkdownStyleSheet(
                                                      p: const TextStyle(
                                                        fontSize: 13,
                                                        color: Colors.white,
                                                        height: 1.4,
                                                      ),
                                                      code: TextStyle(
                                                        color: colors.accent,
                                                        backgroundColor: Colors.black26,
                                                        fontSize: 12,
                                                      ),
                                                    ),
                                                  ),
                                            ),
                                          ),
                                        );
                                      },
                                    ),
                            ),

                            // 底部输入框 (支持 Enter 发送)
                            Container(
                              padding: const EdgeInsets.all(10),
                              decoration: BoxDecoration(
                                border: Border(
                                  top: BorderSide(
                                    color: Colors.white.withValues(alpha: 0.08),
                                  ),
                                ),
                              ),
                              child: Row(
                                children: [
                                  Expanded(
                                    child: TextField(
                                      controller: _inputController,
                                      focusNode: _inputFocus,
                                      style: const TextStyle(color: Colors.white, fontSize: 13),
                                      decoration: InputDecoration(
                                        hintText: '输入你想聊的话题... (Enter 发送)',
                                        hintStyle: TextStyle(
                                          color: Colors.white.withValues(alpha: 0.4),
                                          fontSize: 12,
                                        ),
                                        isDense: true,
                                        contentPadding: const EdgeInsets.symmetric(
                                          horizontal: 14,
                                          vertical: 9,
                                        ),
                                        border: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(20),
                                          borderSide: BorderSide(
                                            color: Colors.white.withValues(alpha: 0.15),
                                          ),
                                        ),
                                        focusedBorder: OutlineInputBorder(
                                          borderRadius: BorderRadius.circular(20),
                                          borderSide: BorderSide(
                                            color: colors.accent,
                                          ),
                                        ),
                                      ),
                                      onSubmitted: (_) => _sendMessage(ws),
                                    ),
                                  ),
                                  const SizedBox(width: 8),
                                  Container(
                                    decoration: BoxDecoration(
                                      color: colors.accent,
                                      shape: BoxShape.circle,
                                    ),
                                    child: IconButton(
                                      icon: const Icon(Icons.send_rounded, size: 16, color: Colors.white),
                                      splashRadius: 16,
                                      padding: const EdgeInsets.all(8),
                                      constraints: const BoxConstraints(minWidth: 32, minHeight: 32),
                                      onPressed: () => _sendMessage(ws),
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
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

// ─── Firefly 风格斜侧打招呼小气泡 ────────────────────────────────────────────────

class _FireflySpeechBubble extends StatelessWidget {
  final String text;

  const _FireflySpeechBubble({required this.text});

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 160),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 7),
      decoration: BoxDecoration(
        color: const Color(0xFF262D38).withValues(alpha: 0.95),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.15),
        ),
        boxShadow: [
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.35),
            blurRadius: 10,
            offset: const Offset(0, 4),
          ),
        ],
      ),
      child: Text(
        text,
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        textAlign: TextAlign.center,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11.5,
          height: 1.3,
          fontWeight: FontWeight.w500,
        ),
      ),
    );
  }
}
