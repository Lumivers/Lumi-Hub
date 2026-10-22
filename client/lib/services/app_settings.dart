import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'dart:async';

/// 可用字体选项（key: Flutter fontFamily 名，value: 显示名）
const Map<String, String> kAvailableFonts = {'': '系统默认', 'MiSans': 'MiSans'};

enum WindowCloseAction { ask, minimize, exit }

const Map<WindowCloseAction, String> kWindowCloseActionLabels = {
  WindowCloseAction.ask: '每次询问',
  WindowCloseAction.minimize: '默认最小化到后台',
  WindowCloseAction.exit: '默认直接退出',
};

class AppSettings extends ChangeNotifier {
  final Completer<void> _loadedCompleter = Completer<void>();
  bool _isLoaded = false;
  static const String _fontKeyStorage = 'app.font_key';
  static const String _windowCloseActionStorage = 'app.window_close_action';
  static const String _enableAiVoiceOutputStorage = 'app.enable_ai_voice_output';
  static const String _ttsVoiceIdStorage = 'app.tts_voice_id';

  String _fontFamily = 'MiSans'; // 默认使用 MiSans
  WindowCloseAction _windowCloseAction = WindowCloseAction.ask;
  bool _enableAiVoiceOutput = false;
  String _ttsVoiceId = '';

  AppSettings() {
    _load();
  }

  /// 当前字体族名（null = 系统默认，传给 ThemeData.fontFamily）
  String? get fontFamily => _fontFamily.isEmpty ? null : _fontFamily;

  /// 当前字体 key
  String get fontKey => _fontFamily;

  WindowCloseAction get windowCloseAction => _windowCloseAction;
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

  void setWindowCloseAction(WindowCloseAction value) {
    if (_windowCloseAction == value) return;
    _windowCloseAction = value;
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
    if (_ttsVoiceId == value) return;
    _ttsVoiceId = value;
    notifyListeners();
    _save();
  }

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _fontFamily = prefs.getString(_fontKeyStorage) ?? 'MiSans';

    final closeActionRaw = prefs.getString(_windowCloseActionStorage) ?? 'ask';
    _windowCloseAction = switch (closeActionRaw) {
      'minimize' => WindowCloseAction.minimize,
      'exit' => WindowCloseAction.exit,
      _ => WindowCloseAction.ask,
    };

    _enableAiVoiceOutput = prefs.getBool(_enableAiVoiceOutputStorage) ?? false;
    _ttsVoiceId = prefs.getString(_ttsVoiceIdStorage) ?? '';
    _isLoaded = true;
    if (!_loadedCompleter.isCompleted) {
      _loadedCompleter.complete();
    }
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fontKeyStorage, _fontFamily);

    final closeActionRaw = switch (_windowCloseAction) {
      WindowCloseAction.ask => 'ask',
      WindowCloseAction.minimize => 'minimize',
      WindowCloseAction.exit => 'exit',
    };
    await prefs.setString(_windowCloseActionStorage, closeActionRaw);
    await prefs.setBool(_enableAiVoiceOutputStorage, _enableAiVoiceOutput);
    await prefs.setString(_ttsVoiceIdStorage, _ttsVoiceId);
  }
}
