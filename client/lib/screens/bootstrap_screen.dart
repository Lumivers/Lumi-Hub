import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

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
    BuildContext context,
    ConnectionMode mode,
    String? customUrl,
  ) async {
    final ws = context.read<WsService>();
    final settings = context.read<AppSettings>();
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
    final settings = context.read<AppSettings>();
    var selected = settings.connectionMode;
    var askEachLaunch = settings.askConnectionModeOnLaunch;
    String? validationText;
    final lanController = TextEditingController();
    final publicController = TextEditingController();

    final localModeLabel = _supportsLocalHostLifecycle
        ? '本机启动 Host (127.0.0.1)'
        : 'USB 调试转发 (127.0.0.1)';

    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('选择连接方式'),
              content: SizedBox(
                width: (MediaQuery.of(dialogContext).size.width * 0.9).clamp(
                  280.0,
                  460.0,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    RadioListTile<ConnectionMode>(
                      value: ConnectionMode.localOrUsb,
                      groupValue: selected,
                      contentPadding: EdgeInsets.zero,
                      title: Text(localModeLabel),
                      subtitle: Text(
                        _supportsLocalHostLifecycle
                            ? '适合电脑端本机启动 AstrBot'
                            : '需 adb reverse tcp:8765 tcp:8765',
                      ),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => selected = value);
                      },
                    ),
                    RadioListTile<ConnectionMode>(
                      value: ConnectionMode.lan,
                      groupValue: selected,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('局域网'),
                      subtitle: const Text('手动填写局域网地址'),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          selected = value;
                          validationText = null;
                        });
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
                      child: TextField(
                        controller: lanController,
                        enabled: selected == ConnectionMode.lan,
                        onTap: () {
                          if (selected != ConnectionMode.lan) {
                            setState(() {
                              selected = ConnectionMode.lan;
                              validationText = null;
                            });
                          }
                        },
                        decoration: const InputDecoration(
                          hintText: '示例: ws://192.168.1.23:8765',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    RadioListTile<ConnectionMode>(
                      value: ConnectionMode.publicTunnel,
                      groupValue: selected,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('公网/内网穿透'),
                      subtitle: const Text('手动填写公网地址'),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() {
                          selected = value;
                          validationText = null;
                        });
                      },
                    ),
                    Padding(
                      padding: const EdgeInsets.only(left: 12, right: 12, bottom: 8),
                      child: TextField(
                        controller: publicController,
                        enabled: selected == ConnectionMode.publicTunnel,
                        onTap: () {
                          if (selected != ConnectionMode.publicTunnel) {
                            setState(() {
                              selected = ConnectionMode.publicTunnel;
                              validationText = null;
                            });
                          }
                        },
                        decoration: const InputDecoration(
                          hintText: '示例: wss://chat.example.com/ws',
                          border: OutlineInputBorder(),
                          isDense: true,
                        ),
                      ),
                    ),
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('每次启动都询问'),
                      subtitle: const Text('关闭后将记住当前选择并自动连接'),
                      value: askEachLaunch,
                      onChanged: (value) {
                        setState(() => askEachLaunch = value);
                      },
                    ),
                    if (validationText != null)
                      Padding(
                        padding: const EdgeInsets.only(top: 6),
                        child: Text(
                          validationText!,
                          style: TextStyle(
                            color: Theme.of(context).colorScheme.error,
                            fontSize: 12,
                          ),
                        ),
                      ),
                  ],
                ),
              ),
              actions: [
                FilledButton(
                  onPressed: () async {
                    String? customUrl;
                    if (selected == ConnectionMode.lan) {
                      customUrl = lanController.text.trim();
                      if (customUrl.isEmpty) {
                        setState(() {
                          validationText = '请选择局域网时，请输入局域网地址。';
                        });
                        return;
                      }
                    } else if (selected == ConnectionMode.publicTunnel) {
                      customUrl = publicController.text.trim();
                      if (customUrl.isEmpty) {
                        setState(() {
                          validationText = '请选择公网/内网穿透时，请输入公网地址。';
                        });
                        return;
                      }
                    }

                    try {
                      await _applyConnectionMode(dialogContext, selected, customUrl);
                    } on FormatException catch (e) {
                      setState(() {
                        validationText = e.message;
                      });
                      return;
                    }

                    settings.setAskConnectionModeOnLaunch(askEachLaunch);
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: const Text('确认并继续'),
                ),
              ],
            );
          },
        );
      },
    );

    lanController.dispose();
    publicController.dispose();
  }

  Future<void> _prepareAndStart() async {
    if (_bootTriggered || !mounted) return;
    _bootTriggered = true;

    final settings = context.read<AppSettings>();
    await settings.loaded;
    if (!mounted) return;

    if (settings.askConnectionModeOnLaunch) {
      await _showConnectionModeDialog(context);
    } else {
      await _applyConnectionMode(context, settings.connectionMode, null);
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
