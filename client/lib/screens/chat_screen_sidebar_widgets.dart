part of 'chat_screen.dart';

class _PersonaTile extends StatefulWidget {
  final String personaId;
  final bool isSelected;
  final LumiColors colors;
  final WsStatus wsStatus;
  final Widget? dragHandle;
  final VoidCallback onTap;
  final VoidCallback onClearHistory;
  final VoidCallback onDelete;

  const _PersonaTile({
    super.key,
    required this.personaId,
    required this.isSelected,
    required this.colors,
    required this.wsStatus,
    this.dragHandle,
    required this.onTap,
    required this.onClearHistory,
    required this.onDelete,
  });

  @override
  State<_PersonaTile> createState() => _PersonaTileState();
}

class _PersonaTileState extends State<_PersonaTile> {
  bool _isHovered = false;

  String get _avatarChar {
    final id = widget.personaId;
    return id.isNotEmpty ? id[0].toUpperCase() : '?';
  }

  void _showMenu(BuildContext context) async {
    final box = context.findRenderObject() as RenderBox;
    final pos = box.localToGlobal(Offset(box.size.width, 0));

    await showMenu(
      context: context,
      position: RelativeRect.fromLTRB(pos.dx, pos.dy, pos.dx + 1, pos.dy + 1),
      color: widget.colors.inputBg,
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(10)),
      items: [
        PopupMenuItem(
          onTap: widget.onClearHistory,
          child: Row(
            children: [
              Icon(
                Icons.delete_sweep_rounded,
                size: 18,
                color: widget.colors.subtext,
              ),
              const SizedBox(width: 10),
              const Text('清空聊天记录'),
            ],
          ),
        ),
        PopupMenuItem(
          onTap: widget.onDelete,
          child: const Row(
            children: [
              Icon(
                Icons.person_remove_rounded,
                size: 18,
                color: Colors.redAccent,
              ),
              SizedBox(width: 10),
              Text('删除人格', style: TextStyle(color: Colors.redAccent)),
            ],
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final colors = widget.colors;
    final isSelected = widget.isSelected;

    return MouseRegion(
      onEnter: (_) => setState(() => _isHovered = true),
      onExit: (_) => setState(() => _isHovered = false),
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 120),
        color: isSelected
            ? colors.accent.withValues(alpha: 0.15)
            : _isHovered
            ? colors.accent.withValues(alpha: 0.06)
            : Colors.transparent,
        child: ListTile(
          contentPadding: const EdgeInsets.only(
            left: 12,
            right: 4,
            top: 2,
            bottom: 2,
          ),
          onTap: widget.onTap,
          leading: Stack(
            children: [
              CircleAvatar(
                radius: 22,
                backgroundColor: isSelected
                    ? colors.accent
                    : colors.accent.withValues(alpha: 0.5),
                child: Text(
                  _avatarChar,
                  style: const TextStyle(color: Colors.white, fontSize: 16),
                ),
              ),
              // 连接状态指示灯（仅激活人格显示）
              if (isSelected)
                Positioned(
                  right: 0,
                  bottom: 0,
                  child: Container(
                    width: 12,
                    height: 12,
                    decoration: BoxDecoration(
                      color: _statusColor(widget.wsStatus),
                      shape: BoxShape.circle,
                      border: Border.all(color: colors.sidebar, width: 2),
                    ),
                  ),
                ),
            ],
          ),
          title: Text(
            widget.personaId,
            style: TextStyle(
              fontWeight: isSelected ? FontWeight.w600 : FontWeight.normal,
              color: Theme.of(context).colorScheme.onSurface,
              fontSize: 14,
            ),
          ),
          subtitle: Text(
            isSelected ? '当前激活' : '点击切换',
            style: TextStyle(fontSize: 11, color: colors.subtext),
          ),
          trailing: AnimatedOpacity(
            opacity: _isHovered || isSelected ? 1.0 : 0.0,
            duration: const Duration(milliseconds: 150),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (widget.dragHandle != null) widget.dragHandle!,
                Builder(
                  builder: (ctx) => IconButton(
                    icon: Icon(
                      Icons.more_vert_rounded,
                      size: 18,
                      color: colors.subtext,
                    ),
                    tooltip: '更多操作',
                    onPressed: () => _showMenu(ctx),
                    splashRadius: 16,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Color _statusColor(WsStatus s) => switch (s) {
    WsStatus.connected => const Color(0xFF4CAF50),
    WsStatus.connecting => const Color(0xFFFFC107),
    WsStatus.disconnected => const Color(0xFF9E9E9E),
  };
}

class _SettingsDialog extends StatelessWidget {
  final WsService ws;
  final LumiColors colors;

  const _SettingsDialog({required this.ws, required this.colors});

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
  ) async {
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
        if (_isLocalHostUrl(currentUrl)) {
          nextUrl = 'ws://192.168.1.10:8765';
        }
        break;
      case ConnectionMode.publicTunnel:
        if (_isLocalHostUrl(currentUrl)) {
          nextUrl = 'wss://your-domain.example.com/ws';
        }
        break;
    }

    settings.setConnectionMode(mode);
    settings.setRemoteClientMode(shouldUseRemote);
    await ws.setServerUrl(nextUrl, reconnectIfConnected: false);
  }

  Future<void> _showConnectionModeSelector(BuildContext context) async {
    final settings = context.read<AppSettings>();
    var selected = settings.connectionMode;

    final localLabel = _supportsLocalHostLifecycle
        ? '本机/USB 调试 (127.0.0.1)'
        : 'USB 调试转发 (127.0.0.1)';

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('连接方式'),
              content: SizedBox(
                width: (MediaQuery.of(dialogContext).size.width * 0.9).clamp(
                  280.0,
                  420.0,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    RadioListTile<ConnectionMode>(
                      value: ConnectionMode.localOrUsb,
                      groupValue: selected,
                      contentPadding: EdgeInsets.zero,
                      title: Text(localLabel),
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
                      subtitle: const Text('ws://192.168.x.x:8765'),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => selected = value);
                      },
                    ),
                    RadioListTile<ConnectionMode>(
                      value: ConnectionMode.publicTunnel,
                      groupValue: selected,
                      contentPadding: EdgeInsets.zero,
                      title: const Text('公网/内网穿透'),
                      subtitle: const Text('wss://your-domain.example.com/ws'),
                      onChanged: (value) {
                        if (value == null) return;
                        setState(() => selected = value);
                      },
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    await _applyConnectionMode(dialogContext, selected);
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: const Text('应用'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showServerUrlEditor(BuildContext context) async {
    final controller = TextEditingController(text: ws.serverUrl);
    String? errorText;

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return StatefulBuilder(
          builder: (context, setState) {
            return AlertDialog(
              title: const Text('Host 地址'),
              content: SizedBox(
                width: (MediaQuery.of(dialogContext).size.width * 0.9).clamp(
                  280.0,
                  420.0,
                ),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    TextField(
                      controller: controller,
                      autofocus: true,
                      decoration: InputDecoration(
                        labelText: 'WebSocket 地址',
                        hintText: 'ws://127.0.0.1:8765 或 192.168.1.10:8765',
                        errorText: errorText,
                      ),
                    ),
                    const SizedBox(height: 8),
                    Text(
                      '留空将恢复默认地址 ws://127.0.0.1:8765',
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).hintColor,
                      ),
                    ),
                  ],
                ),
              ),
              actions: [
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('取消'),
                ),
                FilledButton(
                  onPressed: () async {
                    try {
                      await ws.setServerUrl(controller.text);
                      if (dialogContext.mounted) {
                        Navigator.of(dialogContext).pop();
                      }
                    } on FormatException catch (e) {
                      setState(() {
                        errorText = e.message;
                      });
                    }
                  },
                  child: const Text('保存'),
                ),
              ],
            );
          },
        );
      },
    );
  }

  Future<void> _showAccessKeyEditor(BuildContext context) async {
    final controller = TextEditingController(text: ws.accessKey);

    await showDialog<void>(
      context: context,
      builder: (dialogContext) {
        return AlertDialog(
          title: const Text('接入密钥'),
          content: SizedBox(
            width: (MediaQuery.of(dialogContext).size.width * 0.9).clamp(
              280.0,
              420.0,
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                TextField(
                  controller: controller,
                  autofocus: true,
                  obscureText: true,
                  decoration: const InputDecoration(
                    labelText: 'Access Key',
                    hintText: '为空表示不发送密钥',
                  ),
                ),
                const SizedBox(height: 8),
                Text(
                  '该密钥仅保存在本机，用于 CONNECT 握手校验。',
                  style: TextStyle(
                    fontSize: 12,
                    color: Theme.of(context).hintColor,
                  ),
                ),
              ],
            ),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(),
              child: const Text('取消'),
            ),
            FilledButton(
              onPressed: () async {
                await ws.setAccessKey(controller.text);
                if (dialogContext.mounted) {
                  Navigator.of(dialogContext).pop();
                }
              },
              child: const Text('保存'),
            ),
          ],
        );
      },
    );
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    final bootstrap = context.read<BootstrapService>();
    final user = ws.user;
    final screen = MediaQuery.of(context).size;
    final dialogWidth = (screen.width * 0.94).clamp(320.0, 560.0);
    final dialogMaxHeight = screen.height * 0.78;

    return AlertDialog(
      backgroundColor: colors.sidebar,
      title: Text(
        '偏好设置',
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurface,
          fontSize: 18,
          fontWeight: FontWeight.bold,
        ),
      ),
      content: SizedBox(
        width: dialogWidth,
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: dialogMaxHeight),
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 账号信息卡片
                Container(
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: colors.inputBg,
                    borderRadius: BorderRadius.circular(8),
                  ),
                  child: Row(
                    children: [
                      CircleAvatar(
                        backgroundColor: colors.accent,
                        child: const Icon(Icons.person, color: Colors.white),
                      ),
                      const SizedBox(width: 12),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: [
                            Text(
                              user?['username'] ?? '未知用户',
                              style: TextStyle(
                                color: Theme.of(context).colorScheme.onSurface,
                                fontWeight: FontWeight.bold,
                              ),
                            ),
                            Text(
                              'ID: ${user?['id'] ?? '-'}',
                              style: TextStyle(
                                color: colors.subtext,
                                fontSize: 12,
                              ),
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // 应用与系统设置
                Padding(
                  padding: const EdgeInsets.only(left: 4, bottom: 8),
                  child: Text(
                    '应用与系统',
                    style: TextStyle(
                      color: colors.accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                Container(
                  decoration: BoxDecoration(
                    color: colors.inputBg,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(
                      color: colors.divider.withValues(alpha: 0.1),
                    ),
                  ),
                  child: Column(
                    children: [
                      // 1. 字体
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.font_download_outlined,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '应用字体',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        trailing: DropdownButtonHideUnderline(
                          child: DropdownButton<String>(
                            value: settings.fontKey,
                            dropdownColor: colors.inputBg,
                            icon: Icon(
                              Icons.expand_more,
                              size: 16,
                              color: colors.subtext,
                            ),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 13,
                            ),
                            items: kAvailableFonts.entries
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null) settings.setFontFamily(val);
                            },
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 2. 退出行为
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.close_fullscreen,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '关闭窗口动作',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          '点击系统关闭按钮时...',
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: DropdownButtonHideUnderline(
                          child: DropdownButton<WindowCloseAction>(
                            value: settings.windowCloseAction,
                            dropdownColor: colors.inputBg,
                            icon: Icon(
                              Icons.expand_more,
                              size: 16,
                              color: colors.subtext,
                            ),
                            style: TextStyle(
                              color: Theme.of(context).colorScheme.onSurface,
                              fontSize: 13,
                            ),
                            items: kWindowCloseActionLabels.entries
                                .map(
                                  (e) => DropdownMenuItem(
                                    value: e.key,
                                    child: Text(e.value),
                                  ),
                                )
                                .toList(),
                            onChanged: (val) {
                              if (val != null) {
                                settings.setWindowCloseAction(val);
                              }
                            },
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 3. 随前端关闭 AstrBot
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.power_settings_new,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '同步关闭 AstrBot',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          '完全退出时结束核心进程',
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Transform.scale(
                          scale: 0.8,
                          child: Switch(
                            value: settings.closeAstrBotOnExit,
                            onChanged: settings.setCloseAstrBotOnExit,
                            activeThumbColor: colors.accent,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 4. 连接方式
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.router_outlined,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '连接方式',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          kConnectionModeLabels[settings.connectionMode] ??
                              '未设置',
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.edit,
                          color: colors.subtext,
                          size: 16,
                        ),
                        onTap: () => _showConnectionModeSelector(context),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 5. 每次启动询问连接方式
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.help_outline,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '每次启动询问连接方式',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          settings.askConnectionModeOnLaunch
                              ? '已开启：每次都会弹出选择'
                              : '已关闭：自动使用已保存模式',
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Transform.scale(
                          scale: 0.8,
                          child: Switch(
                            value: settings.askConnectionModeOnLaunch,
                            onChanged: settings.setAskConnectionModeOnLaunch,
                            activeThumbColor: colors.accent,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 6. AI 语音输出
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.record_voice_over_outlined,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          'AI 回复语音转换',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          settings.enableAiVoiceOutput
                              ? '已开启：回复将先显示文字，再后台生成语音'
                              : '已关闭：保持纯文字聊天',
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Transform.scale(
                          scale: 0.8,
                          child: Switch(
                            value: settings.enableAiVoiceOutput,
                            onChanged: settings.setEnableAiVoiceOutput,
                            activeThumbColor: colors.accent,
                            materialTapTargetSize:
                                MaterialTapTargetSize.shrinkWrap,
                          ),
                        ),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 7. 语音配置
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.tune,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '语音配置',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          settings.ttsVoiceId.isEmpty
                              ? '未设置 voice_id'
                              : settings.ttsVoiceId,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.open_in_new,
                          color: colors.subtext,
                          size: 16,
                        ),
                        onTap: () {
                          showDialog<void>(
                            context: context,
                            builder: (_) =>
                                const VoiceSettingsScreen(showAsDialog: true),
                          );
                        },
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 8. 打开日志目录
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.folder_open,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '打开日志目录',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          bootstrap.logDirectoryPath ?? '日志目录尚未初始化',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.open_in_new,
                          color: colors.subtext,
                          size: 16,
                        ),
                        onTap: bootstrap.openLogDirectory,
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 9. Host 地址
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.dns_outlined,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          'Host 地址',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          ws.serverUrl,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.edit,
                          color: colors.subtext,
                          size: 16,
                        ),
                        onTap: () => _showServerUrlEditor(context),
                      ),
                      Divider(
                        height: 1,
                        color: colors.divider.withValues(alpha: 0.2),
                        indent: 48,
                      ),

                      // 10. 接入密钥
                      ListTile(
                        contentPadding: const EdgeInsets.only(
                          left: 16,
                          right: 8,
                        ),
                        leading: Icon(
                          Icons.vpn_key_outlined,
                          color: colors.subtext,
                          size: 20,
                        ),
                        title: Text(
                          '接入密钥',
                          style: TextStyle(
                            fontSize: 14,
                            color: Theme.of(context).colorScheme.onSurface,
                          ),
                        ),
                        subtitle: Text(
                          ws.accessKey.isEmpty ? '未设置' : '已设置（已隐藏）',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(color: colors.subtext, fontSize: 12),
                        ),
                        trailing: Icon(
                          Icons.edit,
                          color: colors.subtext,
                          size: 16,
                        ),
                        onTap: () => _showAccessKeyEditor(context),
                      ),
                    ],
                  ),
                ),
                const SizedBox(height: 24),

                // 注销按钮
                SizedBox(
                  width: double.infinity,
                  child: OutlinedButton.icon(
                    style: OutlinedButton.styleFrom(
                      foregroundColor: Colors.redAccent,
                      side: const BorderSide(color: Colors.redAccent),
                      padding: const EdgeInsets.symmetric(vertical: 12),
                    ),
                    icon: const Icon(Icons.logout, size: 18),
                    label: const Text('注销登录'),
                    onPressed: () async {
                      await ws.logout();
                      if (context.mounted) Navigator.pop(context);
                    },
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.pop(context),
          child: Text('关闭', style: TextStyle(color: colors.subtext)),
        ),
      ],
    );
  }
}

// ─── 顶部栏 ─────────────────────────────────────────────────────────────────

class _TopBar extends StatelessWidget {
  final LumiColors colors;
  final WsService ws;
  final String activePersonaId;
  final bool isSelectionMode;
  final int selectedCount;
  final VoidCallback onCancelSelection;
  final VoidCallback onDeleteSelected;
  final VoidCallback? onOpenSidebar;

  const _TopBar({
    required this.colors,
    required this.ws,
    required this.activePersonaId,
    this.isSelectionMode = false,
    this.selectedCount = 0,
    required this.onCancelSelection,
    required this.onDeleteSelected,
    this.onOpenSidebar,
  });

  @override
  Widget build(BuildContext context) {
    if (isSelectionMode) {
      return SafeArea(
        bottom: false,
        child: Container(
          height: 56,
          padding: const EdgeInsets.symmetric(horizontal: 16),
          color: colors.sidebar,
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.close, color: colors.subtext),
                onPressed: onCancelSelection,
                tooltip: '取消多选',
              ),
              const SizedBox(width: 8),
              Text(
                '已选择 $selectedCount 项',
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w500,
                  color: Theme.of(context).colorScheme.onSurface,
                ),
              ),
              const Spacer(),
              if (selectedCount > 0)
                IconButton(
                  icon: const Icon(
                    Icons.delete_outline,
                    color: Colors.redAccent,
                  ),
                  onPressed: () {
                    showDialog(
                      context: context,
                      builder: (context) => AlertDialog(
                        title: const Text('删除消息'),
                        content: Text('确定要删除选中的 $selectedCount 条消息吗？'),
                        actions: [
                          TextButton(
                            onPressed: () => Navigator.pop(context),
                            child: const Text('取消'),
                          ),
                          TextButton(
                            onPressed: () {
                              Navigator.pop(context);
                              onDeleteSelected();
                            },
                            child: const Text(
                              '删除',
                              style: TextStyle(color: Colors.red),
                            ),
                          ),
                        ],
                      ),
                    );
                  },
                  tooltip: '删除选中项',
                ),
            ],
          ),
        ),
      );
    }

    final statusText = switch (ws.status) {
      WsStatus.connected => '在线',
      WsStatus.connecting => '连接中...',
      WsStatus.disconnected => '未连接',
    };
    final statusColor = switch (ws.status) {
      WsStatus.connected => const Color(0xFF4CAF50),
      WsStatus.connecting => const Color(0xFFFFC107),
      WsStatus.disconnected => const Color(0xFF9E9E9E),
    };

    return SafeArea(
      bottom: false,
      child: Container(
        height: 56,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Row(
          children: [
            if (onOpenSidebar != null) ...[
              IconButton(
                icon: Icon(Icons.menu_rounded, color: colors.subtext),
                onPressed: onOpenSidebar,
                tooltip: '打开侧边栏',
              ),
              const SizedBox(width: 4),
            ],
            CircleAvatar(
              radius: 18,
              backgroundColor: colors.accent,
              child: Text(
                activePersonaId.isNotEmpty
                    ? activePersonaId[0].toUpperCase()
                    : '?',
                style: const TextStyle(color: Colors.white),
              ),
            ),
            const SizedBox(width: 12),
            Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  activePersonaId.isNotEmpty ? activePersonaId : '未选择人格',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    fontSize: 15,
                    color: Theme.of(context).colorScheme.onSurface,
                  ),
                ),
                Row(
                  children: [
                    Container(
                      width: 8,
                      height: 8,
                      margin: const EdgeInsets.only(right: 4),
                      decoration: BoxDecoration(
                        color: statusColor,
                        shape: BoxShape.circle,
                      ),
                    ),
                    Text(
                      statusText,
                      style: TextStyle(fontSize: 12, color: colors.subtext),
                    ),
                  ],
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}

// ─── 消息列表 ────────────────────────────────────────────────────────────────
