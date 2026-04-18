import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

/// 可用字体选项（key: Flutter fontFamily 名，value: 显示名）
const Map<String, String> kAvailableFonts = {'': '系统默认', 'MiSans': 'MiSans'};

enum WindowCloseAction { ask, minimize, exit }

enum ConnectionMode { localOrUsb, lan, publicTunnel }

const Map<WindowCloseAction, String> kWindowCloseActionLabels = {
  WindowCloseAction.ask: '每次询问',
  WindowCloseAction.minimize: '默认最小化到后台',
  WindowCloseAction.exit: '默认直接退出',
};

const Map<ConnectionMode, String> kConnectionModeLabels = {
  ConnectionMode.localOrUsb: '本机/USB 调试 (127.0.0.1)',
  ConnectionMode.lan: '局域网 (ws://192.168.x.x:8765)',
  ConnectionMode.publicTunnel: '公网/内网穿透 (wss://domain)',
};

class AppSettings extends ChangeNotifier {
  final Completer<void> _loadedCompleter = Completer<void>();
  bool _isLoaded = false;
  static const String _fontKeyStorage = 'app.font_key';
  static const String _closeAstrBotOnExitStorage = 'app.close_astrbot_on_exit';
  static const String _windowCloseActionStorage = 'app.window_close_action';
  static const String _remoteClientModeStorage = 'app.remote_client_mode';
  static const String _connectionModeStorage = 'app.connection_mode';
  static const String _askConnectionModeOnLaunchStorage =
      'app.ask_connection_mode_on_launch';
  static const String _enableAiVoiceOutputStorage =
      'app.enable_ai_voice_output';
  static const String _ttsVoiceIdStorage = 'app.tts_voice_id';

  String _fontFamily = 'MiSans'; // 默认使用 MiSans
  bool _closeAstrBotOnExit = false;
  WindowCloseAction _windowCloseAction = WindowCloseAction.ask;
  bool _remoteClientMode = false;
  ConnectionMode _connectionMode = ConnectionMode.localOrUsb;
  bool _askConnectionModeOnLaunch = true;
  bool _enableAiVoiceOutput = false;
  String _ttsVoiceId = '';

  AppSettings() {
    // 构造后异步加载本地持久化配置。
    _load();
  }

  /// 当前字体族名（null = 系统默认，传给 ThemeData.fontFamily）
  String? get fontFamily => _fontFamily.isEmpty ? null : _fontFamily;

  /// 当前字体 key
  String get fontKey => _fontFamily;

  bool get closeAstrBotOnExit => _closeAstrBotOnExit;
  WindowCloseAction get windowCloseAction => _windowCloseAction;
  bool get remoteClientMode => _remoteClientMode;
  ConnectionMode get connectionMode => _connectionMode;
  bool get askConnectionModeOnLaunch => _askConnectionModeOnLaunch;
  bool get enableAiVoiceOutput => _enableAiVoiceOutput;
  String get ttsVoiceId => _ttsVoiceId;
  bool get isLoaded => _isLoaded;
  Future<void> get loaded => _loadedCompleter.future;

  void setFontFamily(String key) {
    if (_fontFamily == key) return;
    _fontFamily = key;
    notifyListeners();
    _save();
  }

  void setCloseAstrBotOnExit(bool value) {
    if (_closeAstrBotOnExit == value) return;
    _closeAstrBotOnExit = value;
    notifyListeners();
    _save();
  }

  void setWindowCloseAction(WindowCloseAction value) {
    if (_windowCloseAction == value) return;
    _windowCloseAction = value;
    notifyListeners();
    _save();
  }

  void setRemoteClientMode(bool value) {
    if (_remoteClientMode == value) return;
    _remoteClientMode = value;
    notifyListeners();
    _save();
  }

  void setConnectionMode(ConnectionMode value) {
    if (_connectionMode == value) return;
    _connectionMode = value;
    notifyListeners();
    _save();
  }

  void setAskConnectionModeOnLaunch(bool value) {
    if (_askConnectionModeOnLaunch == value) return;
    _askConnectionModeOnLaunch = value;
    notifyListeners();
    _save();
  }

  void setEnableAiVoiceOutput(bool value) {
    if (_enableAiVoiceOutput == value) return;
    _enableAiVoiceOutput = value;
    notifyListeners();
    _save();
  }

  void setTtsVoiceId(String value) {
    final normalized = value.trim();
    if (_ttsVoiceId == normalized) return;
    _ttsVoiceId = normalized;
    notifyListeners();
    _save();
  }

  Future<void> _load() async {
    // 统一从 SharedPreferences 回填，缺省值按平台场景给出。
    final prefs = await SharedPreferences.getInstance();
    _fontFamily = prefs.getString(_fontKeyStorage) ?? 'MiSans';
    _closeAstrBotOnExit = prefs.getBool(_closeAstrBotOnExitStorage) ?? false;
    final closeActionRaw = prefs.getString(_windowCloseActionStorage) ?? 'ask';
    _windowCloseAction = switch (closeActionRaw) {
      'minimize' => WindowCloseAction.minimize,
      'exit' => WindowCloseAction.exit,
      _ => WindowCloseAction.ask,
    };
    final mobileDefault =
        !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    _remoteClientMode =
        prefs.getBool(_remoteClientModeStorage) ?? mobileDefault;

    final connectionModeRaw =
        prefs.getString(_connectionModeStorage) ??
        (mobileDefault ? 'lan' : 'local_or_usb');
    _connectionMode = switch (connectionModeRaw) {
      'lan' => ConnectionMode.lan,
      'public_tunnel' => ConnectionMode.publicTunnel,
      _ => ConnectionMode.localOrUsb,
    };

    _askConnectionModeOnLaunch =
        prefs.getBool(_askConnectionModeOnLaunchStorage) ?? true;
    _enableAiVoiceOutput = prefs.getBool(_enableAiVoiceOutputStorage) ?? false;
    _ttsVoiceId = prefs.getString(_ttsVoiceIdStorage) ?? '';
    _isLoaded = true;
    if (!_loadedCompleter.isCompleted) {
      _loadedCompleter.complete();
    }
    notifyListeners();
  }

  Future<void> _save() async {
    // 每次修改都持久化，保证重启后配置一致。
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fontKeyStorage, _fontFamily);
    await prefs.setBool(_closeAstrBotOnExitStorage, _closeAstrBotOnExit);
    final closeActionRaw = switch (_windowCloseAction) {
      WindowCloseAction.ask => 'ask',
      WindowCloseAction.minimize => 'minimize',
      WindowCloseAction.exit => 'exit',
    };
    await prefs.setString(_windowCloseActionStorage, closeActionRaw);
    await prefs.setBool(_remoteClientModeStorage, _remoteClientMode);

    final connectionModeRaw = switch (_connectionMode) {
      ConnectionMode.localOrUsb => 'local_or_usb',
      ConnectionMode.lan => 'lan',
      ConnectionMode.publicTunnel => 'public_tunnel',
    };
    await prefs.setString(_connectionModeStorage, connectionModeRaw);
    await prefs.setBool(
      _askConnectionModeOnLaunchStorage,
      _askConnectionModeOnLaunch,
    );
    await prefs.setBool(_enableAiVoiceOutputStorage, _enableAiVoiceOutput);
    await prefs.setString(_ttsVoiceIdStorage, _ttsVoiceId);
  }
}
