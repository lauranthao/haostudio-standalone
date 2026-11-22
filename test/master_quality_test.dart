// Master quality tests (M-P0-6 Part A).
//
// - The 5-tier chain and the master parameter mappings.
// - The Master honesty gate in [extraQuality]: only resolvers with a
//   verified real Master path (zddyr, xinghai) may claim Master;
//   every other resolver caps at hires.
// - Resolver behaviour with a fake Dio (no network): zddyr master
//   returns a genuine master URL; a 320k-level answer at the master
//   tier does NOT satisfy it — the loop downgrades to hires instead
//   of mislabelling. (2026-11-23: ikun direct deleted — API dead.)
// - [lxQualityForScript] picks the right quality string per script.
//
// Note: the live zddyr/xinghai master responses were verified by curl
// on 2026-11-16 (quality:"master", quality_fallback:false, br 4.27M);
// these tests pin the same behaviour with canned responses.

import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

import 'lx_fake_dio.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-master-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    // Memory-backed box (see live_quality_line_test.dart): file
    // writes inside tests can wedge hive_ce's write lock.
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  group('master chain', () {
    test('five tiers, master first', () {
      expect(
        kQualityChain.map((q) => q.code).toList(),
        ['master', 'hires', 'lossless', '320k', '128k'],
      );
      expect(
        qualityChainFrom(AudioQuality.master).map((q) => q.code).toList(),
        ['master', 'hires', 'lossless', '320k', '128k'],
      );
      expect(
        qualityChainFrom(AudioQuality.hires).map((q) => q.code).toList(),
        ['hires', 'lossless', '320k', '128k'],
      );
      expect(qualityChainFrom(AudioQuality.q128k).length, 1);
    });

    test('codes, labels, badge, rank', () {
      expect(AudioQuality.master.code, 'master');
      expect(AudioQualityX.fromCode('master'), AudioQuality.master);
      expect(AudioQualityX.fromCode('bogus'), AudioQuality.hires);
      expect(AudioQuality.master.label, 'Master');
      expect(AudioQuality.master.badgeLabel, 'Master');
      expect(AudioQuality.master.rank, 5);
      expect(AudioQuality.hires.rank, 4);
    });

    test('parameter mappings ask each API for its best at master', () {
      expect(srcQuality(AudioQuality.master), 'flac');
      expect(songLevel(AudioQuality.master), 'lossless');
      expect(gdBr(AudioQuality.master), 999);
      expect(kwBr(AudioQuality.master), 1);
      expect(lxQuality(AudioQuality.master), 'master');
      expect(wwwwebQuality(AudioQuality.master, 'wy'), 'flac');
      // Non-master mappings unchanged.
      expect(srcQuality(AudioQuality.hires), 'flac');
      expect(songLevel(AudioQuality.q320k), 'exhigh');
      expect(gdBr(AudioQuality.q128k), 128);
    });
  });

  group('extraQuality master gate', () {
    test('verified master paths may claim master', () {
      // (2026-11-23: 'ikun' removed — direct ikun API dead,
      // resolver deleted — so only zddyr / xinghai remain.)
      expect(
        extraQuality('zddyr', AudioQuality.master, 'wy'),
        AudioQuality.master,
      );
      expect(
        extraQuality('xinghai', AudioQuality.master, 'wy'),
        AudioQuality.master,
      );
    });

    test('script URLs cap at hires at the master tier (M-P0-1)', () {
      // A bare-string script URL carries no tier signal: the script
      // only gets a master job because it LISTS 'master', which is
      // a claim, not a verification. Only a map-reported
      // quality: 'master' (via actualQuality) keeps Master — see
      // reportedTierFor and the resolver-level test in
      // b27_music_fixes_test.dart.
      expect(
        extraQuality('lx:suyin', AudioQuality.master, 'tx'),
        AudioQuality.hires,
      );
    });

    test('every other resolver caps at hires at the master tier', () {
      for (final key in [
        'gd',
        'oiapi_kw',
        'tang',
        'zddyr_kw',
        'wwwweb',
        'huibq',
        'lzm',
        'oiapi_wy',
      ]) {
        expect(
          extraQuality(key, AudioQuality.master, 'wy'),
          AudioQuality.hires,
          reason: key,
        );
      }
    });

    test('non-master tiers unchanged', () {
      expect(extraQuality('gd', AudioQuality.hires, 'wy'), AudioQuality.hires);
      expect(
        extraQuality('huibq', AudioQuality.hires, 'wy'),
        AudioQuality.q320k,
      );
      expect(
        extraQuality('wwwweb', AudioQuality.hires, 'wy'),
        AudioQuality.lossless,
      );
      expect(extraQuality('lzm', AudioQuality.hires, 'wy'), AudioQuality.q320k);
    });

    test('script jobs return the requested tier, not 320k', () {
      // A script job only exists when the script declares the tier
      // (scriptJobsFor filters by lxQualityForScript), so its URL IS
      // that tier. Labelling it 320k made the resolver loop hunt for
      // a better URL it already had, and mis-set the quality badge.
      expect(
        extraQuality('lx:fish', AudioQuality.hires, 'wy'),
        AudioQuality.hires,
      );
      expect(
        extraQuality('lx:suyin', AudioQuality.lossless, 'tx'),
        AudioQuality.lossless,
      );
      expect(
        extraQuality('lx:feichangdao', AudioQuality.q320k, 'wy'),
        AudioQuality.q320k,
      );
    });
  });

  group('lxQualityForScript', () {
    test('master needs a literal master entry', () {
      expect(
        lxQualityForScript(AudioQuality.master, ['128k', '320k', 'hires']),
        isNull,
      );
      expect(
        lxQualityForScript(
          AudioQuality.master,
          ['128k', '320k', 'flac', 'hires', 'master'],
        ),
        'master',
      );
    });

    test('hires prefers hires, then flac24bit, then flac', () {
      expect(
        lxQualityForScript(
          AudioQuality.hires,
          ['128k', '320k', 'flac24bit', 'hires'],
        ),
        'hires',
      );
      expect(
        lxQualityForScript(AudioQuality.hires, ['128k', 'flac24bit']),
        'flac24bit',
      );
      expect(
        lxQualityForScript(AudioQuality.hires, ['128k', 'flac']),
        'flac',
      );
      expect(lxQualityForScript(AudioQuality.hires, ['128k']), isNull);
    });

    test('lossless prefers flac, then flac24bit; 320k/128k exact', () {
      expect(
        lxQualityForScript(AudioQuality.lossless, ['flac24bit']),
        'flac24bit',
      );
      expect(
        lxQualityForScript(AudioQuality.lossless, ['128k', '320k']),
        isNull,
      );
      expect(
        lxQualityForScript(AudioQuality.q320k, ['128k', '320k']),
        '320k',
      );
      expect(
        lxQualityForScript(AudioQuality.q128k, ['320k']),
        isNull,
      );
    });
  });

  group('resolvePlayUrl at master (fake Dio)', () {
    test('zddyr master returns a genuine master URL', () async {
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          if (url.contains('yy.zddyr.top') &&
              url.contains('quality=master')) {
            return {
              'status': 200,
              'body':
                  '{"code":200,"url":"https://m801.music.126.net/master.flac","quality":"master","quality_fallback":false}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      final resolvers = MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
        dio: dio,
        // No script assets in resolver tests — script jobs are
        // covered by lx_script_engine_test.dart.
        assetLoader: (_) async => throw StateError('no assets'),
      ),
      );
      final r = await resolvers.resolvePlayUrl(
        '1851244158',
        MusicPlatform.wy,
        AudioQuality.master,
        'Test',
      );
      expect(r, isNotNull);
      expect(r!.quality, AudioQuality.master);
      expect(r.url, 'https://m801.music.126.net/master.flac');
      expect(r.via, 'zddyr');
    });

    test('zddyr master answered with a fallback stream is hires (P1-L1)',
        () async {
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          if (url.contains('yy.zddyr.top') &&
              url.contains('quality=master')) {
            return {
              'status': 200,
              'body':
                  '{"code":200,"url":"https://m801.music.126.net/fallback.flac","quality":"hires","quality_fallback":true}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      final resolvers = MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
        dio: dio,
        assetLoader: (_) async => throw StateError('no assets'),
      ),
      );
      final r = await resolvers.resolvePlayUrl(
        '1851244162',
        MusicPlatform.wy,
        AudioQuality.master,
        'Test',
      );
      expect(r, isNotNull);
      // The API served a fallback stream: labelled hires, never master.
      expect(r!.quality, AudioQuality.hires);
      expect(r.url, 'https://m801.music.126.net/fallback.flac');
      expect(r.via, 'zddyr');
    });

    test('zddyr master answered with quality hires is hires (P1-L1)',
        () async {
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          if (url.contains('yy.zddyr.top') &&
              url.contains('quality=master')) {
            return {
              'status': 200,
              'body':
                  '{"code":200,"url":"https://m801.music.126.net/h.flac","quality":"hires"}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      final resolvers = MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
        dio: dio,
        assetLoader: (_) async => throw StateError('no assets'),
      ),
      );
      final r = await resolvers.resolvePlayUrl(
        '1851244163',
        MusicPlatform.wy,
        AudioQuality.master,
        'Test',
      );
      expect(r, isNotNull);
      expect(r!.quality, AudioQuality.hires);
      expect(r.url, 'https://m801.music.126.net/h.flac');
      expect(r.via, 'zddyr');
    });

    test('xinghai master answered with a fallback stream is hires (P1-L1)',
        () async {
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          if (url.contains('token.php')) {
            return {
              'status': 200,
              'body': '{"data":{"token":"tk-test"}}',
            };
          }
          if (url.contains('yy1.zddyr.top') &&
              url.contains('quality=master')) {
            return {
              'status': 200,
              'body':
                  '{"code":200,"url":"https://m801.music.126.net/xh.flac","quality":"master","quality_fallback":true}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      final resolvers = MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
        dio: dio,
        assetLoader: (_) async => throw StateError('no assets'),
      ),
      );
      final r = await resolvers.resolvePlayUrl(
        '1851244164',
        MusicPlatform.wy,
        AudioQuality.master,
        'Test',
      );
      expect(r, isNotNull);
      // quality says master but the fallback flag is set: hires.
      expect(r!.quality, AudioQuality.hires);
      expect(r.url, 'https://m801.music.126.net/xh.flac');
      expect(r.via, '星海');
    });

    test('ikun direct resolver is deleted: not listed, never requested (2026-11-23)', () async {
      // api.ikunshare.com is dead (curl-verified 2026-11-19, logcat
      // Failed host lookup; re-verified dead 2026-11-23) — the ikun
      // resolver was DELETED, so even with a fake ikun API answering,
      // it must never be asked and the resolve returns null here
      // (every other resolver 404s in this fake dio). Master still
      // comes from zddyr/xinghai when they answer (see the test
      // above).
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          if (url.contains('api.ikunshare.com') &&
              url.contains('quality=master')) {
            return {
              'status': 200,
              'body':
                  '{"code":200,"url":"https://cdn.example.com/m.flac"}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      final resolvers = MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
        dio: dio,
        // No script assets in resolver tests — script jobs are
        // covered by lx_script_engine_test.dart.
        assetLoader: (_) async => throw StateError('no assets'),
      ),
      );
      final r = await resolvers.resolvePlayUrl(
        '1851244159',
        MusicPlatform.wy,
        AudioQuality.master,
        'Test',
      );
      expect(r, isNull);
      expect(
        log.any((u) => u.contains('api.ikunshare.com')),
        isFalse,
      );
      expect(
        resolvers.listResolvers().any((e) => e.key == 'ikun'),
        isFalse,
      );
    });

    test('master falls back to hires when no master URL exists', () async {
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          if (url.contains('yy.zddyr.top') &&
              url.contains('quality=hires')) {
            return {
              'status': 200,
              'body':
                  '{"code":200,"url":"https://m701.music.126.net/hires.flac"}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      final resolvers = MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
        dio: dio,
        // No script assets in resolver tests — script jobs are
        // covered by lx_script_engine_test.dart.
        assetLoader: (_) async => throw StateError('no assets'),
      ),
      );
      final r = await resolvers.resolvePlayUrl(
        '1851244160',
        MusicPlatform.wy,
        AudioQuality.master,
        'Test',
      );
      expect(r, isNotNull);
      // Badge honesty: the tier actually played is hires, not master.
      expect(r!.quality, AudioQuality.hires);
      expect(r.url, 'https://m701.music.126.net/hires.flac');
    });

    test('a 320k answer at the master tier does not satisfy it', () async {
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          // huibq answers at the master tier — but its extraQuality
          // caps at 320k, so the gate must drop it and downgrade.
          if (url.contains('lxmusicapi.onrender.com')) {
            return {
              'status': 200,
              'body': '{"url":"https://x/huibq.flac"}',
            };
          }
          if (url.contains('yy.zddyr.top') &&
              url.contains('quality=hires')) {
            return {
              'status': 200,
              'body':
                  '{"code":200,"url":"https://m701.music.126.net/hires.flac"}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      final resolvers = MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
        dio: dio,
        // No script assets in resolver tests — script jobs are
        // covered by lx_script_engine_test.dart.
        assetLoader: (_) async => throw StateError('no assets'),
      ),
      );
      final r = await resolvers.resolvePlayUrl(
        '1851244161',
        MusicPlatform.wy,
        AudioQuality.master,
        'Test',
      );
      expect(r, isNotNull);
      expect(r!.quality, AudioQuality.hires);
      expect(r.via, 'zddyr');
    });
  });

  group('oiapi_kw singer check (P1-L5)', () {
    MusicResolvers resolversWithKuwo(String singer) {
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          if (url.contains('oiapi.net/api/Kuwo')) {
            return {
              'status': 200,
              'body':
                  '{"data":{"song":"Test Song","singer":"$singer","album":"Alb","url":"https://cdn.example.com/kw.mp3"}}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      return MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
        dio: dio,
        assetLoader: (_) async => throw StateError('no assets'),
      ),
      );
    }

    test('a same-title hit by another singer is not a result', () async {
      final resolvers = resolversWithKuwo('Wrong Singer');
      final r = await resolvers.resolvePlayUrl(
        'kw-1',
        MusicPlatform.kw,
        AudioQuality.hires,
        'Test Song',
        artist: 'Right Singer',
      );
      // The only hit names the wrong singer: the source yields
      // nothing and the loop finds nothing else either.
      expect(r, isNull);
    });

    test('a singer-matching hit plays', () async {
      final resolvers = resolversWithKuwo('Right Singer');
      final r = await resolvers.resolvePlayUrl(
        'kw-1',
        MusicPlatform.kw,
        AudioQuality.hires,
        'Test Song',
        artist: 'Right Singer',
      );
      expect(r, isNotNull);
      expect(r!.url, 'https://cdn.example.com/kw.mp3');
      expect(r.via, 'oiapi-酷我');
    });

    test('singer match ignores case and spaces', () async {
      final resolvers = resolversWithKuwo('RightSinger');
      final r = await resolvers.resolvePlayUrl(
        'kw-1',
        MusicPlatform.kw,
        AudioQuality.hires,
        'Test Song',
        artist: 'Right Singer',
      );
      expect(r, isNotNull);
      expect(r!.via, 'oiapi-酷我');
    });
  });

  group('LX speed: first URL wins, persistent cache', () {
    test('hires tier: a 320k answer does not wait 1 s', () async {
      // Before the sequential fastest-first fix, hi tiers waited up
      // to 1 s for a "tier-matching" candidate; most resolvers answer
      // at 320k, so every default-quality song paid a 1 s tax. Now
      // jobs are tried one by one in speed order and the first URL
      // wins at once (a 320k fallback is returned after a short hunt).
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          if (url.contains('oiapi.net/api/Music_163')) {
            return {
              'status': 200,
              'body':
                  '{"code":0,"data":[{"url":"https://m801.music.126.net/320k.mp3"}]}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      final resolvers = MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
          dio: dio,
          assetLoader: (_) async => throw StateError('no assets'),
        ),
      );
      final sw = Stopwatch()..start();
      final r = await resolvers.resolvePlayUrl(
        '66285',
        MusicPlatform.wy,
        AudioQuality.hires,
        '葡萄成熟时',
      );
      sw.stop();
      expect(r, isNotNull);
      expect(r!.url, 'https://m801.music.126.net/320k.mp3');
      expect(r.quality, AudioQuality.q320k);
      // Old code: ~1000 ms (below-tier timer). New code: near-instant
      // (sequential, first URL wins at once).
      expect(sw.elapsedMilliseconds, lessThan(900));
    });

    test('resolved URL persists in Hive across instances', () async {
      // LX keeps resolved URLs on disk; a fresh MusicResolvers
      // (new app launch) must hit the Hive cache with no HTTP.
      final log = <String>[];
      final dio = buildFakeDio(
        log: log,
        respond: (url) {
          if (url.contains('oiapi.net/api/Music_163')) {
            return {
              'status': 200,
              'body':
                  '{"code":0,"data":[{"url":"https://m801.music.126.net/320k.mp3"}]}',
            };
          }
          return {'status': 404, 'body': '{}'};
        },
      );
      MusicResolvers make() => MusicResolvers(
            dio: dio,
            scriptEngine: LxScriptEngine(
              dio: dio,
              assetLoader: (_) async => throw StateError('no assets'),
            ),
          );
      final first = await make().resolvePlayUrl(
        '66285-persist',
        MusicPlatform.wy,
        AudioQuality.hires,
        '葡萄成熟时',
      );
      expect(first, isNotNull);
      expect(first!.url, 'https://m801.music.126.net/320k.mp3');
      final callsAfterFirst = log.length;
      expect(callsAfterFirst, greaterThan(0));
      final second = await make().resolvePlayUrl(
        '66285-persist',
        MusicPlatform.wy,
        AudioQuality.hires,
        '葡萄成熟时',
      );
      expect(second, isNotNull);
      expect(second!.url, 'https://m801.music.126.net/320k.mp3');
      expect(log.length, callsAfterFirst);
    });
  });

  group('fastest-first sequential (chen 2026-11-17)', () {
    // 每次解析都用最快的源, 没有想要的资源就换源继续找, 直到找到
    // 能播的为止. Jobs are tried one by one in measured-speed order;
    // a cooled-down (3 consecutive failures) source is sorted last;
    // a source that times out is skipped at later tiers in the same
    // resolve. Speeds are seeded through the same Hive key the
    // resolver persists (hao_resolver_speed).

    Future<void> seedSpeeds(Map<String, Object> speeds) async {
      await HiveStore.put('hao_resolver_speed', jsonEncode(speeds));
    }

    MusicResolvers makeResolvers(Dio dio) => MusicResolvers(
          dio: dio,
          scriptEngine: LxScriptEngine(
            dio: dio,
            assetLoader: (_) async => throw StateError('no assets'),
          ),
        );

    Dio twoSourceDio(List<String> log) => buildFakeDio(
          log: log,
          respond: (url) {
            if (url.contains('yy.zddyr.top')) {
              return {
                'status': 200,
                'body':
                    '{"code":200,"url":"https://m701.music.126.net/zddyr.flac"}',
              };
            }
            if (url.contains('music-api.gdstudio.xyz')) {
              return {
                'status': 200,
                'body': '{"url":"https://m701.music.126.net/gd.flac"}',
              };
            }
            return {'status': 404, 'body': '{}'};
          },
        );

    test('measured-fastest source is tried first (zddyr fast)', () async {
      await seedSpeeds({
        'zddyr': {'avg': 100},
        'gd': {'avg': 3000},
      });
      final log = <String>[];
      final r = await makeResolvers(
        twoSourceDio(log),
      ).resolvePlayUrl('66285-fast-a', MusicPlatform.wy,
          AudioQuality.hires, 'Test');
      expect(r, isNotNull);
      expect(r!.via, 'zddyr');
      expect(r.quality, AudioQuality.hires);
      // The winner matched at once; the slower source was never asked.
      expect(
        log.any((u) => u.contains('music-api.gdstudio.xyz')),
        isFalse,
      );
    });

    test('measured-fastest source is tried first (gd fast)', () async {
      await seedSpeeds({
        'zddyr': {'avg': 3000},
        'gd': {'avg': 100},
      });
      final log = <String>[];
      final r = await makeResolvers(
        twoSourceDio(log),
      ).resolvePlayUrl('66285-fast-b', MusicPlatform.wy,
          AudioQuality.hires, 'Test');
      expect(r, isNotNull);
      expect(r!.via, 'GD Studio');
      expect(r.quality, AudioQuality.hires);
      expect(log.any((u) => u.contains('yy.zddyr.top')), isFalse);
    });

    test('cooled-down fastest source is sorted last', () async {
      await seedSpeeds({
        'zddyr': {
          'avg': 100,
          'fails': 3,
          'cooled': DateTime.now()
              .add(const Duration(minutes: 5))
              .millisecondsSinceEpoch,
        },
        'gd': {'avg': 3000},
      });
      final log = <String>[];
      final r = await makeResolvers(
        twoSourceDio(log),
      ).resolvePlayUrl('66285-cool', MusicPlatform.wy,
          AudioQuality.hires, 'Test');
      expect(r, isNotNull);
      // zddyr is fastest on paper but cooled down, so gd wins.
      expect(r!.via, 'GD Studio');
      expect(log.any((u) => u.contains('yy.zddyr.top')), isFalse);
    });

    test('a hanging source is skipped after its timeout', () async {
      // No seed (clean speeds): declaration order tries zddyr first.
      await seedSpeeds({});
      final log = <String>[];
      final dio = Dio();
      dio.options.validateStatus = (_) => true;
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            final url = options.uri.toString();
            log.add(url);
            if (url.contains('yy.zddyr.top')) {
              // Hangs longer than the 3 s per-job timeout.
              await Future<void>.delayed(const Duration(seconds: 5));
              handler.resolve(
                Response<String>(
                  requestOptions: options,
                  statusCode: 404,
                  data: '{}',
                ),
              );
              return;
            }
            if (url.contains('music-api.gdstudio.xyz')) {
              handler.resolve(
                Response<String>(
                  requestOptions: options,
                  statusCode: 200,
                  data: '{"url":"https://m701.music.126.net/gd.flac"}',
                  headers: Headers.fromMap(
                    {'content-type': ['application/json']},
                  ),
                ),
              );
              return;
            }
            handler.resolve(
              Response<String>(
                requestOptions: options,
                statusCode: 404,
                data: '{}',
              ),
            );
          },
        ),
      );
      final sw = Stopwatch()..start();
      final r = await makeResolvers(dio).resolvePlayUrl(
        '66285-hang',
        MusicPlatform.wy,
        AudioQuality.hires,
        'Test',
      );
      sw.stop();
      expect(r, isNotNull);
      expect(r!.via, 'GD Studio');
      expect(log.any((u) => u.contains('yy.zddyr.top')), isTrue);
      // Proves the 3 s per-job timeout fired instead of waiting out
      // the source's 5 s hang (and the resolve did not stall on it).
      expect(sw.elapsedMilliseconds, greaterThan(2000));
      expect(sw.elapsedMilliseconds, lessThan(4500));
    });
  });

  group('unwrapSearchResult (v1.0.7 search crash follow-up)', () {
    // 裤佬 returns the LX-standard {isEnd, list} object; 溯音/非常刀
    // return a bare list. Both must reach lxSongFromJson — before,
    // the object shape was silently dropped and the 裤佬 leg could
    // never contribute a result.
    test('bare list passes through', () {
      final out = LxScriptEngine.unwrapSearchResult([
        {'id': '1', 'name': 'A'},
        {'id': '2', 'name': 'B'},
        'not-a-map',
      ]);
      expect(out.length, 2);
      expect(out.first['name'], 'A');
    });

    test('{isEnd, list} object unwraps', () {
      final out = LxScriptEngine.unwrapSearchResult({
        'isEnd': true,
        'list': [
          {'id': '1', 'name': 'A'},
        ],
        'total': 1,
      });
      expect(out.length, 1);
      expect(out.first['id'], '1');
    });

    test('anything else is empty, no throw', () {
      expect(LxScriptEngine.unwrapSearchResult(null), isEmpty);
      expect(LxScriptEngine.unwrapSearchResult('nope'), isEmpty);
      expect(LxScriptEngine.unwrapSearchResult({'isEnd': true}), isEmpty);
      expect(LxScriptEngine.unwrapSearchResult({'list': 'nope'}), isEmpty);
    });
  });
}
