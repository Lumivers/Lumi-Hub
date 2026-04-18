import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/foundation.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';
import 'package:tray_manager/tray_manager.dart';

import 'package:screen_retriever/screen_retriever.dart';

import 'screens/chat_screen.dart';
import 'screens/auth_screen.dart';
import 'screens/bootstrap_screen.dart';
import 'services/app_settings.dart';
import 'services/bootstrap_service.dart';
import 'services/ws_service.dart';
import 'theme/app_theme.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  if (!kIsWeb && Platform.isWindows) {
    // 桌面端窗口初始化：按屏幕比例设置初始尺寸并启用拦截关闭。
    await windowManager.ensureInitialized();

    Display primaryDisplay = await screenRetriever.getPrimaryDisplay();
    Size screenSize = primaryDisplay.size;
    Size initialSize = Size(
      screenSize.width * 0.618,
      screenSize.height * 0.618,
    );

    WindowOptions windowOptions = WindowOptions(
      size: initialSize,
      center: true,
      title: 'Lumi Hub',
    );
    windowManager.waitUntilReadyToShow(windowOptions, () async {
      await windowManager.setPreventClose(true);
      await windowManager.show();
      await windowManager.focus();
    });
  }
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettings()),
        ChangeNotifierProvider(create: (_) => WsService()),
        ChangeNotifierProxyProvider2<WsService, AppSettings, BootstrapService>(
          create: (context) => BootstrapService(
            context.read<WsService>(),
            context.read<AppSettings>(),
          ),
          update: (context, ws, settings, previous) =>
              previous ?? BootstrapService(ws, settings),
        ),
      ],
      child: const LumiApp(),
    ),
  );
}

class LumiApp extends StatefulWidget {
  const LumiApp({super.key});

  @override
  State<LumiApp> createState() => _LumiAppState();
}

class _LumiAppState extends State<LumiApp> with WindowListener, TrayListener {
  bool _isClosing = false;
  final GlobalKey<NavigatorState> _navigatorKey = GlobalKey<NavigatorState>();

  Future<void> _initTray() async {
    if (!Platform.isWindows) return;
    await trayManager.setIcon(
      'windows/runner/resources/app_icon.ico',
    ); // use the same icon as the window
    await trayManager.setToolTip('Lumi Hub');
    await _updateTrayMenu();
  }

  Future<void> _updateTrayMenu() async {
    // 托盘菜单只保留两个核心动作：显示窗口、完全退出。
    final Menu menu = Menu(
      items: [
        MenuItem(key: 'show_window', label: '显示窗口'),
        MenuItem(key: 'exit_app', label: '完全退出'),
      ],
    );
    await trayManager.setContextMenu(menu);
  }

  @override
  void onTrayIconMouseDown() {
    windowManager.show();
    windowManager.focus();
  }

  @override
  void onTrayMenuItemClick(MenuItem menuItem) async {
    if (menuItem.key == 'show_window') {
      await windowManager.show();
      await windowManager.focus();
    } else if (menuItem.key == 'exit_app') {
      if (_isClosing) return;
      final settings = context.read<AppSettings>();
      final bootstrap = context.read<BootstrapService>();
      _isClosing = true;
      trayManager.destroy(); // hide tray immediately
      await bootstrap.handleAppExit(
        closeAstrBotOnExit: settings.closeAstrBotOnExit,
      );
      await windowManager.destroy();
    }
  }

  Future<WindowCloseAction> _confirmCloseAction(AppSettings settings) async {
    final dialogContext = _navigatorKey.currentContext;
    if (dialogContext == null) {
      // If UI tree is not ready, fallback to safe behavior.
      return WindowCloseAction.minimize;
    }

    bool rememberChoice = false;
    final result = await showDialog<WindowCloseAction>(
      context: dialogContext,
      builder: (context) {
        return StatefulBuilder(
          builder: (context, setDialogState) {
            return AlertDialog(
              title: const Text('关闭 Lumi Hub'),
              content: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  const Text('请选择关闭行为：最小化到托盘，或直接退出应用。'),
                  const SizedBox(height: 12),
                  CheckboxListTile(
                    contentPadding: EdgeInsets.zero,
                    dense: true,
                    title: const Text('记住本次选择，后续不再询问'),
                    value: rememberChoice,
                    onChanged: (value) {
                      setDialogState(() {
                        rememberChoice = value ?? false;
                      });
                    },
                  ),
                ],
              ),
              actions: [
                TextButton(
                  onPressed: () =>
                      Navigator.of(context).pop(WindowCloseAction.minimize),
                  child: const Text('最小化到托盘'),
                ),
                FilledButton(
                  onPressed: () =>
                      Navigator.of(context).pop(WindowCloseAction.exit),
                  child: const Text('直接退出'),
                ),
              ],
            );
          },
        );
      },
    );

    // 兜底默认最小化，避免误退出导致后台任务被中断。
    final action = result ?? WindowCloseAction.minimize;
    if (rememberChoice) {
      settings.setWindowCloseAction(action);
    }
    return action;
  }

  @override
  void initState() {
    super.initState();
    if (!kIsWeb && Platform.isWindows) {
      windowManager.addListener(this);
      trayManager.addListener(this);
      _initTray();
    }
  }

  @override
  void dispose() {
    if (!kIsWeb && Platform.isWindows) {
      trayManager.removeListener(this);
      windowManager.removeListener(this);
    }
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    if (_isClosing) return;

    final settings = context.read<AppSettings>();
    final bootstrap = context.read<BootstrapService>();
    WindowCloseAction closeAction = settings.windowCloseAction;
    if (closeAction == WindowCloseAction.ask) {
      closeAction = await _confirmCloseAction(settings);
      if (!mounted) return;
    }

    if (closeAction == WindowCloseAction.minimize) {
      await windowManager.hide(); // Use hide to put to tray
      return;
    }

    _isClosing = true;
    trayManager.destroy(); // make sure tray goes away
    await bootstrap.handleAppExit(
      closeAstrBotOnExit: settings.closeAstrBotOnExit,
    );

    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return MaterialApp(
      navigatorKey: _navigatorKey,
      title: 'Lumi Hub',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: AppTheme.light(fontFamily: settings.fontFamily),
      darkTheme: AppTheme.dark(fontFamily: settings.fontFamily),
      home: const AuthWrapper(),
    );
  }
}

class AuthWrapper extends StatelessWidget {
  const AuthWrapper({super.key});

  @override
  Widget build(BuildContext context) {
    final bootstrap = context.watch<BootstrapService>();
    final ws = context.watch<WsService>();

    // 页面路由优先级：启动流程 -> 鉴权页 -> 聊天页。
    if (!bootstrap.isReady) {
      return const BootstrapScreen();
    }

    // 如果没有鉴权通过，则展示 AuthScreen，否则展示 ChatScreen
    if (!ws.isAuthenticated) {
      return const AuthScreen();
    }
    return const ChatScreen();
  }
}
