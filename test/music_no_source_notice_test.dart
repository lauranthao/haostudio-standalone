// "No source" must mean every available source was tried
// (2026-11-19).
//
// Failure chain (music_player_controller.dart _loadCurrent ->
// _tryAltOrNext -> _giveUpOnSong): a null resolve reported
// '无可用音源' even when the 8 s global / 6 s first-pass budget
// died with jobs still untried — e.g. three 2 s hangs eat the
// whole first pass, so the remaining jobs were never asked, yet
// the notice claimed no source exists (simulator case: Die For
// You tapped, "无可用音源", while another same-name track played).
// Fix: MusicResolvers records [lastResolveTruncated] (true when
// any tier ran out of budget with jobs untried; cooled jobs only
// sort last and disabled ones are not applicable, so neither
// counts as untried), and the controller says '解析超时，未试完
// 所有音源' instead of '无可用音源' in that case. Retry really
// re-tries: the cooldown is a sort-last, never a skip, and the
// trial exclusion is cleared at the top of every _loadCurrent
// (retryCurrent goes through _loadCurrent).
//
// - resolver: all-empty -> null + not truncated; hangs burn the
//   budget -> null + truncated.
// - resolver: a job cooled by 3 failures is still tried on retry.
// - controller: not-truncated -> '无可用音源'; truncated ->
//   '解析超时，未试完所有音源'; retry re-resolves (second call) and
//   attempts the open.
//
// Run:
//   TMPDIR=$PWD/.tmp flutter test --concurrency=1
//   test/music_no_source_notice_test.dart

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

Song _wy(String id, String title, {int dur = 260}) => Song(
      songId: id,
      title: title,
      artist: 'The Weeknd',
      platform: MusicPlatform.wy,
      dur: dur,
    );

/// Dio answering [respond] per URL after [delaysMs] per host.
Dio _delayedDio(
  Map<String, int> delaysMs,
  Map<String, dynamic> Function(String url) respond,
  List<String> log,
) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        final url = options.uri.toString();
        log.add(url);
        final delay = delaysMs[options.uri.host] ?? 0;
        if (delay > 0) {
          await Future<void>.delayed(Duration(milliseconds: delay));
        }
        final r = respond(url);
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: r['status'] as int? ?? 200,
            data: r['body'],
          ),
        );
      },
    ),
  );
  return dio;
}

MusicResolvers _resolvers(Dio dio) => MusicResolvers(
      dio: dio,
      scriptEngine: LxScriptEngine(
        dio: dio,
        assetLoader: (_) async => throw StateError('no assets'),
      ),
    );

class _FakeApi extends MusicApi {
  Song? alt;

  @override
  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album,
  ) async =>
      alt;

  @override
  Future<List<LyricLine>> lyrics(Song song) async => [];
}

/// Resolvers driven by a script, like music_playback_reliability_
/// test.dart: [truncated] is what the real resolver would report
/// in [MusicResolvers.lastResolveTruncated] for this call.
class _ScriptedResolvers extends MusicResolvers {
  _ScriptedResolvers(this.script);

  final FutureOr<PlayUrlResult?> Function() script;
  bool truncated = false;
  int calls = 0;

  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
  }) async {
    calls++;
    lastResolveTruncated = truncated;
    return await script();
  }
}

void main() {
  late Directory hiveDir;
  late Box<dynamic> box;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-no-source-');
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
      'test_no_source',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(box);
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  // Fresh state per test: speeds, cached URLs and MusicStore state
  // all live in the same mem box, so clear it between tests.
  setUp(() async {
    await box.clear();
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  group('resolver: truncation is reported honestly', () {
    test('all sources answer empty -> null, not truncated', () async {
      final log = <String>[];
      final dio = _delayedDio(const {}, (_) {
        return {'status': 404, 'body': '{}'};
      }, log);
      final r = _resolvers(dio);
      final res = await r.resolvePlayUrl(
        'no-source-1',
        MusicPlatform.wy,
        AudioQuality.hires,
        'Test',
      );
      expect(res, isNull);
      expect(r.lastResolveTruncated, isFalse,
          reason: 'every job was tried and answered empty');
    });

    test('hangs burn the budget -> null, truncated', () async {
      // lzm / zddyr / gd hang: each burns the 2 s per-job timeout,
      // so the 6 s first pass dies with the rest untried.
      final log = <String>[];
      final dio = _delayedDio(const {
        'music.lzmhhh.com': 5000,
        'yy.zddyr.top': 5000,
        'music-api.gdstudio.xyz': 5000,
      }, (_) {
        return {'status': 200, 'body': '{}'};
      }, log);
      final r = _resolvers(dio);
      final res = await r.resolvePlayUrl(
        'no-source-2',
        MusicPlatform.wy,
        AudioQuality.hires,
        'Test',
      );
      expect(res, isNull);
      expect(r.lastResolveTruncated, isTrue,
          reason: 'jobs after the hangs were never asked');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a cooled job is still tried on retry', () async {
      final log = <String>[];
      // First three resolves: everything empty, so every job fails
      // 3 times in a row and cools down.
      final emptyDio = _delayedDio(const {}, (_) {
        return {'status': 404, 'body': '{}'};
      }, log);
      final r = _resolvers(emptyDio);
      for (var i = 0; i < 3; i++) {
        expect(
          await r.resolvePlayUrl(
            'no-source-cool-$i',
            MusicPlatform.wy,
            AudioQuality.hires,
            'Test',
          ),
          isNull,
        );
      }
      // Retry with lzm answering: the cooled lzm job must still be
      // tried (cooldown sorts last, never skips).
      final log2 = <String>[];
      final liveDio = _delayedDio(const {}, (url) {
        if (url.contains('music.lzmhhh.com')) {
          return {
            'status': 200,
            'body': '{"data":"https://example.com/retry.mp3"}',
          };
        }
        return {'status': 404, 'body': '{}'};
      }, log2);
      final r2 = MusicResolvers(
        dio: liveDio,
        scriptEngine: LxScriptEngine(
          dio: liveDio,
          assetLoader: (_) async => throw StateError('no assets'),
        ),
      );
      // Same Hive speed state as r (shared test box): lzm is cooled.
      final res = await r2.resolvePlayUrl(
        'no-source-cool-retry',
        MusicPlatform.wy,
        AudioQuality.hires,
        'Test',
      );
      expect(res, isNotNull);
      expect(res!.via, 'lzm');
      expect(res.url, 'https://example.com/retry.mp3');
      expect(log2.any((u) => u.contains('music.lzmhhh.com')), isTrue);
    });
  });

  group('controller: the notice names the real cause', () {
    MusicPlayerController controller(
      _FakeApi api,
      _ScriptedResolvers resolvers,
      Song song,
    ) {
      final c = MusicPlayerController(api: api, resolvers: resolvers);
      c.queue.clear();
      c.queue.addAll([song]);
      c.currentIndex.value = 0;
      return c;
    }

    test('all tried, none has it -> 无可用音源', () async {
      final api = _FakeApi();
      final resolvers = _ScriptedResolvers(() => null)..truncated = false;
      final c = controller(api, resolvers, _wy('no-source-3', 'Die For You'));
      await c.playIndex(0);
      expect(c.lastNotice.value, contains('无可用音源'));
      expect(c.lastNotice.value, contains('Die For You'));
      expect(c.lastNotice.value.contains('解析超时'), isFalse);
    });

    test('budget ran out -> 解析超时，未试完所有音源', () async {
      final api = _FakeApi();
      final resolvers = _ScriptedResolvers(() => null)..truncated = true;
      final c = controller(api, resolvers, _wy('no-source-4', 'Die For You'));
      await c.playIndex(0);
      expect(c.lastNotice.value, contains('解析超时，未试完所有音源'));
      expect(c.lastNotice.value.contains('无可用音源'), isFalse);
    });

    test('retry really re-resolves after a failure', () async {
      final api = _FakeApi();
      var attempt = 0;
      final resolvers = _ScriptedResolvers(() {
        attempt++;
        if (attempt == 1) return null;
        return PlayUrlResult(
          url: 'https://example.com/retry.mp3',
          candidates: ['https://example.com/retry.mp3'],
          quality: AudioQuality.hires,
          via: 'lzm',
        );
      });
      final c = controller(api, resolvers, _wy('no-source-5', 'Die For You'));
      await c.playIndex(0);
      expect(c.loadError.value, isNotNull);
      expect(resolvers.calls, 1);
      // No native players in this harness: the retry's open throws
      // LateError — that throw IS the proof the retry resolved fresh
      // and attempted the open, instead of replaying a dead result.
      Object? thrown;
      try {
        await c.retryCurrent();
      } catch (e) {
        thrown = e;
      }
      expect(thrown, isNotNull);
      expect(thrown.runtimeType.toString(), 'LateError');
      expect(resolvers.calls, 2);
    });
  });
}
