// Windows update check (chen 2026-11-20 "windows单独"): the Windows
// app reads version-windows.json, never the phone manifest, and
// compares/offers the exe fields — never the IPA. Tests run against
// local HttpServers (no network dependency), with
// debugDefaultTargetPlatformOverride standing in for a Windows host
// (this VM is Linux).
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/update_service.dart';

const _windowsManifest = {
  'version': '1.1.5',
  'exeBuild': 25,
  'exeUrl': 'https://example.com/HAoStudio-standalone-v1.1.5-windows.zip',
  'exeSize': 123456789,
  'changelog': {'zh': 'x', 'tw': 'x', 'en': 'x'},
};

const _phoneOnlyManifest = {
  'version': '1.1.5',
  'build': 24,
  'size': 20914770,
  'ipaUrl': 'https://example.com/HAoStudio-standalone-v1.1.5.ipa',
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
  setUp(() {
    debugDefaultTargetPlatformOverride = TargetPlatform.windows;
  });
  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
  });

  test('Windows manifest (exe fields, no ipaUrl) parses and offers the exe',
      () async {
    final server = await _server((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(_windowsManifest));
      await req.response.close();
    });
    addTearDown(server.close);
    final svc = UpdateService(
      dio: _testDio(),
      versionUrl: 'http://127.0.0.1:${server.port}/version-windows.json',
      fallbackUrl: 'http://127.0.0.1:${server.port}/never-called',
    );
    final (info, error, status) = await svc.fetchRemote();
    expect(error, isNull);
    expect(status, 200);
    expect(info, isNotNull);
    expect(info!.effectiveVersion, '1.1.5');
    expect(info.effectiveBuild, 25);
    expect(
      info.installUrl,
      'https://example.com/HAoStudio-standalone-v1.1.5-windows.zip',
    );
    expect(info.id, '1.1.5+25');
  });

  test('phone-only manifest (ipaUrl, no exeUrl) is a parse error on Windows',
      () async {
    final server = await _server((req) async {
      req.response.headers.contentType = ContentType.json;
      req.response.write(jsonEncode(_phoneOnlyManifest));
      await req.response.close();
    });
    addTearDown(server.close);
    final svc = UpdateService(
      dio: _testDio(),
      versionUrl: 'http://127.0.0.1:${server.port}/version-windows.json',
      fallbackUrl: 'http://127.0.0.1:${server.port}/never-called',
    );
    final (info, error, _) = await svc.fetchRemote();
    expect(info, isNull);
    expect(error, UpdateFetchError.parse);
  });

  test('UpdateInfo getters fall back to shared fields without exe fields',
      () {
    const info = UpdateInfo(
      version: '1.1.5',
      build: 24,
      ipaUrl: 'https://example.com/app.ipa',
    );
    expect(info.effectiveVersion, '1.1.5');
    expect(info.effectiveBuild, 24);
    expect(info.installUrl, isNull);
    expect(info.id, '1.1.5+24');
  });
}
