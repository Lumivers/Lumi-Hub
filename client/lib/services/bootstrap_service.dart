import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ws_service.dart';

enum BootstrapStage {
  init,
  connectingWs,
  checkingConfig,
  ready,
  failed,
}

enum LogLevel { info, debug, warning, error }

class LogEntry {
  final DateTime time;
  final LogLevel level;
  final String message;

  LogEntry(this.time, this.level, this.message);

  String get timeString {
    final hh = time.hour.toString().padLeft(2, '0');
    final mm = time.minute.toString().padLeft(2, '0');
    final ss = time.second.toString().padLeft(2, '0');
    return '$hh:$mm:$ss';
  }

  String get levelString {
    switch (level) {
      case LogLevel.info:
        return 'INFO';
      case LogLevel.debug:
        return 'DEBUG';
      case LogLevel.warning:
        return 'WARN';
      case LogLevel.error:
        return 'ERROR';
    }
  }

  @override
  String toString() => '[$levelString] [$timeString] $message';
}

class BootstrapService extends ChangeNotifier {
  final WsService _ws;
  Future<void>? _startFuture;

  BootstrapStage _stage = BootstrapStage.init;
  BootstrapStage get stage => _stage;

  final List<LogEntry> _logs = [];
  List<LogEntry> get logs => List.unmodifiable(_logs);

  String? _error;
  String? get error => _error;

  bool get isReady => _stage == BootstrapStage.ready;
  bool get hasFailed => _stage == BootstrapStage.failed;

  // LLM 配置状态
  bool _llmConfigured = false;
  bool get llmConfigured => _llmConfigured;
  String _llmProvider = 'openai';
  String get llmProvider => _llmProvider;
  String _llmModel = '';
  String get llmModel => _llmModel;

  // ── 首次运行检测 ──

  /// 是否已完成首次引导向导。
  /// 首次启动时为 false，向导完成后写入 SharedPreferences 标记为 true。
  bool _setupCompleted = false;
  bool get setupCompleted => _setupCompleted;

  /// 是否为首次运行（需要显示引导向导）。
  /// 条件：向导未完成 且 LLM 未配置。
  bool get isFirstRun => !_setupCompleted && !_llmConfigured;

  BootstrapService(this._ws) {
    _loadSetupFlag();
  }

  Future<void> _loadSetupFlag() async {
    final prefs = await SharedPreferences.getInstance();
    _setupCompleted = prefs.getBool('app.setup_completed') ?? false;
    notifyListeners();
  }

  /// 向导完成后调用，标记首次引导已结束。
  Future<void> markSetupCompleted() async {
    _setupCompleted = true;
    final prefs = await SharedPreferences.getInstance();
    await prefs.setBool('app.setup_completed', true);
    notifyListeners();
  }

  Future<void> ensureStarted() {
    _startFuture ??= start();
    return _startFuture!;
  }

  Future<void> retry() async {
    if (_stage != BootstrapStage.failed) return;
    _error = null;
    _logs.clear();
    _startFuture = null;
    notifyListeners();
    await ensureStarted();
  }

  Future<void> start() async {
    _setStage(BootstrapStage.connectingWs);
    _log('正在连接 Host: ${_ws.serverUrl}');

    await _ws.connect();

    final wsConnected = await _waitWsConnected(const Duration(seconds: 10));
    if (!wsConnected) {
      _fail('无法连接到 Host (${_ws.serverUrl})。请确认 Host 已启动。');
      return;
    }

    _log('WebSocket 连接成功。');

    // 检查 LLM 配置状态
    _setStage(BootstrapStage.checkingConfig);
    _log('正在检查 LLM 配置...');

    final status = await _requestAppStatus();
    if (status != null) {
      _llmConfigured = status['llm_configured'] ?? false;
      _llmProvider = status['llm_provider'] ?? 'openai';
      _llmModel = status['llm_model'] ?? '';

      if (_llmConfigured) {
        _log('LLM 已配置: $_llmProvider ($_llmModel)');
      } else {
        _log('LLM 未配置，请在设置中配置 API Key。', level: LogLevel.warning);
      }
    }

    _log('启动准备完成。');
    _setStage(BootstrapStage.ready);
  }

  Future<Map<String, dynamic>?> _requestAppStatus() async {
    try {
      final resp = await _ws.sendRequest('APP_STATUS', {});
      return resp?['payload'] as Map<String, dynamic>?;
    } catch (e) {
      _log('获取应用状态失败: $e', level: LogLevel.warning);
      return null;
    }
  }

  Future<bool> _waitWsConnected(Duration timeout) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      if (_ws.status == WsStatus.connected) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 300));
    }
    return false;
  }

  void _setStage(BootstrapStage stage) {
    _stage = stage;
    notifyListeners();
  }

  void _log(String message, {LogLevel level = LogLevel.info}) {
    final entry = LogEntry(DateTime.now(), level, message);
    _logs.add(entry);
    if (_logs.length > 30) {
      _logs.removeAt(0);
    }
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _log('启动失败: $message', level: LogLevel.error);
    _stage = BootstrapStage.failed;
    notifyListeners();
  }

  // ── 刷新 LLM 配置状态（从设置页返回时调用） ──

  Future<void> refreshLlmStatus() async {
    final status = await _requestAppStatus();
    if (status != null) {
      _llmConfigured = status['llm_configured'] ?? false;
      _llmProvider = status['llm_provider'] ?? 'openai';
      _llmModel = status['llm_model'] ?? '';
      notifyListeners();
    }
  }

  // ── 日志文件（兼容旧 UI 调用） ──

  String? _logDirectoryPath;
  String? get logDirectoryPath => _logDirectoryPath;

  Future<void> openLogDirectory() async {
    if (_logDirectoryPath == null || _logDirectoryPath!.isEmpty) return;
    try {
      await Process.start('explorer', [_logDirectoryPath!]);
    } catch (_) {}
  }

  // ── 退出处理 ──

  Future<void> handleAppExit() async {
    // 2.0 独立模式下 Host 由 start.py 管理，客户端退出无需额外操作。
  }
}
