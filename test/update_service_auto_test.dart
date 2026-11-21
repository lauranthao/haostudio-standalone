// Automatic update check tests (build 28, D1/D2/D11).
//
// - checkAuto throttle (20 h) + silent branches: no request inside
//   the window, a normal request once expired, all four fetch
//   failures return null without throwing, up-to-date / skipped stay
//   silent.
// - D2: the throttle stamp is written only after the remote manifest
//   was fetched successfully — a failed fetch must not consume the
//   20 h window, so the next cold start retries.
// - D11 (T-gate-1): checkAutoIfEnabled() reads the
//   "启动时自动检查更新" switch first; when off, checkAuto is never
//   called (no request, no stamp write). The manual check
//   (checkManual) is never gated.
// Tests run against local HttpServers / stubbed Dio (no network).
//
// NOTE: no HiveTestSetup here — it initialises
// TestWidgetsFlutterBinding, which mocks HttpClient (every request
// returns 400 and no real request is made), so the local servers
// below would never be hit. Pure Hive.init + HiveStore.setTestBox
// instead (same pattern as favourites_page_test.dart).

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/app/consts.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/update_service.dart';

/// A version newer than the app's own, computed from kAppVersion so
/// these tests keep working after every version bump.
String _newerVersion() {
  final parts = kAppVersion.split('.').map(int.parse).toList();
  parts[parts.length - 1] += 1;
  return parts.join('.');
}

Map<String, dynamic> _manifest(String version, [int build = 1]) => {
      'version': version,
      'build': build,
      'ipaUrl': 'https://example.com/hao-$version-$build.ipa',
      'changelog': 'test changelog',
    };

Future<HttpServer> _server(
  Future<void> Function(HttpRequest req) handler,
) async {
  final server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
  server.listen((req) async {
    try {
      await handler(req);
    } catch (_) {
      try {
        req.response.statusCode = 500;
        await req.response.close();
      } catch (_) {}
    }
  });
  return server;
}

Future<HttpServer> _jsonServer(
  Map<String, dynamic> manifest, {
  void Function()? onHit,
}) async {
  return _server((req) async {
    onHit?.call();
    req.response.headers.contentType = ContentType.json;
    req.response.write(jsonEncode(manifest));
    await req.response.close();
  });
}

Dio _testDio() => Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        validateStatus: (_) => true,
      ),
    );

UpdateService _serviceFor(HttpServer server, {HttpServer? fallbackServer}) {
  final fallback = fallbackServer ?? server;
  return UpdateService(
    dio: _testDio(),
    versionUrl: 'http://127.0.0.1:${server.port}/version.json',
    fallbackUrl: 'http://127.0.0.1:${fallback.port}/version.json',
  );
}

int _stamp() => HiveStore.getInt(HiveKeys.lastUpdateCheckAt, 0);

void main() {
  late Directory hiveDir;
  late Box<dynamic> box;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('hao-update-auto-test-');
    Hive.init(hiveDir.path);
    box = await Hive.openBox<dynamic>(HiveStore.boxName);
    HiveStore.setTestBox(box);
  });

  tearDownAll(() async {
    await box.close();
    await Hive.deleteBoxFromDisk(HiveStore.boxName);
    await hiveDir.delete(recursive: true);
  });

  // Delete only the keys these tests use, so each test starts with
  // no throttle stamp, no skip and no switch value (default on).
  setUp(() async {
    await HiveStore.delete(HiveKeys.lastUpdateCheckAt);
    await HiveStore.delete(HiveKeys.skippedVersion);
    await HiveStore.delete(HiveKeys.autoUpdateCheck);
  });

  group('checkAuto throttle (T-auto-1 / T-auto-2)', () {
    test('T-auto-1: inside the 20 h window no request is sent', () async {
      final now = DateTime.now().millisecondsSinceEpoch;
      await HiveStore.put(HiveKeys.lastUpdateCheckAt, now);
      var hits = 0;
      final server = await _jsonServer(
        _manifest(_newerVersion()),
        onHit: () => hits++,
      );
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAuto();
      expect(info, isNull);
      expect(hits, 0);
      expect(_stamp(), now);
    });

    test('T-auto-2: expired window (21 h) requests normally', () async {
      final oldStamp = DateTime.now().millisecondsSinceEpoch -
          const Duration(hours: 21).inMilliseconds;
      await HiveStore.put(HiveKeys.lastUpdateCheckAt, oldStamp);
      var hits = 0;
      final server = await _jsonServer(
        _manifest(_newerVersion()),
        onHit: () => hits++,
      );
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAuto();
      expect(info, isNotNull);
      expect(info!.version, _newerVersion());
      expect(hits, 1);
      expect(_stamp(), greaterThan(oldStamp));
    });
  });

  group('checkAuto silent failures (T-auto-3, D2)', () {
    test('timeout: null, no throw, stamp not written', () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            handler.reject(
              DioException(
                requestOptions: options,
                type: DioExceptionType.connectionTimeout,
              ),
            );
          },
        ),
      );
      final svc = UpdateService(
        dio: dio,
        versionUrl: 'http://127.0.0.1:9/version.json',
        fallbackUrl: 'http://127.0.0.1:9/version.json',
      );
      final info = await svc.checkAuto();
      expect(info, isNull);
      expect(
        _stamp(),
        0,
        reason: 'a failed fetch must not consume the 20 h window (D2)',
      );
    });

    test('network (both hosts down): null, no throw, stamp not written',
        () async {
      final svc = UpdateService(
        dio: _testDio(),
        versionUrl: 'http://127.0.0.1:1/version.json',
        fallbackUrl: 'http://127.0.0.1:1/version.json',
      );
      final info = await svc.checkAuto();
      expect(info, isNull);
      expect(
        _stamp(),
        0,
        reason: 'a failed fetch must not consume the 20 h window (D2)',
      );
    });

    test('HTTP 5xx on both hosts: null, stamp not written', () async {
      var hits = 0;
      final server = await _server((req) async {
        hits++;
        req.response.statusCode = 502;
        await req.response.close();
      });
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAuto();
      expect(info, isNull);
      // Primary + one transient retry + one fallback attempt.
      expect(hits, 3);
      expect(
        _stamp(),
        0,
        reason: 'a failed fetch must not consume the 20 h window (D2)',
      );
    });

    test('parse failure (missing ipaUrl): null, stamp not written',
        () async {
      var hits = 0;
      final server = await _server((req) async {
        hits++;
        req.response.headers.contentType = ContentType.json;
        req.response.write(jsonEncode({'version': _newerVersion()}));
        await req.response.close();
      });
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAuto();
      expect(info, isNull);
      // Parse is not transient: primary + fallback, no retry.
      expect(hits, 2);
      expect(
        _stamp(),
        0,
        reason: 'a failed fetch must not consume the 20 h window (D2)',
      );
    });
  });

  group('checkAuto silent when nothing new (T-auto-4)', () {
    test('same version + equal build -> null, stamp written', () async {
      final server = await _jsonServer(
        _manifest(kAppVersion, kAppBuild),
      );
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAuto();
      expect(info, isNull);
      expect(_stamp(), greaterThan(0));
    });

    test('same version + lower build -> null, stamp written', () async {
      final server = await _jsonServer(
        _manifest(kAppVersion, kAppBuild - 1),
      );
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAuto();
      expect(info, isNull);
      expect(_stamp(), greaterThan(0));
    });

    test('older version + higher build -> null, stamp written', () async {
      final server = await _jsonServer(_manifest('1.0.3', 99));
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAuto();
      expect(info, isNull);
      expect(_stamp(), greaterThan(0));
    });
  });

  group('checkAuto skipped (T-auto-5)', () {
    test('skipped build silent; next build returns info', () async {
      final newer = _newerVersion();
      await HiveStore.put(HiveKeys.skippedVersion, '$newer+1');
      final first = await _jsonServer(_manifest(newer, 1));
      addTearDown(first.close);
      final skipped = await _serviceFor(first).checkAuto();
      expect(skipped, isNull);
      expect(_stamp(), greaterThan(0));

      // Simulate the window expiring: the first (successful) fetch
      // wrote the stamp, so the second call would be throttled.
      await HiveStore.delete(HiveKeys.lastUpdateCheckAt);
      final next = await _jsonServer(_manifest(newer, 2));
      addTearDown(next.close);
      final info = await _serviceFor(next).checkAuto();
      expect(info, isNotNull);
      expect(info!.version, newer);
      expect(info.build, 2);
    });
  });

  group('checkAuto newer (T-auto-6)', () {
    test('newer version returns info', () async {
      final newer = _newerVersion();
      final server = await _jsonServer(_manifest(newer, 1));
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAuto();
      expect(info, isNotNull);
      expect(info!.version, newer);
      expect(info.build, 1);
      expect(info.ipaUrl, isNotEmpty);
      expect(_stamp(), greaterThan(0));
    });

    test('same version + higher build returns info', () async {
      final server = await _jsonServer(
        _manifest(kAppVersion, kAppBuild + 1),
      );
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAuto();
      expect(info, isNotNull);
      expect(info!.version, kAppVersion);
      expect(info.build, kAppBuild + 1);
      expect(_stamp(), greaterThan(0));
    });
  });

  group('checkAutoIfEnabled gate (T-gate-1, D11)', () {
    test('switch off: checkAuto never runs — no request, no stamp',
        () async {
      await HiveStore.put(HiveKeys.autoUpdateCheck, false);
      var hits = 0;
      final server = await _jsonServer(
        _manifest(_newerVersion()),
        onHit: () => hits++,
      );
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAutoIfEnabled();
      expect(info, isNull);
      expect(hits, 0);
      expect(_stamp(), 0);
    });

    test('switch on (explicit true): delegates to checkAuto', () async {
      await HiveStore.put(HiveKeys.autoUpdateCheck, true);
      var hits = 0;
      final server = await _jsonServer(
        _manifest(_newerVersion()),
        onHit: () => hits++,
      );
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAutoIfEnabled();
      expect(info, isNotNull);
      expect(info!.version, _newerVersion());
      expect(hits, 1);
      expect(_stamp(), greaterThan(0));
    });

    test('switch absent (default on): delegates to checkAuto', () async {
      var hits = 0;
      final server = await _jsonServer(
        _manifest(_newerVersion()),
        onHit: () => hits++,
      );
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAutoIfEnabled();
      expect(info, isNotNull);
      expect(hits, 1);
    });

    test('checkAuto itself ignores the switch (gate lives in '
        'checkAutoIfEnabled only)', () async {
      await HiveStore.put(HiveKeys.autoUpdateCheck, false);
      var hits = 0;
      final server = await _jsonServer(
        _manifest(_newerVersion()),
        onHit: () => hits++,
      );
      addTearDown(server.close);
      final info = await _serviceFor(server).checkAuto();
      expect(info, isNotNull);
      expect(hits, 1);
    });
  });
}
