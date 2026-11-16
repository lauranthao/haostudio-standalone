// Shared HTTP client tests — one Dio instance, and cookie parsing
// that survives Expires dates and base64 (`=`-padded) values.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/network/http_client.dart';

void main() {
  test('sharedDio returns the same instance (connection reuse)', () {
    // Was: a fresh Dio per call, so no HTTP connection was ever
    // reused despite the "single instance" doc.
    expect(identical(sharedDio(), sharedDio()), isTrue);
  });

  group('CookieStore.setFromSetCookie', () {
    setUp(CookieStore.clear);

    test('keeps a base64 value containing =', () {
      CookieStore.setFromSetCookie('ttwid=abc==; Path=/; HttpOnly');
      expect(CookieStore.get('ttwid'), 'abc==');
    });

    test('does not split on the comma inside Expires', () {
      CookieStore.setFromSetCookie(
        'session=xyz; Expires=Wed, 21 Oct 2026 07:28:00 GMT; Path=/',
      );
      expect(CookieStore.get('session'), 'xyz');
      // The old split(',') turned the date tail into a junk key.
      expect(CookieStore.get('21 Oct 2026 07:28:00 GMT'), isNull);
    });

    test('parses two cookies joined by a comma', () {
      CookieStore.setFromSetCookie('a=1; Path=/, b=2; Path=/');
      expect(CookieStore.get('a'), '1');
      expect(CookieStore.get('b'), '2');
    });
  });
}
