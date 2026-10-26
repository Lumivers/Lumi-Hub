import 'dart:io';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_markdown/flutter_markdown.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';

import '../models/message.dart';
import '../screens/chat_screen.dart';
import '../services/ws_service.dart';
import '../theme/app_theme.dart';

/// 消息分享卡片导出弹窗
class MessageShareCardDialog extends StatefulWidget {
  final ChatMessage msg;
  final String personaName;

  const MessageShareCardDialog({
    super.key,
    required this.msg,
    required this.personaName,
  });

  static Future<void> show(
    BuildContext context, {
    required ChatMessage msg,
    required String personaName,
  }) {
    return showDialog<void>(
      context: context,
      barrierDismissible: true,
      builder: (ctx) => MessageShareCardDialog(
        msg: msg,
        personaName: personaName,
      ),
    );
  }

  @override
  State<MessageShareCardDialog> createState() => _MessageShareCardDialogState();
}

class _MessageShareCardDialogState extends State<MessageShareCardDialog> {
  final GlobalKey _repaintKey = GlobalKey();
  bool _isExporting = false;

  String? _getDownloadsDirectory() {
    try {
      if (Platform.isWindows) {
        final profile = Platform.environment['USERPROFILE'];
        if (profile != null) return '$profile\\Downloads';
      } else {
        final home = Platform.environment['HOME'];
        if (home != null) return '$home/Downloads';
      }
    } catch (_) {}
    return null;
  }

  Future<Uint8List?> _captureCardBytes() async {
    final boundary =
        _repaintKey.currentContext?.findRenderObject() as RenderRepaintBoundary?;
    if (boundary == null) return null;

    // 采用 2.5 倍高采样率输出超高清 PNG
    final image = await boundary.toImage(pixelRatio: 2.5);
    final byteData = await image.toByteData(format: ui.ImageByteFormat.png);
    return byteData?.buffer.asUint8List();
  }

  Future<void> _exportSaveAs() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _isExporting = true);
    try {
      final pngBytes = await _captureCardBytes();
      if (pngBytes == null) throw Exception('渲染图片失败');

      final dateStr = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final defaultFileName = 'lumi_share_$dateStr.png';

      final savePath = await FilePicker.platform.saveFile(
        dialogTitle: '保存分享卡片图片',
        fileName: defaultFileName,
        type: FileType.custom,
        allowedExtensions: ['png'],
      );

      if (savePath != null) {
        var finalPath = savePath;
        if (!finalPath.toLowerCase().endsWith('.png')) {
          finalPath = '$finalPath.png';
        }
        await File(finalPath).writeAsBytes(pngBytes);
        if (!mounted) return;
        navigator.pop();
        messenger.showSnackBar(
          SnackBar(
            content: Text('已成功保存分享卡片至:\n$finalPath'),
            backgroundColor: Colors.green.shade700,
            duration: const Duration(seconds: 4),
          ),
        );
      }
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('导出图片失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  Future<void> _exportQuickSave() async {
    final messenger = ScaffoldMessenger.of(context);
    final navigator = Navigator.of(context);
    setState(() => _isExporting = true);
    try {
      final pngBytes = await _captureCardBytes();
      if (pngBytes == null) throw Exception('渲染图片失败');

      final dir = _getDownloadsDirectory();
      if (dir == null || !Directory(dir).existsSync()) {
        // 下载目录不存在则回退至另存为
        if (!mounted) return;
        setState(() => _isExporting = false);
        await _exportSaveAs();
        return;
      }

      final dateStr = DateFormat('yyyyMMdd_HHmmss').format(DateTime.now());
      final separator = Platform.isWindows ? '\\' : '/';
      final finalPath = '$dir${separator}lumi_share_$dateStr.png';

      await File(finalPath).writeAsBytes(pngBytes);
      if (!mounted) return;
      navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text('已直接保存至下载目录:\n$finalPath'),
          backgroundColor: Colors.green.shade700,
          duration: const Duration(seconds: 4),
        ),
      );
    } catch (e) {
      if (!mounted) return;
      messenger.showSnackBar(
        SnackBar(
          content: Text('快速保存失败: $e'),
          backgroundColor: Colors.red,
        ),
      );
    } finally {
      if (mounted) setState(() => _isExporting = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = Theme.of(context);
    final isDark = theme.brightness == Brightness.dark;
    final colors = theme.extension<LumiColors>() ?? LumiColors.dark();
    final ws = context.watch<WsService>();

    final persona = widget.personaName.isNotEmpty ? widget.personaName : '流萤';
    final modelName = ws.activeModelId.isNotEmpty ? ws.activeModelId : 'Lumi-AI';
    final wsPath = ws.activeWorkspacePath;
    final wsName = wsPath.isNotEmpty
        ? wsPath.split(RegExp(r'[/\\]')).where((s) => s.isNotEmpty).last
        : '默认工作区';

    final timeStr = DateFormat('yyyy-MM-dd HH:mm').format(widget.msg.time);

    return Dialog(
      backgroundColor: Colors.transparent,
      insetPadding: const EdgeInsets.symmetric(horizontal: 24, vertical: 24),
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 620, maxHeight: 720),
        child: Container(
          decoration: BoxDecoration(
            color: isDark ? const Color(0xFF131A22) : const Color(0xFFF7F9FC),
            borderRadius: BorderRadius.circular(16),
            border: Border.all(
              color: colors.divider.withValues(alpha: 0.8),
            ),
            boxShadow: [
              BoxShadow(
                color: Colors.black.withValues(alpha: 0.35),
                blurRadius: 24,
                offset: const Offset(0, 8),
              ),
            ],
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              // 顶部标题栏
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 14),
                child: Row(
                  children: [
                    Icon(Icons.image_outlined, size: 20, color: colors.accent),
                    const SizedBox(width: 8),
                    Text(
                      '导出分享卡片',
                      style: theme.textTheme.titleMedium?.copyWith(
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: const Icon(Icons.close, size: 20),
                      tooltip: '关闭',
                      onPressed: () => Navigator.of(context).pop(),
                    ),
                  ],
                ),
              ),
              const Divider(height: 1),

              // 中间卡片预览区（支持滚动）
              Expanded(
                child: SingleChildScrollView(
                  padding: const EdgeInsets.all(20),
                  child: Center(
                    child: RepaintBoundary(
                      key: _repaintKey,
                      child: Container(
                        width: 520,
                        padding: const EdgeInsets.all(24),
                        decoration: BoxDecoration(
                          color: isDark
                              ? const Color(0xFF1B2431)
                              : Colors.white,
                          borderRadius: BorderRadius.circular(16),
                          border: Border.all(
                            color: colors.accent.withValues(alpha: 0.25),
                            width: 1.2,
                          ),
                          boxShadow: [
                            BoxShadow(
                              color: Colors.black.withValues(alpha: 0.12),
                              blurRadius: 16,
                              offset: const Offset(0, 4),
                            ),
                          ],
                        ),
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            // 卡片头部：角色与模型信息
                            Row(
                              crossAxisAlignment: CrossAxisAlignment.center,
                              children: [
                                CircleAvatar(
                                  radius: 20,
                                  backgroundColor: colors.accent,
                                  child: Text(
                                    persona.isNotEmpty ? persona.characters.first : 'L',
                                    style: const TextStyle(
                                      color: Colors.white,
                                      fontSize: 16,
                                      fontWeight: FontWeight.bold,
                                    ),
                                  ),
                                ),
                                const SizedBox(width: 12),
                                Expanded(
                                  child: Column(
                                    crossAxisAlignment: CrossAxisAlignment.start,
                                    children: [
                                      Row(
                                        children: [
                                          Text(
                                            persona,
                                            style: TextStyle(
                                              fontSize: 15,
                                              fontWeight: FontWeight.bold,
                                              color: theme.colorScheme.onSurface,
                                            ),
                                          ),
                                          const SizedBox(width: 8),
                                          Container(
                                            padding: const EdgeInsets.symmetric(
                                              horizontal: 7,
                                              vertical: 2,
                                            ),
                                            decoration: BoxDecoration(
                                              color: colors.accent.withValues(alpha: 0.15),
                                              borderRadius: BorderRadius.circular(4),
                                            ),
                                            child: Text(
                                              modelName,
                                              style: TextStyle(
                                                fontSize: 11,
                                                fontWeight: FontWeight.w500,
                                                color: colors.accent,
                                              ),
                                            ),
                                          ),
                                        ],
                                      ),
                                      const SizedBox(height: 2),
                                      Text(
                                        '$timeStr • 工作区: $wsName',
                                        style: TextStyle(
                                          fontSize: 11,
                                          color: colors.subtext.withValues(alpha: 0.75),
                                        ),
                                      ),
                                    ],
                                  ),
                                ),
                              ],
                            ),
                            const SizedBox(height: 16),
                            Divider(
                              height: 1,
                              color: colors.divider.withValues(alpha: 0.5),
                            ),
                            const SizedBox(height: 16),

                            // 卡片正文：Markdown 渲染
                            MarkdownBody(
                              data: widget.msg.content,
                              selectable: false,
                              styleSheet: MarkdownStyleSheet.fromTheme(theme).copyWith(
                                p: TextStyle(
                                  fontSize: 14,
                                  height: 1.6,
                                  color: theme.colorScheme.onSurface,
                                  fontFamilyFallback: AppTheme.fallbackFonts,
                                ),
                                code: const TextStyle(
                                  fontSize: 12.5,
                                  color: Color(0xFF79C0FF),
                                  fontFamilyFallback: AppTheme.monoFonts,
                                ),
                                codeblockDecoration: BoxDecoration(
                                  color: isDark
                                      ? const Color(0xFF101720)
                                      : const Color(0xFFF3F5F7),
                                  borderRadius: BorderRadius.circular(8),
                                  border: Border.all(
                                    color: colors.divider.withValues(alpha: 0.4),
                                  ),
                                ),
                              ),
                              builders: {'code': CodeElementBuilder()},
                            ),
                            const SizedBox(height: 24),

                            // 卡片底标
                            Row(
                              mainAxisAlignment: MainAxisAlignment.spaceBetween,
                              children: [
                                Row(
                                  children: [
                                    Icon(
                                      Icons.auto_awesome,
                                      size: 14,
                                      color: colors.accent.withValues(alpha: 0.8),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      'Lumi-Hub',
                                      style: TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.bold,
                                        letterSpacing: 0.5,
                                        color: colors.accent,
                                      ),
                                    ),
                                    const SizedBox(width: 6),
                                    Text(
                                      '• AI 协作对话助手',
                                      style: TextStyle(
                                        fontSize: 11,
                                        color: colors.subtext.withValues(alpha: 0.6),
                                      ),
                                    ),
                                  ],
                                ),
                                Text(
                                  'firefly://share-card',
                                  style: TextStyle(
                                    fontSize: 10,
                                    color: colors.subtext.withValues(alpha: 0.4),
                                  ),
                                ),
                              ],
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ),

              const Divider(height: 1),
              // 底部操作按钮栏
              Padding(
                padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 12),
                child: Row(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    TextButton(
                      onPressed: _isExporting ? null : () => Navigator.of(context).pop(),
                      child: const Text('取消'),
                    ),
                    const SizedBox(width: 10),
                    OutlinedButton.icon(
                      icon: const Icon(Icons.download_rounded, size: 18),
                      label: const Text('快捷存至下载'),
                      onPressed: _isExporting ? null : _exportQuickSave,
                    ),
                    const SizedBox(width: 10),
                    FilledButton.icon(
                      icon: _isExporting
                          ? const SizedBox(
                              width: 16,
                              height: 16,
                              child: CircularProgressIndicator(
                                strokeWidth: 2,
                                color: Colors.white,
                              ),
                            )
                          : const Icon(Icons.save_alt_rounded, size: 18),
                      label: Text(_isExporting ? '生成中...' : '另存为图片...'),
                      onPressed: _isExporting ? null : _exportSaveAs,
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ),
    );
  }
}
