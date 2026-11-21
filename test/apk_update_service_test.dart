// APK fields in the update manifest + Android classification.
//
// The manifest carries iOS and Android releases side by side
// (version/build/ipaUrl/size + apkUrl/apkSize/apkVersion/apkBuild).
// On Android the check compares the APK version and only offers the
// update when an APK URL is present; an iOS-only manifest reads as
// up to date, never as an IPA download. iOS behaviour is unchanged.
// Per-ABI APKs (P1-A1): the manifest may also carry one URL+size per
// ABI (apkUrlArm64V8a / apkUrlArmeabiV7a / apkUrlX86_64); the updater
// downloads the one matching the device ABI and falls back to the fat
// apkUrl when it is missing or the ABI is unknown.
//
// Runs against stubbed Dio responses (no network); Hive is backed by
// a temp dir (same pattern as update_dialog_test.dart). Platform is
// overridden per test via debugDefaultTargetPlatformOverride.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/app/consts.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/android_abi.dart';
import 'package:standalone/services/update_service.dart';

Map<String, dynamic> manifest({
  String version = '1.1.5',
  int build = 19,
  String? apkUrl = 'https://example.com/HAoStudio-standalone-v1.1.5.apk',
  int? apkSize = 175207173,
  String? apkVersion = '1.1.5',
  int? apkBuild = 19,
  String? apkUrlArm64V8a,
  int? apkSizeArm64V8a,
  String? apkUrlArmeabiV7a,
  int? apkSizeArmeabiV7a,
  String? apkUrlX86_64,
  int? apkSizeX86_64,
}) => {
      'version': version,
      'build': build,
      'size': 20875814,
      'ipaUrl': 'https://example.com/HAoStudio-standalone-v1.1.5.ipa',
      'changelog': 'x',
      'apkUrl': ?apkUrl,
      'apkSize': ?apkSize,
      'apkVersion': ?apkVersion,
      'apkBuild': ?apkBuild,
      'apkUrlArm64V8a': ?apkUrlArm64V8a,
      'apkSizeArm64V8a': ?apkSizeArm64V8a,
      'apkUrlArmeabiV7a': ?apkUrlArmeabiV7a,
      'apkSizeArmeabiV7a': ?apkSizeArmeabiV7a,
      'apkUrlX86_64': ?apkUrlX86_64,
      'apkSizeX86_64': ?apkSizeX86_64,
    };

Dio stubDio(Map<String, dynamic> data) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: options,
            data: data,
            statusCode: 200,
          ),
        );
      },
    ),
  );
  return dio;
}

/// A version newer than the app's own, computed from kAppVersion so
/// this keeps working after every version bump.
String _newerVersion() {
  final parts = kAppVersion.split('.').map(int.parse).toList();
  parts[parts.length - 1] += 1;
  return parts.join('.');
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-apk-update-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
  });

  // NOTE: do NOT await the Hive box close here. Pending Hive writes
  // from fire-and-forget deletes never resolve in the widget-test
  // fake zone, so awaiting close() hangs tearDownAll forever
  // (same note as update_dialog_test.dart).
  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    await HiveStore.box.clear();
  });

  tearDown(() {
    debugDefaultTargetPlatformOverride = null;
    AndroidAbi.resetForTest();
  });

  test('APK fields are parsed from the manifest', () async {
    final service = UpdateService(dio: stubDio(manifest()));
    final (info, error, _) = await service.fetchRemote();
    expect(error, isNull);
    expect(info, isNotNull);
    expect(info!.apkUrl,
        'https://example.com/HAoStudio-standalone-v1.1.5.apk');
    expect(info.apkSize, 175207173);
    expect(info.apkVersion, '1.1.5');
    expect(info.apkBuild, 19);
    // iOS fields are untouched.
    expect(info.version, '1.1.5');
    expect(info.build, 19);
    expect(info.ipaUrl,
        'https://example.com/HAoStudio-standalone-v1.1.5.ipa');
  });

  test('iOS-only manifest parses with null APK fields', () async {
    final service = UpdateService(
      dio: stubDio(
        manifest(apkUrl: null, apkSize: null, apkVersion: null, apkBuild: null),
      ),
    );
    final (info, error, _) = await service.fetchRemote();
    expect(error, isNull);
    expect(info!.apkUrl, isNull);
    expect(info.apkVersion, isNull);
  });

  group('Android classification', () {
    test('newer APK version -> newerAvailable', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final newer = _newerVersion();
      final service = UpdateService(
        dio: stubDio(manifest(version: newer, apkVersion: newer)),
      );
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
      expect(info!.effectiveVersion, newer);
      expect(info.installUrl,
          'https://example.com/HAoStudio-standalone-v1.1.5.apk');
    });

    test('same APK version -> upToDate', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final service = UpdateService(dio: stubDio(manifest()));
      final (result, _) = await service.checkManual();
      expect(result, UpdateCheckResult.upToDate);
    });

    test('iOS-only manifest on Android -> upToDate, never an IPA offer',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final newer = _newerVersion();
      final service = UpdateService(
        dio: stubDio(
          manifest(
            version: newer,
            apkUrl: null,
            apkSize: null,
            apkVersion: null,
            apkBuild: null,
          ),
        ),
      );
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.upToDate);
      expect(info!.installUrl, isNull);
    });

    test('skipped APK release -> skipped; other version -> newerAvailable',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      final newer = _newerVersion();
      final service = UpdateService(
        dio: stubDio(manifest(version: newer, apkVersion: newer)),
      );
      // The dialog records the skip by release id (version+build);
      // skipping one build must not skip the next build.
      final (first, info) = await service.checkManual();
      expect(first, UpdateCheckResult.newerAvailable);
      await service.skipVersion(info!.id);
      final (skipped, _) = await service.checkManual();
      expect(skipped, UpdateCheckResult.skipped);

      // A further version is not the skipped one: it must offer the
      // update (the comparison uses the APK version on Android).
      final parts = _newerVersion().split('.').map(int.parse).toList();
      parts[parts.length - 1] += 1;
      final further = parts.join('.');
      final third = UpdateService(
        dio: stubDio(manifest(version: further, apkVersion: further)),
      );
      final (result, _) = await third.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
    });

    test('same APK version, higher apkBuild -> newerAvailable', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      // The APK build is one above the app's own build; an APK manifest
      // with the same version but a higher APK build is an update (the
      // build-23 fix: the old version-only comparison reported upToDate
      // for every 1.1.5 build bump). Written relative to kAppBuild so it
      // survives the next bump — the old hard-coded 25 went stale the
      // moment the app itself reached build 25.
      final service = UpdateService(
        dio: stubDio(
          manifest(
            version: '1.1.5',
            build: kAppBuild,
            apkVersion: '1.1.5',
            apkBuild: kAppBuild + 1,
          ),
        ),
      );
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
      expect(info!.effectiveBuild, kAppBuild + 1);
      expect(info.id, '1.1.5+${kAppBuild + 1}');
    });
  });

  group('iOS classification (unchanged)', () {
    test('newer shared version -> newerAvailable, installUrl is the IPA',
        () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final newer = _newerVersion();
      final service = UpdateService(
        dio: stubDio(manifest(version: newer, apkVersion: newer)),
      );
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
      expect(info!.effectiveVersion, newer);
      expect(info.installUrl,
          'https://example.com/HAoStudio-standalone-v1.1.5.ipa');
    });

    test('iOS-only manifest still offers the IPA', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      final newer = _newerVersion();
      final service = UpdateService(
        dio: stubDio(
          manifest(
            version: newer,
            apkUrl: null,
            apkSize: null,
            apkVersion: null,
            apkBuild: null,
          ),
        ),
      );
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
      expect(info!.installUrl,
          'https://example.com/HAoStudio-standalone-v1.1.5.ipa');
    });
  });

  group('per-ABI APK selection (P1-A1)', () {
    Map<String, dynamic> splitManifest() => manifest(
          apkUrlArm64V8a:
              'https://example.com/HAoStudio-standalone-v1.1.5-arm64-v8a.apk',
          apkSizeArm64V8a: 66000000,
          apkUrlArmeabiV7a:
              'https://example.com/HAoStudio-standalone-v1.1.5-armeabi-v7a.apk',
          apkSizeArmeabiV7a: 52000000,
          apkUrlX86_64:
              'https://example.com/HAoStudio-standalone-v1.1.5-x86_64.apk',
          apkSizeX86_64: 68000000,
        );

    test('arm64 picks the arm64 URL and size', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidAbi.setTestAbi('arm64-v8a');
      final service = UpdateService(dio: stubDio(splitManifest()));
      final (info, error, _) = await service.fetchRemote();
      expect(error, isNull);
      expect(info!.effectiveApkUrl,
          'https://example.com/HAoStudio-standalone-v1.1.5-arm64-v8a.apk');
      expect(info.effectiveApkSize, 66000000);
    });

    test('x86_64 (emulator) picks the x86_64 URL', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidAbi.setTestAbi('x86_64');
      final service = UpdateService(dio: stubDio(splitManifest()));
      final (info, _, _) = await service.fetchRemote();
      expect(info!.effectiveApkUrl,
          'https://example.com/HAoStudio-standalone-v1.1.5-x86_64.apk');
      expect(info.effectiveApkSize, 68000000);
    });

    test('armeabi-v7a picks the armeabi URL', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidAbi.setTestAbi('armeabi-v7a');
      final service = UpdateService(dio: stubDio(splitManifest()));
      final (info, _, _) = await service.fetchRemote();
      expect(info!.effectiveApkUrl,
          'https://example.com/HAoStudio-standalone-v1.1.5-armeabi-v7a.apk');
      expect(info.effectiveApkSize, 52000000);
    });

    test('unknown ABI falls back to the fat APK', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidAbi.setTestAbi(null);
      final service = UpdateService(dio: stubDio(splitManifest()));
      final (info, _, _) = await service.fetchRemote();
      expect(info!.effectiveApkUrl,
          'https://example.com/HAoStudio-standalone-v1.1.5.apk');
      expect(info.effectiveApkSize, 175207173);
    });

    test('missing per-ABI URL falls back to the fat APK', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidAbi.setTestAbi('arm64-v8a');
      final service = UpdateService(
        dio: stubDio(manifest()), // no per-ABI fields at all
      );
      final (info, _, _) = await service.fetchRemote();
      expect(info!.effectiveApkUrl,
          'https://example.com/HAoStudio-standalone-v1.1.5.apk');
    });

    test('per-ABI-only manifest still offers the update', () async {
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      AndroidAbi.setTestAbi('arm64-v8a');
      final newer = _newerVersion();
      final service = UpdateService(
        dio: stubDio(
          manifest(
            version: newer,
            apkVersion: newer,
            apkUrl: null,
            apkSize: null,
            apkUrlArm64V8a:
                'https://example.com/HAoStudio-standalone-v1.1.5-arm64-v8a.apk',
            apkSizeArm64V8a: 66000000,
          ),
        ),
      );
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
      expect(info!.effectiveApkUrl,
          'https://example.com/HAoStudio-standalone-v1.1.5-arm64-v8a.apk');
    });
  });
}
