// Search-result prewarm tests: the first few visible songs' URLs
// are resolved while the user is still looking, so tapping one
// plays from the cache.
//
// A fake Dio answers gd (the only working resolver here) after a
// per-song delay, so a cold resolve takes ~300 ms and a warmed one
// (cache hit) takes ~0 ms. The prewarm and the "controller" resolver
// are separate MusicResolvers instances: the warmed URL must travel
// through the shared Hive cache, as it does in the app. Run:
//   TMPDIR=$PWD/.tmp flutter test --concurrency=1
//   test/music_search_prewarm_test.dart
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
import 'package:standalone/services/music/search_prewarm.dart';

const _hiresUrl = 'https://example.com/a.flac';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-prewarm-');
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

  /// A Dio where only gd answers (hires, after [delaysMs] per song
  /// id; absent id = 0 ms). Every other resolver answers empty, so a
  /// cold resolve takes the gd delay and a warmed one is a cache hit.
  /// [failIds] answer empty even from gd (a song no source has).
  /// Unique song ids per test: the play-URL cache (1 h Hive TTL) is
  /// shared across tests in this file, so ids must not repeat.
  Dio fakeDio(Map<String, int> delaysMs, {Set<String> failIds = const {}}) {
    final dio = Dio();
    dio.interceptors.add(
      InterceptorsWrapper(
        onRequest: (options, handler) async {
          final id = options.uri.queryParameters['id'] ??
              options.uri.queryParameters['songmid'] ??
              '';
          if (options.uri.host == 'music-api.gdstudio.xyz' &&
              !failIds.contains(id)) {
            final delay = delaysMs[id] ?? 0;
            if (delay > 0) {
              await Future<void>.delayed(Duration(milliseconds: delay));
            }
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
    return dio;
  }

  MusicResolvers resolversFor(Dio dio) => MusicResolvers(
        dio: dio,
        scriptEngine: LxScriptEngine(
          dio: dio,
          assetLoader: (_) async => throw StateError('no assets'),
        ),
      );

  Song song(String id) => Song(songId: id, title: 'song $id');

  /// Resolve with a fresh instance (like the controller's) and return
  /// the milliseconds. A cache hit is ~0 ms; a cold resolve takes
  /// the fake gd delay.
  Future<int> resolveMs(MusicResolvers r, String id) async {
    final sw = Stopwatch()..start();
    final res = await r.resolvePlayUrl(
      id,
      MusicPlatform.wy,
      AudioQuality.hires,
      'song $id',
    );
    sw.stop();
    expect(res, isNotNull, reason: 'song $id must resolve');
    return sw.elapsedMilliseconds;
  }

  test('prewarm warms the first 3 songs, not the 4th', () async {
    final dio = fakeDio(const {
      '30001': 300,
      '30002': 300,
      '30003': 300,
      '30004': 300,
    });
    final prewarm = SearchPrewarm(resolvers: resolversFor(dio));
    prewarm.prewarm([
      song('30001'),
      song('30002'),
      song('30003'),
      song('30004'),
    ]);
    // 3 songs x 300 ms serial = ~900 ms; wait with margin (the Hive
    // cache write is fire-and-forget, so the wait must also cover it).
    await Future<void>.delayed(const Duration(milliseconds: 2000));
    final controller = resolversFor(dio);
    for (final id in ['30001', '30002', '30003']) {
      final ms = await resolveMs(controller, id);
      // ignore: avoid_print
      print('PREWARM warmed $id ms=$ms');
      expect(ms, lessThan(100), reason: '$id should be a cache hit');
    }
    final ms4 = await resolveMs(controller, '30004');
    // ignore: avoid_print
    print('PREWARM unwarmed 30004 ms=$ms4');
    expect(ms4, greaterThanOrEqualTo(200),
        reason: 'the 4th song was not prewarmed');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('a new prewarm abandons the old run', () async {
    // Old run: slow1 (1000 ms) then slow2 (300 ms). New run, started
    // immediately: fast1 (300 ms). The old run must stop before
    // slow2, so slow2 is never warmed; fast1 is warmed; slow1 still
    // lands (it was already in flight when abandoned).
    final dio = fakeDio(const {
      '31001': 1000,
      '31002': 300,
      '31003': 300,
    });
    final prewarm = SearchPrewarm(resolvers: resolversFor(dio));
    prewarm.prewarm([song('31001'), song('31002')]);
    prewarm.prewarm([song('31003')]);
    await Future<void>.delayed(const Duration(milliseconds: 2500));
    final controller = resolversFor(dio);
    final msFast = await resolveMs(controller, '31003');
    // ignore: avoid_print
    print('PREWARM gen-guard fast1 ms=$msFast');
    expect(msFast, lessThan(100), reason: 'fast1 must be warmed');
    final msSlow2 = await resolveMs(controller, '31002');
    // ignore: avoid_print
    print('PREWARM gen-guard slow2 ms=$msSlow2');
    expect(msSlow2, greaterThanOrEqualTo(200),
        reason: 'slow2 must NOT be warmed (old run abandoned)');
    final msSlow1 = await resolveMs(controller, '31001');
    // ignore: avoid_print
    print('PREWARM gen-guard slow1 ms=$msSlow1');
    expect(msSlow1, lessThan(100),
        reason: 'slow1 was in flight when abandoned, so it still lands');
  }, timeout: const Timeout(Duration(seconds: 120)));

  test('a failing song does not break the next song', () async {
    final dio = fakeDio(
      const {'32002': 300},
      failIds: {'32001'},
    );
    final prewarm = SearchPrewarm(resolvers: resolversFor(dio));
    prewarm.prewarm([song('32001'), song('32002')]);
    await Future<void>.delayed(const Duration(milliseconds: 2000));
    final controller = resolversFor(dio);
    final ms = await resolveMs(controller, '32002');
    // ignore: avoid_print
    print('PREWARM failure-tolerant ms=$ms');
    expect(ms, lessThan(100),
        reason: 'the song after a failure must still be warmed');
  }, timeout: const Timeout(Duration(seconds: 120)));
}
