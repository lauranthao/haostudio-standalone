// APK update dialog tests (Android).
//
// - On Android with an APK URL, 下载 runs the injected APK installer
//   (progress shows on the button) and returns download; the IPA
//   URL opener is never called.
// - On Android without an APK URL, 下载 falls back to the URL opener.
// - Off Android, 下载 opens the IPA URL even when an APK URL exists.
//
// Pump pattern copied from update_dialog_test.dart (GetMaterialApp +
// HaoThemes + a button that opens the dialog). Hive is backed by a
// temp dir; platform is overridden per test.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/settings/update_dialog.dart';
import 'package:standalone/services/update_service.dart';

const _apkInfo = UpdateInfo(
  version: '1.1.6',
  build: 20,
  ipaUrl: 'https://example.com/HAoStudio-standalone-v1.1.6.ipa',
  apkUrl: 'https://example.com/HAoStudio-standalone-v1.1.6.apk',
  apkSize: 123,
  apkVersion: '1.1.6',
  apkBuild: 20,
);

const _iosOnlyInfo = UpdateInfo(
  version: '1.1.6',
  build: 20,
  ipaUrl: 'https://example.com/HAoStudio-standalone-v1.1.6.ipa',
);

Dio _stubDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: options,
            data: const {'version': '1.1.6'},
            statusCode: 200,
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-apk-dialog-test-');
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

  // NOTE: do NOT await the Hive box close here (same note as
  // update_dialog_test.dart — awaiting close() hangs tearDownAll).
  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    await HiveStore.box.clear();
  });

  tearDown(() {
    Get.reset();
  });

  // Platform is set via TargetPlatformVariant.only(...) on each test:
  // its setUp/tearDown run inside the test body, before the binding
  // verifies foundation debug variables. Setting
  // debugDefaultTargetPlatformOverride manually and resetting it in
  // tearDown/addTearDown is too late — both run after the check.

  testWidgets('Android + APK URL: 下载 runs the installer with progress',
      (tester) async {
    final installed = <UpdateInfo>[];
    final completer = Completer<bool>();
    UpdateDialogAction? action;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                action = await showUpdateDialog(
                  context,
                  _apkInfo,
                  service: UpdateService(dio: _stubDio()),
                  apkInstaller: (info, onProgress) async {
                    installed.add(info);
                    onProgress(0.5);
                    return completer.future;
                  },
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    expect(find.text('发现新版本 v1.1.6'), findsOneWidget);

    await tester.tap(find.text('下载'));
    await tester.pump();
    expect(installed, hasLength(1));
    expect(installed.single.apkUrl, _apkInfo.apkUrl);
    expect(find.text('下载中 50%'), findsOneWidget);

    completer.complete(true);
    await tester.pumpAndSettle();
    expect(action, UpdateDialogAction.download);
    expect(find.text('发现新版本 v1.1.6'), findsNothing);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('Android without APK URL: 下载 falls back to the URL opener',
      (tester) async {
    final opened = <Uri>[];
    var installerCalled = false;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                await showUpdateDialog(
                  context,
                  _iosOnlyInfo,
                  service: UpdateService(dio: _stubDio()),
                  urlOpener: (uri) async {
                    opened.add(uri);
                    return true;
                  },
                  apkInstaller: (_, _) async {
                    installerCalled = true;
                    return true;
                  },
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(installerCalled, isFalse);
    expect(opened, [Uri.parse(_iosOnlyInfo.ipaUrl)]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.android));

  testWidgets('iOS with APK URL: 下载 still opens the IPA URL',
      (tester) async {
    final opened = <Uri>[];
    var installerCalled = false;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: Builder(
            builder: (context) => ElevatedButton(
              onPressed: () async {
                await showUpdateDialog(
                  context,
                  _apkInfo,
                  service: UpdateService(dio: _stubDio()),
                  urlOpener: (uri) async {
                    opened.add(uri);
                    return true;
                  },
                  apkInstaller: (_, _) async {
                    installerCalled = true;
                    return true;
                  },
                );
              },
              child: const Text('open'),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('open'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('下载'));
    await tester.pumpAndSettle();
    expect(installerCalled, isFalse);
    expect(opened, [Uri.parse(_apkInfo.ipaUrl)]);
  }, variant: TargetPlatformVariant.only(TargetPlatform.iOS));
}
