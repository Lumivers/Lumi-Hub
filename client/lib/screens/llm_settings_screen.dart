import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/ws_service.dart';

/// LLM 配置页面 — 通过 WebSocket 直接配置 Host。
class LlmSettingsScreen extends StatefulWidget {
  final bool embedded;

  const LlmSettingsScreen({super.key, this.embedded = false});

  @override
  State<LlmSettingsScreen> createState() => _LlmSettingsScreenState();
}

class _LlmSettingsScreenState extends State<LlmSettingsScreen> {
  String _provider = 'openai';
  final _apiKeyController = TextEditingController();
  final _baseUrlController = TextEditingController();
  final _modelController = TextEditingController();
  bool _loading = true;
  bool _saving = false;
  bool _apiKeyConfigured = false;
  String _apiKeyMasked = '';

  @override
  void initState() {
    super.initState();
    _loadConfig();
  }

  @override
  void dispose() {
    _apiKeyController.dispose();
    _baseUrlController.dispose();
    _modelController.dispose();
    super.dispose();
  }

  Future<void> _loadConfig() async {
    final ws = context.read<WsService>();
    final resp = await ws.sendRequest('LLM_CONFIG_GET', {});
    if (!mounted) return;

    if (resp != null) {
      final config = resp['payload']?['config'] as Map<String, dynamic>? ?? {};
      setState(() {
        _provider = config['provider'] ?? 'openai';
        _modelController.text = config['model'] ?? '';
        _baseUrlController.text = config['base_url'] ?? '';
        _apiKeyConfigured = config['api_key_configured'] ?? false;
        _apiKeyMasked = config['api_key_masked'] ?? '';
        _loading = false;
      });
    } else {
      setState(() => _loading = false);
    }
  }

  Future<void> _save() async {
    setState(() => _saving = true);
    final ws = context.read<WsService>();

    final config = <String, dynamic>{
      'provider': _provider,
      'model': _modelController.text.trim(),
      'base_url': _baseUrlController.text.trim(),
    };

    // 只有用户输入了新 key 才更新
    final newKey = _apiKeyController.text.trim();
    if (newKey.isNotEmpty) {
      config['api_key'] = newKey;
    }

    final resp = await ws.sendRequest('LLM_CONFIG_SET', {'config': config});
    if (!mounted) return;

    setState(() => _saving = false);

    final success = resp?['payload']?['status'] == 'success';
    if (success) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('配置已保存')),
      );
      _apiKeyController.clear();
      _loadConfig(); // 刷新掩码
    } else {
      final msg = resp?['payload']?['message'] ?? '保存失败';
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('错误: $msg'), backgroundColor: Colors.red),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return Scaffold(
        appBar: widget.embedded ? null : AppBar(title: const Text('LLM 设置')),
        body: const Center(child: CircularProgressIndicator()),
      );
    }

    final body = ListView(
      padding: const EdgeInsets.all(24),
      children: [
        // Provider 选择
        Text('AI 服务商', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        SegmentedButton<String>(
          segments: const [
            ButtonSegment(value: 'openai', label: Text('OpenAI'), icon: Icon(Icons.auto_awesome)),
            ButtonSegment(value: 'anthropic', label: Text('Anthropic'), icon: Icon(Icons.psychology)),
            ButtonSegment(value: 'ollama', label: Text('Ollama'), icon: Icon(Icons.computer)),
          ],
          selected: {_provider},
          onSelectionChanged: (v) => setState(() => _provider = v.first),
        ),
        const SizedBox(height: 24),

        // API Key
        Text('API Key', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _apiKeyController,
          obscureText: true,
          decoration: InputDecoration(
            hintText: _apiKeyConfigured ? '已配置 ($_apiKeyMasked)，留空不修改' : '输入 API Key',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.key),
          ),
        ),
        const SizedBox(height: 24),

        // Base URL
        Text('Base URL（可选）', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _baseUrlController,
          decoration: InputDecoration(
            hintText: _provider == 'ollama'
                ? 'http://localhost:11434/v1'
                : '留空使用默认端点',
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.link),
          ),
        ),
        const SizedBox(height: 24),

        // Model
        Text('Model 名称', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        TextField(
          controller: _modelController,
          decoration: InputDecoration(
            hintText: _defaultModelForProvider(_provider),
            border: const OutlineInputBorder(),
            prefixIcon: const Icon(Icons.psychology_outlined),
          ),
        ),
        const SizedBox(height: 24),

        // 提示卡片
        Card(
          color: Theme.of(context).colorScheme.surfaceContainerHighest.withValues(alpha: 0.3),
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Icon(Icons.info_outline, size: 20, color: Theme.of(context).colorScheme.primary),
                const SizedBox(width: 12),
                Expanded(
                  child: Text(
                    _providerHint(_provider),
                    style: Theme.of(context).textTheme.bodySmall,
                  ),
                ),
              ],
            ),
          ),
        ),

        if (widget.embedded) ...[
          const SizedBox(height: 24),
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                : const Icon(Icons.save),
            label: const Text('保存并热重载'),
          ),
        ],
      ],
    );

    if (widget.embedded) {
      return body;
    }

    return Scaffold(
      appBar: AppBar(
        title: const Text('LLM 设置'),
        actions: [
          FilledButton.icon(
            onPressed: _saving ? null : _save,
            icon: _saving
                ? const SizedBox(width: 16, height: 16, child: CircularProgressIndicator(strokeWidth: 2))
                : const Icon(Icons.save),
            label: const Text('保存'),
          ),
          const SizedBox(width: 8),
        ],
      ),
      body: body,
    );
  }

  String _defaultModelForProvider(String provider) {
    switch (provider) {
      case 'anthropic':
        return 'claude-sonnet-4-20250514';
      case 'ollama':
        return 'qwen2.5:latest';
      default:
        return 'gpt-4o';
    }
  }

  String _providerHint(String provider) {
    switch (provider) {
      case 'openai':
        return '支持 OpenAI 官方 API 及所有兼容接口（Deepseek、Moonshot、vLLM 等）。填写 API Key 即可，如有自定义端点请填写 Base URL。';
      case 'anthropic':
        return '支持 Claude 系列模型。需要 Anthropic API Key。';
      case 'ollama':
        return '使用本地 Ollama 服务。无需 API Key，确保 Ollama 已运行并拉取了模型。Base URL 默认 http://localhost:11434/v1。';
      default:
        return '';
    }
  }
}
