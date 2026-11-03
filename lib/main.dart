import 'dart:async';

import 'package:flutter/material.dart';
import 'package:provider/provider.dart';

import 'state/app_state.dart';
import 'sync/scheduler.dart';
import 'ui/home_page.dart';
import 'ui/login_page.dart';

const _seed = Color(0xFF0082C9);

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();

  final state = AppState();
  runApp(
    ChangeNotifierProvider<AppState>.value(
      value: state,
      child: const NextcloudSyncApp(),
    ),
  );

  // Bootstrap after the first frame: a slow or misbehaving plugin must never
  // keep the user on the splash screen.
  unawaited(_bootstrap(state));
}

Future<void> _bootstrap(AppState state) async {
  try {
    await state.init().timeout(const Duration(seconds: 20));
  } catch (e) {
    debugPrint('初始化失败: $e');
  }
  try {
    await Scheduler.init().timeout(const Duration(seconds: 15));
    if (state.loggedIn) {
      await Scheduler.schedule(state.settings)
          .timeout(const Duration(seconds: 15));
    }
  } catch (e) {
    debugPrint('后台任务初始化失败: $e');
  }
}

class NextcloudSyncApp extends StatelessWidget {
  const NextcloudSyncApp({super.key});

  @override
  Widget build(BuildContext context) {
    return MaterialApp(
      title: 'Nextcloud 同步',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.light,
        ),
        useMaterial3: true,
        visualDensity: VisualDensity.standard,
      ),
      darkTheme: ThemeData(
        colorScheme: ColorScheme.fromSeed(
          seedColor: _seed,
          brightness: Brightness.dark,
        ),
        useMaterial3: true,
      ),
      themeMode: ThemeMode.system,
      home: Consumer<AppState>(
        builder: (context, state, _) {
          if (!state.initialized) {
            return const Scaffold(
              body: Center(child: CircularProgressIndicator()),
            );
          }
          return state.loggedIn ? const HomePage() : const LoginPage();
        },
      ),
    );
  }
}
