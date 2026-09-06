import 'dart:io';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'screens/accounts_onboarding_screen.dart';
import 'screens/downloads_screen.dart';
import 'screens/home_screen.dart';
import 'screens/settings_screen.dart';
import 'services/background_service.dart';
import 'services/download_manager.dart';
import 'services/notification_service.dart';
import 'services/settings_service.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final prefs = await SharedPreferences.getInstance();
  final settings = SettingsService(prefs);

  final notifications = NotificationService();
  await notifications.init();
  await BackgroundKeeper.instance.init();

  runApp(
    MultiProvider(
      providers: [
        ChangeNotifierProvider.value(value: settings),
        ChangeNotifierProvider(
          create: (_) => DownloadManager(
            settings: settings,
            notifications: notifications,
          ),
        ),
      ],
      child: const VidFetchApp(),
    ),
  );
}

class VidFetchApp extends StatelessWidget {
  const VidFetchApp({super.key});

  @override
  Widget build(BuildContext context) {
    final scheme = ColorScheme.fromSeed(
      seedColor: const Color(0xFF7C4DFF),
      brightness: Brightness.dark,
    );
    return MaterialApp(
      title: 'VidFetch',
      debugShowCheckedModeBanner: false,
      themeMode: ThemeMode.dark,
      darkTheme: ThemeData(
        useMaterial3: true,
        colorScheme: scheme,
        scaffoldBackgroundColor: const Color(0xFF121212),
        inputDecorationTheme: InputDecorationTheme(
          filled: true,
          border: OutlineInputBorder(
            borderRadius: BorderRadius.circular(14),
            borderSide: BorderSide.none,
          ),
        ),
        cardTheme: CardThemeData(
          elevation: 0,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
        ),
      ),
      theme: ThemeData(useMaterial3: true, colorScheme: scheme),
      home: const _AppEntry(),
    );
  }
}

/// Shows first-run account onboarding on Android, then the main shell.
class _AppEntry extends StatelessWidget {
  const _AppEntry();

  @override
  Widget build(BuildContext context) {
    final settings = context.watch<SettingsService>();
    if (Platform.isAndroid && !settings.onboardingDone) {
      return AccountsOnboardingScreen(
        onFinished: () {
          // SettingsService notifies; rebuild swaps to RootShell.
        },
      );
    }
    return const RootShell();
  }
}

class RootShell extends StatefulWidget {
  const RootShell({super.key});

  @override
  State<RootShell> createState() => _RootShellState();
}

class _RootShellState extends State<RootShell> {
  int _index = 0;

  static const _screens = [
    HomeScreen(),
    DownloadsScreen(),
    SettingsScreen(),
  ];

  @override
  Widget build(BuildContext context) {
    final activeCount = context.watch<DownloadManager>().activeTasks.length;

    return Scaffold(
      body: IndexedStack(index: _index, children: _screens),
      bottomNavigationBar: NavigationBar(
        selectedIndex: _index,
        onDestinationSelected: (i) => setState(() => _index = i),
        destinations: [
          const NavigationDestination(
            icon: Icon(Icons.download_outlined),
            selectedIcon: Icon(Icons.download),
            label: 'Download',
          ),
          NavigationDestination(
            icon: Badge(
              isLabelVisible: activeCount > 0,
              label: Text('$activeCount'),
              child: const Icon(Icons.queue_outlined),
            ),
            selectedIcon: const Icon(Icons.queue),
            label: 'Queue',
          ),
          const NavigationDestination(
            icon: Icon(Icons.settings_outlined),
            selectedIcon: Icon(Icons.settings),
            label: 'Settings',
          ),
        ],
      ),
    );
  }
}
