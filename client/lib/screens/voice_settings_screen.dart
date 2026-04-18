import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/app_settings.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';

class VoiceSettingsScreen extends StatefulWidget {
  const VoiceSettingsScreen({super.key, this.showAsDialog = false});

  final bool showAsDialog;

  @override
  State<VoiceSettingsScreen> createState() => _VoiceSettingsScreenState();
}

class _VoiceSettingsScreenState extends State<VoiceSettingsScreen> {
  final TextEditingController _voiceIdController = TextEditingController();
  final TextEditingController _apiKeyController = TextEditingController();

  StreamSubscription<Map<String, dynamic>>? _voiceSub;

  bool _loading = true;
  bool _saving = false;
  bool _apiConfigured = false;
  String _apiSource = 'missing';
  String _apiMasked = '';
  bool _obscureApiKey = true;

  @override
  void initState() {
    super.initState();
    final ws = context.read<WsService>();
    final settings = context.read<AppSettings>();

    _voiceIdController.text = settings.ttsVoiceId;
    _voiceSub = ws.voiceEvents.listen(_handleVoiceEvent);

    // 仅在已连接且已登录时拉取 Host 端语音配置。
    if (ws.status == WsStatus.connected && ws.isAuthenticated) {
      ws.getVoiceConfig();
    } else {
      _loading = false;
    }
  }

  void _handleVoiceEvent(Map<String, dynamic> event) {
    if (!mounted) return;
    final type = event['type'] as String? ?? '';
    if (type != 'VOICE_CONFIG_RESPONSE' &&
        type != 'VOICE_CONFIG_SET_RESPONSE') {
      return;
    }

    final payload = event['payload'] as Map<String, dynamic>? ?? {};
    final status = payload['status'] as String? ?? 'error';

    if (status != 'success') {
      setState(() {
        _loading = false;
        _saving = false;
      });
      _showSnack('语音配置读取/保存失败: ${payload['message'] ?? '未知错误'}', isError: true);
      return;
    }

    // 以 Host 回包为准回填 UI，保证前后端配置一致。
    final config = payload['config'] as Map<String, dynamic>? ?? {};
    final voiceId = (config['voice_id'] as String? ?? '').trim();
    final source = (config['api_key_source'] as String? ?? 'missing').trim();
    final masked = (config['api_key_masked'] as String? ?? '').trim();
    final configured = config['api_key_configured'] == true;

    if (voiceId.isNotEmpty && _voiceIdController.text.trim() != voiceId) {
      _voiceIdController.text = voiceId;
      context.read<AppSettings>().setTtsVoiceId(voiceId);
    }

    setState(() {
      _loading = false;
      _saving = false;
      _apiConfigured = configured;
      _apiSource = source;
      _apiMasked = masked;
    });

    if (type == 'VOICE_CONFIG_SET_RESPONSE') {
      _apiKeyController.clear();
      _showSnack('语音配置已保存');
    }
  }

  Future<void> _refreshConfig() async {
    final ws = context.read<WsService>();
    if (ws.status != WsStatus.connected || !ws.isAuthenticated) {
      _showSnack('当前未连接或未登录，无法读取语音配置', isError: true);
      return;
    }

    setState(() => _loading = true);
    ws.getVoiceConfig();
  }

  void _saveConfig() {
    final ws = context.read<WsService>();
    final settings = context.read<AppSettings>();
    if (ws.status != WsStatus.connected || !ws.isAuthenticated) {
      _showSnack('当前未连接或未登录，无法保存语音配置', isError: true);
      return;
    }

    final voiceId = _voiceIdController.text.trim();
    final apiKey = _apiKeyController.text.trim();

    // 本地偏好先落盘，再请求 Host 更新运行时配置。
    settings.setTtsVoiceId(voiceId);
    setState(() => _saving = true);
    ws.setVoiceConfig(voiceId: voiceId, apiKey: apiKey);
  }

  void _clearApiKey() {
    final ws = context.read<WsService>();
    if (ws.status != WsStatus.connected || !ws.isAuthenticated) {
      _showSnack('当前未连接或未登录，无法清除 API Key', isError: true);
      return;
    }

    setState(() => _saving = true);
    ws.setVoiceConfig(
      voiceId: _voiceIdController.text.trim(),
      clearApiKey: true,
    );
  }

  void _showSnack(String message, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError ? Colors.redAccent : null,
      ),
    );
  }

  @override
  void dispose() {
    _voiceSub?.cancel();
    _voiceIdController.dispose();
    _apiKeyController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>()!;
    final settings = context.watch<AppSettings>();
    final baseBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: colors.divider.withValues(alpha: 0.6)),
    );
    final focusedBorder = OutlineInputBorder(
      borderRadius: BorderRadius.circular(10),
      borderSide: BorderSide(color: colors.accent, width: 1.4),
    );

    // 单一滚动区域复用页面/弹窗两种承载方式。
    final body = ListView(
      padding: const EdgeInsets.all(16),
      children: [
        Container(
          decoration: BoxDecoration(
            color: colors.inputBg,
            borderRadius: BorderRadius.circular(12),
            border: Border.all(color: colors.divider.withValues(alpha: 0.2)),
          ),
          child: Column(
            children: [
              SwitchListTile(
                value: settings.enableAiVoiceOutput,
                onChanged: settings.setEnableAiVoiceOutput,
                title: const Text('启用 AI 回复语音转换'),
                subtitle: const Text('先显示文字，再在后台转语音，完成后显示朗读按钮'),
              ),
              Divider(height: 1, color: colors.divider.withValues(alpha: 0.2)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.record_voice_over_outlined,
                          color: colors.subtext,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          '默认 voice_id',
                          style: TextStyle(
                            fontSize: 18,
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _voiceIdController,
                      decoration: InputDecoration(
                        hintText:
                            '输入 voice_id，例如 cosyvoice-v3.5-plus-firefly-xxxx',
                        filled: true,
                        fillColor: colors.sidebar,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        enabledBorder: baseBorder,
                        border: baseBorder,
                        focusedBorder: focusedBorder,
                      ),
                      onChanged: (v) =>
                          context.read<AppSettings>().setTtsVoiceId(v),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '保存后将应用到 Host，后续语音生成会使用这个 voice_id',
                      style: TextStyle(color: colors.subtext, fontSize: 12),
                    ),
                  ],
                ),
              ),
              Divider(height: 1, color: colors.divider.withValues(alpha: 0.2)),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 14),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(
                          Icons.key_outlined,
                          color: colors.subtext,
                          size: 20,
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'DashScope API Key',
                          style: TextStyle(
                            fontSize: 18,
                            color: Theme.of(context).colorScheme.onSurface,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 10),
                    TextField(
                      controller: _apiKeyController,
                      obscureText: _obscureApiKey,
                      decoration: InputDecoration(
                        hintText: '输入新的 API Key，保存后覆盖',
                        filled: true,
                        fillColor: colors.sidebar,
                        isDense: true,
                        contentPadding: const EdgeInsets.symmetric(
                          horizontal: 12,
                          vertical: 12,
                        ),
                        enabledBorder: baseBorder,
                        border: baseBorder,
                        focusedBorder: focusedBorder,
                        suffixIcon: IconButton(
                          tooltip: _obscureApiKey ? '显示' : '隐藏',
                          onPressed: () {
                            setState(() {
                              _obscureApiKey = !_obscureApiKey;
                            });
                          },
                          icon: Icon(
                            _obscureApiKey
                                ? Icons.visibility_outlined
                                : Icons.visibility_off_outlined,
                            size: 18,
                          ),
                        ),
                      ),
                    ),
                    const SizedBox(height: 6),
                    Text(
                      '留空表示不更新，点击“保存并应用到 Host”后生效',
                      style: TextStyle(color: colors.subtext, fontSize: 12),
                    ),
                    const SizedBox(height: 6),
                    if (_apiConfigured)
                      Text(
                        '当前状态: 已配置 (${_apiSource.isEmpty ? 'unknown' : _apiSource}) ${_apiMasked.isNotEmpty ? _apiMasked : ''}',
                        style: TextStyle(color: colors.subtext, fontSize: 12),
                      )
                    else
                      Text(
                        '当前状态: 未配置',
                        style: TextStyle(color: colors.subtext, fontSize: 12),
                      ),
                  ],
                ),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                onPressed: (_loading || _saving) ? null : _refreshConfig,
                icon: const Icon(Icons.refresh),
                label: const Text('刷新配置'),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: OutlinedButton.icon(
                onPressed: _saving ? null : _clearApiKey,
                icon: const Icon(Icons.delete_outline),
                label: const Text('清空 Key'),
              ),
            ),
          ],
        ),
        const SizedBox(height: 10),
        SizedBox(
          height: 44,
          child: FilledButton.icon(
            onPressed: (_loading || _saving) ? null : _saveConfig,
            icon: _saving
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(Icons.save_outlined),
            label: Text(_saving ? '保存中...' : '保存并应用到 Host'),
          ),
        ),
        if (_loading)
          const Padding(
            padding: EdgeInsets.only(top: 16),
            child: Center(child: CircularProgressIndicator()),
          ),
      ],
    );

    if (widget.showAsDialog) {
      final size = MediaQuery.of(context).size;
      final maxWidth = size.width > 980 ? 980.0 : size.width - 24;
      final maxHeight = size.height > 760 ? 760.0 : size.height - 24;
      return Dialog(
        insetPadding: const EdgeInsets.all(12),
        backgroundColor: Colors.transparent,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxWidth, maxHeight: maxHeight),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(14),
            child: Material(
              color: Theme.of(context).scaffoldBackgroundColor,
              child: Column(
                children: [
                  Container(
                    height: 56,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    color: colors.sidebar,
                    child: Row(
                      children: [
                        Text(
                          '语音输出设置',
                          style: TextStyle(
                            fontSize: 20,
                            fontWeight: FontWeight.w700,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        const Spacer(),
                        IconButton(
                          onPressed: () => Navigator.of(context).pop(),
                          icon: const Icon(Icons.close),
                          tooltip: '关闭',
                        ),
                      ],
                    ),
                  ),
                  Expanded(child: body),
                ],
              ),
            ),
          ),
        ),
      );
    }

    return Scaffold(
      backgroundColor: Theme.of(context).scaffoldBackgroundColor,
      appBar: AppBar(
        backgroundColor: colors.sidebar,
        title: const Text('语音输出设置'),
      ),
      body: body,
    );
  }
}
