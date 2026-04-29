import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:flutter_unity_widget/flutter_unity_widget.dart';

import '../services/unity_launcher.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';

class UnityLaunchScreen extends StatefulWidget {
  const UnityLaunchScreen({super.key});

  static Future<void> open(BuildContext context) {
    return Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const UnityLaunchScreen()),
    );
  }

  @override
  State<UnityLaunchScreen> createState() => _UnityLaunchScreenState();
}

class _UnityLaunchScreenState extends State<UnityLaunchScreen>
    with SingleTickerProviderStateMixin {
  bool _launching = true;
  bool _launched = false;
  String _status = '正在准备启动...';
  String? _error;
  late final AnimationController _gradientController;
  
  // For Android Embedded Unity
  UnityWidgetController? _unityWidgetController;
  bool _unityReady = false;
  Timer? _readyTimeout;
  Timer? _retryTimer;
  int _retryCount = 0;
  String _unityStatus = '等待 Unity 初始化...';

  @override
  void initState() {
    super.initState();
    _gradientController = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 900),
    );
    if (!Platform.isAndroid) {
      WidgetsBinding.instance.addPostFrameCallback((_) => _startLaunch());
    }
  }

  void _onUnityCreated(UnityWidgetController controller) {
    _unityWidgetController = controller;
    if (mounted) {
      setState(() => _unityStatus = 'Unity 视图已创建，正在检查状态...');
    }
    debugPrint('[UnityLaunch] onUnityCreated fired');

    // Probe Unity player state
    _probeUnityState();

    // Delay first message slightly to let Unity scene initialize
    Future.delayed(const Duration(seconds: 2), () {
      _sendConnectionData();
      _probeUnityState();
    });

    // Retry sending every 3 seconds in case the first attempt was too early
    _retryTimer = Timer.periodic(const Duration(seconds: 3), (_) {
      if (_unityReady || _retryCount >= 5) {
        _retryTimer?.cancel();
        return;
      }
      _retryCount++;
      debugPrint('[UnityLaunch] Retry #$_retryCount sending connection data');
      _sendConnectionData();
      _probeUnityState();
    });

    // Timeout fallback: auto-dismiss loading after 15 seconds
    _readyTimeout = Timer(const Duration(seconds: 15), () {
      if (!_unityReady && mounted) {
        debugPrint('[UnityLaunch] Timeout: Ready message never received, auto-dismissing overlay');
        setState(() {
          _unityReady = true;
          _unityStatus = 'Unity 已加载（超时自动跳过）';
        });
      }
    });
  }

  Future<void> _probeUnityState() async {
    if (_unityWidgetController == null) return;
    try {
      final isReady = await _unityWidgetController!.isReady();
      final isLoaded = await _unityWidgetController!.isLoaded();
      final isPaused = await _unityWidgetController!.isPaused();
      debugPrint('[UnityLaunch] Unity state: isReady=$isReady, isLoaded=$isLoaded, isPaused=$isPaused');
      if (mounted) {
        setState(() => _unityStatus = 'Ready=$isReady Loaded=$isLoaded Paused=$isPaused');
      }
    } catch (e) {
      debugPrint('[UnityLaunch] Failed to probe Unity state: $e');
    }
  }

  void _sendConnectionData() {
    if (_unityWidgetController == null) return;
    final ws = context.read<WsService>();
    _unityWidgetController?.postMessage(
      'GameManager',
      'SetConnectionData',
      '${ws.serverUrl}|${ws.accessKey}',
    );
    debugPrint('[UnityLaunch] Sent SetConnectionData to GameManager');
    if (mounted) {
      setState(() => _unityStatus = '已发送连接数据，等待 Unity Ready...');
    }
  }

  void _onUnityMessage(dynamic message) {
    debugPrint('[UnityLaunch] Received message from Unity: $message');
    if (message == 'Ready') {
      _readyTimeout?.cancel();
      _retryTimer?.cancel();
      setState(() {
        _unityReady = true;
        _unityStatus = 'Unity 已就绪';
      });
    }
  }

  @override
  void dispose() {
    _readyTimeout?.cancel();
    _retryTimer?.cancel();
    _gradientController.dispose();
    super.dispose();
  }

  Future<void> _startLaunch() async {
    if (!mounted) return;
    setState(() {
      _launching = true;
      _launched = false;
      _error = null;
      _status = '正在启动 Firefly...';
    });

    final ws = context.read<WsService>();
    final result = await UnityLauncher.launch(
      wsUrl: ws.serverUrl,
      accessKey: ws.accessKey,
    );

    if (!mounted) return;
    if (result.ok) {
      setState(() {
        _launching = false;
        _launched = true;
        _status = result.message;
      });
      _gradientController.forward(from: 0);
      await Future<void>.delayed(const Duration(milliseconds: 900));
      if (mounted) {
        Navigator.of(context).pop();
      }
      return;
    }

    setState(() {
      _launching = false;
      _launched = false;
      _error = result.message;
      _status = '启动失败';
    });
  }

  Widget _buildAndroidEmbeddedView(BuildContext context, LumiColors colors) {
    return Scaffold(
      body: Stack(
        children: [
          // 底层：Unity 视图
          UnityWidget(
            onUnityCreated: _onUnityCreated,
            onUnityMessage: _onUnityMessage,
            onUnityUnloaded: () {
              debugPrint('[UnityLaunch] Unity was UNLOADED');
            },
            onUnitySceneLoaded: (SceneLoaded? scene) {
              debugPrint('[UnityLaunch] Scene loaded: ${scene?.name} buildIndex=${scene?.buildIndex}');
              // If we get a scene loaded event, Unity is definitely working
              if (!_unityReady && mounted) {
                _readyTimeout?.cancel();
                _retryTimer?.cancel();
                setState(() {
                  _unityReady = true;
                  _unityStatus = 'Unity 场景已加载';
                });
              }
            },
            useAndroidViewSurface: true,
            fullscreen: false,
          ),
          // 顶层：加载遮罩
          if (!_unityReady)
            Container(
              color: colors.sidebar,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    const CircularProgressIndicator(),
                    const SizedBox(height: 20),
                    Text(
                      '正在加载 3D 场景...',
                      style: TextStyle(
                        color: colors.subtext,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      _unityStatus,
                      style: TextStyle(
                        color: colors.subtext.withOpacity(0.6),
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
            ),
          // 返回按钮悬浮层
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 8,
            child: IconButton(
              icon: const Icon(Icons.arrow_back),
              color: Colors.white,
              onPressed: () => Navigator.of(context).pop(),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = Theme.of(context).extension<LumiColors>()!;
    
    if (Platform.isAndroid) {
      return _buildAndroidEmbeddedView(context, colors);
    }

    final ws = context.watch<WsService>();
    final accessKeyLabel = ws.accessKey.trim().isEmpty ? '未设置' : '已设置';

    final platformHint = Platform.isWindows
        ? 'Windows: ${UnityLauncher.resolveWindowsExePath()}'
        : Platform.isAndroid
            ? 'Android: ${UnityLauncher.resolveAndroidPackage()}'
            : '当前平台未支持';

    return Scaffold(
      appBar: AppBar(
        title: const Text('启动 Firefly'),
        actions: [
          TextButton(
            onPressed: _launching ? null : () => Navigator.of(context).pop(),
            child: const Text('返回'),
          ),
        ],
      ),
      body: Stack(
        children: [
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 560),
              child: Container(
                margin: const EdgeInsets.all(24),
                padding: const EdgeInsets.all(24),
                decoration: BoxDecoration(
                  color: colors.inputBg,
                  borderRadius: BorderRadius.circular(16),
                  border: Border.all(color: colors.divider),
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.auto_awesome, color: colors.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Text(
                            _status,
                            style: const TextStyle(
                              fontSize: 18,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    Text(
                      '连接地址: ${ws.serverUrl}',
                      style: TextStyle(color: colors.subtext),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'AccessKey: $accessKeyLabel',
                      style: TextStyle(color: colors.subtext),
                    ),
                    const SizedBox(height: 12),
                    Text(
                      platformHint,
                      style: TextStyle(color: colors.subtext, fontSize: 12),
                    ),
                    const SizedBox(height: 16),
                    if (_launching)
                      const LinearProgressIndicator(minHeight: 6)
                    else if (_error != null)
                      Text(
                        _error!,
                        style: TextStyle(color: Theme.of(context).colorScheme.error),
                      )
                    else
                      Text(
                        '已发出启动指令。',
                        style: TextStyle(color: colors.subtext),
                      ),
                    const SizedBox(height: 16),
                    Row(
                      children: [
                        if (_error != null)
                          FilledButton.icon(
                            onPressed: _startLaunch,
                            icon: const Icon(Icons.refresh, size: 16),
                            label: const Text('重试'),
                          ),
                        if (_launched) const Spacer(),
                        if (_launched)
                          Text(
                            '已启动，稍后自动返回',
                            style: TextStyle(color: colors.subtext, fontSize: 12),
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
          if (_launched)
            Positioned.fill(
              child: IgnorePointer(
                child: AnimatedBuilder(
                  animation: _gradientController,
                  builder: (context, child) {
                    final t = Curves.easeOut.transform(
                      _gradientController.value,
                    );
                    return Opacity(
                      opacity: t,
                      child: Container(
                        decoration: BoxDecoration(
                          gradient: LinearGradient(
                            begin: Alignment(-1.0 + t * 0.4, -1.0),
                            end: Alignment(1.0, 1.0 - t * 0.4),
                            colors: [
                              colors.accent.withValues(alpha: 0.2),
                              colors.accent.withValues(alpha: 0.06),
                              Colors.transparent,
                            ],
                            stops: const [0.0, 0.6, 1.0],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              ),
            ),
        ],
      ),
    );
  }
}
