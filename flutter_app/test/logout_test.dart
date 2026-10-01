import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_mechanika/services/timetable_service.dart';
import 'package:sqflite_common_ffi/sqflite_ffi.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUpAll(() {
    sqfliteFfiInit();
    databaseFactory = databaseFactoryFfi;
  });

  setUp(() {
    FlutterSecureStorage.setMockInitialValues({
      'auth_username': 'jan',
      'auth_password': 'tajne',
      'auth_role': 'student',
    });
  });

  test('plain logout wipes the credentials and leaves no biometric vault', () async {
    final service = TimetableService();
    expect(await service.hasSavedCredentials(), isTrue);

    await service.logout();

    expect(await service.hasSavedCredentials(), isFalse);
    expect(await service.readBiometricVault(), isNull);
  });

  test('logout with rememberForBiometric ends the session but keeps the login in the vault', () async {
    final service = TimetableService();

    await service.logout(rememberForBiometric: true);

    // Logged out: nothing for auto-login or background sync to use...
    expect(await service.hasSavedCredentials(), isFalse);
    expect(await service.getSavedUsername(), isNull);
    // ...but the fingerprint shortcut has what it needs.
    final vault = await service.readBiometricVault();
    expect(vault, isNotNull);
    expect(vault!.username, 'jan');
    expect(vault.password, 'tajne');
    expect(vault.role, 'student');
  });

  test('a later plain logout wipes a previously remembered vault', () async {
    final service = TimetableService();
    await service.logout(rememberForBiometric: true);

    await service.logout();

    expect(await service.readBiometricVault(), isNull);
  });

  test('forgetBiometricVault removes the remembered login', () async {
    final service = TimetableService();
    await service.logout(rememberForBiometric: true);

    await service.forgetBiometricVault();

    expect(await service.readBiometricVault(), isNull);
  });

  test('logging out when nothing is saved does not create a vault', () async {
    FlutterSecureStorage.setMockInitialValues({});
    final service = TimetableService();

    await service.logout(rememberForBiometric: true);

    expect(await service.readBiometricVault(), isNull);
  });
}
