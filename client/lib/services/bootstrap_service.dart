import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'ws_service.dart';

enum BootstrapStage {
  init,
  startingHost,
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

  bool _offlineMode = false;
  bool get isOfflineMode => _offlineMode;

  void enterOfflineMode() {
    _offlineMode = true;
    _stage = BootstrapStage.ready;
    notifyListeners();
  }

  /// 是否为首次运行（需要显示引导向导）。
  /// 条件：向导未完成 且 未激活离线跳过。
  bool get isFirstRun => !_setupCompleted && !_offlineMode;

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

  // ── 伴生内核进程 (Sidecar) ──
  Process? _hostProcess;

  Future<void> start() async {
    _setStage(BootstrapStage.init);
    _log('正在初始化客户端环境...');

    final uri = Uri.tryParse(_ws.serverUrl);
    final host = (uri?.host.isNotEmpty ?? false) ? uri!.host : '127.0.0.1';
    final port = (uri?.hasPort ?? false) ? uri!.port : 8765;
    final isLocal = host == '127.0.0.1' || host == 'localhost';

    // 1. 如果是连接本地 Host，先探活；未通则自动拉起伴生进程
    if (isLocal) {
      final alreadyRunning = await _isPortOpen(host, port);
      if (alreadyRunning) {
        _log('检测到本地 Host 服务已在运行 (端口 $port)，直接复用。');
      } else {
        _setStage(BootstrapStage.startingHost);
        _log('未检测到运行中的 Host 服务，准备自动拉起内核...');
        final spawned = await _spawnHostProcess(port);
        if (!spawned) {
          _fail('无法自动启动内核服务。请确认本地 Python 环境或依赖已正确安装。');
          return;
        }
      }
    }

    // 2. 建立 WebSocket 连接
    _setStage(BootstrapStage.connectingWs);
    _log('正在连接 Host: ${_ws.serverUrl}');

    await _ws.connect();

    final wsConnected = await _waitWsConnected(const Duration(seconds: 15));
    if (!wsConnected) {
      _fail('无法连接到 Host (${_ws.serverUrl})。请确认 Host 已正常启动。');
      return;
    }

    _log('WebSocket 连接成功。');

    // 3. 检查 LLM 配置状态
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
        _log('LLM 未配置，请在设置向导中完成 API Key 配置。', level: LogLevel.warning);
      }
    }

    _log('启动准备完成。');
    _setStage(BootstrapStage.ready);
  }

  Future<bool> _isPortOpen(String host, int port,
      {Duration timeout = const Duration(milliseconds: 500)}) async {
    try {
      final socket = await Socket.connect(host, port, timeout: timeout);
      socket.destroy();
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<bool> _spawnHostProcess(int port) async {
    if (_hostProcess != null) return true;

    // 优先查找生产环境打包好的独立 host 可执行文件
    final bundledHost = _findBundledHostExecutable();
    if (bundledHost != null) {
      _log('找到打包内核程序: ${bundledHost.path}');
      return _launchProcess(
          bundledHost.path, [], bundledHost.parent.path, port);
    }

    // 开发环境：查找项目根目录与 Python 解释器
    final projectRoot = _findProjectRoot();
    if (projectRoot == null) {
      _log('未找到 host 源码目录 (host/main.py)', level: LogLevel.error);
      return false;
    }

    final pythonExe = await _findPythonExecutable(projectRoot);
    if (pythonExe == null) {
      _log('未检测到可用的 Python 解释器，请确保 Python 已加入环境变量或存在虚拟环境。',
          level: LogLevel.error);
      return false;
    }

    _log('使用 Python: $pythonExe 在 ${projectRoot.path} 启动 Host 模块');
    return _launchProcess(
      pythonExe,
      ['-m', 'host.main'],
      projectRoot.path,
      port,
    );
  }

  Future<bool> _launchProcess(
    String executable,
    List<String> args,
    String workingDirectory,
    int port,
  ) async {
    try {
      final env = Map<String, String>.from(Platform.environment);
      if (Platform.isLinux || Platform.isMacOS) {
        final home = Platform.environment['HOME'] ?? '';
        final localSites = [
          '$home/.local/lib/python3.13/site-packages',
          '$home/.local/lib/python3.12/site-packages',
          '$home/.local/lib/python3/site-packages',
        ];
        final existing = env['PYTHONPATH'] ?? '';
        final pathsToAdd =
            localSites.where((p) => Directory(p).existsSync()).toList();
        if (pathsToAdd.isNotEmpty) {
          final prefix = pathsToAdd.join(':');
          env['PYTHONPATH'] = existing.isNotEmpty ? '$prefix:$existing' : prefix;
        }
      }

      // runInShell: false 保证 Windows 桌面端不会弹黑窗口 cmd
      _hostProcess = await Process.start(
        executable,
        args,
        workingDirectory: workingDirectory,
        environment: env,
        runInShell: false,
      );

      _log('内核服务已启动 (PID: ${_hostProcess!.pid})');

      _hostProcess!.stdout.transform(utf8.decoder).listen((data) {
        for (final line in data.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) {
            _log('[Host] $trimmed', level: LogLevel.debug);
          }
        }
      });

      _hostProcess!.stderr.transform(utf8.decoder).listen((data) {
        for (final line in data.split('\n')) {
          final trimmed = line.trim();
          if (trimmed.isNotEmpty) {
            _log('[Host ERR] $trimmed', level: LogLevel.warning);
          }
        }
      });

      bool processExited = false;
      int? exitCode;
      _hostProcess!.exitCode.then((code) {
        processExited = true;
        exitCode = code;
        if (_stage != BootstrapStage.ready && !isReady) {
          _fail('内核服务异常退出，退出码: $code');
        }
      });

      // 轮询等待端口真正开放（最多等待 15 秒）
      final stopwatch = Stopwatch()..start();
      while (stopwatch.elapsed < const Duration(seconds: 15)) {
        if (processExited) {
          _log('内核服务进程已提前终止 (退出码: $exitCode)', level: LogLevel.error);
          return false;
        }
        if (await _isPortOpen('127.0.0.1', port)) {
          _log('内核服务端口 ($port) 监听就绪。');
          return true;
        }
        await Future.delayed(const Duration(milliseconds: 300));
      }

      _log('等待内核端口 ($port) 开放超时', level: LogLevel.error);
      return false;
    } catch (e) {
      _log('启动内核进程失败: $e', level: LogLevel.error);
      return false;
    }
  }

  File? _findBundledHostExecutable() {
    final exeDir = File(Platform.resolvedExecutable).parent;
    final isWin = Platform.isWindows;
    final candidates = [
      File('${exeDir.path}/${isWin ? "host.exe" : "host"}'),
      File('${exeDir.path}/bin/${isWin ? "host.exe" : "host"}'),
      File('${exeDir.path}/bin/host/${isWin ? "host.exe" : "host"}'),
      File('${exeDir.path}/data/${isWin ? "host.exe" : "host"}'),
    ];
    for (final file in candidates) {
      if (file.existsSync()) return file;
    }
    return null;
  }

  Directory? _findProjectRoot() {
    Directory current = Directory.current;
    for (int i = 0; i < 5; i++) {
      if (File('${current.path}/host/main.py').existsSync()) {
        return current;
      }
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }

    current = File(Platform.resolvedExecutable).parent;
    for (int i = 0; i < 8; i++) {
      if (File('${current.path}/host/main.py').existsSync()) {
        return current;
      }
      final parent = current.parent;
      if (parent.path == current.path) break;
      current = parent;
    }
    return null;
  }

  Future<String?> _findPythonExecutable(Directory projectRoot) async {
    final isWin = Platform.isWindows;
    // 1. 优先检查项目根目录下的虚拟环境
    final venvCandidates = [
      '${projectRoot.path}/.venv/${isWin ? "Scripts/python.exe" : "bin/python3"}',
      '${projectRoot.path}/client/.venv/${isWin ? "Scripts/python.exe" : "bin/python3"}',
      '${projectRoot.path}/venv/${isWin ? "Scripts/python.exe" : "bin/python3"}',
      '${projectRoot.path}/.venv/${isWin ? "Scripts/python.exe" : "bin/python"}',
      '${projectRoot.path}/client/.venv/${isWin ? "Scripts/python.exe" : "bin/python"}',
      '${projectRoot.path}/venv/${isWin ? "Scripts/python.exe" : "bin/python"}',
    ];
    for (final path in venvCandidates) {
      if (File(path).existsSync()) {
        return path;
      }
    }

    // 2. 检查系统 PATH 命令
    final commandCandidates = isWin
        ? ['python', 'py', 'python3']
        : ['python3', 'python'];

    for (final cmd in commandCandidates) {
      try {
        final result = await Process.run(cmd, ['--version']);
        if (result.exitCode == 0) {
          return cmd;
        }
      } catch (_) {}
    }
    return null;
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
    debugPrint('[Bootstrap] $message');
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
    if (_hostProcess != null) {
      try {
        _log('正在关闭内核服务...');
        _hostProcess!.kill(ProcessSignal.sigterm);
        await Future.any([
          _hostProcess!.exitCode,
          Future.delayed(const Duration(milliseconds: 1500)),
        ]);
        _hostProcess!.kill(ProcessSignal.sigkill);
      } catch (e) {
        debugPrint('[Bootstrap] 关闭 Host 异常: $e');
      } finally {
        _hostProcess = null;
      }
    }
  }
}
