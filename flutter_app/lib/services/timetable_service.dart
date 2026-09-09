import 'dart:convert';
import 'dart:io';
import 'package:flutter/foundation.dart';
import 'package:html/parser.dart' as html_parser;
import 'package:http/http.dart' as http;
import 'package:kisiplan/models/lesson.dart';
import 'package:kisiplan/models/load_result.dart';
import 'package:kisiplan/services/local_db_service.dart';
import 'package:kisiplan/services/secure_storage_service.dart';

/// Domain-aware cookie jar that keeps cookies scoped per domain,
/// preventing api.librus.pl and synergia.librus.pl from overwriting
/// each other's DZIENNIKSID cookie.
class DomainCookieJar {
  final Map<String, Map<String, String>> _domains = {};

  /// Get cookies for a specific URL domain.
  Map<String, String> forDomain(String domain) {
    return _domains.putIfAbsent(_domainKey(domain), () => {});
  }

  /// Get all cookies that should be sent with a request to [url].
  /// Merges cookies from the exact domain.
  String cookieHeaderForUrl(String url) {
    final uri = Uri.parse(url);
    final domain = _domainKey(uri.host);
    final cookies = Map<String, String>.from(_domains[domain] ?? {});
    return cookies.entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  /// Get cookies as a flat map for a specific domain.
  Map<String, String> cookiesForUrl(String url) {
    final uri = Uri.parse(url);
    return Map<String, String>.from(_domains[_domainKey(uri.host)] ?? {});
  }

  /// Store cookies from a response for the given domain.
  void collectFromResponse(HttpClientResponse res, String requestUrl) {
    final domain = _domainKey(Uri.parse(requestUrl).host);
    final jar = _domains.putIfAbsent(domain, () => {});
    final setCookies = res.headers['set-cookie'];
    if (setCookies == null) return;
    for (final raw in setCookies) {
      final semi = raw.indexOf(';');
      final pair = semi >= 0 ? raw.substring(0, semi) : raw;
      final eq = pair.indexOf('=');
      if (eq < 0) continue;
      final name = pair.substring(0, eq).trim();
      final value = pair.substring(eq + 1).trim();
      if (name.isNotEmpty) jar[name] = value;
    }
  }

  /// Get ALL cookies from all domains as a flat map.
  /// Synergia cookies take priority over API cookies for shared keys.
  Map<String, String> allCookiesFlat() {
    final result = <String, String>{};
    // Add API cookies first, then synergia (so synergia overrides shared keys)
    for (final domain in ['api.librus.pl', 'portal.librus.pl', 'synergia.librus.pl']) {
      final jar = _domains[domain];
      if (jar != null) result.addAll(jar);
    }
    // Add any remaining domains
    for (final entry in _domains.entries) {
      if (!['api.librus.pl', 'portal.librus.pl', 'synergia.librus.pl'].contains(entry.key)) {
        result.addAll(entry.value);
      }
    }
    return result;
  }

  /// Copy specific cookies from one domain to another.
  void copyCookies(String fromDomain, String toDomain, List<String> keys) {
    final src = _domains[_domainKey(fromDomain)];
    if (src == null) return;
    final dst = _domains.putIfAbsent(_domainKey(toDomain), () => {});
    for (final key in keys) {
      if (src.containsKey(key)) dst[key] = src[key]!;
    }
  }

  /// Set a cookie for a specific domain.
  void set(String domain, String name, String value) {
    _domains.putIfAbsent(_domainKey(domain), () => {})[name] = value;
  }

  /// Get all domain names that have cookies.
  List<String> get domains => _domains.keys.toList();

  /// Get all cookie names for a domain.
  List<String> cookieNamesForDomain(String domain) {
    return _domains[_domainKey(domain)]?.keys.toList() ?? [];
  }

  String _domainKey(String host) {
    // Normalize: api.librus.pl, synergia.librus.pl, portal.librus.pl
    if (host.contains('api.librus')) return 'api.librus.pl';
    if (host.contains('synergia.librus')) return 'synergia.librus.pl';
    if (host.contains('portal.librus')) return 'portal.librus.pl';
    return host;
  }

  @override
  String toString() {
    final buf = StringBuffer('DomainCookieJar{');
    for (final entry in _domains.entries) {
      buf.write('${entry.key}: ${entry.value.keys.toList()}, ');
    }
    buf.write('}');
    return buf.toString();
  }
}

class TimetableService {
  static const String _apiUrl = 'https://api.librus.pl';
  static const String _synergiaUrl = 'https://synergia.librus.pl';
  static const String _clientIdTeacher = '47';
  static const String _clientIdStudent = '46';
  static const bool _diagnosticLogs = false;

  final SecureStorageService _secureStorage = SecureStorageService();
  final LocalDbService _db = LocalDbService();

  String? _sessionCookies;
  String? _portalCookies;
  String? _bearerToken;
  String? _csrfToken;
  String? _gatewayToken;
  String? _teacherUuid;
  DomainCookieJar? _domainJar;

  Future<bool> hasSavedCredentials() async {
    final creds = await _secureStorage.readCredentials();
    return (creds.username?.isNotEmpty ?? false) &&
        (creds.password?.isNotEmpty ?? false);
  }

  Future<String?> getSavedUsername() async {
    final creds = await _secureStorage.readCredentials();
    return creds.username;
  }

  Future<String?> getSavedPassword() async {
    final creds = await _secureStorage.readCredentials();
    return creds.password;
  }

  Future<String?> getSavedRole() => _secureStorage.readRole();

  Future<String?> login(
    String username,
    String password, {
    String role = 'teacher',
  }) async {
    final clientId = role == 'teacher' ? _clientIdTeacher : _clientIdStudent;

    debugPrint('[LOGIN] Starting login: role=$role, clientId=$clientId, username=$username');

    try {
      final cookieJar = <String, String>{};
      final domainJar = DomainCookieJar();
      final ioClient = HttpClient()..connectionTimeout = const Duration(seconds: 10);

      // Step 1: Initialize OAuth session (follow all redirects, collect cookies)
      await _ioGetWithRedirects(
        ioClient,
        '$_apiUrl/OAuth/Authorization?client_id=$clientId&response_type=code&scope=mydata',
        cookieJar,
        domainJar: domainJar,
      );

      // Step 2: POST credentials — returns JSON {status, goTo}
      final postBody = await _ioPost(
        ioClient,
        '$_apiUrl/OAuth/Authorization?client_id=$clientId',
        'action=login&login=${Uri.encodeComponent(username)}&pass=${Uri.encodeComponent(password)}',
        cookieJar,
        domainJar: domainJar,
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

      // Step 3: Follow goTo — capture OAuth authorization code from redirect chain.
      // The chain typically goes: api.librus.pl/OAuth/... (several hops)
      //   → synergia.librus.pl/loguj/portalRodzina?code=XXX → portal.librus.pl
      // We need the 'code' parameter to exchange for a Bearer token.
      final goUrl = goTo.startsWith('/') ? '$_apiUrl$goTo' : goTo;
      String? authCode;
      await _ioGetWithBodyCapturingCode(goUrl, cookieJar, (code) {
        authCode = code;
      }, domainJar: domainJar);
      _domainJar = domainJar;
      // Always log cookies after login (critical for debugging session issues)
      debugPrint('[auth] Login cookies after goTo chain: ${cookieJar.keys.toList()}');
      debugPrint('[auth] DomainJar: $domainJar');
      debugPrint('[auth] Has SDZIENNIKSID=${cookieJar.containsKey("SDZIENNIKSID")}, DZIENNIKSID=${cookieJar.containsKey("DZIENNIKSID")}, oauth_token=${cookieJar.containsKey("oauth_token")}');
      if (authCode != null) {
        debugPrint('[auth] authCode captured: ${authCode!.substring(0, authCode!.length.clamp(0, 30))}...');
      }

      if (!cookieJar.containsKey('DZIENNIKSID') &&
          !cookieJar.containsKey('SDZIENNIKSID')) {
        return 'Logowanie nie powiodlo sie: brak sesji Synergia.';
      }

      _sessionCookies = _cookieHeader(cookieJar);
      await _secureStorage.saveCredentials(username: username, password: password);
      await _secureStorage.saveRole(role);
      await _secureStorage.saveCookies(_sessionCookies!);

      // Save portal cookies separately (needed for Bearer token refresh via portal API).
      final portalKeys = {'XSRF-TOKEN', 'portal_librus_session', 'device_identifier', 'cpcs'};
      final portalJar = <String, String>{};
      for (final key in cookieJar.keys) {
        if (portalKeys.contains(key) || key.length > 30) {
          portalJar[key] = cookieJar[key]!;
        }
      }
      if (portalJar.isNotEmpty) {
        _portalCookies = _cookieHeader(portalJar);
        await _secureStorage.savePortalCookies(_portalCookies!);
      }

      // Step 4: Use portal SSO to establish a FULL Synergia session.
      // The session from portalRodzina?code=... is LIMITED (no plan_lekcji).
      // We need to navigate from portal to Synergia via the SSO link
      // (portalRodzina?v=TIMESTAMP) which sets the oauth_token cookie.
      //
      // IMPORTANT (found via live testing): for student accounts this chain never
      // reaches a working plan_lekcji HTML page (Librus rejects client_id=46 there),
      // BUT it still sets an `oauth_token` cookie along the way that the REST/gateway
      // API fallback (_fetchTimetableFromRestApi) needs to authenticate. Skipping this
      // step for students entirely (tried once) broke the gateway fallback with 401s
      // across the board — so it must still run for every role, even though the HTML
      // session itself is a lost cause for students.
      if (portalJar.isNotEmpty) {
        debugPrint('[auth] Trying portal SSO for full Synergia session (role=$role)...');
        await _tryPortalSsoSession(cookieJar, portalJar);
        _sessionCookies = _cookieHeader(cookieJar);
        await _secureStorage.saveCookies(_sessionCookies!);
      }

      // Step 5: Try to get Bearer token.
      // (a) Try exchanging auth code from portalRodzina redirect at portal's token endpoint.
      if (_bearerToken == null && authCode != null) {
        debugPrint('[auth] Trying auth code exchange at portal /oauth2/access_token...');
        await _tryExchangePortalAuthCode(authCode!, clientId);
      }
      // (b) Portal API – works for student accounts (client_id=46).
      if (_bearerToken == null) {
        await _tryGetBearerTokenViaPortal(username, password);
      }
      // (c) Password grant – works for some teacher accounts.
      if (_bearerToken == null) {
        await _tryGetBearerToken(username, password, clientId);
      }

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
    int maxHops = 15,
    DomainCookieJar? domainJar,
  }) async {
    String url = startUrl;
    for (var i = 0; i < maxHops; i++) {
      final uri = Uri.parse(url);
      final req = await client.getUrl(uri);
      req.followRedirects = false;
      req.headers.set('User-Agent', _ua);
      if (domainJar != null) {
        final ch = domainJar.cookieHeaderForUrl(url);
        if (ch.isNotEmpty) req.headers.set('Cookie', ch);
      } else if (cookieJar.isNotEmpty) {
        req.headers.set('Cookie', _cookieHeader(cookieJar));
      }
      final res = await req.close();
      _collectIoCookies(res, cookieJar);
      domainJar?.collectFromResponse(res, url);

      if (_diagnosticLogs) {
        debugPrint('[redirect] hop $i: ${res.statusCode} $url');
      }

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
    Map<String, String> cookieJar, {
    DomainCookieJar? domainJar,
  }) async {
    final uri = Uri.parse(url);
    final req = await client.postUrl(uri);
    req.followRedirects = false;
    req.headers.set('User-Agent', _ua);
    req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
    if (domainJar != null) {
      final ch = domainJar.cookieHeaderForUrl(url);
      if (ch.isNotEmpty) req.headers.set('Cookie', ch);
    } else if (cookieJar.isNotEmpty) {
      req.headers.set('Cookie', _cookieHeader(cookieJar));
    }
    req.write(body);
    final res = await req.close();
    _collectIoCookies(res, cookieJar);
    domainJar?.collectFromResponse(res, url);

    // If redirect after POST, follow with GET
    if (res.statusCode >= 300 && res.statusCode < 400) {
      final location = res.headers.value('location');
      await res.drain<void>();
      if (location != null) {
        await _ioGetWithRedirects(
          client,
          location.startsWith('http') ? location : uri.resolve(location).toString(),
          cookieJar,
          domainJar: domainJar,
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

  /// Uses the portal SSO to establish a full Synergia session.
  /// The portalRodzina?code= flow creates a limited session for students.
  /// We try to extract a JWT from the portal page to call SynergiaAccounts API.
  Future<void> _tryPortalSsoSession(
    Map<String, String> cookieJar,
    Map<String, String> portalJar,
  ) async {
    final ioClient = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      // APPROACH 1: Fetch the portal page and extract JWT / access token.
      // The portal SPA page (portal.librus.pl/rodzina) may contain the JWT
      // in an inline script or window.__INITIAL_STATE__.
      // With the JWT, we can call /api/v3/SynergiaAccounts to get a
      // Synergia access URL that creates a full session.
      for (final portalPath in ['rodzina', 'szkola']) {
        final portalUrl = 'https://portal.librus.pl/$portalPath';
        debugPrint('[sso] Fetching portal page: $portalUrl');
        
        // Start with ALL cookies (api.librus.pl + synergia + portal).
        // The browser has a global cookie jar — we need to simulate that.
        final ssoJar = Map<String, String>.from(cookieJar);
        // Add portal cookies on top (they override for portal.librus.pl domain)
        ssoJar.addAll(portalJar);
        // Seed portal cookies into domain jar (they were extracted from flat jar).
        if (_domainJar != null) {
          for (final e in portalJar.entries) {
            _domainJar!.set('portal.librus.pl', e.key, e.value);
          }
        }

        try {
          // First try the SSO login URL – might redirect through Synergia
          final ssoUrl = 'https://portal.librus.pl/$portalPath/synergia/loguj';
          String? portalBody;
          String url = ssoUrl;
          
          for (var hop = 0; hop < 15; hop++) {
            final uri = Uri.parse(url);
            final req = await ioClient.getUrl(uri);
            req.followRedirects = false;
            req.headers.set('User-Agent', _ua);
            req.headers.set('Referer', 'https://portal.librus.pl/$portalPath');
            if (_domainJar != null) {
              final ch = _domainJar!.cookieHeaderForUrl(url);
              if (ch.isNotEmpty) req.headers.set('Cookie', ch);
            } else if (ssoJar.isNotEmpty) {
              req.headers.set('Cookie', _cookieHeader(ssoJar));
            }
            final res = await req.close();
            _collectIoCookies(res, ssoJar);
            _domainJar?.collectFromResponse(res, url);

            final loc = res.headers.value('location');
            debugPrint('[sso] hop $hop: ${res.statusCode} ${uri.host}${uri.path} → $loc');

            // If we reached Synergia, check cookies
            if (uri.host.contains('synergia.librus.pl') && ssoJar.containsKey('SDZIENNIKSID')) {
              for (final k in ['SDZIENNIKSID', 'DZIENNIKSID', 'DeviceCookie', 'oauth_token']) {
                if (ssoJar.containsKey(k)) cookieJar[k] = ssoJar[k]!;
              }
              final testBody = await _ioGetWithBody('$_synergiaUrl/plan_lekcji', cookieJar);
              if (testBody != null && !testBody.contains('Brak dost') && testBody.contains('data-date')) {
                debugPrint('[sso] SUCCESS! plan_lekcji accessible via SSO ($ssoUrl)');
                return;
              }
            }

            if (res.statusCode >= 300 && res.statusCode < 400 && loc != null) {
              await res.drain<void>();
              url = loc.startsWith('http') ? loc : uri.resolve(loc).toString();
            } else {
              // Got the page body – save it for JWT scanning
              try {
                portalBody = await utf8.decoder.bind(res).join();
              } catch (_) {
                try {
                  portalBody = await res.transform(latin1.decoder).join();
                } catch (_) {
                  try { await res.drain<void>(); } catch (_) {}
                }
              }
              break;
            }
          }

          if (portalBody == null || portalBody.isEmpty) continue;

          // APPROACH 1a: Follow the Synergia SSO link found in the portal page.
          // The portal page contains links like:
          //   https://synergia.librus.pl/loguj/portalRodzina?v=TIMESTAMP
          // When followed with portal+synergia cookies, this may create a full session.
          final synergiaLoginMatch = RegExp(
            r'''https://synergia\.librus\.pl/loguj/portal(?:Rodzina|Szkoly)\?v=\d+'''
          ).firstMatch(portalBody);
          if (synergiaLoginMatch != null) {
            final synergiaLoginUrl = synergiaLoginMatch.group(0)!;
            debugPrint('[sso] Following Synergia SSO link from portal: $synergiaLoginUrl');
            
            // Follow this URL with domain-aware cookies to prevent
            // api.librus.pl and synergia.librus.pl DZIENNIKSID collision.
            final loginJar = Map<String, String>.from(ssoJar);
            String loginUrl = synergiaLoginUrl;
            for (var hop = 0; hop < 15; hop++) {
              final uri = Uri.parse(loginUrl);
              final req = await ioClient.getUrl(uri);
              req.followRedirects = false;
              req.headers.set('User-Agent', _ua);
              req.headers.set('Referer', 'https://portal.librus.pl/$portalPath');
              // Use domain-specific cookies so api.librus.pl gets its own
              // DZIENNIKSID (from initial login) instead of synergia's.
              if (_domainJar != null) {
                final ch = _domainJar!.cookieHeaderForUrl(loginUrl);
                if (ch.isNotEmpty) req.headers.set('Cookie', ch);
              } else if (loginJar.isNotEmpty) {
                req.headers.set('Cookie', _cookieHeader(loginJar));
              }
              final res = await req.close();
              
              // Log ALL Set-Cookie headers
              final rawCookies = res.headers['set-cookie'];
              if (rawCookies != null) {
                for (final c in rawCookies) {
                  final cookieName = c.split('=').first;
                  debugPrint('[sso] SSO-link hop $hop Set-Cookie: $cookieName (${c.length} chars)');
                }
              }
              _collectIoCookies(res, loginJar);
              _domainJar?.collectFromResponse(res, loginUrl);
              
              final loc = res.headers.value('location');
              debugPrint('[sso] SSO-link hop $hop: ${res.statusCode} ${uri.host}${uri.path} → ${loc ?? "null"}');
              // Log the FULL redirect URL to see client_id and parameters
              if (loc != null && loc.contains('OAuth')) {
                debugPrint('[sso] FULL OAuth redirect URL: $loc');
              }
              
              // Check for new cookies
              if (loginJar.containsKey('SDZIENNIKSID')) {
                debugPrint('[sso] Got SDZIENNIKSID from SSO link: ${loginJar["SDZIENNIKSID"]!.substring(0, 10)}...');
              }
              
              if (res.statusCode >= 300 && res.statusCode < 400 && loc != null) {
                await res.drain<void>();
                final nextUrl = loc.startsWith('http') ? loc : uri.resolve(loc).toString();
                // Stop if redirected to portal.librus.pl (end of chain)
                if (nextUrl.contains('portal.librus.pl') && !nextUrl.contains('synergia')) {
                  debugPrint('[sso] SSO-link chain reached portal — stopping');
                  break;
                }
                loginUrl = nextUrl;
              } else {
                // Read and check body for JS cookies/redirects
                String? body;
                try {
                  body = await utf8.decoder.bind(res).join();
                } catch (_) {
                  try { body = await res.transform(latin1.decoder).join(); } catch (_) {}
                }
                if (body != null) {
                  _extractJsCookies(body, loginJar);

                  // If we hit the API login form (200 on api.librus.pl),
                  // the original API session was consumed by Grant.
                  // Re-post credentials to complete this new OAuth flow.
                  // Detection: page title "Centrum Autoryzacji" or presence of login form.
                  final isApiLoginPage = uri.host.contains('api.librus') &&
                      (body.contains('Centrum Autoryzacji') || 
                       body.contains('name="login"') ||
                       body.contains('id="Login"') ||
                       body.contains('action="login"'));
                  if (isApiLoginPage) {
                    debugPrint('[sso] Hit API login form — re-posting credentials for SSO flow');
                    final creds = await _secureStorage.readCredentials();
                    if (creds.username != null && creds.password != null) {
                      // Extract client_id from the URL
                      final clientIdMatch = RegExp(r'client_id=(\d+)').firstMatch(loginUrl);
                      final ssoClientId = clientIdMatch?.group(1) ?? _clientIdTeacher;
                      
                      final postUri = Uri.parse('${uri.scheme}://${uri.host}/OAuth/Authorization?client_id=$ssoClientId');
                      final postReq = await ioClient.postUrl(postUri);
                      postReq.followRedirects = false;
                      postReq.headers.set('User-Agent', _ua);
                      postReq.headers.set('Content-Type', 'application/x-www-form-urlencoded');
                      if (_domainJar != null) {
                        final ch = _domainJar!.cookieHeaderForUrl(postUri.toString());
                        if (ch.isNotEmpty) postReq.headers.set('Cookie', ch);
                      } else {
                        postReq.headers.set('Cookie', _cookieHeader(loginJar));
                      }
                      final postBody = 'action=login&login=${Uri.encodeComponent(creds.username!)}&pass=${Uri.encodeComponent(creds.password!)}';
                      postReq.write(postBody);
                      final postRes = await postReq.close();
                      _collectIoCookies(postRes, loginJar);
                      _domainJar?.collectFromResponse(postRes, postUri.toString());
                      final postResBody = await utf8.decoder.bind(postRes).join();
                      debugPrint('[sso] Re-login POST: ${postRes.statusCode}, body=${postResBody.substring(0, postResBody.length.clamp(0, 300))}');
                      
                      try {
                        final postData = json.decode(postResBody) as Map<String, dynamic>;
                        final goTo = postData['goTo'] as String?;
                        if (goTo != null) {
                          loginUrl = goTo.startsWith('/') ? '${uri.scheme}://${uri.host}$goTo' : goTo;
                          debugPrint('[sso] Re-login goTo: $loginUrl');
                          continue; // Continue the SSO redirect chain
                        }
                      } catch (_) {
                        // Not JSON — check for redirect
                        if (postRes.statusCode >= 300 && postRes.statusCode < 400) {
                          final postLoc = postRes.headers.value('location');
                          if (postLoc != null) {
                            loginUrl = postLoc.startsWith('http') ? postLoc : postUri.resolve(postLoc).toString();
                            continue;
                          }
                        }
                      }
                    }
                  }

                  // Log what the final page contains
                  if (uri.host.contains('api.librus') || uri.host.contains('synergia')) {
                    debugPrint('[sso] SSO-link final page (${body.length} chars) on ${uri.host}: ${body.substring(0, body.length.clamp(0, 1000))}');
                  }
                  final jsRedir = _extractJsRedirect(body, uri);
                  if (jsRedir != null) {
                    debugPrint('[sso] Following JS redirect from SSO link: $jsRedir');
                    loginUrl = jsRedir;
                    continue;
                  }
                }
                break;
              }
            }
            
            // Copy session cookies back to main jar (prefer domain jar for synergia cookies)
            if (_domainJar != null) {
              final synCookies = _domainJar!.cookiesForUrl('https://synergia.librus.pl/');
              for (final k in ['SDZIENNIKSID', 'DZIENNIKSID', 'DeviceCookie', 'oauth_token']) {
                if (synCookies.containsKey(k)) cookieJar[k] = synCookies[k]!;
              }
              debugPrint('[sso] Domain jar synergia cookies after SSO: ${synCookies.keys.toList()}');
              debugPrint('[sso] oauth_token in domain jar: ${synCookies.containsKey("oauth_token")}');
            }
            for (final k in ['SDZIENNIKSID', 'DZIENNIKSID', 'DeviceCookie', 'oauth_token']) {
              if (loginJar.containsKey(k) && !cookieJar.containsKey(k)) cookieJar[k] = loginJar[k]!;
            }
            final testBody = await _ioGetWithBody('$_synergiaUrl/plan_lekcji', cookieJar);
            if (testBody != null && !testBody.contains('Brak dost') && testBody.contains('data-date')) {
              debugPrint('[sso] SUCCESS! plan_lekcji accessible via portal SSO link');
              return;
            }
            debugPrint('[sso] Portal SSO link: plan_lekcji still Brak dostępu');
          }

          // Look for JWT tokens (eyJ...xxx.yyy.zzz)
          final jwtPattern = RegExp(r'eyJ[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}\.[A-Za-z0-9_-]{20,}');
          final jwtMatches = jwtPattern.allMatches(portalBody).toList();
          debugPrint('[sso] Found ${jwtMatches.length} potential JWT(s) in portal page');
          
          // Look for access_token, apiToken, token patterns in JS
          final tokenPatterns = [
            RegExp(r'''["']?access_token["']?\s*[:=]\s*["']([^"']+)["']'''),
            RegExp(r'''["']?accessToken["']?\s*[:=]\s*["']([^"']+)["']'''),
            RegExp(r'''["']?api_token["']?\s*[:=]\s*["']([^"']+)["']'''),
            RegExp(r'''["']?apiToken["']?\s*[:=]\s*["']([^"']+)["']'''),
            RegExp(r'''["']?token["']?\s*[:=]\s*["']([^"']{40,})["']'''),
            RegExp(r'''Authorization["']\s*:\s*["']Bearer\s+([^"']+)["']'''),
          ];
          
          final foundTokens = <String>{};
          for (final jwt in jwtMatches) {
            foundTokens.add(jwt.group(0)!);
          }
          for (final pat in tokenPatterns) {
            for (final m in pat.allMatches(portalBody)) {
              final val = m.group(1)!;
              if (val.length > 30) foundTokens.add(val);
            }
          }
          
          // Also check for SynergiaAccounts URLs or redirect URLs in the page
          final synergiaUrlPattern = RegExp(r'(https?://synergia\.librus\.pl/[^\s"<>]+(?:token|loguj|authorize)[^\s"<>]*)');
          for (final m in synergiaUrlPattern.allMatches(portalBody)) {
            debugPrint('[sso] Found Synergia URL in portal: ${m.group(0)}');
          }

          // Try each found token as Bearer for SynergiaAccounts
          for (final token in foundTokens) {
            debugPrint('[sso] Trying token as Bearer (${token.length} chars): ${token.substring(0, token.length.clamp(0, 40))}...');
            try {
              final accReq = await ioClient.getUrl(Uri.parse('https://portal.librus.pl/api/v3/SynergiaAccounts'));
              accReq.followRedirects = false;
              accReq.headers.set('User-Agent', _ua);
              accReq.headers.set('Accept', 'application/json');
              accReq.headers.set('Authorization', 'Bearer $token');
              accReq.headers.set('Cookie', _cookieHeader(ssoJar));
              final xsrf = ssoJar['XSRF-TOKEN'];
              if (xsrf != null) accReq.headers.set('X-XSRF-TOKEN', Uri.decodeComponent(xsrf));
              final accRes = await accReq.close();
              _collectIoCookies(accRes, ssoJar);
              final accBody = await utf8.decoder.bind(accRes).join();
              
              debugPrint('[sso] SynergiaAccounts with token: status=${accRes.statusCode}, body=${accBody.substring(0, accBody.length.clamp(0, 500))}');
              
              if (accRes.statusCode == 200) {
                _bearerToken = token;
                await _secureStorage.saveToken(token);
                // Extract Synergia access URL from the response
                await _extractSynergiaSessionFromAccounts(ioClient, cookieJar, ssoJar, accBody);
                if (await _testPlanLekcjiAccess(cookieJar)) return;
              }
            } catch (e) {
              debugPrint('[sso] Token test error: $e');
            }
          }

          // If no tokens found in page, try meta CSRF + cookie auth anyway
          if (foundTokens.isEmpty) {
            debugPrint('[sso] No tokens found, trying cookie-based auth with portal cookies');
            final xsrf = ssoJar['XSRF-TOKEN'];
            try {
              final accReq = await ioClient.getUrl(Uri.parse('https://portal.librus.pl/api/v3/SynergiaAccounts'));
              accReq.followRedirects = false;
              accReq.headers.set('User-Agent', _ua);
              accReq.headers.set('Accept', 'application/json');
              accReq.headers.set('X-Requested-With', 'XMLHttpRequest');
              accReq.headers.set('Referer', portalUrl);
              accReq.headers.set('Origin', 'https://portal.librus.pl');
              accReq.headers.set('Cookie', _cookieHeader(ssoJar));
              if (xsrf != null) accReq.headers.set('X-XSRF-TOKEN', Uri.decodeComponent(xsrf));
              // Also try the meta CSRF token
              final csrfMatch = RegExp(r'csrf-token["\s]+content="([^"]+)"').firstMatch(portalBody);
              if (csrfMatch != null) {
                accReq.headers.set('X-CSRF-TOKEN', csrfMatch.group(1)!);
              }
              final accRes = await accReq.close();
              _collectIoCookies(accRes, ssoJar);
              final accBody = await utf8.decoder.bind(accRes).join();
              debugPrint('[sso] SynergiaAccounts cookie-auth: status=${accRes.statusCode}, body=${accBody.substring(0, accBody.length.clamp(0, 500))}');
              
              if (accRes.statusCode == 200) {
                await _extractSynergiaSessionFromAccounts(ioClient, cookieJar, ssoJar, accBody);
                if (await _testPlanLekcjiAccess(cookieJar)) return;
              }
            } catch (e) {
              debugPrint('[sso] Cookie-auth error: $e');
            }
          }
        } catch (e) {
          debugPrint('[sso] Portal page scan error: $e');
        }
      }

      // APPROACH 2: Direct Synergia login form.
      debugPrint('[sso] Approach 2: direct Synergia login form');
      
      // GET the login page to get a fresh CSRF token and session cookies
      final loginReq = await ioClient.getUrl(Uri.parse('$_synergiaUrl/loguj'));
      loginReq.followRedirects = false;
      loginReq.headers.set('User-Agent', _ua);
      final loginRes = await loginReq.close();
      _collectIoCookies(loginRes, cookieJar);
      
      final location = loginRes.headers.value('location');
      debugPrint('[sso] /loguj: status=${loginRes.statusCode}, location=$location');

      if (loginRes.statusCode == 200) {
        // We got the login page — parse it for CSRF token and POST credentials
        final loginBody = await utf8.decoder.bind(loginRes).join();
        final csrfMatch = RegExp(r'csrfTokenValue\s*=\s*"([^"]+)"').firstMatch(loginBody);
        if (csrfMatch != null) {
          final csrf = csrfMatch.group(1)!;
          debugPrint('[sso] CSRF: $csrf');
          
          // Read credentials
          final creds = await _secureStorage.readCredentials();
          final username = creds.username;
          final password = creds.password;
          if (username != null && password != null) {
            final postReq = await ioClient.postUrl(Uri.parse('$_synergiaUrl/loguj'));
            postReq.followRedirects = false;
            postReq.headers.set('User-Agent', _ua);
            postReq.headers.set('Content-Type', 'application/x-www-form-urlencoded');
            postReq.headers.set('Cookie', _cookieHeader(cookieJar));
            postReq.headers.set('Referer', '$_synergiaUrl/loguj');
            final body = 'login=${Uri.encodeComponent(username)}'
                '&passwd=${Uri.encodeComponent(password)}'
                '&csrf_token=${Uri.encodeComponent(csrf)}';
            postReq.contentLength = utf8.encode(body).length;
            postReq.write(body);
            final postRes = await postReq.close();
            _collectIoCookies(postRes, cookieJar);
            final postLoc = postRes.headers.value('location');
            final postBody = await utf8.decoder.bind(postRes).join();
            debugPrint('[sso] POST /loguj: status=${postRes.statusCode}, location=$postLoc, body=${postBody.substring(0, postBody.length.clamp(0, 300))}');
            
            if (postRes.statusCode >= 300 && postRes.statusCode < 400 && postLoc != null) {
              // Follow redirect chain after login
              await _ioGetWithRedirects(ioClient, 
                postLoc.startsWith('http') ? postLoc : '$_synergiaUrl$postLoc',
                cookieJar);
            }
            
            // Test plan_lekcji access
            final testBody = await _ioGetWithBody('$_synergiaUrl/plan_lekcji', cookieJar);
            if (testBody != null && !testBody.contains('Brak dost')) {
              debugPrint('[sso] SUCCESS! plan_lekcji accessible after direct Synergia login');
              return;
            }
            debugPrint('[sso] Direct login still gives Brak dostępu');
          }
        }
      } else {
        await loginRes.drain<void>();
        // If redirect, follow chain
        if (location != null) {
          debugPrint('[sso] /loguj redirects to $location — already logged in?');
          await _ioGetWithRedirects(ioClient, 
            location.startsWith('http') ? location : '$_synergiaUrl$location',
            cookieJar);
        }
      }

      // APPROACH 3: Re-do OAuth login with teacher client_id 47.
      // Known to fail for student accounts with "invalidUserType", 
      // but kept as last resort in case Librus changes the behavior.
      debugPrint('[sso] Approach 3: OAuth re-login with client_id=47');
      final ioClient2 = HttpClient()..connectionTimeout = const Duration(seconds: 10);
      try {
        final oauthJar = <String, String>{};
        await _ioGetWithRedirects(ioClient2,
          '$_apiUrl/OAuth/Authorization?client_id=$_clientIdTeacher&response_type=code&scope=mydata',
          oauthJar);
        final postBody2 = await _ioPost(ioClient2,
          '$_apiUrl/OAuth/Authorization?client_id=$_clientIdTeacher',
          'action=login&login=${Uri.encodeComponent(
            (await _secureStorage.readCredentials()).username ?? '')}'
          '&pass=${Uri.encodeComponent(
            (await _secureStorage.readCredentials()).password ?? '')}',
          oauthJar);
        debugPrint('[sso] OAuth teacher POST: ${postBody2.substring(0, postBody2.length.clamp(0, 300))}');
        
        try {
          final data = json.decode(postBody2) as Map<String, dynamic>;
          final goTo = data['goTo'] as String?;
          if (goTo != null) {
            final goUrl = goTo.startsWith('/') ? '$_apiUrl$goTo' : goTo;
            String url = goUrl;
            for (var hop = 0; hop < 15; hop++) {
              final uri = Uri.parse(url);
              final req = await ioClient2.getUrl(uri);
              req.followRedirects = false;
              req.headers.set('User-Agent', _ua);
              req.headers.set('Cookie', _cookieHeader(oauthJar));
              final res = await req.close();
              _collectIoCookies(res, oauthJar);
              final loc = res.headers.value('location');
              if (res.statusCode >= 300 && res.statusCode < 400 && loc != null) {
                await res.drain<void>();
                final nextUrl = loc.startsWith('http') ? loc : uri.resolve(loc).toString();
                if (nextUrl.contains('portal.librus.pl')) break;
                url = nextUrl;
              } else {
                await res.drain<void>();
                break;
              }
            }
            for (final key in ['SDZIENNIKSID', 'DZIENNIKSID', 'DeviceCookie']) {
              if (oauthJar.containsKey(key)) cookieJar[key] = oauthJar[key]!;
            }
            final testBody3 = await _ioGetWithBody('$_synergiaUrl/plan_lekcji', cookieJar);
            if (testBody3 != null && !testBody3.contains('Brak dost') && testBody3.contains('data-date')) {
              debugPrint('[sso] SUCCESS! plan_lekcji accessible with teacher OAuth session');
              return;
            }
          }
        } catch (e) {
          debugPrint('[sso] OAuth teacher error: $e');
        }
      } finally {
        ioClient2.close();
      }
    } catch (e) {
      debugPrint('[sso] _tryPortalSsoSession error: $e');
    } finally {
      ioClient.close();
    }
  }

  /// Extract Synergia access info from SynergiaAccounts JSON response
  /// and try to establish a full session.
  Future<void> _extractSynergiaSessionFromAccounts(
    HttpClient ioClient,
    Map<String, String> cookieJar,
    Map<String, String> portalJar,
    String responseBody,
  ) async {
    try {
      final data = json.decode(responseBody);
      final List accounts;
      if (data is List) {
        accounts = data;
      } else if (data is Map && data.containsKey('accounts')) {
        accounts = data['accounts'] as List;
      } else {
        debugPrint('[sso] Unexpected SynergiaAccounts format');
        return;
      }
      if (accounts.isEmpty) return;

      debugPrint('[sso] SynergiaAccounts: ${accounts.length} account(s)');
      for (final rawAccount in accounts) {
        final account = rawAccount as Map<String, dynamic>;
        debugPrint('[sso] Account keys: ${account.keys.toList()}');

        final accessToken = account['accessToken'] as String?
            ?? account['access_token'] as String?;
        final login = account['login']?.toString()
            ?? account['id']?.toString();

        if (accessToken != null && accessToken.isNotEmpty) {
          debugPrint('[sso] Got accessToken (${accessToken.length} chars)');

          // Try setting oauth_token and testing
          cookieJar['oauth_token'] = Uri.encodeComponent(accessToken);
          var testBody = await _ioGetWithBody('$_synergiaUrl/plan_lekcji', cookieJar);
          if (testBody != null && !testBody.contains('Brak dost') && testBody.contains('data-date')) {
            debugPrint('[sso] SUCCESS with oauth_token cookie');
            return;
          }

          // Try navigating to Synergia /loguj with the token
          final tokenUrls = [
            '$_synergiaUrl/loguj/token/$accessToken',
            '$_synergiaUrl/loguj?token=${Uri.encodeComponent(accessToken)}',
          ];
          for (final tokenUrl in tokenUrls) {
            debugPrint('[sso] Trying Synergia token URL: $tokenUrl');
            await _ioGetWithBody(tokenUrl, cookieJar);
            testBody = await _ioGetWithBody('$_synergiaUrl/plan_lekcji', cookieJar);
            if (testBody != null && !testBody.contains('Brak dost') && testBody.contains('data-date')) {
              debugPrint('[sso] SUCCESS via token URL');
              return;
            }
          }
        }

        // Also try /fresh endpoint if login is known
        if (login != null && _bearerToken != null) {
          debugPrint('[sso] Trying /fresh/$login');
          final freshReq = await ioClient.getUrl(
            Uri.parse('https://portal.librus.pl/api/v3/SynergiaAccounts/fresh/$login'));
          freshReq.followRedirects = false;
          freshReq.headers.set('User-Agent', _ua);
          freshReq.headers.set('Accept', 'application/json');
          freshReq.headers.set('Authorization', 'Bearer $_bearerToken');
          freshReq.headers.set('Cookie', _cookieHeader(portalJar));
          final xsrf = portalJar['XSRF-TOKEN'];
          if (xsrf != null) freshReq.headers.set('X-XSRF-TOKEN', Uri.decodeComponent(xsrf));
          final freshRes = await freshReq.close();
          final freshBody = await utf8.decoder.bind(freshRes).join();
          debugPrint('[sso] /fresh/$login: status=${freshRes.statusCode}, body=${freshBody.substring(0, freshBody.length.clamp(0, 500))}');

          if (freshRes.statusCode == 200) {
            final freshData = json.decode(freshBody) as Map<String, dynamic>;
            final freshToken = freshData['accessToken'] as String?
                ?? freshData['access_token'] as String?;
            if (freshToken != null) {
              cookieJar['oauth_token'] = Uri.encodeComponent(freshToken);
              await _ioGetWithBody('$_synergiaUrl/loguj/token/$freshToken', cookieJar);
              final testBody = await _ioGetWithBody('$_synergiaUrl/plan_lekcji', cookieJar);
              if (testBody != null && !testBody.contains('Brak dost') && testBody.contains('data-date')) {
                debugPrint('[sso] SUCCESS via /fresh token');
                return;
              }
            }
          }
        }
      }
    } catch (e) {
      debugPrint('[sso] _extractSynergiaSessionFromAccounts error: $e');
    }
  }

  /// Quick test if plan_lekcji is now accessible.
  Future<bool> _testPlanLekcjiAccess(Map<String, String> jar) async {
    final body = await _ioGetWithBody('$_synergiaUrl/plan_lekcji', jar);
    return body != null && !body.contains('Brak dost') && body.contains('data-date');
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

  /// Exchanges the OAuth authorization code (from portalRodzina redirect) at the portal's token endpoint.
  Future<void> _tryExchangePortalAuthCode(String code, String clientId) async {
    final ioClient = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      _portalCookies ??= await _secureStorage.readPortalCookies();
      final portalJar = _portalCookies != null ? _parseCookieString(_portalCookies!) : <String, String>{};
      final cookieStr = _cookieHeader(portalJar);

      // Try exchanging at portal's OAuth2 token endpoint with various configurations.
      final exchangeConfigs = [
        // Portal OAuth2 endpoint (no client_secret)
        {
          'url': 'https://portal.librus.pl/oauth2/access_token',
          'body': 'grant_type=authorization_code'
              '&code=${Uri.encodeComponent(code)}'
              '&client_id=$clientId'
              '&redirect_uri=${Uri.encodeComponent("$_synergiaUrl/loguj/portalRodzina")}',
        },
        // Portal OAuth2 endpoint with redirect to portal
        {
          'url': 'https://portal.librus.pl/oauth2/access_token',
          'body': 'grant_type=authorization_code'
              '&code=${Uri.encodeComponent(code)}'
              '&client_id=$clientId'
              '&redirect_uri=${Uri.encodeComponent("https://portal.librus.pl")}',
        },
        // API token endpoint (already tried, but now with portal cookies too)
        {
          'url': '$_apiUrl/OAuth/Token',
          'body': 'grant_type=authorization_code'
              '&code=${Uri.encodeComponent(code)}'
              '&client_id=$clientId'
              '&redirect_uri=${Uri.encodeComponent("$_synergiaUrl/loguj/portalRodzina")}',
        },
      ];

      for (final cfg in exchangeConfigs) {
        try {
          final req = await ioClient.postUrl(Uri.parse(cfg['url']!));
          req.followRedirects = false;
          req.headers.set('User-Agent', _ua);
          req.headers.set('Content-Type', 'application/x-www-form-urlencoded');
          req.headers.set('Accept', 'application/json');
          if (cookieStr.isNotEmpty) req.headers.set('Cookie', cookieStr);
          req.contentLength = utf8.encode(cfg['body']!).length;
          req.write(cfg['body']!);
          final res = await req.close();
          final resBody = await utf8.decoder.bind(res).join();
          debugPrint('[auth] Code exchange ${cfg['url']}: status=${res.statusCode}, body=${resBody.substring(0, resBody.length.clamp(0, 400))}');

          if (res.statusCode == 200) {
            try {
              final data = json.decode(resBody) as Map<String, dynamic>;
              final jwt = data['access_token'] as String? ?? data['token'] as String?;
              if (jwt != null && jwt.contains('.')) {
                _bearerToken = jwt;
                await _secureStorage.saveToken(jwt);
                debugPrint('[auth] Bearer JWT from code exchange: ${jwt.substring(0, 30)}...');
                return;
              }
            } catch (_) {}
          }
        } catch (e) {
          debugPrint('[auth] Code exchange error: $e');
        }
      }
    } finally {
      ioClient.close();
    }
  }

  /// Tries to obtain a Bearer token via the Librus Portal API (for student/parent accounts).
  /// After the main OAuth login flow, we already have portal_librus_session cookie.
  /// Use it to call the Portal SynergiaAccounts API for an access token.
  Future<void> _tryGetBearerTokenViaPortal(String username, String password) async {
    final ioClient = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      // We already have portal cookies from the main login's goTo redirect.
      // Let's use them to call the Portal API directly.
      _portalCookies ??= await _secureStorage.readPortalCookies();
      if (_portalCookies == null || _portalCookies!.isEmpty) {
        debugPrint('[auth] Portal: no portal cookies available');
        return;
      }

      final portalJar = _parseCookieString(_portalCookies!);
      final xsrfRaw = portalJar['XSRF-TOKEN'];
      final xsrfDecoded = xsrfRaw != null ? Uri.decodeComponent(xsrfRaw) : null;

      debugPrint('[auth] Portal: cookies=${portalJar.keys.toList()}, xsrf=${xsrfRaw != null ? "${xsrfRaw.substring(0, xsrfRaw.length.clamp(0, 20))}..." : "null"}');

      // First: GET portal /rodzina page to check if our cookies give us an active session,
      // and look for any embedded tokens (the portal is an SPA that may inject tokens into HTML).
      final portalPageReq = await ioClient.getUrl(Uri.parse('https://portal.librus.pl/rodzina'));
      portalPageReq.followRedirects = false;
      portalPageReq.headers.set('User-Agent', _ua);
      portalPageReq.headers.set('Cookie', _cookieHeader(portalJar));
      var portalPageRes = await portalPageReq.close();
      // Log ALL Set-Cookie headers from this response
      if (_diagnosticLogs) {
        final rawCookies = portalPageRes.headers['set-cookie'];
        debugPrint('[auth] Portal /rodzina Set-Cookie (${rawCookies?.length ?? 0}): ${rawCookies?.map((c) => c.substring(0, c.length.clamp(0, 80))).toList()}');
      }
      _collectIoCookies(portalPageRes, portalJar);
      // Follow redirects manually to capture all Set-Cookie headers
      var hopCount = 0;
      while (portalPageRes.statusCode >= 300 && portalPageRes.statusCode < 400 && hopCount < 10) {
        final location = portalPageRes.headers.value('location');
        await portalPageRes.drain<void>();
        if (location == null) break;
        final nextUrl = location.startsWith('http') ? location : 'https://portal.librus.pl$location';
        debugPrint('[auth] Portal redirect hop $hopCount: ${portalPageRes.statusCode} → $nextUrl');
        final nextReq = await ioClient.getUrl(Uri.parse(nextUrl));
        nextReq.followRedirects = false;
        nextReq.headers.set('User-Agent', _ua);
        nextReq.headers.set('Cookie', _cookieHeader(portalJar));
        portalPageRes = await nextReq.close();
        if (_diagnosticLogs) {
          final rawCookies = portalPageRes.headers['set-cookie'];
          if (rawCookies != null && rawCookies.isNotEmpty) {
            debugPrint('[auth] Portal redirect Set-Cookie: ${rawCookies.map((c) => c.substring(0, c.length.clamp(0, 100))).toList()}');
          }
        }
        _collectIoCookies(portalPageRes, portalJar);
        hopCount++;
      }
      final portalPageBody = await utf8.decoder.bind(portalPageRes).join();

      if (_diagnosticLogs) {
        debugPrint('[auth] Portal /rodzina: status=${portalPageRes.statusCode}, len=${portalPageBody.length}');
        // List ALL cookies we have after the portal page load
        debugPrint('[auth] All portal cookies: ${portalJar.keys.toList()}');
        // Check for laravel_token cookie specifically
        debugPrint('[auth] laravel_token cookie: ${portalJar['laravel_token'] != null ? "present (${portalJar['laravel_token']!.substring(0, portalJar['laravel_token']!.length.clamp(0, 30))}...)" : "MISSING"}');
        // Find CSRF meta token
        final csrfMatch2 = RegExp(r'csrf-token["\s]+content="([^"]+)"').firstMatch(portalPageBody);
        if (csrfMatch2 != null) {
          debugPrint('[auth] Portal HTML csrf-token: ${csrfMatch2.group(1)}');
        }
        // Find all JS source files referenced in the portal page
        final jsFiles = RegExp(r'src="([^"]+\.js[^"]*)"').allMatches(portalPageBody);
        final jsUrls = <String>{};
        for (final m in jsFiles) {
          final url = m.group(1) ?? '';
          if (url.contains('app') || url.contains('main') || url.contains('vendor') || url.contains('manifest')) {
            jsUrls.add(url.startsWith('http') ? url : 'https://portal.librus.pl$url');
          }
        }
        debugPrint('[auth] Portal JS files: $jsUrls');

        // Search portal HTML for embedded JWT tokens (format: eyJ...xxx.yyy.zzz)
        final jwtPattern = RegExp(r'eyJ[A-Za-z0-9_-]+\.eyJ[A-Za-z0-9_-]+\.[A-Za-z0-9_-]+');
        final jwtMatches = jwtPattern.allMatches(portalPageBody);
        for (final m in jwtMatches) {
          final jwt = m.group(0)!;
          debugPrint('[auth] FOUND JWT in HTML: ${jwt.substring(0, jwt.length.clamp(0, 80))}...');
        }

        // Search for token-like variables in inline scripts
        final tokenPatterns = [
          RegExp(r'''["']?(?:access_?[tT]oken|api_?[tT]oken|bearer_?[tT]oken|jwt|authToken)["']?\s*[:=]\s*["']([^"']+)["']'''),
          RegExp(r'window\.__(?:TOKEN|AUTH|JWT|API_TOKEN|ACCESS_TOKEN)\s*=\s*["\x27]([^"\x27]+)["\x27]'),
          RegExp(r'<meta\s+name="api[_-]token"\s+content="([^"]+)"'),
          RegExp(r'Laravel\s*=\s*\{[^}]*"apiToken"\s*:\s*"([^"]+)"'),
        ];
        for (final p in tokenPatterns) {
          final match = p.firstMatch(portalPageBody);
          if (match != null) {
            debugPrint('[auth] FOUND token pattern in HTML: ${match.group(0)!.substring(0, match.group(0)!.length.clamp(0, 100))}');
            final token = match.group(1);
            if (token != null && token.contains('.') && token.split('.').length == 3) {
              _bearerToken = token;
              await _secureStorage.saveToken(token);
              debugPrint('[auth] Bearer JWT extracted from HTML!');
              return;
            }
          }
        }
      }

      // Refresh XSRF token from portal page if we got new cookies.
      final updatedXsrf = portalJar['XSRF-TOKEN'];
      final updatedXsrfDecoded = updatedXsrf != null ? Uri.decodeComponent(updatedXsrf) : xsrfDecoded;

      // Extract meta csrf-token from portal HTML (Laravel uses this as X-CSRF-TOKEN).
      String? metaCsrf;
      final csrfMatch = RegExp(r'csrf-token["\s]+content="([^"]+)"').firstMatch(portalPageBody);
      if (csrfMatch != null) {
        metaCsrf = csrfMatch.group(1);
        debugPrint('[auth] Meta CSRF token: $metaCsrf');
      }

      // Try multiple SynergiaAccounts request variants.
      // The portal SPA sets these headers — maybe some are required.
      final cookieStr = _cookieHeader(portalJar);

      // Find the "unknown" cookie — it has a long random name (>30 chars) and could be a token.
      String? unknownCookieValue;
      String? unknownCookieName;
      for (final entry in portalJar.entries) {
        if (!{'XSRF-TOKEN', 'device_identifier', 'portal_librus_session', 'cpcs', 'SDZIENNIKSID', 'DZIENNIKSID', 'DeviceCookie', 'personalizedLoginPage', 'cookiesession1'}.contains(entry.key) && entry.key.length > 20) {
          unknownCookieName = entry.key;
          unknownCookieValue = entry.value;
          debugPrint('[auth] Unknown cookie "$unknownCookieName": ${entry.value.substring(0, entry.value.length.clamp(0, 60))}...');
          break;
        }
      }

      final variants = <String, Map<String, String>>{
        'cookies-only': {
          'User-Agent': _ua,
          'Accept': 'application/json',
          'Cookie': cookieStr,
          if (updatedXsrfDecoded != null) 'X-XSRF-TOKEN': updatedXsrfDecoded,
          if (metaCsrf != null) 'X-CSRF-TOKEN': metaCsrf,
        },
        if (unknownCookieValue != null) 'bearer-unknown-cookie': {
          'User-Agent': _ua,
          'Accept': 'application/json',
          'Cookie': cookieStr,
          'Authorization': 'Bearer $unknownCookieValue',
        },
        'bearer-session': {
          'User-Agent': _ua,
          'Accept': 'application/json',
          'Cookie': cookieStr,
          'Authorization': 'Bearer ${portalJar['portal_librus_session'] ?? ''}',
        },
        if (updatedXsrfDecoded != null) 'bearer-xsrf': {
          'User-Agent': _ua,
          'Accept': 'application/json',
          'Cookie': cookieStr,
          'Authorization': 'Bearer $updatedXsrfDecoded',
        },
      };

      String? accBody;
      for (final entry in variants.entries) {
        final label = entry.key;
        final hdrs = entry.value;
        final accReq = await ioClient.getUrl(Uri.parse('https://portal.librus.pl/api/v3/SynergiaAccounts'));
        accReq.followRedirects = false;
        for (final h in hdrs.entries) {
          accReq.headers.set(h.key, h.value);
        }
        final accRes = await accReq.close();
        _collectIoCookies(accRes, portalJar);
        accBody = await utf8.decoder.bind(accRes).join();

        debugPrint('[auth] SynergiaAccounts [$label]: status=${accRes.statusCode}, len=${accBody.length}, body=${accBody.substring(0, accBody.length.clamp(0, 500))}');

        if (accRes.statusCode == 200) {
          await _extractTokenFromSynergiaAccounts(ioClient, portalJar, accBody);
          if (_bearerToken != null) return;
        }
      }

      if (_bearerToken == null) {
        // None of the SynergiaAccounts variants worked.
        // The API requires a JWT Bearer token (not cookies, not encrypted cookies).
        // Try to find an OAuth2 token endpoint on the portal.
        debugPrint('[auth] Need JWT Bearer token. Trying OAuth2 flows...');

        // Try POST to /oauth/token (Laravel Passport) with various paths
        final tokenEndpoints = [
          'https://portal.librus.pl/oauth/token',
          'https://portal.librus.pl/api/v3/Login',
          'https://portal.librus.pl/api/v3/Token',
          'https://portal.librus.pl/api/Login',
        ];
        for (final url in tokenEndpoints) {
          try {
            // Try as POST with grant_type=client_credentials or password
            final req = await ioClient.postUrl(Uri.parse(url));
            req.followRedirects = false;
            req.headers.set('User-Agent', _ua);
            req.headers.set('Content-Type', 'application/json');
            req.headers.set('Accept', 'application/json');
            req.headers.set('Cookie', cookieStr);
            if (updatedXsrfDecoded != null) req.headers.set('X-XSRF-TOKEN', updatedXsrfDecoded);
            if (metaCsrf != null) req.headers.set('X-CSRF-TOKEN', metaCsrf);
            final body = json.encode({'email': username, 'password': password});
            req.contentLength = utf8.encode(body).length;
            req.write(body);
            final res = await req.close();
            _collectIoCookies(res, portalJar);
            final resBody = await utf8.decoder.bind(res).join();
            debugPrint('[auth] POST $url: status=${res.statusCode}, body=${resBody.substring(0, resBody.length.clamp(0, 300))}');
            if (res.statusCode == 200) {
              // Check for token in response
              try {
                final data = json.decode(resBody);
                final token = data['access_token'] as String? ?? data['token'] as String? ?? data['accessToken'] as String?;
                if (token != null && token.contains('.')) {
                  _bearerToken = token;
                  await _secureStorage.saveToken(token);
                  debugPrint('[auth] Bearer JWT from $url: ${token.substring(0, 30)}...');
                  return;
                }
              } catch (_) {}
            }
          } catch (e) {
            debugPrint('[auth] POST $url error: $e');
          }
        }

        // Last resort: try OAuth2 authorize with response_type=token (Implicit Grant) on portal
        // Try multiple known client IDs.
        final implicitClients = [
          {'client_id': 'VaItV6oRutdo8j2hdUdPvfBmqRa5cFnFKnVjFtLw', 'redirect_uri': 'app://szkolny'},
          {'client_id': 'wmSyUMo8llDAs4y9tJVYY92oyZ6h4AQo', 'redirect_uri': 'http://localhost/librus'},
          {'client_id': '46', 'redirect_uri': 'https://portal.librus.pl'},
        ];
        for (final ic in implicitClients) {
          try {
            final implicitUrl = 'https://portal.librus.pl/oauth2/authorize'
                '?client_id=${Uri.encodeComponent(ic['client_id']!)}'
                '&response_type=token'
                '&redirect_uri=${Uri.encodeComponent(ic['redirect_uri']!)}';
            debugPrint('[auth] Trying implicit grant: ${ic['client_id']!.substring(0, ic['client_id']!.length.clamp(0, 10))}...');
            final implReq = await ioClient.getUrl(Uri.parse(implicitUrl));
            implReq.followRedirects = false;
            implReq.headers.set('User-Agent', _ua);
            implReq.headers.set('Cookie', cookieStr);
            final implRes = await implReq.close();
            _collectIoCookies(implRes, portalJar);
            final location = implRes.headers.value('location');
            final implBody = await utf8.decoder.bind(implRes).join();
            debugPrint('[auth] Implicit grant: status=${implRes.statusCode}, location=$location, body=${implBody.substring(0, implBody.length.clamp(0, 300))}');
            // Check for token in fragment or query
            if (location != null) {
              final tokenMatch = RegExp(r'access_token=([^&#]+)').firstMatch(location);
              if (tokenMatch != null) {
                final token = Uri.decodeComponent(tokenMatch.group(1)!);
                _bearerToken = token;
                await _secureStorage.saveToken(token);
                debugPrint('[auth] Bearer JWT from implicit: ${token.substring(0, 30)}...');
                return;
              }
              // Also check for auth code (might redirect with code instead)
              final codeMatch = RegExp(r'[?&]code=([^&#]+)').firstMatch(location);
              if (codeMatch != null) {
                debugPrint('[auth] Got auth code from implicit redirect: ${codeMatch.group(1)!.substring(0, 20)}...');
                // Exchange for token
                final tokenReq = await ioClient.postUrl(Uri.parse('https://portal.librus.pl/oauth2/access_token'));
                tokenReq.followRedirects = false;
                tokenReq.headers.set('User-Agent', _ua);
                tokenReq.headers.set('Content-Type', 'application/x-www-form-urlencoded');
                tokenReq.headers.set('Accept', 'application/json');
                final tokenBody = 'grant_type=authorization_code'
                    '&code=${Uri.encodeComponent(codeMatch.group(1)!)}'
                    '&client_id=${Uri.encodeComponent(ic['client_id']!)}'
                    '&redirect_uri=${Uri.encodeComponent(ic['redirect_uri']!)}';
                tokenReq.contentLength = utf8.encode(tokenBody).length;
                tokenReq.write(tokenBody);
                final tokenRes = await tokenReq.close();
                final tokenResBody = await utf8.decoder.bind(tokenRes).join();
                debugPrint('[auth] Code→Token: status=${tokenRes.statusCode}, body=${tokenResBody.substring(0, tokenResBody.length.clamp(0, 300))}');
                if (tokenRes.statusCode == 200) {
                  try {
                    final data = json.decode(tokenResBody) as Map<String, dynamic>;
                    final jwt = data['access_token'] as String?;
                    if (jwt != null && jwt.contains('.')) {
                      _bearerToken = jwt;
                      await _secureStorage.saveToken(jwt);
                      debugPrint('[auth] Bearer JWT from code exchange: ${jwt.substring(0, 30)}...');
                      return;
                    }
                  } catch (_) {}
                }
              }
            }
          } catch (e) {
            debugPrint('[auth] Implicit grant error: $e');
          }
        }

        debugPrint('[auth] All portal Bearer token methods failed — trying school login');
        await _tryPortalLogin(ioClient, portalJar, username, password);
        if (_bearerToken != null) return;
        return;
      }
    } catch (e) {
      debugPrint('[auth] _tryGetBearerTokenViaPortal error: $e');
    } finally {
      ioClient.close();
    }
  }

  /// Try to obtain a Bearer JWT via the portal's OAuth2 Authorization Code flow.
  /// This mimics what the Librus mobile app (and third-party apps like szkolny.eu) do:
  ///   1. GET /oauth2/authorize?client_id=...&response_type=code&redirect_uri=... (with portal cookies)
  ///   2. Follow redirect to get ?code=XXX from the redirect URI
  ///   3. POST /oauth2/access_token with code → get JWT
  ///   4. Use JWT as Bearer to call /api/v3/SynergiaAccounts
  Future<void> _tryPortalLogin(HttpClient ioClient, Map<String, String> portalJar, String username, String password) async {
    try {
      final cookieStr = _cookieHeader(portalJar);

      // Known portal OAuth2 client IDs from third-party Librus apps.
      final oauthClients = [
        // szkolny.eu app
        {'client_id': 'VaItV6oRutdo8j2hdUdPvfBmqRa5cFnFKnVjFtLw', 'redirect_uri': 'app://szkolny'},
        // Generic / self-hosted
        {'client_id': 'wmSyUMo8llDAs4y9tJVYY92oyZ6h4AQo', 'redirect_uri': 'http://localhost/librus'},
      ];

      for (final client in oauthClients) {
        final clientId = client['client_id']!;
        final redirectUri = client['redirect_uri']!;
        debugPrint('[auth] Portal OAuth2: client_id=${clientId.substring(0, 10)}..., redirect=$redirectUri');

        // Step 1: Authorization request — should redirect to redirect_uri?code=XXX if logged in.
        final authUrl = 'https://portal.librus.pl/oauth2/authorize'
            '?client_id=${Uri.encodeComponent(clientId)}'
            '&redirect_uri=${Uri.encodeComponent(redirectUri)}'
            '&response_type=code';

        String? authCode;
        String currentUrl = authUrl;

        for (var hop = 0; hop < 15; hop++) {
          final req = await ioClient.getUrl(Uri.parse(currentUrl));
          req.followRedirects = false;
          req.headers.set('User-Agent', _ua);
          req.headers.set('Cookie', _cookieHeader(portalJar));
          final res = await req.close();
          _collectIoCookies(res, portalJar);

          final location = res.headers.value('location');
          final body = await utf8.decoder.bind(res).join();

          debugPrint('[auth] OAuth2 hop $hop: ${res.statusCode} $currentUrl → location=$location');
          if (body.isNotEmpty && body.length < 500) {
            debugPrint('[auth] OAuth2 hop $hop body: $body');
          }

          // Check if the redirect URI contains a code parameter
          if (location != null) {
            final codeMatch = RegExp(r'[?&]code=([^&]+)').firstMatch(location);
            if (codeMatch != null) {
              authCode = codeMatch.group(1)!;
              debugPrint('[auth] OAuth2 auth code from redirect: ${authCode.substring(0, authCode.length.clamp(0, 30))}...');
              break;
            }
          }
          // Also check current URL for code (might be the final destination)
          final currentCodeMatch = RegExp(r'[?&]code=([^&]+)').firstMatch(currentUrl);
          if (currentCodeMatch != null) {
            authCode = currentCodeMatch.group(1)!;
            debugPrint('[auth] OAuth2 auth code from URL: ${authCode.substring(0, authCode.length.clamp(0, 30))}...');
            break;
          }

          // Check if we're at a login page (need to login first) — dump body
          if (res.statusCode == 200 && body.contains('login')) {
            debugPrint('[auth] OAuth2 landed on login page (${body.length} bytes)');
            // Check for embedded code in body (some flows return it in JSON)
            final bodyCodeMatch = RegExp(r'"code"\s*:\s*"([^"]+)"').firstMatch(body);
            if (bodyCodeMatch != null) {
              authCode = bodyCodeMatch.group(1)!;
              debugPrint('[auth] OAuth2 auth code from body JSON: ${authCode.substring(0, authCode.length.clamp(0, 30))}...');
              break;
            }
          }

          if (res.statusCode >= 300 && res.statusCode < 400 && location != null) {
            currentUrl = location.startsWith('http') ? location : Uri.parse(currentUrl).resolve(location).toString();
          } else {
            break;
          }
        }

        if (authCode != null) {
          // Step 2: Exchange auth code for access token.
          debugPrint('[auth] Exchanging auth code for token...');
          final tokenReq = await ioClient.postUrl(Uri.parse('https://portal.librus.pl/oauth2/access_token'));
          tokenReq.followRedirects = false;
          tokenReq.headers.set('User-Agent', _ua);
          tokenReq.headers.set('Content-Type', 'application/x-www-form-urlencoded');
          tokenReq.headers.set('Accept', 'application/json');

          final tokenBody = 'grant_type=authorization_code'
              '&code=${Uri.encodeComponent(authCode)}'
              '&client_id=${Uri.encodeComponent(clientId)}'
              '&redirect_uri=${Uri.encodeComponent(redirectUri)}';
          tokenReq.contentLength = utf8.encode(tokenBody).length;
          tokenReq.write(tokenBody);
          final tokenRes = await tokenReq.close();
          final tokenResBody = await utf8.decoder.bind(tokenRes).join();
          debugPrint('[auth] OAuth2 token response: status=${tokenRes.statusCode}, body=${tokenResBody.substring(0, tokenResBody.length.clamp(0, 500))}');

          if (tokenRes.statusCode == 200) {
            try {
              final data = json.decode(tokenResBody) as Map<String, dynamic>;
              final jwt = data['access_token'] as String?;
              if (jwt != null && jwt.contains('.')) {
                _bearerToken = jwt;
                await _secureStorage.saveToken(jwt);
                debugPrint('[auth] Portal OAuth2 JWT obtained! ${jwt.substring(0, 30)}...');

                // Step 3: Use JWT to call SynergiaAccounts and get Synergia access token.
                final accReq = await ioClient.getUrl(Uri.parse('https://portal.librus.pl/api/v3/SynergiaAccounts'));
                accReq.followRedirects = false;
                accReq.headers.set('User-Agent', _ua);
                accReq.headers.set('Accept', 'application/json');
                accReq.headers.set('Authorization', 'Bearer $jwt');
                final accRes = await accReq.close();
                final accBody = await utf8.decoder.bind(accRes).join();
                debugPrint('[auth] SynergiaAccounts with JWT: status=${accRes.statusCode}, body=${accBody.substring(0, accBody.length.clamp(0, 500))}');

                if (accRes.statusCode == 200) {
                  await _extractTokenFromSynergiaAccounts(ioClient, portalJar, accBody);
                }
                return;
              }
            } catch (e) {
              debugPrint('[auth] OAuth2 token parse error: $e');
            }
          }
        } else {
          debugPrint('[auth] No auth code obtained for client $clientId');
        }
      }

      // If OAuth2 flow didn't work, try X-Requested-With header (Laravel AJAX cookie auth).
      debugPrint('[auth] OAuth2 flows failed. Trying XHR cookie auth...');
      final accReq = await ioClient.getUrl(Uri.parse('https://portal.librus.pl/api/v3/SynergiaAccounts'));
      accReq.followRedirects = false;
      accReq.headers.set('User-Agent', _ua);
      accReq.headers.set('Accept', 'application/json');
      accReq.headers.set('X-Requested-With', 'XMLHttpRequest');
      accReq.headers.set('Cookie', cookieStr);
      final xsrfRaw = portalJar['XSRF-TOKEN'];
      if (xsrfRaw != null) accReq.headers.set('X-XSRF-TOKEN', Uri.decodeComponent(xsrfRaw));
      final accRes = await accReq.close();
      _collectIoCookies(accRes, portalJar);
      final accBody = await utf8.decoder.bind(accRes).join();
      debugPrint('[auth] SynergiaAccounts with XHR: status=${accRes.statusCode}, body=${accBody.substring(0, accBody.length.clamp(0, 500))}');
      if (accRes.statusCode == 200) {
        await _extractTokenFromSynergiaAccounts(ioClient, portalJar, accBody);
      }
    } catch (e) {
      debugPrint('[auth] _tryPortalLogin error: $e');
    }
  }

  /// Extract access token from a SynergiaAccounts response body.
  Future<void> _extractTokenFromSynergiaAccounts(HttpClient ioClient, Map<String, String> portalJar, String responseBody) async {
    try {
      final data = json.decode(responseBody);
      final List accounts;
      if (data is List) {
        accounts = data;
      } else if (data is Map && data.containsKey('accounts')) {
        accounts = data['accounts'] as List;
      } else {
        debugPrint('[auth] Unexpected SynergiaAccounts format: ${data.runtimeType}');
        return;
      }
      if (accounts.isEmpty) return;

      debugPrint('[auth] SynergiaAccounts: ${accounts.length} account(s)');
      final firstAccount = accounts[0] as Map<String, dynamic>;
      debugPrint('[auth] First account keys: ${firstAccount.keys.toList()}');

      // Check for embedded token.
      final embeddedToken = firstAccount['accessToken'] as String? ?? firstAccount['access_token'] as String?;
      if (embeddedToken != null && embeddedToken.isNotEmpty) {
        _bearerToken = embeddedToken;
        await _secureStorage.saveToken(embeddedToken);
        debugPrint('[auth] Bearer from embedded token: ${embeddedToken.substring(0, embeddedToken.length.clamp(0, 20))}...');
        return;
      }

      // Get login/id and call /fresh endpoint.
      final login = firstAccount['login']?.toString() ??
          firstAccount['id']?.toString() ??
          firstAccount['accountIdentifier']?.toString();
      if (login == null) {
        debugPrint('[auth] No login/id in account: ${firstAccount.keys.toList()}');
        return;
      }

      final xsrfRaw = portalJar['XSRF-TOKEN'];
      final xsrfDecoded = xsrfRaw != null ? Uri.decodeComponent(xsrfRaw) : null;

      final freshReq = await ioClient.getUrl(Uri.parse('https://portal.librus.pl/api/v3/SynergiaAccounts/fresh/$login'));
      freshReq.followRedirects = false;
      freshReq.headers.set('User-Agent', _ua);
      freshReq.headers.set('Accept', 'application/json');
      freshReq.headers.set('Cookie', _cookieHeader(portalJar));
      if (xsrfDecoded != null) {
        freshReq.headers.set('X-XSRF-TOKEN', xsrfDecoded);
      }

      final freshRes = await freshReq.close();
      final freshBody = await utf8.decoder.bind(freshRes).join();

      debugPrint('[auth] SynergiaAccounts/fresh/$login: status=${freshRes.statusCode}, body=${freshBody.substring(0, freshBody.length.clamp(0, 500))}');

      if (freshRes.statusCode == 200) {
        final freshData = json.decode(freshBody) as Map<String, dynamic>;
        final token = freshData['accessToken'] as String? ?? freshData['access_token'] as String?;
        if (token != null && token.isNotEmpty) {
          _bearerToken = token;
          await _secureStorage.saveToken(token);
          debugPrint('[auth] Bearer from fresh: ${token.substring(0, token.length.clamp(0, 20))}...');
        }
      }
    } catch (e) {
      debugPrint('[auth] _extractTokenFromSynergiaAccounts error: $e');
    }
  }

  Future<String?> autoLoginIfPossible() async {
    _bearerToken ??= await _secureStorage.readToken();
    final savedCookies = await _secureStorage.readCookies();

    final creds = await _secureStorage.readCredentials();
    if (creds.username != null && creds.password != null) {
      // Always attempt fresh login to avoid relying on stale cookies.
      final role = (await _secureStorage.readRole()) ?? 'teacher';
      final error = await login(creds.username!, creds.password!, role: role);
      if (error == null) return null; // Fresh login succeeded.

      debugPrint('autoLoginIfPossible: fresh login failed: $error');
      // Login failed (network issue, etc.) – fall back to existing cookies.
      if (savedCookies != null && savedCookies.isNotEmpty) {
        _sessionCookies = savedCookies;
        return null;
      }
      return error;
    }

    // No credentials – rely on saved cookies if they exist.
    if (savedCookies != null && savedCookies.isNotEmpty) {
      _sessionCookies = savedCookies;
      return null;
    }
    return 'Brak zapisanych danych logowania.';
  }

  Future<void> logout() async {
    _sessionCookies = null;
    await _secureStorage.clearAll();
    await _db.clear();
  }

  Future<LoadResult> getTodayLessons() async {
    // Only actually true once a relogin is attempted below — otherwise a
    // failed fetch here just means a network/server hiccup (bad school
    // wifi, DNS blip, Librus down, ...) and blaming "session expired"
    // would be misleading.
    var sessionActuallyExpired = false;
    var relogAttempted = false;

    // Tries a fresh login at most once per call. Cookies being non-empty
    // doesn't mean the session is actually alive — Librus can reject a
    // stale token outright (e.g. HTML "Brak dostępu" or REST/gateway 401
    // "TokenIsExpired") without us clearing it locally first, so this is
    // also used as a last resort even when cookies "looked" fine.
    Future<bool> tryRelogin() async {
      if (relogAttempted) return false;
      relogAttempted = true;
      sessionActuallyExpired = true;
      return (await autoLoginIfPossible()) == null;
    }

    final remote = await _fetchRemoteTimetable();
    if (remote != null) {
      final totalRemote = remote.values.expand((x) => x).length;
      if (totalRemote > 0) {
        await _db.replaceAll(remote);
      }
      return LoadResult(lessons: _extractToday(remote), weekTimetable: remote, fromCache: false);
    }

    // Jeśli _sessionCookies == null lub puste, sesja wygasła - próbuj ponownie zalogować
    if (_sessionCookies == null || _sessionCookies!.isEmpty) {
      if (await tryRelogin()) {
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

    // Both the HTML plan and the REST/gateway API failed. If cookies looked
    // empty this was already retried above; if they looked non-empty but
    // everything still failed, the session may be dead server-side without
    // us knowing — try one relogin before giving up either way.
    if (await tryRelogin()) {
      final remoteAfterRelogin = await _fetchRemoteTimetable();
      if (remoteAfterRelogin != null) {
        await _db.replaceAll(remoteAfterRelogin);
        return LoadResult(lessons: _extractToday(remoteAfterRelogin), weekTimetable: remoteAfterRelogin, fromCache: false);
      }
      final apiAfterRelogin = await _fetchTimetableFromRestApi();
      if (apiAfterRelogin != null) {
        await _db.replaceAll(apiAfterRelogin);
        return LoadResult(lessons: _extractToday(apiAfterRelogin), weekTimetable: apiAfterRelogin, fromCache: false);
      }
    }

    final cached = await _db.readAll();
    final todayFromCache = _extractToday(cached);
    if (todayFromCache.isNotEmpty) {
      return LoadResult(
        lessons: todayFromCache,
        weekTimetable: cached,
        fromCache: true,
        warning: sessionActuallyExpired
            ? 'Sesja wygasła, nie udało się pobrać nowego planu. Pokazano ostatni zapisany.'
            : 'Brak internetu lub problem z serwerem Librusa. Pokazano ostatni zapisany plan.',
      );
    }
    return const LoadResult(
      lessons: [],
      weekTimetable: {},
      fromCache: true,
      warning: 'Nie udalo sie pobrac planu i brak danych offline.',
    );
  }

  /// Instantly returns whatever timetable is already saved on the phone,
  /// without touching the network. School wifi/signal is often too weak or
  /// absent during the day, and schedule changes are only published in the
  /// morning or afternoon/evening anyway — so the screen shouldn't have to
  /// wait on a live fetch just to show today's plan.
  Future<LoadResult> getCachedTimetable() async {
    final cached = await _db.readAll();
    return LoadResult(lessons: _extractToday(cached), weekTimetable: cached, fromCache: true);
  }

  Future<Map<String, List<Lesson>>?> _fetchRemoteTimetable() async {
    _sessionCookies ??= await _secureStorage.readCookies();
    if (_sessionCookies == null || _sessionCookies!.isEmpty) {
      debugPrint('[FETCH] No session cookies available!');
      return null;
    }

    try {
      // Parse existing cookies into a mutable jar so redirects can update them.
      final cookieJar = _parseCookieString(_sessionCookies!);
      debugPrint('[FETCH] Cookies: ${cookieJar.keys.toList()}');

      // First: try direct URL (works for teachers and some student accounts).
      var body = await _ioGetWithBody(
        '$_synergiaUrl/plan_lekcji?pokaz_dyzury_miedzylekcyjne=1',
        cookieJar,
      );
      
      // Always log the result of the first fetch
      if (body != null) {
        final hasDataDate = body.contains('data-date');
        final hasBrakDost = body.contains('Brak dost');
        debugPrint('[FETCH] plan_lekcji: len=${body.length}, hasDataDate=$hasDataDate, hasBrakDost=$hasBrakDost');
      } else {
        debugPrint('[FETCH] plan_lekcji returned null!');
      }

      if (_diagnosticLogs && body != null) {
        final containsDutyWord = body.toLowerCase().contains('dyżur') || body.toLowerCase().contains('dyzur');
        final hasDataDate = body.contains('data-date');
        final hasBrakDost = body.contains('Brak dost');
        debugPrint('[diag] plan_lekcji status=200, len=${body.length}, containsDyzur=$containsDutyWord, hasDataDate=$hasDataDate, hasBrakDost=$hasBrakDost');
        // Dump first request to see what we actually get
        if (hasBrakDost || !hasDataDate) {
          const chunkSize = 2000;
          for (var i = 0; i < body.length; i += chunkSize) {
            final end = (i + chunkSize).clamp(0, body.length);
            debugPrint('[diag] plan-first[$i..$end]: ${body.substring(i, end)}');
          }
        }
      }

      // Detect "Brak dostępu" page with JS redirect to /loguj/przenies/...
      // Librus sometimes requires a session transfer before accessing the timetable.
      // We need to follow the transfer URL (which sets up cookies), then re-fetch.
      if (body != null && body.contains('Brak dost')) {
        final hasRedirect = body.contains('loguj') && body.contains('przenies');
        if (hasRedirect) {
          debugPrint('[diag] Brak dostępu z redirect do /loguj/przenies/ – przenoszę sesję');

          // Step 1: Follow the session transfer path
          await _ioGetWithBody(
            '$_synergiaUrl/loguj/przenies/plan_lekcji?pokaz_dyzury_miedzylekcyjne=1',
            cookieJar,
          );
          _sessionCookies = _cookieHeader(cookieJar);
          await _secureStorage.saveCookies(_sessionCookies!);

          // Step 2: Re-fetch the timetable with transferred session
          body = await _ioGetWithBody(
            '$_synergiaUrl/plan_lekcji?pokaz_dyzury_miedzylekcyjne=1',
            cookieJar,
          );
          _sessionCookies = _cookieHeader(cookieJar);
          await _secureStorage.saveCookies(_sessionCookies!);

          if (_diagnosticLogs && body != null) {
            debugPrint('[diag] po przeniesieniu sesji: len=${body.length}, hasDataDate=${body.contains("data-date")}');
            // Dump full page after transfer for debugging
            const chunkSize = 3000;
            for (var i = 0; i < body.length; i += chunkSize) {
              final end = (i + chunkSize).clamp(0, body.length);
              debugPrint('[diag] html-after-transfer[$i..$end]: ${body.substring(i, end)}');
            }
          }

          // If still "Brak dostępu", try alternative URLs for students.
          if (body != null && body.contains('Brak dost') && !body.contains('data-date')) {
            debugPrint('[diag] Brak dostępu po przeniesieniu sesji – próbuję alternatywne adresy');

            // Students often have access to przegladaj_plan_lekcji instead of plan_lekcji
            for (final altUrl in [
              '$_synergiaUrl/przegladaj_plan_lekcji',
              '$_synergiaUrl/terminarz',
              '$_synergiaUrl/uczen_index',
            ]) {
              final altBody = await _ioGetWithBody(altUrl, cookieJar);
              if (altBody != null) {
                debugPrint('[diag] alt $altUrl: len=${altBody.length}, hasDataDate=${altBody.contains("data-date")}, hasBrakDost=${altBody.contains("Brak dost")}');
                if (altBody.contains('data-date') || (altBody.contains('plan_lekcji') && !altBody.contains('Brak dost'))) {
                  body = altBody;
                  break;
                }
              }
            }
            if (body != null && body.contains('Brak dost') && !body.contains('data-date')) {
              debugPrint('[diag] Brak dostępu po wszystkich próbach – HTML scraping niedostępny');
              return null;
            }
          }
        } else if (!body.contains('data-date')) {
          debugPrint('[diag] Brak dostępu wykryty, brak redirectu i brak data-date – HTML scraping nie dostępny');
          _sessionCookies = _cookieHeader(cookieJar);
          await _secureStorage.saveCookies(_sessionCookies!);
          return null;
        }
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
        // Check if the HTML is a genuine timetable page (just with no lessons this week)
        // vs a broken/empty page after session expiry.
        final hasValidStructure = body.contains('plan_lekcji') ||
            body.contains('data-date') ||
            _csrfToken != null;
        if (hasValidStructure) {
          debugPrint('[diag] HTML sparsowany, 0 lekcji ale strona wygląda na poprawną – pusty tydzień');
          // Don't cache empty timetable — keep previous cached data.
          return timetable;
        }
        debugPrint('[diag] HTML sparsowany ale 0 lekcji i brak struktury planu – traktuję jako wygaśnięcie sesji');
        _sessionCookies = null;
        await _secureStorage.saveCookies('');
        return null;
      }
      _bearerToken ??= await _secureStorage.readToken();
      await _fetchAndCacheLessonTimesIfPossible();
      // Dyżury (breaktime supervision) to koncepcja wyłącznie nauczycielska.
      // Bez tego gatingu konto ucznia, które trafi tu przez SSO (zamiast fallbacku
      // REST API), dostałoby _teacherUuid == null i _fetchAndMergeDuties wpadłby
      // w wariant "bez filtra", doklejając uczniowi dyżury WSZYSTKICH nauczycieli.
      final role = await _secureStorage.readRole();
      if (role == 'teacher') {
        await _fetchAndMergeDuties(timetable);
      }
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
      headers = {
        'Cookie': _sessionCookies!,
        'User-Agent': _ua,
        'X-Requested-With': 'XMLHttpRequest',
      };
      debugPrint('[api] używam gateway z ciasteczkami sesji');
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
            // Previously skipped outright, which hid cancellations from
            // students entirely. Keep the slot and mark it isCancelled so the
            // UI can show it struck through, matching the teacher HTML view.
            final isCanceled = slotMap['IsCanceled'] == true;

            final lessonNo = int.tryParse(slotMap['LessonNo']?.toString() ?? '') ?? periodIdx;
            final times = lessonTimes[lessonNo];

            final subject = (slotMap['Subject'] as Map<String, dynamic>?)?['Name']?.toString() ?? '';
            if (subject.isEmpty) continue;

            final classroomId = (slotMap['Classroom'] as Map<String, dynamic>?)?['Id']?.toString() ?? '';
            final room = classroomNames[classroomId] ?? '';
            final isSubstitution = !isCanceled && slotMap['IsSubstitutionClass'] == true;
            // No confirmed field for the covering teacher's name yet (see
            // commit "Show substitutions and cancellations for student
            // accounts" — the REST API slot didn't expose the original
            // lesson either). Log the raw slot so the field can be found and
            // wired up next time a real substitution shows up; remove once done.
            if (isSubstitution) {
              debugPrint('[api][substitution-raw] ${json.encode(slotMap)}');
            }

            final classSymbol = (slotMap['Class'] as Map<String, dynamic>?)?['Symbol']?.toString() ?? '';
            final classGroupName = (slotMap['ClassGroup'] as Map<String, dynamic>?)?['Name']?.toString() ?? '';
            final className = [classSymbol, classGroupName].where((s) => s.isNotEmpty).join(' ');

            result[dayKey]!.add(Lesson.fromJson({
              'start': times?['from'] ?? '',
              'end': times?['to'] ?? '',
              'subject': subject,
              'room': room,
              'className': className,
              'isSubstitution': isSubstitution,
              'isDuty': false,
              'isCancelled': isCanceled,
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

      const baseUrl = '$_synergiaUrl/gateway/ms/breaktimesupervision';
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
      for (var i = 0; i < items.length; i++) {
        final encoded = json.encode(items[i]);
        debugPrint('[diag] supervision item $i: ${encoded.substring(0, encoded.length.clamp(0, 700))}');
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
      // A duty covering for another supervisor comes back with
      // status "SUBSTITUTION" (and a substitutedSupervisorIdentifier)
      // instead of the normal "ACTUAL".
      final isSubstitutionDuty = item['status'] == 'SUBSTITUTION';
      if (dateStr == null || timeFrom == null || timeTo == null) continue;
      final date = DateTime.tryParse(dateStr);
      if (date == null) continue;
      final dayKey = dayKeys[date.weekday];
        if (dayKey == null) continue;

        bool matchesThisDuty(Lesson l) =>
            l.isDuty &&
            l.startString == timeFrom.toString() &&
            l.endString == timeTo.toString() &&
            l.room.trim().toLowerCase() == location.toString().trim().toLowerCase();
        final existing = timetable[dayKey]!.where(matchesThisDuty).toList();
        if (existing.isNotEmpty) {
          // Already added (e.g. by the HTML parser) — only worth touching if
          // this feed knows it's a substitution and the existing entry
          // doesn't yet reflect that.
          if (isSubstitutionDuty && existing.any((l) => !l.isSubstitution)) {
            timetable[dayKey]!.removeWhere(matchesThisDuty);
          } else {
            continue;
          }
        }

        timetable[dayKey]!.add(Lesson.fromJson({
          'start': timeFrom.toString(),
          'end': timeTo.toString(),
          'subject': 'Dyżur',
          'room': location.toString(),
          'className': '',
          'isDuty': true,
          'isSubstitution': isSubstitutionDuty,
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
        // Diagnoza: sprawdź czy HTML w ogóle ma elementy z data-date
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
      // Librus strikes a cell through (<s>) whenever the originally planned
      // lesson doesn't happen as scheduled: a shift/substitution (which also
      // shows a replacement lesson), or a plain cancellation — teacher
      // absence, class absence, "odwołane" — with no replacement at all.
      // The keyword check is kept as a fallback for markup variants that
      // don't use <s> but still describe a shift/substitution in words.
      final hasStrike = cell.querySelector('s') != null;
      final looksLikeChange = cellLower.contains('przesunięcie') ||
          cellLower.contains('zastępstwo') ||
          cellLower.contains('zastepstwo');
      final isStruckThrough = !isDuty && (hasStrike || looksLikeChange);

      String subject;
      String room;
      String className;
      bool isSubstitution = false;
      bool isCancelled = false;
      String? originalSubject;
      String? originalRoom;
      String? originalClassName;

      if (isDuty) {
        // For duties: the cell text is the location (e.g. "PARTER").
        subject = 'Dyżur';
        room = cellText; // location used as "room"
        className = '';
        isSubstitution = rowCells.any(
          (c) => c.text.toLowerCase().contains('zastępstwo') ||
              c.text.toLowerCase().contains('zastepstwo'),
        );
      } else if (isStruckThrough) {
        // First <div class="text"> holds the cancelled lesson, second (if
        // present) holds the new lesson replacing it (a "zastępstwo"). The
        // <s> strike itself may sit inside the first div OR wrap both divs
        // as their common ancestor, so its exact position can't be used to
        // decide whether a replacement exists — only the div count can.
        final textDivs = cell.querySelectorAll('div.text');

        if (textDivs.length >= 2) {
          isSubstitution = true;
          final origText = textDivs[0].text.trim();
          originalSubject = textDivs[0].querySelector('b')?.text.trim() ?? '';
          originalRoom = RegExp(r's\.[\s\u00a0]*([0-9a-zA-Z]+)').firstMatch(origText)?.group(1) ?? '';
          originalClassName = _extractClassName(origText);

          final newText = textDivs[1].text.trim();
          subject = textDivs[1].querySelector('b')?.text.trim() ?? newText;
          room = RegExp(r's\.[\s\u00a0]*([0-9a-zA-Z]+)').firstMatch(newText)?.group(1) ?? '';
          className = _extractClassName(newText);
        } else {
          // No replacement lesson - the whole slot is just crossed out.
          isCancelled = true;
          final source = textDivs.isNotEmpty ? textDivs[0] : cell;
          final text = source.text.trim();
          subject = source.querySelector('b')?.text.trim() ?? text;
          room = RegExp(r's\.[\s\u00a0]*([0-9a-zA-Z]+)').firstMatch(text)?.group(1) ?? '';
          className = _extractClassName(text);
        }
      } else {
        subject = cell.querySelector('b')?.text.trim() ?? cellText;
        room = RegExp(r's\.[\s\u00a0]*([0-9a-zA-Z]+)').firstMatch(cellText)?.group(1) ?? '';
        className = _extractClassName(cellText);
      }

      if (subject.isEmpty) continue;

      final key = '$dayKey|$timeFrom|$timeTo|${subject.toLowerCase()}|${room.toLowerCase()}|${className.toLowerCase()}';
      if (!seen.add(key)) continue;

      result[dayKey]!.add(Lesson.fromJson({
        'start': timeFrom,
        'end': timeTo,
        'subject': subject,
        'room': room,
        'className': className,
        'isSubstitution': isSubstitution,
        'isDuty': isDuty,
        'isCancelled': isCancelled,
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

      final key = '$dayKey|$timeFrom|$timeTo|dyżur|${location.toLowerCase()}|';
      if (!seen.add(key)) continue;

      final rowCells = cell.parent?.querySelectorAll('td') ?? [];
      final isSubstitutionDuty = rowCells.any(
        (c) => c.text.toLowerCase().contains('zastępstwo') ||
            c.text.toLowerCase().contains('zastepstwo'),
      );

      result[dayKey]!.add(Lesson.fromJson({
        'start': timeFrom,
        'end': timeTo,
        'subject': 'Dyżur',
        'room': location,
        'className': '',
        'isDuty': true,
        'isSubstitution': isSubstitutionDuty,
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

      final key = '$dayKey|$timeFrom|$timeTo|dyżur|${location.toLowerCase()}|';
      if (!seen.add(key)) continue;

      final isSubstitutionDuty = cols.any(
        (c) => c.text.toLowerCase().contains('zastępstwo') ||
            c.text.toLowerCase().contains('zastepstwo'),
      );

      result[dayKey]!.add(Lesson.fromJson({
        'start': timeFrom,
        'end': timeTo,
        'subject': 'Dyżur',
        'room': location,
        'className': '',
        'isDuty': true,
        'isSubstitution': isSubstitutionDuty,
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
    final ioClient = HttpClient()..connectionTimeout = const Duration(seconds: 10);
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

        if (_diagnosticLogs) {
          debugPrint('[getBody] hop $i: ${res.statusCode} $url');
        }

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

  /// Like [_ioGetWithBody] but also captures OAuth authorization code from redirect URLs.
  Future<String?> _ioGetWithBodyCapturingCode(
    String startUrl,
    Map<String, String> cookieJar,
    void Function(String code) onCodeFound, {
    int maxHops = 15,
    DomainCookieJar? domainJar,
  }) async {
    final ioClient = HttpClient()..connectionTimeout = const Duration(seconds: 10);
    try {
      String url = startUrl;
      for (var i = 0; i < maxHops; i++) {
        final uri = Uri.parse(url);
        final req = await ioClient.getUrl(uri);
        req.followRedirects = false;
        req.headers.set('User-Agent', _ua);
        if (domainJar != null) {
          final ch = domainJar.cookieHeaderForUrl(url);
          if (ch.isNotEmpty) req.headers.set('Cookie', ch);
        } else if (cookieJar.isNotEmpty) {
          req.headers.set('Cookie', _cookieHeader(cookieJar));
        }
        final res = await req.close();

        // Always log Set-Cookie headers and redirect URL at every hop
        // to find where oauth_token should come from.
        final rawCookies = res.headers['set-cookie'];
        if (rawCookies != null && rawCookies.isNotEmpty) {
          for (final c in rawCookies) {
            final cookieName = c.split('=').first;
            debugPrint('[goTo] hop $i Set-Cookie: $cookieName (${c.length} chars)');
          }
        }

        _collectIoCookies(res, cookieJar);
        domainJar?.collectFromResponse(res, url);

        final location = res.headers.value('location');
        debugPrint('[goTo] hop $i: ${res.statusCode} ${uri.host}${uri.path} → ${location ?? "null"} cookies=${cookieJar.keys.toList()}');

        // Capture OAuth code from redirect URL (e.g. /loguj/portalRodzina?code=XXX)
        final codeMatch = RegExp(r'[?&]code=([^&#]+)').firstMatch(url);
        if (codeMatch != null) {
          onCodeFound(Uri.decodeComponent(codeMatch.group(1)!));
        }

        if (res.statusCode >= 300 && res.statusCode < 400) {
          final location = res.headers.value('location');
          await res.drain<void>();
          if (location == null) break;
          url = location.startsWith('http')
              ? location
              : uri.resolve(location).toString();
        } else {
          String body;
          try {
            body = await utf8.decoder.bind(res).join();
          } catch (_) {
            try {
              body = await res.transform(latin1.decoder).join();
            } catch (_) {
              try { await res.drain<void>(); } catch (_) {}
              break;
            }
          }

          // Extract cookies set by JavaScript in the page body.
          // Librus pages (especially portalRodzina) may set cookies via JS
          // instead of Set-Cookie headers.
          _extractJsCookies(body, cookieJar);

          // Check for META refresh or JS redirect and continue following.
          final jsRedirect = _extractJsRedirect(body, uri);
          if (jsRedirect != null) {
            debugPrint('[goTo] Following JS/META redirect: $jsRedirect');
            url = jsRedirect;
            continue;
          }

          return body;
        }
      }
    } finally {
      ioClient.close();
    }
    return null;
  }

  /// Extract cookies set by JavaScript (document.cookie = "name=value...") in HTML body.
  void _extractJsCookies(String body, Map<String, String> jar) {
    // Pattern: document.cookie = "name=value; path=/; ..."
    final patterns = [
      RegExp(r'document\.cookie\s*=\s*"([^"]+)"'),
      RegExp(r"document\.cookie\s*=\s*'([^']+)'"),
    ];
    for (final pattern in patterns) {
      for (final match in pattern.allMatches(body)) {
        final cookieStr = match.group(1)!;
        final parts = cookieStr.split(';');
        if (parts.isNotEmpty) {
          final nameValue = parts.first.trim();
          final eq = nameValue.indexOf('=');
          if (eq > 0) {
            final name = nameValue.substring(0, eq).trim();
            final value = nameValue.substring(eq + 1).trim();
            if (name.isNotEmpty && !const {'path', 'domain', 'expires', 'max-age'}.contains(name.toLowerCase())) {
              jar[name] = value;
              debugPrint('[goTo] JS cookie found: $name (${value.length} chars)');
            }
          }
        }
      }
    }

    // Also look for oauth_token assigned via JS variable concatenation
    // e.g.: var token = "VALUE"; document.cookie = "oauth_token=" + token
    final oauthAssign = RegExp(r'oauth_token\s*[=:]\s*["\x27]([^"\x27]{10,})["\x27]').firstMatch(body);
    if (oauthAssign != null && !jar.containsKey('oauth_token')) {
      jar['oauth_token'] = oauthAssign.group(1)!;
      debugPrint('[goTo] Found oauth_token in HTML variable');
    }
  }

  /// Extract redirect URL from META refresh or JavaScript window.location.
  String? _extractJsRedirect(String body, Uri baseUri) {
    // META refresh: <meta http-equiv="refresh" content="0;url=https://...">
    final metaMatch = RegExp(
      r'<meta[^>]+http-equiv\s*=\s*["\x27]refresh["\x27][^>]+content\s*=\s*["\x27][^"\x27]*url\s*=\s*([^"\x27>\s]+)',
      caseSensitive: false,
    ).firstMatch(body);
    if (metaMatch != null) {
      final redirectUrl = metaMatch.group(1)!;
      return redirectUrl.startsWith('http') ? redirectUrl : baseUri.resolve(redirectUrl).toString();
    }

    // JavaScript: window.location = "..." or window.location.href = "..."
    final jsMatch = RegExp(
      r'window\.location(?:\.href)?\s*=\s*["\x27]([^"\x27]+)["\x27]',
    ).firstMatch(body);
    if (jsMatch != null) {
      final redirectUrl = jsMatch.group(1)!;
      return redirectUrl.startsWith('http') ? redirectUrl : baseUri.resolve(redirectUrl).toString();
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
      final ioClient = HttpClient()..connectionTimeout = const Duration(seconds: 10);

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
        // Gateway token refresh failed – this is normal for some accounts
        // (e.g. teacher accounts where REST API isn't available).
        // Do NOT clear session cookies – they may still be valid for HTML scraping.
        debugPrint('[diag] Gateway /Me 401 – gateway REST API niedostępne, ale sesja HTML może być ważna');
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
