import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

import 'components/connection_settings_dialog.dart';
import '../services/app_settings.dart';
import '../services/bootstrap_service.dart';
import '../services/ws_service.dart';

/// Lumi-Hub 2.0 首次启动引导向导。
///
/// 三步流程：LLM 配置 → 注册/登录 → 完成（含连接信息）。
/// 老用户（setupCompleted = true）不会进入此页面。
class SetupWizardScreen extends StatefulWidget {
  const SetupWizardScreen({super.key});

  @override
  State<SetupWizardScreen> createState() => _SetupWizardScreenState();
}

class _SetupWizardScreenState extends State<SetupWizardScreen> {
  final _pageController = PageController();
  int _currentStep = 0;
  bool _bootTriggered = false;

  // ── Step 1: LLM 配置 ──
  String _provider = 'openai';
  final _apiKeyCtrl = TextEditingController();
  final _baseUrlCtrl = TextEditingController();
  final _modelCtrl = TextEditingController();
  bool _savingLlm = false;

  // ── Step 2: 账号 ──
  final _usernameCtrl = TextEditingController();
  final _passwordCtrl = TextEditingController();
  bool _isLoginMode = false; // 新用户默认注册
  bool _submittingAuth = false;

  // ── Step 3: 完成 ──
  String _lanIp = '';
  String _publicIp = '';
  bool _detectingNetwork = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _startBootstrap();
    });
  }

  @override
  void dispose() {
    _pageController.dispose();
    _apiKeyCtrl.dispose();
    _baseUrlCtrl.dispose();
    _modelCtrl.dispose();
    _usernameCtrl.dispose();
    _passwordCtrl.dispose();
    super.dispose();
  }

  /// 后台触发 WebSocket 连接（不阻塞 UI）。
  Future<void> _startBootstrap() async {
    if (_bootTriggered || !mounted) return;
    _bootTriggered = true;

    final settings = context.read<AppSettings>();
    await settings.loaded;
    if (!mounted) return;

    await context.read<BootstrapService>().ensureStarted();
  }

  void _goToStep(int step) {
    _pageController.animateToPage(
      step,
      duration: const Duration(milliseconds: 400),
      curve: Curves.easeInOut,
    );
    setState(() => _currentStep = step);
  }

  // ── Step 1: 保存 LLM 配置 ──

  Future<void> _saveLlmConfig() async {
    setState(() => _savingLlm = true);
    final ws = context.read<WsService>();

    final config = <String, dynamic>{
      'provider': _provider,
      'model': _modelCtrl.text.trim(),
      'base_url': _baseUrlCtrl.text.trim(),
    };

    final newKey = _apiKeyCtrl.text.trim();
    if (newKey.isNotEmpty) {
      config['api_key'] = newKey;
    } else if (_provider != 'ollama') {
      setState(() => _savingLlm = false);
      _showSnack('请输入 API Key', isError: true);
      return;
    }

    final resp = await ws.sendRequest('LLM_CONFIG_SET', {'config': config});
    if (!mounted) return;
    setState(() => _savingLlm = false);

    final success = resp?['payload']?['status'] == 'success';
    if (success) {
      // 刷新 bootstrap 状态
      await context.read<BootstrapService>().refreshLlmStatus();
      if (mounted) _goToStep(1);
    } else {
      final msg = resp?['payload']?['message'] ?? '配置保存失败';
      _showSnack('错误: $msg', isError: true);
    }
  }

  // ── Step 2: 注册/登录 ──

  Future<void> _submitAuth() async {
    final username = _usernameCtrl.text.trim();
    final password = _passwordCtrl.text.trim();
    if (username.isEmpty || password.isEmpty) {
      _showSnack('用户名和密码不能为空', isError: true);
      return;
    }

    setState(() => _submittingAuth = true);
    final ws = context.read<WsService>();

    if (_isLoginMode) {
      ws.login(username, password);
    } else {
      ws.register(username, password);
    }

    // 等待认证结果（最多 10 秒）
    final success = await _waitForAuth(const Duration(seconds: 10));
    if (!mounted) return;
    setState(() => _submittingAuth = false);

    if (success) {
      // 检测网络信息供 Step 3 使用
      _detectNetworkInfo();
      _goToStep(2);
    } else {
      _showSnack(_isLoginMode ? '登录失败，请检查用户名和密码' : '注册失败，用户名可能已存在',
          isError: true);
    }
  }

  Future<bool> _waitForAuth(Duration timeout) async {
    final ws = context.read<WsService>();
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      if (ws.isAuthenticated) return true;
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  // ── Step 3: 网络检测 ──

  Future<void> _detectNetworkInfo() async {
    setState(() => _detectingNetwork = true);

    // 检测局域网 IP
    try {
      final interfaces = await NetworkInterface.list(
        type: InternetAddressType.IPv4,
        includeLoopback: false,
      );
      for (final iface in interfaces) {
        for (final addr in iface.addresses) {
          final ip = addr.address;
          if (ip.startsWith('192.168.') ||
              ip.startsWith('10.') ||
              ip.startsWith('172.')) {
            _lanIp = ip;
            break;
          }
        }
        if (_lanIp.isNotEmpty) break;
      }
    } catch (_) {}

    // 检测公网 IP
    try {
      final client = HttpClient();
      client.connectionTimeout = const Duration(seconds: 3);
      final request = await client.getUrl(Uri.parse('https://api.ipify.org'));
      final response = await request.close();
      final body = await response.transform(const SystemEncoding().decoder).join();
      if (body.isNotEmpty && body.contains('.')) {
        _publicIp = body.trim();
      }
      client.close();
    } catch (_) {}

    if (mounted) setState(() => _detectingNetwork = false);
  }

  // ── Step 3: 完成向导 ──

  Future<void> _finishSetup() async {
    await context.read<BootstrapService>().markSetupCompleted();
  }

  void _showSnack(String text, {bool isError = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(text),
        backgroundColor: isError ? Colors.red.shade700 : null,
      ),
    );
  }

  void _copyToClipboard(String text) {
    Clipboard.setData(ClipboardData(text: text));
    _showSnack('已复制到剪贴板');
  }

  // ── 构建 UI ──

  @override
  Widget build(BuildContext context) {
    final bootstrap = context.watch<BootstrapService>();

    return Scaffold(
      body: Center(
        child: Container(
          width: 520,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              _buildStepIndicator(),
              const SizedBox(height: 28),
              Flexible(
                child: PageView(
                  controller: _pageController,
                  physics: const NeverScrollableScrollPhysics(),
                  children: [
                    _buildStep1LlmConfig(bootstrap),
                    _buildStep2Auth(bootstrap),
                    _buildStep3Complete(bootstrap),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }

  // ── 步骤指示器 ──

  Widget _buildStepIndicator() {
    const labels = ['AI 配置', '账号', '完成'];
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: List.generate(labels.length, (i) {
        final isActive = i == _currentStep;
        final isDone = i < _currentStep;
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (i > 0)
              Container(
                width: 48,
                height: 2,
                color: isDone
                    ? Theme.of(context).colorScheme.primary
                    : Theme.of(context).dividerColor,
              ),
            Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                AnimatedContainer(
                  duration: const Duration(milliseconds: 300),
                  width: 32,
                  height: 32,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: isDone || isActive
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context).colorScheme.surfaceContainerHighest,
                  ),
                  child: Center(
                    child: isDone
                        ? const Icon(Icons.check, size: 18, color: Colors.white)
                        : Text(
                            '${i + 1}',
                            style: TextStyle(
                              fontWeight: FontWeight.bold,
                              color: isActive
                                  ? Colors.white
                                  : Theme.of(context).colorScheme.onSurface,
                            ),
                          ),
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  labels[i],
                  style: TextStyle(
                    fontSize: 12,
                    fontWeight: isActive ? FontWeight.bold : FontWeight.normal,
                    color: isActive
                        ? Theme.of(context).colorScheme.primary
                        : Theme.of(context)
                            .colorScheme
                            .onSurface
                            .withValues(alpha: 0.6),
                  ),
                ),
              ],
            ),
          ],
        );
      }),
    );
  }

  // ── Step 1: LLM 配置 ──

  Widget _buildStep1LlmConfig(BootstrapService bootstrap) {
    final connected = bootstrap.isReady;
    final isOllama = _provider == 'ollama';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.auto_awesome,
                  color: Theme.of(context).colorScheme.primary, size: 28),
              const SizedBox(width: 12),
              Text(
                '欢迎使用 Lumi-Hub',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '选择你的 AI 服务商，配置 API 即可开始。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7),
                ),
          ),
          const SizedBox(height: 24),

          // Provider 选择
          Text('AI 服务商', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          SegmentedButton<String>(
            segments: const [
              ButtonSegment(
                  value: 'openai',
                  label: Text('OpenAI'),
                  icon: Icon(Icons.auto_awesome)),
              ButtonSegment(
                  value: 'anthropic',
                  label: Text('Anthropic'),
                  icon: Icon(Icons.psychology)),
              ButtonSegment(
                  value: 'ollama',
                  label: Text('Ollama'),
                  icon: Icon(Icons.computer)),
            ],
            selected: {_provider},
            onSelectionChanged: (v) => setState(() => _provider = v.first),
          ),
          const SizedBox(height: 20),

          // API Key（Ollama 隐藏）
          if (!isOllama) ...[
            Text('API Key', style: Theme.of(context).textTheme.titleSmall),
            const SizedBox(height: 8),
            TextField(
              controller: _apiKeyCtrl,
              obscureText: true,
              decoration: InputDecoration(
                hintText: '输入 API Key',
                border: const OutlineInputBorder(),
                prefixIcon: const Icon(Icons.key),
                helperText: _provider == 'openai'
                    ? '支持 OpenAI 官方及兼容接口（Deepseek、Moonshot 等）'
                    : '需要 Anthropic API Key',
              ),
            ),
            const SizedBox(height: 20),
          ],

          // Base URL
          Text(isOllama ? 'Ollama 地址' : 'Base URL（可选）',
              style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _baseUrlCtrl,
            decoration: InputDecoration(
              hintText: isOllama
                  ? 'http://localhost:11434/v1'
                  : '留空使用默认端点',
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.link),
            ),
          ),
          const SizedBox(height: 20),

          // Model
          Text('模型', style: Theme.of(context).textTheme.titleSmall),
          const SizedBox(height: 8),
          TextField(
            controller: _modelCtrl,
            decoration: InputDecoration(
              hintText: _defaultModel(_provider),
              border: const OutlineInputBorder(),
              prefixIcon: const Icon(Icons.smart_toy),
              helperText: '留空使用默认模型',
            ),
          ),
          const SizedBox(height: 28),

          // 连接状态 & 下一步
          if (!connected)
            Container(
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                color: Theme.of(context).colorScheme.errorContainer,
                borderRadius: BorderRadius.circular(8),
              ),
              child: Row(
                children: [
                  Icon(Icons.warning_amber,
                      color: Theme.of(context).colorScheme.onErrorContainer,
                      size: 20),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      bootstrap.hasFailed
                          ? '无法连接到 Host，请确认 Host 已启动'
                          : '正在连接 Host...',
                      style: TextStyle(
                          color: Theme.of(context).colorScheme.onErrorContainer),
                    ),
                  ),
                  if (bootstrap.hasFailed)
                    TextButton(
                      onPressed: bootstrap.retry,
                      child: const Text('重试'),
                    ),
                ],
              ),
            ),

          if (!connected) ...[
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: TextButton.icon(
                onPressed: () {
                  final ws = context.read<WsService>();
                  final settings = context.read<AppSettings>();
                  ConnectionSettingsDialog.show(
                    context,
                    ws: ws,
                    settings: settings,
                    title: '连接设置',
                    confirmText: '保存并重连',
                    reconnectIfConnected: true,
                  );
                },
                icon: const Icon(Icons.settings_ethernet, size: 16),
                label: const Text('修改服务器地址'),
              ),
            ),
          ],

          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              FilledButton.icon(
                onPressed: connected && !_savingLlm ? _saveLlmConfig : null,
                icon: _savingLlm
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.arrow_forward),
                label: const Text('下一步'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Step 2: 注册/登录 ──

  Widget _buildStep2Auth(BootstrapService bootstrap) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.person_add,
                  color: Theme.of(context).colorScheme.primary, size: 28),
              const SizedBox(width: 12),
              Text(
                _isLoginMode ? '欢迎回来' : '创建你的账号',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            _isLoginMode ? '使用已有的用户名和密码登录。' : '为你的 Lumi-Hub 创建一个本地账号。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7),
                ),
          ),
          const SizedBox(height: 32),

          // 用户名
          TextField(
            controller: _usernameCtrl,
            decoration: const InputDecoration(
              labelText: '用户名',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person),
            ),
            textInputAction: TextInputAction.next,
          ),
          const SizedBox(height: 16),

          // 密码
          TextField(
            controller: _passwordCtrl,
            obscureText: true,
            decoration: const InputDecoration(
              labelText: '密码',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.lock),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submitAuth(),
          ),
          const SizedBox(height: 12),

          // 切换登录/注册
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton(
              onPressed: () => setState(() => _isLoginMode = !_isLoginMode),
              child: Text(_isLoginMode ? '没有账号？点击注册' : '已有账号？点击登录'),
            ),
          ),

          const SizedBox(height: 28),

          // 按钮行
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              OutlinedButton.icon(
                onPressed: () => _goToStep(0),
                icon: const Icon(Icons.arrow_back),
                label: const Text('上一步'),
              ),
              FilledButton.icon(
                onPressed: _submittingAuth ? null : _submitAuth,
                icon: _submittingAuth
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.arrow_forward),
                label: Text(_isLoginMode ? '登录' : '注册并继续'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Step 3: 完成 ──

  Widget _buildStep3Complete(BootstrapService bootstrap) {
    final port = '8765'; // 默认端口
    final adbAddr = 'ws://127.0.0.1:$port';
    final lanAddr = _lanIp.isNotEmpty ? 'ws://$_lanIp:$port' : '';
    final publicAddr = _publicIp.isNotEmpty ? 'ws://$_publicIp:$port' : '';

    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          const SizedBox(height: 8),
          Center(
            child: Icon(
              Icons.celebration,
              size: 56,
              color: Theme.of(context).colorScheme.primary,
            ),
          ),
          const SizedBox(height: 16),
          Center(
            child: Text(
              '一切就绪！',
              style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                    fontWeight: FontWeight.bold,
                  ),
            ),
          ),
          const SizedBox(height: 24),

          // 配置摘要
          _summaryTile(
            icon: Icons.smart_toy,
            label: 'AI',
            value: '${bootstrap.llmProvider} (${bootstrap.llmModel.isNotEmpty ? bootstrap.llmModel : _defaultModel(bootstrap.llmProvider)})',
          ),
          const SizedBox(height: 8),
          _summaryTile(
            icon: Icons.person,
            label: '账号',
            value: _usernameCtrl.text.trim(),
          ),

          const SizedBox(height: 24),

          // 手机连接方式
          Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: Theme.of(context).colorScheme.surfaceContainerHighest,
              borderRadius: BorderRadius.circular(12),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Icon(Icons.phone_android,
                        size: 20,
                        color: Theme.of(context).colorScheme.primary),
                    const SizedBox(width: 8),
                    Text('手机连接方式',
                        style: Theme.of(context).textTheme.titleSmall?.copyWith(
                              fontWeight: FontWeight.bold,
                            )),
                  ],
                ),
                const SizedBox(height: 12),

                // ADB 转发
                _connectionRow(
                  emoji: '📱',
                  label: 'ADB 转发',
                  address: adbAddr,
                  hint: '需执行 adb forward tcp:$port tcp:$port',
                ),
                const SizedBox(height: 8),

                // 局域网
                _connectionRow(
                  emoji: '🏠',
                  label: '局域网',
                  address: lanAddr.isNotEmpty ? lanAddr : null,
                  hint: _detectingNetwork ? '正在检测...' : '未检测到局域网 IP',
                ),
                const SizedBox(height: 8),

                // 公网
                _connectionRow(
                  emoji: '🌐',
                  label: '公网',
                  address: publicAddr.isNotEmpty ? publicAddr : null,
                  hint: _detectingNetwork ? '正在检测...' : '未检测到公网 IP',
                ),
              ],
            ),
          ),

          const SizedBox(height: 28),

          // 开始对话
          Center(
            child: FilledButton.icon(
              onPressed: _finishSetup,
              icon: const Icon(Icons.chat_bubble_outline),
              label: const Text('开始对话'),
              style: FilledButton.styleFrom(
                padding:
                    const EdgeInsets.symmetric(horizontal: 32, vertical: 16),
                textStyle: const TextStyle(fontSize: 16),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _summaryTile({
    required IconData icon,
    required String label,
    required String value,
  }) {
    return Row(
      children: [
        Icon(icon, size: 20, color: Theme.of(context).colorScheme.primary),
        const SizedBox(width: 12),
        Text('$label: ',
            style: Theme.of(context)
                .textTheme
                .bodyMedium
                ?.copyWith(fontWeight: FontWeight.w600)),
        Expanded(
          child: Text(value, style: Theme.of(context).textTheme.bodyMedium),
        ),
        Icon(Icons.check_circle,
            size: 20, color: Colors.green.shade400),
      ],
    );
  }

  Widget _connectionRow({
    required String emoji,
    required String label,
    String? address,
    String? hint,
  }) {
    final hasAddress = address != null && address.isNotEmpty;
    return Row(
      children: [
        Text(emoji, style: const TextStyle(fontSize: 16)),
        const SizedBox(width: 8),
        SizedBox(
          width: 64,
          child: Text(label,
              style: Theme.of(context).textTheme.bodySmall?.copyWith(
                    fontWeight: FontWeight.w600,
                  )),
        ),
        Expanded(
          child: Text(
            hasAddress ? address : (hint ?? ''),
            style: Theme.of(context).textTheme.bodySmall?.copyWith(
                  fontFamily: hasAddress ? 'monospace' : null,
                  color: hasAddress
                      ? Theme.of(context).colorScheme.onSurface
                      : Theme.of(context)
                          .colorScheme
                          .onSurface
                          .withValues(alpha: 0.5),
                ),
          ),
        ),
        if (hasAddress)
          IconButton(
            icon: const Icon(Icons.copy, size: 16),
            onPressed: () => _copyToClipboard(address),
            tooltip: '复制',
            visualDensity: VisualDensity.compact,
          ),
      ],
    );
  }

  String _defaultModel(String provider) {
    switch (provider) {
      case 'anthropic':
        return 'claude-sonnet-4-20250514';
      case 'ollama':
        return 'qwen2.5:latest';
      default:
        return 'gpt-4o';
    }
  }
}

// ─────────────────────────────────────────────────────────────────────
// BootstrapScreen — 老用户简洁等待页
// ─────────────────────────────────────────────────────────────────────

/// 老用户启动时的简洁等待页面。
///
/// 只显示连接进度和错误提示，不走完整向导流程。
class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({super.key});

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  bool _bootTriggered = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _prepareAndStart();
    });
  }

  Future<void> _prepareAndStart() async {
    if (_bootTriggered || !mounted) return;
    _bootTriggered = true;

    final settings = context.read<AppSettings>();
    await settings.loaded;
    if (!mounted) return;

    if (settings.askConnectionModeOnLaunch) {
      await ConnectionSettingsDialog.show(
        context,
        ws: context.read<WsService>(),
        settings: settings,
        title: '选择连接方式',
        confirmText: '确认并继续',
        barrierDismissible: false,
        allowCancel: false,
      );
    }

    if (!mounted) return;
    await context.read<BootstrapService>().ensureStarted();
  }

  @override
  Widget build(BuildContext context) {
    final bootstrap = context.watch<BootstrapService>();

    return Scaffold(
      body: Center(
        child: Container(
          width: 400,
          padding: const EdgeInsets.all(32),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              CircleAvatar(
                radius: 32,
                backgroundColor: Theme.of(context).colorScheme.primary,
                child:
                    const Icon(Icons.rocket_launch, color: Colors.white, size: 28),
              ),
              const SizedBox(height: 20),
              Text(
                'Lumi-Hub',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
              const SizedBox(height: 8),
              Text(
                _stageLabel(bootstrap.stage),
                style: TextStyle(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7),
                ),
              ),
              const SizedBox(height: 20),
              if (!bootstrap.hasFailed && !bootstrap.isReady)
                const LinearProgressIndicator(minHeight: 4),
              if (bootstrap.hasFailed) ...[
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    bootstrap.error ?? '启动失败',
                    style: TextStyle(
                        color: Theme.of(context).colorScheme.onErrorContainer),
                  ),
                ),
                const SizedBox(height: 12),
                FilledButton.icon(
                  onPressed: bootstrap.retry,
                  icon: const Icon(Icons.refresh),
                  label: const Text('重试'),
                ),
              ],
            ],
          ),
        ),
      ),
    );
  }

  static String _stageLabel(BootstrapStage stage) {
    switch (stage) {
      case BootstrapStage.init:
        return '正在初始化...';
      case BootstrapStage.connectingWs:
        return '正在连接 Host...';
      case BootstrapStage.checkingConfig:
        return '正在检查配置...';
      case BootstrapStage.ready:
        return '启动完成';
      case BootstrapStage.failed:
        return '启动失败';
    }
  }
}

