import 'package:flutter_test/flutter_test.dart';
import 'package:kisiplan/services/timetable_service.dart';

/// Simulates the multi-domain Librus login handshake:
/// api.librus.pl issues a DZIENNIKSID, then synergia.librus.pl issues its
/// OWN DZIENNIKSID with a different value. Before DomainCookieJar existed,
/// a flat cookie map would let the second write clobber the first, breaking
/// whichever domain's session cookie got overwritten. These tests simulate
/// that handshake and assert the two stay isolated.
void main() {
  group('DomainCookieJar domain isolation', () {
    test('api.librus.pl and synergia.librus.pl keep separate DZIENNIKSID values', () {
      final jar = DomainCookieJar();

      jar.set('api.librus.pl', 'DZIENNIKSID', 'api-session-111');
      jar.set('synergia.librus.pl', 'DZIENNIKSID', 'synergia-session-222');

      expect(jar.forDomain('api.librus.pl')['DZIENNIKSID'], 'api-session-111');
      expect(jar.forDomain('synergia.librus.pl')['DZIENNIKSID'], 'synergia-session-222');
    });

    test('cookieHeaderForUrl only returns cookies scoped to that URL\'s domain', () {
      final jar = DomainCookieJar();
      jar.set('api.librus.pl', 'DZIENNIKSID', 'api-value');
      jar.set('synergia.librus.pl', 'SDZIENNIKSID', 'synergia-value');

      final apiHeader = jar.cookieHeaderForUrl('https://api.librus.pl/OAuth/Token');
      final synergiaHeader = jar.cookieHeaderForUrl('https://synergia.librus.pl/plan_lekcji');

      expect(apiHeader, 'DZIENNIKSID=api-value');
      expect(synergiaHeader, 'SDZIENNIKSID=synergia-value');
    });

    test('subdomains/hosts containing "api.librus" or "synergia.librus" normalize to the same bucket', () {
      final jar = DomainCookieJar();
      jar.set('api.librus.pl', 'DZIENNIKSID', 'v1');
      // A redirect hop might resolve to a slightly different host string.
      jar.set('foo.api.librus.pl', 'DZIENNIKSID', 'v2');

      // Both writes should have landed in the same normalized bucket.
      expect(jar.forDomain('api.librus.pl')['DZIENNIKSID'], 'v2');
      expect(jar.domains, ['api.librus.pl']);
    });

    test('unrelated hosts are kept under their own literal key', () {
      final jar = DomainCookieJar();
      jar.set('portal.librus.pl', 'XSRF-TOKEN', 'xsrf-1');
      jar.set('example.com', 'session', 'other-1');

      expect(jar.domains..sort(), ['example.com', 'portal.librus.pl']);
      expect(jar.cookieHeaderForUrl('https://example.com/x'), 'session=other-1');
    });
  });

  group('DomainCookieJar.allCookiesFlat merge priority', () {
    test('synergia cookies override api cookies for shared cookie names', () {
      final jar = DomainCookieJar();
      jar.set('api.librus.pl', 'oauth_token', 'api-token');
      jar.set('synergia.librus.pl', 'oauth_token', 'synergia-token');

      final flat = jar.allCookiesFlat();

      expect(flat['oauth_token'], 'synergia-token');
    });

    test('cookies from domains outside the known trio are still included', () {
      final jar = DomainCookieJar();
      jar.set('api.librus.pl', 'a', '1');
      jar.set('weird.host.pl', 'b', '2');

      final flat = jar.allCookiesFlat();

      expect(flat, containsPair('a', '1'));
      expect(flat, containsPair('b', '2'));
    });
  });

  group('DomainCookieJar.copyCookies', () {
    test('copies only the requested keys, leaving the rest behind', () {
      final jar = DomainCookieJar();
      jar.set('portal.librus.pl', 'XSRF-TOKEN', 'xsrf-value');
      jar.set('portal.librus.pl', 'device_identifier', 'device-value');
      jar.set('portal.librus.pl', 'unrelated', 'should-not-copy');

      jar.copyCookies('portal.librus.pl', 'synergia.librus.pl', ['XSRF-TOKEN', 'device_identifier']);

      final copied = jar.forDomain('synergia.librus.pl');
      expect(copied['XSRF-TOKEN'], 'xsrf-value');
      expect(copied['device_identifier'], 'device-value');
      expect(copied.containsKey('unrelated'), isFalse);
    });

    test('copying from a domain with no cookies yet is a safe no-op', () {
      final jar = DomainCookieJar();
      jar.copyCookies('api.librus.pl', 'synergia.librus.pl', ['DZIENNIKSID']);

      expect(jar.domains, isEmpty);
    });
  });

  group('End-to-end login handshake simulation', () {
    test('a realistic multi-hop login leaves each domain with its own coherent jar', () {
      final jar = DomainCookieJar();

      // Hop 1: api.librus.pl OAuth/Authorization sets an API session cookie.
      jar.set('api.librus.pl', 'DZIENNIKSID', 'api-session');

      // Hop 2: redirect chain reaches synergia.librus.pl via portalRodzina,
      // which sets its own DZIENNIKSID + SDZIENNIKSID.
      jar.set('synergia.librus.pl', 'DZIENNIKSID', 'synergia-session');
      jar.set('synergia.librus.pl', 'SDZIENNIKSID', 'synergia-full-session');

      // Hop 3: portal.librus.pl issues an XSRF token for the SPA.
      jar.set('portal.librus.pl', 'XSRF-TOKEN', 'portal-xsrf');

      // The app then re-visits api.librus.pl for a token refresh — its
      // original session cookie must be untouched by the synergia hop.
      expect(jar.forDomain('api.librus.pl')['DZIENNIKSID'], 'api-session');
      expect(jar.forDomain('synergia.librus.pl')['DZIENNIKSID'], 'synergia-session');
      expect(jar.forDomain('synergia.librus.pl')['SDZIENNIKSID'], 'synergia-full-session');

      // A request built for plan_lekcji must only carry synergia cookies.
      final planLekcjiHeader = jar.cookieHeaderForUrl('https://synergia.librus.pl/plan_lekcji');
      expect(planLekcjiHeader, contains('DZIENNIKSID=synergia-session'));
      expect(planLekcjiHeader, contains('SDZIENNIKSID=synergia-full-session'));
      expect(planLekcjiHeader, isNot(contains('api-session')));
    });
  });
}
