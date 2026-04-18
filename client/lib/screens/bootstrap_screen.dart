import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'components/connection_settings_dialog.dart';
import '../services/app_settings.dart';
import '../services/bootstrap_service.dart';
import '../services/ws_service.dart';

class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({super.key});

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  bool _bootTriggered = false;

  bool get _supportsLocalHostLifecycle => !kIsWeb && Platform.isWindows;

  bool _isLocalHostUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  Future<void> _applyConnectionMode(
    WsService ws,
    AppSettings settings,
    ConnectionMode mode,
    String? customUrl,
  ) async {
    // 启动前统一归一化连接模式，决定默认地址与是否远程客户端模式。
    final currentUrl = ws.serverUrl;

    String nextUrl = currentUrl;
    final shouldUseRemote =
        mode != ConnectionMode.localOrUsb || !_supportsLocalHostLifecycle;

    switch (mode) {
      case ConnectionMode.localOrUsb:
        nextUrl = 'ws://127.0.0.1:8765';
        break;
      case ConnectionMode.lan:
        if (customUrl != null && customUrl.trim().isNotEmpty) {
          nextUrl = customUrl.trim();
        } else if (_isLocalHostUrl(currentUrl)) {
          nextUrl = 'ws://192.168.1.10:8765';
        }
        break;
      case ConnectionMode.publicTunnel:
        if (customUrl != null && customUrl.trim().isNotEmpty) {
          nextUrl = customUrl.trim();
        } else if (_isLocalHostUrl(currentUrl)) {
          nextUrl = 'wss://your-domain.example.com/ws';
        }
        break;
    }

    settings.setConnectionMode(mode);
    settings.setRemoteClientMode(shouldUseRemote);
    await ws.setServerUrl(nextUrl, reconnectIfConnected: false);
  }

  Future<void> _showConnectionModeDialog(BuildContext context) async {
    final ws = context.read<WsService>();
    final settings = context.read<AppSettings>();
    await ConnectionSettingsDialog.show(
      context,
      ws: ws,
      settings: settings,
      title: '选择连接方式',
      confirmText: '确认并继续',
      barrierDismissible: false,
      allowCancel: false,
    );
  }

  Future<void> _openConnectionSettings() async {
    final ws = context.read<WsService>();
    final settings = context.read<AppSettings>();
    final changed = await ConnectionSettingsDialog.show(
      context,
      ws: ws,
      settings: settings,
      title: '连接设置',
      confirmText: '保存设置',
      barrierDismissible: true,
      allowCancel: true,
    );

    if (!mounted || !changed) return;

    final bootstrap = context.read<BootstrapService>();
    if (bootstrap.hasFailed) {
      await bootstrap.retry();
      return;
    }

    if (!mounted) return;
    ScaffoldMessenger.of(
      context,
    ).showSnackBar(const SnackBar(content: Text('连接设置已保存，下次连接将使用新地址。')));
  }

  Future<void> _prepareAndStart() async {
    if (_bootTriggered || !mounted) return;
    _bootTriggered = true;

    final ws = context.read<WsService>();
    final settings = context.read<AppSettings>();
    await settings.loaded;
    if (!mounted) return;

    // 首次阶段：先确定连接模式，再进入 BootstrapService 启动流程。
    if (settings.askConnectionModeOnLaunch) {
      await _showConnectionModeDialog(context);
    } else {
      await _applyConnectionMode(ws, settings, settings.connectionMode, null);
    }

    if (!mounted) return;
    await context.read<BootstrapService>().ensureStarted();
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      unawaited(_prepareAndStart());
    });
  }

  @override
  Widget build(BuildContext context) {
    final bootstrap = context.watch<BootstrapService>();

    return Scaffold(
      body: Center(
        child: Container(
          width: 560,
          padding: const EdgeInsets.all(28),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              Row(
                children: [
                  CircleAvatar(
                    radius: 28,
                    backgroundColor: Theme.of(context).colorScheme.primary,
                    child: const Icon(
                      Icons.rocket_launch,
                      color: Colors.white,
                      size: 28,
                    ),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text(
                      'Lumi-Hub 启动准备',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 18),
              Text(
                _stageLabel(bootstrap.stage),
                style: TextStyle(
                  fontSize: 14,
                  color: Theme.of(context).colorScheme.secondary,
                ),
              ),
              const SizedBox(height: 12),
              if (!bootstrap.hasFailed)
                const LinearProgressIndicator(minHeight: 6),
              if (bootstrap.hasFailed)
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Text(
                    bootstrap.error ?? '启动失败',
                    style: TextStyle(
                      color: Theme.of(context).colorScheme.onErrorContainer,
                    ),
                  ),
                ),
              const SizedBox(height: 16),
              Container(
                height: 250,
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  border: Border.all(color: Theme.of(context).dividerColor),
                  borderRadius: BorderRadius.circular(10),
                ),
                child: ListView.builder(
                  itemCount: bootstrap.logs.length,
                  itemBuilder: (context, index) {
                    final log = bootstrap.logs[index];
                    Color color;
                    switch (log.level) {
                      case LogLevel.error:
                        color = Theme.of(context).colorScheme.error;
                        break;
                      case LogLevel.warning:
                        color = Colors.orange;
                        break;
                      case LogLevel.debug:
                        color = Colors.grey;
                        break;
                      case LogLevel.info:
                        color = Theme.of(context).colorScheme.onSurfaceVariant;
                        break;
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        log.toString(),
                        style: TextStyle(
                          fontFamily: 'Consolas',
                          fontSize: 12,
                          color: color,
                        ),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  if (!bootstrap.hasFailed)
                    Expanded(
                      child: Text(
                        bootstrap.isRemoteClientMode
                            ? '启动流程：远程地址检测 -> WebSocket 连接 -> 登录'
                            : '启动流程：环境检查 -> AstrBot 检测/拉起 -> Host 连通性确认 -> 登录',
                        style: const TextStyle(fontSize: 12),
                      ),
                    ),
                  if (bootstrap.hasFailed) const Spacer(),
                  OutlinedButton.icon(
                    onPressed: _openConnectionSettings,
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text('连接设置'),
                  ),
                  if (bootstrap.hasFailed) const SizedBox(width: 8),
                  if (bootstrap.hasFailed)
                    FilledButton.icon(
                      onPressed: bootstrap.retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试启动'),
                    ),
                ],
              ),
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
      case BootstrapStage.checkingEnv:
        return '正在进行环境检查...';
      case BootstrapStage.checkingHost:
        return '正在检查 Host 是否已运行...';
      case BootstrapStage.startingAstrBot:
        return '正在启动 AstrBot...';
      case BootstrapStage.waitingHost:
        return '正在等待 Host 端口可用...';
      case BootstrapStage.connectingWs:
        return '正在连接 WebSocket...';
      case BootstrapStage.ready:
        return '启动完成。';
      case BootstrapStage.failed:
        return '启动失败。';
    }
  }
}
