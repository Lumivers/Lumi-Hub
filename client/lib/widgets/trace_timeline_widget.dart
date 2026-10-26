import 'package:flutter/material.dart';
import '../theme/app_theme.dart';

/// 渲染 Agent 执行步骤的折叠时间线组件 (Step Trace Timeline)
class TraceTimelineWidget extends StatefulWidget {
  final List<Map<String, dynamic>> traces;
  final LumiColors colors;
  final bool isGenerating;

  const TraceTimelineWidget({
    super.key,
    required this.traces,
    required this.colors,
    this.isGenerating = false,
  });

  @override
  State<TraceTimelineWidget> createState() => _TraceTimelineWidgetState();
}

class _TraceTimelineWidgetState extends State<TraceTimelineWidget> {
  bool _isExpanded = false;
  final Set<int> _expandedSteps = <int>{};

  @override
  void initState() {
    super.initState();
    // 如果仍在生成中，默认展开
    if (widget.isGenerating) {
      _isExpanded = true;
    }
  }

  @override
  void didUpdateWidget(covariant TraceTimelineWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isGenerating && widget.isGenerating) {
      _isExpanded = true;
    }
  }

  int get _totalDurationMs {
    int total = 0;
    for (final t in widget.traces) {
      final dur = t['duration_ms'];
      if (dur is num) total += dur.toInt();
    }
    return total;
  }

  bool get _hasError {
    return widget.traces.any((t) => t['status'] == 'error');
  }

  String _formatDuration(int ms) {
    if (ms < 1000) return '${ms}ms';
    return '${(ms / 1000).toStringAsFixed(1)}s';
  }

  @override
  Widget build(BuildContext context) {
    if (widget.traces.isEmpty) {
      return const SizedBox.shrink();
    }

    final hasRunning = widget.traces.any((t) => t['status'] == 'running');

    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      decoration: BoxDecoration(
        color: widget.colors.sidebar.withValues(alpha: 0.5),
        borderRadius: BorderRadius.circular(8),
        border: Border.all(
          color: _hasError
              ? Colors.redAccent.withValues(alpha: 0.4)
              : widget.colors.divider,
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // 头部：总览与折叠触发器
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Row(
                children: [
                  Icon(
                    hasRunning
                        ? Icons.motion_photos_on_rounded
                        : _hasError
                        ? Icons.warning_amber_rounded
                        : Icons.account_tree_outlined,
                    size: 14,
                    color: hasRunning
                        ? widget.colors.accent
                        : _hasError
                        ? Colors.redAccent
                        : widget.colors.accent,
                  ),
                  const SizedBox(width: 6),
                  Text(
                    '执行链路 (${widget.traces.length} 步)',
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: widget.colors.onBubbleThem.withValues(alpha: 0.9),
                    ),
                  ),
                  const Spacer(),
                  if (_totalDurationMs > 0)
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      margin: const EdgeInsets.only(right: 6),
                      decoration: BoxDecoration(
                        color: widget.colors.inputBg.withValues(alpha: 0.8),
                        borderRadius: BorderRadius.circular(4),
                      ),
                      child: Text(
                        _formatDuration(_totalDurationMs),
                        style: TextStyle(
                          fontSize: 10,
                          color: widget.colors.subtext,
                          fontFamilyFallback: AppTheme.monoFonts,
                        ),
                      ),
                    ),
                  Icon(
                    _isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 16,
                    color: widget.colors.subtext,
                  ),
                ],
              ),
            ),
          ),

          // 展开项：详细步骤列表
          if (_isExpanded) ...[
            Divider(height: 1, color: widget.colors.divider),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(
                children: widget.traces.map((step) {
                  final stepId = step['step_id'] as int? ?? 0;
                  final toolName = step['tool_name'] as String? ?? 'tool';
                  final status = step['status'] as String? ?? 'running';
                  final durMs = (step['duration_ms'] as num?)?.toInt() ?? 0;
                  final exitCode = step['exit_code'] as int?;
                  final outputSummary =
                      step['output_summary'] as String? ?? '';
                  final isStepExpanded = _expandedSteps.contains(stepId);
                  final toolArgs = step['tool_args'] as Map<String, dynamic>? ?? {};

                  return Container(
                    margin: const EdgeInsets.only(bottom: 4),
                    padding: const EdgeInsets.all(6),
                    decoration: BoxDecoration(
                      color: widget.colors.inputBg.withValues(alpha: 0.4),
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        InkWell(
                          onTap: () {
                            setState(() {
                              if (isStepExpanded) {
                                _expandedSteps.remove(stepId);
                              } else {
                                _expandedSteps.add(stepId);
                              }
                            });
                          },
                          child: Row(
                            children: [
                              // 状态小圆点/图标
                              if (status == 'running')
                                SizedBox(
                                  width: 10,
                                  height: 10,
                                  child: CircularProgressIndicator(
                                    strokeWidth: 1.5,
                                    valueColor: AlwaysStoppedAnimation<Color>(
                                      widget.colors.accent,
                                    ),
                                  ),
                                )
                              else if (status == 'error')
                                const Icon(
                                  Icons.error_outline_rounded,
                                  size: 12,
                                  color: Colors.redAccent,
                                )
                              else
                                const Icon(
                                  Icons.check_circle_outline_rounded,
                                  size: 12,
                                  color: Colors.greenAccent,
                                ),
                              const SizedBox(width: 6),

                              // 工具名称
                              Text(
                                'Step $stepId: $toolName',
                                style: TextStyle(
                                  fontSize: 11,
                                  fontWeight: FontWeight.bold,
                                  fontFamilyFallback: AppTheme.monoFonts,
                                  color: status == 'error'
                                      ? Colors.redAccent
                                      : widget.colors.onBubbleThem,
                                ),
                              ),
                              const Spacer(),

                              // 退出码
                              if (exitCode != null)
                                Container(
                                  padding: const EdgeInsets.symmetric(
                                    horizontal: 4,
                                    vertical: 1,
                                  ),
                                  margin: const EdgeInsets.only(right: 6),
                                  decoration: BoxDecoration(
                                    color: exitCode == 0
                                        ? Colors.green.withValues(alpha: 0.2)
                                        : Colors.red.withValues(alpha: 0.2),
                                    borderRadius: BorderRadius.circular(3),
                                  ),
                                  child: Text(
                                    'exit $exitCode',
                                    style: TextStyle(
                                      fontSize: 9,
                                      fontFamilyFallback: AppTheme.monoFonts,
                                      color: exitCode == 0
                                          ? Colors.greenAccent
                                          : Colors.redAccent,
                                    ),
                                  ),
                                ),

                              // 耗时
                              Text(
                                '${durMs}ms',
                                style: TextStyle(
                                  fontSize: 10,
                                  color: widget.colors.subtext,
                                  fontFamilyFallback: AppTheme.monoFonts,
                                ),
                              ),
                              const SizedBox(width: 4),
                              Icon(
                                isStepExpanded
                                    ? Icons.expand_less
                                    : Icons.expand_more,
                                size: 12,
                                color: widget.colors.subtext,
                              ),
                            ],
                          ),
                        ),

                        // 点击展开入参及输出预览
                        if (isStepExpanded) ...[
                          const SizedBox(height: 4),
                          if (toolArgs.isNotEmpty)
                            Container(
                              width: double.infinity,
                              margin: const EdgeInsets.only(bottom: 4),
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.black26,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                'Args: $toolArgs',
                                style: TextStyle(
                                  fontSize: 10,
                                  fontFamilyFallback: AppTheme.monoFonts,
                                  color: widget.colors.subtext,
                                ),
                                maxLines: 3,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                          if (outputSummary.isNotEmpty)
                            Container(
                              width: double.infinity,
                              padding: const EdgeInsets.all(4),
                              decoration: BoxDecoration(
                                color: Colors.black38,
                                borderRadius: BorderRadius.circular(4),
                              ),
                              child: Text(
                                outputSummary,
                                style: TextStyle(
                                  fontSize: 10,
                                  fontFamilyFallback: AppTheme.monoFonts,
                                  color: widget.colors.onBubbleThem.withValues(
                                    alpha: 0.8,
                                  ),
                                ),
                                maxLines: 6,
                                overflow: TextOverflow.ellipsis,
                              ),
                            ),
                        ],
                      ],
                    ),
                  );
                }).toList(),
              ),
            ),
          ],
        ],
      ),
    );
  }
}
