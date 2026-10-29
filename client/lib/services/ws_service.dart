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

part 'ws_service_chat.dart';
part 'ws_service_features.dart';
part 'ws_service_llm.dart';
part 'ws_service_session.dart';
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
  /// 采用 part 文件解耦业务模块：
  /// - ws_service_chat.dart: 对话、流式回包、打断、Trace 轨迹与回滚
  /// - ws_service_llm.dart: 模型列表拉取、模型切换、推理思考强度调节
  /// - ws_service_session.dart: 工作区、会话、人格、历史记录分页与消息删除
  /// - ws_service_features.dart: MCP、记忆档案、技能管理、审批授权与问答交互
  /// - ws_service_tts.dart: 语音流分块合成与本地播放
  /// - ws_service_upload.dart: 大文件分片上传
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

  // 用户交互式问答卡片流 (ask_user_question)
  final _userQuestionController =
      StreamController<Map<String, dynamic>>.broadcast();
  Stream<Map<String, dynamic>> get userQuestions =>
      _userQuestionController.stream;

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

  // ── 模型配置与快速切换 ──
  String _activeModelId = 'default';
  String _activeModelName = '';
  String _reasoningEffort = 'high';
  List<Map<String, dynamic>> _configuredModels = [];

  String get activeModelId => _activeModelId;
  String get activeModelName => _activeModelName.isNotEmpty ? _activeModelName : '默认模型';
  String get reasoningEffort => _reasoningEffort;
  List<Map<String, dynamic>> get configuredModels => List.unmodifiable(_configuredModels);

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
    if (_status == WsStatus.connected && !_isAuthenticated) {
      restoreAuth();
    }
    if (!_authInitCompleter.isCompleted) {
      _authInitCompleter.complete();
    }
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

  // ── 协议分发中心 ────────────────────────────────────────────────────────

  void _onData(dynamic raw) {
    try {
      final data = jsonDecode(raw as String) as Map<String, dynamic>;
      final type = data['type'] as String? ?? '';

      // 优先处理 pending response（通过 message_id 匹配）
      _handlePendingResponse(data);

      switch (type) {
        case 'CHAT_RESPONSE':
          _handleChatResponse(data);
          break;
        case 'CHAT_MESSAGE_SYNC':
          _handleChatMessageSync(data);
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
        case 'TOOL_CALL_START':
        case 'TOOL_CALL_RESULT':
          break;
        case 'PONG':
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
        case 'ASK_USER_QUESTION':
          _handleAskUserQuestion(data);
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
          break;
        default:
          debugPrint('[WS] 未处理消息类型: $type');
      }
    } catch (e) {
      debugPrint('[WS] 解析消息失败: $e');
    }
  }

  void _handlePendingResponse(Map<String, dynamic> data) {
    final msgId = data['message_id'] as String?;
    if (msgId == null || msgId.isEmpty) return;

    final completer = _pendingResponses.remove(msgId);
    if (completer != null && !completer.isCompleted) {
      completer.complete(data);
    }
  }

  // ── 认证逻辑 ─────────────────────────────────────────────────────────

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
        fetchLlmConfig();
      }));
      notifyListeners();
    } else {
      debugPrint('[WS] Auth 响应未成功: ${payload['message']}');
    }
  }

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

  // ── 通信底层 ──────────────────────────────────────────────────────────

  void _onError(Object error) {
    debugPrint('[WS] 错误: $error');
    _handleDisconnect();
  }

  void _onDone() {
    debugPrint('[WS] 连接关闭');
    _handleDisconnect();
  }

  void _handleDisconnect() {
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

  void _setStatus(WsStatus s) {
    _status = s;
    notifyListeners();
  }

  String _genId() =>
      Random().nextInt(0xFFFFFF).toRadixString(16).padLeft(6, '0');

  @override
  void dispose() {
    _disposed = true;
    _authRequestController.close();
    _userQuestionController.close();
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
