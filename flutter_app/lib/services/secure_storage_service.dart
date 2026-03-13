import 'dart:convert';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';

class SecureStorageService {
  static const _usernameKey = 'auth_username';
  static const _passwordKey = 'auth_password';
  static const _tokenKey = 'auth_token';
  static const _roleKey = 'auth_role'; // 'teacher' | 'student'
  static const _cookiesKey = 'auth_cookies'; // session cookies for synergia
  static const _lessonTimesKey = 'lesson_times'; // cached lesson period times

  final FlutterSecureStorage _storage = const FlutterSecureStorage(
    aOptions: AndroidOptions(encryptedSharedPreferences: true),
  );

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
    await _storage.delete(key: _lessonTimesKey);
  }
}
