import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

class UnityLaunchResult {
  final bool ok;
  final String message;

  const UnityLaunchResult({required this.ok, required this.message});
}

class UnityLauncher {
  static const MethodChannel _channel = MethodChannel(
    'lumi_hub/unity_launcher',
  );

  static const String _windowsExeEnv = 'LUMI_UNITY_EXE';
  static const String _androidPackageEnv = 'LUMI_UNITY_ANDROID_PACKAGE';
  static const String _androidActivityEnv = 'LUMI_UNITY_ANDROID_ACTIVITY';

  static const String _defaultWindowsExe = r'E:\unity buildings\firefly.exe';
  static const String _defaultAndroidPackage =
      'com.UnityTechnologies.com.unity.template.urpblank';
  static const String _defaultAndroidActivity =
      'com.unity3d.player.UnityPlayerActivity';

  static String resolveWindowsExePath() {
    return Platform.environment[_windowsExeEnv] ?? _defaultWindowsExe;
  }

  static String resolveAndroidPackage() {
    return Platform.environment[_androidPackageEnv] ?? _defaultAndroidPackage;
  }

  static String resolveAndroidActivity() {
    return Platform.environment[_androidActivityEnv] ?? _defaultAndroidActivity;
  }

  static Future<UnityLaunchResult> launch({
    required String wsUrl,
    required String accessKey,
  }) async {
    if (kIsWeb) {
      return const UnityLaunchResult(ok: false, message: 'Web 端不支持拉起 Unity。');
    }

    if (Platform.isWindows) {
      return _launchWindows(wsUrl: wsUrl, accessKey: accessKey);
    }

    if (Platform.isAndroid) {
      return _launchAndroid(wsUrl: wsUrl, accessKey: accessKey);
    }

    return const UnityLaunchResult(ok: false, message: '当前平台暂不支持。');
  }

  static Future<UnityLaunchResult> _launchWindows({
    required String wsUrl,
    required String accessKey,
  }) async {
    final exePath = resolveWindowsExePath();
    if (wsUrl.trim().isEmpty) {
      return const UnityLaunchResult(ok: false, message: '连接地址为空。');
    }

    if (!File(exePath).existsSync()) {
      return UnityLaunchResult(
        ok: false,
        message: '未找到 Unity 可执行文件: $exePath',
      );
    }

    final args = <String>['--ws-url', wsUrl.trim()];
    if (accessKey.trim().isNotEmpty) {
      args..add('--access-key')..add(accessKey.trim());
    }

    try {
      await Process.start(
        exePath,
        args,
        mode: ProcessStartMode.detached,
      );
      return const UnityLaunchResult(ok: true, message: '已启动 Unity。');
    } catch (e) {
      return UnityLaunchResult(ok: false, message: '启动失败: $e');
    }
  }

  static Future<UnityLaunchResult> _launchAndroid({
    required String wsUrl,
    required String accessKey,
  }) async {
    final packageName = resolveAndroidPackage();
    final activityName = resolveAndroidActivity();

    if (packageName.trim().isEmpty) {
      return const UnityLaunchResult(ok: false, message: '未配置 Android 包名。');
    }

    try {
      final ok = await _channel.invokeMethod<bool>('launchUnityApp', {
        'packageName': packageName,
        'activityName': activityName,
        'extras': <String, String>{
          'ws_url': wsUrl.trim(),
          'access_key': accessKey.trim(),
        },
      });

      if (ok == true) {
        return const UnityLaunchResult(ok: true, message: '已拉起 Unity。');
      }

      return const UnityLaunchResult(ok: false, message: '拉起 Unity 失败。');
    } on PlatformException catch (e) {
      final msg = e.message?.trim();
      return UnityLaunchResult(
        ok: false,
        message: msg == null || msg.isEmpty ? '拉起 Unity 失败。' : msg,
      );
    } catch (e) {
      return UnityLaunchResult(ok: false, message: '拉起 Unity 异常: $e');
    }
  }
}
