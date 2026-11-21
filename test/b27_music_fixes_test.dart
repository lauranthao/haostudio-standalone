// B27 music fixes — one test per audit item (M-P0-1, M-P0-2,
// M-P1-1/2/3/4/5/6/7/8, M-P2-3, M-P2-7). The controller-level M-P1-4
// test lives in test/music_playback_reliability_test.dart (it needs
// that file's fakes); the M-P2-2 prelude test lives in
// test/lx_script_engine_test.dart (it needs a real JS runtime and is
// skipped on the Linux host, which has no QuickJS native lib).
//
// Run: TMPDIR=$PWD/.tmp flutter test --concurrency=1
//   test/b27_music_fixes_test.dart
import 'dart:async';
import 'dart:convert';
import 'dart:ffi';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/services.dart';
import 'package:flutter_js/flutter_js.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';
import 'package:standalone/services/music/search_prewarm.dart';
import 'package:standalone/services/music/song_search_service.dart';

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

/// Canned bodies per route (copied from music_resolve_speed_test).
/// Absent route => empty map (fast empty answer).
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

/// Every resolver route answering empty (for tests that need a
/// fully-dead world). _bodyFor's tang/ikun/etc. bodies carry URLs,
/// so "no bodies" does NOT mean "no URLs" — a test that wants all
/// sources dead must pass this map.
const Map<String, Map<String, dynamic>> _emptyBodies = {
  'tang.api.s01s.cn': <String, dynamic>{},
  'api.ikunshare.com': <String, dynamic>{},
  'music.lzmhhh.com': <String, dynamic>{},
  'yy.zddyr.top': <String, dynamic>{},
  'music-api.gdstudio.xyz': <String, dynamic>{},
  'xh-token': <String, dynamic>{},
  'yy1.zddyr.top': <String, dynamic>{},
  'oiapi.net': <String, dynamic>{},
  'metings.qjqq.cn': <String, dynamic>{},
  'ncm.kangqiovo.com': <String, dynamic>{},
  'api.yutangxiaowu.cn': <String, dynamic>{},
  'c.wwwweb.top': <String, dynamic>{},
};

/// A Dio that answers every route empty instantly unless [bodies]
/// overrides the body or [delaysMs] adds a delay. A [route] returning
/// a 500 counts as "no answer" for _getJson (null).
Dio _dioWith({
  Map<String, int> delaysMs = const {},
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
          if (options.cancelToken?.isCancelled == true) return;
        }
        handler.resolve(
          Response(
            requestOptions: options,
            statusCode: 200,
            data: bodies[route] ?? _bodyFor(route),
          ),
        );
      },
    ),
  );
  return dio;
}

/// Resolvers with no script engine behind them (all bundled scripts
/// fail to load from the throwing asset loader, exactly like
/// music_resolve_speed_test's fakeResolvers).
MusicResolvers _resolversNoScripts(Dio dio) => MusicResolvers(
      dio: dio,
      scriptEngine: LxScriptEngine(
        dio: dio,
        assetLoader: (_) async => throw StateError('no assets'),
      ),
    );

Song _wySong(String id, String title) => Song(
      songId: id,
      title: title,
      artist: 'A',
      platform: MusicPlatform.wy,
    );

/// Fake script engine for M-P0-1: its jobs return exactly what the
/// test configures — a bare URL with no reported tier, or a URL with
/// a reported tier. [throwKeys] are extra jobs whose fn throws at
/// once (M-P2-3: ten instant errors to trip the 10-attempt throttle).
class _FakeScriptEngine extends LxScriptEngine {
  _FakeScriptEngine({required this.jobs, this.throwKeys = const []});

  final Map<String, ({String url, AudioQuality? actualQuality})> jobs;
  final List<String> throwKeys;

  @override
  Future<void> ensureInitialized() async {}

  @override
  List<
      ({
        String key,
        String name,
        Future<({String url, AudioQuality? actualQuality})> Function({
          CancelToken? cancelToken,
        })
        fn,
      })> scriptJobsFor(
    MusicPlatform platform,
    AudioQuality quality,
    Song song,
  ) {
    return [
      for (final k in throwKeys)
        (
          key: 'lx:$k',
          name: k,
          fn: ({CancelToken? cancelToken}) async =>
              throw LxScriptException('boom $k'),
        ),
      for (final e in jobs.entries)
        (
          key: 'lx:${e.key}',
          name: e.key,
          fn: ({CancelToken? cancelToken}) async => e.value,
        ),
    ];
  }
}

/// Fake JS runtime for M-P1-1b / M-P1-2 (same shape as
/// lx_script_engine_test's _FakeJsRuntime, plus an evaluate counter
/// so a test can prove polling stopped). No native QuickJS is touched:
/// the factory hands these out directly, so these tests run on Linux.
class _CountingJsRuntime extends JavascriptRuntime {
  _CountingJsRuntime({this.initedDelay});

  final Duration? initedDelay;
  final Map<String, Function(dynamic)> _handlers = {};
  var evaluateCalls = 0;
  bool disposed = false;

  @override
  void initChannelFunctions() {}

  @override
  JsEvalResult evaluate(String code, {String? sourceUrl}) {
    evaluateCalls++;
    if (code != kLxPrelude && initedDelay != null) {
      Timer(initedDelay!, () {
        _handlers['LxSend']?.call({
          'event': 'inited',
          'data': {
            'status': true,
            'sources': {
              'wy': {
                'name': 'wy',
                'type': 'music',
                'actions': ['musicUrl'],
                'qualitys': ['128k', '320k'],
              },
            },
          },
        });
      });
    }
    return JsEvalResult('1', null);
  }

  @override
  Future<JsEvalResult> evaluateAsync(String code, {String? sourceUrl}) async =>
      evaluate(code, sourceUrl: sourceUrl);

  @override
  JsEvalResult callFunction(Pointer<NativeType> fn, Pointer<NativeType> obj) =>
      JsEvalResult('null', null);

  @override
  T? convertValue<T>(JsEvalResult jsValue) => null;

  @override
  String jsonStringify(JsEvalResult jsValue) => 'null';

  @override
  int executePendingJob() => 0;

  @override
  void dispose() {
    disposed = true;
  }

  @override
  bool setupBridge(String channelName, Function(dynamic args) fn) {
    _handlers[channelName] = fn;
    return true;
  }

  @override
  String getEngineInstanceId() => 'fake-${identityHashCode(this)}';

  @override
  void setInspectable(bool inspectable) {}
}

/// Fake platform search + fake script legs for M-P1-6 (same shape as
/// music_search_stream_test's fakes).
class _B27FakeApi extends MusicApi {
  _B27FakeApi({required this.delays, required this.results});

  final Map<MusicPlatform, Duration> delays;
  final Map<MusicPlatform, List<Song>> results;

  @override
  Future<List<Song>> searchOne(
    MusicPlatform pf,
    String q, {
    CancelToken? cancelToken,
  }) async {
    await Future<void>.delayed(delays[pf] ?? Duration.zero);
    return List.of(results[pf] ?? const []);
  }
}

class _B27FakeEngine extends LxScriptEngine {
  _B27FakeEngine({
    this.legs = const [],
    this.scriptResults = const {},
    this.scriptDelay = Duration.zero,
  });

  final List<({MusicPlatform pf, String scriptId})> legs;
  final Map<String, List<Map<String, dynamic>>> scriptResults;
  final Duration scriptDelay;

  @override
  Future<void> ensureInitialized() async {}

  @override
  List<({String scriptId, String scriptName})> searchLegsFor(
    MusicPlatform platform,
  ) => [
        for (final l in legs)
          if (l.pf == platform) (scriptId: l.scriptId, scriptName: l.scriptId),
      ];

  @override
  Future<List<Map<String, dynamic>>> search({
    required String scriptId,
    required String platform,
    required String keyword,
    int page = 1,
    int limit = 20,
  }) async {
    await Future<void>.delayed(scriptDelay);
    return scriptResults[scriptId] ?? const [];
  }
}

/// Mock Dio for the NetEase import tests (M-P1-3): a 250-song v6
/// playlist, chunked song/detail, and a 10-track old-endpoint
/// fallback. [chunkFailures] maps chunk index -> how many times that
/// chunk's detail call answers 500 before succeeding; [v6Failures]
/// counts how many v6 calls answer 500.
Dio _wyImportDio({
  Map<int, int> chunkFailures = const {},
  int v6Failures = 0,
}) {
  var v6Calls = 0;
  final chunkCalls = <int, int>{};
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        final uri = options.uri;
        if (uri.host == 'music.163.com' &&
            uri.path == '/api/v6/playlist/detail') {
          v6Calls++;
          if (v6Calls <= v6Failures) {
            handler.resolve(
              Response(requestOptions: options, statusCode: 500, data: null),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'code': 200,
                'playlist': {
                  'name': 'WY',
                  'trackIds': [
                    for (var i = 1; i <= 250; i++) {'id': i},
                  ],
                },
              },
            ),
          );
          return;
        }
        if (uri.host == 'music.163.com' && uri.path.contains('song/detail')) {
          final ids = (jsonDecode(uri.queryParameters['ids'] ?? '[]') as List)
              .map((e) => (e as num).toInt())
              .toList();
          final chunk = (ids.first - 1) ~/ 100;
          chunkCalls[chunk] = (chunkCalls[chunk] ?? 0) + 1;
          if ((chunkCalls[chunk] ?? 0) <= (chunkFailures[chunk] ?? 0)) {
            handler.resolve(
              Response(requestOptions: options, statusCode: 500, data: null),
            );
            return;
          }
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'songs': [
                  for (final id in ids)
                    {
                      'id': id,
                      'name': '歌$id',
                      'ar': [
                        {'name': '歌手$id'},
                      ],
                      'al': {'name': '专辑$id', 'picUrl': ''},
                      'dt': 180000,
                    },
                ],
              },
            ),
          );
          return;
        }
        if (uri.host == 'music.163.com' &&
            uri.path == '/api/playlist/detail') {
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'result': {
                  'name': 'WY-old',
                  'tracks': [
                    for (var i = 1; i <= 10; i++)
                      {
                        'id': i,
                        'name': '旧歌$i',
                        'artists': [
                          {'name': '歌手$i'},
                        ],
                        'album': {'name': '专辑$i', 'picUrl': ''},
                        'duration': 180000,
                      },
                  ],
                },
              },
            ),
          );
          return;
        }
        handler.resolve(
          Response(requestOptions: options, statusCode: 404, data: null),
        );
      },
    ),
  );
  return dio;
}

/// Mock Dio for the Kugou plist tests (M-P1-7): 40 pages x 10 songs,
/// total 400. [pageDelayMs] is the per-page latency; [pageFailures]
/// maps page -> how many times that page answers 500 before
/// succeeding. [onCall] sees every plist request (for the cancel
/// test's call counting); [onConcurrency] sees the live in-flight
/// count after each increment.
Dio _kgPlistDio({
  int pageDelayMs = 300,
  Map<int, int> pageFailures = const {},
  void Function()? onCall,
  void Function(int inFlight)? onConcurrency,
}) {
  final pageCalls = <int, int>{};
  var inFlight = 0;
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) async {
        final uri = options.uri;
        if (uri.host == 'm.kugou.com' && uri.path.contains('/plist/list/')) {
          onCall?.call();
          final page = int.parse(uri.queryParameters['page'] ?? '1');
          pageCalls[page] = (pageCalls[page] ?? 0) + 1;
          inFlight++;
          onConcurrency?.call(inFlight);
          await Future<void>.delayed(Duration(milliseconds: pageDelayMs));
          inFlight--;
          // Cancelled mid-flight: the request future already completed
          // with a cancel error (Dio Future.any); do not resolve late.
          if (options.cancelToken?.isCancelled == true) return;
          if ((pageCalls[page] ?? 0) <= (pageFailures[page] ?? 0)) {
            handler.resolve(
              Response(requestOptions: options, statusCode: 500, data: null),
            );
            return;
          }
          final start = (page - 1) * 10;
          handler.resolve(
            Response(
              requestOptions: options,
              statusCode: 200,
              data: {
                'list': {
                  'list': {
                    'info': [
                      for (var i = 0; i < 10; i++)
                        {
                          'filename': '歌手${start + i} - 歌${start + i}',
                          'hash': 'h${start + i}',
                          'duration': 180,
                        },
                    ],
                    'total': 400,
                  },
                },
              },
            ),
          );
          return;
        }
        // Special-page title fetch: no name, so the import falls back
        // to '酷狗歌单 <id>'.
        handler.resolve(
          Response(requestOptions: options, statusCode: 200, data: ''),
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
    hiveDir = await Directory.systemTemp.createTemp('hao-b27-music-');
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

  // Fresh ranking state per test: speeds/fails/cooldowns persist in
  // Hive across resolves, so clear them between tests. Unique song
  // ids per test: the play-URL cache (1 h Hive TTL) is shared.
  setUp(() async {
    await HiveStore.put('hao_resolver_speed', '');
    await Future<void>.delayed(const Duration(milliseconds: 50));
  });

  group('M-P0-1 script URL quality cap', () {
    test('bare-string script URL caps at hires at the master tier',
        () async {
      final r = MusicResolvers(
        dio: _dioWith(),
        scriptEngine: _FakeScriptEngine(jobs: {
          'fake': (url: 'https://example.com/x.flac', actualQuality: null),
        }),
      );
      final res = await r.resolvePlayUrl(
        'b27-p01-a',
        MusicPlatform.wy,
        AudioQuality.master,
        'test',
      );
      expect(res, isNotNull);
      expect(res!.url, 'https://example.com/x.flac');
      // A bare string carries no tier report: only a map-reported
      // quality: 'master' keeps Master; a bare string caps at hires.
      expect(res.quality, AudioQuality.hires);
    });

    test('map-reported quality master keeps Master', () async {
      final r = MusicResolvers(
        dio: _dioWith(),
        scriptEngine: _FakeScriptEngine(jobs: {
          'fake': (
            url: 'https://example.com/x.flac',
            actualQuality: AudioQuality.master,
          ),
        }),
      );
      final res = await r.resolvePlayUrl(
        'b27-p01-b',
        MusicPlatform.wy,
        AudioQuality.master,
        'test',
      );
      expect(res, isNotNull);
      expect(res!.quality, AudioQuality.master);
    });
  });

  group('M-P0-2 xinghai token warmup', () {
    test('token wait sits outside the 2s job timeout', () async {
      // xh-token takes 3 s; the xinghai API is instant; every other
      // source answers empty instantly. Before the fix the xinghai
      // job burned its 2 s waiting for the token, timed out, and got
      // cooled — the first song after a cold start never played.
      final r = _resolversNoScripts(
        _dioWith(
          delaysMs: const {'xh-token': 3000},
          bodies: const {
            'tang.api.s01s.cn': <String, dynamic>{},
            'music.lzmhhh.com': <String, dynamic>{},
            'yy.zddyr.top': <String, dynamic>{},
            'music-api.gdstudio.xyz': <String, dynamic>{},
          },
        ),
      );
      final sw = Stopwatch()..start();
      final res = await r.resolvePlayUrl(
        'b27-p02-1',
        MusicPlatform.wy,
        AudioQuality.hires,
        'test',
      );
      sw.stop();
      // ignore: avoid_print
      print('B27 P0-2 ms=${sw.elapsedMilliseconds} via=${res?.via}');
      expect(res?.via, '星海');
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(2900));
      expect(sw.elapsedMilliseconds, lessThan(5000));
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final speeds = HiveStore.getString('hao_resolver_speed', '');
      expect(speeds.contains('cooled'), isFalse,
          reason: 'xinghai must not be cooled by its own token wait');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('M-P1-1 per-job cancellation', () {
    test('slow built-in source is cancelled at the 2s job timeout',
        () async {
      var lzmRequests = 0;
      var lzmCancelled = false;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            final route = _route(options.uri);
            if (route == 'music.lzmhhh.com') {
              lzmRequests++;
              await Future<void>.delayed(const Duration(milliseconds: 4000));
              if (options.cancelToken?.isCancelled == true) {
                lzmCancelled = true;
                // The request future already completed with a cancel
                // error (Dio Future.any); do not resolve late.
                return;
              }
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
      final r = _resolversNoScripts(dio);
      final sw = Stopwatch()..start();
      final res = await r.resolvePlayUrl(
        'b27-p11-a',
        MusicPlatform.wy,
        AudioQuality.hires,
        'test',
      );
      sw.stop();
      // ignore: avoid_print
      print('B27 P1-1a ms=${sw.elapsedMilliseconds} lzmRequests=$lzmRequests');
      expect(res, isNull, reason: 'every source is empty or hung');
      expect(sw.elapsedMilliseconds, lessThan(3000),
          reason: 'the resolve must end at the 2 s job timeout, not the 4 s flight');
      expect(lzmRequests, 1);
      // Let the 4 s flight finish and confirm the token was cancelled.
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(lzmCancelled, isTrue);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('script dispatch stops polling when cancelled', () async {
      final runtimes = <_CountingJsRuntime>[];
      final engine = LxScriptEngine(
        dio: Dio(),
        runtimeFactory: () {
          final rt = _CountingJsRuntime(initedDelay: Duration.zero);
          runtimes.add(rt);
          return rt;
        },
        assetLoader: (_) async =>
            '// @name Tiny\n// @version 1.0\nglobalThis.lx = {};',
        initedTimeout: const Duration(seconds: 5),
      );
      await engine.ensureInitialized();
      final scriptId = engine.scripts.firstWhere((s) => s.loaded).id;
      int totalCalls() =>
          runtimes.fold<int>(0, (a, r) => a + r.evaluateCalls);
      final token = CancelToken();
      final song = _wySong('b27-p11-b', 'T');
      final sw = Stopwatch()..start();
      final fut = engine.requestAction(
        scriptId: scriptId,
        action: 'musicUrl',
        source: 'wy',
        info: LxScriptEngine.musicInfoFor(song),
        cancelToken: token,
      );
      await Future<void>.delayed(const Duration(milliseconds: 200));
      token.cancel();
      await expectLater(fut, throwsA(isA<Exception>()));
      sw.stop();
      // ignore: avoid_print
      print('B27 P1-1b cancel ms=${sw.elapsedMilliseconds}');
      expect(sw.elapsedMilliseconds, lessThan(1000),
          reason: 'without the cancel check the poll runs to the 8 s deadline');
      final callsAtThrow = totalCalls();
      expect(callsAtThrow, greaterThan(0));
      await Future<void>.delayed(const Duration(milliseconds: 300));
      expect(totalCalls(), callsAtThrow,
          reason: 'no JS polling after the cancel');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('M-P1-2 batched script init', () {
    test('a never-inited script does not block later scripts', () async {
      var created = 0;
      final engine = LxScriptEngine(
        dio: Dio(),
        runtimeFactory: () {
          final idx = created++;
          // The first four scripts never send `inited`; the rest do
          // at once. Serial init would take 4 x 5 s + the rest.
          return _CountingJsRuntime(
            initedDelay: idx < 4 ? null : Duration.zero,
          );
        },
        assetLoader: (_) async =>
            '// @name Tiny\n// @version 1.0\nglobalThis.lx = {};',
        initedTimeout: const Duration(seconds: 5),
      );
      final sw = Stopwatch()..start();
      await engine.ensureInitialized();
      sw.stop();
      final loaded = engine.scripts.where((s) => s.loaded).length;
      final failed = engine.scripts.where((s) => !s.loaded).length;
      // ignore: avoid_print
      print('B27 P1-2 init ms=${sw.elapsedMilliseconds} loaded=$loaded failed=$failed');
      expect(loaded + failed, kBundledLxScripts.length);
      expect(loaded, kBundledLxScripts.length - 4);
      expect(failed, 4);
      expect(sw.elapsedMilliseconds, lessThan(12000),
          reason: 'serial would be ~20 s (4 x 5 s timeouts first)');
      // The last bundled spec sits behind the four slow ones in the
      // old serial order: it must still be loaded.
      expect(engine.script(kBundledLxScripts.last.id)?.loaded, isTrue);
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('M-P1-3 NetEase playlist import retries', () {
    test('chunk failing once then succeeding imports the full list',
        () async {
      final api = MusicApi(dio: _wyImportDio(chunkFailures: const {1: 1}));
      final r = await api.importWyPlaylist('777');
      expect(r.tracks.length, 250);
      expect(r.missing, 0);
      expect(r.note, '');
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('chunk failing twice reports the missing count and reason',
        () async {
      final api = MusicApi(dio: _wyImportDio(chunkFailures: const {2: 2}));
      final r = await api.importWyPlaylist('777');
      expect(r.tracks.length, 200);
      expect(r.missing, 50);
      expect(r.note, contains('未导入'));
      expect(r.note, contains('第 3 组'));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('v6 answering twice says the fallback may be truncated',
        () async {
      final api = MusicApi(dio: _wyImportDio(v6Failures: 2));
      final r = await api.importWyPlaylist('777');
      expect(r.tracks.length, 10);
      expect(r.note, contains('可能未导全'));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('M-P1-4 tight auto-advance budget (API level)', () {
    test('findAltPlatform gives up at its 2s cap', () async {
      var cancelledSeen = false;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            await Future<void>.delayed(const Duration(milliseconds: 4000));
            if (options.cancelToken?.isCancelled == true) {
              cancelledSeen = true;
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
      final api = MusicApi(dio: dio);
      final sw = Stopwatch()..start();
      final alt = await api.findAltPlatform(
        'T',
        'A',
        MusicPlatform.wy,
        '',
        timeout: const Duration(seconds: 2),
      );
      sw.stop();
      // ignore: avoid_print
      print('B27 P1-4 alt ms=${sw.elapsedMilliseconds}');
      expect(alt, isNull);
      expect(sw.elapsedMilliseconds, lessThan(3000));
      await Future<void>.delayed(const Duration(milliseconds: 2500));
      expect(cancelledSeen, isTrue);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('resolvePlayUrl totalBudget bounds a chain of slow empties',
        () async {
      // Every job answers empty after 1.5 s — under the 2 s per-job
      // timeout, so no single job times out; serially the chain
      // would take 9 x 1.5 s per tier. The 2 s global budget must
      // cut it off.
      final r = _resolversNoScripts(
        _dioWith(
          delaysMs: const {
            'tang.api.s01s.cn': 1500,
            'music.lzmhhh.com': 1500,
            'yy.zddyr.top': 1500,
            'music-api.gdstudio.xyz': 1500,
            'yy1.zddyr.top': 1500,
            'xh-token': 0,
            'oiapi.net': 1500,
            'metings.qjqq.cn': 1500,
            'ncm.kangqiovo.com': 1500,
            'api.yutangxiaowu.cn': 1500,
            'c.wwwweb.top': 1500,
          },
          bodies: const {
            'tang.api.s01s.cn': <String, dynamic>{},
            'music.lzmhhh.com': <String, dynamic>{},
            'yy.zddyr.top': <String, dynamic>{},
            'music-api.gdstudio.xyz': <String, dynamic>{},
            'yy1.zddyr.top': <String, dynamic>{},
            'oiapi.net': <String, dynamic>{},
            'metings.qjqq.cn': <String, dynamic>{},
            'ncm.kangqiovo.com': <String, dynamic>{},
            'api.yutangxiaowu.cn': <String, dynamic>{},
            'c.wwwweb.top': <String, dynamic>{},
          },
        ),
      );
      final sw = Stopwatch()..start();
      final res = await r.resolvePlayUrl(
        'b27-p14-b',
        MusicPlatform.wy,
        AudioQuality.hires,
        'test',
        totalBudget: const Duration(seconds: 2),
      );
      sw.stop();
      // ignore: avoid_print
      print('B27 P1-4 budget ms=${sw.elapsedMilliseconds}');
      expect(res, isNull);
      expect(sw.elapsedMilliseconds, lessThan(3000));
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('M-P1-5 background prewarm never cools', () {
    test('a prewarm timeout leaves the source first in line', () async {
      var lzmDelayMs = 5000;
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            final route = _route(options.uri);
            if (route == 'music.lzmhhh.com' && lzmDelayMs > 0) {
              await Future<void>.delayed(
                Duration(milliseconds: lzmDelayMs),
              );
              if (options.cancelToken?.isCancelled == true) return;
            }
            // The prewarm song is answered by zddyr; the foreground
            // song makes zddyr hang, so lzm (first in line) must win
            // it — unless the prewarm cooled lzm out.
            final isFg = options.uri.toString().contains('b27-p15-fg');
            if (route == 'yy.zddyr.top' && isFg) {
              await Future<void>.delayed(const Duration(milliseconds: 3000));
              if (options.cancelToken?.isCancelled == true) return;
            }
            handler.resolve(
              Response(
                requestOptions: options,
                statusCode: 200,
                data: route == 'music.lzmhhh.com' ||
                        route == 'yy.zddyr.top'
                    ? _bodyFor(route)
                    : <String, dynamic>{},
              ),
            );
          },
        ),
      );
      final r = _resolversNoScripts(dio);
      SearchPrewarm(resolvers: r).prewarm([_wySong('b27-p15-pre', 'Pre')]);
      // Prewarm: lzm times out at 2 s in the background, zddyr
      // answers at once. Give it time to settle.
      await Future<void>.delayed(const Duration(seconds: 3));
      final speeds = HiveStore.getString('hao_resolver_speed', '');
      expect(speeds.contains('cooled'), isFalse,
          reason: 'a background timeout must not cool the source');
      lzmDelayMs = 100;
      final res = await r.resolvePlayUrl(
        'b27-p15-fg',
        MusicPlatform.wy,
        AudioQuality.hires,
        'test',
      );
      expect(res?.via, 'lzm',
          reason: 'lzm was never cooled, so it still answers first');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('M-P1-6 title/artist dedup key', () {
    test('"Song (Live)" platform leg and "song live" script leg dedupe',
        () async {
      final api = _B27FakeApi(
        delays: const {MusicPlatform.wy: Duration.zero},
        results: {
          MusicPlatform.wy: [
            Song(
              songId: 'p1',
              title: 'Song (Live)',
              artist: 'A',
              platform: MusicPlatform.wy,
            ),
          ],
        },
      );
      final engine = _B27FakeEngine(
        legs: const [(pf: MusicPlatform.wy, scriptId: 'lx1')],
        scriptResults: {
          'lx1': [
            {
              'id': 's9',
              'name': 'song live',
              'singer': 'A',
              'albumName': '',
            },
          ],
        },
        scriptDelay: const Duration(milliseconds: 100),
      );
      final service = SongSearchService(api: api, scriptEngine: engine);
      final updates = await service
          .searchAllStream('song live', onlyPlatform: MusicPlatform.wy)
          .toList();
      expect(updates.last.songs.length, 1,
          reason: 'different songIds — only the title/artist key can drop it');
      expect(updates.last.songs.first.title, 'Song (Live)');
    });

    test('script "Song" matches platform "Song (Live)" via the base key',
        () async {
      final api = _B27FakeApi(
        delays: const {MusicPlatform.wy: Duration.zero},
        results: {
          MusicPlatform.wy: [
            Song(
              songId: 'p1',
              title: 'Song (Live)',
              artist: 'A',
              platform: MusicPlatform.wy,
            ),
          ],
        },
      );
      final engine = _B27FakeEngine(
        legs: const [(pf: MusicPlatform.wy, scriptId: 'lx1')],
        scriptResults: {
          'lx1': [
            {'id': 's9', 'name': 'Song', 'singer': 'A', 'albumName': ''},
          ],
        },
        scriptDelay: const Duration(milliseconds: 100),
      );
      final service = SongSearchService(api: api, scriptEngine: engine);
      final updates = await service
          .searchAllStream('Song', onlyPlatform: MusicPlatform.wy)
          .toList();
      expect(updates.last.songs.length, 1);
    });
  });

  group('M-P1-7 Kugou plist import', () {
    test('400 songs import in parallel, 3 pages at a time', () async {
      var maxInFlight = 0;
      final api = MusicApi(
        dio: _kgPlistDio(
          pageDelayMs: 300,
          onConcurrency: (n) {
            if (n > maxInFlight) maxInFlight = n;
          },
        ),
      );
      final sw = Stopwatch()..start();
      final r = await api.importKgPlist('12345');
      sw.stop();
      // ignore: avoid_print
      print('B27 P1-7 ms=${sw.elapsedMilliseconds} maxInFlight=$maxInFlight tracks=${r.tracks.length}');
      expect(r.tracks.length, 400);
      expect(r.missing, 0);
      expect(r.note, '');
      expect(sw.elapsedMilliseconds, lessThan(9000),
          reason: 'serial would be 40 x 300 ms = 12 s');
      expect(maxInFlight, 3);
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('cancelling stops further requests', () async {
      var calls = 0;
      final api = MusicApi(
        dio: _kgPlistDio(
          pageDelayMs: 500,
          onCall: () => calls++,
        ),
      );
      final token = CancelToken();
      final fut = api.importKgPlist('12345', cancelToken: token);
      await Future<void>.delayed(const Duration(milliseconds: 1200));
      token.cancel();
      final r = await fut;
      final callsAtCancel = calls;
      await Future<void>.delayed(const Duration(milliseconds: 1500));
      expect(calls, callsAtCancel,
          reason: 'no plist request may start after the cancel settles');
      expect(r.tracks.length, lessThan(400));
      expect(r.note, contains('已取消'));
    }, timeout: const Timeout(Duration(seconds: 120)));

    test('a page failing once then succeeding completes the import',
        () async {
      final api = MusicApi(
        dio: _kgPlistDio(pageDelayMs: 300, pageFailures: const {2: 1}),
      );
      final r = await api.importKgPlist('12345');
      expect(r.tracks.length, 400);
      expect(r.missing, 0);
      expect(r.note, '');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('M-P1-8 empty answers are not failures', () {
    test('three all-empty master resolves cool nothing', () async {
      final r = _resolversNoScripts(_dioWith(bodies: _emptyBodies));
      for (var i = 0; i < 3; i++) {
        final res = await r.resolvePlayUrl(
          'b27-p18-$i',
          MusicPlatform.wy,
          AudioQuality.master,
          'test',
        );
        expect(res, isNull);
      }
      await Future<void>.delayed(const Duration(milliseconds: 150));
      final raw = HiveStore.getString('hao_resolver_speed', '');
      expect(raw.contains('cooled'), isFalse);
      expect(raw.contains('fails'), isFalse);
      // The sources are still in line: with lzm and zddyr both fast
      // at 320k, lzm (order 20) must win — a cooled lzm would lose
      // to zddyr (order 25).
      final r2 = _resolversNoScripts(
        _dioWith(
          // Not const: the spread already carries these keys and the
          // overrides must win.
          bodies: {
            ..._emptyBodies,
            'music.lzmhhh.com': {'data': _lowUrl},
            'yy.zddyr.top': {'code': 200, 'url': _hiresUrl},
          },
        ),
      );
      final res = await r2.resolvePlayUrl(
        'b27-p18-x',
        MusicPlatform.wy,
        AudioQuality.q320k,
        'test',
      );
      expect(res?.via, 'lzm');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('M-P2-3 throttled speed saves', () {
    test('speeds land in Hive mid-resolve, before the resolve ends',
        () async {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) async {
            final route = _route(options.uri);
            if (route == 'c.wwwweb.top') {
              final is320 = options.data
                      ?.toString()
                      .contains('"quality":"320k"') ==
                  true;
              if (is320) {
                await Future<void>.delayed(
                  const Duration(milliseconds: 1500),
                );
                if (options.cancelToken?.isCancelled == true) return;
                handler.resolve(
                  Response(
                    requestOptions: options,
                    statusCode: 200,
                    data: {'code': 200, 'url': _hiresUrl},
                  ),
                );
                return;
              }
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
      // Ten script jobs that throw at once: ten counted attempts
      // (errors) in ~0 ms, so the 10-attempt throttle fires long
      // before the slow wwwweb success ends the resolve at ~1.5 s.
      // (Empty answers do not count toward the throttle — they record
      // nothing — so a world of fast empties has nothing to save.)
      final r = MusicResolvers(
        dio: dio,
        scriptEngine: _FakeScriptEngine(
          jobs: const {},
          throwKeys: [for (var i = 0; i < 10; i++) 'fake$i'],
        ),
      );
      final fut = r.resolvePlayUrl(
        'b27-p23-1',
        MusicPlatform.wy,
        AudioQuality.hires,
        'test',
      );
      await Future<void>.delayed(const Duration(milliseconds: 500));
      final midRaw = HiveStore.getString('hao_resolver_speed', '');
      expect(midRaw.contains('fails'), isTrue,
          reason: 'the 10-attempt throttle must have saved the ten '
              'script errors before the resolve returned');
      final res = await fut;
      expect(res?.via, 'wwwweb');
    }, timeout: const Timeout(Duration(seconds: 120)));
  });

  group('M-P2-7 dedupeKey drops the title', () {
    test('same platform+songId with "(Live)" in one title is one key',
        () {
      final a = Song(
        songId: 's1',
        title: 'Song',
        artist: 'A',
        platform: MusicPlatform.wy,
      );
      final b = Song(
        songId: 's1',
        title: 'Song (Live)',
        artist: 'A',
        platform: MusicPlatform.wy,
      );
      expect(a.dedupeKey, b.dedupeKey);
    });

    test('empty songIds with different titles stay distinct', () {
      final a = Song(
        songId: '',
        title: 'Song',
        artist: 'A',
        platform: MusicPlatform.wy,
      );
      final b = Song(
        songId: '',
        title: 'Song (Live)',
        artist: 'A',
        platform: MusicPlatform.wy,
      );
      expect(a.dedupeKey, isNot(b.dedupeKey));
    });
  });
}
