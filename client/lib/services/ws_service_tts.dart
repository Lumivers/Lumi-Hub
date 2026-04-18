part of 'ws_service.dart';

extension WsServiceTtsPart on WsService {
  // 检查某一轮 turn 是否已有可播放音频（内存索引 + 磁盘恢复）。

  bool hasTtsAudio(String turnId) {
    final normalized = turnId.trim();
    if (normalized.isEmpty) return false;

    final cachedPath = _ttsAudioFiles[normalized];
    if (cachedPath != null && cachedPath.isNotEmpty) {
      if (File(cachedPath).existsSync()) {
        return true;
      }
      _ttsAudioFiles.remove(normalized);
    }

    final recoveredPath = _recoverTtsAudioPath(normalized);
    if (recoveredPath != null) {
      _ttsAudioFiles[normalized] = recoveredPath;
      return true;
    }

    return false;
  }

  bool isTtsGenerating(String turnId) => _ttsGeneratingTurns.contains(turnId);

  // 优先使用 Windows 的 LOCALAPPDATA，避免 systemTemp 在重启后被清理。
  Directory _resolveTtsCacheDir() {
    if (!kIsWeb && Platform.isWindows) {
      final localAppData = Platform.environment['LOCALAPPDATA'];
      if (localAppData != null && localAppData.trim().isNotEmpty) {
        return Directory(
          '$localAppData${Platform.pathSeparator}Lumi-Hub${Platform.pathSeparator}tts_cache',
        );
      }
    }

    return Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumi_hub_tts_cache',
    );
  }

  // 兼容历史缓存目录：即使内存索引丢失，也尝试按 turnId 扫描恢复。
  String? _recoverTtsAudioPath(String turnId) {
    final dirs = <Directory>[_resolveTtsCacheDir()];
    final legacyTempDir = Directory(
      '${Directory.systemTemp.path}${Platform.pathSeparator}lumi_hub_tts_cache',
    );
    if (!dirs.any((d) => d.path == legacyTempDir.path)) {
      dirs.add(legacyTempDir);
    }

    const candidates = <String>['mp3', 'wav', 'ogg'];
    for (final dir in dirs) {
      for (final ext in candidates) {
        final path = '${dir.path}${Platform.pathSeparator}$turnId.$ext';
        if (File(path).existsSync()) {
          return path;
        }
      }
    }
    return null;
  }

  void _initTtsPlayer() {
    if (kIsWeb) return;
    _ttsPlayer = AudioPlayer();
    _ttsPlayerStateSub = _ttsPlayer!.playerStateStream.listen((state) {
      final isPlaying = state.playing;
      final completed = state.processingState == ProcessingState.completed;
      final nextPlaying = isPlaying && !completed;
      if (_isTtsPlaying != nextPlaying) {
        _isTtsPlaying = nextPlaying;
        if (!nextPlaying && completed) {
          _playingTtsTurnId = null;
        }
        _notifyStateChanged();
      }
      if (completed && _playingTtsTurnId != null) {
        _playingTtsTurnId = null;
        _notifyStateChanged();
      }
    });
  }

  void _handleTtsStreamStart(Map<String, dynamic> data) {
    // 阶段 1：初始化当前 turn 的分片缓冲区。
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final turnId = (payload['turn_id'] as String? ?? '').trim();
    if (turnId.isEmpty) return;

    final format = ((payload['format'] as String?) ?? 'mp3')
        .trim()
        .toLowerCase();
    _ttsBuffers[turnId] = _TtsTurnBuffer(
      format: format.isEmpty ? 'mp3' : format,
    );
    _ttsGeneratingTurns.add(turnId);
    _notifyStateChanged();
  }

  void _handleTtsStreamChunk(Map<String, dynamic> data) {
    // 阶段 2：持续接收分片并按 seq 存储。
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final turnId = (payload['turn_id'] as String? ?? '').trim();
    if (turnId.isEmpty) return;

    final buffer = _ttsBuffers.putIfAbsent(
      turnId,
      () => _TtsTurnBuffer(format: 'mp3'),
    );
    final seqValue = payload['seq'];
    final seq = seqValue is num ? seqValue.toInt() : 0;
    final b64 = (payload['audio_base64'] as String? ?? '').trim();
    if (b64.isEmpty) return;

    try {
      final bytes = base64Decode(b64);
      buffer.chunks[seq] = bytes;
    } catch (e) {
      debugPrint('[WS] 解码 TTS 分片失败: $e');
    }
  }

  Future<void> _handleTtsStreamEnd(Map<String, dynamic> data) async {
    // 阶段 3：合并分片并落盘，写入可播放文件索引。
    final payload = data['payload'] as Map<String, dynamic>? ?? {};
    final turnId = (payload['turn_id'] as String? ?? '').trim();
    if (turnId.isEmpty) return;

    final status = (payload['status'] as String? ?? '').trim().toLowerCase();
    final buffer = _ttsBuffers.remove(turnId);
    _ttsGeneratingTurns.remove(turnId);

    if (status == 'success' && buffer != null && buffer.chunks.isNotEmpty) {
      try {
        final ext = _normalizeTtsExt(buffer.format);
        final dir = _resolveTtsCacheDir();
        if (!await dir.exists()) {
          await dir.create(recursive: true);
        }

        final filePath = '${dir.path}${Platform.pathSeparator}$turnId.$ext';
        final file = File(filePath);
        await file.writeAsBytes(buffer.mergeBytes(), flush: true);
        _ttsAudioFiles[turnId] = filePath;
      } catch (e) {
        debugPrint('[WS] 保存 TTS 音频失败: $e');
      }
    }

    _notifyStateChanged();
  }

  Future<void> _handleTtsStreamEndAndNotify(Map<String, dynamic> data) async {
    await _handleTtsStreamEnd(data);
    _voiceEventController.add(data);
  }

  String _normalizeTtsExt(String raw) {
    final value = raw.trim().toLowerCase();
    if (value == 'wav' || value == 'ogg' || value == 'mp3') {
      return value;
    }
    return 'mp3';
  }

  Future<void> playTtsAudio(String turnId) async {
    if (kIsWeb) return;
    final player = _ttsPlayer;
    if (player == null) return;
    if (_ttsOperationLocked) return;

    final path = _ttsAudioFiles[turnId];
    if (path == null || path.isEmpty) {
      throw Exception('该消息尚未生成可播放语音');
    }

    final file = File(path);
    if (!await file.exists()) {
      _ttsAudioFiles.remove(turnId);
      throw Exception('语音文件不存在，请稍后重试');
    }

    final fileSize = await file.length();
    if (fileSize <= 0) {
      _ttsAudioFiles.remove(turnId);
      throw Exception('语音文件尚未准备完成，请稍后重试');
    }

    // 防抖锁：避免连续点击播放/停止导致播放器状态竞争。
    _ttsOperationLocked = true;

    try {
      if (_playingTtsTurnId == turnId && _isTtsPlaying) {
        await stopTtsAudio();
        return;
      }

      await player.stop();
      _playingTtsTurnId = turnId;
      _isTtsPlaying = false;
      _notifyStateChanged();

      await player.setFilePath(path);
      await player.play();
    } catch (e) {
      _isTtsPlaying = false;
      _playingTtsTurnId = null;
      _notifyStateChanged();
      rethrow;
    } finally {
      _ttsOperationLocked = false;
    }
  }

  Future<void> stopTtsAudio() async {
    final player = _ttsPlayer;
    if (player == null) return;

    await player.stop();
    _isTtsPlaying = false;
    _playingTtsTurnId = null;
    _notifyStateChanged();
  }

  void getVoiceConfig() {
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'VOICE_CONFIG_GET',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {},
    });
  }

  void setVoiceConfig({
    String provider = 'dashscope',
    String voiceId = '',
    String apiKey = '',
    bool clearApiKey = false,
  }) {
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'VOICE_CONFIG_SET',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        'config': {
          'provider': provider,
          if (voiceId.trim().isNotEmpty) 'voice_id': voiceId.trim(),
          if (apiKey.trim().isNotEmpty) 'api_key': apiKey.trim(),
          'clear_api_key': clearApiKey,
        },
      },
    });
  }

  void requestVoiceTts({
    required String text,
    required String turnId,
    String provider = 'dashscope',
    String voiceId = '',
    bool useSsml = true,
    bool autoStyle = true,
  }) {
    final normalizedText = text.trim();
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    if (normalizedText.isEmpty) return;

    // 请求 Host 异步生成语音，客户端通过 TTS_STREAM_* 消息流接收结果。
    _send({
      'message_id': _genId(),
      'type': 'VOICE_TTS_REQUEST',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        'text': normalizedText,
        'turn_id': turnId,
        'provider': provider,
        if (voiceId.trim().isNotEmpty) 'voice_id': voiceId.trim(),
        'use_ssml': useSsml,
        'auto_style': autoStyle,
      },
    });
  }

  void interruptVoice({String? turnId}) {
    if (_status != WsStatus.connected || !_isAuthenticated) return;
    _send({
      'message_id': _genId(),
      'type': 'VOICE_INTERRUPT',
      'source': 'client',
      'target': 'host',
      'timestamp': DateTime.now().millisecondsSinceEpoch,
      'payload': {
        if (turnId != null && turnId.trim().isNotEmpty)
          'turn_id': turnId.trim(),
      },
    });
  }
}
