import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:http/http.dart' as http;
import 'package:package_info_plus/package_info_plus.dart';
import 'package:path_provider/path_provider.dart';

class UpdateInfo {
  final String version;
  final String downloadUrl;
  final String releaseNotes;

  UpdateInfo({
    required this.version,
    required this.downloadUrl,
    required this.releaseNotes,
  });
}

/// Checks GitHub Releases for a newer version of the app and installs it.
///
/// Relies on the CI workflow publishing a GitHub Release (tag `vX.Y.Z`) with
/// a `.apk` asset attached whenever a new version should be offered to users.
class UpdateService {
  static const _owner = 'kisielewski-teacher';
  static const _repo = 'KisiPlan';
  static const _channel = MethodChannel('com.example.kisiplan/installer');

  /// Returns update info if a newer version is published on GitHub, or null
  /// if the check succeeded but there's genuinely nothing newer (or the
  /// release has no APK asset attached).
  ///
  /// Throws on failure (offline, GitHub API rate limit, malformed response,
  /// ...) instead of swallowing it — callers that run silently in the
  /// background should catch and ignore; a manual "check now" button should
  /// show the error instead of misreporting "up to date".
  Future<UpdateInfo?> checkForUpdate() async {
    final http.Response res;
    try {
      res = await http
          .get(
            Uri.parse('https://api.github.com/repos/$_owner/$_repo/releases/latest'),
            headers: {'Accept': 'application/vnd.github+json'},
          )
          .timeout(const Duration(seconds: 10));
    } catch (e) {
      throw Exception('Brak połączenia z GitHubem.');
    }

    if (res.statusCode == 403) {
      throw Exception('GitHub odrzucił zapytanie (limit zapytań) — spróbuj ponownie za jakiś czas.');
    }
    if (res.statusCode == 404) {
      throw Exception('Nie znaleziono żadnego wydania na GitHubie.');
    }
    if (res.statusCode != 200) {
      throw Exception('GitHub zwrócił błąd (HTTP ${res.statusCode}).');
    }

    final Map<String, dynamic> data;
    try {
      data = json.decode(res.body) as Map<String, dynamic>;
    } catch (e) {
      throw Exception('Nieprawidłowa odpowiedź z GitHuba.');
    }

    final tag = (data['tag_name'] as String?) ?? '';
    final latestVersion = tag.startsWith('v') ? tag.substring(1) : tag;
    if (latestVersion.isEmpty) return null;

    final assets = (data['assets'] as List?) ?? [];
    String? downloadUrl;
    for (final raw in assets) {
      final asset = raw as Map<String, dynamic>;
      final name = (asset['name'] as String? ?? '').toLowerCase();
      if (name.endsWith('.apk')) {
        downloadUrl = asset['browser_download_url'] as String?;
        break;
      }
    }
    if (downloadUrl == null) return null;

    final currentVersion = (await PackageInfo.fromPlatform()).version;
    if (!_isNewer(latestVersion, currentVersion)) return null;

    return UpdateInfo(
      version: latestVersion,
      downloadUrl: downloadUrl,
      releaseNotes: (data['body'] as String?)?.trim() ?? '',
    );
  }

  bool _isNewer(String latest, String current) {
    final l = _parseVersion(latest);
    final c = _parseVersion(current);
    for (var i = 0; i < 3; i++) {
      if (l[i] != c[i]) return l[i] > c[i];
    }
    return false;
  }

  List<int> _parseVersion(String v) {
    final parts = v.split('.');
    return List.generate(3, (i) => i < parts.length ? (int.tryParse(parts[i]) ?? 0) : 0);
  }

  /// Downloads [url] to the app's cache dir, reporting progress in [0, 1].
  Future<File> download(String url, void Function(double progress) onProgress) async {
    final response = await http.Client().send(http.Request('GET', Uri.parse(url)));
    if (response.statusCode != 200) {
      throw Exception('Pobieranie nie powiodło się: HTTP ${response.statusCode}');
    }

    final total = response.contentLength ?? 0;
    var received = 0;

    final dir = await getTemporaryDirectory();
    final file = File('${dir.path}/plan-mechanika-update.apk');
    final sink = file.openWrite();

    final subscription = response.stream.listen((chunk) {
      received += chunk.length;
      sink.add(chunk);
      if (total > 0) onProgress(received / total);
    });
    await subscription.asFuture<void>();
    await sink.close();

    return file;
  }

  /// Whether the OS currently allows this app to trigger a package install
  /// (the "Install unknown apps" per-app toggle, Android 8+).
  Future<bool> canRequestInstalls() async {
    final result = await _channel.invokeMethod<bool>('canRequestInstalls');
    return result ?? false;
  }

  /// Opens the system settings screen where the user grants this app
  /// permission to install unknown apps.
  Future<void> openInstallPermissionSettings() {
    return _channel.invokeMethod('openInstallPermissionSettings');
  }

  /// Launches the system package installer for the downloaded APK.
  Future<void> installApk(String filePath) {
    return _channel.invokeMethod('installApk', {'filePath': filePath});
  }
}
