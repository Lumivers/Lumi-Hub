import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'screens/chat_screen.dart';
import 'services/app_settings.dart';
import 'services/ws_service.dart';
import 'theme/app_theme.dart';

void main() {
  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AppSettings()),
        ChangeNotifierProvider(create: (_) => WsService()..connect()),
      ],
      child: const FireflyApp(),
    ),
  );
}

class FireflyApp extends StatelessWidget {
  const FireflyApp({super.key});

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<AppSettings>();
    return MaterialApp(
      title: 'Firefly Hub',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.system,
      theme: AppTheme.light(fontFamily: settings.fontFamily),
      darkTheme: AppTheme.dark(fontFamily: settings.fontFamily),
      home: const ChatScreen(),
    );
  }
}
