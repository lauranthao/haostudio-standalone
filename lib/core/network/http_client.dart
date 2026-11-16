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
Dio sharedDio() {
  final dio = Dio(
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
  return dio;
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
    for (final part in setCookieHeader.split(',')) {
      final kv = part.split(';').first.trim().split('=');
      if (kv.length == 2 && kv[0].isNotEmpty) {
        _cookies[kv[0].trim()] = kv[1].trim();
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
