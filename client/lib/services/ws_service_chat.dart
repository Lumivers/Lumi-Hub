part of 'ws_service.dart';

extension WsServiceChatPart on WsService {
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
    _notifyStateChanged();

    // 发送到 Host
    final payload = <String, dynamic>{
      'content': contentForHost,
      'context_id': 'default',
      'persona_id': _activePersonaId,
      'session_id': _activeSessionId,
      'workspace_path': _activeWorkspacePath,
      'attachments': attachments,
      'reasoning_effort': _reasoningEffort,
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

  /// 打断当前正在进行的 AI 生成/工具执行
  void cancelCurrentGeneration() {
    if (!_isGenerating) return;
    _send({
      'type': 'CHAT_CANCEL',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        'session_id': _activeSessionId,
      },
    });
    _isGenerating = false;
    _generationUnlockTimer?.cancel();
    _notifyStateChanged();
  }

  /// 回退指定文件的代码修改 (支持 Git checkout 与 .Lumi_cache 备份还原)
  Future<List<Map<String, dynamic>>> revertFiles(List<String> filePaths) async {
    if (filePaths.isEmpty || _status != WsStatus.connected) return [];
    final resp = await sendRequest('REVERT_FILES', {
      'files': filePaths,
      'workspace_path': _activeWorkspacePath,
    });
    if (resp != null && resp['payload']?['status'] == 'success') {
      final results = resp['payload']?['results'] as List<dynamic>? ?? [];
      return results.map((e) => Map<String, dynamic>.from(e as Map)).toList();
    }
    return [];
  }

  /// 获取当前会话中最后一条用户提问消息（排除单纯附件气泡）
  ChatMessage? get lastUserMessage {
    for (int i = _messages.length - 1; i >= 0; i--) {
      final m = _messages[i];
      if (m.sender == MessageSender.me &&
          !m.content.startsWith('[附件] ') &&
          !m.content.startsWith('[图片] ')) {
        return m;
      }
    }
    return null;
  }

  /// 判断指定消息是否为当前最新的（即最后一条）用户提问
  bool isLastUserMessage(String id) {
    return lastUserMessage?.id == id;
  }

  /// 判断指定消息是否为更早的历史用户提问（可回滚节点）
  bool isEarlierUserMessage(String id) {
    final last = lastUserMessage;
    if (last == null || last.id == id) return false;
    final idx = _messages.indexWhere((m) => m.id == id);
    if (idx == -1) return false;
    final msg = _messages[idx];
    return msg.sender == MessageSender.me &&
        !msg.content.startsWith('[附件] ') &&
        !msg.content.startsWith('[图片] ');
  }

  /// 获取从指定用户提问（包含其附件）开始一直到当前会话末尾的所有消息
  List<ChatMessage> getMessagesFromUserOnwards(String userMsgId) {
    final attId = '${userMsgId}_att';
    int startIdx = _messages.indexWhere((m) => m.id == attId);
    if (startIdx == -1) {
      startIdx = _messages.indexWhere((m) => m.id == userMsgId);
    }
    if (startIdx == -1) return [];
    return _messages.sublist(startIdx);
  }

  /// 收集从指定用户提问开始之后所有助手回复中变动过的文件
  List<Map<String, dynamic>> getFilesChangedFromUserOnwards(String userMsgId) {
    final msgs = getMessagesFromUserOnwards(userMsgId);
    final fileMap = <String, Map<String, dynamic>>{};
    for (final m in msgs) {
      if (m.sender == MessageSender.ai) {
        final raw = m.extra?['files_changed'] ??
            m.extra?['trace_summary']?['files_changed'];
        final list =
            (raw as List?)?.whereType<Map<dynamic, dynamic>>().toList() ?? [];
        for (final item in list) {
          final f = Map<String, dynamic>.from(item);
          final path = f['path'] as String? ?? '';
          if (path.isNotEmpty) {
            fileMap[path] = f;
          }
        }
      }
    }
    return fileMap.values.toList();
  }

  /// 获取与指定用户消息对应的助手消息（或正在生成的占位消息）
  ChatMessage? getAssistantMessageForUser(String userMsgId) {
    final asstId = _assistantMsgId(userMsgId);
    final typingId = '${userMsgId}_typing';
    final target = _messages.where((m) => m.id == asstId || m.id == typingId);
    if (target.isNotEmpty) return target.first;

    final userIdx = _messages.indexWhere((m) => m.id == userMsgId);
    if (userIdx != -1 && userIdx + 1 < _messages.length) {
      final next = _messages[userIdx + 1];
      if (next.sender == MessageSender.ai) return next;
    }
    return null;
  }

  /// 获取本轮对话关联的所有消息 ID（包括用户提问、附件、助手回复及 typing 占位）
  Set<String> getTurnMessageIds(String userMsgId) {
    final ids = <String>{
      userMsgId,
      '${userMsgId}_att',
      '${userMsgId}_typing',
      _assistantMsgId(userMsgId),
    };
    final asst = getAssistantMessageForUser(userMsgId);
    if (asst != null) ids.add(asst.id);
    return ids;
  }

  void _handleChatMessageSync(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final msgId = (payload['message_id'] as String?) ?? (data['message_id'] as String?) ?? '';
    if (msgId.isEmpty) return;

    // 回声抑制 (Echo Suppression): 若本地已包含该消息（例如自身发送并乐观渲染），直接忽略
    if (_messages.any((m) => m.id == msgId)) {
      return;
    }

    final targetSessionId = payload['session_id'] as String?;
    if (targetSessionId != null &&
        _activeSessionId != null &&
        targetSessionId != _activeSessionId) {
      return;
    }

    final content = payload['content'] as String? ?? '';
    final role = payload['role'] as String? ?? 'user';
    final now = DateTime.now();

    // 渲染对端设备发送的用户消息
    if (role == 'user' && content.isNotEmpty) {
      _messages.add(
        ChatMessage(
          id: msgId,
          content: content,
          sender: MessageSender.me,
          time: now,
        ),
      );

      // 为接收端挂上 AI 正在输入的 typing 占位，并开启生成状态
      final typingId = '${msgId}_typing';
      if (!_messages.any((m) => m.id == typingId)) {
        _messages.add(
          ChatMessage(
            id: typingId,
            content: '',
            sender: MessageSender.ai,
            time: now,
            isTyping: true,
            extra: {'traces': _traceCache.putIfAbsent(msgId, () => <Map<String, dynamic>>[])},
          ),
        );
      }
      _isGenerating = true;
      _generationUnlockTimer?.cancel();
      _generationUnlockTimer = Timer(const Duration(seconds: 120), () {
        _isGenerating = false;
        _notifyStateChanged();
      });

      _notifyStateChanged();
    }
  }

  void _handleChatResponse(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final targetSessionId = payload['session_id'] as String?;
    if (targetSessionId != null &&
        _activeSessionId != null &&
        targetSessionId != _activeSessionId) {
      return;
    }

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
      _notifyStateChanged();
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

    _notifyStateChanged();
  }

  void _handleChatStreamChunk(Map<String, dynamic> data) {
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final targetSessionId = payload['session_id'] as String?;
    if (targetSessionId != null &&
        _activeSessionId != null &&
        targetSessionId != _activeSessionId) {
      return;
    }

    final chunk = payload['chunk'] as String? ?? '';
    final finished = payload['finished'] == true;
    final msgId = data['message_id'] as String? ?? _genId();
    final assistantId = _assistantMsgId(msgId);

    // 结束帧只负责状态收口。
    if (finished) {
      _streamingMsgIds.add(msgId);
      _isGenerating = false;
      _generationUnlockTimer?.cancel();
      _notifyStateChanged();
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

    _notifyStateChanged();
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
      _notifyStateChanged();
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
      if (payload['files_changed'] != null) {
        currentExtra['files_changed'] = payload['files_changed'];
      }
      _messages[targetIdx] = msg.copyWith(extra: currentExtra);
      _notifyStateChanged();
    }
  }
}
