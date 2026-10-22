import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';

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

  // ── Step 2: 称呼设置 ──
  final _usernameCtrl = TextEditingController(text: '开拓者');
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

  // ── Step 2: 设置称呼 ──

  Future<void> _submitAuth() async {
    final username =
        _usernameCtrl.text.trim().isEmpty ? '开拓者' : _usernameCtrl.text.trim();

    final ws = context.read<WsService>();
    if (ws.status == WsStatus.connected) {
      setState(() => _submittingAuth = true);
      ws.register(username, '');
      await _waitForAuth(const Duration(seconds: 3));
      if (!mounted) return;
      setState(() => _submittingAuth = false);
    }

    _detectNetworkInfo();
    _goToStep(2);
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
    final bootstrap = context.read<BootstrapService>();
    await bootstrap.markSetupCompleted();
    bootstrap.enterOfflineMode();
  }

  Future<void> _skipDirectlyToApp() async {
    final bootstrap = context.read<BootstrapService>();
    await bootstrap.markSetupCompleted();
    bootstrap.enterOfflineMode();
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

  Future<void> _editServerUrl(BuildContext context) async {
    final ws = context.read<WsService>();
    final ctrl = TextEditingController(text: ws.serverUrl);
    await showDialog<void>(
      context: context,
      builder: (ctx) => AlertDialog(
        title: const Text('修改 Host 服务地址'),
        content: TextField(
          controller: ctrl,
          autofocus: true,
          decoration: const InputDecoration(
            labelText: 'WebSocket 地址',
            hintText: 'ws://127.0.0.1:8765',
            border: OutlineInputBorder(),
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(ctx),
            child: const Text('取消'),
          ),
          FilledButton(
            onPressed: () async {
              final val = ctrl.text.trim();
              if (val.isNotEmpty) {
                await ws.setServerUrl(val, reconnectIfConnected: true);
              }
              if (ctx.mounted) Navigator.pop(ctx);
            },
            child: const Text('保存并重连'),
          ),
        ],
      ),
    );
  }

  // ── 构建 UI ──

  @override
  Widget build(BuildContext context) {
    final bootstrap = context.watch<BootstrapService>();

    return Scaffold(
      body: Center(
        child: Container(
          width: 580,
          padding: const EdgeInsets.symmetric(horizontal: 32, vertical: 24),
          child: ScrollConfiguration(
            behavior:
                ScrollConfiguration.of(context).copyWith(scrollbars: false),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: [
                _buildStepIndicator(),
                const SizedBox(height: 20),
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
      ),
    );
  }

  // ── 步骤指示器 ──

  Widget _buildStepIndicator() {
    const labels = ['AI 配置', '你的称呼', '完成'];
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
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
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
              TextButton.icon(
                onPressed: _skipDirectlyToApp,
                icon: const Icon(Icons.arrow_forward, size: 16),
                label: const Text('跳过配置，直接进入'),
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
                onPressed: () => _editServerUrl(context),
                icon: const Icon(Icons.settings_ethernet, size: 16),
                label: const Text('修改服务器地址'),
              ),
            ),
          ],

          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.spaceBetween,
            children: [
              TextButton(
                onPressed: () => _goToStep(1),
                child: const Text('暂不配置，下一步 >'),
              ),
              FilledButton.icon(
                onPressed: !_savingLlm
                    ? () async {
                        if (connected) {
                          await _saveLlmConfig();
                        } else {
                          _goToStep(1);
                        }
                      }
                    : null,
                icon: _savingLlm
                    ? const SizedBox(
                        width: 16,
                        height: 16,
                        child: CircularProgressIndicator(
                            strokeWidth: 2, color: Colors.white))
                    : const Icon(Icons.arrow_forward),
                label: Text(connected ? '保存并继续' : '下一步 (离线模式)'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Step 2: 设置你的称呼 ──

  Widget _buildStep2Auth(BootstrapService bootstrap) {
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          Row(
            children: [
              Icon(Icons.face_outlined,
                  color: Theme.of(context).colorScheme.primary, size: 28),
              const SizedBox(width: 12),
              Text(
                '设置你的称呼',
                style: Theme.of(context).textTheme.headlineSmall?.copyWith(
                      fontWeight: FontWeight.bold,
                    ),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '告诉流萤该怎么称呼你，无需繁琐的账号密码。',
            style: Theme.of(context).textTheme.bodyMedium?.copyWith(
                  color: Theme.of(context)
                      .colorScheme
                      .onSurface
                      .withValues(alpha: 0.7),
                ),
          ),
          const SizedBox(height: 32),

          // 称呼/昵称输入
          TextField(
            controller: _usernameCtrl,
            decoration: const InputDecoration(
              labelText: '你的称呼 / 昵称',
              hintText: '例如：开拓者、旅行者、指挥官...',
              border: OutlineInputBorder(),
              prefixIcon: Icon(Icons.person),
            ),
            textInputAction: TextInputAction.done,
            onSubmitted: (_) => _submitAuth(),
          ),
          const SizedBox(height: 16),
          Text(
            '提示：后续也可以在统一设置中心随时修改你的称呼。',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context)
                  .colorScheme
                  .onSurface
                  .withValues(alpha: 0.5),
            ),
          ),

          const SizedBox(height: 36),

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
                label: const Text('确认并继续'),
              ),
            ],
          ),
        ],
      ),
    );
  }

  // ── Step 3: 完成 ──

  Widget _buildStep3Complete(BootstrapService bootstrap) {
    final isDesktop = !kIsWeb &&
        (Platform.isWindows || Platform.isLinux || Platform.isMacOS);
    final port = '8765'; // 默认端口
    final localAddr = 'ws://127.0.0.1:$port';
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
            label: '称呼',
            value: _usernameCtrl.text.trim().isEmpty
                ? '开拓者'
                : _usernameCtrl.text.trim(),
          ),

          const SizedBox(height: 24),

          // 服务连接方式 / 局域网多端访问
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
                    Icon(
                      isDesktop ? Icons.devices_outlined : Icons.phone_android,
                      size: 20,
                      color: Theme.of(context).colorScheme.primary,
                    ),
                    const SizedBox(width: 8),
                    Text(
                      isDesktop ? '服务连接与多端访问' : '连接方式',
                      style: Theme.of(context).textTheme.titleSmall?.copyWith(
                            fontWeight: FontWeight.bold,
                          ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),

                // 桌面端显示本机直连，手机端显示 ADB 转发
                if (isDesktop)
                  _connectionRow(
                    emoji: '💻',
                    label: '本机直连',
                    address: localAddr,
                    hint: '当前电脑客户端直接连接本机 Host',
                  )
                else
                  _connectionRow(
                    emoji: '📱',
                    label: 'ADB 转发',
                    address: localAddr,
                    hint: '需在电脑执行 adb forward tcp:$port tcp:$port',
                  ),
                const SizedBox(height: 8),

                // 局域网
                _connectionRow(
                  emoji: '🏠',
                  label: '局域网',
                  address: lanAddr.isNotEmpty ? lanAddr : null,
                  hint: _detectingNetwork
                      ? '正在检测...'
                      : (isDesktop ? '可供手机或局域网其他设备连接' : '未检测到局域网 IP'),
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
                Row(
                  mainAxisAlignment: MainAxisAlignment.center,
                  children: [
                    FilledButton.icon(
                      onPressed: bootstrap.retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试连接'),
                    ),
                    const SizedBox(width: 12),
                    OutlinedButton.icon(
                      onPressed: bootstrap.enterOfflineMode,
                      icon: const Icon(Icons.arrow_forward),
                      label: const Text('跳过，直接进入'),
                    ),
                  ],
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
      case BootstrapStage.startingHost:
        return '正在启动内核服务...';
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

