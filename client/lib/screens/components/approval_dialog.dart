import 'dart:ui';
import 'package:flutter/material.dart';

class ApprovalDialog extends StatelessWidget {
  final Map<String, dynamic> authRequest;
  final Function(String decision) onDecision;

  const ApprovalDialog({
    super.key,
    required this.authRequest,
    required this.onDecision,
  });

  @override
  Widget build(BuildContext context) {
    final payload = authRequest['payload'] as Map<String, dynamic>? ?? {};
    final actionType = payload['action_type'] as String? ?? 'COMMAND_RUN';
    final targetPath = payload['target_path'] as String? ?? 'N/A';
    final description = payload['description'] as String? ?? '';
    final diffPreview = payload['diff_preview'] as String? ?? '';
    final theme = Theme.of(context);

    final isCommand = actionType == 'COMMAND_RUN';
    final isDelete = actionType == 'FILE_DELETE';

    final Color badgeColor = isDelete
        ? Colors.redAccent
        : (isCommand ? Colors.cyanAccent : Colors.amberAccent);
    final IconData badgeIcon = isDelete
        ? Icons.delete_forever_rounded
        : (isCommand ? Icons.terminal_rounded : Icons.security_rounded);
    final String titleText = isDelete
        ? '物理删除确认 (File Delete)'
        : (isCommand ? '终端命令执行审批 (Shell Command)' : '高危操作审批');

    return BackdropFilter(
      filter: ImageFilter.blur(sigmaX: 12, sigmaY: 12),
      child: Dialog(
        backgroundColor: Colors.transparent,
        elevation: 0,
        insetPadding: const EdgeInsets.symmetric(horizontal: 20, vertical: 24),
        child: Container(
          constraints: const BoxConstraints(maxWidth: 540),
          decoration: BoxDecoration(
            color: theme.colorScheme.surface.withValues(alpha: 0.9),
            borderRadius: BorderRadius.circular(24),
            border: Border.all(
              color: Colors.white.withValues(alpha: 0.15),
              width: 1.2,
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.4),
                blurRadius: 36,
                spreadRadius: 4,
                offset: const Offset(0, 10),
              ),
            ],
          ),
          child: Padding(
            padding: const EdgeInsets.all(24.0),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                // 顶部标题
                Row(
                  children: [
                    Container(
                      padding: const EdgeInsets.all(12),
                      decoration: BoxDecoration(
                        color: badgeColor.withValues(alpha: 0.15),
                        borderRadius: BorderRadius.circular(14),
                        border: Border.all(
                          color: badgeColor.withValues(alpha: 0.3),
                          width: 1,
                        ),
                      ),
                      child: Icon(badgeIcon, color: badgeColor, size: 24),
                    ),
                    const SizedBox(width: 16),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: [
                          Text(
                            titleText,
                            style: theme.textTheme.titleMedium?.copyWith(
                              fontSize: 18,
                              fontWeight: FontWeight.bold,
                            ),
                          ),
                          const SizedBox(height: 2),
                          Text(
                            '单次授权确认 · 超时 60 秒将自动安全拒绝 (Fail-Closed)',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: Colors.grey,
                              fontSize: 11,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 20),

                // 目标路径或命令
                _buildInfoRow(
                  isCommand ? '命令行' : '目标路径',
                  targetPath,
                  badgeColor,
                  isCode: isCommand,
                ),
                const SizedBox(height: 12),

                // 描述信息
                if (description.isNotEmpty) ...[
                  Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      const SizedBox(
                        width: 70,
                        child: Text(
                          '说明:',
                          style: TextStyle(
                            color: Colors.grey,
                            fontWeight: FontWeight.w500,
                            fontSize: 13,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          description,
                          style: theme.textTheme.bodyMedium?.copyWith(
                            height: 1.4,
                          ),
                        ),
                      ),
                    ],
                  ),
                ],

                // 终端命令或 Diff 预览区
                if (diffPreview.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(
                    width: double.infinity,
                    constraints: const BoxConstraints(maxHeight: 180),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(
                      color: Colors.black.withValues(alpha: 0.35),
                      borderRadius: BorderRadius.circular(10),
                      border: Border.all(
                        color: Colors.white.withValues(alpha: 0.08),
                        width: 1,
                      ),
                    ),
                    child: SingleChildScrollView(
                      child: SelectableText(
                        diffPreview,
                        style: const TextStyle(
                          fontFamily: 'monospace',
                          fontSize: 12,
                          color: Color(0xFF68D391), // light green monospace
                          height: 1.4,
                        ),
                      ),
                    ),
                  ),
                ],
                const SizedBox(height: 24),

                // 底部按钮
                Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    OutlinedButton(
                      onPressed: () => onDecision('REJECTED'),
                      style: OutlinedButton.styleFrom(
                        padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                        side: BorderSide(color: Colors.white.withValues(alpha: 0.2)),
                        foregroundColor: Colors.grey,
                      ),
                      child: const Text('拒绝 (Reject)'),
                    ),
                    const SizedBox(width: 12),
                    FilledButton(
                      onPressed: () => onDecision('APPROVED'),
                      style: FilledButton.styleFrom(
                        backgroundColor: isDelete ? Colors.redAccent : theme.colorScheme.primary,
                        foregroundColor: Colors.white,
                        padding: const EdgeInsets.symmetric(horizontal: 28, vertical: 12),
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(12),
                        ),
                      ),
                      child: const Text(
                        '批准执行 (Allow Once)',
                        style: TextStyle(fontWeight: FontWeight.bold),
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildInfoRow(String label, String value, Color color, {bool isCode = false}) {
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        SizedBox(
          width: 70,
          child: Text(
            label,
            style: const TextStyle(
              color: Colors.grey,
              fontWeight: FontWeight.w500,
              fontSize: 13,
            ),
          ),
        ),
        Expanded(
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
            decoration: BoxDecoration(
              color: color.withValues(alpha: 0.1),
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: color.withValues(alpha: 0.25), width: 0.8),
            ),
            child: SelectableText(
              isCode ? '\$ $value' : value,
              style: TextStyle(
                color: color,
                fontFamily: isCode ? 'monospace' : null,
                fontWeight: FontWeight.w600,
                fontSize: 13,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
