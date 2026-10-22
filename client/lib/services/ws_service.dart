import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:audioplayers/audioplayers.dart' as ap;
import 'package:flutter/foundation.dart';
import 'package:just_audio/just_audio.dart';
import 'package:web_socket_channel/web_socket_channel.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../models/message.dart';

part 'ws_service_tts.dart';
part 'ws_service_upload.dart';

enum WsStatus { disconnected, connecting, connected }

/// 单轮 TTS 的分片缓存。
///
/// Host 可能按 seq 分块回传音频，这里先按序号暂存，
/// 在 TTS_STREAM_END 时统一合并落盘。
class _TtsTurnBuffer {
  _TtsTurnBuffer({required this.format});

  final String format;
  final Map<int, List<int>> chunks = <int, List<int>>{};

  List<int> mergeBytes() {
    final merged = <int>[];
    final orderedKeys = chunks.keys.toList()..sort();
    for (final seq in orderedKeys) {
      merged.addAll(chunks[seq] ?? const <int>[]);
    }
    return merged;
  }
}

class WsService extends ChangeNotifier {
  /// WebSocket + 协议状态入口。
  ///
  /// 职责：
  /// 1. 管理连接/重连/心跳
  /// 2. 处理鉴权、聊天、历史、人格、MCP、上传、语音协议消息
  /// 3. 维护前端页面直接消费的状态（messages、isGenerating、personas 等）
  static const String _defaultUrl = 'ws://127.0.0.1:8765';
  static const String _serverUrlStorage = 'ws.server_url';
  static const String _accessKeyStorage = 'ws.access_key';
  static const Duration _pingInterval = Duration(seconds: 20);
  static const Duration _reconnectDelay = Duration(seconds: 3);

  WsStatus _status = WsStatus.disconnected;
  WsStatus get status => _status;

  final List<ChatMessage> _messages = [];
  List<ChatMessage> get messages => List.unmodifiable(_messages);

  WebSocketChannel? _channel;
  StreamSubscription? _sub;
  Timer? _pingTimer;
  Timer? _reconnectTimer;
  bool _disposed = false;
  final Completer<void> _authInitCompleter = Completer<void>();

  bool _isAuthenticated = false;
  bool get isAuthenticated => _isAuthenticated;
  bool isRestoringAuth = false;
  String? _token;
  String _serverUrl = _defaultUrl;
  String _accessKey = '';
  Map<String, dynamic>? _user;
  Map<String, dynamic>? get user => _user;

  bool _isGenerating = false;
  bool get isGenerating => _isGenerating;
  Timer? _generationUnlockTimer;
  final Set<String> _streamingMsgIds = <String>{};
  final Map<String, List<Map<String, dynamic>>> _traceCache = {};
  final Map<String, Completer<Map<String, dynamic>>> _pendingResponses = {};
  final Map<String, int> _historyRequestOffsets = <String, int>{};
  final Map<String, Completer<void>> _historyRequestCompleters =
      <String, Completer<void>>{};
  static const int _historyPageSize = 30;
  int _historyOffset = 0;
  bool _historyHasMore = true;
  bool _historyLoading = false;
  bool get hasMoreHistory => _historyHasMore;
  bool get isHistoryLoading => _historyLoading;
  static const int _uploadChunkSize = 256 * 1024;

  // 审批请求流
  final _authRequestController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get authRequests =>
      _authRequestController.stream;

  // MCP 配置流
  final _mcpConfigController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get mcpConfigResponses =>
      _mcpConfigController.stream;

  // 语音消息流
  final _voiceEventController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get voiceEvents => _voiceEventController.stream;

  final Map<String, _TtsTurnBuffer> _ttsBuffers = <String, _TtsTurnBuffer>{};
  final Map<String, String> _ttsAudioFiles = <String, String>{};
  final Set<String> _ttsGeneratingTurns = <String>{};
  AudioPlayer? _ttsPlayer;
  StreamSubscription<PlayerState>? _ttsPlayerStateSub;
  ap.AudioPlayer? _ttsWindowsPlayer;
  StreamSubscription<ap.PlayerState>? _ttsWindowsPlayerStateSub;
  bool _isTtsPlaying = false;
  String? _playingTtsTurnId;
  bool _ttsOperationLocked = false;

  bool get isTtsPlaying => _isTtsPlaying;
  String? get playingTtsTurnId => _playingTtsTurnId;

  // 供 part 文件使用，避免在 extension 里直接调用受保护成员 notifyListeners。
  void _notifyStateChanged() {
    notifyListeners();
  }

  // 人格列表 & 当前激活人格
  List<Map<String, dynamic>> _personas = [];
  List<Map<String, dynamic>> get personas => List.unmodifiable(_personas);
  String _activePersonaId = '';
  String get activePersonaId => _activePersonaId;

  // ── 工作区与会话状态 ──
  List<Map<String, dynamic>> _sessions = [];
  List<Map<String, dynamic>> get sessions => List.unmodifiable(_sessions);
  String? _activeSessionId;
  String? get activeSessionId => _activeSessionId;
  String _activeWorkspacePath = '';
  String get activeWorkspacePath => _activeWorkspacePath;
  List<String> _recentWorkspaces = [];
  List<String> get recentWorkspaces => List.unmodifiable(_recentWorkspaces);

  // 约定 AI 回复 id 与请求 message_id 的映射规则。
  String _assistantMsgId(String msgId) => '${msgId}_ai';

  // 合并流式回复时，尽量做重叠去重，避免重复片段导致“叠字”。
  String _mergeAssistantContent(String existing, String incoming) {
    if (incoming.isEmpty) return existing;
    if (existing.isEmpty) return incoming;
    if (existing.endsWith(incoming)) return existing;

    final maxOverlap = min(existing.length, incoming.length);
    for (var overlap = maxOverlap; overlap > 0; overlap--) {
      if (existing.endsWith(incoming.substring(0, overlap))) {
        return existing + incoming.substring(overlap);
      }
    }
    return existing + incoming;
  }

  // 人格操作响应流
  final _personaController = StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get personaResponses =>
      _personaController.stream;

  String get serverUrl => _serverUrl;
  String get accessKey => _accessKey;

  WsService() {
    _initTtsPlayer();
    _initAuth();
  }

  Future<void> _initAuth() async {
    final prefs = await SharedPreferences.getInstance();
    _token = prefs.getString('auth_token');
    _serverUrl = prefs.getString(_serverUrlStorage) ?? _defaultUrl;
    _accessKey = prefs.getString(_accessKeyStorage) ?? '';
    isRestoringAuth = true;
    // 兜底：若连接已建立且尚未鉴权，触发自动恢复/默认登录。
    if (_status == WsStatus.connected && !_isAuthenticated) {
      restoreAuth();
    }
    if (!_authInitCompleter.isCompleted) {
      _authInitCompleter.complete();
    }
    // 注意：这里不再乐观地直接设置 _isAuthenticated = true
    // 而是等待 connect() 之后通过 AUTH_RESTORE 从服务端拿回结果，才进入 ChatScreen
    notifyListeners();
  }

  Future<void> setAccessKey(
    String rawKey, {
    bool reconnectIfConnected = true,
  }) async {
    final normalized = rawKey.trim();
    if (normalized == _accessKey) return;

    _accessKey = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_accessKeyStorage, _accessKey);
    notifyListeners();

    if (reconnectIfConnected &&
        (_status == WsStatus.connected || _status == WsStatus.connecting)) {
      disconnect();
      unawaited(connect());
    }
  }

  // ── 连接 ──────────────────────────────────────────────────────────────

  Future<void> connect() async {
    if (_status == WsStatus.connected || _status == WsStatus.connecting) return;

    // 等待本地 token/serverUrl/accessKey 读取完成，避免热重启后自动登录竞态。
    await _authInitCompleter.future;

    _setStatus(WsStatus.connecting);

    try {
      _channel = WebSocketChannel.connect(Uri.parse(_serverUrl));
      await _channel!.ready;
      _sub = _channel!.stream.listen(
        _onData,
        onError: _onError,
        onDone: _onDone,
      );
      _setStatus(WsStatus.connected);
      _sendHandshake();
      restoreAuth();
      _startPing();
    } catch (e) {
      debugPrint('[WS] 连接失败: $e');
      _setStatus(WsStatus.disconnected);
      _scheduleReconnect();
    }
  }

  Future<void> setServerUrl(
    String rawUrl, {
    bool reconnectIfConnected = true,
  }) async {
    final normalized = _normalizeServerUrl(rawUrl);
    if (normalized == _serverUrl) return;

    _serverUrl = normalized;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_serverUrlStorage, _serverUrl);
    notifyListeners();

    if (reconnectIfConnected &&
        (_status == WsStatus.connected || _status == WsStatus.connecting)) {
      disconnect();
      unawaited(connect());
    }
  }

  String _normalizeServerUrl(String rawUrl) {
    final raw = rawUrl.trim();
    if (raw.isEmpty) {
      return _defaultUrl;
    }

    final withScheme = raw.contains('://') ? raw : 'ws://$raw';
    final uri = Uri.tryParse(withScheme);
    if (uri == null || uri.host.isEmpty) {
      throw const FormatException('无效地址');
    }
    if (uri.scheme != 'ws' && uri.scheme != 'wss') {
      throw const FormatException('仅支持 ws:// 或 wss://');
    }

    final effectivePort = uri.hasPort
        ? uri.port
        : (uri.scheme == 'wss' ? 443 : 80);

    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: effectivePort,
      path: uri.path,
      query: uri.query.isEmpty ? null : uri.query,
    ).toString();
  }

  void disconnect() {
    _reconnectTimer?.cancel();
    _pingTimer?.cancel();
    _sub?.cancel();
    _channel?.sink.close();
    _channel = null;
    _setStatus(WsStatus.disconnected);
  }

  // ── 发送消息 ───────────────────────────────────────────────────────────

  void sendMessage(
    String text, {
    List<Map<String, dynamic>> attachments = const [],
    String? skillName,
    Map<String, dynamic>? skillParams,
  }) {
    final normalized = text.trim();
    if (_status != WsStatus.connected) return;
    if (normalized.isEmpty && attachments.isEmpty && skillName == null) return;

    final contentForHost = normalized.isNotEmpty
        ? normalized
        : (skillName != null ? '执行技能：$skillName' : '我上传了附件，请先确认接收并根据附件内容回答。');

    final requestId = _genId();
    final now = DateTime.now();

    // 先加入本地：附件和文本分成两个气泡
    if (attachments.isNotEmpty) {
      final att = attachments.first;
      final fileName = (att['file_name'] ?? '未命名文件').toString();
      final mimeType = (att['mime_type'] ?? '').toString().toLowerCase();
      final localPath = (att['local_path'] ?? '').toString();
      final lowerName = fileName.toLowerCase();
      final isImage =
          mimeType.startsWith('image/') ||
          lowerName.endsWith('.png') ||
          lowerName.endsWith('.jpg') ||
          lowerName.endsWith('.jpeg') ||
          lowerName.endsWith('.webp') ||
          lowerName.endsWith('.gif');
      final prefix = isImage ? '[图片]' : '[附件]';
      _messages.add(
        ChatMessage(
          id: '${requestId}_att',
          content: '$prefix $localPath|||$fileName',
          sender: MessageSender.me,
          time: now,
          extra: att,
        ),
      );
    }

    if (normalized.isNotEmpty || skillName != null) {
      _messages.add(
        ChatMessage(
          id: requestId,
          content: normalized.isNotEmpty
              ? normalized
              : (skillName != null ? '⚡ 触发技能: $skillName' : ''),
          sender: MessageSender.me,
          time: now,
        ),
      );
    }

    // 加 AI 正在输入占位
    final placeholder = ChatMessage(
      id: '${requestId}_typing',
      content: '',
      sender: MessageSender.ai,
      time: now,
      isTyping: true,
      extra: {'traces': _traceCache.putIfAbsent(requestId, () => <Map<String, dynamic>>[])},
    );
    _messages.add(placeholder);
    _isGenerating = true;
    _generationUnlockTimer?.cancel();
    notifyListeners();

    // 发送到 Host
    final payload = <String, dynamic>{
      'content': contentForHost,
      'context_id': 'default',
      'persona_id': _activePersonaId,
      'session_id': _activeSessionId,
      'workspace_path': _activeWorkspacePath,
      'attachments': attachments,
    };
    if (skillName != null && skillName.isNotEmpty) {
      payload['skill_name'] = skillName;
      payload['skill_params'] = skillParams ?? {};
    }

    _send({
      'message_id': requestId,
      'type': 'CHAT_REQUEST',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': payload,
    });
  }

  // ── 内部 ───────────────────────────────────────────────────────────────

  void _onData(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = data['type'] as String? ?? '';

      // 优先处理 pending response（通过 message_id 匹配），不走 switch 分支。
      _handlePendingResponse(data);

      // 协议分发中心：所有 Host 回包都从这里进入，再路由到具体处理函数。
      switch (type) {
        case 'CHAT_RESPONSE':
          _handleChatResponse(data);
          break;
        case 'CHAT_STREAM_CHUNK':
          _handleChatStreamChunk(data);
          break;
        case 'CHAT_RESPONSE_END':
          _isGenerating = false;
          _generationUnlockTimer?.cancel();
          notifyListeners();
          break;
        case 'TRACE_STEP_UPDATE':
          _handleTraceStepUpdate(data);
          break;
        case 'TRACE_SUMMARY':
          _handleTraceSummary(data);
          break;
        case 'PONG':
          // 心跳回应，忽略
          break;
        case 'CONNECT':
          debugPrint('[WS] 握手确认: ${data['payload']}');
          break;
        case 'AUTH_RESPONSE':
          _handleAuthResponse(data);
          break;
        case 'AUTH_REQUIRED':
          _handleAuthRequired(data);
          break;
        case 'HISTORY_RESPONSE':
          _handleHistoryResponse(data);
          break;
        case 'MCP_CONFIG_RESPONSE':
        case 'MCP_CONFIG_UPDATE_RESPONSE':
          _mcpConfigController.add(data);
          break;
        case 'VOICE_CONFIG_RESPONSE':
        case 'VOICE_CONFIG_SET_RESPONSE':
        case 'VOICE_INTERRUPT_ACK':
          _voiceEventController.add(data);
          break;
        case 'TTS_STREAM_START':
          _handleTtsStreamStart(data);
          _voiceEventController.add(data);
          break;
        case 'TTS_STREAM_CHUNK':
          _handleTtsStreamChunk(data);
          break;
        case 'TTS_STREAM_END':
          unawaited(_handleTtsStreamEndAndNotify(data));
          break;
        case 'FILE_UPLOAD_ACK':
        case 'FILE_UPLOAD_ERROR':
          _handlePendingResponse(data);
          break;
        case 'PERSONA_LIST':
          _handlePersonaList(data);
          break;
        case 'PERSONA_SWITCH':
        case 'PERSONA_CLEAR_HISTORY_RESPONSE':
        case 'MESSAGE_DELETE_RESPONSE':
        case 'PERSONA_DELETE_RESPONSE':
          _personaController.add(data);
          break;
        case 'SESSION_LIST_RESPONSE':
          _handleSessionListResponse(data);
          break;
        case 'SESSION_CREATE_RESPONSE':
          _handleSessionCreateResponse(data);
          break;
        case 'SESSION_UPDATE_RESPONSE':
        case 'SESSION_DELETE_RESPONSE':
          break;
        case 'LLM_CONFIG_RESPONSE':
        case 'APP_STATUS_RESPONSE':
        case 'MEMORY_LIST_RESPONSE':
        case 'MEMORY_ADD_RESPONSE':
        case 'MEMORY_DELETE_RESPONSE':
        case 'MEMORY_CLEAR_RESPONSE':
        case 'SKILL_LIST_RESPONSE':
        case 'SKILL_INSTALL_RESPONSE':
        case 'SKILL_UNINSTALL_RESPONSE':
          // 已由 _handlePendingResponse 消费
          break;
        default:
          debugPrint('[WS] 未处理消息类型: $type');
      }
    } catch (e) {
      debugPrint('[WS] 解析消息失败: $e');
    }
  }

  void _handleChatResponse(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final content = payload['content'] as String? ?? '';
    if (content.isEmpty) return;

    final msgId = data['message_id'] as String? ?? _genId();
    final assistantId = _assistantMsgId(msgId);
    final isFromStreaming = _streamingMsgIds.contains(msgId);

    // 同 message_id 的多次 CHAT_RESPONSE 视为追加/覆盖。
    final existingIndex = _messages.indexWhere(
      (m) => m.id == assistantId && m.sender == MessageSender.ai,
    );
    if (existingIndex != -1) {
      final existing = _messages[existingIndex];

      // 支持分段回复：同 message_id 的多次 CHAT_RESPONSE 视为追加。
      // 若来自 CHAT_STREAM_CHUNK 流程，则最终 CHAT_RESPONSE 以完整文本覆盖。
      final nextContent = isFromStreaming
          ? content
          : _mergeAssistantContent(existing.content, content);

      final currentExtra = Map<String, dynamic>.from(existing.extra ?? {});
      if (_traceCache.containsKey(msgId)) {
        currentExtra['traces'] = List<Map<String, dynamic>>.from(_traceCache[msgId]!);
      }

      _messages[existingIndex] = existing.copyWith(
        content: nextContent,
        isTyping: false,
        extra: currentExtra,
      );
      if (isFromStreaming) {
        _streamingMsgIds.remove(msgId);
      }
      notifyListeners();
      return;
    }

    // 移除占位，插入真实回复
    _messages.removeWhere((m) => m.isTyping);
    _messages.add(
      ChatMessage(
        id: assistantId,
        content: content,
        sender: MessageSender.ai,
        time: DateTime.now(),
        extra: {'traces': List<Map<String, dynamic>>.from(_traceCache[msgId] ?? [])},
      ),
    );

    notifyListeners();
  }

  void _handleChatStreamChunk(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final chunk = payload['chunk'] as String? ?? '';
    final finished = payload['finished'] == true;
    final msgId = data['message_id'] as String? ?? _genId();
    final assistantId = _assistantMsgId(msgId);

    // 结束帧只负责状态收口。
    if (finished) {
      _streamingMsgIds.add(msgId);
      _isGenerating = false;
      _generationUnlockTimer?.cancel();
      notifyListeners();
      return;
    }

    if (chunk.isEmpty) return;

    // 第一块到达时移除 typing 占位。
    _streamingMsgIds.add(msgId);
    _messages.removeWhere((m) => m.isTyping);

    final existingIndex = _messages.indexWhere(
      (m) => m.id == assistantId && m.sender == MessageSender.ai,
    );

    if (existingIndex == -1) {
      _messages.add(
        ChatMessage(
          id: assistantId,
          content: chunk,
          sender: MessageSender.ai,
          time: DateTime.now(),
          extra: {'traces': List<Map<String, dynamic>>.from(_traceCache[msgId] ?? [])},
        ),
      );
    } else {
      final existing = _messages[existingIndex];
      final currentExtra = Map<String, dynamic>.from(existing.extra ?? {});
      if (_traceCache.containsKey(msgId)) {
        currentExtra['traces'] = List<Map<String, dynamic>>.from(_traceCache[msgId]!);
      }
      _messages[existingIndex] = existing.copyWith(
        content: _mergeAssistantContent(existing.content, chunk),
        isTyping: false,
        extra: currentExtra,
      );
    }

    notifyListeners();
  }

  void _handleTraceStepUpdate(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final msgId = data['message_id'] as String? ?? '';
    if (msgId.isEmpty) return;

    final stepId = payload['step_id'];
    final traceList = _traceCache.putIfAbsent(msgId, () => <Map<String, dynamic>>[]);
    final existingStepIdx = traceList.indexWhere((s) => s['step_id'] == stepId);
    if (existingStepIdx != -1) {
      traceList[existingStepIdx] = payload;
    } else {
      traceList.add(payload);
    }

    final assistantId = _assistantMsgId(msgId);
    final typingId = '${msgId}_typing';

    // 优先尝试查找助手消息或正在输入的占位
    int targetIdx = _messages.indexWhere((m) => m.id == assistantId);
    if (targetIdx == -1) {
      targetIdx = _messages.indexWhere((m) => m.id == typingId);
    }

    if (targetIdx != -1) {
      final msg = _messages[targetIdx];
      final currentExtra = Map<String, dynamic>.from(msg.extra ?? {});
      currentExtra['traces'] = List<Map<String, dynamic>>.from(traceList);
      _messages[targetIdx] = msg.copyWith(extra: currentExtra);
      notifyListeners();
    }
  }

  void _handleTraceSummary(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final msgId = data['message_id'] as String? ?? '';
    if (msgId.isEmpty) return;

    final assistantId = _assistantMsgId(msgId);
    final targetIdx = _messages.indexWhere((m) => m.id == assistantId);
    if (targetIdx != -1) {
      final msg = _messages[targetIdx];
      final currentExtra = Map<String, dynamic>.from(msg.extra ?? {});
      currentExtra['trace_summary'] = payload;
      _messages[targetIdx] = msg.copyWith(extra: currentExtra);
      notifyListeners();
    }
  }

  Future<void> _handleAuthResponse(Map<String, dynamic> data) async {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final status = payload['status'] as String?;

    isRestoringAuth = false;

    if (status == 'success') {
      _token = payload['token'] as String?;
      _user = payload['user'] as Map<String, dynamic>?;

      if (_token != null) {
        final prefs = await SharedPreferences.getInstance();
        await prefs.setString('auth_token', _token!);
        debugPrint('[WS] Auth 成功，已保存 Token: $_token');
      }

      _isAuthenticated = true;
      unawaited(loadRecentWorkspaces().then((_) {
        requestPersonaList();
        requestSessionList();
      }));
      notifyListeners();
    } else {
      debugPrint('[WS] Auth 响应未成功: ${payload['message']}');
    }
  }

  void _handleAuthRequired(Map<String, dynamic> data) {
    debugPrint('[WS] 收到审批请求: ${data['message_id']}');
    _authRequestController.add(data);
  }

  void _handleHistoryResponse(Map<String, dynamic> data) {
    final msgId = data['message_id'] as String?;
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final messagesJson = payload['messages'] as List<dynamic>? ?? [];
    final hasMore = payload['has_more'] == true;
    final offset = msgId != null
        ? (_historyRequestOffsets.remove(msgId) ?? 0)
        : 0;

    final loaded = <ChatMessage>[];
    for (var m in messagesJson) {
      final msg = m as Map<String, dynamic>;
      final isMe = msg['role'] == 'user';
      loaded.add(
        ChatMessage(
          id: msg['message_id']?.toString() ?? _genId(),
          content: msg['content'] as String? ?? '',
          sender: isMe ? MessageSender.me : MessageSender.ai,
          time: DateTime.fromMillisecondsSinceEpoch(
            (msg['timestamp'] as num).toInt(),
          ),
        ),
      );
    }

    // offset=0 代表首屏加载；否则是向上翻页加载更早记录。
    if (offset == 0) {
      _messages
        ..clear()
        ..addAll(loaded);
    } else {
      // 向上翻页时把更早消息插入头部，同时去重。
      final existingIds = _messages.map((m) => m.id).toSet();
      final prepend = loaded.where((m) => !existingIds.contains(m.id)).toList();
      _messages.insertAll(0, prepend);
    }

    _historyOffset = offset + loaded.length;
    _historyHasMore = hasMore;
    _historyLoading = false;
    if (msgId != null) {
      final completer = _historyRequestCompleters.remove(msgId);
      if (completer != null && !completer.isCompleted) {
        completer.complete();
      }
    }
    notifyListeners();
  }

  void _handlePersonaList(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final list = payload['personas'] as List<dynamic>? ?? [];
    _personas = list.map((p) => Map<String, dynamic>.from(p as Map)).toList();
    if (_activePersonaId.isEmpty && _personas.isNotEmpty) {
      _activePersonaId = _personas.first['id'] as String? ?? '';
    }
    notifyListeners();
  }

  void _handleSessionListResponse(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final list = payload['sessions'] as List<dynamic>? ?? [];
    _sessions = list.map((s) => Map<String, dynamic>.from(s as Map)).toList();

    if (_sessions.isEmpty) {
      createSession(workspacePath: _activeWorkspacePath);
    } else {
      final exists = _sessions.any((s) => s['id'] == _activeSessionId);
      if (!exists) {
        _activeSessionId = _sessions.first['id'] as String?;
        final pid = _sessions.first['persona_id'] as String?;
        if (pid != null && pid.isNotEmpty) {
          _activePersonaId = pid;
        }
      }
      unawaited(loadInitialHistory());
    }
    notifyListeners();
  }

  void _handleSessionCreateResponse(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final session = payload['session'] as Map<String, dynamic>?;
    if (session != null) {
      final sid = session['id'] as String?;
      _sessions.removeWhere((s) => s['id'] == sid);
      _sessions.insert(0, session);
      if (sid != null) {
        _activeSessionId = sid;
        final pid = session['persona_id'] as String?;
        if (pid != null && pid.isNotEmpty) {
          _activePersonaId = pid;
        }
        _messages.clear();
        _historyOffset = 0;
        _historyHasMore = false;
        unawaited(loadInitialHistory());
      }
    }
    notifyListeners();
  }

  void _handlePendingResponse(Map<String, dynamic> data) {
    final msgId = data['message_id'] as String?;
    if (msgId == null || msgId.isEmpty) return;

    final completer = _pendingResponses.remove(msgId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(data);
    }
  }

  // ── 认证方法 ─────────────────────────────────────────────────────────

  void login(String username, String password) {
    if (_status != WsStatus.connected) return;
    _send({
      'message_id': _genId(),
      'type': 'AUTH_LOGIN',
      'source': 'client',
      'target': 'host',
      'payload': {'username': username, 'password': password},
    });
  }

  void register(String username, String password) {
    if (_status != WsStatus.connected) return;
    _send({
      'message_id': _genId(),
      'type': 'AUTH_REGISTER',
      'source': 'client',
      'target': 'host',
      'payload': {'username': username, 'password': password},
    });
  }

  void restoreAuth() {
    if (_status != WsStatus.connected) return;
    isRestoringAuth = true;
    _send({
      'message_id': _genId(),
      'type': 'AUTH_RESTORE',
      'source': 'client',
      'target': 'host',
      'payload': {'token': _token ?? ''},
    });
  }

  void updateNickname(String nickname) {
    if (_status != WsStatus.connected) return;
    register(nickname, '');
  }

  void sendAuthResponse(String taskId, String decision) {
    if (_status != WsStatus.connected) return;
    _send({
      'message_id': taskId, // 必须回传相同的 message_id/task_id
      'type': 'AUTH_RESPONSE',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'task_id': taskId, 'decision': decision, 'reason': ''},
    });
  }

  Future<void> requestHistory({int limit = _historyPageSize, int offset = 0}) {
    if (_status != WsStatus.connected || !_isAuthenticated) {
      return Future.value();
    }
    final msgId = _genId();
    _historyLoading = true;
    // 用 message_id 绑定 offset/completer，保证并发请求时结果可正确归位。
    _historyRequestOffsets[msgId] = offset;
    final completer = Completer<void>();
    _historyRequestCompleters[msgId] = completer;
    notifyListeners();
    _send({
      'message_id': msgId,
      'type': 'HISTORY_REQUEST',
      'source': 'client',
      'target': 'host',
      'payload': {
        'limit': limit,
        'offset': offset,
        'persona_id': _activePersonaId,
        'session_id': _activeSessionId,
      },
    });
    return completer.future.timeout(
      const Duration(seconds: 10),
      onTimeout: () {
        _historyLoading = false;
        _historyRequestOffsets.remove(msgId);
        _historyRequestCompleters.remove(msgId);
        notifyListeners();
      },
    );
  }

  Future<void> loadInitialHistory({int limit = _historyPageSize}) async {
    _historyOffset = 0;
    _historyHasMore = true;
    await requestHistory(limit: limit, offset: 0);
  }

  Future<void> loadOlderHistory({int limit = _historyPageSize}) async {
    if (_historyLoading || !_historyHasMore) return;
    await requestHistory(limit: limit, offset: _historyOffset);
  }

  // ── 工作区与会话控制方法 ──

  Future<void> loadRecentWorkspaces() async {
    final prefs = await SharedPreferences.getInstance();
    _recentWorkspaces = prefs.getStringList('recent_workspaces') ?? [];
    if (_recentWorkspaces.isEmpty) {
      final defaultPath = Directory.current.path;
      _recentWorkspaces = [defaultPath];
      await prefs.setStringList('recent_workspaces', _recentWorkspaces);
    }
    if (_activeWorkspacePath.isEmpty && _recentWorkspaces.isNotEmpty) {
      _activeWorkspacePath = _recentWorkspaces.first;
    }
    notifyListeners();
  }

  Future<void> addWorkspace(String path) async {
    if (path.isEmpty) return;
    final normalized = path.trim();
    if (!_recentWorkspaces.contains(normalized)) {
      _recentWorkspaces.insert(0, normalized);
      final prefs = await SharedPreferences.getInstance();
      await prefs.setStringList('recent_workspaces', _recentWorkspaces);
    }
    setActiveWorkspace(normalized);
  }

  Future<void> removeWorkspace(String path) async {
    _recentWorkspaces.remove(path);
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('recent_workspaces', _recentWorkspaces);
    if (_activeWorkspacePath == path) {
      if (_recentWorkspaces.isNotEmpty) {
        setActiveWorkspace(_recentWorkspaces.first);
      } else {
        _activeWorkspacePath = '';
        _activeSessionId = null;
        _sessions.clear();
        _messages.clear();
      }
    }
    notifyListeners();
  }

  void setActiveWorkspace(String path) {
    if (_activeWorkspacePath == path) return;
    _activeWorkspacePath = path;
    _activeSessionId = null;
    _messages.clear();
    _historyOffset = 0;
    _historyHasMore = false;
    notifyListeners();
    requestSessionList(workspacePath: path);
  }

  void requestSessionList({String? workspacePath}) {
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'SESSION_LIST',
      'source': 'client',
      'target': 'host',
      'payload': {
        'workspace_path': workspacePath ?? _activeWorkspacePath,
      },
    });
  }

  void createSession({String? workspacePath, String? title, String? personaId}) {
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'SESSION_CREATE',
      'source': 'client',
      'target': 'host',
      'payload': {
        'workspace_path': workspacePath ?? _activeWorkspacePath,
        'title': title ?? '新对话',
        'persona_id': personaId ?? _activePersonaId,
      },
    });
  }

  void switchSession(String sessionId) {
    if (_activeSessionId == sessionId) return;
    _activeSessionId = sessionId;
    final sess = _sessions.firstWhere((s) => s['id'] == sessionId, orElse: () => {});
    if (sess['persona_id'] != null && sess['persona_id'].toString().isNotEmpty) {
      _activePersonaId = sess['persona_id'].toString();
    }
    _messages.clear();
    _historyOffset = 0;
    _historyHasMore = true;
    _historyLoading = false;
    notifyListeners();
    unawaited(loadInitialHistory());
  }

  void updateSessionTitle(String sessionId, String newTitle) {
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'SESSION_UPDATE',
      'source': 'client',
      'target': 'host',
      'payload': {
        'session_id': sessionId,
        'title': newTitle,
      },
    });
    final idx = _sessions.indexWhere((s) => s['id'] == sessionId);
    if (idx != -1) {
      _sessions[idx]['title'] = newTitle;
      notifyListeners();
    }
  }

  void updateSessionPersona(String sessionId, String personaId) {
    _activePersonaId = personaId;
    if (_status != WsStatus.connected || !_isAuthenticated) {
      notifyListeners();
      return;
    }
    _send({
      'message_id': _genId(),
      'type': 'SESSION_UPDATE',
      'source': 'client',
      'target': 'host',
      'payload': {
        'session_id': sessionId,
        'persona_id': personaId,
      },
    });
    final idx = _sessions.indexWhere((s) => s['id'] == sessionId);
    if (idx != -1) {
      _sessions[idx]['persona_id'] = personaId;
    }
    notifyListeners();
  }

  void deleteSession(String sessionId) {
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'SESSION_DELETE',
      'source': 'client',
      'target': 'host',
      'payload': {'session_id': sessionId},
    });
    _sessions.removeWhere((s) => s['id'] == sessionId);
    if (_activeSessionId == sessionId) {
      if (_sessions.isNotEmpty) {
        switchSession(_sessions.first['id']);
      } else {
        _activeSessionId = null;
        _messages.clear();
        createSession(workspacePath: _activeWorkspacePath);
      }
    }
    notifyListeners();
  }

  void clearSessionHistory() {
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'PERSONA_CLEAR_HISTORY',
      'source': 'client',
      'target': 'host',
      'payload': {
        'persona_id': _activePersonaId,
        'session_id': _activeSessionId,
      },
    });
    _messages.clear();
    _historyOffset = 0;
    _historyHasMore = false;
    notifyListeners();
  }

  void requestPersonaList() {
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'PERSONA_LIST',
      'source': 'client',
      'target': 'host',
      'payload': {},
    });
  }

  void switchPersona(String personaId) {
    if (_status != WsStatus.connected) return;
    _activePersonaId = personaId;
    _messages.clear();
    _historyOffset = 0;
    _historyHasMore = true;
    _historyLoading = false;
    notifyListeners();
    _send({
      'message_id': _genId(),
      'type': 'PERSONA_SWITCH',
      'source': 'client',
      'target': 'host',
      'payload': {'persona_id': personaId},
    });
    loadInitialHistory();
  }

  void clearPersonaHistory() {
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'PERSONA_CLEAR_HISTORY',
      'source': 'client',
      'target': 'host',
      'payload': {'persona_id': _activePersonaId},
    });
  }

  void deletePersona(String personaId) {
    if (_status != WsStatus.connected) return;
    _send({
      'message_id': _genId(),
      'type': 'PERSONA_DELETE',
      'source': 'client',
      'target': 'host',
      'payload': {'persona_id': personaId},
    });
  }

  void getMcpConfig() {
    if (_status != WsStatus.connected) return;
    _send({
      'message_id': _genId(),
      'type': 'MCP_CONFIG_GET',
      'source': 'client',
      'target': 'host',
      'payload': {},
    });
  }

  void updateMcpConfig(Map<String, dynamic> config) {
    if (_status != WsStatus.connected) return;
    _send({
      'message_id': _genId(),
      'type': 'MCP_CONFIG_UPDATE',
      'source': 'client',
      'target': 'host',
      'payload': {'config': config},
    });
  }

  Future<void> logout() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.remove('auth_token');
    _isAuthenticated = false;
    isRestoringAuth = false;
    _token = null;
    _user = null;
    _messages.clear();
    notifyListeners();
    if (_status == WsStatus.connected) {
      restoreAuth();
    }
  }

  void removeMessages(Set<String> messageIds) {
    if (messageIds.isEmpty) return;
    _messages.removeWhere((m) => messageIds.contains(m.id));
    notifyListeners();

    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'MESSAGE_DELETE',
      'source': 'client',
      'target': 'host',
      'payload': {
        'persona_id': _activePersonaId,
        'message_ids': messageIds.toList(),
      },
    });
  }

  /// 清空本地消息列表（配合清空历史记录使用）
  void clearLocalMessages() {
    _messages.clear();
    notifyListeners();
  }

  void _onError(Object error) {
    debugPrint('[WS] 错误: $error');
    _handleDisconnect();
  }

  void _onDone() {
    debugPrint('[WS] 连接关闭');
    _handleDisconnect();
  }

  void _handleDisconnect() {
    // 断线收口：先清 UI 占位，再释放 pending/completer，最后触发重连。
    _messages.removeWhere((m) => m.isTyping);
    _streamingMsgIds.clear();
    _pendingResponses.forEach((_, completer) {
      if (!completer.isCompleted) {
        completer.completeError(Exception('连接已断开'));
      }
    });
    _pendingResponses.clear();
    for (final completer in _historyRequestCompleters.values) {
      if (!completer.isCompleted) {
        completer.complete();
      }
    }
    _historyRequestCompleters.clear();
    _historyRequestOffsets.clear();
    _historyLoading = false;
    _isGenerating = false;
    _ttsGeneratingTurns.clear();
    _ttsBuffers.clear();
    _generationUnlockTimer?.cancel();
    _pingTimer?.cancel();
    unawaited(stopTtsAudio());
    _setStatus(WsStatus.disconnected);
    _scheduleReconnect();
  }

  void _sendHandshake() {
    // 连接建立后先发 CONNECT，向 Host 声明客户端能力与访问密钥。
    _send({
      'message_id': _genId(),
      'type': 'CONNECT',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        'client_version': '0.1.0',
        'platform': 'windows',
        'device_name': 'Lumi Client',
        if (_accessKey.isNotEmpty) 'access_key': _accessKey,
      },
    });
  }

  void _startPing() {
    // 心跳仅用于保活与探活，PONG 不参与业务状态更新。
    _pingTimer?.cancel();
    _pingTimer = Timer.periodic(_pingInterval, (_) {
      _send({
        'message_id': _genId(),
        'type': 'PING',
        'source': 'client',
        'target': 'host',
        'timestamp': DateTime.now().millisecondsSinceEpoch,
        'payload': {},
      });
    });
  }

  void _scheduleReconnect() {
    if (_disposed) return;
    _reconnectTimer?.cancel();
    _reconnectTimer = Timer(_reconnectDelay, connect);
  }

  void _send(Map<String, dynamic> data) {
    try {
      _channel?.sink.add(jsonEncode(data));
    } catch (e) {
      debugPrint('[WS] 发送失败: $e');
    }
  }

  /// 发送请求并等待响应（通过 message_id 匹配）。
  Future<Map<String, dynamic>?> sendRequest(
    String type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 10),
  }) async {
    if (_status != WsStatus.connected) return null;
    final msgId = _genId();
    final completer = Completer<Map<String, dynamic>>();
    _pendingResponses[msgId] = completer;
    _send({
      'message_id': msgId,
      'type': type,
      'source': 'client',
      'target': 'host',
      'payload': payload,
    });
    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pendingResponses.remove(msgId);
      return null;
    }
  }

  // ── 记忆系统 API ───────────────────────────────────────────────────────

  /// 获取指定人格的记忆列表
  Future<List<Map<String, dynamic>>> getMemories({
    String? personaId,
    String? category,
  }) async {
    final payload = <String, dynamic>{
      'persona_id': personaId ?? _activePersonaId,
    };
    if (category != null) {
      payload['category'] = category;
    }
    final resp = await sendRequest('MEMORY_LIST', payload);
    if (resp == null) return [];
    final list = resp['payload']?['memories'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// 手动录入一条记忆
  Future<bool> addMemory({
    String? personaId,
    required String category,
    required String content,
  }) async {
    final resp = await sendRequest('MEMORY_ADD', {
      'persona_id': personaId ?? _activePersonaId,
      'category': category,
      'content': content.trim(),
    });
    return resp?['payload']?['status'] == 'success';
  }

  /// 删除指定记忆
  Future<bool> deleteMemory(dynamic memoryId) async {
    final resp = await sendRequest('MEMORY_DELETE', {
      'memory_id': memoryId,
    });
    return resp?['payload']?['status'] == 'success';
  }

  /// 清空当前人格的所有记忆
  Future<int> clearMemories([String? personaId]) async {
    final resp = await sendRequest('MEMORY_CLEAR', {
      'persona_id': personaId ?? _activePersonaId,
    });
    if (resp?['payload']?['status'] == 'success') {
      return (resp!['payload']['cleared_count'] as num?)?.toInt() ?? 0;
    }
    return 0;
  }

  // ── 技能系统 API ───────────────────────────────────────────────────────

  /// 获取已安装的技能列表
  Future<List<Map<String, dynamic>>> getSkills() async {
    final resp = await sendRequest('SKILL_LIST', {});
    if (resp == null) return [];
    final list = resp['payload']?['skills'] as List<dynamic>? ?? [];
    return list.map((e) => Map<String, dynamic>.from(e as Map)).toList();
  }

  /// 从 Git 仓库安装技能
  Future<bool> installSkill(String gitUrl) async {
    final resp = await sendRequest('SKILL_INSTALL', {
      'git_url': gitUrl.trim(),
    }, timeout: const Duration(seconds: 45));
    return resp?['payload']?['status'] == 'success';
  }

  /// 卸载指定技能
  Future<bool> uninstallSkill(String skillName) async {
    final resp = await sendRequest('SKILL_UNINSTALL', {
      'skill_name': skillName.trim(),
    });
    return resp?['payload']?['status'] == 'success';
  }

  void _setStatus(WsStatus s) {
    _status = s;
    notifyListeners();
  }

  String _genId() =>
      // 轻量本地 id：用于请求-响应关联，不用于安全场景。
      Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

  @override
  void dispose() {
    _disposed = true;
    _authRequestController.close();
    _mcpConfigController.close();
    _voiceEventController.close();
    _personaController.close();
    _ttsPlayerStateSub?.cancel();
    _ttsWindowsPlayerStateSub?.cancel();

    final windowsPlayer = _ttsWindowsPlayer;
    _ttsWindowsPlayer = null;
    if (windowsPlayer != null) {
      unawaited(windowsPlayer.dispose());
    }

    _ttsPlayer?.dispose();
    disconnect();
    super.dispose();
  }
}
