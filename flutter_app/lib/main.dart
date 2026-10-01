import 'dart:io';
import 'package:flutter/material.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';
import 'package:workmanager/workmanager.dart';
import 'package:plan_mechanika/screens/login_screen.dart';
import 'package:plan_mechanika/screens/home_screen.dart';
import 'package:plan_mechanika/services/background_sync_service.dart';
import 'package:plan_mechanika/services/biometric_auth_service.dart';
import 'package:plan_mechanika/services/notification_service.dart';
import 'package:plan_mechanika/services/release_logging.dart';
import 'package:plan_mechanika/services/timetable_service.dart';

void main() async {
  silenceDebugLogsInRelease();
  WidgetsFlutterBinding.ensureInitialized();

  // sqflite requires FFI on desktop platforms
  if (Platform.isWindows || Platform.isLinux || Platform.isMacOS) {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  }

  await NotificationService().init();
  await _registerBackgroundSync();
  runApp(const PlanMechanikaApp());
}

/// Periodically re-fetches the timetable in the background so the user gets
/// notified about plan changes (and the home screen widget stays current)
/// even while the app isn't open. Android only — see background_sync_service.dart.
///
/// Runs at most once an hour, and only when there's a network connection
/// (NetworkType.connected below) — school buildings often have no signal, so
/// WorkManager simply holds the job until connectivity comes back (e.g. the
/// first wifi/data the phone gets in the morning) instead of retrying blindly.
Future<void> _registerBackgroundSync() async {
  if (!Platform.isAndroid) return;
  try {
    await Workmanager().initialize(backgroundSyncCallbackDispatcher);
    await Workmanager().registerPeriodicTask(
      backgroundSyncTaskName,
      backgroundSyncTaskName,
      frequency: const Duration(hours: 1),
      constraints: Constraints(networkType: NetworkType.connected),
      // `replace` (not `keep`) so devices upgrading from the old 30-minute
      // build actually pick up the new hourly frequency.
      existingWorkPolicy: ExistingPeriodicWorkPolicy.replace,
    );
  } catch (_) {
    // Background sync is a nice-to-have — never block app startup on it.
  }
}

class PlanMechanikaApp extends StatefulWidget {
  const PlanMechanikaApp({super.key});

  @override
  State<PlanMechanikaApp> createState() => _PlanMechanikaAppState();
}

class _PlanMechanikaAppState extends State<PlanMechanikaApp> {
  final TimetableService _service = TimetableService();
  final BiometricAuthService _biometricAuth = BiometricAuthService();
  bool _loading = true;
  bool _loggedIn = false;
  String? _initialUsername;
  String _initialRole = 'teacher';
  bool _canUseBiometric = false;
  bool _biometricAvailable = false;

  @override
  void initState() {
    super.initState();
    _bootstrap();
  }

  Future<void> _bootstrap() async {
    final hasCreds = await _service.hasSavedCredentials();
    final username = await _service.getSavedUsername();

    final savedRole = await _service.getSavedRole() ?? 'teacher';

    // Previously this ran the full login chain (OAuth + portal SSO + token
    // exchange — several sequential network round trips) on every single
    // app launch before showing anything. That's redundant: HomeScreen
    // already paints the cached plan instantly and TimetableService itself
    // re-authenticates transparently in the background only if the saved
    // session actually turns out to be dead (see getTodayLessons ->
    // _fetchRemoteTimetable / autoLoginIfPossible). So just trust saved
    // credentials here and let the real fetch sort out login lazily.
    _loggedIn = hasCreds;

    // Only offer the fingerprint shortcut when there's actually a saved
    // password to fill in AND the device supports biometrics — otherwise
    // the button would just be a dead end.
    final biometricAvailable = await _biometricAuth.isAvailable();
    final vault = await _service.readBiometricVault();
    final canUseBiometric = biometricAvailable && vault != null;

    if (!mounted) {
      return;
    }

    setState(() {
      _initialUsername = username ?? vault?.username;
      _initialRole = vault?.role ?? savedRole;
      _biometricAvailable = biometricAvailable;
      _canUseBiometric = canUseBiometric;
      _loading = false;
    });
  }

  Future<({String username, String password, String role})?> _biometricFill() async {
    final authenticated = await _biometricAuth.authenticate();
    if (!authenticated) return null;
    return _service.readBiometricVault();
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

  Future<void> _forgetSavedLogin() async {
    await _service.forgetBiometricVault();
    if (!mounted) {
      return;
    }
    setState(() {
      _canUseBiometric = false;
    });
  }

  Future<void> _logout(bool rememberForBiometric) async {
    await _service.logout(rememberForBiometric: rememberForBiometric);
    final vault = await _service.readBiometricVault();
    if (!mounted) {
      return;
    }
    setState(() {
      _loggedIn = false;
      _canUseBiometric = _biometricAvailable && vault != null;
      _initialUsername = vault?.username;
      _initialRole = vault?.role ?? _initialRole;
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
        canRememberForBiometric: _biometricAvailable,
        timetableService: _service,
      );
    } else {
      home = LoginScreen(
        onLogin: _login,
        initialUsername: _initialUsername,
        initialRole: _initialRole,
        canUseBiometric: _canUseBiometric,
        onBiometricFill: _biometricFill,
        onForgetSavedLogin: _forgetSavedLogin,
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
