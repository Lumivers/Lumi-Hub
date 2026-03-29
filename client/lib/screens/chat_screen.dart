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
  String? _pendingFileName;
  bool _isUploadingAttachment = false;
  double _uploadProgress = 0;
  String? _uploadError;
  Map<String, dynamic>? _uploadedAttachment;

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
    // 监听审批请求
    WidgetsBinding.instance.addPostFrameCallback((_) {
      final ws = context.read<WsService>();
      _authSubscription = ws.authRequests.listen(_handleAuthRequest);
      _lastMessageCount = ws.messages.length;
      _wsListener = () {
        if (!mounted) return;
        final count = ws.messages.length;
        if (count == 0) {
          _pendingInitialBottom = true;
        }

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

        _lastMessageCount = count;
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

  @override
  void dispose() {
    final ws = context.read<WsService>();
    if (_wsListener != null) {
      ws.removeListener(_wsListener!);
    }
    _scroll.removeListener(_onScrollMaybeLoadOlder);
    _authSubscription?.cancel();
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

    ws.sendMessage(text, attachments: attachments);
    _input.clear();
    setState(() {
      _pendingFileName = null;
      _isUploadingAttachment = false;
      _uploadProgress = 0;
      _uploadError = null;
      _uploadedAttachment = null;
    });
    _focusNode.requestFocus();
    // 滚到底部
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

  Future<void> _onAttach(WsService ws) async {
    if (_isUploadingAttachment) return;

    if (ws.status != WsStatus.connected) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('未连接到 Host，暂时无法上传文件')));
      return;
    }
    if (!ws.isAuthenticated) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('当前未登录，无法上传文件')));
      return;
    }

    final picked = await FilePicker.platform.pickFiles(
      allowMultiple: false,
      type: FileType.custom,
      allowedExtensions: [
        'png',
        'jpg',
        'jpeg',
        'gif',
        'webp',
        'pdf',
        'mp4',
        'webm',
        'mov',
      ],
    );
    if (!mounted) return;

    if (picked == null || picked.files.isEmpty) {
      return;
    }

    final file = picked.files.first;
    final filePath = file.path;
    if (filePath == null || filePath.isEmpty) {
      ScaffoldMessenger.of(
        context,
      ).showSnackBar(const SnackBar(content: Text('文件路径无效，上传已取消')));
      return;
    }

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
              ws.removeMessages({msgId});
            },
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

class _Sidebar extends StatefulWidget {
  final LumiColors colors;
  final WsService ws;
  final VoidCallback? onPersonaSelected;

  const _Sidebar({
    required this.colors,
    required this.ws,
    this.onPersonaSelected,
  });

  @override
  State<_Sidebar> createState() => _SidebarState();
}

class _SidebarState extends State<_Sidebar> {
  StreamSubscription? _personaSub;
  List<String> _personaOrder = [];

  String _personaOrderStorageKey() {
    final uid = widget.ws.user?['id']?.toString() ?? 'guest';
    return 'persona_order_$uid';
  }

  Future<void> _loadPersonaOrder() async {
    final prefs = await SharedPreferences.getInstance();
    _personaOrder = prefs.getStringList(_personaOrderStorageKey()) ?? [];
    if (mounted) setState(() {});
  }

  Future<void> _savePersonaOrder() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList(_personaOrderStorageKey(), _personaOrder);
  }

  List<Map<String, dynamic>> _orderedPersonas(
    List<Map<String, dynamic>> personas,
  ) {
    if (personas.isEmpty) return personas;

    final byId = {for (final p in personas) (p['id'] as String? ?? ''): p};

    final ordered = <Map<String, dynamic>>[];
    final used = <String>{};

    for (final id in _personaOrder) {
      final p = byId[id];
      if (p != null) {
        ordered.add(p);
        used.add(id);
      }
    }

    for (final p in personas) {
      final id = p['id'] as String? ?? '';
      if (!used.contains(id)) {
        ordered.add(p);
      }
    }

    final newOrder = ordered
        .map((p) => p['id'] as String? ?? '')
        .where((id) => id.isNotEmpty)
        .toList();
    if (newOrder.join('|') != _personaOrder.join('|')) {
      _personaOrder = newOrder;
      unawaited(_savePersonaOrder());
    }

    return ordered;
  }

  @override
  void initState() {
    super.initState();
    unawaited(_loadPersonaOrder());
    // 监听人格操作响应，刷新列表
    _personaSub = widget.ws.personaResponses.listen((data) {
      final type = data['type'] as String? ?? '';
      final payload = data['payload'] as Map<String, dynamic>? ?? {};
      final status = payload['status'] as String? ?? '';

      if (!mounted) return;
      if (type == 'PERSONA_DELETE_RESPONSE' && status == 'success') {
        widget.ws.requestPersonaList();
      } else if (type == 'PERSONA_CLEAR_HISTORY_RESPONSE' &&
          status == 'success') {
        widget.ws.clearLocalMessages();
        ScaffoldMessenger.of(
          context,
        ).showSnackBar(const SnackBar(content: Text('聊天记录已清空')));
      } else if (type == 'PERSONA_DELETE_RESPONSE' && status == 'error') {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text('删除失败: ${payload['message'] ?? ''}'),
            backgroundColor: Colors.red,
          ),
        );
      }
    });
  }

  @override
  void dispose() {
    _personaSub?.cancel();
    super.dispose();
  }

  Future<void> _confirmClearHistory(String personaId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('清空聊天记录'),
        content: Text('确认清空与「$personaId」的所有聊天记录？此操作不可恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            child: const Text('清空', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
    if (ok == true) {
      widget.ws.clearPersonaHistory();
    }
  }

  Future<void> _confirmDelete(String personaId) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除人格'),
        content: Text('确认从 AstrBot 中删除人格「$personaId」？'),
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
      widget.ws.deletePersona(personaId);
    }
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final ws = widget.ws;
    final personas = _orderedPersonas(ws.personas);

    return Container(
      width: 260,
      color: colors.sidebar,
      child: Column(
        children: [
          // 顶部标题栏
          Container(
            height: 56,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            alignment: Alignment.centerLeft,
            child: Text(
              'Lumi Hub',
              style: TextStyle(
                fontSize: 17,
                fontWeight: FontWeight.bold,
                color: Theme.of(context).colorScheme.onSurface,
              ),
            ),
          ),
          Divider(height: 1, color: colors.divider),

          // ── 人格列表 ──
          Expanded(
            child: personas.isEmpty
                ? Center(
                    child: Text(
                      ws.status == WsStatus.connected ? '加载人格中...' : '未连接',
                      style: TextStyle(color: colors.subtext, fontSize: 12),
                    ),
                  )
                : ReorderableListView.builder(
                    buildDefaultDragHandles: false,
                    onReorder: (oldIndex, newIndex) {
                      if (newIndex > oldIndex) newIndex -= 1;
                      if (oldIndex < 0 || oldIndex >= personas.length) return;
                      if (newIndex < 0 || newIndex >= personas.length) return;

                      final reordered = [...personas];
                      final item = reordered.removeAt(oldIndex);
                      reordered.insert(newIndex, item);

                      setState(() {
                        _personaOrder = reordered
                            .map((p) => p['id'] as String? ?? '')
                            .where((id) => id.isNotEmpty)
                            .toList();
                      });
                      unawaited(_savePersonaOrder());
                    },
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: personas.length,
                    itemBuilder: (context, i) {
                      final p = personas[i];
                      final id = p['id'] as String? ?? '';
                      final isActive = id == ws.activePersonaId;
                      return _PersonaTile(
                        key: ValueKey('persona_$id'),
                        personaId: id,
                        isSelected: isActive,
                        colors: colors,
                        wsStatus: ws.status,
                        dragHandle: ReorderableDragStartListener(
                          index: i,
                          child: Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: Icon(
                              Icons.drag_indicator_rounded,
                              size: 18,
                              color: colors.subtext,
                            ),
                          ),
                        ),
                        onTap: () {
                          ws.switchPersona(id);
                          widget.onPersonaSelected?.call();
                        },
                        onClearHistory: () => _confirmClearHistory(id),
                        onDelete: () => _confirmDelete(id),
                      );
                    },
                  ),
          ),

          Divider(height: 1, color: colors.divider),

          // MCP 扩展入口
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              hoverColor: colors.accent.withValues(alpha: 0.1),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(
                Icons.extension_outlined,
                color: colors.subtext,
                size: 20,
              ),
              title: Text(
                '扩展生态 (MCP)',
                style: TextStyle(color: colors.subtext, fontSize: 13),
              ),
              onTap: () {
                Navigator.push(
                  context,
                  MaterialPageRoute(
                    builder: (context) => const McpSettingsScreen(),
                  ),
                );
              },
            ),
          ),

          // 设置入口
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8.0, vertical: 2.0),
            child: ListTile(
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(8),
              ),
              hoverColor: colors.accent.withValues(alpha: 0.1),
              contentPadding: const EdgeInsets.symmetric(horizontal: 16),
              leading: Icon(
                Icons.settings_outlined,
                color: colors.subtext,
                size: 20,
              ),
              title: Text(
                '设置',
                style: TextStyle(color: colors.subtext, fontSize: 13),
              ),
              onTap: () {
                showDialog(
                  context: context,
                  builder: (_) => _SettingsDialog(ws: ws, colors: colors),
                );
              },
            ),
          ),
          const SizedBox(height: 4),
        ],
      ),
    );
  }
}

// ─── 人格瓦片 ────────────────────────────────────────────────────────────────

class _PersonaTile extends StatefulWidget {
  final String personaId;
  final bool isSelected;
  final LumiColors colors;
  final WsStatus wsStatus;
  final Widget? dragHandle;
  final VoidCallback onTap;
  final VoidCallback onClearHistory;
  final VoidCallback onDelete;

  const _PersonaTile({
    super.key,
    required this.personaId,
    required this.isSelected,
    required this.colors,
    required this.wsStatus,
    this.dragHandle,
    required this.onTap,
    required this.onClearHistory,
    required this.onDelete,
  });

  @override
  State<_PersonaTile> createState() => _PersonaTileState();
}

class _PersonaTileState extends State<_PersonaTile> {
  bool _isHovered = false;

  String get _avatarChar {
    final id = widget.personaId;
    return id.isNotEmpty ? id[0].toUpperCase() : '?';
  }

  void _showMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(box.size.width, 0));

    await showMenu(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      color: widget.colors.inputBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      items: [
        PopupMenuItem(
          onTap: widget.onClearHistory,
          child: Row(
            children: [
              Icon(
                Icons.delete_sweep_rounded,
                size: 18,
                color: widget.colors.subtext,
              ),
              const SizedBox(width: 10),
              const Text('清空聊天记录'),
            ],
          ),
        ),
        PopupMenuItem(
          onTap: widget.onDelete,
          child: const Row(
            children: [
              Icon(
                Icons.person_remove_rounded,
                size: 18,
                color: Colors.redAccent,
              ),
              SizedBox(width: 10),
              Text('删除人格', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final isSelected = widget.isSelected;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: isSelected
            ? colors.accent.withValues(alpha: 0.15)
            : _isHovered
            ? colors.accent.withValues(alpha: 0.06)
            : Colors.transparent,
        child: ListTile(
          contentPadding: const EdgeInsets.only(
            left: 12,
            right: 4,
            top: 2,
            bottom: 2,
          ),
          onTap: widget.onTap,
          leading: Stack(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: isSelected
                    ? colors.accent
                    : colors.accent.withValues(alpha: 0.5),
                child: Text(
                  _avatarChar,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              // 连接状态指示灯（仅激活人格显示）
              if (isSelected)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _statusColor(widget.wsStatus),
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.sidebar, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          title: Text(
            widget.personaId,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 14,
            ),
          ),
          subtitle: Text(
            isSelected ? '当前激活' : '点击切换',
            style: TextStyle(fontSize: 11, color: colors.subtext),
          ),
          trailing: AnimatedOpacity(
            opacity: _isHovered || isSelected ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.dragHandle != null) widget.dragHandle!,
                Builder(
                  builder: (ctx) => IconButton(
                    icon: Icon(
                      Icons.more_vert_rounded,
                      size: 18,
                      color: colors.subtext,
                    ),
                    tooltip: '更多操作',
                    onPressed: () => _showMenu(ctx),
                    splashRadius: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _statusColor(WsStatus s) => switch (s) {
    WsStatus.connected => const Color(0xFF4CAF50),
    WsStatus.connecting => const Color(0xFFFFC107),
    WsStatus.disconnected => const Color(0xFF9E9E9E),
  };
}

class _SettingsDialog extends StatelessWidget {
  final WsService ws;
  final LumiColors colors;

  const _SettingsDialog({required this.ws, required this.colors});

  bool get _supportsLocalHostLifecycle => !kIsWeb && Platform.isWindows;

  bool _isLocalHostUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  Future<void> _applyConnectionMode(
    BuildContext context,
    ConnectionMode mode,
  ) async {
    final settings = context.read<AppSettings>();
    final currentUrl = ws.serverUrl;
    String nextUrl = currentUrl;

    final shouldUseRemote =
        mode != ConnectionMode.localOrUsb || !_supportsLocalHostLifecycle;

    switch (mode) {
      case ConnectionMode.localOrUsb:
        nextUrl = 'ws://127.0.0.1:8765';
        break;
      case ConnectionMode.lan:
        if (_isLocalHostUrl(currentUrl)) {
          nextUrl = 'ws://192.168.1.10:8765';
        }
        break;
      case ConnectionMode.publicTunnel:
        if (_isLocalHostUrl(currentUrl)) {
          nextUrl = 'wss://your-domain.example.com/ws';
        }
        break;
    }

    settings.setConnectionMode(mode);
    settings.setRemoteClientMode(shouldUseRemote);
    await ws.setServerUrl(nextUrl, reconnectIfConnected: false);
  }

  Future<void> _showConnectionModeSelector(BuildContext context) async {
    final settings = context.read<AppSettings>();
    var selected = settings.connectionMode;

    final localLabel = _supportsLocalHostLifecycle
        ? '本机/USB 调试 (127.0.0.1)'
        : 'USB 调试转发 (127.0.0.1)';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('连接方式'),
              content: SizedBox(
                width: (MediaQuery.of(dialogContext).size.width * 0.9).clamp(
                  280.0,
                  420.0,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<ConnectionMode>(
                      value: ConnectionMode.localOrUsb,
                      groupValue: selected,
                      contentPadding: EdgeInsets.zero,
                      title: Text(localLabel),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => selected = value);
                      },
                    ),
                    RadioListTile<ConnectionMode>(
                      value: ConnectionMode.lan,
                      groupValue: selected,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('局域网'),
                      subtitle: const Text('ws://192.168.x.x:8765'),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => selected = value);
                      },
                    ),
                    RadioListTile<ConnectionMode>(
                      value: ConnectionMode.publicTunnel,
                      groupValue: selected,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('公网/内网穿透'),
                      subtitle: const Text('wss://your-domain.example.com/ws'),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => selected = value);
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    await _applyConnectionMode(dialogContext, selected);
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: const Text('应用'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showServerUrlEditor(BuildContext context) async {
    final controller = TextEditingController(text: ws.serverUrl);
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Host 地址'),
              content: SizedBox(
                width: (MediaQuery.of(dialogContext).size.width * 0.9).clamp(
                  280.0,
                  420.0,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: 'WebSocket 地址',
                        hintText: 'ws://127.0.0.1:8765 或 192.168.1.10:8765',
                        errorText: errorText,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '留空将恢复默认地址 ws://127.0.0.1:8765',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    try {
                      await ws.setServerUrl(controller.text);
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    } on FormatException catch (e) {
                      setState(() {
                        errorText = e.message;
                      });
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showAccessKeyEditor(BuildContext context) async {
    final controller = TextEditingController(text: ws.accessKey);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('接入密钥'),
          content: SizedBox(
            width: (MediaQuery.of(dialogContext).size.width * 0.9).clamp(
              280.0,
              420.0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Access Key',
                    hintText: '为空表示不发送密钥',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '该密钥仅保存在本机，用于 CONNECT 握手校验。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                await ws.setAccessKey(controller.text);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final bootstrap = context.read<BootstrapService>();
    final user = ws.user;
    final screen = MediaQuery.of(context).size;
    final dialogWidth = (screen.width * 0.94).clamp(320.0, 560.0);
    final dialogMaxHeight = screen.height * 0.78;

    return AlertDialog(
      backgroundColor: colors.sidebar,
      title: Text(
        '偏好设置',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: dialogWidth,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: dialogMaxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 账号信息卡片
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.inputBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: colors.accent,
                        child: const Icon(Icons.person, color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?['username'] ?? '未知用户',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'ID: ${user?['id'] ?? '-'}',
                              style: TextStyle(
                                color: colors.subtext,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // 应用与系统设置
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    '应用与系统',
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: colors.inputBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: colors.divider.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Column(
                    children: [
                      // 1. 字体
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.font_download_outlined,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '应用字体',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        trailing: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: settings.fontKey,
                            dropdownColor: colors.inputBg,
                            icon: Icon(
                              Icons.expand_more,
                              size: 16,
                              color: colors.subtext,
                            ),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 13,
                            ),
                            items: kAvailableFonts.entries
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null) settings.setFontFamily(val);
                            },
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 2. 退出行为
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.close_fullscreen,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '关闭窗口动作',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          '点击系统关闭按钮时...',
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: DropdownButtonHideUnderline(
                          child: DropdownButton<WindowCloseAction>(
                            value: settings.windowCloseAction,
                            dropdownColor: colors.inputBg,
                            icon: Icon(
                              Icons.expand_more,
                              size: 16,
                              color: colors.subtext,
                            ),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 13,
                            ),
                            items: kWindowCloseActionLabels.entries
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null)
                                settings.setWindowCloseAction(val);
                            },
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 3. 随前端关闭 AstrBot
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.power_settings_new,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '同步关闭 AstrBot',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          '完全退出时结束核心进程',
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Transform.scale(
                          scale: 0.8,
                          child: Switch(
                            value: settings.closeAstrBotOnExit,
                            onChanged: settings.setCloseAstrBotOnExit,
                            activeThumbColor: colors.accent,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 4. 连接方式
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.router_outlined,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '连接方式',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          kConnectionModeLabels[settings.connectionMode] ??
                              '未设置',
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.edit,
                          color: colors.subtext,
                          size: 16,
                        ),
                        onTap: () => _showConnectionModeSelector(context),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 5. 每次启动询问连接方式
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.help_outline,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '每次启动询问连接方式',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          settings.askConnectionModeOnLaunch
                              ? '已开启：每次都会弹出选择'
                              : '已关闭：自动使用已保存模式',
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Transform.scale(
                          scale: 0.8,
                          child: Switch(
                            value: settings.askConnectionModeOnLaunch,
                            onChanged: settings.setAskConnectionModeOnLaunch,
                            activeThumbColor: colors.accent,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 6. 打开日志目录
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.folder_open,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '打开日志目录',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          bootstrap.logDirectoryPath ?? '日志目录尚未初始化',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.open_in_new,
                          color: colors.subtext,
                          size: 16,
                        ),
                        onTap: bootstrap.openLogDirectory,
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 7. Host 地址
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.dns_outlined,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          'Host 地址',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          ws.serverUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.edit,
                          color: colors.subtext,
                          size: 16,
                        ),
                        onTap: () => _showServerUrlEditor(context),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 8. 接入密钥
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.vpn_key_outlined,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '接入密钥',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          ws.accessKey.isEmpty ? '未设置' : '已设置（已隐藏）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.edit,
                          color: colors.subtext,
                          size: 16,
                        ),
                        onTap: () => _showAccessKeyEditor(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // 注销按钮
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('注销登录'),
                    onPressed: () async {
                      await ws.logout();
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('关闭', style: TextStyle(color: colors.subtext)),
        ),
      ],
    );
  }
}

// ─── 顶部栏 ─────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final LumiColors colors;
  final WsService ws;
  final String activePersonaId;
  final bool isSelectionMode;
  final int selectedCount;
  final VoidCallback onCancelSelection;
  final VoidCallback onDeleteSelected;
  final VoidCallback? onOpenSidebar;

  const _TopBar({
    required this.colors,
    required this.ws,
    required this.activePersonaId,
    this.isSelectionMode = false,
    this.selectedCount = 0,
    required this.onCancelSelection,
    required this.onDeleteSelected,
    this.onOpenSidebar,
  });

  @override
  Widget build(BuildContext context) {
    if (isSelectionMode) {
      return SafeArea(
        bottom: false,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          color: colors.sidebar,
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.close, color: colors.subtext),
                onPressed: onCancelSelection,
                tooltip: '取消多选',
              ),
              const SizedBox(width: 8),
              Text(
                '已选择 $selectedCount 项',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              if (selectedCount > 0)
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('删除消息'),
                        content: Text('确定要删除选中的 $selectedCount 条消息吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              onDeleteSelected();
                            },
                            child: const Text(
                              '删除',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  tooltip: '删除选中项',
                ),
            ],
          ),
        ),
      );
    }

    final statusText = switch (ws.status) {
      WsStatus.connected => '在线',
      WsStatus.connecting => '连接中...',
      WsStatus.disconnected => '未连接',
    };
    final statusColor = switch (ws.status) {
      WsStatus.connected => const Color(0xFF4CAF50),
      WsStatus.connecting => const Color(0xFFFFC107),
      WsStatus.disconnected => const Color(0xFF9E9E9E),
    };

    return SafeArea(
      bottom: false,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            if (onOpenSidebar != null) ...[
              IconButton(
                icon: Icon(Icons.menu_rounded, color: colors.subtext),
                onPressed: onOpenSidebar,
                tooltip: '打开侧边栏',
              ),
              const SizedBox(width: 4),
            ],
            CircleAvatar(
              radius: 18,
              backgroundColor: colors.accent,
              child: Text(
                activePersonaId.isNotEmpty
                    ? activePersonaId[0].toUpperCase()
                    : '?',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activePersonaId.isNotEmpty ? activePersonaId : '未选择人格',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Text(
                      statusText,
                      style: TextStyle(fontSize: 12, color: colors.subtext),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 消息列表 ────────────────────────────────────────────────────────────────

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
              final isMobile = !kIsWeb && (Platform.isAndroid || Platform.isIOS);
              final targetMessageId = _activeTextActionMessageId;

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

class _BubbleItem extends StatefulWidget {
  final ChatMessage msg;
  final LumiColors colors;
  final bool isSelected;
  final bool isSelectionMode;
  final bool Function() hasGlobalSelection;
  final VoidCallback onToggleSelection;
  final VoidCallback onEnterSelectionMode;
  final VoidCallback onDeleteMessage;
  final VoidCallback onActivateForTextActions;
  final ValueChanged<Rect> onRowRectChanged;
  final ValueChanged<Rect> onBubbleRectChanged;

  const _BubbleItem({
    super.key,
    required this.msg,
    required this.colors,
    this.isSelected = false,
    this.isSelectionMode = false,
    required this.hasGlobalSelection,
    required this.onToggleSelection,
    required this.onEnterSelectionMode,
    required this.onDeleteMessage,
    required this.onActivateForTextActions,
    required this.onRowRectChanged,
    required this.onBubbleRectChanged,
  });

  @override
  State<_BubbleItem> createState() => _BubbleItemState();
}

class _BubbleItemState extends State<_BubbleItem> {
  bool _isHovered = false;
  final GlobalKey _rowKey = GlobalKey();
  final GlobalKey _bubbleContentKey = GlobalKey();

  void _reportRects() {
    final rowCtx = _rowKey.currentContext;
    final rowBox = rowCtx?.findRenderObject() as RenderBox?;
    if (rowBox != null && rowBox.hasSize) {
      final rowRect = rowBox.localToGlobal(Offset.zero) & rowBox.size;
      widget.onRowRectChanged(rowRect);
    }

    final bubbleCtx = _bubbleContentKey.currentContext;
    final bubbleBox = bubbleCtx?.findRenderObject() as RenderBox?;
    if (bubbleBox != null && bubbleBox.hasSize) {
      final bubbleRect =
          bubbleBox.localToGlobal(Offset.zero) & bubbleBox.size;
      widget.onBubbleRectChanged(bubbleRect);
    }
  }

  bool get _isAttachmentBubble => widget.msg.content.startsWith('[附件] ');
  bool get _isImageBubble => widget.msg.content.startsWith('[图片] ');

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

  Widget _buildBubbleContent(Color textColor) {
    if (widget.msg.isTyping) {
      return _TypingIndicator(color: textColor);
    }

    if (_isImageBubble) {
      final path = _getAttachmentPath();
      final fileName = _getAttachmentName();
      if (path != null) {
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
      crossAxisAlignment: CrossAxisAlignment.end,
      children: [
        MarkdownBody(
          data: widget.msg.content,
          // 文本选择统一交给列表层 SelectionArea，避免嵌套选择器造成跨空格/跨气泡拖选异常。
          selectable: false,
          styleSheet: MarkdownStyleSheet(
            p: TextStyle(color: textColor, fontSize: 14, height: 1.4),
            listBullet: TextStyle(color: textColor, fontSize: 14),
            code: TextStyle(
              backgroundColor: Colors.black26,
              color: textColor,
              fontFamily: 'monospace',
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
        ),
      ],
    );
  }

  void _confirmDelete(BuildContext context) {
    showDialog(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('删除消息'),
        content: const Text('确定要在本地删除这条消息吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () {
              Navigator.pop(context);
              widget.onDeleteMessage();
            },
            child: const Text('删除', style: TextStyle(color: Colors.red)),
          ),
        ],
      ),
    );
  }

  void _showDesktopMenu(BuildContext context, Offset position) async {
    if (widget.msg.isTyping) return;

    final value = await showGeneralDialog<String>(
      context: context,
      barrierDismissible: true,
      barrierLabel: 'message_context_menu',
      barrierColor: Colors.transparent,
      transitionDuration: Duration.zero,
      pageBuilder: (dialogContext, animation, secondaryAnimation) {
        final size = MediaQuery.of(dialogContext).size;
        const menuWidth = 156.0;
        const menuHeight = 134.0;
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
                            icon: Icons.copy,
                            text: '复制',
                            radius: const BorderRadius.only(
                              topLeft: Radius.circular(14),
                              topRight: Radius.circular(14),
                            ),
                          ),
                          menuItem(
                            value: 'select',
                            icon: Icons.checklist,
                            text: '多选',
                          ),
                          Divider(
                            height: 1,
                            thickness: 1,
                            color: Colors.white.withValues(alpha: 0.24),
                          ),
                          menuItem(
                            value: 'delete',
                            icon: Icons.delete_outline,
                            text: '删除',
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

    if (value == 'copy') {
      await Clipboard.setData(ClipboardData(text: widget.msg.content));
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('已复制到剪贴板'),
          duration: Duration(seconds: 1),
        ),
      );
    } else if (value == 'select') {
      widget.onEnterSelectionMode();
      widget.onToggleSelection();
    } else if (value == 'delete') {
      _confirmDelete(context);
    }
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
        ? DateFormat('MM-dd HH:mm:ss').format(widget.msg.time)
        : DateFormat('yyyy-MM-dd HH:mm:ss').format(widget.msg.time);

    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      _reportRects();
    });

    Widget bubbleWidget = Padding(
      key: _rowKey,
      padding: const EdgeInsets.only(bottom: 6),
      child: MouseRegion(
        onEnter: (_) => setState(() => _isHovered = true),
        onExit: (_) => setState(() => _isHovered = false),
        child: Column(
          crossAxisAlignment: isMe
              ? CrossAxisAlignment.end
              : CrossAxisAlignment.start,
          children: [
            AnimatedOpacity(
              opacity: _isHovered ? 1.0 : 0.0,
              duration: const Duration(milliseconds: 200),
              child: Padding(
                padding: EdgeInsets.only(
                  left: isMe ? 0 : 54.0,
                  right: isMe ? 12.0 : 0,
                  bottom: 4,
                ),
                child: Text(
                  timeStr,
                  style: TextStyle(
                    color: widget.colors.subtext.withValues(alpha: 0.8),
                    fontSize: 12,
                  ),
                ),
              ),
            ),
            Listener(
              onPointerDown: (event) {
                widget.onActivateForTextActions();
                if (event.kind == PointerDeviceKind.mouse &&
                    event.buttons == kSecondaryMouseButton &&
                    !widget.isSelectionMode &&
                    !widget.hasGlobalSelection()) {
                  _showDesktopMenu(context, event.position);
                }
              },
              child: GestureDetector(
                onTap: widget.isSelectionMode ? widget.onToggleSelection : null,
                child: Container(
                  color: widget.isSelected
                      ? widget.colors.accent.withValues(alpha: 0.15)
                      : Colors.transparent,
                  child: Row(
                    mainAxisAlignment: isMe
                        ? MainAxisAlignment.end
                        : MainAxisAlignment.start,
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: [
                      if (widget.isSelectionMode && !isMe)
                        Padding(
                          padding: const EdgeInsets.only(right: 8, bottom: 8),
                          child: AbsorbPointer(
                            child: Checkbox(
                              value: widget.isSelected,
                              onChanged: (_) {},
                              activeColor: widget.colors.accent,
                            ),
                          ),
                        ),
                      if (!isMe) ...[
                        CircleAvatar(
                          radius: 16,
                          backgroundColor: widget.colors.accent,
                          child: const Text(
                            '流',
                            style: TextStyle(color: Colors.white, fontSize: 12),
                          ),
                        ),
                        const SizedBox(width: 8),
                      ],
                      Flexible(
                        child: Container(
                          key: _bubbleContentKey,
                          constraints: BoxConstraints(
                            maxWidth: MediaQuery.of(context).size.width <= 640
                                ? MediaQuery.of(context).size.width * 0.78
                                : MediaQuery.of(context).size.width * 0.55,
                          ),
                          padding: const EdgeInsets.symmetric(
                            horizontal: 12,
                            vertical: 8,
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
                      if (isMe) const SizedBox(width: 8),
                      if (widget.isSelectionMode && isMe)
                        Padding(
                          padding: const EdgeInsets.only(left: 8, bottom: 8),
                          child: AbsorbPointer(
                            child: Checkbox(
                              value: widget.isSelected,
                              onChanged: (_) {},
                              activeColor: widget.colors.accent,
                            ),
                          ),
                        ),
                    ],
                  ),
                ),
              ),
            ),
          ],
        ),
      ),
    );
    return bubbleWidget;
  }
}

class _SelectionMarqueePainter extends CustomPainter {
  final Rect rect;

  _SelectionMarqueePainter(this.rect);

  @override
  void paint(Canvas canvas, Size size) {
    final normalized = Rect.fromLTRB(
      rect.left < rect.right ? rect.left : rect.right,
      rect.top < rect.bottom ? rect.top : rect.bottom,
      rect.left > rect.right ? rect.left : rect.right,
      rect.top > rect.bottom ? rect.top : rect.bottom,
    );

    final fillPaint = Paint()
      ..color = const Color(0x334A90E2)
      ..style = PaintingStyle.fill;
    final borderPaint = Paint()
      ..color = const Color(0xFF4A90E2)
      ..style = PaintingStyle.stroke
      ..strokeWidth = 1.2;

    canvas.drawRect(normalized, fillPaint);
    canvas.drawRect(normalized, borderPaint);
  }

  @override
  bool shouldRepaint(covariant _SelectionMarqueePainter oldDelegate) {
    return oldDelegate.rect != rect;
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
