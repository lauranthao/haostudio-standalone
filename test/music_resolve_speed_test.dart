// Deterministic, no-network speed tests for music resolution.
//
// A fake Dio answers each resolver API with canned JSON after a
// configured delay, so the structural costs (per-job timeout,
// first-playable-wins, dead-source ranking) are measurable without
// real network. The VM's Dart HTTP has no usable internet (egress
// proxy 400s), so real-network timing is impossible here; these
// tests are the evidence instead. Run:
//   TMPDIR=$PWD/.tmp flutter test --concurrency=1
//   test/music_resolve_speed_test.dart
import 'dart:async';
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

const _hiresUrl = 'https://example.com/a.flac';
const _lowUrl = 'https://example.com/b.mp3';

/// Route key for a resolver request: one resolver per host, except
/// xinghai where the token endpoint shares the host with the API.
String _route(Uri u) {
  if (u.host == 'yy1.zddyr.top' && u.path.contains('token.php')) {
    return 'xh-token';
  }
  return u.host;
}

/// Canned bodies per route. Absent route => empty map (fast empty answer).
Map<String, dynamic> _bodyFor(String route) {
  switch (route) {
    case 'api.ikunshare.com':
      return {'code': 200, 'url': _hiresUrl};
    case 'music.lzmhhh.com':
      return {'data': _lowUrl};
    case 'yy.zddyr.top':
      return {'code': 200, 'url': _hiresUrl};
    case 'music-api.gdstudio.xyz':
      return {'url': _hiresUrl};
    case 'xh-token':
      return {
        'data': {'token': 'tok'},
      };
    case 'yy1.zddyr.top':
      return {'code': 200, 'url': _hiresUrl};
    case 'oiapi.net':
      return {
        'code': 0,
        'data': [
          {'url': _hiresUrl},
        ],
      };
    case 'metings.qjqq.cn':
      return {
        'data': {'url': _hiresUrl},
      };
    case 'ncm.kangqiovo.com':
      return {
        'data': {'url': _hiresUrl},
      };
    case 'api.yutangxiaowu.cn':
      return {'url': _hiresUrl};
    case 'c.wwwweb.top':
      return {'code': 200, 'url': _hiresUrl};
    case 'tang.api.s01s.cn':
      // One distinct URL per tier field, so the field selection is
      // observable (see the tang master test below).
      return {
        'song_play_url': 'https://example.com/tang-fallback.mp3',
        'song_play_url_standard': 'https://example.com/tang-standard.mp3',
        'song_play_url_hq': 'https://example.com/tang-hq.mp3',
        'song_play_url_sq': 'https://example.com/tang-sq.flac',
        'song_play_url_pq': 'https://example.com/tang-pq.flac',
      };
    default:
      return <String, dynamic>{};
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-resolve-speed-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  // Fresh ranking state per test: the resolver speeds/fails/cooldowns
  // persist in Hive across resolves, so clear them between tests.
  setUp(() async {
    await HiveStore.put('hao_resolver_speed', '');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  /// Build resolvers whose Dio answers each route after [delaysMs]
  /// (absent route = 0 ms) with the canned body, or with [lowBody]
  /// for lzm (the below-tier first hit in first-wins tests). [bodies]
  /// overrides the canned body per route (e.g. a dead ikun).
  MusicResolvers fakeResolvers(
    Map<String, int> delaysMs, {
    bool lzmLow = false,
    Map<String, Map<String, dynamic>> bodies = const {},
  }) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final route = _route(options.uri);
          final delay = delaysMs[route] ?? 0;
          if (delay > 0) {
            await Future<void>.delayed(Duration(milliseconds: delay));
          }
          var body = bodies[route] ?? _bodyFor(route);
          if (lzmLow && route == 'music.lzmhhh.com') {
            body = {'data': _lowUrl};
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: body,
            ),
          );
        },
      ),
    );
    return MusicResolvers(
      dio: dio,
      scriptEngine: LxScriptEngine(
        dio: dio,
        assetLoader: (_) async => throw StateError('no assets'),
      ),
    );
  }

  Future<(PlayUrlResult?, int)> timedResolve(
    MusicResolvers r,
    String songId,
    AudioQuality q,
  ) async {
    final sw = Stopwatch()..start();
    final res = await r.resolvePlayUrl(songId, MusicPlatform.wy, q, 'test');
    sw.stop();
    return (res, sw.elapsedMilliseconds);
  }

  test('first playable wins: below-tier first hit plays at once (hires)',
      () async {
    // chen 2026-11-17 铁律: the FIRST source that returns a playable
    // URL plays immediately — no hunting for a higher tier. lzm
    // answers a 320k URL in 100 ms; zddyr hangs; the rest answer
    // empty immediately. The resolve must return the 320k URL at
    // ~100 ms, NOT wait for zddyr or any other source.
    // Unique song id: the play-URL cache (1 h Hive TTL) is shared
    // across tests in this file, so ids must not repeat.
    final r = fakeResolvers(const {'yy.zddyr.top': 5000}, lzmLow: true);
    final (res, ms) = await timedResolve(r, '10001', AudioQuality.hires);
    // ignore: avoid_print
    print('SPEED first-wins-hires ms=$ms result=${res?.via}/${res?.quality.code}');
    expect(res, isNotNull, reason: 'a playable URL was found at 100 ms');
    expect(res!.url, _lowUrl);
    expect(res.quality, AudioQuality.q320k,
        reason: 'per-song downgrade: the 320k URL plays now, labelled 320k');
    // No hunt: the resolve ends the moment the first playable URL
    // arrives (~100 ms). Before the iron law it waited out a hunt
    // window (~350-600 ms) for a better tier that might never come.
    expect(ms, lessThan(300));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('first playable wins: below-target at master plays at once',
      () async {
    // ikun is dead in the real world (empty replies); simulate that,
    // otherwise the fake ikun answers master instantly. lzm answers
    // a URL at once (labelled hires at the master tier); zddyr WOULD
    // answer a real master URL if asked (its canned body, 0 ms) — the
    // resolve must NOT ask it. The result is lzm's hires URL, a
    // per-song downgrade, and the Master tier is retried next song.
    final r = fakeResolvers(
      const {},
      lzmLow: true,
      bodies: const {
        'api.ikunshare.com': <String, dynamic>{},
      },
    );
    final (res, ms) = await timedResolve(r, '10002', AudioQuality.master);
    // ignore: avoid_print
    print('SPEED first-wins-master ms=$ms result=${res?.via}/${res?.quality.code}');
    expect(res, isNotNull);
    expect(res!.via, 'lzm',
        reason: 'zddyr has a master URL but must never be asked');
    expect(res.quality, AudioQuality.hires,
        reason: 'per-song downgrade to hires, labelled honestly');
    expect(ms, lessThan(300));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('hangs before the worker: resolve succeeds, next resolve is fast',
      () async {
    // lzm, zddyr, gd all hang; xinghai answers in 300 ms. A resolve
    // that burns its whole budget on hangs must still find the worker,
    // and the NEXT resolve must not retry the dead sources first.
    final r = fakeResolvers(const {
      'music.lzmhhh.com': 5000,
      'yy.zddyr.top': 5000,
      'music-api.gdstudio.xyz': 5000,
      'yy1.zddyr.top': 300,
      'xh-token': 0,
    });
    final (res1, ms1) = await timedResolve(r, '10003', AudioQuality.hires);
    // ignore: avoid_print
    print('SPEED hang-first ms=$ms1 result=${res1?.via}');
    expect(res1, isNotNull,
        reason: 'xinghai answers; the resolve must not give up on hangs');
    // Let the persisted speed/cool state land before the next resolve.
    await Future<void>.delayed(const Duration(milliseconds: 100));
    final r2 = fakeResolvers(const {
      'music.lzmhhh.com': 5000,
      'yy.zddyr.top': 5000,
      'music-api.gdstudio.xyz': 5000,
      'yy1.zddyr.top': 300,
      'xh-token': 0,
    });
    final (res2, ms2) =
        await timedResolve(r2, '10004', AudioQuality.hires);
    // ignore: avoid_print
    print('SPEED hang-second ms=$ms2 result=${res2?.via}');
    expect(res2, isNotNull);
    // Before fix: dead sources are retried first again -> ~8 s NULL.
    // After: they are cooled -> xinghai first -> ~300 ms.
    expect(ms2, lessThan(2000));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('first source empty: ask the next source', () async {
    // chen 2026-11-17 铁律, second half: only when a source returns
    // NOTHING do you ask the next one. lzm (fastest here) answers
    // empty; zddyr answers hires in 200 ms; the rest are empty. The
    // resolve must return zddyr's hires URL at ~200 ms — the empty
    // first source costs nothing but its own instant reply.
    final r = fakeResolvers(
      const {'yy.zddyr.top': 200},
      bodies: const {
        'music.lzmhhh.com': <String, dynamic>{},
      },
    );
    final (res, ms) = await timedResolve(r, '40001', AudioQuality.hires);
    // ignore: avoid_print
    print('SPEED first-empty ms=$ms result=${res?.via}/${res?.quality.code}');
    expect(res, isNotNull, reason: 'zddyr has the URL');
    expect(res!.via, 'zddyr');
    expect(res.quality, AudioQuality.hires);
    expect(ms, lessThan(600));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('chain walk: nothing at master, downgrade to hires and re-ask',
      () async {
    // chen 2026-11-17: only when ALL sources return nothing at the
    // target tier do you drop a tier and re-ask. zddyr's API takes
    // quality=master/hires in the query: it has no master for this
    // song, but has hires (200 ms). Every other source answers empty
    // at every tier. The resolve must walk master (all empty) ->
    // hires and return zddyr's hires URL at ~200 ms.
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final route = _route(options.uri);
          if (route == 'yy.zddyr.top' &&
              options.uri.queryParameters['quality'] == 'hires') {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'code': 200, 'url': _hiresUrl},
              ),
            );
            return;
          }
          if (route == 'xh-token') {
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {
                  'data': {'token': 'tok'},
                },
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{},
            ),
          );
        },
      ),
    );
    final r = MusicResolvers(
      dio: dio,
      scriptEngine: LxScriptEngine(
        dio: dio,
        assetLoader: (_) async => throw StateError('no assets'),
      ),
    );
    final (res, ms) = await timedResolve(r, '40002', AudioQuality.master);
    // ignore: avoid_print
    print('SPEED chain-walk ms=$ms result=${res?.via}/${res?.quality.code}');
    expect(res, isNotNull,
        reason: 'zddyr has hires; the chain must reach it');
    expect(res!.via, 'zddyr');
    expect(res.quality, AudioQuality.hires);
    expect(ms, lessThan(600));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('user picks 320k: play 320k, never upgrade on its own', () async {
    // chen 2026-11-17: the target tier is the user's choice and the
    // chain only walks DOWN. Resolving at 320k must return a 320k
    // URL — never a hires/master one — even though the same sources
    // would serve hires if asked at hires.
    final r = fakeResolvers(const {}, lzmLow: true);
    final (res, ms) = await timedResolve(r, '40003', AudioQuality.q320k);
    // ignore: avoid_print
    print('SPEED target-320k ms=$ms result=${res?.via}/${res?.quality.code}');
    expect(res, isNotNull);
    expect(res!.quality, AudioQuality.q320k,
        reason: 'the user asked for 320k; the result must be 320k');
    expect(res.url, _lowUrl);
    expect(ms, lessThan(300));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('fast path: tier-matching first hit returns immediately', () async {
    // gd answers a hires URL in 200 ms (gd's extraQuality IS the
    // requested tier, so it matches at once); everything else is empty.
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final route = _route(options.uri);
          if (route == 'music-api.gdstudio.xyz') {
            await Future<void>.delayed(const Duration(milliseconds: 200));
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: {'url': _hiresUrl},
              ),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{},
            ),
          );
        },
      ),
    );
    final r = MusicResolvers(
      dio: dio,
      scriptEngine: LxScriptEngine(
        dio: dio,
        assetLoader: (_) async => throw StateError('no assets'),
      ),
    );
    final (res, ms) = await timedResolve(r, '10005', AudioQuality.hires);
    // ignore: avoid_print
    print('SPEED fast-path ms=$ms result=${res?.via}/${res?.quality.code}');
    expect(res, isNotNull);
    expect(res!.via, 'GD Studio');
    expect(res.quality, AudioQuality.hires);
    expect(ms, lessThan(1000));
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('tang master serves the top field, labelled hires (not standard)',
      () async {
    // Peripheral audit (chen 2026-11-18): tang's field selection
    // fell through to `song_play_url_standard` at the Master tier
    // while extraQuality labelled the result hires — the lowest
    // tier served under a Hi-Res badge. tang is the only QQ
    // resolver, so a tx resolve can only be served by it. Master
    // must take the top field (`song_play_url_pq`, i.e. hires).
    // Unique song ids: the play-URL cache is shared across tests.
    const tiers = <(AudioQuality, String, AudioQuality)>[
      (
        AudioQuality.master,
        'https://example.com/tang-pq.flac',
        AudioQuality.hires,
      ),
      (
        AudioQuality.hires,
        'https://example.com/tang-pq.flac',
        AudioQuality.hires,
      ),
      (
        AudioQuality.lossless,
        'https://example.com/tang-sq.flac',
        AudioQuality.lossless,
      ),
      (
        AudioQuality.q320k,
        'https://example.com/tang-hq.mp3',
        AudioQuality.q320k,
      ),
      (
        AudioQuality.q128k,
        'https://example.com/tang-standard.mp3',
        AudioQuality.q128k,
      ),
    ];
    final r = fakeResolvers(const {});
    var n = 0;
    for (final (q, url, labelled) in tiers) {
      final res = await r.resolvePlayUrl(
        'tang-$n',
        MusicPlatform.tx,
        q,
        'test',
      );
      n++;
      expect(res, isNotNull, reason: 'tang serves $q');
      expect(res!.via, 'tang');
      expect(res.url, url, reason: 'tang field for $q');
      expect(res.quality, labelled, reason: 'tang $q labelled honestly');
    }
  }, timeout: const Timeout(Duration(seconds: 120)));
}
