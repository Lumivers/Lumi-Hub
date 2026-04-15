import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../services/app_settings.dart';
import '../../services/ws_service.dart';

class ConnectionSettingsDialog extends StatefulWidget {
  final WsService ws;
  final AppSettings settings;
  final bool allowAskEachLaunch;
  final bool reconnectIfConnected;
  final bool barrierDismissible;
  final bool allowCancel;
  final String title;
  final String confirmText;

  const ConnectionSettingsDialog({
    super.key,
    required this.ws,
    required this.settings,
    required this.title,
    required this.confirmText,
    this.allowAskEachLaunch = true,
    this.reconnectIfConnected = false,
    this.barrierDismissible = true,
    this.allowCancel = true,
  });

  static Future<bool> show(
    BuildContext context, {
    required WsService ws,
    required AppSettings settings,
    String title = '连接设置',
    String confirmText = '保存',
    bool allowAskEachLaunch = true,
    bool reconnectIfConnected = false,
    bool barrierDismissible = true,
    bool allowCancel = true,
  }) async {
    final result = await showDialog<bool>(
      context: context,
      barrierDismissible: barrierDismissible,
      builder: (_) => ConnectionSettingsDialog(
        ws: ws,
        settings: settings,
        title: title,
        confirmText: confirmText,
        allowAskEachLaunch: allowAskEachLaunch,
        reconnectIfConnected: reconnectIfConnected,
        barrierDismissible: barrierDismissible,
        allowCancel: allowCancel,
      ),
    );

    return result ?? false;
  }

  @override
  State<ConnectionSettingsDialog> createState() =>
      _ConnectionSettingsDialogState();
}

class _ConnectionSettingsDialogState extends State<ConnectionSettingsDialog> {
  late ConnectionMode _selectedMode;
  late bool _askEachLaunch;
  final TextEditingController _lanController = TextEditingController();
  final TextEditingController _publicController = TextEditingController();
  String? _validationText;

  bool get _supportsLocalHostLifecycle => !kIsWeb && Platform.isWindows;

  bool _isLocalHostUrl(String raw) {
    final uri = Uri.tryParse(raw);
    if (uri == null) return false;
    final host = uri.host.toLowerCase();
    return host == '127.0.0.1' || host == 'localhost' || host == '::1';
  }

  @override
  void initState() {
    super.initState();
    _selectedMode = widget.settings.connectionMode;
    _askEachLaunch = widget.settings.askConnectionModeOnLaunch;
    _prefillAddressInputs();
  }

  void _prefillAddressInputs() {
    final currentUrl = widget.ws.serverUrl;

    if (_selectedMode == ConnectionMode.lan) {
      _lanController.text = currentUrl;
    }
    if (_selectedMode == ConnectionMode.publicTunnel) {
      _publicController.text = currentUrl;
    }

    if (_isLocalHostUrl(currentUrl)) {
      return;
    }

    if (currentUrl.startsWith('wss://') && _publicController.text.isEmpty) {
      _publicController.text = currentUrl;
    }

    if (currentUrl.startsWith('ws://') && _lanController.text.isEmpty) {
      _lanController.text = currentUrl;
    }
  }

  Future<void> _applyConnectionMode(String? customUrl) async {
    final currentUrl = widget.ws.serverUrl;
    String nextUrl = currentUrl;

    final shouldUseRemote =
        _selectedMode != ConnectionMode.localOrUsb || !_supportsLocalHostLifecycle;

    switch (_selectedMode) {
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

    widget.settings.setConnectionMode(_selectedMode);
    widget.settings.setRemoteClientMode(shouldUseRemote);
    await widget.ws.setServerUrl(
      nextUrl,
      reconnectIfConnected: widget.reconnectIfConnected,
    );
  }

  Future<void> _save() async {
    String? customUrl;

    if (_selectedMode == ConnectionMode.lan) {
      final entered = _lanController.text.trim();
      customUrl = entered.isEmpty ? null : entered;
      if (customUrl == null && _isLocalHostUrl(widget.ws.serverUrl)) {
        setState(() {
          _validationText = '当前仍是本机地址，请输入局域网地址。';
        });
        return;
      }
    } else if (_selectedMode == ConnectionMode.publicTunnel) {
      final entered = _publicController.text.trim();
      customUrl = entered.isEmpty ? null : entered;
      if (customUrl == null && _isLocalHostUrl(widget.ws.serverUrl)) {
        setState(() {
          _validationText = '当前仍是本机地址，请输入公网地址。';
        });
        return;
      }
    }

    try {
      await _applyConnectionMode(customUrl);
      if (widget.allowAskEachLaunch) {
        widget.settings.setAskConnectionModeOnLaunch(_askEachLaunch);
      }
    } on FormatException catch (e) {
      setState(() {
        _validationText = e.message;
      });
      return;
    }

    if (!mounted) return;
    Navigator.of(context).pop(true);
  }

  @override
  void dispose() {
    _lanController.dispose();
    _publicController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final localModeLabel = _supportsLocalHostLifecycle
        ? '本机启动 Host (127.0.0.1)'
        : 'USB 调试转发 (127.0.0.1)';
    final bottomInset = MediaQuery.of(context).viewInsets.bottom;

    return AlertDialog(
      scrollable: true,
      title: Text(widget.title),
      content: AnimatedPadding(
        duration: const Duration(milliseconds: 120),
        curve: Curves.easeOut,
        padding: EdgeInsets.only(bottom: bottomInset > 0 ? 8 : 0),
        child: SizedBox(
          width: (MediaQuery.of(context).size.width * 0.9).clamp(280.0, 460.0),
          child: ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.of(context).size.height *
                  (bottomInset > 0 ? 0.48 : 0.62),
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    '当前地址: ${widget.ws.serverUrl}',
                    style: TextStyle(
                      fontSize: 12,
                      color: Theme.of(context).colorScheme.onSurfaceVariant,
                    ),
                  ),
                  const SizedBox(height: 8),
                  RadioGroup<ConnectionMode>(
                    groupValue: _selectedMode,
                    onChanged: (value) {
                      if (value == null) return;
                      setState(() {
                        _selectedMode = value;
                        _validationText = null;
                      });
                    },
                    child: Column(
                      children: [
                        RadioListTile<ConnectionMode>(
                          value: ConnectionMode.localOrUsb,
                          contentPadding: EdgeInsets.zero,
                          title: Text(localModeLabel),
                          subtitle: Text(
                            _supportsLocalHostLifecycle
                                ? '适合电脑端本机启动 AstrBot'
                                : '需 adb reverse tcp:8765 tcp:8765',
                          ),
                        ),
                        const SizedBox(height: 0),
                        RadioListTile<ConnectionMode>(
                          value: ConnectionMode.lan,
                          contentPadding: EdgeInsets.zero,
                          title: const Text('局域网'),
                          subtitle: const Text('手动填写局域网地址'),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 12,
                            right: 12,
                            bottom: 8,
                          ),
                          child: TextField(
                            controller: _lanController,
                            enabled: _selectedMode == ConnectionMode.lan,
                            onTap: () {
                              if (_selectedMode != ConnectionMode.lan) {
                                setState(() {
                                  _selectedMode = ConnectionMode.lan;
                                  _validationText = null;
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
                          contentPadding: EdgeInsets.zero,
                          title: const Text('公网/内网穿透'),
                          subtitle: const Text('手动填写公网地址'),
                        ),
                        Padding(
                          padding: const EdgeInsets.only(
                            left: 12,
                            right: 12,
                            bottom: 8,
                          ),
                          child: TextField(
                            controller: _publicController,
                            enabled:
                                _selectedMode == ConnectionMode.publicTunnel,
                            onTap: () {
                              if (_selectedMode !=
                                  ConnectionMode.publicTunnel) {
                                setState(() {
                                  _selectedMode = ConnectionMode.publicTunnel;
                                  _validationText = null;
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
                      ],
                    ),
                  ),
                  if (widget.allowAskEachLaunch) ...[
                    const SizedBox(height: 8),
                    SwitchListTile(
                      contentPadding: EdgeInsets.zero,
                      title: const Text('每次启动都询问'),
                      subtitle: const Text('关闭后将记住当前选择并自动连接'),
                      value: _askEachLaunch,
                      onChanged: (value) {
                        setState(() {
                          _askEachLaunch = value;
                        });
                      },
                    ),
                  ],
                  if (_validationText != null)
                    Padding(
                      padding: const EdgeInsets.only(top: 6),
                      child: Text(
                        _validationText!,
                        style: TextStyle(
                          color: Theme.of(context).colorScheme.error,
                          fontSize: 12,
                        ),
                      ),
                    ),
                ],
              ),
            ),
          ),
        ),
      ),
      actions: [
        if (widget.allowCancel)
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
        FilledButton(
          onPressed: _save,
          child: Text(widget.confirmText),
        ),
      ],
    );
  }
}
