// Shared HTTP client — one Dio instance for all platform adapters and
// music/video sources. Owned by the coordinator; adapters must NOT create
// their own Dio instances with different timeouts/headers.
//
// Rules carried from the Swift+web app and the Pure Live port:
// - Default timeout 8 s per request; callers needing longer set it per-call.
// - Browser-like User-Agent on HTML scrapes; JSON APIs get Accept:
//   application/json. Platform adapters set their own Referer/Origin
//   per request (see each adapter's request-params).
// - Never throws for HTTP error statuses: callers check statusCode.
// - Cookie jar: none built in — adapters that need cookies (Douyin ttwid,
//   Douyu did/acf_did) manage their own cookie strings via the
//   [CookieStore] helpers below.

import 'package:dio/dio.dart';

/// Browser-like UA used for HTML scrapes (Huya / Kuaishou room pages).
const String kBrowserUserAgent =
    'Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) '
    'AppleWebKit/537.36 (KHTML, like Gecko) '
    'Chrome/126.0.0.0 Safari/537.36';

/// UA used for direct JSON API calls.
const String kApiUserAgent = kBrowserUserAgent;

/// Shared Dio instance. Lazily created, single instance for the app.
///
/// Was: a fresh Dio per call, despite this doc — every adapter and every
/// per-request call site (`douban_service`, `referer_image`, danmaku
/// transports) got its own instance, so no HTTP connection was ever
/// reused and each request paid a new TLS handshake + HttpClient.
/// Now memoized: one instance, connection pooling works.
Dio? _sharedDio;

Dio sharedDio() {
  return _sharedDio ??= Dio(
    BaseOptions(
      connectTimeout: const Duration(seconds: 8),
      receiveTimeout: const Duration(seconds: 8),
      sendTimeout: const Duration(seconds: 8),
      headers: <String, String>{
        'User-Agent': kApiUserAgent,
        'Accept': 'application/json',
      },
      // Callers handle non-2xx themselves; Dio must not throw on 4xx/5xx.
      validateStatus: (_) => true,
    ),
  );
}

/// Minimal in-memory cookie store for adapters that need session cookies
/// (Douyin `ttwid`/`__ac_nonce`/`msToken`, Douyu `did`/`acf_did`).
/// Persisted by the owning adapter through Hive when the platform requires
/// it across launches; this class itself is deliberately not persisted.
class CookieStore {
  CookieStore._();
  static final Map<String, String> _cookies = <String, String>{};

  static void setFromSetCookie(String? setCookieHeader) {
    if (setCookieHeader == null || setCookieHeader.isEmpty) return;
    // Split into individual cookies. A naive split(',') breaks on the
    // comma inside Expires dates ("Expires=Wed, 21 Oct ..."), and
    // `part.split('=')` with `length == 2` silently dropped any value
    // containing '=' (base64-padded values such as `ttwid=abc==`).
    // So: split only on commas that start a new `name=` pair, and
    // split name/value on the FIRST '='.
    final cookieStrings = <String>[];
    var start = 0;
    for (var i = 0; i < setCookieHeader.length; i++) {
      if (setCookieHeader[i] != ',') continue;
      final rest = setCookieHeader.substring(i + 1);
      if (RegExp(r'^\s*[^=;\s]+\s*=').hasMatch(rest)) {
        cookieStrings.add(setCookieHeader.substring(start, i));
        start = i + 1;
      }
    }
    cookieStrings.add(setCookieHeader.substring(start));
    for (final cookie in cookieStrings) {
      final first = cookie.split(';').first.trim();
      final eq = first.indexOf('=');
      if (eq > 0) {
        _cookies[first.substring(0, eq).trim()] =
            first.substring(eq + 1).trim();
      }
    }
  }

  static void set(String name, String value) => _cookies[name] = value;

  static String? get(String name) => _cookies[name];

  /// `Cookie: a=b; c=d` header value for the given names (all stored
  /// cookies when [names] is null).
  static String header([List<String>? names]) {
    final entries = names == null
        ? _cookies.entries
        : _cookies.entries.where((e) => names.contains(e.key));
    return entries.map((e) => '${e.key}=${e.value}').join('; ');
  }

  static void clear() => _cookies.clear();
}
