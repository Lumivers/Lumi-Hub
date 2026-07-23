import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'components/connection_settings_dialog.dart';
import 'llm_settings_screen.dart';
import '../services/app_settings.dart';
import '../services/bootstrap_service.dart';
import '../services/ws_service.dart';

class BootstrapScreen extends StatefulWidget {
  const BootstrapScreen({super.key});

  @override
  State<BootstrapScreen> createState() => _BootstrapScreenState();
}

class _BootstrapScreenState extends State<BootstrapScreen> {
  bool _bootTriggered = bool.fromEnvironment('dart.vm.product') == false ? false : false;

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

  Future<void> _prepareAndStart() async {
    if (_bootTriggered || !mounted) return;
    _bootTriggered = true;

    final settings = context.read<AppSettings>();
    await settings.loaded;
    if (!mounted) return;

    if (settings.askConnectionModeOnLaunch) {
      await _showConnectionModeDialog(context);
    }

    if (!mounted) return;
    await context.read<BootstrapService>().ensureStarted();
  }

  void _openLlmSettings() async {
    await Navigator.of(context).push(
      MaterialPageRoute(builder: (_) => const LlmSettingsScreen()),
    );
    // 从设置页返回后刷新 LLM 配置状态
    if (mounted) {
      context.read<BootstrapService>().refreshLlmStatus();
    }
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
                    child: const Icon(Icons.rocket_launch, color: Colors.white, size: 28),
                  ),
                  const SizedBox(width: 14),
                  const Expanded(
                    child: Text(
                      'Lumi-Hub',
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.bold),
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

              // 进度条或错误提示
              if (!bootstrap.hasFailed && !bootstrap.isReady)
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
                    style: TextStyle(color: Theme.of(context).colorScheme.onErrorContainer),
                  ),
                ),

              // LLM 未配置提示
              if (bootstrap.isReady && !bootstrap.llmConfigured) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.smart_toy, size: 48, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 12),
                      Text(
                        '配置 AI 服务',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'LLM 尚未配置，请先设置 API Key 才能开始对话。',
                        textAlign: TextAlign.center,
                        style: Theme.of(context).textTheme.bodyMedium,
                      ),
                      const SizedBox(height: 16),
                      FilledButton.icon(
                        onPressed: _openLlmSettings,
                        icon: const Icon(Icons.settings),
                        label: const Text('去配置'),
                      ),
                    ],
                  ),
                ),
              ],

              // 启动成功提示
              if (bootstrap.isReady && bootstrap.llmConfigured) ...[
                const SizedBox(height: 16),
                Container(
                  padding: const EdgeInsets.all(16),
                  decoration: BoxDecoration(
                    color: Theme.of(context).colorScheme.primaryContainer,
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: Column(
                    children: [
                      Icon(Icons.check_circle, size: 48, color: Theme.of(context).colorScheme.primary),
                      const SizedBox(height: 12),
                      Text(
                        '准备就绪',
                        style: Theme.of(context).textTheme.titleMedium?.copyWith(
                          fontWeight: FontWeight.bold,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'AI: ${bootstrap.llmProvider} (${bootstrap.llmModel})',
                        style: Theme.of(context).textTheme.bodySmall,
                      ),
                    ],
                  ),
                ),
              ],

              const SizedBox(height: 16),

              // 日志区域
              Container(
                height: 180,
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
                      case LogLevel.warning:
                        color = Colors.orange;
                      case LogLevel.debug:
                        color = Colors.grey;
                      case LogLevel.info:
                        color = Theme.of(context).colorScheme.onSurfaceVariant;
                    }
                    return Padding(
                      padding: const EdgeInsets.symmetric(vertical: 2),
                      child: Text(
                        log.toString(),
                        style: TextStyle(fontFamily: 'Consolas', fontSize: 12, color: color),
                      ),
                    );
                  },
                ),
              ),
              const SizedBox(height: 16),

              // 底部按钮
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  OutlinedButton.icon(
                    onPressed: () {
                      final ws = context.read<WsService>();
                      final settings = context.read<AppSettings>();
                      ConnectionSettingsDialog.show(
                        context,
                        ws: ws,
                        settings: settings,
                        title: '连接设置',
                        confirmText: '保存',
                        barrierDismissible: true,
                        allowCancel: true,
                      );
                    },
                    icon: const Icon(Icons.tune, size: 16),
                    label: const Text('连接设置'),
                  ),
                  if (bootstrap.isReady) ...[
                    const SizedBox(width: 8),
                    OutlinedButton.icon(
                      onPressed: _openLlmSettings,
                      icon: const Icon(Icons.smart_toy, size: 16),
                      label: const Text('LLM 设置'),
                    ),
                  ],
                  if (bootstrap.hasFailed) ...[
                    const SizedBox(width: 8),
                    FilledButton.icon(
                      onPressed: bootstrap.retry,
                      icon: const Icon(Icons.refresh),
                      label: const Text('重试'),
                    ),
                  ],
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
