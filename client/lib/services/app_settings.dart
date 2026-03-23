import 'package:flutter/foundation.dart';
import 'package:shared_preferences/shared_preferences.dart';

/// 可用字体选项（key: Flutter fontFamily 名，value: 显示名）
const Map<String, String> kAvailableFonts = {'': '系统默认', 'MiSans': 'MiSans'};

class AppSettings extends ChangeNotifier {
  static const String _fontKeyStorage = 'app.font_key';
  static const String _closeAstrBotOnExitStorage = 'app.close_astrbot_on_exit';

  String _fontFamily = 'MiSans'; // 默认使用 MiSans
  bool _closeAstrBotOnExit = false;

  AppSettings() {
    _load();
  }

  /// 当前字体族名（null = 系统默认，传给 ThemeData.fontFamily）
  String? get fontFamily => _fontFamily.isEmpty ? null : _fontFamily;

  /// 当前字体 key
  String get fontKey => _fontFamily;

  bool get closeAstrBotOnExit => _closeAstrBotOnExit;

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

  Future<void> _load() async {
    final prefs = await SharedPreferences.getInstance();
    _fontFamily = prefs.getString(_fontKeyStorage) ?? 'MiSans';
    _closeAstrBotOnExit = prefs.getBool(_closeAstrBotOnExitStorage) ?? false;
    notifyListeners();
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setString(_fontKeyStorage, _fontFamily);
    await prefs.setBool(_closeAstrBotOnExitStorage, _closeAstrBotOnExit);
  }
}
