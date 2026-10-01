import 'package:flutter_test/flutter_test.dart';
import 'package:package_info_plus/package_info_plus.dart';
import 'package:plan_mechanika/services/update_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

void _runningVersion(String version) {
  PackageInfo.setMockInitialValues(
    appName: 'Plan Mechanika',
    packageName: 'com.example.kisiplan',
    version: version,
    buildNumber: '1',
    buildSignature: '',
  );
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  group('UpdateService.cachedUpdate', () {
    test('returns nothing when no update was ever cached', () async {
      SharedPreferences.setMockInitialValues({});
      _runningVersion('1.4.30');

      expect(await UpdateService().cachedUpdate(), isNull);
    });

    test('returns the cached update when it is newer than the running version', () async {
      SharedPreferences.setMockInitialValues({
        'update_cached_version': '1.4.40',
        'update_cached_url': 'https://example.com/PlanMechanika.apk',
        'update_cached_notes': 'Nowości',
      });
      _runningVersion('1.4.39');

      final info = await UpdateService().cachedUpdate();

      expect(info, isNotNull);
      expect(info!.version, '1.4.40');
      expect(info.downloadUrl, 'https://example.com/PlanMechanika.apk');
      expect(info.releaseNotes, 'Nowości');
    });

    test('drops a stale cache once that version is already installed', () async {
      SharedPreferences.setMockInitialValues({
        'update_cached_version': '1.4.36',
        'update_cached_url': 'https://example.com/PlanMechanika.apk',
      });
      _runningVersion('1.4.36');
      final service = UpdateService();

      expect(await service.cachedUpdate(), isNull);

      final prefs = await SharedPreferences.getInstance();
      expect(prefs.getString('update_cached_version'), isNull);
      expect(prefs.getString('update_cached_url'), isNull);
    });

    test('also drops a cached version older than the running one', () async {
      SharedPreferences.setMockInitialValues({
        'update_cached_version': '1.4.20',
        'update_cached_url': 'https://example.com/old.apk',
      });
      _runningVersion('1.5.0');

      expect(await UpdateService().cachedUpdate(), isNull);
    });

    test('compares versions numerically, not as text (1.4.9 < 1.4.10)', () async {
      SharedPreferences.setMockInitialValues({
        'update_cached_version': '1.4.10',
        'update_cached_url': 'https://example.com/PlanMechanika.apk',
      });
      _runningVersion('1.4.9');

      expect(await UpdateService().cachedUpdate(), isNotNull);
    });
  });
}
