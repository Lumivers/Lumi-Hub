import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可用字体选项（key: Flutter fontFamily 名，value: 显示名）
const Map<String, String> kAvailableFonts = {'': '系统默认', 'MiSans': 'MiSans'};

enum WindowCloseAction { ask, minimize, exit }

const Map<WindowCloseAction, String> kWindowCloseActionLabels = {
  WindowCloseAction.ask: '每次询问',
  WindowCloseAction.minimize: '默认最小化到后台',
  WindowCloseAction.exit: '默认直接退出',
};

class AppSettings extends ChangeNotifier {
  static const String _fontKeyStorage = 'app.font_key';
  static const String _closeAstrBotOnExitStorage = 'app.close_astrbot_on_exit';
  static const String _windowCloseActionStorage = 'app.window_close_action';
  static const String _remoteClientModeStorage = 'app.remote_client_mode';

  String _fontFamily = 'MiSans'; // 默认使用 MiSans
  bool _closeAstrBotOnExit = false;
  WindowCloseAction _windowCloseAction = WindowCloseAction.ask;
  bool _remoteClientMode = false;

  AppSettings() {
    _load();
  }

  /// 当前字体族名（null = 系统默认，传给 ThemeData.fontFamily）
  String? get fontFamily => _fontFamily.isEmpty ? null : _fontFamily;

  /// 当前字体 key
  String get fontKey => _fontFamily;

  bool get closeAstrBotOnExit => _closeAstrBotOnExit;
  WindowCloseAction get windowCloseAction => _windowCloseAction;
  bool get remoteClientMode => _remoteClientMode;

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

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _fontFamily = prefs.getString(_fontKeyStorage) ?? 'MiSans';
    _closeAstrBotOnExit = prefs.getBool(_closeAstrBotOnExitStorage) ?? false;
    final closeActionRaw = prefs.getString(_windowCloseActionStorage) ?? 'ask';
    _windowCloseAction = switch (closeActionRaw) {
      'minimize' => WindowCloseAction.minimize,
      'exit' => WindowCloseAction.exit,
      _ => WindowCloseAction.ask,
    };
    final mobileDefault = !kIsWeb &&
        (defaultTargetPlatform == TargetPlatform.android ||
            defaultTargetPlatform == TargetPlatform.iOS);
    _remoteClientMode =
        prefs.getBool(_remoteClientModeStorage) ?? mobileDefault;
    notifyListeners();
  }

  Future<void> _save() async {
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
  }
}
