// Online-update download flow tests (fix 8, download flow).
//
// - checkManual result classification (newer / up-to-date / skipped /
//   failure) against a stubbed version source — no network.
// - Skip logic: skipping a version makes checkManual return `skipped`
//   for it and not for a different version.
// - The dialog shows version + changelog and all three buttons
//   (下载 / 跳过此版本 / 稍后); 下载 calls the injected URL opener with
//   the IPA URL (the real opener is url_launcher externalApplication),
//   跳过 records the skip, 稍后 just dismisses.
// - The dialog renders under all 4 themes x light/dark.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:standalone/app/consts.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/settings/update_dialog.dart';
import 'package:standalone/services/update_service.dart';

import 'helpers/hive_test_setup.dart';

Map<String, dynamic> _manifest(String version, [int build = 6]) => {
      'version': version,
      'build': build,
      'ipaUrl': 'https://example.com/hao-$version.ipa',
      // Widget tests run as Android by default (flutter_test), and
      // the Android gate reports upToDate for any manifest without an
      // APK — so the classification tests need an apkUrl, or every
      // "newer" case reads as upToDate. The dialog tests below build
      // their UpdateInfo directly (no apkUrl), so they still exercise
      // the iOS download path.
      'apkUrl': 'https://example.com/hao-$version.apk',
      'changelog': '新功能：测试更新日志',
    };

Dio _stubDio(Map<String, dynamic> manifest) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.resolve(
          Response<Map<String, dynamic>>(
            requestOptions: options,
            data: manifest,
            statusCode: 200,
          ),
        );
      },
    ),
  );
  return dio;
}

/// A version newer than the app's own, computed from kAppVersion so
/// these tests keep working after every version bump. The old
/// hard-coded '1.0.5' stubs went stale the moment the app passed
/// 1.0.5 (1.0.5 < 1.0.7 reads as upToDate, not newerAvailable).
String _newerVersion([int steps = 1]) {
  final parts = kAppVersion.split('.').map(int.parse).toList();
  parts[parts.length - 1] += steps;
  return parts.join('.');
}

Dio _failingDio() {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        handler.reject(
          DioException(requestOptions: options, error: 'offline'),
        );
      },
    ),
  );
  return dio;
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init(prefix: 'hao-update-test-');
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  // P1-T1: awaiting box.clear() in setUp hangs every widget test —
  // the clear's disk-write Future never resolves in the fake-async
  // zone. It is ALSO wrong unawaited: box.clear() only clears the
  // in-memory box AFTER `await backend.clear()` resolves, so an
  // unawaited clear lands after the test body's own Hive puts and
  // wipes them (proven by the Skip-logic tests: skipVersion's put
  // vanished before checkManual read it). Delete only the key these
  // tests use: HiveStore.delete applies to memory synchronously
  // (beginTransaction runs before the first await), and no other key
  // in this file needs isolating between tests.
  setUp(() {
    unawaited(HiveStore.delete(HiveKeys.skippedVersion));
  });

  tearDown(() {
    Get.reset();
  });

  group('UpdateService.checkManual classification', () {
    test('newer remote version -> newerAvailable with info', () async {
      final newer = _newerVersion();
      final service = UpdateService(dio: _stubDio(_manifest(newer)));
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
      expect(info?.version, newer);
      expect(info?.ipaUrl, 'https://example.com/hao-$newer.ipa');
      expect(info?.changelog, '新功能：测试更新日志');
    });

    test('same version -> upToDate', () async {
      final service = UpdateService(dio: _stubDio(_manifest(kAppVersion)));
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.upToDate);
      expect(info?.version, kAppVersion);
    });

    test('same version + higher build -> newerAvailable (chen 2026-11-20)',
        () async {
      // The 1.1.5 build-bump bug: the old version-only comparison
      // reported upToDate for every 1.1.5+ build, so the app never
      // offered 1.1.5+20/21/22. A higher build of the same version
      // IS an update.
      final service = UpdateService(
        dio: _stubDio(_manifest(kAppVersion, kAppBuild + 1)),
      );
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
      expect(info?.version, kAppVersion);
      expect(info?.build, kAppBuild + 1);
    });

    test('same version + equal build -> upToDate', () async {
      final service = UpdateService(
        dio: _stubDio(_manifest(kAppVersion, kAppBuild)),
      );
      final (result, _) = await service.checkManual();
      expect(result, UpdateCheckResult.upToDate);
    });

    test('same version + lower build -> upToDate', () async {
      final service = UpdateService(
        dio: _stubDio(_manifest(kAppVersion, kAppBuild - 1)),
      );
      final (result, _) = await service.checkManual();
      expect(result, UpdateCheckResult.upToDate);
    });

    test('older version + higher build -> upToDate', () async {
      // The version decides first: a higher build of an OLDER
      // version is not an update.
      final service = UpdateService(
        dio: _stubDio(_manifest('1.0.3', 99)),
      );
      final (result, _) = await service.checkManual();
      expect(result, UpdateCheckResult.upToDate);
    });

    test('older remote version -> upToDate', () async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.3')));
      final (result, _) = await service.checkManual();
      expect(result, UpdateCheckResult.upToDate);
    });

    test('numeric semver: x.y.10 beats x.y.3', () async {
      // Numeric, not lexicographic: as strings '1.1.10' < '1.1.3'
      // ('1' < '3' in the last segment), but 10 > 3 numerically.
      // Computed from kAppVersion so it survives version bumps —
      // the old hard-coded '1.0.10' went stale the moment the app
      // passed 1.0.10 (it now reads as upToDate, correctly).
      final parts = kAppVersion.split('.').map(int.parse).toList();
      parts[parts.length - 1] =
          parts[parts.length - 1] < 10 ? 10 : parts[parts.length - 1] + 1;
      final remote = parts.join('.');
      final service = UpdateService(dio: _stubDio(_manifest(remote)));
      final (result, _) = await service.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
    });

    test('fetch failure -> unavailable', () async {
      final service = UpdateService(dio: _failingDio());
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.unavailable);
      expect(info, isNull);
    });
  });

  group('Skip logic', () {
    test('skipped version+build -> skipped; other version -> newerAvailable',
        () async {
      final newer = _newerVersion();
      final service = UpdateService(dio: _stubDio(_manifest(newer)));
      // The skip key is the version+build id, not the bare version.
      await service.skipVersion('$newer+6');
      final (skipped, _) = await service.checkManual();
      expect(skipped, UpdateCheckResult.skipped);

      final other = UpdateService(dio: _stubDio(_manifest(_newerVersion(2))));
      final (result, _) = await other.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
    });

    test('skipping one build does not skip the next build', () async {
      final newer = _newerVersion();
      final service = UpdateService(dio: _stubDio(_manifest(newer, 6)));
      await service.skipVersion('$newer+6');
      final (skipped, _) = await service.checkManual();
      expect(skipped, UpdateCheckResult.skipped);

      // Same version, next build: offered again.
      final next = UpdateService(dio: _stubDio(_manifest(newer, 7)));
      final (result, _) = await next.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
    });

    test('old plain-version skip does not block a build', () async {
      // A skip recorded before the id change (bare '1.1.6') never
      // matches a version+build id, so it cannot hide an update.
      final newer = _newerVersion();
      final service = UpdateService(dio: _stubDio(_manifest(newer)));
      await service.skipVersion(newer);
      final (result, _) = await service.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
    });

    test('skipVersion persists the exact version+build id', () async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.5')));
      await service.skipVersion('1.0.5+6');
      expect(
        HiveStore.getString(HiveKeys.skippedVersion, ''),
        '1.0.5+6',
      );
    });
  });

  group('showUpdateDialog', () {
    // The dialog must offer a version NEWER than the app: checkManual
    // classifies anything older as upToDate, so the old hard-coded
    // '1.0.5' made the skip test's final checkManual return upToDate
    // instead of skipped once the app passed 1.0.5 (same staleness
    // _newerVersion was written for above).
    final dialogVersion = _newerVersion();
    final info = UpdateInfo(
      version: dialogVersion,
      build: 6,
      ipaUrl: 'https://example.com/hao-$dialogVersion.ipa',
      changelog: '新功能：测试更新日志',
    );

    Future<void> pumpDialog(
      WidgetTester tester, {
      UpdateUrlOpener? urlOpener,
      required UpdateService service,
    }) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  await showUpdateDialog(
                    context,
                    info,
                    service: service,
                    urlOpener: urlOpener ?? (_) async => true,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await pumpFor(tester, const Duration(milliseconds: 300));
    }

    testWidgets('shows version + changelog and all three buttons',
        (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest(dialogVersion)));
      await pumpDialog(tester, service: service);

      expect(find.text('发现新版本 v$dialogVersion (build 6)'), findsOneWidget);
      expect(find.text('新功能：测试更新日志'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('跳过此版本'), findsOneWidget);
      expect(find.text('稍后'), findsOneWidget);
    });

    testWidgets('下载 opens the IPA URL and returns download',
        (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest(dialogVersion)));
      final opened = <Uri>[];
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
                    info,
                    service: service,
                    urlOpener: (uri) async {
                      opened.add(uri);
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
      await pumpFor(tester, const Duration(milliseconds: 300));
      await tester.tap(find.text('下载'));
      await pumpFor(tester, const Duration(milliseconds: 300));

      expect(opened, [Uri.parse('https://example.com/hao-$dialogVersion.ipa')]);
      expect(action, UpdateDialogAction.download);
      // Dialog dismissed after a successful open.
      expect(find.text('发现新版本 v$dialogVersion (build 6)'), findsNothing);
    });

    testWidgets('下载 failure keeps the dialog open and shows a hint',
        (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest(dialogVersion)));
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: Builder(
              builder: (context) => ElevatedButton(
                onPressed: () async {
                  await showUpdateDialog(
                    context,
                    info,
                    service: service,
                    urlOpener: (_) async => false,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await pumpFor(tester, const Duration(milliseconds: 300));
      await tester.tap(find.text('下载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('无法打开下载链接，请检查网络后重试'), findsOneWidget);
      expect(find.text('发现新版本 v$dialogVersion (build 6)'), findsOneWidget);

      // Close the snackbar before the test ends: Get.snackbar leaves a
      // pending 3 s auto-dismiss timer and an active animation ticker;
      // leaving them behind fails teardown (Overlay disposed with an
      // active ticker) and poisons the next test's pumps with a stale
      // ticker. Pump until it is actually gone — the exit animation
      // outlives a single 500 ms pump.
      Get.closeAllSnackbars();
      for (var i = 0;
          i < 10 &&
              find
                  .text('无法打开下载链接，请检查网络后重试')
                  .evaluate()
                  .isNotEmpty;
          i++) {
        await pumpFor(tester, const Duration(milliseconds: 300));
      }
    });

    testWidgets('跳过此版本 records the skip and returns skipped',
        (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest(dialogVersion)));
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
                    info,
                    service: service,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await pumpFor(tester, const Duration(milliseconds: 300));
      await tester.tap(find.text('跳过此版本'));
      // The dialog pops synchronously on tap now (the skip is
      // recorded in the background), so a bounded pump deterministically
      // closes it and `action` is set — no disk I/O in this path.
      await pumpFor(tester, const Duration(milliseconds: 300));

      expect(action, UpdateDialogAction.skipped);
      // The background Hive write still needs real time to land
      // before the persistence asserts below; pumps alone do not
      // yield real time to disk I/O.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      expect(
        HiveStore.getString(HiveKeys.skippedVersion, ''),
        '$dialogVersion+6',
      );
      // Skipped version is now classified as skipped by checkManual.
      // runAsync: checkManual awaits a Dio fetch guarded by a 30 s
      // .timeout Timer — both live on the fake clock in a widget
      // test, and Dio's event-queue work never progresses without a
      // pump, so awaiting it in the test body hangs forever.
      // (runAsync returns T?, so destructure after a null check.)
      final checked = await tester.runAsync(() => service.checkManual());
      expect(checked?.$1, UpdateCheckResult.skipped);
    });

    testWidgets('稍后 dismisses without recording anything',
        (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest(dialogVersion)));
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
                    info,
                    service: service,
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open'));
      await pumpFor(tester, const Duration(milliseconds: 300));
      await tester.tap(find.text('稍后'));
      await pumpFor(tester, const Duration(milliseconds: 300));

      expect(action, UpdateDialogAction.later);
      expect(HiveStore.getString(HiveKeys.skippedVersion, ''), '');
      expect(find.text('发现新版本 v$dialogVersion (build 6)'), findsNothing);
    });

    testWidgets('renders in all 4 themes x light/dark', (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest(dialogVersion)));
      for (final id in HaoThemeId.values) {
        for (final mode in [ThemeMode.light, ThemeMode.dark]) {
          final pair = HaoThemes.of(id);
          await tester.pumpWidget(
            GetMaterialApp(
              theme: pair.light,
              darkTheme: pair.dark,
              themeMode: mode,
              home: Scaffold(
                body: Builder(
                  builder: (context) => ElevatedButton(
                    onPressed: () async {
                      await showUpdateDialog(
                        context,
                        info,
                        service: service,
                      );
                    },
                    child: const Text('open'),
                  ),
                ),
              ),
            ),
          );
          await tester.tap(find.text('open'));
          await pumpFor(tester, const Duration(milliseconds: 300));
          expect(
            find.text('发现新版本 v$dialogVersion (build 6)'),
            findsOneWidget,
            reason: 'theme $id mode $mode',
          );
          expect(find.text('下载'), findsOneWidget, reason: 'theme $id');
          await tester.tap(find.text('稍后'));
          await pumpFor(tester, const Duration(milliseconds: 300));
        }
      }
    });
  });
}
