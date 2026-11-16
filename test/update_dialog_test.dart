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

Map<String, dynamic> _manifest(String version) => {
      'version': version,
      'build': 6,
      'ipaUrl': 'https://example.com/hao-$version.ipa',
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
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-update-test-');
    // HiveStore.init() goes through path_provider; point it at a temp
    // dir (same pattern as live_quality_line_test.dart).
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

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    await HiveStore.box.clear();
  });

  tearDown(() {
    Get.reset();
  });

  group('UpdateService.checkManual classification', () {
    test('newer remote version -> newerAvailable with info', () async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.5')));
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
      expect(info?.version, '1.0.5');
      expect(info?.ipaUrl, 'https://example.com/hao-1.0.5.ipa');
      expect(info?.changelog, '新功能：测试更新日志');
    });

    test('same version -> upToDate', () async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.4')));
      final (result, info) = await service.checkManual();
      expect(result, UpdateCheckResult.upToDate);
      expect(info?.version, '1.0.4');
    });

    test('older remote version -> upToDate', () async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.3')));
      final (result, _) = await service.checkManual();
      expect(result, UpdateCheckResult.upToDate);
    });

    test('numeric semver: 1.0.10 beats 1.0.9', () async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.10')));
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
    test('skipped version -> skipped; other version -> newerAvailable',
        () async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.5')));
      await service.skipVersion('1.0.5');
      final (skipped, _) = await service.checkManual();
      expect(skipped, UpdateCheckResult.skipped);

      final other = UpdateService(dio: _stubDio(_manifest('1.0.6')));
      final (result, _) = await other.checkManual();
      expect(result, UpdateCheckResult.newerAvailable);
    });

    test('skipVersion persists the exact version string', () async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.5')));
      await service.skipVersion('1.0.5');
      expect(
        HiveStore.getString(HiveKeys.skippedVersion, ''),
        '1.0.5',
      );
    });
  });

  group('showUpdateDialog', () {
    const info = UpdateInfo(
      version: '1.0.5',
      build: 6,
      ipaUrl: 'https://example.com/hao-1.0.5.ipa',
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
      await tester.pumpAndSettle();
    }

    testWidgets('shows version + changelog and all three buttons',
        (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.5')));
      await pumpDialog(tester, service: service);

      expect(find.text('发现新版本 v1.0.5'), findsOneWidget);
      expect(find.text('新功能：测试更新日志'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('跳过此版本'), findsOneWidget);
      expect(find.text('稍后'), findsOneWidget);
    });

    testWidgets('下载 opens the IPA URL and returns download',
        (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.5')));
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pumpAndSettle();

      expect(opened, [Uri.parse('https://example.com/hao-1.0.5.ipa')]);
      expect(action, UpdateDialogAction.download);
      // Dialog dismissed after a successful open.
      expect(find.text('发现新版本 v1.0.5'), findsNothing);
    });

    testWidgets('下载 failure keeps the dialog open and shows a hint',
        (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.5')));
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('下载'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(find.text('无法打开下载链接，请检查网络后重试'), findsOneWidget);
      expect(find.text('发现新版本 v1.0.5'), findsOneWidget);

      // Close the snackbar before the test ends: Get.snackbar leaves a
      // pending 3 s auto-dismiss timer and an active animation ticker;
      // leaving them behind fails teardown ("Timer is still pending")
      // and poisons the next test's pumps with a stale ticker.
      Get.closeAllSnackbars();
      await tester.pumpAndSettle();
    });

    testWidgets('跳过此版本 records the skip and returns skipped',
        (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.5')));
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('跳过此版本'));
      // The dialog pops synchronously on tap now (the skip is
      // recorded in the background), so pumpAndSettle deterministically
      // closes it and `action` is set — no disk I/O in this path.
      await tester.pumpAndSettle();

      expect(action, UpdateDialogAction.skipped);
      // The background Hive write still needs real time to land
      // before the persistence asserts below; pumps alone do not
      // yield real time to disk I/O.
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(seconds: 2));
      });
      expect(
        HiveStore.getString(HiveKeys.skippedVersion, ''),
        '1.0.5',
      );
      // Skipped version is now classified as skipped by checkManual.
      final (result, _) = await service.checkManual();
      expect(result, UpdateCheckResult.skipped);
    });

    testWidgets('稍后 dismisses without recording anything',
        (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.5')));
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
      await tester.pumpAndSettle();
      await tester.tap(find.text('稍后'));
      await tester.pumpAndSettle();

      expect(action, UpdateDialogAction.later);
      expect(HiveStore.getString(HiveKeys.skippedVersion, ''), '');
      expect(find.text('发现新版本 v1.0.5'), findsNothing);
    });

    testWidgets('renders in all 4 themes x light/dark', (tester) async {
      final service = UpdateService(dio: _stubDio(_manifest('1.0.5')));
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
          await tester.pumpAndSettle();
          expect(
            find.text('发现新版本 v1.0.5'),
            findsOneWidget,
            reason: 'theme $id mode $mode',
          );
          expect(find.text('下载'), findsOneWidget, reason: 'theme $id');
          await tester.tap(find.text('稍后'));
          await tester.pumpAndSettle();
        }
      }
    });
  });
}
