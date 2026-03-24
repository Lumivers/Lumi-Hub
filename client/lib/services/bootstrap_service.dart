import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';

import 'ws_service.dart';

enum BootstrapStage {
  init,
  checkingEnv,
  checkingHost,
  startingAstrBot,
  waitingHost,
  connectingWs,
  ready,
  failed,
}

enum LogLevel {
  info,
  debug,
  warning,
  error,
}

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
      case LogLevel.info: return 'INFO';
      case LogLevel.debug: return 'DEBUG';
      case LogLevel.warning: return 'WARN';
      case LogLevel.error: return 'ERROR';
    }
  }

  @override
  String toString() => '[$levelString] [$timeString] $message';
}

class BootstrapService extends ChangeNotifier {
  static const int _hostPort = 8765;
  static const String _hostAddress = '127.0.0.1';

  final WsService _ws;
  bool _startedAstrBotByHub = false;
  int? _astrBotPid;

  String? _logDirectoryPath;
  String? _logFilePath;

  BootstrapStage _stage = BootstrapStage.init;
  BootstrapStage get stage => _stage;

  final List<LogEntry> _logs = [];
  List<LogEntry> get logs => List.unmodifiable(_logs);
  String? get logDirectoryPath => _logDirectoryPath;
  String? get logFilePath => _logFilePath;

  String? _error;
  String? get error => _error;

  bool get isReady => _stage == BootstrapStage.ready;
  bool get hasFailed => _stage == BootstrapStage.failed;

  final String astrbotRoot =
      Platform.environment['LUMI_ASTRBOT_ROOT'] ??
      'D:\\astrbot-develop\\AstrBot';

  BootstrapService(this._ws) {
    unawaited(start());
  }

  Future<void> retry() async {
    if (_stage != BootstrapStage.failed) return;
    _error = null;
    _logs.clear();
    notifyListeners();
    await start();
  }

  Future<void> start() async {
    await _ensureLogFileReady();
    _setStage(BootstrapStage.checkingEnv);
    _log('正在初始化内核...');

    final pythonOk = await _checkPythonAvailable();
    if (!pythonOk) {
      _fail('未检测到 Python，请确认 python 已加入 PATH。');
      return;
    }
    _log('Python 环境检测通过。');

    _setStage(BootstrapStage.checkingHost);
    _log('正在检测 AstrBot Host 连通性 ($_hostAddress:$_hostPort)...');

    final hostOnline = await _isHostReachable();
    if (hostOnline) {
      _log('Host 已在线，跳过 AstrBot 启动。');
    } else {
      _setStage(BootstrapStage.startingAstrBot);
      _log('Host 未在线，正在拉起 AstrBot...');

      final started = await _startAstrBot();
      if (!started) {
        _fail('AstrBot 启动失败，请检查路径: $astrbotRoot');
        return;
      }

      _setStage(BootstrapStage.waitingHost);
      _log('AstrBot 已启动，等待 Host 端口就绪...');

      final ready = await _waitHostReady(const Duration(seconds: 45));
      if (!ready) {
        _fail('等待 Host 超时（45 秒），请查看 AstrBot 控制台日志。');
        return;
      }
      _log('Host 端口已就绪。');
    }

    _setStage(BootstrapStage.connectingWs);
    _log('正在连接 WebSocket 并准备进入登录界面...');
    await _ws.connect();

    final wsConnected = await _waitWsConnected(const Duration(seconds: 10));
    if (!wsConnected) {
      _fail('WebSocket 连接失败，请确认 Host 已正常监听 8765。');
      return;
    }

    _log('启动准备完成。');
    _setStage(BootstrapStage.ready);
  }

  Future<bool> _checkPythonAvailable() async {
    try {
      final result = await Process.run('python', ['--version']);
      if (result.exitCode == 0) {
        final version = result.stdout.toString().trim().isNotEmpty
            ? result.stdout.toString().trim()
            : result.stderr.toString().trim();
        if (version.isNotEmpty) {
          _log('Python 版本: $version');
        }
        return true;
      }

      _log('Python 检测失败，退出码: ${result.exitCode}', level: LogLevel.error);
      final err = result.stderr.toString().trim();
      if (err.isNotEmpty) {
        _log('Python 错误输出: $err', level: LogLevel.error);
      }
      return false;
    } catch (_) {
      _log('Python 检测异常：无法执行 python --version', level: LogLevel.error);
      return false;
    }
  }

  Future<bool> _startAstrBot() async {
    final mainFile = File('$astrbotRoot\\main.py');
    if (!await mainFile.exists()) {
      _log('未找到 AstrBot 启动文件: ${mainFile.path}', level: LogLevel.error);
      return false;
    }

    try {
      final process = await Process.start(
        'python',
        ['main.py'],
        workingDirectory: astrbotRoot,
        mode: ProcessStartMode.detached,
      );
      _startedAstrBotByHub = true;
      _astrBotPid = process.pid;
      _log('已发出启动命令: python main.py', level: LogLevel.debug);
      _log('AstrBot 进程 PID: ${process.pid}', level: LogLevel.debug);
      return true;
    } catch (e) {
      _log('启动 AstrBot 异常: $e', level: LogLevel.error);
      return false;
    }
  }

  Future<void> handleAppExit({required bool closeAstrBotOnExit}) async {
    if (!closeAstrBotOnExit) {
      _log('退出策略：保留 AstrBot 继续运行。');
      return;
    }

    if (_startedAstrBotByHub && _astrBotPid != null) {
      await _killAstrBotByPid(_astrBotPid!);
      return;
    }

    _log('退出策略：未检测到由 Hub 拉起的 AstrBot，不执行关闭。');
  }

  Future<void> _killAstrBotByPid(int pid) async {
    try {
      final result = await Process.run('taskkill', [
        '/PID',
        pid.toString(),
        '/T',
        '/F',
      ]);

      if (result.exitCode == 0) {
        _log('已关闭 AstrBot（PID: $pid）。');
      } else {
        _log('关闭 AstrBot 失败: ${result.stderr.toString().trim()}', level: LogLevel.error);
      }
    } catch (e) {
      _log('关闭 AstrBot 异常: $e', level: LogLevel.error);
    }
  }

  Future<void> openLogDirectory() async {
    if (_logDirectoryPath == null || _logDirectoryPath!.isEmpty) {
      _log('日志目录尚未初始化，无法打开。', level: LogLevel.warning);
      return;
    }

    try {
      await Process.start('explorer', [_logDirectoryPath!]);
    } catch (e) {
      _log('打开日志目录失败: $e', level: LogLevel.error);
    }
  }

  Future<bool> _waitHostReady(Duration timeout) async {
    final stopwatch = Stopwatch()..start();
    while (stopwatch.elapsed < timeout) {
      if (await _isHostReachable()) {
        return true;
      }
      await Future<void>.delayed(const Duration(milliseconds: 500));
    }
    return false;
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

  Future<bool> _isHostReachable() async {
    try {
      final socket = await Socket.connect(
        _hostAddress,
        _hostPort,
        timeout: const Duration(milliseconds: 500),
      );
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  void _setStage(BootstrapStage stage) {
    _stage = stage;
    notifyListeners();
  }

  void _log(String message, {LogLevel level = LogLevel.info}) {
    final entry = LogEntry(DateTime.now(), level, message);
    _logs.add(entry);
    if (_logs.length > 30) { // Keep a bit more logs for better debugging
      _logs.removeAt(0);
    }
    unawaited(_appendLogLine(entry.toString()));
    notifyListeners();
  }

  void _fail(String message) {
    _error = message;
    _log('启动失败: $message', level: LogLevel.error);
    if (_logFilePath != null) {
      _log('详细日志文件: $_logFilePath', level: LogLevel.info);
    }
    _stage = BootstrapStage.failed;
    notifyListeners();
  }

  Future<void> _ensureLogFileReady() async {
    if (_logFilePath != null && _logDirectoryPath != null) {
      await _appendLogLine('---------------- new session ----------------');
      return;
    }

    String? baseDir = Platform.environment['LOCALAPPDATA'];
    if (baseDir == null || baseDir.isEmpty) {
      baseDir = Directory.current.path;
    }

    final dir = Directory('$baseDir\\LumiHub\\logs');
    await dir.create(recursive: true);

    _logDirectoryPath = dir.path;
    
    final now = DateTime.now();
    final dateStr = '${now.year}-${now.month.toString().padLeft(2, '0')}-${now.day.toString().padLeft(2, '0')}';
    _logFilePath = '${dir.path}\\launcher_$dateStr.log';

    final file = File(_logFilePath!);
    if (!await file.exists()) {
      await file.create(recursive: true);
    }

    await _appendLogLine('---------------- new session ----------------');
    await _appendLogLine('日志文件初始化完成: $_logFilePath');
  }

  Future<void> _appendLogLine(String line) async {
    if (_logFilePath == null) return;
    try {
      final file = File(_logFilePath!);
      await file.writeAsString('$line\n', mode: FileMode.append, flush: true);
    } catch (_) {
      // Ignore disk write failures to avoid blocking startup flow.
    }
  }
}
