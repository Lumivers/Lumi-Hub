import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import '../services/bootstrap_service.dart';

class BootstrapScreen extends StatelessWidget {
  const BootstrapScreen({super.key});

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
                    const Expanded(
                      child: Text(
                        '启动流程：环境检查 -> AstrBot 检测/拉起 -> Host 连通性确认 -> 登录',
                        style: TextStyle(fontSize: 12),
                      ),
                    ),
                  if (bootstrap.hasFailed)
                    const Spacer(),
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
