part of 'ws_service.dart';

extension WsServiceLlmPart on WsService {
  // ── 模型配置管理与快速切换 API ───────────────────────────────────────

  /// 从 Host 获取模型列表与当前激活模型
  Future<void> fetchLlmConfig() async {
    final resp = await sendRequest('LLM_CONFIG_GET', {});
    if (resp != null) {
      final payload = resp['payload'] as Map<String, dynamic>? ?? {};
      _activeModelId = (payload['active_model_id'] as String?) ?? 'default';
      if (payload['reasoning_effort'] != null) {
        _reasoningEffort = (payload['reasoning_effort'] as String).toLowerCase();
      }
      final list = payload['models'] as List<dynamic>? ?? [];
      _configuredModels = list.map((m) => Map<String, dynamic>.from(m as Map)).toList();

      final active = _configuredModels.firstWhere(
        (m) => m['id'] == _activeModelId,
        orElse: () => _configuredModels.isNotEmpty ? _configuredModels.first : <String, dynamic>{},
      );
      _activeModelName = (active['name'] as String?) ?? (active['model'] as String?) ?? '';
      _notifyStateChanged();
    }
  }

  /// 快速切换当前生效模型
  Future<bool> switchModel(String modelId) async {
    final resp = await sendRequest('LLM_SWITCH_MODEL', {'model_id': modelId});
    if (resp != null && resp['payload']?['status'] == 'success') {
      _activeModelId = modelId;
      final payload = resp['payload'] as Map<String, dynamic>? ?? {};
      _activeModelName = (payload['name'] as String?) ?? (payload['model'] as String?) ?? _activeModelName;
      if (payload['reasoning_effort'] != null) {
        _reasoningEffort = (payload['reasoning_effort'] as String).toLowerCase();
      }
      _notifyStateChanged();
      return true;
    }
    return false;
  }

  /// 快速切换思考/推理等级 (low / medium / high)
  Future<bool> setReasoningEffort(String level) async {
    final clean = level.trim().toLowerCase();
    if (!['low', 'medium', 'high'].contains(clean)) return false;
    _reasoningEffort = clean;
    _notifyStateChanged();
    final resp = await sendRequest('LLM_SET_THINKING_LEVEL', {'level': clean});
    return resp != null && resp['payload']?['status'] == 'success';
  }

  /// 保存或添加模型 Profile
  Future<bool> saveModelProfile(Map<String, dynamic> modelData, {bool setActive = false}) async {
    final resp = await sendRequest('LLM_MODEL_SAVE', {
      'model': modelData,
      'set_active': setActive,
    });
    if (resp != null && resp['payload']?['status'] == 'success') {
      await fetchLlmConfig();
      return true;
    }
    return false;
  }

  /// 删除模型 Profile
  Future<bool> deleteModelProfile(String modelId) async {
    final resp = await sendRequest('LLM_MODEL_DELETE', {'model_id': modelId});
    if (resp != null && resp['payload']?['status'] == 'success') {
      await fetchLlmConfig();
      return true;
    }
    return false;
  }
}
