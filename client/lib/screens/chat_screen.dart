import 'dart:async';
import 'dart:io';
import 'dart:ui' as ui;
import 'package:flutter/gestures.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:file_picker/file_picker.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:markdown/markdown.dart' as md;

import '../models/message.dart';
import '../services/app_settings.dart';
import '../services/bootstrap_service.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';
import 'components/approval_dialog.dart';
import 'mcp_settings_screen.dart';
import 'voice_settings_screen.dart';

part 'chat_screen_sidebar.dart';
part 'chat_screen_sidebar_widgets.dart';
part 'chat_screen_message_list.dart';
part 'chat_screen_message_bubbles.dart';
part 'chat_screen_input_bar.dart';

class ChatScreen extends StatefulWidget {
  const ChatScreen({super.key});

  @override
  State<ChatScreen> createState() => _ChatScreenState();
}

class _ChatScreenState extends State<ChatScreen> {
  final TextEditingController _input = TextEditingController();
  final ScrollController _scroll = ScrollController();
  final FocusNode _focusNode = FocusNode();
  VoidCallback? _wsListener;

  bool _isSelectionMode = false;
  bool _loadingOlder = false;
  bool _pendingInitialBottom = true;
  bool _bottomJumpScheduled = false;
  int _lastMessageCount = 0;
  final Set<String> _selectedMessageIds = {};
  StreamSubscription? _authSubscription;
  StreamSubscription<Map<String, dynamic>>? _voiceSubscription;
  String? _pendingFileName;
  bool _isUploadingAttachment = false;
  double _uploadProgress = 0;
  String? _uploadError;
  Map<String, dynamic>? _uploadedAttachment;
  final Set<String> _ttsReadyMessageIds = <String>{};
  final Set<String> _ttsGeneratingMessageIds = <String>{};
  final Set<String> _ttsRequestedMessageIds = <String>{};
  bool _pendingAutoTts = false;
  bool _lastGeneratingState = false;

  String _readableUploadError(Object e) {
    final raw = e.toString().trim();
    if (raw.startsWith('Exception:')) {
      return raw.substring('Exception:'.length).trim();
    }
    return raw;
  }

  @override
  void initState() {
    super.initState();
    // 页面启动后统一注册 WS 事件监听：审批、语音事件与消息变化。
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ws = context.read<WsService>();
      _authSubscription = ws.authRequests.listen(_handleAuthRequest);
      _voiceSubscription = ws.voiceEvents.listen(_handleVoiceEvent);
      _lastMessageCount = ws.messages.length;
      _lastGeneratingState = ws.isGenerating;
      _wsListener = () {
        if (!mounted) return;
        // 清理已被删除消息对应的本地 TTS 状态，防止集合残留。
        final aliveIds = ws.messages.map((m) => m.id).toSet();
        _ttsReadyMessageIds.removeWhere((id) => !aliveIds.contains(id));
        _ttsGeneratingMessageIds.removeWhere((id) => !aliveIds.contains(id));
        _ttsRequestedMessageIds.removeWhere((id) => !aliveIds.contains(id));

        for (final msg in ws.messages) {
          if (msg.sender == MessageSender.ai &&
              !msg.isTyping &&
              ws.hasTtsAudio(msg.id)) {
            _ttsReadyMessageIds.add(msg.id);
          }
        }

        final count = ws.messages.length;
        if (count == 0) {
          _pendingInitialBottom = true;
        }

        // 新消息增长时，若用户在底部附近则自动贴底。
        final grew = count > _lastMessageCount;
        if (grew && !_loadingOlder) {
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (!_scroll.hasClients) return;
            final nearBottom =
                (_scroll.position.maxScrollExtent - _scroll.position.pixels) <
                80;
            if (_pendingInitialBottom || nearBottom) {
              _scroll.jumpTo(_scroll.position.maxScrollExtent);
              _pendingInitialBottom = false;
            }
          });
        }

        _maybeTriggerAutoTts(ws);

        _lastMessageCount = count;
        _lastGeneratingState = ws.isGenerating;
      };
      ws.addListener(_wsListener!);
    });
    _scroll.addListener(_onScrollMaybeLoadOlder);
  }

  void _handleAuthRequest(Map<String, dynamic> request) {
    if (!mounted) return;

    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => ApprovalDialog(
        authRequest: request,
        onDecision: (decision) {
          final ws = context.read<WsService>();
          ws.sendAuthResponse(request['message_id'], decision);
          Navigator.pop(context);
        },
      ),
    );
  }

  void _handleVoiceEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final ws = context.read<WsService>();

    final type = event['type'] as String? ?? '';
    final payload = event['payload'] as Map<String, dynamic>? ?? {};
    final turnId = (payload['turn_id'] as String? ?? '').trim();

    if (turnId.isEmpty) return;

    if (type == 'TTS_STREAM_START') {
      setState(() {
        _ttsGeneratingMessageIds.add(turnId);
      });
      return;
    }

    if (type == 'TTS_STREAM_END') {
      final status = (payload['status'] as String? ?? '').trim().toLowerCase();
      setState(() {
        _ttsGeneratingMessageIds.remove(turnId);
        if (status == 'success' && ws.hasTtsAudio(turnId)) {
          _ttsReadyMessageIds.add(turnId);
        }
      });
      return;
    }
  }

  void _maybeTriggerAutoTts(WsService ws) {
    final settings = context.read<AppSettings>();
    if (!settings.enableAiVoiceOutput) return;

    // 仅在“本轮生成刚结束”时尝试自动朗读，避免每次 setState 都触发。
    if (!(_lastGeneratingState && !ws.isGenerating)) {
      return;
    }

    if (!_pendingAutoTts) return;

    ChatMessage? latestAi;
    for (var i = ws.messages.length - 1; i >= 0; i--) {
      final msg = ws.messages[i];
      if (msg.sender == MessageSender.ai &&
          !msg.isTyping &&
          msg.content.trim().isNotEmpty) {
        latestAi = msg;
        break;
      }
    }

    if (latestAi == null) return;
    if (_ttsRequestedMessageIds.contains(latestAi.id)) {
      _pendingAutoTts = false;
      return;
    }

    _pendingAutoTts = false;
    _ttsRequestedMessageIds.add(latestAi.id);
    _ttsGeneratingMessageIds.add(latestAi.id);

    ws.requestVoiceTts(
      text: latestAi.content,
      turnId: latestAi.id,
      voiceId: settings.ttsVoiceId,
    );

    setState(() {});
  }

  Future<void> _onReadAloudTap(WsService ws, ChatMessage msg) async {
    // 点同一条且正在播放时，行为切换为“停止”。
    if (msg.isTyping || msg.content.trim().isEmpty) return;

    if (ws.playingTtsTurnId == msg.id && ws.isTtsPlaying) {
      await ws.stopTtsAudio();
      return;
    }

    if (ws.hasTtsAudio(msg.id)) {
      try {
        await ws.playTtsAudio(msg.id);
      } catch (e) {
        if (!mounted) return;
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(SnackBar(content: Text('播放失败: $e')));
      }
      return;
    }

    if (_ttsGeneratingMessageIds.contains(msg.id)) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('语音仍在生成中，请稍候')));
      return;
    }

    final settings = context.read<AppSettings>();
    setState(() {
      _ttsRequestedMessageIds.add(msg.id);
      _ttsGeneratingMessageIds.add(msg.id);
    });

    ws.requestVoiceTts(
      text: msg.content,
      turnId: msg.id,
      voiceId: settings.ttsVoiceId,
    );

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('已开始生成语音')));
  }

  @override
  void dispose() {
    final ws = context.read<WsService>();
    if (_wsListener != null) {
      ws.removeListener(_wsListener!);
    }
    _scroll.removeListener(_onScrollMaybeLoadOlder);
    _authSubscription?.cancel();
    _voiceSubscription?.cancel();
    _input.dispose();
    _scroll.dispose();
    _focusNode.dispose();
    super.dispose();
  }

  void _onScrollMaybeLoadOlder() {
    if (_loadingOlder || _isSelectionMode || !_scroll.hasClients) return;
    if (_scroll.position.pixels <= 60) {
      unawaited(_loadOlderMessages());
    }
  }

  Future<void> _loadOlderMessages() async {
    final ws = context.read<WsService>();
    if (_loadingOlder || ws.isHistoryLoading || !ws.hasMoreHistory) return;
    if (ws.messages.isEmpty) return;

    _loadingOlder = true;
    final beforeMax = _scroll.hasClients
        ? _scroll.position.maxScrollExtent
        : 0.0;
    final beforePixels = _scroll.hasClients ? _scroll.position.pixels : 0.0;

    try {
      await ws.loadOlderHistory();
    } finally {
      if (!mounted) {
        _loadingOlder = false;
      } else {
        WidgetsBinding.instance.addPostFrameCallback((_) {
          if (_scroll.hasClients) {
            // 翻页后修正滚动位置，保持视觉锚点不跳。
            final afterMax = _scroll.position.maxScrollExtent;
            final delta = afterMax - beforeMax;
            final target = (beforePixels + delta).clamp(
              0.0,
              _scroll.position.maxScrollExtent,
            );
            _scroll.jumpTo(target);
          }
          _loadingOlder = false;
        });
      }
    }
  }

  void _ensureInitialBottomIfNeeded(WsService ws) {
    if (!_pendingInitialBottom || _bottomJumpScheduled) return;
    if (ws.messages.isEmpty || _loadingOlder) return;

    _bottomJumpScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) {
        _bottomJumpScheduled = false;
        return;
      }

      if (_scroll.hasClients) {
        _scroll.jumpTo(_scroll.position.maxScrollExtent);
      }

      Future<void>.delayed(const Duration(milliseconds: 30), () {
        if (!mounted) {
          _bottomJumpScheduled = false;
          return;
        }
        if (_scroll.hasClients) {
          _scroll.jumpTo(_scroll.position.maxScrollExtent);
        }
        _pendingInitialBottom = false;
        _bottomJumpScheduled = false;
      });
    });
  }

  void _send(WsService ws) {
    if (_isUploadingAttachment) return;

    final text = _input.text.trim();
    final attachments = _uploadedAttachment != null
        ? <Map<String, dynamic>>[_uploadedAttachment!]
        : const <Map<String, dynamic>>[];
    if (text.isEmpty && attachments.isEmpty) return;

    // 文本与附件统一走 sendMessage，具体拆分在 WsService 内完成。
    ws.sendMessage(text, attachments: attachments);
    if (ws.isTtsPlaying) {
      unawaited(ws.stopTtsAudio());
      ws.interruptVoice();
    }
    final settings = context.read<AppSettings>();
    if (settings.enableAiVoiceOutput) {
      _pendingAutoTts = true;
    }
    _input.clear();
    setState(() {
      _pendingFileName = null;
      _isUploadingAttachment = false;
      _uploadProgress = 0;
      _uploadError = null;
      _uploadedAttachment = null;
    });
    _focusNode.requestFocus();
    WidgetsBinding.instance.addPostFrameCallback((_) => _scrollToBottom());
  }

  void _scrollToBottom() {
    if (_scroll.hasClients) {
      _scroll.animateTo(
        _scroll.position.maxScrollExtent,
        duration: const Duration(milliseconds: 300),
        curve: Curves.easeOut,
      );
    }
  }

  void _toggleSelectionMode() {
    setState(() {
      _isSelectionMode = !_isSelectionMode;
      if (!_isSelectionMode) {
        _selectedMessageIds.clear();
      }
    });
  }

  void _toggleMessageSelection(String messageId) {
    setState(() {
      if (_selectedMessageIds.contains(messageId)) {
        _selectedMessageIds.remove(messageId);
        if (_selectedMessageIds.isEmpty) {
          _isSelectionMode = false;
        }
      } else {
        _selectedMessageIds.add(messageId);
      }
    });
  }

  void _setSelectedMessages(Set<String> messageIds) {
    setState(() {
      _selectedMessageIds
        ..clear()
        ..addAll(messageIds);
      _isSelectionMode = _selectedMessageIds.isNotEmpty;
    });
  }

  void _deleteSelectedMessages(WsService ws) {
    if (_selectedMessageIds.isEmpty) return;
    ws.removeMessages(_selectedMessageIds);
    setState(() {
      _isSelectionMode = false;
      _selectedMessageIds.clear();
    });
  }

  Future<void> _confirmDeleteMessages(
    WsService ws,
    Set<String> messageIds,
  ) async {
    if (messageIds.isEmpty) return;
    final count = messageIds.length;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除消息'),
        content: Text(count == 1 ? '确定删除这条消息吗？' : '确定删除选中的 $count 条消息吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );

    if (ok == true) {
      ws.removeMessages(messageIds);
      if (!mounted) return;
      if (_isSelectionMode) {
        setState(() {
          _selectedMessageIds.removeAll(messageIds);
          if (_selectedMessageIds.isEmpty) {
            _isSelectionMode = false;
          }
        });
      }
    }
  }

  Future<void> _onAttach(WsService ws) async {
    if (_isUploadingAttachment) return;

    if (ws.status != WsStatus.connected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前未连接，无法上传附件')));
      return;
    }

    final result = await FilePicker.platform.pickFiles(
      type: FileType.any,
      allowMultiple: false,
      withData: false,
    );
    if (!mounted) return;
    if (result == null || result.files.isEmpty) return;
    final file = result.files.single;
    final filePath = file.path;
    if (filePath == null || filePath.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('无法读取文件路径')));
      return;
    }

    // 进入“上传中”UI 状态。
    setState(() {
      _pendingFileName = file.name;
      _isUploadingAttachment = true;
      _uploadProgress = 0;
      _uploadError = null;
      _uploadedAttachment = null;
    });

    try {
      final attachment = await ws.uploadFile(
        filePath,
        onProgress: (progress) {
          if (!mounted) return;
          setState(() {
            _uploadProgress = progress.clamp(0, 1);
          });
        },
      );
      if (!mounted) return;
      setState(() {
        // 上传成功后仅缓存附件，不立即发送；由用户按发送键触发。
        _uploadedAttachment = attachment;
        _isUploadingAttachment = false;
        _uploadProgress = 1;
      });
    } catch (e) {
      if (!mounted) return;
      final err = _readableUploadError(e);
      setState(() {
        _isUploadingAttachment = false;
        _uploadError = err;
      });
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(SnackBar(content: Text('上传失败: $err')));
    }
  }

  void _clearAttachmentState() {
    setState(() {
      _pendingFileName = null;
      _isUploadingAttachment = false;
      _uploadProgress = 0;
      _uploadError = null;
      _uploadedAttachment = null;
    });
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>()!;
    final ws = context.watch<WsService>();
    final settings = context.watch<AppSettings>();
    final screenWidth = MediaQuery.of(context).size.width;
    final isCompact = screenWidth < 920;

    _ensureInitialBottomIfNeeded(ws);

    final chatMain = Column(
      children: [
        Builder(
          builder: (scaffoldContext) => _TopBar(
            colors: colors,
            ws: ws,
            activePersonaId: ws.activePersonaId,
            isSelectionMode: _isSelectionMode,
            selectedCount: _selectedMessageIds.length,
            onCancelSelection: _toggleSelectionMode,
            onDeleteSelected: () => _deleteSelectedMessages(ws),
            onOpenSidebar: isCompact
                ? () => Scaffold.of(scaffoldContext).openDrawer()
                : null,
          ),
        ),
        Divider(height: 1, color: colors.divider),
        Expanded(
          child: _MessageList(
            messages: ws.messages,
            activePersonaId: ws.activePersonaId,
            scroll: _scroll,
            colors: colors,
            isSelectionMode: _isSelectionMode,
            selectedMessageIds: _selectedMessageIds,
            onToggleSelection: _toggleMessageSelection,
            onSetSelection: _setSelectedMessages,
            onEnterSelectionMode: () {
              if (!_isSelectionMode) _toggleSelectionMode();
            },
            onDeleteMessage: (msgId) {
              unawaited(_confirmDeleteMessages(ws, {msgId}));
            },
            enableAiVoiceOutput: settings.enableAiVoiceOutput,
            ttsReadyMessageIds: _ttsReadyMessageIds,
            ttsGeneratingMessageIds: _ttsGeneratingMessageIds,
            playingTtsMessageId: ws.playingTtsTurnId,
            isTtsPlaying: ws.isTtsPlaying,
            onReadAloudTap: (msg) => _onReadAloudTap(ws, msg),
          ),
        ),
        Divider(height: 1, color: colors.divider),
        Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (_pendingFileName != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: ConstrainedBox(
                    constraints: BoxConstraints(
                      maxWidth: MediaQuery.of(context).size.width * 0.62,
                    ),
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        color: colors.inputBg,
                        borderRadius: BorderRadius.circular(12),
                        border: Border.all(color: colors.divider),
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.insert_drive_file_outlined,
                            color: colors.accent,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  _pendingFileName!,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: Theme.of(
                                      context,
                                    ).colorScheme.onSurface,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                if (_isUploadingAttachment)
                                  Row(
                                    children: [
                                      Expanded(
                                        child: ClipRRect(
                                          borderRadius: BorderRadius.circular(
                                            6,
                                          ),
                                          child: LinearProgressIndicator(
                                            value: _uploadProgress,
                                            minHeight: 5,
                                            backgroundColor: colors.divider,
                                            valueColor:
                                                AlwaysStoppedAnimation<Color>(
                                                  colors.accent,
                                                ),
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 6),
                                      Text(
                                        '${(_uploadProgress * 100).toStringAsFixed(0)}%',
                                        style: TextStyle(
                                          color: colors.subtext,
                                          fontSize: 11,
                                        ),
                                      ),
                                    ],
                                  )
                                else
                                  Text(
                                    _uploadError != null
                                        ? '失败: $_uploadError'
                                        : '上传完成',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      color: _uploadError != null
                                          ? Colors.redAccent
                                          : const Color(0xFF4CAF50),
                                      fontSize: 11,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          IconButton(
                            onPressed: _isUploadingAttachment
                                ? null
                                : _clearAttachmentState,
                            icon: Icon(
                              Icons.close_rounded,
                              color: colors.subtext,
                              size: 16,
                            ),
                            splashRadius: 14,
                            padding: EdgeInsets.zero,
                            constraints: const BoxConstraints(
                              minWidth: 24,
                              minHeight: 24,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            _InputBar(
              controller: _input,
              focusNode: _focusNode,
              colors: colors,
              activePersonaId: ws.activePersonaId,
              onSend: () => _send(ws),
              onAttach: () {
                _onAttach(ws);
              },
              enabled:
                  ws.status == WsStatus.connected &&
                  !ws.isGenerating &&
                  !_isUploadingAttachment,
              isGenerating: ws.isGenerating,
            ),
          ],
        ),
      ],
    );

    return Scaffold(
      drawer: isCompact
          ? Drawer(
              width: (screenWidth * 0.62).clamp(220.0, 280.0),
              child: SafeArea(
                child: _Sidebar(
                  colors: colors,
                  ws: ws,
                  onPersonaSelected: () {
                    if (Navigator.of(context).canPop()) {
                      Navigator.of(context).pop();
                    }
                  },
                ),
              ),
            )
          : null,
      body: isCompact
          ? chatMain
          : Row(
              children: [
                _Sidebar(colors: colors, ws: ws),
                VerticalDivider(width: 1, color: colors.divider),
                Expanded(child: chatMain),
              ],
            ),
    );
  }
}

// ─── 左侧栏 ─────────────────────────────────────────────────────────────────
