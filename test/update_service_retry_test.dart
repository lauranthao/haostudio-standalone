import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/update_service.dart';

/// Update check resilience (Gitee primary, 2026-11-19): a transient
/// failure on the primary must be retried before giving up — the old
/// code retried only timeout/network, so one Railway 502 failed the
/// whole check even though the next attempt would have succeeded.
/// Tests run against local HttpServers (no network dependency).

const _manifest = {
  'version': '1.1.4',
  'build': 16,
  'size': 123456,
  'ipaUrl': 'https://example.com/HAoStudio-standalone-v1.1.4.ipa',
  'changelog': {'zh': 'x', 'tw': 'x', 'en': 'x'},
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

Dio _testDio() => Dio(
      BaseOptions(
        connectTimeout: const Duration(seconds: 5),
        receiveTimeout: const Duration(seconds: 5),
        validateStatus: (_) => true,
      ),
    );

void main() {
  test('primary 502 then 200: retry succeeds, no fallback needed', () async {
    var hits = 0;
    final server = await _server((req) async {
      hits++;
      if (hits == 1) {
        req.response.statusCode = 502;
        await req.response.close();
        return;
      }
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(_manifest));
      await req.response.close();
    });
    addTearDown(server.close);
    final svc = UpdateService(
      dio: _testDio(),
      versionUrl: 'http://127.0.0.1:${server.port}/version.json',
      fallbackUrl: 'http://127.0.0.1:${server.port}/never-called',
    );
    final (info, error, status) = await svc.fetchRemote();
    expect(error, isNull);
    expect(status, 200);
    expect(info, isNotNull);
    expect(info!.version, '1.1.4');
    expect(info.build, 16);
    expect(hits, 2);
  });

  test('primary always 502: falls back to the second host', () async {
    final primary = await _server((req) async {
      req.response.statusCode = 502;
      await req.response.close();
    });
    final fallback = await _server((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(_manifest));
      await req.response.close();
    });
    addTearDown(primary.close);
    addTearDown(fallback.close);
    final svc = UpdateService(
      dio: _testDio(),
      versionUrl: 'http://127.0.0.1:${primary.port}/version.json',
      fallbackUrl: 'http://127.0.0.1:${fallback.port}/version.json',
    );
    final (info, error, _) = await svc.fetchRemote();
    expect(error, isNull);
    expect(info, isNotNull);
    expect(info!.version, '1.1.4');
  });

  test('primary 404 (not transient): no retry, fallback is tried', () async {
    var primaryHits = 0;
    var fallbackHits = 0;
    final primary = await _server((req) async {
      primaryHits++;
      req.response.statusCode = 404;
      await req.response.close();
    });
    final fallback = await _server((req) async {
      fallbackHits++;
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(_manifest));
      await req.response.close();
    });
    addTearDown(primary.close);
    addTearDown(fallback.close);
    final svc = UpdateService(
      dio: _testDio(),
      versionUrl: 'http://127.0.0.1:${primary.port}/version.json',
      fallbackUrl: 'http://127.0.0.1:${fallback.port}/version.json',
    );
    final (info, error, _) = await svc.fetchRemote();
    expect(error, isNull);
    expect(info, isNotNull);
    expect(primaryHits, 1, reason: '4xx is not retried');
    expect(fallbackHits, 1);
  });

  test('both hosts down: reports the primary error', () async {
    final svc = UpdateService(
      dio: _testDio(),
      versionUrl: 'http://127.0.0.1:1/version.json',
      fallbackUrl: 'http://127.0.0.1:1/version.json',
    );
    final (info, error, status) = await svc.fetchRemote();
    expect(info, isNull);
    expect(error, UpdateFetchError.network);
    expect(status, isNull);
  });
}
