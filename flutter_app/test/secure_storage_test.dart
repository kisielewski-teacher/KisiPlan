import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:plan_mechanika/services/secure_storage_service.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  setUp(() => FlutterSecureStorage.setMockInitialValues({}));

  group('credentials', () {
    test('saved credentials are read back', () async {
      final storage = SecureStorageService();
      await storage.saveCredentials(username: 'jan', password: 'tajne');

      final creds = await storage.readCredentials();

      expect(creds.username, 'jan');
      expect(creds.password, 'tajne');
    });

    test('clearAll removes credentials, role and cookies', () async {
      final storage = SecureStorageService();
      await storage.saveCredentials(username: 'jan', password: 'tajne');
      await storage.saveRole('student');
      await storage.saveCookies('a=b');

      await storage.clearAll();

      final creds = await storage.readCredentials();
      expect(creds.username, isNull);
      expect(creds.password, isNull);
      expect(await storage.readRole(), isNull);
      expect(await storage.readCookies(), isNull);
    });
  });

  group('biometric vault', () {
    test('is empty by default', () async {
      expect(await SecureStorageService().readBiometricVault(), isNull);
    });

    test('stores and returns username, password and role', () async {
      final storage = SecureStorageService();
      await storage.saveBiometricVault(username: 'jan', password: 'tajne', role: 'student');

      final vault = await storage.readBiometricVault();

      expect(vault, isNotNull);
      expect(vault!.username, 'jan');
      expect(vault.password, 'tajne');
      expect(vault.role, 'student');
    });

    test('survives clearAll (that is the point of logging out with the vault)', () async {
      final storage = SecureStorageService();
      await storage.saveCredentials(username: 'jan', password: 'tajne');
      await storage.saveBiometricVault(username: 'jan', password: 'tajne', role: 'teacher');

      await storage.clearAll();

      expect(await storage.readBiometricVault(), isNotNull);
      expect((await storage.readCredentials()).password, isNull);
    });

    test('clearBiometricVault removes it', () async {
      final storage = SecureStorageService();
      await storage.saveBiometricVault(username: 'jan', password: 'tajne', role: 'teacher');

      await storage.clearBiometricVault();

      expect(await storage.readBiometricVault(), isNull);
    });

    test('an incomplete vault (no password) counts as empty', () async {
      FlutterSecureStorage.setMockInitialValues({'bio_username': 'jan'});

      expect(await SecureStorageService().readBiometricVault(), isNull);
    });

    test('role defaults to teacher when missing', () async {
      FlutterSecureStorage.setMockInitialValues({'bio_username': 'jan', 'bio_password': 'x'});

      expect((await SecureStorageService().readBiometricVault())!.role, 'teacher');
    });
  });
}
