// Master quality tests (M-P0-6 Part A).
//
// - The 5-tier chain and the master parameter mappings.
// - The Master honesty gate in [extraQuality]: only resolvers with a
//   verified real Master path (ikun direct, zddyr, xinghai, lx:*
//   scripts) may claim Master; every other resolver caps at hires.
// - Resolver behaviour with a fake Dio (no network): zddyr master
//   returns a genuine master URL; ikun direct returns master; a
//   320k-level answer at the master tier does NOT satisfy it — the
//   loop downgrades to hires instead of mislabelling.
// - [lxQualityForScript] picks the right quality string per script.
//
// Note: the live zddyr/xinghai master responses were verified by curl
// on 2026-11-16 (quality:"master", quality_fallback:false, br 4.27M);
// these tests pin the same behaviour with canned responses.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

import 'lx_fake_dio.dart';

void main() {
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
      expect(
        extraQuality('ikun', AudioQuality.master, 'wy'),
        AudioQuality.master,
      );
      expect(
        extraQuality('zddyr', AudioQuality.master, 'wy'),
        AudioQuality.master,
      );
      expect(
        extraQuality('xinghai', AudioQuality.master, 'wy'),
        AudioQuality.master,
      );
      expect(
        extraQuality('lx:ikun', AudioQuality.master, 'wy'),
        AudioQuality.master,
      );
      expect(
        extraQuality('lx:suyin', AudioQuality.master, 'tx'),
        AudioQuality.master,
      );
    });

    test('every other resolver caps at hires at the master tier', () {
      for (final key in [
        'gd',
        'yutang',
        'kangqi',
        'qjqq',
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

    test('ikun direct resolver returns master when zddyr is down', () async {
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
        '1851244158',
        MusicPlatform.wy,
        AudioQuality.master,
        'Test',
      );
      expect(r, isNotNull);
      expect(r!.quality, AudioQuality.master);
      expect(r.via, 'ikun');
      expect(
        log.any(
          (u) =>
              u.contains('api.ikunshare.com') &&
              u.contains('quality=master'),
        ),
        isTrue,
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
        '1851244158',
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
        '1851244158',
        MusicPlatform.wy,
        AudioQuality.master,
        'Test',
      );
      expect(r, isNotNull);
      expect(r!.quality, AudioQuality.hires);
      expect(r.via, 'zddyr');
    });
  });
}
