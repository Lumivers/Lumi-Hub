part of 'ws_service.dart';

extension WsServiceFeaturesPart on WsService {
  // ── 用户审批与交互式问答 ──

  void _handleAuthRequired(Map<String, dynamic> data) {
    debugPrint('[WS] 收到审批请求: ${data['message_id']}');
    _authRequestController.add(data);
  }

  void _handleAskUserQuestion(Map<String, dynamic> data) {
    debugPrint('[WS] 收到用户问答卡片请求: ${data['message_id']}');
    _userQuestionController.add(data);
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

  void sendUserQuestionResponse(String messageId, List<Map<String, dynamic>> answers) {
    if (_status != WsStatus.connected) return;
    _send({
      'message_id': messageId, // 必须回传相同的 message_id 作为挂起 Future 的唤醒键
      'type': 'USER_QUESTION_RESPONSE',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {'answers': answers},
    });
  }

  // ── MCP 配置 API ──

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
}
