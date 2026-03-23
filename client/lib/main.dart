import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:window_manager/window_manager.dart';

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

  await windowManager.ensureInitialized();

  Display primaryDisplay = await screenRetriever.getPrimaryDisplay();
  Size screenSize = primaryDisplay.size;
  Size initialSize = Size(screenSize.width * 0.618, screenSize.height * 0.618);

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
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettings()),
        ChangeNotifierProvider(create: (_) => WsService()),
        ChangeNotifierProxyProvider<WsService, BootstrapService>(
          create: (context) => BootstrapService(context.read<WsService>()),
          update: (context, ws, previous) => previous ?? BootstrapService(ws),
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

class _LumiAppState extends State<LumiApp> with WindowListener {
  bool _isClosing = false;

  @override
  void initState() {
    super.initState();
    windowManager.addListener(this);
  }

  @override
  void dispose() {
    windowManager.removeListener(this);
    super.dispose();
  }

  @override
  Future<void> onWindowClose() async {
    if (_isClosing) return;
    _isClosing = true;

    final settings = context.read<AppSettings>();
    final bootstrap = context.read<BootstrapService>();
    await bootstrap.handleAppExit(
      closeAstrBotOnExit: settings.closeAstrBotOnExit,
    );

    await windowManager.destroy();
  }

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return MaterialApp(
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
