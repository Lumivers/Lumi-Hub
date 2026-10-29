part of 'ws_service.dart';

extension WsServiceSessionPart on WsService {
  void _handlePersonaList(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final list = payload['personas'] as List<dynamic>? ?? [];
    _personas = list.map((p) => Map<String, dynamic>.from(p as Map)).toList();
    if (_activePersonaId.isEmpty && _personas.isNotEmpty) {
      _activePersonaId = _personas.first['id'] as String? ?? '';
    }
    _notifyStateChanged();
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
    _notifyStateChanged();
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
    _notifyStateChanged();
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
      final extraRaw = msg['extra'];
      Map<String, dynamic>? extraMap;
      if (extraRaw is Map) {
        extraMap = Map<String, dynamic>.from(extraRaw);
      }

      // 同步恢复历史中的 Trace 执行轨迹至本地缓存
      if (extraMap != null && extraMap['traces'] is List) {
        final rawId = msg['message_id']?.toString() ?? '';
        final baseMsgId = rawId.replaceAll(RegExp(r'_ai$'), '');
        if (baseMsgId.isNotEmpty) {
          final list = (extraMap['traces'] as List)
              .whereType<Map<dynamic, dynamic>>()
              .map((e) => Map<String, dynamic>.from(e))
              .toList();
          _traceCache[baseMsgId] = list;
        }
      }

      loaded.add(
        ChatMessage(
          id: msg['message_id']?.toString() ?? _genId(),
          content: msg['content'] as String? ?? '',
          sender: isMe ? MessageSender.me : MessageSender.ai,
          time: DateTime.fromMillisecondsSinceEpoch(
            (msg['timestamp'] as num).toInt(),
          ),
          extra: extraMap,
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
    _notifyStateChanged();
  }

  Future<void> requestHistory({int limit = WsService._historyPageSize, int offset = 0}) {
    if (_status != WsStatus.connected || !_isAuthenticated) {
      return Future.value();
    }
    final msgId = _genId();
    _historyLoading = true;
    _historyRequestOffsets[msgId] = offset;
    final completer = Completer<void>();
    _historyRequestCompleters[msgId] = completer;
    _notifyStateChanged();
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
        _notifyStateChanged();
      },
    );
  }

  Future<void> loadInitialHistory({int limit = WsService._historyPageSize}) async {
    _historyOffset = 0;
    _historyHasMore = true;
    await requestHistory(limit: limit, offset: 0);
  }

  Future<void> loadOlderHistory({int limit = WsService._historyPageSize}) async {
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
    _notifyStateChanged();
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
    _notifyStateChanged();
  }

  void setActiveWorkspace(String path) {
    if (_activeWorkspacePath == path) return;
    _activeWorkspacePath = path;
    _activeSessionId = null;
    _messages.clear();
    _historyOffset = 0;
    _historyHasMore = false;
    _notifyStateChanged();
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
    _notifyStateChanged();
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
      _notifyStateChanged();
    }
  }

  void updateSessionPersona(String sessionId, String personaId) {
    _activePersonaId = personaId;
    if (_status != WsStatus.connected || !_isAuthenticated) {
      _notifyStateChanged();
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
    _notifyStateChanged();
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
    _notifyStateChanged();
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
    _notifyStateChanged();
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
    _notifyStateChanged();
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

  void removeMessages(Set<String> messageIds) {
    if (messageIds.isEmpty) return;
    _messages.removeWhere((m) => messageIds.contains(m.id));
    _notifyStateChanged();

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
    _notifyStateChanged();
  }
}
