import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:kisiplan/models/lesson.dart';
import 'package:kisiplan/models/load_result.dart';
import 'package:kisiplan/services/local_db_service.dart';
import 'package:kisiplan/services/secure_storage_service.dart';

class TimetableService {
  static const String _apiUrl = 'https://api.librus.pl';
  static const String _synergiaUrl = 'https://synergia.librus.pl';
  static const String _clientIdTeacher = '47';
  static const String _clientIdStudent = '46';
  static const bool _diagnosticLogs = true;

  final SecureStorageService _secureStorage = SecureStorageService();
  final LocalDbService _db = LocalDbService();

  String? _sessionCookies;
  String? _bearerToken;
  String? _csrfToken;
  String? _gatewayToken;
  String? _teacherUuid;

  Future<bool> hasSavedCredentials() async {
    final creds = await _secureStorage.readCredentials();
    return (creds.username?.isNotEmpty ?? false) &&
        (creds.password?.isNotEmpty ?? false);
  }

  Future<String?> getSavedUsername() async {
    final creds = await _secureStorage.readCredentials();
    return creds.username;
  }

  Future<String?> getSavedRole() => _secureStorage.readRole();

  Future<String?> login(
    String username,
    String password, {
    String role = 'teacher',
  }) async {
    final clientId = role == 'teacher' ? _clientIdTeacher : _clientIdStudent;

    try {
      final cookieJar = <String, String>{};
      final ioClient = HttpClient();

      // Step 1: Initialize OAuth session (follow all redirects, collect cookies)
      await _ioGetWithRedirects(
        ioClient,
        '$_apiUrl/OAuth/Authorization?client_id=$clientId&response_type=code&scope=mydata',
        cookieJar,
      );

      // Step 2: POST credentials — returns JSON {status, goTo}
      final postBody = await _ioPost(
        ioClient,
        '$_apiUrl/OAuth/Authorization?client_id=$clientId',
        'action=login&login=${Uri.encodeComponent(username)}&pass=${Uri.encodeComponent(password)}',
        cookieJar,
      );
      ioClient.close();

      final data = json.decode(postBody) as Map<String, dynamic>;

      if (data['status'] == 'error') {
        final errors = data['errors'] as List?;
        final msg = (errors?.isNotEmpty == true)
            ? (errors!.first as Map)['message'] as String? ?? 'Nieznany blad'
            : 'Nieznany blad';
        return 'Niepoprawny login lub haslo: $msg';
      }

      final goTo = data['goTo'] as String?;
      if (goTo == null) {
        return 'Blad logowania: brak goTo w odpowiedzi.';
      }

      // Step 3: Follow goTo to establish synergia session (collect cookies)
      final goUrl = goTo.startsWith('/') ? '$_apiUrl$goTo' : goTo;
      final ioClient2 = HttpClient();
      await _ioGetWithRedirects(ioClient2, goUrl, cookieJar);
      ioClient2.close();

      if (!cookieJar.containsKey('DZIENNIKSID') &&
          !cookieJar.containsKey('SDZIENNIKSID')) {
        return 'Logowanie nie powiodlo sie: brak sesji Synergia.';
      }

      _sessionCookies = _cookieHeader(cookieJar);
      await _secureStorage.saveCredentials(username: username, password: password);
      await _secureStorage.saveRole(role);
      await _secureStorage.saveCookies(_sessionCookies!);

      // Try to get Bearer token for gateway MS endpoints (duties etc.)
      await _tryGetBearerToken(username, password, clientId);

      return null;

    } on SocketException {
      return 'Brak polaczenia z internetem.';
    } on http.ClientException catch (e) {
      if (kIsWeb) {
        return 'Wersja webowa nie obsługuje logowania (CORS).\nUruchom aplikację na Androidzie lub iOS.';
      }
      return 'Blad HTTP: ${e.message}';
    } catch (e) {
      debugPrint('login error: $e');
      return 'Blad logowania: $e';
    }
  }

  /// GET with manual redirect following — collects cookies at every hop.
  Future<void> _ioGetWithRedirects(
    HttpClient client,
    String startUrl,
    Map<String, String> cookieJar, {
    int maxHops = 10,
  }) async {
    String url = startUrl;
    for (var i = 0; i < maxHops; i++) {
      final uri = Uri.parse(url);
      final req = await client.getUrl(uri);
      req.followRedirects = false;
      req.headers.set('User-Agent', _ua);
      if (cookieJar.isNotEmpty) {
        req.headers.set('Cookie', _cookieHeader(cookieJar));
      }
      final res = await req.close();
      _collectIoCookies(res, cookieJar);

      if (res.statusCode >= 300 && res.statusCode < 400) {
        final location = res.headers.value('location');
        await res.drain<void>();
        if (location == null) break;
        url = location.startsWith('http') ? location : uri.resolve(location).toString();
      } else {
        await res.drain<void>();
        break;
      }
    }
  }

  /// POST — does NOT follow redirects, returns response body as string.
  Future<String> _ioPost(
    HttpClient client,
    String url,
    String body,
    Map<String, String> cookieJar,
  ) async {
    final uri = Uri.parse(url);
    final req = await client.postUrl(uri);
    req.followRedirects = false;
    req.headers.set('User-Agent', _ua);
    req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
    if (cookieJar.isNotEmpty) {
      req.headers.set('Cookie', _cookieHeader(cookieJar));
    }
    req.write(body);
    final res = await req.close();
    _collectIoCookies(res, cookieJar);

    // If redirect after POST, follow with GET
    if (res.statusCode >= 300 && res.statusCode < 400) {
      final location = res.headers.value('location');
      await res.drain<void>();
      if (location != null) {
        await _ioGetWithRedirects(
          client,
          location.startsWith('http') ? location : uri.resolve(location).toString(),
          cookieJar,
        );
      }
      return '{"status":"ok","goTo":null}'; // not JSON-redirected login
    }

    return await utf8.decoder.bind(res).join();
  }

  void _collectIoCookies(HttpClientResponse res, Map<String, String> jar) {
    final cookies = res.headers['set-cookie'];
    if (cookies == null) return;
    for (final raw in cookies) {
      final semi = raw.indexOf(';');
      final pair = semi >= 0 ? raw.substring(0, semi) : raw;
      final eq = pair.indexOf('=');
      if (eq < 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isNotEmpty) jar[name] = value;
    }
  }

  /// Tries to obtain a Bearer token via the Librus REST API password grant.
  /// Failure is silently ignored — Synergia session is used as fallback.
  Future<void> _tryGetBearerToken(String username, String password, String clientId) async {
    try {
      final res = await http.post(
        Uri.parse('$_apiUrl/OAuth/Token'),
        headers: {
          'User-Agent': _ua,
          'Content-Type': 'application/x-www-form-urlencoded',
        },
        body: 'grant_type=password'
            '&username=${Uri.encodeComponent(username)}'
            '&password=${Uri.encodeComponent(password)}'
            '&client_id=$clientId',
      );
      debugPrint('BearerToken status: ${res.statusCode}, body: ${res.body.substring(0, res.body.length.clamp(0, 300))}');
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as Map<String, dynamic>;
        final token = data['access_token'] as String?;
        if (token != null) {
          _bearerToken = token;
          await _secureStorage.saveToken(token);
          debugPrint('Bearer token obtained: ${token.substring(0, 20)}...');
        }
      }
    } catch (e) {
      debugPrint('_tryGetBearerToken error: $e');
    }
  }

  Future<String?> autoLoginIfPossible() async {
    _sessionCookies = await _secureStorage.readCookies();
    _bearerToken ??= await _secureStorage.readToken();
    if (_sessionCookies != null && _sessionCookies!.isNotEmpty) {

      return null;
    }
    final creds = await _secureStorage.readCredentials();
    if (creds.username == null || creds.password == null) {
      return 'Brak zapisanych danych logowania.';
    }
    return login(creds.username!, creds.password!, role: (await _secureStorage.readRole()) ?? 'teacher');
  }

  Future<void> logout() async {
    _sessionCookies = null;
    await _secureStorage.clearAll();
    await _db.clear();
  }

  Future<LoadResult> getTodayLessons() async {
    final remote = await _fetchRemoteTimetable();
    if (remote != null) {
      await _db.replaceAll(remote);
      return LoadResult(lessons: _extractToday(remote), weekTimetable: remote, fromCache: false);
    }

    // Jeśli _sessionCookies == null, sesja wygasła - próbuj ponownie zalogować
    if (_sessionCookies == null) {
      final loginError = await autoLoginIfPossible();
      if (loginError == null) {
        final remoteAfterRelogin = await _fetchRemoteTimetable();
        if (remoteAfterRelogin != null) {
          await _db.replaceAll(remoteAfterRelogin);
          return LoadResult(lessons: _extractToday(remoteAfterRelogin), weekTimetable: remoteAfterRelogin, fromCache: false);
        }
      }
    }

    // Fallback: Librus REST API (działa dla uczniów z client_id=46)
    final apiResult = await _fetchTimetableFromRestApi();
    if (apiResult != null) {
      await _db.replaceAll(apiResult);
      return LoadResult(lessons: _extractToday(apiResult), weekTimetable: apiResult, fromCache: false);
    }

    // Jeśli REST API zawiodło i sesja wygasła (wyczyszczona przez _tryGetGatewayToken
    // gdy /Me zwróciło 401), spróbuj ponownie zalogować i jeszcze raz REST API
    if (_sessionCookies == null) {
      final loginError = await autoLoginIfPossible();
      if (loginError == null) {
        final apiAfterRelogin = await _fetchTimetableFromRestApi();
        if (apiAfterRelogin != null) {
          await _db.replaceAll(apiAfterRelogin);
          return LoadResult(lessons: _extractToday(apiAfterRelogin), weekTimetable: apiAfterRelogin, fromCache: false);
        }
      }
    }

    final cached = await _db.readAll();
    final todayFromCache = _extractToday(cached);
    if (todayFromCache.isNotEmpty) {
      return LoadResult(
        lessons: todayFromCache,
        weekTimetable: cached,
        fromCache: true,
        warning: 'Sesja wygasła, nie udało się pobrać nowego planu. Pokazano ostatni zapisany.',
      );
    }
    return const LoadResult(
      lessons: [],
      weekTimetable: {},
      fromCache: true,
      warning: 'Nie udalo sie pobrac planu i brak danych offline.',
    );
  }

  Future<Map<String, List<Lesson>>?> _fetchRemoteTimetable() async {
    _sessionCookies ??= await _secureStorage.readCookies();
    if (_sessionCookies == null || _sessionCookies!.isEmpty) return null;

    try {
      // Parse existing cookies into a mutable jar so redirects can update them.
      final cookieJar = _parseCookieString(_sessionCookies!);

      // First: try direct URL (works for teachers and some student accounts).
      var body = await _ioGetWithBody(
        '$_synergiaUrl/plan_lekcji?pokaz_dyzury_miedzylekcyjne=1',
        cookieJar,
      );
      if (_diagnosticLogs && body != null) {
        final containsDutyWord = body.toLowerCase().contains('dyżur') || body.toLowerCase().contains('dyzur');
        debugPrint('[diag] plan_lekcji status=200, len=${body.length}, containsDyzur=$containsDutyWord');
      }

      // Detect "Brak dostępu" page – HTML endpoint doesn't work for this
      // account type (common for student accounts). Don't clear cookies —
      // they may still be valid for the Gateway REST API fallback.
      if (body != null && body.contains('Brak dost')) {
        debugPrint('[diag] Brak dostępu wykryty – HTML scraping nie dostępny dla tego konta');
        // Persist any cookies collected so far for REST API fallback.
        _sessionCookies = _cookieHeader(cookieJar);
        await _secureStorage.saveCookies(_sessionCookies!);
        return null;
      }

      // Persist any cookies collected during redirects.
      _sessionCookies = _cookieHeader(cookieJar);
      await _secureStorage.saveCookies(_sessionCookies!);

      if (body == null) return null;

      // Session expired when server shows the login form.
      final isLoginPage = body.contains('name="login"') && body.contains('name="pass"');
      if (isLoginPage) {
        debugPrint('Sesja wygasła – strona logowania');
        _sessionCookies = null;
        await _secureStorage.saveCookies('');
        return null;
      }

      // Extract CSRF token and try to get gateway access token from HTML
      _csrfToken = _extractCsrfToken(body);
      _teacherUuid = _extractTeacherUuid(body);
      await _tryGetGatewayToken();
      final timetable = _parseHtmlTimetable(body);
      final totalLessons = timetable.values.expand((x) => x).length;
      if (totalLessons == 0) {
        debugPrint('[diag] HTML sparsowany ale 0 lekcji – traktuję jako wygaśnięcie sesji');
        _sessionCookies = null;
        await _secureStorage.saveCookies('');
        return null;
      }
      _bearerToken ??= await _secureStorage.readToken();
      await _fetchAndCacheLessonTimesIfPossible();
      await _fetchAndMergeDuties(timetable);
      if (_diagnosticLogs) {
        final dutiesCount = timetable.values.expand((x) => x).where((l) => l.isDuty).length;
        final lessonsCount = timetable.values.expand((x) => x).length;
        debugPrint('[diag] final timetable: lessons=$lessonsCount, duties=$dutiesCount');
      }
      return timetable;

    } on SocketException catch (e) {
      debugPrint('Brak połączenia z internetem: $e');
      // Zwróć null, ale nie czyść sesji - to rzeczywiście problem z siecią
    } catch (e) {
      debugPrint('fetch timetable error: $e');
    }
    return null;
  }

  /// Pobiera plan z Librus REST API v2.0 (działa dla uczniów z client_id=46).
  /// Próbuje Bearer token (jeśli dostępny), a gdy nie – gateway Synergii z ciasteczkami sesji.
  Future<Map<String, List<Lesson>>?> _fetchTimetableFromRestApi() async {
    _bearerToken ??= await _secureStorage.readToken();
    _sessionCookies ??= await _secureStorage.readCookies();

    // Ustal bazowy URL i nagłówki autoryzacji
    final String apiBase;
    final Map<String, String> headers;
    if (_bearerToken != null && _bearerToken!.isNotEmpty) {
      // Bezpośredni dostęp do REST API z Bearer tokenem
      apiBase = '$_apiUrl/2.0';
      headers = {'Authorization': 'Bearer $_bearerToken', 'User-Agent': _ua};
      debugPrint('[api] używam Bearer token');
    } else if (_sessionCookies != null && _sessionCookies!.isNotEmpty) {
      // Dla uczniów: gateway Synergii wymaga świeżego tokenu gateway.
      // _tryGetGatewayToken odświeża go przez /refreshToken i aktualizuje _sessionCookies.
      apiBase = '$_synergiaUrl/gateway/api/2.0';
      await _tryGetGatewayToken();
      // _tryGetGatewayToken czyści _sessionCookies gdy gateway token wygasł (Me → 401)
      if (_sessionCookies == null || _sessionCookies!.isEmpty) return null;
      headers = {
        'Cookie': _sessionCookies!,  // zawiera świeży token po _tryGetGatewayToken
        'User-Agent': _ua,
        'X-Requested-With': 'XMLHttpRequest',
      };
      debugPrint('[api] używam gateway z ciasteczkami sesji (po odświeżeniu tokenu)');
    } else {
      debugPrint('[api] brak Bearer tokenu i ciasteczek sesji');
      return null;
    }

    try {
      // Pobierz numery lekcji (godziny)
      // Gateway może nie obsługiwać /LessonNumbers – spróbuj też bezpośrednio przez api.librus.pl
      final lessonTimes = <int, Map<String, String>>{};
      for (final lnUrl in ['$apiBase/LessonNumbers', '$_apiUrl/2.0/LessonNumbers']) {
        final lnHeaders = lnUrl.startsWith(_synergiaUrl) ? headers : {
          'Cookie': _sessionCookies ?? '',
          'User-Agent': _ua,
        };
        final lnRes = await http.get(Uri.parse(lnUrl), headers: lnHeaders);
        debugPrint('[api] LessonNumbers ($lnUrl) status=${lnRes.statusCode}');
        if (lnRes.statusCode != 200) {
          debugPrint('[api] LessonNumbers error body: ${lnRes.body.substring(0, lnRes.body.length.clamp(0, 300))}');
        }
        if (lnRes.statusCode == 200) {
          debugPrint('[api] LessonNumbers raw: ${lnRes.body}');
          final lnData = json.decode(lnRes.body) as Map<String, dynamic>;
          for (final ln in (lnData['LessonNumbers'] as List? ?? [])) {
            final num = int.tryParse(ln['Number'].toString()) ?? 0;
            if (num > 0) {
              lessonTimes[num] = {'from': ln['From']?.toString() ?? '', 'to': ln['To']?.toString() ?? ''};
            }
          }
          debugPrint('[api] lessonTimes: ${lessonTimes.map((k, v) => MapEntry(k, "${v['from']}-${v['to']}"))}');
          await _secureStorage.saveLessonTimes(lessonTimes);
          break;  // sukces – nie próbuj dalej
        }
      }
      // Fallback: najpierw cached times, potem typowy plan polskiej szkoły
      if (lessonTimes.isEmpty) {
        final cached = await _secureStorage.readLessonTimes();
        if (cached != null && cached.isNotEmpty) {
          lessonTimes.addAll(cached);
          debugPrint('[api] LessonNumbers z cache: ${lessonTimes.length} wpisów');
        } else {
          debugPrint('[api] LessonNumbers niedostępne – używam domyślnego planu godzin');
          const defaults = {
            1: ('08:00', '08:45'), 2: ('08:50', '09:35'), 3: ('09:45', '10:30'),
            4: ('10:50', '11:35'), 5: ('11:45', '12:30'), 6: ('12:40', '13:25'),
            7: ('13:30', '14:15'), 8: ('14:20', '15:05'), 9: ('15:10', '15:55'),
            10: ('16:00', '16:45'), 11: ('16:55', '17:35'),
          };
          defaults.forEach((n, t) => lessonTimes[n] = {'from': t.$1, 'to': t.$2});
        }
      }

      // Pobierz nazwy sal (Classrooms) – opcjonalnie
      final classroomNames = <String, String>{};
      try {
        final clsRes = await http.get(Uri.parse('$apiBase/Classrooms'), headers: headers);
        debugPrint('[api] Classrooms status=${clsRes.statusCode}');
        if (clsRes.statusCode == 200) {
          final clsData = json.decode(clsRes.body) as Map<String, dynamic>;
          for (final cls in (clsData['Classrooms'] as List? ?? [])) {
            final id = cls['Id']?.toString() ?? '';
            final symbol = cls['Symbol']?.toString() ?? cls['Name']?.toString() ?? '';
            if (id.isNotEmpty && symbol.isNotEmpty) classroomNames[id] = symbol;
          }
          debugPrint('[api] classrooms: ${classroomNames.length}');
        }
      } catch (_) {}

      // Pobierz plan – gateway nie obsługuje WeekStart, zwraca bieżący tydzień
      final ttRes = await http.get(Uri.parse('$apiBase/Timetables'), headers: headers);
      debugPrint('[api] Timetables status=${ttRes.statusCode}, len=${ttRes.body.length}');
      if (ttRes.statusCode != 200) return null;

      final ttData = json.decode(ttRes.body) as Map<String, dynamic>;
      // Gateway API nie zwraca pola Status (tylko bezpośredni REST API); ignoruj null
      final status = ttData['Status'] as String?;
      if (status != null && status != 'ok') {
        debugPrint('[api] Timetables Status: $status');
        return null;
      }

      final timetableRaw = ttData['Timetable'] as Map<String, dynamic>?;
      if (timetableRaw == null) return null;

      const dayKeys = {1: 'monday', 2: 'tuesday', 3: 'wednesday', 4: 'thursday', 5: 'friday'};
      final result = <String, List<Lesson>>{for (final d in dayKeys.values) d: []};

      // Format odpowiedzi: Timetable[date] = List<List<slot>>
      // Indeks zewnętrznej listy = numer lekcji (LessonNo)
      timetableRaw.forEach((dateStr, dayData) {
        final date = DateTime.tryParse(dateStr);
        if (date == null) return;
        final dayKey = dayKeys[date.weekday];
        if (dayKey == null) return;

        final dayList = dayData as List;
        for (int periodIdx = 0; periodIdx < dayList.length; periodIdx++) {
          final periodData = dayList[periodIdx];
          if (periodData == null || periodData is! List || periodData.isEmpty) continue;

          for (final slot in periodData) {
            final slotMap = slot as Map<String, dynamic>;
            if (slotMap['IsCanceled'] == true) continue;

            final lessonNo = int.tryParse(slotMap['LessonNo']?.toString() ?? '') ?? periodIdx;
            final times = lessonTimes[lessonNo];

            final subject = (slotMap['Subject'] as Map<String, dynamic>?)?['Name']?.toString() ?? '';
            if (subject.isEmpty) continue;

            final classroomId = (slotMap['Classroom'] as Map<String, dynamic>?)?['Id']?.toString() ?? '';
            final room = classroomNames[classroomId] ?? '';
            final isSubstitution = slotMap['IsSubstitutionClass'] == true;

            result[dayKey]!.add(Lesson.fromJson({
              'start': times?['from'] ?? '',
              'end': times?['to'] ?? '',
              'subject': subject,
              'room': room,
              'className': '',
              'isSubstitution': isSubstitution,
              'isDuty': false,
            }));
          }
        }
      });

      result.forEach((_, lessons) => lessons.sort((a, b) => a.startMinutes.compareTo(b.startMinutes)));

      final total = result.values.expand((x) => x).length;
      debugPrint('[api] REST API timetable: $total lekcji w tygodniu');
      return result;
    } catch (e) {
      debugPrint('[api] _fetchTimetableFromRestApi error: $e');
      return null;
    }
  }

  /// Pobiera LessonNumbers z API i zapisuje do cache (używane po sukcesie HTML nauczyciela,
  /// żeby uczeń mógł korzystać z tych samych godzin).
  Future<void> _fetchAndCacheLessonTimesIfPossible() async {
    if (_bearerToken == null && (_sessionCookies == null || _sessionCookies!.isEmpty)) return;
    try {
      final String url;
      final Map<String, String> headers;
      if (_bearerToken != null && _bearerToken!.isNotEmpty) {
        url = '$_apiUrl/2.0/LessonNumbers';
        headers = {'Authorization': 'Bearer $_bearerToken', 'User-Agent': _ua};
      } else {
        url = '$_synergiaUrl/gateway/api/2.0/LessonNumbers';
        headers = {'Cookie': _sessionCookies!, 'User-Agent': _ua, 'X-Requested-With': 'XMLHttpRequest'};
      }
      final res = await http.get(Uri.parse(url), headers: headers);
      if (res.statusCode == 200) {
        final data = json.decode(res.body) as Map<String, dynamic>;
        final times = <int, Map<String, String>>{};
        for (final ln in (data['LessonNumbers'] as List? ?? [])) {
          final num = int.tryParse(ln['Number'].toString()) ?? 0;
          if (num > 0) times[num] = {'from': ln['From']?.toString() ?? '', 'to': ln['To']?.toString() ?? ''};
        }
        if (times.isNotEmpty) {
          await _secureStorage.saveLessonTimes(times);
          debugPrint('[api] LessonNumbers zapisane do cache: ${times.length} wpisów');
        }
      }
    } catch (e) {
      debugPrint('[api] _fetchAndCacheLessonTimesIfPossible error: $e');
    }
  }

  Future<void> _fetchAndMergeDuties(Map<String, List<Lesson>> timetable) async {
    try {
      final now = DateTime.now();
      final monday = now.subtract(Duration(days: now.weekday - 1));
      final friday = monday.add(const Duration(days: 4));
      final from = '${monday.year}-${monday.month.toString().padLeft(2,'0')}-${monday.day.toString().padLeft(2,'0')}';
      final to = '${friday.year}-${friday.month.toString().padLeft(2,'0')}-${friday.day.toString().padLeft(2,'0')}';

      if (_diagnosticLogs) {
        debugPrint('[diag] duty date range: from=$from, to=$to');
        debugPrint('[diag] teacherUuid: $_teacherUuid');
      }

      // The JS calls: POST /gateway/ms/breaktimesupervision/schedule/supervisions
      // with a JSON body containing supervisor filter, date range, etc.
      // It also calls GET /gateway/ms/breaktimesupervision/places for place names.

      final baseUrl = '$_synergiaUrl/gateway/ms/breaktimesupervision';
      final headers = {
        'User-Agent': _ua,
        'Cookie': _sessionCookies!,
        'X-Requested-With': 'XMLHttpRequest',
        'Accept': 'application/json, text/plain, */*',
        'Content-Type': 'application/json',
        'Referer': '$_synergiaUrl/plan_lekcji',
      };

      // Step 1: Get places (location names)
      final placesMap = <String, String>{};
      try {
        final placesRes = await http.get(
          Uri.parse('$baseUrl/places'),
          headers: {
            'User-Agent': _ua,
            'Cookie': _sessionCookies!,
            'X-Requested-With': 'XMLHttpRequest',
            'Accept': 'application/json, text/plain, */*',
            'Referer': '$_synergiaUrl/plan_lekcji',
          },
        );
        debugPrint('[duties-places] status=${placesRes.statusCode}, body=${placesRes.body.substring(0, placesRes.body.length.clamp(0, 400))}');
        if (placesRes.statusCode == 200 && placesRes.body.isNotEmpty) {
          final placesData = json.decode(placesRes.body);
          final placesList = (placesData is List ? placesData : (placesData['data'] ?? [])) as List;
          for (final p in placesList) {
            final id = p['placeIdentifier'] ?? p['identifier'] ?? p['id'] ?? '';
            final name = p['name'] ?? p['label'] ?? '';
            if (id.toString().isNotEmpty && name.toString().isNotEmpty) {
              placesMap[id.toString()] = name.toString();
            }
          }
          if (_diagnosticLogs) debugPrint('[diag] places loaded: ${placesMap.length}');
        }
      } catch (e) {
        debugPrint('[duties-places] error: $e');
      }

      // Step 2: POST to /schedule/supervisions with the proper body
      // Build request body matching what JS does
      final body = <String, dynamic>{
        'date:greaterOrEqual': from,
        'date:smallerOrEqual': to,
        'limit': 2100,
        'offset': 0,
        'sort': 'date:asc',
      };
      // Add supervisor filter if we have the UUID
      if (_teacherUuid != null) {
        body['supervisorIdentifier:oneOf'] = [_teacherUuid];
      }

      final res = await http.post(
        Uri.parse('$baseUrl/schedule/supervisions'),
        headers: headers,
        body: json.encode(body),
      );
      debugPrint('[duties-supervisions] status=${res.statusCode}, body=${res.body.substring(0, res.body.length.clamp(0, 600))}');

      if (res.statusCode != 200 || res.body.isEmpty) {
        // Try without supervisor filter
        if (_teacherUuid != null) {
          body.remove('supervisorIdentifier:oneOf');
          final res2 = await http.post(
            Uri.parse('$baseUrl/schedule/supervisions'),
            headers: headers,
            body: json.encode(body),
          );
          debugPrint('[duties-supervisions-nofilter] status=${res2.statusCode}, body=${res2.body.substring(0, res2.body.length.clamp(0, 600))}');
          if (res2.statusCode != 200 || res2.body.isEmpty) {
            debugPrint('[diag] duties fetch failed');
            return;
          }
          // Parse res2 instead
          _parseDutyResponse(res2.body, placesMap, timetable);
          return;
        }
        debugPrint('[diag] duties fetch failed');
        return;
      }

      _parseDutyResponse(res.body, placesMap, timetable);
    } catch (e) {
      debugPrint('fetchDuties error: $e');
    }
  }

  void _parseDutyResponse(String responseBody, Map<String, String> placesMap, Map<String, List<Lesson>> timetable) {
    final data = json.decode(responseBody);
    final items = (data is List ? data : (data['data'] ?? data['items'] ?? [])) as List;
    if (_diagnosticLogs) {
      debugPrint('[diag] breaktimesupervision items: ${items.length}');
      if (items.isNotEmpty) {
        debugPrint('[diag] first item keys: ${(items.first as Map).keys.toList()}');
        final encoded = json.encode(items.first);
        debugPrint('[diag] first item: ${encoded.substring(0, encoded.length.clamp(0, 500))}');
      }
    }

    const dayKeys = {1: 'monday', 2: 'tuesday', 3: 'wednesday', 4: 'thursday', 5: 'friday'};
    for (final item in items) {
      final dateStr = item['date'] as String?;
      // JS uses supervisionHours.startTime / .endTime
      final hours = item['supervisionHours'];
      final timeFrom = hours?['startTime'] ?? item['timeFrom'] ?? item['time_from'] ?? item['startTime'];
      final timeTo = hours?['endTime'] ?? item['timeTo'] ?? item['time_to'] ?? item['endTime'];
      final placeId = item['placeIdentifier'] ?? item['place'] ?? item['location'] ?? '';
      final location = placesMap[placeId.toString()] ?? placeId.toString();
      if (dateStr == null || timeFrom == null || timeTo == null) continue;
      final date = DateTime.tryParse(dateStr);
      if (date == null) continue;
      final dayKey = dayKeys[date.weekday];
        if (dayKey == null) continue;

        final alreadyPresent = timetable[dayKey]!.any(
          (l) =>
              l.isDuty &&
              l.startString == timeFrom.toString() &&
              l.endString == timeTo.toString() &&
              l.room.trim().toLowerCase() == location.toString().trim().toLowerCase(),
        );
        if (alreadyPresent) continue;

        timetable[dayKey]!.add(Lesson.fromJson({
          'start': timeFrom.toString(),
          'end': timeTo.toString(),
          'subject': 'Dyżur',
          'room': location.toString(),
          'className': '',
          'isDuty': true,
        }));
      }
      timetable.forEach((_, lessons) => lessons.sort((a, b) => a.startMinutes.compareTo(b.startMinutes)));
  }

  Map<String, List<Lesson>> _parseHtmlTimetable(String htmlBody) {
    final doc = html_parser.parse(htmlBody);

    // Select ALL cells with data-date.
    final cells = doc.querySelectorAll('td[data-date]');
    final breaktimeCells = doc.querySelectorAll(
      'td#breaktimeSupervisionBox[data-date][data-time_from][data-time_to]',
    );
    final dutyRows = doc.querySelectorAll(
      'tr.lessonPanelTableRow.isNotLessonWithSchoolClass[data-date][data-time_from][data-time_to]',
    );
    final textDutyRows = doc.querySelectorAll('tr.lessonPanelTableRow.isNotLessonWithSchoolClass');

    if (_diagnosticLogs) {
      debugPrint(
        '[diag] html parser: td[data-date]=${cells.length}, breaktimeCells=${breaktimeCells.length}, '
        'dutyRowsWithTime=${dutyRows.length}, notLessonRows=${textDutyRows.length}',
      );
      if (cells.isEmpty) {
        // Diagnoza dla ucznia: sprawdź czy HTML w ogóle ma elementy z data-date
        final allDataDate = doc.querySelectorAll('[data-date]');
        debugPrint('[diag] brak td[data-date] – wszystkie [data-date]: ${allDataDate.length}');
        if (allDataDate.isNotEmpty) {
          final first = allDataDate.first;
          debugPrint('[diag] pierwszy [data-date]: tag=${first.localName}, attrs=${first.attributes}');
        }
        // Sprawdź alternatywne selektory które Synergia może używać dla uczniów
        final trWithDate = doc.querySelectorAll('tr[data-date]');
        final anyLesson = doc.querySelectorAll('.lessonPanelTableRow');
        final tableLekcji = doc.querySelectorAll('table.plan');
        debugPrint('[diag] tr[data-date]=${trWithDate.length}, .lessonPanelTableRow=${anyLesson.length}, table.plan=${tableLekcji.length}');
        // Pokaż fragment HTML (pierwsze 800 znaków i środek gdzie jest treść)
        debugPrint('[diag] html[0..800]: ${htmlBody.substring(0, htmlBody.length.clamp(0, 800))}');
        final midStart = (htmlBody.length ~/ 3).clamp(0, htmlBody.length);
        final midEnd = (midStart + 1500).clamp(0, htmlBody.length);
        debugPrint('[diag] html[mid]: ${htmlBody.substring(midStart, midEnd)}');
        // Pokaż ostatnią część HTML gdzie zwykle są JS inicjalizatory wywołujące xajax
        final lastStart = (htmlBody.length - 3500).clamp(0, htmlBody.length);
        debugPrint('[diag] html[last 3500]: ${htmlBody.substring(lastStart)}');
      }
    }

    const dayKeys = {1: 'monday', 2: 'tuesday', 3: 'wednesday', 4: 'thursday', 5: 'friday'};
    final result = <String, List<Lesson>>{for (final d in dayKeys.values) d: []};
    final seen = <String>{};

    for (final cell in cells) {
      final dateStr = cell.attributes['data-date'];
      final timeFrom = cell.attributes['data-time_from'];
      final timeTo = cell.attributes['data-time_to'];
      if (dateStr == null || timeFrom == null || timeTo == null) continue;

      final date = DateTime.tryParse(dateStr);
      if (date == null) continue;
      final dayKey = dayKeys[date.weekday];
      if (dayKey == null) continue;

      final cellText = cell.text.trim();
      if (cellText.isEmpty) continue;

      // Duty detection: "Dyżur" appears in the "Typ zajęć" sibling cell of the row,
      // while the data-date cell contains only the location (e.g. "PARTER").
      final rowCells = cell.parent?.querySelectorAll('td') ?? [];
      final isDuty = rowCells.any(
        (c) => c != cell && c.text.trim().toLowerCase().contains('dyżur'),
      );

      final cellLower = cellText.toLowerCase();
      final isSubstitution = !isDuty && (
          cellLower.contains('przesunięcie') ||
          cellLower.contains('zastępstwo') ||
          cellLower.contains('zastepstwo'));

      String subject;
      String room;
      String className;
      String? originalSubject;
      String? originalRoom;
      String? originalClassName;

      if (isDuty) {
        // For duties: the cell text is the location (e.g. "PARTER").
        subject = 'Dyżur';
        room = cellText; // location used as "room"
        className = '';
      } else if (isSubstitution) {
        // First <div class="text"> has <s> (cancelled), second has the new lesson.
        final textDivs = cell.querySelectorAll('div.text');
        if (textDivs.length >= 2) {
          final origText = textDivs[0].text.trim();
          originalSubject = textDivs[0].querySelector('b')?.text.trim() ?? '';
          originalRoom = RegExp(r's\.[\s\u00a0]*([0-9a-zA-Z]+)').firstMatch(origText)?.group(1) ?? '';
          originalClassName = _extractClassName(origText);

          final newText = textDivs[1].text.trim();
          subject = textDivs[1].querySelector('b')?.text.trim() ?? newText;
          room = RegExp(r's\.[\s\u00a0]*([0-9a-zA-Z]+)').firstMatch(newText)?.group(1) ?? '';
          className = _extractClassName(newText);
        } else {
          subject = cell.querySelector('b')?.text.trim() ?? cellText;
          room = RegExp(r's\.[\s\u00a0]*([0-9a-zA-Z]+)').firstMatch(cellText)?.group(1) ?? '';
          className = _extractClassName(cellText);
        }
      } else {
        subject = cell.querySelector('b')?.text.trim() ?? cellText;
        room = RegExp(r's\.[\s\u00a0]*([0-9a-zA-Z]+)').firstMatch(cellText)?.group(1) ?? '';
        className = _extractClassName(cellText);
      }

      if (subject.isEmpty) continue;

      final key = '${dayKey}|${timeFrom}|${timeTo}|${subject.toLowerCase()}|${room.toLowerCase()}|${className.toLowerCase()}';
      if (!seen.add(key)) continue;

      result[dayKey]!.add(Lesson.fromJson({
        'start': timeFrom,
        'end': timeTo,
        'subject': subject,
        'room': room,
        'className': className,
        'isSubstitution': isSubstitution,
        'isDuty': isDuty,
        if (originalSubject != null && originalSubject.isNotEmpty)
          'originalSubject': originalSubject,
        if (originalRoom != null && originalRoom.isNotEmpty)
          'originalRoom': originalRoom,
        if (originalClassName != null && originalClassName.isNotEmpty)
          'originalClassName': originalClassName,
      }));
    }

    // Some schools inject break duties later as separate <tr> rows with data-date/time
    // instead of putting data-date directly on a lesson <td>.
    var dutyRowsParsed = 0;
    var dutyCellsParsed = 0;

    for (final cell in breaktimeCells) {
      final dateStr = cell.attributes['data-date'];
      final timeFrom = cell.attributes['data-time_from'];
      final timeTo = cell.attributes['data-time_to'];
      if (dateStr == null || timeFrom == null || timeTo == null) continue;

      final date = DateTime.tryParse(dateStr);
      if (date == null) continue;
      final dayKey = dayKeys[date.weekday];
      if (dayKey == null) continue;

      final rawText = cell.text.replaceAll('\u00a0', ' ').trim();
      final location = rawText;
      if (location.isEmpty) continue;

      final key = '${dayKey}|${timeFrom}|${timeTo}|dyżur|${location.toLowerCase()}|';
      if (!seen.add(key)) continue;

      result[dayKey]!.add(Lesson.fromJson({
        'start': timeFrom,
        'end': timeTo,
        'subject': 'Dyżur',
        'room': location,
        'className': '',
        'isDuty': true,
      }));
      dutyCellsParsed++;

      if (_diagnosticLogs && dutyCellsParsed <= 5) {
        debugPrint('[diag] breaktime cell parsed: day=$dayKey $timeFrom-$timeTo location=$location');
      }
    }

    for (final row in dutyRows) {
      final dateStr = row.attributes['data-date'];
      final timeFrom = row.attributes['data-time_from'];
      final timeTo = row.attributes['data-time_to'];
      if (dateStr == null || timeFrom == null || timeTo == null) continue;

      final date = DateTime.tryParse(dateStr);
      if (date == null) continue;
      final dayKey = dayKeys[date.weekday];
      if (dayKey == null) continue;

      final cols = row.querySelectorAll('td');
      if (cols.length < 4) continue;

      final location = cols[2].text.trim();
      final typeText = cols[3].text.trim().toLowerCase();
      if (!typeText.contains('dyżur')) continue;

      final key = '${dayKey}|${timeFrom}|${timeTo}|dyżur|${location.toLowerCase()}|';
      if (!seen.add(key)) continue;

      result[dayKey]!.add(Lesson.fromJson({
        'start': timeFrom,
        'end': timeTo,
        'subject': 'Dyżur',
        'room': location,
        'className': '',
        'isDuty': true,
      }));
      dutyRowsParsed++;

      if (_diagnosticLogs && dutyRowsParsed <= 5) {
        debugPrint('[diag] duty row parsed: day=$dayKey $timeFrom-$timeTo location=$location');
      }
    }

    if (_diagnosticLogs) {
      final dutiesFromCells = result.values
          .expand((x) => x)
          .where((l) => l.isDuty)
          .length;
      debugPrint(
        '[diag] html parser summary: parsedBreaktimeCells=$dutyCellsParsed, '
        'parsedDutyRows=$dutyRowsParsed, dutiesTotalAfterHtml=$dutiesFromCells',
      );
    }

    result.forEach((_, lessons) {
      lessons.sort((a, b) => a.startMinutes.compareTo(b.startMinutes));
    });
    return result;
  }

  List<Lesson> _extractToday(Map<String, List<Lesson>> timetable) {
    const days = ['', 'monday', 'tuesday', 'wednesday', 'thursday', 'friday', 'saturday', 'sunday'];
    return timetable[days[DateTime.now().weekday]] ?? [];
  }

  /// Extracts the class name from a div.text content.
  /// Format: "Subject- ClassName [group]  s. Room"
  /// Returns e.g. "4cT5 T4", "3rT5 robotyk", "1aT5 gr. 1"
  String _extractClassName(String text) {
    final match = RegExp(r'-\s*(.+?)[\s\u00a0]+s\.').firstMatch(text);
    return match?.group(1)?.trim() ?? '';
  }

  static const _ua = 'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 Chrome/124.0.0.0 Safari/537.36';

  String _cookieHeader(Map<String, String> jar) =>
      jar.entries.map((e) => '${e.key}=${e.value}').join('; ');

  /// Extract CSRF token from HTML page source.
  String? _extractCsrfToken(String html) {
    final match = RegExp(r'csrfTokenValue\s*=\s*"([^"]+)"').firstMatch(html);
    final token = match?.group(1);
    if (_diagnosticLogs) {
      debugPrint('[diag] csrfToken extracted: ${token != null ? "${token.substring(0, token.length.clamp(0, 30))}..." : "null"}');
    }
    return token;
  }

  /// Extract teacher UUID from HTML (selected option in teacher select has data-uuid).
  String? _extractTeacherUuid(String html) {
    // Look for pattern: <option ... selected ... data-uuid="...">
    // The HTML has options like: <option value="1421894" selected="selected" data-uuid="LID-AUTH-...">
    final match = RegExp(r'<option[^>]*selected[^>]*data-uuid="([^"]+)"').firstMatch(html);
    final uuid = match?.group(1);
    if (uuid == null) {
      // Try reverse order: data-uuid before selected
      final match2 = RegExp(r'<option[^>]*data-uuid="([^"]+)"[^>]*selected').firstMatch(html);
      final uuid2 = match2?.group(1);
      if (_diagnosticLogs) debugPrint('[diag] teacherUuid extracted (alt): $uuid2');
      return uuid2;
    }
    if (_diagnosticLogs) debugPrint('[diag] teacherUuid extracted: $uuid');
    return uuid;
  }

  /// GET with manual redirect following — collects cookies at every hop and
  /// returns the final response body (or null on failure).
  Future<String?> _ioGetWithBody(
    String startUrl,
    Map<String, String> cookieJar, {
    int maxHops = 15,
  }) async {
    final ioClient = HttpClient();
    try {
      String url = startUrl;
      for (var i = 0; i < maxHops; i++) {
        final uri = Uri.parse(url);
        final req = await ioClient.getUrl(uri);
        req.followRedirects = false;
        req.headers.set('User-Agent', _ua);
        if (cookieJar.isNotEmpty) {
          req.headers.set('Cookie', _cookieHeader(cookieJar));
        }
        final res = await req.close();
        _collectIoCookies(res, cookieJar);

        if (res.statusCode >= 300 && res.statusCode < 400) {
          final location = res.headers.value('location');
          await res.drain<void>();
          if (location == null) break;
          url = location.startsWith('http')
              ? location
              : uri.resolve(location).toString();
        } else {
          return await utf8.decoder.bind(res).join();
        }
      }
    } finally {
      ioClient.close();
    }
    return null;
  }

  /// Parse a cookie header string ("A=1; B=2") into a mutable map.
  Map<String, String> _parseCookieString(String cookies) {
    final jar = <String, String>{};
    for (final part in cookies.split(';')) {
      final eq = part.indexOf('=');
      if (eq > 0) {
        jar[part.substring(0, eq).trim()] = part.substring(eq + 1).trim();
      }
    }
    return jar;
  }

  /// Try to get a gateway access token for microservice calls (duties etc.).
  /// Flow mirrors what Synergia JS does:
  ///   1. POST /refreshToken with session cookies → captures new cookies
  ///   2. GET /gateway/api/2.0/Me with updated cookies → extracts access token
  Future<void> _tryGetGatewayToken() async {
    if (_sessionCookies == null) return;
    try {
      final ioClient = HttpClient();

      final cookieJar = _parseCookieString(_sessionCookies!);

      // Step 1: POST /refreshToken — captures Set-Cookie with new gateway auth
      final rtUri = Uri.parse('$_synergiaUrl/refreshToken');
      final rtReq = await ioClient.getUrl(rtUri);
      rtReq.followRedirects = false;
      rtReq.headers.set('User-Agent', _ua);
      rtReq.headers.set('Cookie', _sessionCookies!);
      rtReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      final rtRes = await rtReq.close();
      // Capture any Set-Cookie headers
      final rtCookies = rtRes.headers['set-cookie'];
      if (rtCookies != null) {
        for (final raw in rtCookies) {
          final semi = raw.indexOf(';');
          final pair = semi >= 0 ? raw.substring(0, semi) : raw;
          final eq = pair.indexOf('=');
          if (eq > 0) {
            cookieJar[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
          }
        }
      }
      final rtBody = await rtRes.transform(utf8.decoder).join();
      if (_diagnosticLogs) {
        debugPrint('[diag] /refreshToken status=${rtRes.statusCode}, '
            'setCookies=${rtCookies?.length ?? 0}, '
            'body=${rtBody.substring(0, rtBody.length.clamp(0, 300))}');
      }

      // Update session cookies with any new ones from refreshToken
      _sessionCookies = cookieJar.entries.map((e) => '${e.key}=${e.value}').join('; ');
      await _secureStorage.saveCookies(_sessionCookies!);

      // Step 2: GET /gateway/api/2.0/Me — should now succeed with refreshed cookies
      final meUri = Uri.parse('$_synergiaUrl/gateway/api/2.0/Me');
      final meReq = await ioClient.getUrl(meUri);
      meReq.followRedirects = false;
      meReq.headers.set('User-Agent', _ua);
      meReq.headers.set('Cookie', _sessionCookies!);
      meReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      final meRes = await meReq.close();
      // Also capture cookies from Me response
      final meCookies = meRes.headers['set-cookie'];
      if (meCookies != null) {
        for (final raw in meCookies) {
          final semi = raw.indexOf(';');
          final pair = semi >= 0 ? raw.substring(0, semi) : raw;
          final eq = pair.indexOf('=');
          if (eq > 0) {
            cookieJar[pair.substring(0, eq).trim()] = pair.substring(eq + 1).trim();
          }
        }
        _sessionCookies = cookieJar.entries.map((e) => '${e.key}=${e.value}').join('; ');
        await _secureStorage.saveCookies(_sessionCookies!);
      }
      final meBody = await meRes.transform(utf8.decoder).join();
      if (_diagnosticLogs) {
        debugPrint('[diag] /gateway/api/2.0/Me status=${meRes.statusCode}, '
            'setCookies=${meCookies?.length ?? 0}, '
            'body=${meBody.substring(0, meBody.length.clamp(0, 500))}');
      }

      if (meRes.statusCode == 401) {
        // Gateway token wygasł i nie dało się odświeżyć – wyczyść sesję aby wymusić relogin
        debugPrint('[diag] Gateway /Me 401 – sesja wygasła, czyści cookies aby wymusić ponowne logowanie');
        _sessionCookies = null;
        await _secureStorage.saveCookies('');
        ioClient.close();
        return;
      }

      if (meRes.statusCode == 200 && meBody.isNotEmpty) {
        try {
          final data = json.decode(meBody) as Map<String, dynamic>;
          // Try known token field names
          final token = data['accessToken'] ?? data['access_token']
              ?? data['token'] ?? data['Token']
              ?? (data['Me'] is Map ? (data['Me'] as Map)['accessToken'] : null);
          if (token != null) {
            _gatewayToken = token.toString();
            debugPrint('[diag] gateway token obtained: ${_gatewayToken!.substring(0, _gatewayToken!.length.clamp(0, 20))}...');
          } else if (_diagnosticLogs) {
            debugPrint('[diag] Me response parsed but no token field found. Keys: ${data.keys.toList()}');
          }
        } catch (_) {}
      }

      ioClient.close();
    } catch (e) {
      debugPrint('[diag] _tryGetGatewayToken error: $e');
    }
  }
}
