import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static const _usernameKey = 'auth_username';
  static const _passwordKey = 'auth_password';
  static const _tokenKey = 'auth_token';
  static const _roleKey = 'auth_role'; // 'teacher' | 'student'
  static const _cookiesKey = 'auth_cookies'; // session cookies for synergia
  static const _portalCookiesKey = 'auth_portal_cookies'; // portal.librus.pl cookies
  static const _lessonTimesKey = 'lesson_times'; // cached lesson period times

  // Copy of the login kept after an explicit "remember for fingerprint"
  // logout. Separate from the active credentials above, so a logged-out app
  // has no session, no auto-login and no background sync - the vault is only
  // ever read after a successful biometric prompt.
  static const _vaultUsernameKey = 'bio_username';
  static const _vaultPasswordKey = 'bio_password';
  static const _vaultRoleKey = 'bio_role';

  final FlutterSecureStorage _storage = const FlutterSecureStorage();

  Future<void> saveCredentials({
    required String username,
    required String password,
  }) async {
    await _storage.write(key: _usernameKey, value: username);
    await _storage.write(key: _passwordKey, value: password);
  }

  Future<({String? username, String? password})> readCredentials() async {
    final username = await _storage.read(key: _usernameKey);
    final password = await _storage.read(key: _passwordKey);
    return (username: username, password: password);
  }

  Future<void> saveBiometricVault({
    required String username,
    required String password,
    required String role,
  }) async {
    await _storage.write(key: _vaultUsernameKey, value: username);
    await _storage.write(key: _vaultPasswordKey, value: password);
    await _storage.write(key: _vaultRoleKey, value: role);
  }

  Future<({String username, String password, String role})?> readBiometricVault() async {
    final username = await _storage.read(key: _vaultUsernameKey);
    final password = await _storage.read(key: _vaultPasswordKey);
    if (username == null || password == null || username.isEmpty || password.isEmpty) return null;
    final role = await _storage.read(key: _vaultRoleKey) ?? 'teacher';
    return (username: username, password: password, role: role);
  }

  Future<void> clearBiometricVault() async {
    await _storage.delete(key: _vaultUsernameKey);
    await _storage.delete(key: _vaultPasswordKey);
    await _storage.delete(key: _vaultRoleKey);
  }

  Future<void> saveToken(String token) async {
    await _storage.write(key: _tokenKey, value: token);
  }

  Future<String?> readToken() {
    return _storage.read(key: _tokenKey);
  }

  Future<void> saveRole(String role) async {
    await _storage.write(key: _roleKey, value: role);
  }

  Future<String?> readRole() {
    return _storage.read(key: _roleKey);
  }

  Future<void> saveCookies(String cookies) async {
    await _storage.write(key: _cookiesKey, value: cookies);
  }

  Future<String?> readCookies() {
    return _storage.read(key: _cookiesKey);
  }

  Future<void> savePortalCookies(String cookies) async {
    await _storage.write(key: _portalCookiesKey, value: cookies);
  }

  Future<String?> readPortalCookies() {
    return _storage.read(key: _portalCookiesKey);
  }

  Future<void> saveLessonTimes(Map<int, Map<String, String>> times) async {
    final encoded = jsonEncode(times.map((k, v) => MapEntry(k.toString(), v)));
    await _storage.write(key: _lessonTimesKey, value: encoded);
  }

  Future<Map<int, Map<String, String>>?> readLessonTimes() async {
    final raw = await _storage.read(key: _lessonTimesKey);
    if (raw == null) return null;
    try {
      final decoded = jsonDecode(raw) as Map<String, dynamic>;
      return decoded.map((k, v) => MapEntry(int.parse(k), Map<String, String>.from(v as Map)));
    } catch (_) {
      return null;
    }
  }

  Future<void> clearAll() async {
    await _storage.delete(key: _usernameKey);
    await _storage.delete(key: _passwordKey);
    await _storage.delete(key: _tokenKey);
    await _storage.delete(key: _roleKey);
    await _storage.delete(key: _cookiesKey);
    await _storage.delete(key: _portalCookiesKey);
    await _storage.delete(key: _lessonTimesKey);
  }
}
