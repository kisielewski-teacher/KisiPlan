import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:workmanager/workmanager.dart';
import 'package:kisiplan/screens/login_screen.dart';
import 'package:kisiplan/screens/home_screen.dart';
import 'package:kisiplan/services/background_sync_service.dart';
import 'package:kisiplan/services/notification_service.dart';
import 'package:kisiplan/services/timetable_service.dart';

void main() async {
  WidgetsFlutterBinding.ensureInitialized();

  // sqflite requires FFI on desktop platforms
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  await NotificationService().init();
  await _registerBackgroundSync();
  runApp(const SzkolplanApp());
}

/// Periodically re-fetches the timetable in the background so the user gets
/// notified about plan changes (and the home screen widget stays current)
/// even while the app isn't open. Android only — see background_sync_service.dart.
Future<void> _registerBackgroundSync() async {
  if (!Platform.isAndroid) return;
  try {
    await Workmanager().initialize(backgroundSyncCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      backgroundSyncTaskName,
      backgroundSyncTaskName,
      frequency: const Duration(minutes: 30),
      constraints: Constraints(networkType: NetworkType.connected),
      existingWorkPolicy: ExistingPeriodicWorkPolicy.keep,
    );
  } catch (_) {
    // Background sync is a nice-to-have — never block app startup on it.
  }
}

class SzkolplanApp extends StatefulWidget {
  const SzkolplanApp({super.key});

  @override
  State<SzkolplanApp> createState() => _SzkolplanAppState();
}

class _SzkolplanAppState extends State<SzkolplanApp> {
  final TimetableService _service = TimetableService();
  bool _loading = true;
  bool _loggedIn = false;
  String? _initialUsername;
  String _initialRole = 'teacher';

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final hasCreds = await _service.hasSavedCredentials();
    final username = await _service.getSavedUsername();

    final savedRole = await _service.getSavedRole() ?? 'teacher';

    if (hasCreds) {
      final loginError = await _service.autoLoginIfPossible();
      _loggedIn = loginError == null;
    }

    if (!mounted) {
      return;
    }

    setState(() {
      _initialUsername = username;
      _initialRole = savedRole;
      _loading = false;
    });
  }

  Future<String?> _login(String username, String password, String role) async {
    final error = await _service.login(username, password, role: role);
    if (error != null) {
      return error;
    }

    if (!mounted) {
      return null;
    }

    setState(() {
      _loggedIn = true;
    });
    return null;
  }

  Future<void> _logout() async {
    await _service.logout();
    if (!mounted) {
      return;
    }
    setState(() {
      _loggedIn = false;
    });
  }

  @override
  Widget build(BuildContext context) {
    final Widget home;
    if (_loading) {
      home = const Scaffold(
        body: Center(
          child: Column(
            mainAxisAlignment: MainAxisAlignment.center,
            children: [
              Image(image: AssetImage('assets/Mechanik.png'), width: 200),
              SizedBox(height: 24),
              CircularProgressIndicator(),
            ],
          ),
        ),
      );
    } else if (_loggedIn) {
      home = HomeScreen(
        onLogout: _logout,
        timetableService: _service,
      );
    } else {
      home = LoginScreen(
        onLogin: _login,
        initialUsername: _initialUsername,
        initialRole: _initialRole,
      );
    }

    return MaterialApp(
      title: 'Plan Mechanika',
      debugShowCheckedModeBanner: false,
      theme: ThemeData(
        colorScheme: ColorScheme.fromSeed(seedColor: Colors.blue),
        useMaterial3: true,
      ),
      home: home,
    );
  }
}
