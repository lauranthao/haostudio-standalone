// ikun disabled (2026-11-19): api.ikunshare.com is dead — curl from
// this VM fails http + https (DNS resolves but connect fails), and
// logcat shows `Failed host lookup: 'api.ikunshare.com'`. Both the
// built-in ikun resolver (music_resolvers.dart, same `enabled: false`
// precedent as huibq / hyw) and the bundled ikun LX script (default
// OFF in LxScriptSourcesStore, still visible + re-enableable in
// 音源管理) must stop participating in resolution.
//
// - resolver: ikun reports disabled in listResolvers, is never
//   requested, and the other resolvers still work.
// - script store: ikun is off by default, the user can turn it back
//   on, and toggling it never touches another script.
//
// Run:
//   TMPDIR=$PWD/.tmp flutter test --concurrency=1
//   test/music_ikun_disabled_test.dart

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/lx_script_store.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

import 'lx_fake_dio.dart';

void main() {
  late Directory hiveDir;
  late Box<dynamic> box;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-ikun-disabled-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    box = await Hive.openBox<dynamic>(
      'test_ikun_disabled',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(box);
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    await HiveStore.put('hao_resolver_speed', '');
    await HiveStore.put(HiveKeys.lxScriptDisabled, '');
    await HiveStore.put(HiveKeys.lxScriptExplicitlyEnabled, '');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  MusicResolvers resolversWith(Dio dio) => MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
          dio: dio,
          assetLoader: (_) async => throw StateError('no assets'),
        ),
      );

  group('built-in ikun resolver', () {
    test('listResolvers reports ikun disabled, others untouched', () {
      final r = resolversWith(Dio());
      final byKey = {for (final e in r.listResolvers()) e.key: e};
      expect(byKey['ikun']!.enabled, isFalse);
      // Same precedent, still disabled.
      expect(byKey['huibq']!.enabled, isFalse);
      expect(byKey['hyw']!.enabled, isFalse);
      // The rest of the wy chain is untouched.
      for (final k in [
        'lzm',
        'zddyr',
        'gd',
        'xinghai',
        'oiapi_wy',
        'qjqq',
        'kangqi',
        'yutang',
        'wwwweb',
      ]) {
        expect(byKey[k]!.enabled, isTrue, reason: k);
      }
    });

    test('ikun is never requested even when it alone would answer',
        () async {
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          if (url.contains('api.ikunshare.com')) {
            return {
              'status': 200,
              'body': '{"code":200,"url":"https://cdn.example.com/m.flac"}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      final r = resolversWith(dio);
      final res = await r.resolvePlayUrl(
        'ikun-only-1',
        MusicPlatform.wy,
        AudioQuality.master,
        'Test',
      );
      expect(res, isNull);
      expect(
        log.any((u) => u.contains('api.ikunshare.com')),
        isFalse,
        reason: 'a disabled resolver must not be asked at all',
      );
    });

    test('other resolvers still serve when ikun is out', () async {
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          if (url.contains('music.lzmhhh.com')) {
            return {
              'status': 200,
              'body': '{"data":"https://example.com/lzm.mp3"}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      final r = resolversWith(dio);
      final res = await r.resolvePlayUrl(
        'ikun-only-2',
        MusicPlatform.wy,
        AudioQuality.hires,
        'Test',
      );
      expect(res, isNotNull);
      expect(res!.via, 'lzm');
      expect(res.url, 'https://example.com/lzm.mp3');
    });
  });

  group('bundled ikun LX script (store default)', () {
    test('ikun is off by default, other scripts are on', () {
      expect(LxScriptSourcesStore.isEnabled('ikun', box: box), isFalse);
      expect(LxScriptSourcesStore.isEnabled('xinlan', box: box), isTrue);
      expect(LxScriptSourcesStore.isEnabled('suyin', box: box), isTrue);
      expect(LxScriptSourcesStore.isEnabled('luoxue', box: box), isTrue);
    });

    test('the user can turn ikun back on, and off again', () async {
      await LxScriptSourcesStore.setEnabled('ikun', true, box: box);
      expect(LxScriptSourcesStore.isEnabled('ikun', box: box), isTrue);
      await LxScriptSourcesStore.setEnabled('ikun', false, box: box);
      expect(LxScriptSourcesStore.isEnabled('ikun', box: box), isFalse);
    });

    test('toggling ikun never touches another script', () async {
      await LxScriptSourcesStore.setEnabled('xinlan', false, box: box);
      expect(LxScriptSourcesStore.isEnabled('xinlan', box: box), isFalse);
      expect(LxScriptSourcesStore.isEnabled('ikun', box: box), isFalse);
      await LxScriptSourcesStore.setEnabled('ikun', true, box: box);
      expect(LxScriptSourcesStore.isEnabled('ikun', box: box), isTrue);
      expect(LxScriptSourcesStore.isEnabled('xinlan', box: box), isFalse);
    });
  });
}
