// build 27 视频+直播组修复回归测试（b27-audit-video-live / general）。
//
// 每项断言对应审计里的一项修法；失败 = 该修法已退化。
// - L-P0-1 session 层排除 IJK（虎牙/斗鱼）；L-P1-3 整份 urls 交梯子；
//   V-P1-2 VOD 开流总预算；V-P1-3 部分 typeMap 不写长缓存；V-P1-4
//   detail 取消透传；V-P2-2 vod_content mp4 兜底；V-P2-4 父分类并发
//   上限；G-P1-1 home() 静态节流 + fetchFresh Hive 新鲜缓存；
//   V-P2-1 fetchFresh 9 秒窗口；D-P1-1 豆瓣 15 秒取消标志；D-P1-2
//   桌面页与百科并行；L-P2-5 亮度拖动缓存种子；G-P1-2 RefererImage
//   布局下采样；D-P2-1 海报失败 2 秒重试一次；B-P1-1 关注卡片空标题
//   单行 + 观看数 pill；L-P0-2 自动恢复成功清失败卡片；L-P1-4
//   取失败 null 直接出失败卡片；V-P1-1 先试同集其他线路；V-P2-3
//   切线路保持集数与续播点。
//
// Harness 复用既有文件模式：video_test 的 clientWith、
// douban_year_match_test 的 fetcherFor、video_autoplay_test 的
// _FakeBackend、live_single_line_recovery_test 的 _FakeSite/_BackendLog。

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/cache/disk_image_cache.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/native/system_volume.dart';
import 'package:standalone/core/network/http_client.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/live_follow_store.dart';
import 'package:standalone/domains/live/presentation/live_follows_page.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/player/system_drag_controller.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_detail_service.dart';
import 'package:standalone/features/video/video_home_service.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/features/video/widgets/referer_image.dart';
import 'package:standalone/services/video/cms_client.dart';
import 'package:standalone/services/video/douban_service.dart';
import 'package:standalone/shared/platforms/live_site.dart';

import 'helpers/hive_test_setup.dart';

// ---------------------------------------------------------------------------
// Session fake backend (L-P0-1 / L-P1-3 / V-P1-2)
// ---------------------------------------------------------------------------

/// Fake backend for PlaybackSession tests: records every open (engine +
/// URL), fails first-frame only for URLs in [failFirstFrameUrls], and
/// optionally never returns a first frame ([hangFirstFrame]).
class _SessionBackend implements PlayerBackend {
  _SessionBackend({
    required this.engine,
    required this.log,
    this.failFirstFrameUrls = const {},
    this.hangFirstFrame = false,
  });

  @override
  final PlayerEngine engine;

  final _SessionLog log;
  final Set<String> failFirstFrameUrls;
  final bool hangFirstFrame;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  String? _lastUrl;
  bool _disposed = false;

  @override
  Widget buildVideoWidget() => const SizedBox(key: ValueKey('fake-video'));

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    _lastUrl = url;
    log.opens.add((engine: engine, url: url));
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (hangFirstFrame) return Completer<bool>().future;
    return !failFirstFrameUrls.contains(_lastUrl);
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Future<void> seekTo(Duration position) async {
    log.seeks.add(position);
  }

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  void emitPosition(Duration position) => _position.add(position);

  void emitCompleted() => _completed.add(null);

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}

class _SessionLog {
  final List<({PlayerEngine engine, String url})> opens = [];
  final List<Duration> seeks = [];
}

// ---------------------------------------------------------------------------
// RefererImage fake Dio adapter (G-P1-2 / D-P2-1)
// ---------------------------------------------------------------------------

/// 1x1 transparent PNG (kTransparentImage is not exported by
/// flutter_test in this SDK version).
final Uint8List _kPng1x1 = base64Decode(
  'iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==',
);

/// Serves canned image bytes / failures through sharedDio()'s adapter.
/// Restored by the caller in tearDown (sharedDio is a process singleton).
class _FakeImageAdapter implements HttpClientAdapter {
  _FakeImageAdapter({required this.firstStatus, this.secondStatus});

  final int firstStatus;
  final int? secondStatus;
  int calls = 0;

  @override
  Future<ResponseBody> fetch(
    RequestOptions options,
    Stream<Uint8List>? requestStream,
    Future<void>? cancelFuture,
  ) async {
    calls++;
    final status = calls == 1 ? firstStatus : (secondStatus ?? firstStatus);
    if (status != 200) return ResponseBody.fromString('', status);
    return ResponseBody.fromBytes(
      _kPng1x1,
      200,
      headers: {Headers.contentTypeHeader: ['image/png']},
    );
  }

  @override
  void close({bool force = false}) {}
}

// ---------------------------------------------------------------------------
// Douban fixtures (D-P1-1 / D-P1-2)
// ---------------------------------------------------------------------------

const _b27Abstract2020 =
    '{"r":0,"subject":{"id":222,"title":"同名片","rate":"8.0","release_year":"2020","is_tv":false,"directors":["导演甲"],"actors":["演员甲"],"types":["剧情"],"region":"中国大陆","duration":"100分钟"}}';
const _b27Mpage =
    '<meta property="og:image" content="https://img9.doubanio.com/view/photo/s_ratio_poster/public/p9.jpg"><meta itemprop="description" content="豆瓣评分：8.0 简介：简介。"><meta itemprop="ratingValue" content="8.0">';
const _b27Suggest =
    '[{"id":"222","title":"同名片","type":"movie","year":"2020"}]';

// ---------------------------------------------------------------------------
// Live room fakes (L-P0-2 / L-P1-4) — copied from
// live_single_line_recovery_test.dart, plus a shared
// [failOpensRemaining] counter so the FIRST N backend opens fail
// across engines (the ladder's first attempts die, the recovery
// open succeeds).
// ---------------------------------------------------------------------------

class _RoomFakeSite extends LiveSite {
  List<LivePlayQuality> qualities = const [
    LivePlayQuality(quality: '原画', id: '10000'),
    LivePlayQuality(quality: '高清', id: '400'),
  ];

  Map<String, List<String>> urlsByQuality = {
    '10000': [
      'https://tx.flv.huya.com/src/660000.flv?wsSecret=A1',
      'https://al.huya.com/src/660000.m3u8?wsSecret=A1',
    ],
    '400': [
      'https://tx.flv.huya.com/src/660000.flv?wsSecret=B1',
      'https://al.huya.com/src/660000.m3u8?wsSecret=B1',
    ],
  };

  Map<String, List<String>> recoveryUrlsByQuality = {
    '10000': [
      'https://tx.flv.huya.com/src/660000.flv?wsSecret=A2',
      'https://al.huya.com/src/660000.m3u8?wsSecret=A2',
    ],
    '400': [
      'https://tx.flv.huya.com/src/660000.flv?wsSecret=B2',
      'https://al.huya.com/src/660000.m3u8?wsSecret=B2',
    ],
  };

  bool recoveryThrows = false;
  int recoveryCalls = 0;

  @override
  String get id => 'huya';

  @override
  String get name => 'Huya';

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async => room;

  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async =>
      qualities;

  LivePlayUrlResolution _resolution(
    Map<String, List<String>> urls,
    LivePlayQuality? quality,
  ) {
    final id = quality?.selectionId ?? '';
    final issued = DateTime.now();
    final list = urls[id] ?? const <String>[];
    return LivePlayUrlResolution(
      urls: list,
      issuedAt: issued,
      refreshAt: issued.add(const Duration(seconds: 100)),
      invalidAt: issued.add(const Duration(seconds: 125)),
      streamFacts: list
          .map(
            (u) => u.toLowerCase().split('?').first.endsWith('.m3u8')
                ? const LiveStreamFacts(format: 'hls')
                : const LiveStreamFacts(format: 'flv'),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async =>
      _resolution(urlsByQuality, quality);

  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecovery({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    recoveryCalls++;
    if (recoveryThrows) {
      throw StateError('recovery resolve failed');
    }
    return _resolution(recoveryUrlsByQuality, quality);
  }
}

class _RoomBackendLog {
  final List<({PlayerEngine engine, String url})> opens = [];
  final List<_RoomFakeBackend> backends = [];

  /// Shared across engines: the next N opens throw, then opens succeed.
  int failOpensRemaining = 0;

  void cancelAllTickers() {
    for (final backend in backends) {
      backend.cancelTicker();
    }
  }
}

class _RoomFakeBackend implements PlayerBackend {
  _RoomFakeBackend({
    required this.engine,
    required this.log,
  }) {
    log.backends.add(this);
  }

  @override
  final PlayerEngine engine;

  final _RoomBackendLog log;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  Timer? _positionTimer;
  int _positionSeconds = 0;
  bool _disposed = false;

  void emitError(String message) => _error.add(message);

  void cancelTicker() => _positionTimer?.cancel();

  @override
  Widget buildVideoWidget() => const SizedBox(key: ValueKey('fake-video'));

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    log.opens.add((engine: engine, url: url));
    if (log.failOpensRemaining > 0) {
      log.failOpensRemaining--;
      throw StateError('fake open failed');
    }
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _positionSeconds++;
      _position.add(Duration(seconds: _positionSeconds));
    });
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      true;

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Future<void> seekTo(Duration position) async {}

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _positionTimer?.cancel();
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}

// ---------------------------------------------------------------------------
// Follows fake site (B-P1-1)
// ---------------------------------------------------------------------------

class _FollowStatusSite extends LiveSite {
  _FollowStatusSite({
    this.liveIds = const {},
    this.watchingById = const {},
  });

  @override
  final String id = 'fake';

  @override
  final String name = 'Fake';

  final Set<String> liveIds;
  final Map<String, int> watchingById;

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async =>
      room.copyWith(
        liveStatus: liveIds.contains(room.roomId),
        watching: watchingById[room.roomId] ?? 0,
      );
}

// ---------------------------------------------------------------------------
// VOD details (V-P1-1 / V-P2-3)
// ---------------------------------------------------------------------------

VideoDetail _twoLineDetail({
  required String deadUrl,
  required String liveUrl,
}) =>
    VideoDetail(
      source: 12,
      vodId: '93344',
      meta: VideoMeta(name: '流浪地球2'),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: [PlayEpisode(name: '正片', url: deadUrl)],
        ),
        PlayLine(
          name: '线路2',
          episodes: [PlayEpisode(name: '正片', url: liveUrl)],
        ),
      ],
    );

VideoDetail _fiveEpisodeTwoLineDetail() => VideoDetail(
      source: 12,
      vodId: '93344',
      meta: VideoMeta(name: '流浪地球2'),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: [
            for (var i = 1; i <= 5; i++)
              PlayEpisode(
                name: '第$i集',
                url: 'https://example.com/l1-ep$i.mp4',
              ),
          ],
        ),
        PlayLine(
          name: '线路2',
          episodes: [
            for (var i = 1; i <= 5; i++)
              PlayEpisode(
                name: '第$i集',
                url: 'https://example.com/l2-ep$i.mp4',
              ),
          ],
        ),
      ],
    );

// ---------------------------------------------------------------------------
// CJK + icon fonts for goldens (copied from render_live_tab_test.dart)
// ---------------------------------------------------------------------------

Future<void> _loadCjkFont() async {
  final loader = FontLoader('NotoSansSC');
  for (final path in const [
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc',
  ]) {
    final bytes = await File(path).readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
  final iconLoader = FontLoader('MaterialIcons');
  final iconBytes = await File(
    '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytes();
  iconLoader.addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

ThemeData _cjkTheme(ThemeData base) {
  final text = base.textTheme.apply(fontFamily: 'NotoSansSC');
  final primary = base.primaryTextTheme.apply(fontFamily: 'NotoSansSC');
  ButtonStyle cjkButton(ButtonStyle? style) {
    final resolved = style?.textStyle?.resolve({});
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStatePropertyAll(
        (resolved ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC'),
      ),
    );
  }

  TextStyle cjkStyle(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC');
  return base.copyWith(
    cupertinoOverrideTheme: haoCupertinoThemeWithFont('NotoSansSC'),
    textTheme: text,
    primaryTextTheme: primary,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjkStyle(base.appBarTheme.titleTextStyle),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: cjkStyle(base.chipTheme.labelStyle),
    ),
    elevatedButtonTheme: ElevatedButtonThemeData(
      style: cjkButton(base.elevatedButtonTheme.style),
    ),
    outlinedButtonTheme: OutlinedButtonThemeData(
      style: cjkButton(base.outlinedButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: cjkButton(base.textButtonTheme.style),
    ),
  );
}

/// CmsClient whose home() answers after [delay] (V-P2-1): the only way
/// to put a home load between the 9 s window and the old 12 s + 5 s
/// grace — a real CmsClient settles by ~9 s on its own budgets.
class _SlowHomeClient extends CmsClient {
  _SlowHomeClient(this.delay) : super(sources: const []);

  final Duration delay;

  @override
  Future<VideoHomeData> home({CancelToken? cancelToken}) async {
    await Future<void>.delayed(delay);
    return VideoHomeData(rows: const [], fetchedAt: DateTime.now());
  }
}

void main() {
  late Directory hiveDir;
  late Directory imgDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init(prefix: 'hao-b27-test-');
    imgDir = await Directory.systemTemp.createTemp('hao-b27-img-');
    DiskImageCache.setDirectoryForTest(imgDir);
    // FontLoader is real async I/O: it must load here on the real
    // clock. Called inside a testWidgets body it never resolves in
    // the fake-async zone and the golden test hangs (probed 2026-11-21).
    await _loadCjkFont();
  });

  tearDownAll(() async {
    DiskImageCache.resetForTest();
    await HiveTestSetup.dispose(hiveDir);
    await imgDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
    unawaited(HiveStore.put(HiveKeys.videoPlayerKey, 'mpv'));
  });

  const sourceA = VideoSource(
    id: 12,
    name: 'A',
    apiUrl: 'http://b27a.example.com/api.php/provide/vod',
    kind: 'play',
    sort: 1,
  );
  const sourceB = VideoSource(
    id: 13,
    name: 'B',
    apiUrl: 'http://b27b.example.com/api.php/provide/vod',
    kind: 'play',
    sort: 2,
  );

  Map<String, dynamic> classJson(List<Map<String, dynamic>> rows) =>
      {'code': 1, 'class': rows};

  Map<String, dynamic> listJson(List<Map<String, dynamic>> items) => {
        'code': 1,
        'page': '1',
        'pagecount': 1,
        'total': items.length,
        'list': items,
      };

  Map<String, dynamic> item(String id, String name) => {
        'vod_id': id,
        'vod_name': name,
        'vod_pic': 'https://image.example.com/$id.jpg',
        'type_name': '电影',
        'vod_year': '2024',
        'vod_area': '大陆',
      };

  group('PlaybackSession: L-P0-1 / L-P1-3 / V-P1-2', () {
    test('L-P0-1: excludeIjk keeps fijk out of the Huya/Douyu ladder',
        () async {
      final log = _SessionLog();
      final session = PlaybackSession(
        preferred: PlayerEngine.fijk,
        backendFactory: (engine) =>
            _SessionBackend(engine: engine, log: log),
      );
      final ok = await session.open(
        url: 'https://example.com/live.m3u8',
        isLive: true,
        excludeIjk: true,
      );
      expect(ok, isTrue);
      expect(
        log.opens.map((o) => o.engine),
        isNot(contains(PlayerEngine.fijk)),
        reason: 'no IJK attempt for a Huya/Douyu room',
      );
      expect(session.currentUrl, 'https://example.com/live.m3u8');
      await session.dispose();
    });

    test('L-P0-1 control: without excludeIjk, fijk is tried first',
        () async {
      final log = _SessionLog();
      final session = PlaybackSession(
        preferred: PlayerEngine.fijk,
        backendFactory: (engine) =>
            _SessionBackend(engine: engine, log: log),
      );
      final ok = await session.open(
        url: 'https://example.com/live.m3u8',
        isLive: true,
      );
      expect(ok, isTrue);
      expect(log.opens.first.engine, PlayerEngine.fijk);
      await session.dispose();
    });

    test('L-P1-3: the whole resolution rides the ladder, no re-parse',
        () async {
      const dead = 'https://line1.example.com/dead.m3u8';
      const live = 'https://line2.example.com/live.m3u8';
      final log = _SessionLog();
      var refreshCalls = 0;
      final session = PlaybackSession(
        preferred: PlayerEngine.mediaKit,
        backendFactory: (engine) => _SessionBackend(
          engine: engine,
          log: log,
          failFirstFrameUrls: {dead},
        ),
      );
      final ok = await session.open(
        url: dead,
        urls: const [dead, live],
        isLive: true,
        refreshUrls: () async {
          refreshCalls++;
          return null;
        },
      );
      expect(ok, isTrue);
      expect(refreshCalls, 0, reason: 'line 2 played, no re-parse needed');
      expect(session.currentUrl, live);
      expect(log.opens.map((o) => o.url), containsAll([dead, live]));
      expect(log.opens.last.url, live);
      await session.dispose();
    });

    test('V-P1-2: openBudget cuts a never-first-frame open at the budget',
        () async {
      final log = _SessionLog();
      final session = PlaybackSession(
        preferred: PlayerEngine.mediaKit,
        backendFactory: (engine) => _SessionBackend(
          engine: engine,
          log: log,
          hangFirstFrame: true,
        ),
      );
      final sw = Stopwatch()..start();
      final ok = await session.open(
        url: 'https://example.com/film.m3u8',
        isLive: false,
        openBudget: const Duration(seconds: 2),
      );
      sw.stop();
      expect(ok, isFalse);
      // Without the budget this open would hang forever (the fake
      // first frame never arrives); with it, it reports in ~2 s.
      expect(sw.elapsed, lessThan(const Duration(seconds: 5)));
      await session.dispose();
    });
  });

  group('CmsClient: V-P1-3 / V-P1-4 / V-P2-2 / V-P2-4 / G-P1-1(a)', () {
    test('V-P1-3: partial typeMap is NOT cached for 10 minutes', () {
      fakeAsync((async) {
        final log = <String>[];
        Future<Map<String, dynamic>> fetcher(
          String url, {
          Duration timeout = const Duration(seconds: 8),
          CancelToken? cancelToken,
        }) async {
          log.add(url);
          // Sources 1-2 answer at once; 3-6 take 30 s (past the 6 s
          // cap), so the first table covers 2 of 6 sources.
          if (url.contains('s3.example') ||
              url.contains('s4.example') ||
              url.contains('s5.example') ||
              url.contains('s6.example')) {
            await Future<void>.delayed(const Duration(seconds: 30));
          }
          return classJson([
            {'type_id': 1, 'type_pid': 0, 'type_name': '电影'},
          ]);
        }

        final sources = [
          for (var i = 1; i <= 6; i++)
            VideoSource(
              id: i,
              name: 'S$i',
              apiUrl: 'http://s$i.example.com/api.php/provide/vod',
              kind: 'play',
              sort: i,
            ),
        ];
        final client = CmsClient(sources: sources, fetcher: fetcher);
        Map<String, CmsTypeEntry>? m1;
        client.typeMap().then((v) => m1 = v);
        async.elapse(const Duration(seconds: 7));
        async.flushMicrotasks();
        expect(m1, isNotNull);
        expect(log.length, 6);
        // 5 min later — still inside the 10-min window, so a cached
        // table would serve with zero new fetches.
        async.elapse(const Duration(minutes: 5));
        Map<String, CmsTypeEntry>? m2;
        client.typeMap().then((v) => m2 = v);
        async.elapse(const Duration(seconds: 7));
        async.flushMicrotasks();
        expect(m2, isNotNull);
        expect(
          log.length,
          12,
          reason: 'partial table must re-fetch, not serve thin for 10 min',
        );
      });
    });

    test('V-P1-4: detail() cancellation reaches the fetcher', () {
      fakeAsync((async) {
        CancelToken? seen;
        Future<Map<String, dynamic>> fetcher(
          String url, {
          Duration timeout = const Duration(seconds: 8),
          CancelToken? cancelToken,
        }) async {
          seen = cancelToken;
          await cancelToken!.whenCancel;
          throw DioException(
            requestOptions: RequestOptions(path: url),
            type: DioExceptionType.cancel,
          );
        }

        final client = CmsClient(
          sources: const [sourceA],
          fetcher: fetcher,
        );
        final token = CancelToken();
        Object? failure;
        VideoDetail? out;
        client.detail(12, '1', cancelToken: token).then<void>((v) {
          out = v;
        }, onError: (e, _) {
          failure = e;
        });
        async.flushMicrotasks();
        expect(seen, isNotNull, reason: 'detail passed its token down');
        expect(token.isCancelled, isFalse);
        token.cancel();
        async.flushMicrotasks();
        expect(failure, isA<DioException>());
        expect(
          (failure as DioException).type,
          DioExceptionType.cancel,
          reason: 'cancellation rethrows as cancel, never a source failure',
        );
        expect(out, isNull);
      });
    });

    test('V-P2-2: vod_content mp4 fallback yields one line', () {
      final d = parseCmsDetail(sourceA, '1', {
        'code': 1,
        'list': [
          {
            'vod_id': '1',
            'vod_name': '片名',
            'vod_pic': '',
            'vod_play_url': '',
            'vod_play_from': '',
            'vod_content':
                '简介文字 https://cdn.example.com/film.mp4 更多文字',
          },
        ],
      });
      expect(d, isNotNull);
      expect(d!.lines.length, 1);
      expect(
        d.lines.first.episodes.first.url,
        'https://cdn.example.com/film.mp4',
      );
    });

    test('V-P2-2: m3u8 still wins over mp4 in vod_content', () {
      final d = parseCmsDetail(sourceA, '1', {
        'code': 1,
        'list': [
          {
            'vod_id': '1',
            'vod_name': '片名',
            'vod_pic': '',
            'vod_play_url': '',
            'vod_play_from': '',
            'vod_content':
                'https://cdn.example.com/film.mp4 https://cdn.example.com/film.m3u8',
          },
        ],
      });
      expect(d, isNotNull);
      expect(
        d!.lines.first.episodes.first.url,
        'https://cdn.example.com/film.m3u8',
      );
    });

    test('V-P2-4: parent fan-out caps concurrent requests at 5', () async {
      final rows = [
        {'type_id': 2, 'type_pid': 0, 'type_name': '电影'},
        for (var i = 0; i < 20; i++)
          {'type_id': 100 + i, 'type_pid': 2, 'type_name': '子$i'},
      ];
      var active = 0;
      var maxActive = 0;
      Future<Map<String, dynamic>> fetcher(
        String url, {
        Duration timeout = const Duration(seconds: 8),
        CancelToken? cancelToken,
      }) async {
        if (url.contains('?ac=list')) return classJson(rows);
        active++;
        if (active > maxActive) maxActive = active;
        try {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          final t = Uri.parse(url).queryParameters['t'] ?? '';
          return listJson([item(t, '片$t')]);
        } finally {
          active--;
        }
      }

      final client = CmsClient(sources: const [sourceA], fetcher: fetcher);
      final r = await client.byType('电影', 1);
      expect(maxActive, lessThanOrEqualTo(5));
      expect(r.items.length, 20);
    });

    test('G-P1-1(a): home() static throttle — second client, no requests',
        () async {
      var calls = 0;
      Future<Map<String, dynamic>> fetcher(
        String url, {
        Duration timeout = const Duration(seconds: 8),
        CancelToken? cancelToken,
      }) async {
        calls++;
        if (url.contains('?ac=list')) {
          return classJson([
            {'type_id': 2, 'type_pid': 0, 'type_name': '电影'},
            {'type_id': 9, 'type_pid': 2, 'type_name': '动作片'},
            {'type_id': 11, 'type_pid': 2, 'type_name': '喜剧片'},
          ]);
        }
        final t = Uri.parse(url).queryParameters['t'] ?? '';
        return listJson([item(t, '片$t')]);
      }

      final a = CmsClient(sources: const [sourceA], fetcher: fetcher);
      final b = CmsClient(sources: const [sourceA], fetcher: fetcher);
      final first = await a.home();
      expect(first.rows, isNotEmpty);
      final afterFirst = calls;
      expect(afterFirst, greaterThan(0));
      final second = await b.home();
      expect(second.rows, isNotEmpty);
      expect(calls, afterFirst, reason: 'same fetcher, 60 s window');
    });
  });

  group('VideoHomeService: V-P2-1 / G-P1-1(b)', () {
    test('V-P2-1: fetchFresh cuts a slow home at 9 s, not 12 + 5', () {
      fakeAsync((async) {
        final service = VideoHomeService(
          cms: _SlowHomeClient(const Duration(seconds: 10)),
        );
        VideoHomeData? out;
        var done = false;
        unawaited(
          service.fetchFresh(force: true).then((v) {
            out = v;
            done = true;
          }),
        );
        async.elapse(const Duration(seconds: 9));
        async.flushMicrotasks();
        // The old code would still be inside its 12 s window here
        // (and would return the 10 s home at t=10); the new code
        // reports null at the 9 s budget.
        expect(done, isTrue);
        expect(out, isNull);
        expect(async.elapsed, const Duration(seconds: 9));
      });
    });

    test('G-P1-1(b): fetchFresh serves fresh Hive cache, zero network',
        () async {
      await HiveStore.delete(HiveKeys.videoHomeCache);
      var calls = 0;
      Future<Map<String, dynamic>> fetcher(
        String url, {
        Duration timeout = const Duration(seconds: 8),
        CancelToken? cancelToken,
      }) async {
        calls++;
        if (url.contains('?ac=list')) {
          return classJson([
            {'type_id': 2, 'type_pid': 0, 'type_name': '电影'},
            {'type_id': 9, 'type_pid': 2, 'type_name': '动作片'},
          ]);
        }
        final t = Uri.parse(url).queryParameters['t'] ?? '';
        return listJson([item(t, '片$t')]);
      }

      final service = VideoHomeService(
        cms: CmsClient(sources: const [sourceB], fetcher: fetcher),
      );
      final first = await service.fetchFresh();
      expect(first, isNotNull);
      expect(first!.rows, isNotEmpty);
      final afterFirst = calls;
      expect(afterFirst, greaterThan(0));
      final second = await service.fetchFresh();
      expect(second, isNotNull);
      expect(calls, afterFirst, reason: 'fresh Hive cache, no network');
      expect(
        second!.rows.map((r) => r.name).toList(),
        first.rows.map((r) => r.name).toList(),
      );
    });
  });

  group('Douban: D-P1-1 / D-P1-2', () {
    test('D-P1-1: 15 s timeout abandons the chain, next call is not delayed',
        () {
      fakeAsync((async) {
        var calls = 0;
        Future<({int status, String body})> fetcher(
          String url,
          Map<String, String> headers, {
          Duration timeout = const Duration(seconds: 10),
        }) async {
          calls++;
          if (url.contains('movie.douban.com/subject/')) {
            // Desktop page: always 6 s. This is the orphaned chain's
            // leftover _call: without the fix it runs (18-24 s) and
            // the next detail()'s calls queue behind it; with the fix
            // it is never even queued.
            await Future<void>.delayed(const Duration(seconds: 6));
            return (status: 200, body: '');
          }
          // The first three calls (suggest, abstract, m page) each
          // take 6 s; later calls are instant.
          if (calls <= 3) {
            await Future<void>.delayed(const Duration(seconds: 6));
          }
          if (url.contains('subject_suggest')) {
            return (status: 200, body: _b27Suggest);
          }
          if (url.contains('subject_abstract')) {
            return (status: 200, body: _b27Abstract2020);
          }
          if (url.contains('m.douban.com')) {
            return (status: 200, body: _b27Mpage);
          }
          return (status: 404, body: '');
        }

        final cache = MemoryDoubanCache();
        final service = DoubanService(
          fetcher: fetcher,
          cache: cache,
          castPhotoFetcher: (_) async => '',
        );
        DoubanDetail? first;
        var firstDone = false;
        unawaited(
          service.detail('同名片', '2020').then((d) {
            first = d;
            firstDone = true;
          }),
        );
        async.elapse(const Duration(seconds: 15));
        async.flushMicrotasks();
        expect(firstDone, isTrue);
        expect(first, isNull, reason: '6 s steps cannot fit the 15 s budget');
        // The timed-out chain never cached anything.
        expect(cache.detail('222'), isNull);
        // The next call is not stuck behind the orphan's leftover
        // steps: the desktop fetch is abandoned, so the second
        // detail() lands ~11 s after it starts (fixed world ~26 s
        // absolute), while without the fix it queues behind the
        // orphan's 6 s desktop fetch and lands ~32 s.
        DoubanDetail? second;
        var secondDone = false;
        unawaited(
          service.detail('同名片', '2020').then((d) {
            second = d;
            secondDone = true;
          }),
        );
        async.elapse(const Duration(seconds: 15));
        async.flushMicrotasks();
        expect(secondDone, isTrue);
        expect(second, isNotNull);
        expect(second!.id, '222');
      });
    });

    test('D-P1-2: desktop page + Baike run in parallel', () {
      fakeAsync((async) {
        Future<({int status, String body})> fetcher(
          String url,
          Map<String, String> headers, {
          Duration timeout = const Duration(seconds: 10),
        }) async {
          if (url.contains('subject_suggest')) {
            return (status: 200, body: _b27Suggest);
          }
          if (url.contains('subject_abstract')) {
            return (status: 200, body: _b27Abstract2020);
          }
          if (url.contains('m.douban.com')) {
            return (status: 200, body: _b27Mpage);
          }
          if (url.contains('movie.douban.com/subject/')) {
            // Desktop page: 6 s (its own timeout).
            await Future<void>.delayed(const Duration(seconds: 6));
            return (status: 200, body: '');
          }
          return (status: 404, body: '');
        }

        final service = DoubanService(
          fetcher: fetcher,
          cache: MemoryDoubanCache(),
          castPhotoFetcher: (_) async {
            // Baike: 7 s. Serial code would need 6 + 7 = 13 s after
            // the m page and miss the 15 s budget; parallel code
            // needs max(6, 7) = 7 s.
            await Future<void>.delayed(const Duration(seconds: 7));
            return 'https://img.example.com/actor.jpg';
          },
        );
        DoubanDetail? out;
        var done = false;
        unawaited(
          service.detail('同名片', '2020').then((d) {
            out = d;
            done = true;
          }),
        );
        async.elapse(const Duration(seconds: 12));
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(out, isNotNull);
        expect(out!.castPhotos, contains('https://img.example.com/actor.jpg'));
      });
    });
  });

  group('SystemDragController: L-P2-5', () {
    late MethodChannel volumeChannel;

    setUp(() {
      volumeChannel = const MethodChannel('test/b27-drag-volume');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(volumeChannel, (call) async {
        if (call.method == 'getVolume') return 1.0;
        return null;
      });
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(volumeChannel, null);
    });

    SystemDragController controller() => SystemDragController(
          systemVolume: SystemVolume(channel: volumeChannel),
        );

    test(
        'brightness drag: ticks banked while the fresh seed lands, then anchored at the fresh level',
        () async {
      // The channel re-read is slow on purpose (50 ms): ticks that
      // arrive while startDrag is still waiting must be banked, not
      // dropped — and the drag must anchor at the FRESH 0.6, never
      // at the stale cached 0.7.
      final sets = <double>[];
      const brightnessChannel = MethodChannel(
        'github.com/aaassseee/screen_brightness',
      );
      final messenger =
          TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
      messenger.setMockMethodCallHandler(brightnessChannel, (call) async {
        switch (call.method) {
          case 'getApplicationScreenBrightness':
            await Future<void>.delayed(const Duration(milliseconds: 50));
            return 0.6;
          case 'setApplicationScreenBrightness':
            sets.add((call.arguments as Map)['brightness'] as double);
            return null;
          default:
            return null;
        }
      });
      addTearDown(
        () => messenger.setMockMethodCallHandler(brightnessChannel, null),
      );

      final c = controller();
      c.brightnessLevel = 0.7;
      final start = c.startDrag(const Offset(50, 500), const Size(400, 800));
      // HUD shows the cached level at once, but the seed is not
      // ready until the fresh re-read lands.
      expect(c.seedReady, isFalse);
      expect(c.value.value, 0.7);
      c.updateDrag(
        DragUpdateDetails(
          delta: const Offset(0, -30),
          globalPosition: const Offset(50, 470),
        ),
        const Size(400, 800),
      );
      // Banked, not dropped and not applied yet: no platform write,
      // HUD still the cached 0.7.
      expect(sets, isEmpty);
      expect(c.value.value, 0.7);
      await start;
      // Seed landed fresh at 0.6 with the banked -30 px applied (+0.1).
      expect(c.seedReady, isTrue);
      expect(c.value.value, closeTo(0.7, 0.001));
      expect(c.brightnessLevel, closeTo(0.7, 0.001));
      expect(sets, [closeTo(0.7, 0.001)]);
      // A further tick continues from the fresh anchor.
      c.updateDrag(
        DragUpdateDetails(
          delta: const Offset(0, -30),
          globalPosition: const Offset(50, 440),
        ),
        const Size(400, 800),
      );
      expect(c.value.value, closeTo(0.8, 0.001));
      expect(c.brightnessLevel, closeTo(0.8, 0.001));
      c.endDrag();
      expect(c.brightnessLevel, closeTo(0.8, 0.001));
      c.dispose();
    });

    test('brightness drag without movement: re-read seeds the next drag',
        () async {
      final c = controller();
      c.brightnessLevel = 0.7;
      await c.startDrag(const Offset(50, 500), const Size(400, 800));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      c.endDrag();
      // The drag never moved brightness, but the re-read already
      // landed at drag start (0.5 in tests — no channel mock, so
      // the read falls back), and that fresh value is the next
      // drag's seed.
      expect(c.brightnessLevel, 0.5);
      c.dispose();
    });
  });

  group('RefererImage: G-P1-2 / D-P2-1 (widget)', () {
    late HttpClientAdapter originalAdapter;

    setUp(() {
      originalAdapter = sharedDio().httpClientAdapter;
    });

    tearDown(() async {
      sharedDio().httpClientAdapter = originalAdapter;
      await Future<void>.delayed(const Duration(milliseconds: 100));
    });

    Future<void> pumpImage(
      WidgetTester tester, {
      required String url,
      double width = 84,
      double height = 112,
      Widget? fallback,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: width,
                height: height,
                child: RefererImage(url: url, fallback: fallback),
              ),
            ),
          ),
        ),
      );
      // DiskImageCache.get is real file I/O: a lookup started inside
      // the widget test's fake-async zone never resolves on pump/settle
      // alone (a bare runAsync delay does not drain it either — probed
      // 2026-11-21: 4x settle left the Dio fetch at 0 calls). Awaiting
      // a real I/O call on the real clock releases the pending lookup,
      // and the continuation is only delivered when the fake clock
      // elapses — a bare pump does not release it (same probe: bare
      // pump + settle still 0 calls, a 500 ms pump fired the fetch).
      await tester.runAsync(() => DiskImageCache.get(url));
      await tester.pump(const Duration(milliseconds: 500));
      await settle(tester);
      await tester.pump();
    }

    testWidgets('G-P1-2: decode size follows the layout box, not full res',
        (tester) async {
      sharedDio().httpClientAdapter = _FakeImageAdapter(firstStatus: 200);
      await pumpImage(
        tester,
        url: 'https://example.com/poster-g12.jpg',
      );
      final image = tester.widget<Image>(find.byType(Image));
      // Image.memory folds cacheWidth/cacheHeight into a ResizeImage
      // provider: read the decode size there. 84x112 layout at the
      // test surface dpr caps the decode at the displayed size
      // (before the fix both were null — full-resolution decode).
      final dpr = tester.view.devicePixelRatio;
      final resized = image.image as ResizeImage;
      expect(resized.width, (84 * dpr).ceil());
      expect(resized.height, (112 * dpr).ceil());
    });

    testWidgets('D-P2-1: one automatic retry 2 s after a 500',
        (tester) async {
      final adapter = _FakeImageAdapter(firstStatus: 500, secondStatus: 200);
      sharedDio().httpClientAdapter = adapter;
      const url = 'https://example.com/poster-d21.jpg';
      await pumpImage(
        tester,
        url: url,
        fallback: const Text('FAILED'),
      );
      expect(find.text('FAILED'), findsOneWidget);
      expect(adapter.calls, 1);
      // The retry fires 2 s after the first failure; its _load hits
      // the same fake-zone disk lookup, so drain it again on the real
      // clock before pumping.
      await tester.pump(const Duration(seconds: 2));
      await tester.runAsync(() => DiskImageCache.get(url));
      await tester.pump(const Duration(milliseconds: 500));
      await settle(tester);
      await tester.pump();
      expect(find.byType(Image), findsOneWidget);
      expect(adapter.calls, 2);
      // And only once: no third attempt after another 2 s.
      await tester.pump(const Duration(seconds: 3));
      await tester.pump();
      expect(adapter.calls, 2);
    });
  });

  group('LiveFollowsPage: B-P1-1 (widget)', () {
    // The follow cards' covers are RefererImages: give them the same
    // mocked 200 adapter as the poster tests, or their Dio fetches
    // leave 0-duration Timers pending at dispose and the test fails
    // with 'A Timer is still pending even after the widget tree was
    // disposed' (golden, 2026-11-21).
    late HttpClientAdapter originalAdapter;

    setUp(() {
      originalAdapter = sharedDio().httpClientAdapter;
      sharedDio().httpClientAdapter = _FakeImageAdapter(firstStatus: 200);
    });

    tearDown(() {
      sharedDio().httpClientAdapter = originalAdapter;
    });

    Future<void> addFollow(WidgetTester tester, LiveRoom room) =>
        tester.runAsync(() => LiveFollowStore.add(room));

    Future<void> resetFollows(WidgetTester tester) =>
        tester.runAsync(() => HiveStore.delete(HiveKeys.liveFollows));

    /// Drain the cover RefererImages' fake-zone disk lookups on the
    /// real clock, then advance the fake clock so their Dio fetches
    /// complete — otherwise a pending Dio Timer fails the test at
    /// dispose (see the group setUp comment).
    Future<void> settleCovers(WidgetTester tester) async {
      await tester.runAsync(
        () => DiskImageCache.get('https://example.com/cover-x.jpg'),
      );
      await tester.runAsync(
        () => DiskImageCache.get('https://example.com/cover-y.jpg'),
      );
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
    }

    Future<void> pumpFollows(
      WidgetTester tester, {
      required _FollowStatusSite site,
      ThemeData? theme,
    }) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: theme ?? HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveFollowsPage(
            siteOf: (_) => site,
            onOpenRoom: (_) {},
            onBrowse: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets('empty title: nick once, watching pill shown',
        (tester) async {
      await resetFollows(tester);
      await addFollow(
        tester,
        LiveRoom(
          roomId: 'x',
          platform: 'bilibili',
          title: '',
          nick: '主播甲',
          cover: 'https://example.com/cover-x.jpg',
          watching: 12345,
          liveStatus: true,
        ),
      );
      await pumpFollows(
        tester,
        site: _FollowStatusSite(
          liveIds: {'x'},
          watchingById: {'x': 12345},
        ),
      );
      await settleCovers(tester);

      expect(find.text('主播甲'), findsOneWidget);
      // The second line is skipped for an empty title — the nick
      // must not show twice (before the fix it read "主播甲 · 哔哩哔哩").
      expect(find.text('主播甲 · 哔哩哔哩'), findsNothing);
      // Watching pill, same style as the live tab's card.
      // Build-29 item 6: the pill is labelled by metric kind, never a
      // bare number — bilibili reports 在线人数, so 12345 renders as
      // "在线 1.2万人" (same text as the live tab's card).
      expect(find.text('在线 1.2万人'), findsOneWidget);
      expect(find.byIcon(Icons.visibility_outlined), findsOneWidget);
    });

    testWidgets('golden: empty-title follow card', (tester) async {
      // Same surface as render_live_tab_test.dart (780x1688 @2.0) so
      // the golden is comparable with the tab page's.
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await resetFollows(tester);
      await addFollow(
        tester,
        LiveRoom(
          roomId: 'x',
          platform: 'bilibili',
          title: '',
          nick: '主播甲',
          cover: 'https://example.com/cover-x.jpg',
          watching: 12345,
          liveStatus: true,
        ),
      );
      await addFollow(
        tester,
        LiveRoom(
          roomId: 'y',
          platform: 'huya',
          title: '夜跑',
          nick: '阿跑',
          cover: 'https://example.com/cover-y.jpg',
          watching: 9999,
          liveStatus: true,
        ),
      );
      await pumpFollows(
        tester,
        site: _FollowStatusSite(
          liveIds: {'x', 'y'},
          watchingById: {'x': 12345, 'y': 9999},
        ),
        theme: _cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light),
      );
      await settleCovers(tester);
      await expectLater(
        find.byType(GetMaterialApp),
        matchesGoldenFile('goldens/live_follows_empty_title_light.png'),
      );
    });
  });

  group('LiveRoomPage: L-P0-2 / L-P1-4 (widget)', () {
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<void> pumpRoom(
      WidgetTester tester,
      _RoomFakeSite site,
      _RoomBackendLog log,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(
        () => HiveStore.put(HiveKeys.preferResolution, '原画'),
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveRoomPage(
            room: const LiveRoom(
              roomId: '660000',
              platform: 'huya',
              title: 'test room',
              nick: 'tester',
              liveStatus: true,
            ),
            site: site,
            backendFactory: (engine) =>
                _RoomFakeBackend(engine: engine, log: log),
          ),
        ),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
    }

    Future<void> disposeRoom(
      WidgetTester tester,
      _RoomBackendLog log,
    ) async {
      log.cancelAllTickers();
      Get.closeAllSnackbars();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    testWidgets('L-P0-2: auto recovery success clears the failure card',
        (tester) async {
      final site = _RoomFakeSite();
      // Huya excludes IJK, so the ladder is [mpv] x 2 urls: the
      // first 2 opens die, the recovery open plays.
      final log = _RoomBackendLog()..failOpensRemaining = 2;
      await pumpRoom(tester, site, log);
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(site.recoveryCalls, 1);
      expect(log.opens.last.url, contains('wsSecret=A2'));
      expect(find.text('▶ 重试'), findsNothing);
      await disposeRoom(tester, log);
      // The room page issues fire-and-forget Hive writes (history +
      // quality + breadcrumbs) in the fake zone; hive_ce serialises
      // them through one queue, and a write left pending here sticks
      // the queue for the NEXT test — its first Hive write hangs
      // forever, even through runAsync (helpers/hive_test_setup.dart).
      // Drain inside the test body, before the zone is discarded.
      await drainHiveWrites(tester);
    });

    testWidgets(
        'L-P1-4: failed re-parse shows the failure card, never opens a stale line',
        (tester) async {
      final site = _RoomFakeSite()..recoveryThrows = true;
      final log = _RoomBackendLog();
      await pumpRoom(tester, site, log);
      expect(find.text('▶ 重试'), findsNothing);
      final opensBefore = log.opens.length;
      log.backends.last.emitError('boom');
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(site.recoveryCalls, 1);
      expect(find.text('▶ 重试'), findsOneWidget);
      // The old code opened the next (stale) line here; the fix
      // shows the card instead.
      expect(log.opens.length, opensBefore);
      await disposeRoom(tester, log);
      // Same Hive-write drain as L-P0-2 (see the comment there): the
      // room page's fire-and-forget writes must not stick the queue
      // for the next test.
      await drainHiveWrites(tester);
    });
  });

  group('NativeVideoPlayerPage: V-P1-1 / V-P2-3 (widget)', () {
    late PlaybackSession session;
    final backends = <_SessionBackend>[];
    final log = _SessionLog();

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<void> pumpPlayer(
      WidgetTester tester, {
      required VideoDetail detail,
      int initialEpisodeIndex = 0,
      double initialPosition = 0,
      Set<String> failFirstFrameUrls = const {},
      VideoDetailService? detailService,
    }) async {
      backends.clear();
      log.opens.clear();
      log.seeks.clear();
      session = PlaybackSession(
        backendFactory: (engine) {
          final b = _SessionBackend(
            engine: engine,
            log: log,
            failFirstFrameUrls: failFirstFrameUrls,
          );
          backends.add(b);
          return b;
        },
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: NativeVideoPlayerPage(
            detail: detail,
            initialEpisodeIndex: initialEpisodeIndex,
            initialPosition: initialPosition,
            session: session,
            detailService: detailService,
          ),
        ),
      );
      await settle(tester);
      await settle(tester);
    }

    Future<void> unmountPlayer(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    testWidgets('V-P1-1: dead episode tries the other line first, no CMS call',
        (tester) async {
      const deadUrl = 'https://example.com/l1-dead.mp4';
      const liveUrl = 'https://example.com/l2-live.mp4';
      var findAltsCalls = 0;
      final detailService = VideoDetailService(
        findAlts: (title, year, exclude, {cancelToken}) {
          findAltsCalls++;
          return const Stream<AltVideoSource>.empty();
        },
      );
      await pumpPlayer(
        tester,
        detail: _twoLineDetail(deadUrl: deadUrl, liveUrl: liveUrl),
        failFirstFrameUrls: {deadUrl},
        detailService: detailService,
      );
      // The same episode played on line 2 with zero network requests:
      // the cross-source sweep never ran.
      expect(findAltsCalls, 0);
      expect(log.opens.map((o) => o.url).last, liveUrl);
      // The header shows the composite line + episode label
      // ('线路2 · 正片'); the bare episode name only exists inside
      // the episode-picker sheet, which is not open here.
      expect(find.text('线路2 · 正片'), findsOneWidget);
      await unmountPlayer(tester);
      // The page's trailing _recordHistory Hive write starts in the
      // fake zone and sticks hive_ce's write queue for the next test
      // (see the room group's drainHiveWrites comment) — drain it
      // before this test ends.
      await drainHiveWrites(tester);
    });

    testWidgets('V-P2-3: switching lines keeps the episode and position',
        (tester) async {
      await pumpPlayer(
        tester,
        detail: _fiveEpisodeTwoLineDetail(),
        initialEpisodeIndex: 4,
      );
      // _switchLine awaits _saveProgress (a Hive write) before
      // opening the new line; the initial open's trailing
      // _recordHistory write started in the fake zone and sticks
      // hive_ce's write queue, so drain it first or the tap below
      // never opens anything (same mechanism as the room group).
      await drainHiveWrites(tester);
      expect(
        log.opens.map((o) => o.url).toList(),
        ['https://example.com/l1-ep5.mp4'],
      );
      // Play to 10:00 on episode 5, then switch lines.
      backends.last.emitPosition(const Duration(minutes: 10));
      await settle(tester);
      await tester.tap(find.text('线路2'));
      // The tap's _switchLine awaits _saveProgress (a Hive write)
      // before opening the new line, and that write starts in the
      // fake zone — plain settles do not release it in time (probed
      // 2026-11-21: 2 settles left opens at [l1-ep5]). Drain the
      // queue (settle + flush probe) so the switch actually opens.
      await drainHiveWrites(tester);
      await settle(tester);
      expect(
        log.opens.map((o) => o.url).last,
        'https://example.com/l2-ep5.mp4',
        reason: 'same episode (第5集) on the new line',
      );
      expect(
        log.seeks.any(
          (s) =>
              (s - const Duration(minutes: 10)).abs() <
              const Duration(seconds: 2),
        ),
        isTrue,
        reason: 'resume seek keeps the 10:00 position',
      );
      await unmountPlayer(tester);
      await drainHiveWrites(tester);
    });
  });
}
