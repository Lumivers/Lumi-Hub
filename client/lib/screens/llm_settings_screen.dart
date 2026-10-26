import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ws_service.dart';

/// 预设模板元数据（供添加模型时一键回填默认配置）
class _ModelTemplate {
  final String id;
  final String name;
  final String providerType; // 'openai', 'anthropic', 'ollama'
  final String defaultBaseUrl;
  final String defaultModel;
  final List<String> recommendedModels;
  final String hint;

  const _ModelTemplate({
    required this.id,
    required this.name,
    required this.providerType,
    required this.defaultBaseUrl,
    required this.defaultModel,
    required this.recommendedModels,
    required this.hint,
  });
}

const List<_ModelTemplate> _kTemplates = [
  _ModelTemplate(
    id: 'custom',
    name: '自定义中转站 / 反代',
    providerType: 'openai',
    defaultBaseUrl: '',
    defaultModel: '',
    recommendedModels: [],
    hint: '兼容 OpenAI 协议的自建网关或中转分发服务',
  ),
  _ModelTemplate(
    id: 'deepseek',
    name: 'DeepSeek',
    providerType: 'openai',
    defaultBaseUrl: 'https://api.deepseek.com',
    defaultModel: 'deepseek-chat',
    recommendedModels: ['deepseek-chat', 'deepseek-reasoner'],
    hint: '官方 OpenAI 兼容端点',
  ),
  _ModelTemplate(
    id: 'aliyun_bailian',
    name: '阿里百炼 / 通义千问',
    providerType: 'openai',
    defaultBaseUrl: 'https://dashscope.aliyuncs.com/compatible-mode/v1',
    defaultModel: 'qwen-plus',
    recommendedModels: ['qwen-max', 'qwen-plus', 'qwen-turbo', 'qwen2.5-72b-instruct'],
    hint: '阿里云 DashScope 兼容模式',
  ),
  _ModelTemplate(
    id: 'zhipu',
    name: '智谱 AI / GLM',
    providerType: 'openai',
    defaultBaseUrl: 'https://open.bigmodel.cn/api/paas/v4',
    defaultModel: 'glm-4-plus',
    recommendedModels: ['glm-4-plus', 'glm-4-flash', 'glm-4-air'],
    hint: '清华智谱大模型',
  ),
  _ModelTemplate(
    id: 'moonshot',
    name: '月之暗面 / Kimi',
    providerType: 'openai',
    defaultBaseUrl: 'https://api.moonshot.cn/v1',
    defaultModel: 'moonshot-v1-8k',
    recommendedModels: ['moonshot-v1-8k', 'moonshot-v1-32k', 'moonshot-v1-128k'],
    hint: '长文本长上下文理解',
  ),
  _ModelTemplate(
    id: 'siliconflow',
    name: '硅基流动',
    providerType: 'openai',
    defaultBaseUrl: 'https://api.siliconflow.cn/v1',
    defaultModel: 'deepseek-ai/DeepSeek-V3',
    recommendedModels: [
      'deepseek-ai/DeepSeek-V3',
      'deepseek-ai/DeepSeek-R1',
      'Qwen/Qwen2.5-72B-Instruct',
    ],
    hint: '开源模型聚合加速平台',
  ),
  _ModelTemplate(
    id: 'openai',
    name: 'OpenAI (ChatGPT)',
    providerType: 'openai',
    defaultBaseUrl: 'https://api.openai.com/v1',
    defaultModel: 'gpt-4o',
    recommendedModels: ['gpt-4o', 'gpt-4o-mini', 'o1', 'o3-mini'],
    hint: 'OpenAI 官方端点',
  ),
  _ModelTemplate(
    id: 'anthropic',
    name: 'Anthropic (Claude)',
    providerType: 'anthropic',
    defaultBaseUrl: 'https://api.anthropic.com',
    defaultModel: 'claude-3-7-sonnet-20250219',
    recommendedModels: [
      'claude-3-7-sonnet-20250219',
      'claude-3-5-sonnet-20241022',
      'claude-3-5-haiku-20241022',
    ],
    hint: 'Anthropic 官方端点',
  ),
  _ModelTemplate(
    id: 'ollama',
    name: 'Ollama (本地离线)',
    providerType: 'ollama',
    defaultBaseUrl: 'http://localhost:11434/v1',
    defaultModel: 'qwen2.5:latest',
    recommendedModels: ['qwen2.5:latest', 'deepseek-r1:8b', 'llama3.2:latest'],
    hint: '本地私有服务，无需 API Key',
  ),
];

/// AI 模型设置页面 — 支持用户自主增删管理模型，主页下拉按需展示
class LlmSettingsScreen extends StatefulWidget {
  final bool embedded;

  const LlmSettingsScreen({super.key, this.embedded = false});

  @override
  State<LlmSettingsScreen> createState() => _LlmSettingsScreenState();
}

class _LlmSettingsScreenState extends State<LlmSettingsScreen> {
  bool _loading = true;
  bool _editing = false;
  String? _editingModelId;

  // 编辑表单控制器
  String _selectedTemplateId = 'custom';
  final _nameController = TextEditingController();
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  bool _setActiveOnSave = true;
  bool _showApiKey = false;
  bool _saving = false;
  bool _testing = false;
  Map<String, dynamic>? _testResult;

  @override
  void initState() {
    super.initState();
    _loadModels();
  }

  @override
  void dispose() {
    _nameController.dispose();
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _loadModels() async {
    final ws = context.read<WsService>();
    await ws.fetchLlmConfig();
    if (mounted) {
      setState(() => _loading = false);
    }
  }

  void _openEditor({Map<String, dynamic>? model}) {
    setState(() {
      _editing = true;
      _testResult = null;
      _showApiKey = false;

      if (model != null) {
        _editingModelId = model['id'] as String?;
        _nameController.text = (model['name'] as String?) ?? '';
        _baseUrlController.text = (model['base_url'] as String?) ?? '';
        _modelController.text = (model['model'] as String?) ?? '';
        _apiKeyController.clear();
        _selectedTemplateId = (model['provider_preset'] as String?) ?? 'custom';
        _setActiveOnSave = model['id'] == context.read<WsService>().activeModelId;
      } else {
        _editingModelId = null;
        _nameController.clear();
        _apiKeyController.clear();
        _baseUrlController.clear();
        _modelController.clear();
        _selectedTemplateId = 'deepseek';
        _setActiveOnSave = true;
        _applyTemplate('deepseek');
      }
    });
  }

  void _applyTemplate(String templateId) {
    final t = _kTemplates.firstWhere(
      (item) => item.id == templateId,
      orElse: () => _kTemplates.first,
    );
    if (t.id != 'custom') {
      if (_nameController.text.trim().isEmpty ||
          _kTemplates.any((item) => item.name == _nameController.text.trim())) {
        _nameController.text = t.name;
      }
      _baseUrlController.text = t.defaultBaseUrl;
      _modelController.text = t.defaultModel;
    }
  }

  void _cancelEditor() {
    setState(() {
      _editing = false;
      _editingModelId = null;
      _testResult = null;
    });
  }

  Future<void> _testConnection() async {
    setState(() {
      _testing = true;
      _testResult = null;
    });

    final ws = context.read<WsService>();
    final t = _kTemplates.firstWhere(
      (item) => item.id == _selectedTemplateId,
      orElse: () => _kTemplates.first,
    );

    final config = <String, dynamic>{
      'provider': t.providerType,
      'provider_preset': t.id,
      'base_url': _baseUrlController.text.trim(),
      'model': _modelController.text.trim(),
    };

    final key = _apiKeyController.text.trim();
    if (key.isNotEmpty) {
      config['api_key'] = key;
    }

    final resp = await ws.sendRequest('LLM_TEST_CONNECTION', {
      'config': config,
    }, timeout: const Duration(seconds: 20));

    if (!mounted) return;

    setState(() {
      _testing = false;
      if (resp != null && resp['payload'] != null) {
        _testResult = Map<String, dynamic>.from(resp['payload'] as Map);
      } else {
        _testResult = {
          'status': 'error',
          'latency_ms': 0,
          'message': '测试请求超时，未能从 Host 获得连通响应',
        };
      }
    });
  }

  Future<void> _saveModel() async {
    final name = _nameController.text.trim();
    final modelName = _modelController.text.trim();
    if (name.isEmpty || modelName.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('请填写模型名称和模型标识 (Model ID)')),
      );
      return;
    }

    setState(() => _saving = true);
    final ws = context.read<WsService>();
    final t = _kTemplates.firstWhere(
      (item) => item.id == _selectedTemplateId,
      orElse: () => _kTemplates.first,
    );

    final modelData = <String, dynamic>{
      'name': name,
      'provider': t.providerType,
      'provider_preset': t.id,
      'model': modelName,
      'base_url': _baseUrlController.text.trim(),
    };

    if (_editingModelId != null && _editingModelId!.isNotEmpty) {
      modelData['id'] = _editingModelId;
    }

    final newKey = _apiKeyController.text.trim();
    if (newKey.isNotEmpty) {
      modelData['api_key'] = newKey;
    }

    final ok = await ws.saveModelProfile(modelData, setActive: _setActiveOnSave);
    if (!mounted) return;

    setState(() {
      _saving = false;
      if (ok) {
        _editing = false;
        _editingModelId = null;
      }
    });

    if (ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('已保存模型: $name')),
      );
    } else {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('保存模型失败'), backgroundColor: Colors.red),
      );
    }
  }

  Future<void> _deleteModel(String modelId, String name) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('删除模型'),
        content: Text('确定要删除模型「$name」吗？'),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx, false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.pop(ctx, true),
            style: TextButton.styleFrom(foregroundColor: Colors.red),
            child: const Text('删除'),
          ),
        ],
      ),
    );

    if (ok == true && mounted) {
      final ws = context.read<WsService>();
      final deleted = await ws.deleteModelProfile(modelId);
      if (mounted) {
        if (deleted) {
          ScaffoldMessenger.of(context).showSnackBar(
            SnackBar(content: Text('已删除模型: $name')),
          );
        } else {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('删除失败，至少需要保留一个模型'), backgroundColor: Colors.red),
          );
        }
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }

    return _editing ? _buildEditorView(context) : _buildModelListView(context);
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // 视图 1: 我的模型列表（单列清爽卡片流）
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildModelListView(BuildContext context) {
    final theme = Theme.of(context);
    final ws = context.watch<WsService>();
    final models = ws.configuredModels;
    final activeId = ws.activeModelId;

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      children: [
        // 顶部操作行
        Row(
          mainAxisAlignment: MainAxisAlignment.spaceBetween,
          children: [
            Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  '已配置模型',
                  style: theme.textTheme.titleMedium?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  '主页面下拉菜单将仅展示你在此添加的模型',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
            FilledButton.icon(
              onPressed: () => _openEditor(),
              icon: const Icon(Icons.add, size: 18),
              label: const Text('添加模型'),
              style: FilledButton.styleFrom(
                visualDensity: VisualDensity.compact,
                padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 8),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        if (models.isEmpty)
          Container(
            padding: const EdgeInsets.all(24),
            decoration: BoxDecoration(
              color: theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
              borderRadius: BorderRadius.circular(12),
            ),
            child: Center(
              child: Column(
                children: [
                  Icon(
                    Icons.smart_toy_outlined,
                    size: 36,
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.4),
                  ),
                  const SizedBox(height: 12),
                  const Text('暂无模型配置'),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => _openEditor(),
                    icon: const Icon(Icons.add, size: 16),
                    label: const Text('添加第一个模型'),
                  ),
                ],
              ),
            ),
          )
        else
          ...models.map((m) {
            final id = m['id'] as String? ?? '';
            final name = (m['name'] as String?) ?? (m['model'] as String?) ?? '未命名';
            final modelCode = (m['model'] as String?) ?? '';
            final baseUrl = (m['base_url'] as String?) ?? '';
            final keyConfigured = m['api_key_configured'] as bool? ?? false;
            final keyMasked = (m['api_key_masked'] as String?) ?? '';
            final isCur = id == activeId;

            return Container(
              margin: const EdgeInsets.only(bottom: 12),
              decoration: BoxDecoration(
                color: isCur
                    ? theme.colorScheme.primaryContainer.withValues(alpha: 0.25)
                    : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color: isCur
                      ? theme.colorScheme.primary.withValues(alpha: 0.7)
                      : theme.colorScheme.outlineVariant.withValues(alpha: 0.4),
                  width: isCur ? 1.5 : 1.0,
                ),
              ),
              child: Padding(
                padding: const EdgeInsets.all(16),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: [
                    // 图标
                    Container(
                      padding: const EdgeInsets.all(10),
                      decoration: BoxDecoration(
                        color: isCur
                            ? theme.colorScheme.primary.withValues(alpha: 0.15)
                            : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.5),
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(
                        Icons.smart_toy_outlined,
                        size: 22,
                        color: isCur ? theme.colorScheme.primary : theme.colorScheme.onSurfaceVariant,
                      ),
                    ),
                    const SizedBox(width: 14),

                    // 中间信息
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Row(
                            children: [
                              Text(
                                name,
                                style: theme.textTheme.titleSmall?.copyWith(
                                  fontWeight: FontWeight.bold,
                                ),
                              ),
                              if (isCur) ...[
                                const SizedBox(width: 8),
                                Container(
                                  padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
                                  decoration: BoxDecoration(
                                    color: Colors.green.withValues(alpha: 0.18),
                                    borderRadius: BorderRadius.circular(4),
                                    border: Border.all(color: Colors.green.withValues(alpha: 0.4)),
                                  ),
                                  child: const Text(
                                    '当前生效',
                                    style: TextStyle(
                                      fontSize: 10,
                                      fontWeight: FontWeight.bold,
                                      color: Colors.green,
                                    ),
                                  ),
                                ),
                              ],
                            ],
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 12,
                            runSpacing: 4,
                            children: [
                              Text(
                                '模型: $modelCode',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: theme.colorScheme.onSurface.withValues(alpha: 0.75),
                                ),
                              ),
                              if (baseUrl.isNotEmpty)
                                Text(
                                  '端点: $baseUrl',
                                  style: theme.textTheme.bodySmall?.copyWith(
                                    color: theme.colorScheme.onSurface.withValues(alpha: 0.5),
                                  ),
                                ),
                              Text(
                                keyConfigured ? '密钥: $keyMasked' : '未配置密钥',
                                style: theme.textTheme.bodySmall?.copyWith(
                                  color: keyConfigured ? Colors.green.shade700 : Colors.amber.shade800,
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),

                    // 右侧操作
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        if (!isCur)
                          TextButton(
                            onPressed: () => ws.switchModel(id),
                            child: const Text('启用'),
                          ),
                        IconButton(
                          icon: const Icon(Icons.edit_outlined, size: 18),
                          tooltip: '编辑',
                          onPressed: () => _openEditor(model: m),
                        ),
                        if (models.length > 1)
                          IconButton(
                            icon: const Icon(Icons.delete_outline, size: 18),
                            tooltip: '删除',
                            onPressed: () => _deleteModel(id, name),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            );
          }),
      ],
    );
  }

  // ─────────────────────────────────────────────────────────────────────────────
  // 视图 2: 模型添加 / 编辑表单（单列干净表单）
  // ─────────────────────────────────────────────────────────────────────────────

  Widget _buildEditorView(BuildContext context) {
    final theme = Theme.of(context);
    final isNew = _editingModelId == null;

    final currentT = _kTemplates.firstWhere(
      (item) => item.id == _selectedTemplateId,
      orElse: () => _kTemplates.first,
    );

    return ListView(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 20),
      children: [
        // 顶部返回栏
        Row(
          children: [
            IconButton(
              icon: const Icon(Icons.arrow_back),
              tooltip: '返回模型列表',
              onPressed: _cancelEditor,
            ),
            const SizedBox(width: 8),
            Text(
              isNew ? '添加新模型' : '编辑模型配置',
              style: theme.textTheme.titleMedium?.copyWith(
                fontWeight: FontWeight.bold,
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),

        // 快速预设模板下拉
        Text('从模板快速填入（可选）', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        InputDecorator(
          decoration: const InputDecoration(
            border: OutlineInputBorder(),
            contentPadding: EdgeInsets.symmetric(horizontal: 12, vertical: 4),
          ),
          child: DropdownButtonHideUnderline(
            child: DropdownButton<String>(
              value: _selectedTemplateId,
              isExpanded: true,
              items: _kTemplates.map((t) {
                return DropdownMenuItem<String>(
                  value: t.id,
                  child: Text('${t.name} — ${t.hint}'),
                );
              }).toList(),
              onChanged: (val) {
                if (val != null) {
                  setState(() {
                    _selectedTemplateId = val;
                    _applyTemplate(val);
                  });
                }
              },
            ),
          ),
        ),
        const SizedBox(height: 16),

        // 显示名称
        Text('模型显示名称', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        TextField(
          controller: _nameController,
          decoration: const InputDecoration(
            hintText: '如 DeepSeek V3、代码助手模型、自建代理',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.badge_outlined),
          ),
        ),
        const SizedBox(height: 16),

        // API Key
        Text('API Key', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        TextField(
          controller: _apiKeyController,
          obscureText: !_showApiKey,
          decoration: InputDecoration(
            hintText: isNew ? '输入 API Key (sk-...)' : '留空保持使用原有已保存密钥',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.key),
            suffixIcon: IconButton(
              icon: Icon(_showApiKey ? Icons.visibility_off : Icons.visibility, size: 20),
              onPressed: () => setState(() => _showApiKey = !_showApiKey),
            ),
          ),
        ),
        const SizedBox(height: 16),

        // Base URL
        Text('Base URL (API 端点)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        TextField(
          controller: _baseUrlController,
          decoration: const InputDecoration(
            hintText: '如 https://api.deepseek.com 或中转站地址',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.link),
          ),
        ),
        const SizedBox(height: 16),

        // Model ID
        Text('模型标识符 (Model ID)', style: theme.textTheme.titleSmall),
        const SizedBox(height: 6),
        TextField(
          controller: _modelController,
          decoration: const InputDecoration(
            hintText: '如 deepseek-chat, gpt-4o, claude-3-7-sonnet-20250219',
            border: OutlineInputBorder(),
            prefixIcon: Icon(Icons.psychology_outlined),
          ),
        ),

        // 推荐模型快捷 Chips
        if (currentT.recommendedModels.isNotEmpty) ...[
          const SizedBox(height: 8),
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Padding(
                padding: const EdgeInsets.only(top: 6.0, right: 8.0),
                child: Text(
                  '推荐:',
                  style: theme.textTheme.bodySmall?.copyWith(
                    color: theme.colorScheme.onSurface.withValues(alpha: 0.6),
                  ),
                ),
              ),
              Expanded(
                child: Wrap(
                  spacing: 6,
                  runSpacing: 4,
                  children: currentT.recommendedModels.map((m) {
                    final isCur = _modelController.text.trim() == m;
                    return ActionChip(
                      label: Text(m, style: const TextStyle(fontSize: 11)),
                      backgroundColor: isCur
                          ? theme.colorScheme.primaryContainer
                          : theme.colorScheme.surfaceContainerHighest.withValues(alpha: 0.4),
                      visualDensity: VisualDensity.compact,
                      onPressed: () => setState(() => _modelController.text = m),
                    );
                  }).toList(),
                ),
              ),
            ],
          ),
        ],
        const SizedBox(height: 16),

        // 设为当前生效模型
        CheckboxListTile(
          contentPadding: EdgeInsets.zero,
          value: _setActiveOnSave,
          title: const Text('保存后立即设为当前使用的生效模型'),
          controlAffinity: ListTileControlAffinity.leading,
          onChanged: (val) => setState(() => _setActiveOnSave = val ?? true),
        ),
        const SizedBox(height: 20),

        // 操作按钮行
        Row(
          children: [
            OutlinedButton.icon(
              onPressed: _testing ? null : _testConnection,
              icon: _testing
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.network_check, size: 16),
              label: Text(_testing ? '正在测试...' : '测试连接'),
            ),
            const SizedBox(width: 12),
            FilledButton.icon(
              onPressed: _saving ? null : _saveModel,
              icon: _saving
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white),
                    )
                  : const Icon(Icons.check, size: 16),
              label: Text(_saving ? '保存中...' : '保存模型'),
            ),
            const SizedBox(width: 12),
            TextButton(
              onPressed: _cancelEditor,
              child: const Text('取消'),
            ),
          ],
        ),

        // 测试结果卡片
        if (_testResult != null) ...[
          const SizedBox(height: 16),
          _buildTestCard(context),
        ],
      ],
    );
  }

  Widget _buildTestCard(BuildContext context) {
    final status = _testResult?['status'] as String? ?? 'error';
    final isSuccess = status == 'success';
    final latency = _testResult?['latency_ms'] ?? 0;
    final message = _testResult?['message'] as String? ?? '';
    final preview = _testResult?['reply_preview'] as String? ?? '';

    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: isSuccess
            ? Colors.green.withValues(alpha: 0.12)
            : Colors.red.withValues(alpha: 0.12),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: isSuccess
              ? Colors.green.withValues(alpha: 0.4)
              : Colors.red.withValues(alpha: 0.4),
        ),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Icon(
            isSuccess ? Icons.check_circle_outline : Icons.error_outline,
            color: isSuccess ? Colors.green : Colors.red,
            size: 20,
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Text(
                      isSuccess ? '连接成功' : '连接失败',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 13,
                        color: isSuccess ? Colors.green : Colors.redAccent,
                      ),
                    ),
                    if (isSuccess && latency is num && latency > 0) ...[
                      const SizedBox(width: 8),
                      Container(
                        padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 1),
                        decoration: BoxDecoration(
                          color: Colors.green.withValues(alpha: 0.2),
                          borderRadius: BorderRadius.circular(4),
                        ),
                        child: Text(
                          '${latency}ms',
                          style: const TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.bold,
                            color: Colors.green,
                          ),
                        ),
                      ),
                    ],
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: 12,
                    color: isSuccess ? Colors.green.shade200 : Colors.red.shade200,
                  ),
                ),
                if (preview.isNotEmpty) ...[
                  const SizedBox(height: 4),
                  Text(
                    '模型回显预览: "$preview"',
                    style: TextStyle(
                      fontSize: 11,
                      fontStyle: FontStyle.italic,
                      color: isSuccess ? Colors.green.shade300 : Colors.red.shade300,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}
