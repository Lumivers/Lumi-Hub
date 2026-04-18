part of 'ws_service.dart';

extension WsServiceUploadPart on WsService {

  String? _readUploadErrorDetail(Map<String, dynamic> response) {
    final payload = response['payload'];
    if (payload is! Map<String, dynamic>) return null;

    final detail = payload['detail'];
    if (detail == null) return null;
    if (detail is String) {
      final normalized = detail.trim();
      return normalized.isEmpty ? null : normalized;
    }
    return detail.toString();
  }

  Future<Map<String, dynamic>> _sendAndAwaitResponse(
    String type,
    Map<String, dynamic> payload, {
    Duration timeout = const Duration(seconds: 30),
  }) async {
    if (_status != WsStatus.connected) {
      throw Exception('WebSocket 未连接');
    }

    final msgId = '${_genId()}_${DateTime.now().microsecondsSinceEpoch}';
    final completer = Completer<Map<String, dynamic>>();
    _pendingResponses[msgId] = completer;

    _send({
      'message_id': msgId,
      'type': type,
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': payload,
    });

    try {
      return await completer.future.timeout(timeout);
    } on TimeoutException {
      _pendingResponses.remove(msgId);
      throw Exception('$type 请求超时');
    }
  }

  String _mimeFromFileName(String fileName) {
    final lower = fileName.toLowerCase();
    if (lower.endsWith('.png')) return 'image/png';
    if (lower.endsWith('.jpg') || lower.endsWith('.jpeg')) return 'image/jpeg';
    if (lower.endsWith('.gif')) return 'image/gif';
    if (lower.endsWith('.webp')) return 'image/webp';
    if (lower.endsWith('.pdf')) return 'application/pdf';
    if (lower.endsWith('.mp4')) return 'video/mp4';
    if (lower.endsWith('.webm')) return 'video/webm';
    if (lower.endsWith('.mov')) return 'video/quicktime';
    return 'application/octet-stream';
  }

  Future<Map<String, dynamic>> uploadFile(
    String filePath, {
    void Function(double progress)? onProgress,
  }) async {
    final file = File(filePath);
    if (!await file.exists()) {
      throw Exception('文件不存在: $filePath');
    }

    final fileName = file.uri.pathSegments.isNotEmpty
        ? file.uri.pathSegments.last
        : filePath.split(RegExp(r'[\\/]')).last;
    final mimeType = _mimeFromFileName(fileName);
    final bytes = await file.readAsBytes();
    final sizeBytes = bytes.length;
    final sha256Hex = sha256.convert(bytes).toString();

    Future<Map<String, dynamic>> sendInit() {
      return _sendAndAwaitResponse('FILE_UPLOAD_INIT', {
        'file_name': fileName,
        'mime_type': mimeType,
        'size_bytes': sizeBytes,
        'sha256': sha256Hex,
      }, timeout: const Duration(seconds: 15));
    }

    Map<String, dynamic> initResp;
    try {
      initResp = await sendInit();
    } catch (e) {
      final err = e.toString();
      if (err.contains('FILE_UPLOAD_INIT 请求超时')) {
        debugPrint('[WS] FILE_UPLOAD_INIT 超时，正在重试一次...');
        try {
          initResp = await sendInit();
        } catch (_) {
          throw Exception(
            '上传初始化超时：Host 未响应 FILE_UPLOAD_INIT。请检查 Host 是否已重启到最新代码，或查看 Host 日志是否出现“未知消息类型: FILE_UPLOAD_INIT”。',
          );
        }
      } else {
        rethrow;
      }
    }

    if ((initResp['type'] as String?) == 'FILE_UPLOAD_ERROR') {
      final detail = _readUploadErrorDetail(initResp);
      throw Exception(detail ?? '初始化上传失败');
    }

    final initPayload = initResp['payload'] as Map<String, dynamic>? ?? {};
    final uploadId = initPayload['upload_id'] as String?;
    if (uploadId == null || uploadId.isEmpty) {
      throw Exception('服务器未返回 upload_id（请确认 Host 已更新并重启）');
    }

    final totalChunks = (sizeBytes / WsService._uploadChunkSize).ceil();
    onProgress?.call(0);
    for (var index = 0; index < totalChunks; index++) {
      final start = index * WsService._uploadChunkSize;
      final end = min(sizeBytes, start + WsService._uploadChunkSize);
      final chunk = bytes.sublist(start, end);
      final chunkResp = await _sendAndAwaitResponse('FILE_UPLOAD_CHUNK', {
        'upload_id': uploadId,
        'chunk_index': index,
        'total_chunks': totalChunks,
        'chunk_base64': base64Encode(chunk),
      }, timeout: const Duration(seconds: 60));

      if ((chunkResp['type'] as String?) == 'FILE_UPLOAD_ERROR') {
        final detail = _readUploadErrorDetail(chunkResp);
        throw Exception(detail ?? '上传分片失败');
      }

      onProgress?.call((index + 1) / totalChunks);
    }

    final completeResp = await _sendAndAwaitResponse('FILE_UPLOAD_COMPLETE', {
      'upload_id': uploadId,
    }, timeout: const Duration(seconds: 60));

    if ((completeResp['type'] as String?) == 'FILE_UPLOAD_ERROR') {
      final detail = _readUploadErrorDetail(completeResp);
      throw Exception(detail ?? '上传完成失败');
    }

    final completePayload =
        completeResp['payload'] as Map<String, dynamic>? ?? {};
    final attachment = completePayload['attachment'] as Map<String, dynamic>?;
    if (attachment == null) {
      throw Exception('服务器未返回附件信息');
    }
    // 前端渲染图片与本地点击打开都依赖原始本地路径。
    attachment['local_path'] = file.path;
    onProgress?.call(1);
    return attachment;
  }

}
