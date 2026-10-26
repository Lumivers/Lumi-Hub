import 'dart:async';
import 'dart:math' as math;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import '../theme/app_theme.dart';

/// 渲染 Agent 执行步骤的折叠时间线组件 (Step Trace Timeline)
/// 严格还原 IDE 级的现代 Agent 思考与工作流折叠卡片 (Image 1 风格)
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
  Timer? _liveTimer;
  late DateTime _startTime;

  @override
  void initState() {
    super.initState();
    _startTime = DateTime.now();
    // 生成中默认展开以展示实时进度，生成结束后默认收起为单行摘要
    if (widget.isGenerating) {
      _isExpanded = true;
      _startLiveTimer();
    }
  }

  void _startLiveTimer() {
    _liveTimer?.cancel();
    _liveTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      if (mounted) setState(() {});
    });
  }

  @override
  void didUpdateWidget(covariant TraceTimelineWidget oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (!oldWidget.isGenerating && widget.isGenerating) {
      _isExpanded = true;
      _startTime = DateTime.now();
      _startLiveTimer();
    } else if (oldWidget.isGenerating && !widget.isGenerating) {
      _liveTimer?.cancel();
    }
  }

  @override
  void dispose() {
    _liveTimer?.cancel();
    super.dispose();
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
    final sec = ms / 1000;
    if (sec < 60) return '${sec.toStringAsFixed(1)}s';
    final min = (sec / 60).floor();
    final remSec = (sec % 60).round();
    return '${min}m ${remSec}s';
  }

  /// 智能解析生成清晰、具体的可读指令标题（如：Ran: git status / Read main.dart）
  String _formatStepTitle(String toolName, Map<String, dynamic> args) {
    switch (toolName) {
      case 'run_command':
        final cmd = args['command'] ?? args['CommandLine'] ?? args['cmd'] ?? '';
        if (cmd.toString().isNotEmpty) {
          final s = cmd.toString().trim();
          final firstLine = s.split('\n').first.trim();
          return firstLine.length > 55
              ? 'Ran: ${firstLine.substring(0, 52)}...'
              : 'Ran: $firstLine';
        }
        return 'Ran command';
      case 'read_file':
      case 'view_file':
        final p = args['path'] ?? args['AbsolutePath'] ?? '';
        if (p.toString().isNotEmpty) {
          final base = p.toString().replaceAll(r'\', '/').split('/').last;
          return 'Read $base';
        }
        return 'Read file';
      case 'write_file':
      case 'insert_content':
      case 'replace_content':
      case 'search_replace':
      case 'edit_file':
        final p = args['path'] ?? args['TargetFile'] ?? '';
        if (p.toString().isNotEmpty) {
          final base = p.toString().replaceAll(r'\', '/').split('/').last;
          return 'Edited $base';
        }
        return 'Edited file';
      case 'grep_code':
      case 'search_workspace':
        final q = args['query'] ?? args['pattern'] ?? '';
        if (q.toString().isNotEmpty) {
          final sq = q.toString().length > 30 ? '${q.toString().substring(0, 28)}...' : q.toString();
          return 'Searched for "$sq"';
        }
        return 'Searched workspace';
      case 'find_symbol':
        final sym = args['symbol'] ?? '';
        if (sym.toString().isNotEmpty) {
          return 'Find symbol "$sym"';
        }
        return 'Find symbol';
      case 'list_dir':
        final p = args['path'] ?? '';
        if (p.toString().isNotEmpty) {
          final base = p.toString().replaceAll(r'\', '/').split('/').last;
          return 'Listed ${base.isEmpty ? "/" : base}';
        }
        return 'Listed directory';
      default:
        for (final k in ['command', 'path', 'query', 'name', 'symbol']) {
          if (args[k] != null && args[k].toString().isNotEmpty) {
            final v = args[k].toString();
            final shortV = v.length > 35 ? '${v.substring(0, 33)}...' : v;
            return '$toolName: $shortV';
          }
        }
        return toolName;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.traces.isEmpty) {
      if (!widget.isGenerating) {
        return const SizedBox.shrink();
      }
      final elapsedMs = DateTime.now().difference(_startTime).inMilliseconds;
      final durStr = _formatDuration(elapsedMs);
      return Container(
        margin: const EdgeInsets.symmetric(vertical: 6),
        padding: const EdgeInsets.symmetric(horizontal: 13, vertical: 8),
        decoration: BoxDecoration(
          color: const Color(0xFF16191E),
          borderRadius: BorderRadius.circular(10),
          border: Border.all(color: const Color(0xFF2D333B), width: 1),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            const SizedBox(
              width: 13,
              height: 13,
              child: CircularProgressIndicator(
                strokeWidth: 2,
                valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF58A6FF)),
              ),
            ),
            const SizedBox(width: 9),
            Text(
              'Thinking ($durStr)...',
              style: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
                color: Color(0xFFC9D1D9),
                fontFamilyFallback: AppTheme.monoFonts,
              ),
            ),
          ],
        ),
      );
    }

    final hasRunning = widget.traces.any((t) => t['status'] == 'running');
    final elapsedMs = widget.isGenerating
        ? DateTime.now().difference(_startTime).inMilliseconds
        : _totalDurationMs;
    final durationStr = _formatDuration(math.max(elapsedMs, _totalDurationMs));
    final headerTitle = widget.isGenerating
        ? 'Working... (${widget.traces.length} steps · $durationStr)'
        : 'Worked for $durationStr (${widget.traces.length} steps)';

    return Container(
      margin: const EdgeInsets.symmetric(vertical: 6),
      decoration: BoxDecoration(
        color: const Color(0xFF16191E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: _hasError
              ? Colors.redAccent.withValues(alpha: 0.4)
              : const Color(0xFF2D333B),
          width: 1,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 卡片头部总览（类似 Image 1：Worked for 16m ∨）──
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  if (hasRunning)
                    const SizedBox(
                      width: 13,
                      height: 13,
                      child: CircularProgressIndicator(
                        strokeWidth: 2,
                        valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF58A6FF)),
                      ),
                    )
                  else if (_hasError)
                    const Icon(
                      Icons.warning_amber_rounded,
                      size: 15,
                      color: Colors.redAccent,
                    )
                  else
                    const Icon(
                      Icons.check_circle_outline_rounded,
                      size: 15,
                      color: Color(0xFF3FB950),
                    ),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      headerTitle,
                      style: TextStyle(
                        fontSize: 12.5,
                        fontWeight: FontWeight.w600,
                        color: hasRunning
                            ? const Color(0xFFE6EDF3)
                            : const Color(0xFF8B949E),
                        fontFamilyFallback: AppTheme.fallbackFonts,
                      ),
                    ),
                  ),
                  Icon(
                    _isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: const Color(0xFF8B949E),
                  ),
                ],
              ),
            ),
          ),

          // ── 展开的具体执行指令与步骤链路 ──
          if (_isExpanded) ...[
            Container(height: 1, color: const Color(0xFF2D333B)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
              child: Column(
                children: [
                  ...widget.traces.map((step) {
                  final stepId = step['step_id'] as int? ?? 0;
                  final toolName = step['tool_name'] as String? ?? 'tool';
                  final status = step['status'] as String? ?? 'running';
                  final durMs = (step['duration_ms'] as num?)?.toInt() ?? 0;
                  final exitCode = step['exit_code'] as int?;
                  final outputSummary = step['output_summary'] as String? ?? '';
                  final isStepExpanded = _expandedSteps.contains(stepId);
                  final toolArgs = (step['tool_args'] as Map?)?.cast<String, dynamic>() ?? const {};
                  final actionTitle = _formatStepTitle(toolName, toolArgs);

                  return Container(
                    margin: const EdgeInsets.symmetric(vertical: 2.5),
                    decoration: BoxDecoration(
                      color: isStepExpanded
                          ? const Color(0xFF1E2228)
                          : Colors.transparent,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        // 单步头部行：图标 + 具体执行指令 + 耗时 + 展开按钮
                        InkWell(
                          borderRadius: BorderRadius.circular(6),
                          onTap: () {
                            setState(() {
                              if (isStepExpanded) {
                                _expandedSteps.remove(stepId);
                              } else {
                                _expandedSteps.add(stepId);
                              }
                            });
                          },
                          child: Padding(
                            padding: const EdgeInsets.symmetric(
                              horizontal: 8,
                              vertical: 6,
                            ),
                            child: Row(
                              children: [
                                if (status == 'running')
                                  const SizedBox(
                                    width: 10,
                                    height: 10,
                                    child: CircularProgressIndicator(
                                      strokeWidth: 1.5,
                                      valueColor: AlwaysStoppedAnimation<Color>(
                                        Color(0xFF58A6FF),
                                      ),
                                    ),
                                  )
                                else if (status == 'error')
                                  const Icon(
                                    Icons.cancel_outlined,
                                    size: 13,
                                    color: Colors.redAccent,
                                  )
                                else
                                  const Icon(
                                    Icons.done_rounded,
                                    size: 13,
                                    color: Color(0xFF3FB950),
                                  ),
                                const SizedBox(width: 8),

                                Expanded(
                                  child: Text(
                                    actionTitle,
                                    style: TextStyle(
                                      fontSize: 12,
                                      fontWeight: FontWeight.w500,
                                      color: status == 'error'
                                          ? Colors.redAccent
                                          : const Color(0xFFC9D1D9),
                                      fontFamilyFallback: AppTheme.monoFonts,
                                    ),
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                  ),
                                ),
                                const SizedBox(width: 6),

                                if (exitCode != null)
                                  Container(
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 4,
                                      vertical: 1,
                                    ),
                                    margin: const EdgeInsets.only(right: 6),
                                    decoration: BoxDecoration(
                                      color: exitCode == 0
                                          ? const Color(0x33238636)
                                          : const Color(0x33DA3633),
                                      borderRadius: BorderRadius.circular(3),
                                    ),
                                    child: Text(
                                      'exit $exitCode',
                                      style: TextStyle(
                                        fontSize: 9.5,
                                        fontFamilyFallback: AppTheme.monoFonts,
                                        color: exitCode == 0
                                            ? const Color(0xFF3FB950)
                                            : Colors.redAccent,
                                      ),
                                    ),
                                  ),

                                Text(
                                  durMs > 0 ? '${durMs}ms' : '',
                                  style: const TextStyle(
                                    fontSize: 10,
                                    color: Color(0xFF8B949E),
                                    fontFamilyFallback: AppTheme.monoFonts,
                                  ),
                                ),
                                const SizedBox(width: 4),
                                Icon(
                                  isStepExpanded
                                      ? Icons.keyboard_arrow_down_rounded
                                      : Icons.chevron_right_rounded,
                                  size: 14,
                                  color: const Color(0xFF8B949E),
                                ),
                              ],
                            ),
                          ),
                        ),

                        // 单步展开详情：具体入参与完整输出
                        if (isStepExpanded) ...[
                          Padding(
                            padding: const EdgeInsets.fromLTRB(10, 0, 10, 8),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: [
                                if (toolArgs.isNotEmpty)
                                  Container(
                                    width: double.infinity,
                                    margin: const EdgeInsets.only(top: 4, bottom: 4),
                                    padding: const EdgeInsets.all(7),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0D1117),
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(
                                        color: const Color(0xFF30363D),
                                        width: 0.8,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        const Text(
                                          'Parameters:',
                                          style: TextStyle(
                                            fontSize: 10,
                                            fontWeight: FontWeight.bold,
                                            color: Color(0xFF8B949E),
                                          ),
                                        ),
                                        const SizedBox(height: 3),
                                        SelectableText(
                                          toolArgs.entries
                                              .map((e) => '  ${e.key}: ${e.value}')
                                              .join('\n'),
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontFamilyFallback: AppTheme.monoFonts,
                                            color: Color(0xFF58A6FF),
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                if (outputSummary.isNotEmpty)
                                  Container(
                                    width: double.infinity,
                                    padding: const EdgeInsets.all(7),
                                    decoration: BoxDecoration(
                                      color: const Color(0xFF0D1117),
                                      borderRadius: BorderRadius.circular(5),
                                      border: Border.all(
                                        color: const Color(0xFF30363D),
                                        width: 0.8,
                                      ),
                                    ),
                                    child: Column(
                                      crossAxisAlignment: CrossAxisAlignment.start,
                                      children: [
                                        Row(
                                          mainAxisAlignment:
                                              MainAxisAlignment.spaceBetween,
                                          children: [
                                            const Text(
                                              'Output:',
                                              style: TextStyle(
                                                fontSize: 10,
                                                fontWeight: FontWeight.bold,
                                                color: Color(0xFF8B949E),
                                              ),
                                            ),
                                            InkWell(
                                              onTap: () {
                                                Clipboard.setData(
                                                  ClipboardData(text: outputSummary),
                                                );
                                                ScaffoldMessenger.of(context)
                                                    .showSnackBar(
                                                  const SnackBar(
                                                    content: Text('已复制输出内容'),
                                                    duration:
                                                        Duration(seconds: 1),
                                                  ),
                                                );
                                              },
                                              child: const Row(
                                                children: [
                                                  Icon(
                                                    Icons.copy_rounded,
                                                    size: 11,
                                                    color: Color(0xFF8B949E),
                                                  ),
                                                  SizedBox(width: 3),
                                                  Text(
                                                    '复制',
                                                    style: TextStyle(
                                                      fontSize: 10,
                                                      color: Color(0xFF8B949E),
                                                    ),
                                                  ),
                                                ],
                                              ),
                                            ),
                                          ],
                                        ),
                                        const SizedBox(height: 3),
                                        SelectableText(
                                          outputSummary,
                                          style: const TextStyle(
                                            fontSize: 11,
                                            fontFamilyFallback: AppTheme.monoFonts,
                                            color: Color(0xFFC9D1D9),
                                            height: 1.4,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                              ],
                            ),
                          ),
                        ],
                      ],
                    ),
                  );
                }),
                if (widget.isGenerating && !hasRunning)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
                    child: Row(
                      children: [
                        const SizedBox(
                          width: 12,
                          height: 12,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            valueColor: AlwaysStoppedAnimation<Color>(Color(0xFF58A6FF)),
                          ),
                        ),
                        const SizedBox(width: 8),
                        Text(
                          'Thinking ($durationStr)...',
                          style: const TextStyle(
                            fontSize: 11.5,
                            color: Color(0xFF8B949E),
                            fontFamilyFallback: AppTheme.monoFonts,
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
          ),
          ],
        ],
      ),
    );
  }
}

/// 渲染 Agent 任务执行后修改的文件列表卡片 (Image 2 风格)
class FilesChangedWidget extends StatefulWidget {
  final List<Map<String, dynamic>> files;
  final LumiColors colors;

  const FilesChangedWidget({
    super.key,
    required this.files,
    required this.colors,
  });

  @override
  State<FilesChangedWidget> createState() => _FilesChangedWidgetState();
}

class _FilesChangedWidgetState extends State<FilesChangedWidget> {
  bool _isExpanded = true;

  IconData _iconForFile(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.dart')) return Icons.flutter_dash_rounded;
    if (lower.endsWith('.cc') ||
        lower.endsWith('.cpp') ||
        lower.endsWith('.c') ||
        lower.endsWith('.h')) {
      return Icons.code_rounded;
    }
    if (lower.endsWith('.py')) return Icons.terminal_rounded;
    if (lower.endsWith('.yaml') ||
        lower.endsWith('.json') ||
        lower.endsWith('.xml') ||
        lower.endsWith('.toml')) {
      return Icons.settings_suggest_rounded;
    }
    if (lower.endsWith('.md')) return Icons.article_outlined;
    return Icons.insert_drive_file_outlined;
  }

  Color _iconColorForFile(String name) {
    final lower = name.toLowerCase();
    if (lower.endsWith('.dart')) return const Color(0xFF58A6FF);
    if (lower.endsWith('.cc') ||
        lower.endsWith('.cpp') ||
        lower.endsWith('.c') ||
        lower.endsWith('.h')) {
      return const Color(0xFF79C0FF);
    }
    if (lower.endsWith('.py')) return const Color(0xFFFFD166);
    if (lower.endsWith('.yaml') || lower.endsWith('.json')) {
      return const Color(0xFFFFA657);
    }
    return const Color(0xFF8B949E);
  }

  @override
  Widget build(BuildContext context) {
    if (widget.files.isEmpty) {
      return const SizedBox.shrink();
    }

    int totalAdds = 0;
    int totalDels = 0;
    for (final f in widget.files) {
      totalAdds += (f['additions'] as num?)?.toInt() ?? 0;
      totalDels += (f['deletions'] as num?)?.toInt() ?? 0;
    }

    final count = widget.files.length;
    final fileWord = count == 1 ? 'file' : 'files';

    return Container(
      margin: const EdgeInsets.only(top: 8, bottom: 4),
      decoration: BoxDecoration(
        color: const Color(0xFF16191E),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFF2D333B), width: 1),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // ── 头部：2 files changed +12 -0 ∨ ──
          InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _isExpanded = !_isExpanded),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
              child: Row(
                children: [
                  Text(
                    '$count $fileWord changed',
                    style: const TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                      color: Color(0xFFE6EDF3),
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (totalAdds > 0 || totalDels > 0) ...[
                    Text(
                      '+$totalAdds',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFF3FB950),
                        fontFamilyFallback: AppTheme.monoFonts,
                      ),
                    ),
                    const SizedBox(width: 4),
                    Text(
                      '-$totalDels',
                      style: const TextStyle(
                        fontSize: 12,
                        fontWeight: FontWeight.bold,
                        color: Color(0xFFF85149),
                        fontFamilyFallback: AppTheme.monoFonts,
                      ),
                    ),
                  ],
                  const Spacer(),
                  Icon(
                    _isExpanded
                        ? Icons.keyboard_arrow_up_rounded
                        : Icons.keyboard_arrow_down_rounded,
                    size: 18,
                    color: const Color(0xFF8B949E),
                  ),
                ],
              ),
            ),
          ),

          // ── 文件列表 ──
          if (_isExpanded) ...[
            Container(height: 1, color: const Color(0xFF2D333B)),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 6),
              child: Column(
                children: widget.files.map((file) {
                  final path = file['path'] as String? ?? '';
                  final name = file['name'] as String? ??
                      (path.isNotEmpty ? path.split(RegExp(r'[/\\]')).last : 'file');
                  final dir = file['dir'] as String? ??
                      (path.contains(RegExp(r'[/\\]'))
                          ? path.substring(0, path.lastIndexOf(RegExp(r'[/\\]')))
                          : '');
                  final adds = (file['additions'] as num?)?.toInt() ?? 0;
                  final dels = (file['deletions'] as num?)?.toInt() ?? 0;
                  final icon = _iconForFile(name);
                  final iconColor = _iconColorForFile(name);

                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 6,
                    ),
                    child: Row(
                      children: [
                        Icon(icon, size: 16, color: iconColor),
                        const SizedBox(width: 8),
                        Text(
                          name,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.bold,
                            color: Color(0xFFE6EDF3),
                            fontFamilyFallback: AppTheme.monoFonts,
                          ),
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            dir,
                            style: const TextStyle(
                              fontSize: 11.5,
                              color: Color(0xFF8B949E),
                              fontFamilyFallback: AppTheme.monoFonts,
                            ),
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                        if (adds > 0 || dels > 0) ...[
                          Text(
                            '+$adds',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFF3FB950),
                              fontFamilyFallback: AppTheme.monoFonts,
                            ),
                          ),
                          const SizedBox(width: 3),
                          Text(
                            '-$dels',
                            style: const TextStyle(
                              fontSize: 11,
                              color: Color(0xFFF85149),
                              fontFamilyFallback: AppTheme.monoFonts,
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
