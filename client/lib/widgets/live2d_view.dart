import 'dart:async';
import 'dart:math';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:webview_windows/webview_windows.dart';

import '../services/ws_service.dart';

/// 可在任意页面嵌入的 Live2D 看板娘 Widget
class Live2dView extends StatefulWidget {
  final double? width;
  final double? height;
  final ValueChanged<String>? onHitArea;

  const Live2dView({
    super.key,
    this.width,
    this.height,
    this.onHitArea,
  });

  @override
  State<Live2dView> createState() => _Live2dViewState();
}

class _Live2dViewState extends State<Live2dView> {
  final WebviewController _webview = WebviewController();
  bool _initialized = false;
  Timer? _lipSyncTimer;
  StreamSubscription? _voiceSub;

  @override
  void initState() {
    super.initState();
    _initWebview();
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _subscribeVoiceEvents();
  }

  void _subscribeVoiceEvents() {
    final ws = context.read<WsService>();
    _voiceSub?.cancel();
    _voiceSub = ws.voiceEvents.listen((evt) {
      final type = evt['type'];
      if (type == 'TTS_START') {
        _startLipSync();
      } else if (type == 'TTS_END' || type == 'TTS_STOP') {
        _stopLipSync();
      }
    });
  }

  Future<void> _initWebview() async {
    try {
      await _webview.initialize();
      await _webview.setBackgroundColor(Colors.transparent);

      // 从 Host 提供的 HTTP 静态服务加载 viewer.html
      const url = 'http://127.0.0.1:8765/live2d/viewer.html';
      await _webview.loadUrl(url);

      if (mounted) {
        setState(() => _initialized = true);
      }
    } catch (e) {
      debugPrint('[Live2D] Webview 初始化异常: $e');
    }
  }

  void _startLipSync() {
    _lipSyncTimer?.cancel();
    final random = Random();
    _lipSyncTimer = Timer.periodic(const Duration(milliseconds: 100), (_) {
      if (!_initialized) return;
      final volume = 0.2 + random.nextDouble() * 0.7;
      _webview.executeScript('window.setLive2DLipSync($volume);');
    });
  }

  void _stopLipSync() {
    _lipSyncTimer?.cancel();
    _lipSyncTimer = null;
    if (_initialized) {
      _webview.executeScript('window.setLive2DLipSync(0);');
    }
  }

  @override
  void dispose() {
    _lipSyncTimer?.cancel();
    _voiceSub?.cancel();
    _webview.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (!_initialized) {
      return SizedBox(
        width: widget.width ?? 280,
        height: widget.height ?? 380,
        child: const Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(strokeWidth: 2),
          ),
        ),
      );
    }

    return SizedBox(
      width: widget.width,
      height: widget.height,
      child: Webview(_webview),
    );
  }
}
