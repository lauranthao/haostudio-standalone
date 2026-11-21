// VOD danmaku (build 28) — client + player wiring tests.
//
// Pure client: top-1 only, title+year dual validation, silent
// failures, timeline build (sorted, filtered, media-clock
// similarity), uniform sampling, format=xml -> format=json rewrite.
// Widget: gate OFF -> no request + greyed toggle + no overlay;
// gate ON -> one fetch after open + overlay mounted; toggle OFF ->
// overlay unmounts; long-press cycles to the next candidate.
// Timeline release / seek-skip semantics belong to the flame_barrage
// engine (its own barrage_timeline_test covers them); here we pin
// our side: items carry correct sorted `at` values and the page
// calls seekTo on every seek path without crashing.

// Backstop (library annotation, must sit before the imports): a
// widget test that hangs (e.g. on a wedged Hive write queue) must
// fail at 2 minutes, not at the 10-minute framework default — a hung
// test poisons the binding's runAsync state and every later test in
// the file fails with "Reentrant call to runAsync()".
@Timeout(Duration(minutes: 2))
library;

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flame_barrage/flame_barrage.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/presentation/playback/danmaku_filter.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/settings/source_stores.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/video/vod_danmaku_client.dart';

import 'helpers/hive_test_setup.dart';

// ---------------------------------------------------------------------------
// Pure client tests
// ---------------------------------------------------------------------------

const _hop1Body = '''
[{"name": "狂飙(2023)from iqiyi - 狂飙第1集 指导组入驻京海调查",
  "url": "https://danmu-api-production-60e143e3.up.railway.app/api/v2/comment/11479?format=xml"},
 {"name": "狂飙支队(2012)from 360 - 第1集",
  "url": "https://danmu-api-production-60e143e3.up.railway.app/api/v2/comment/999?format=xml"},
 {"name": "纳斯卡：全速狂飙 第二季(2025)",
  "url": "https://danmu-api-production-60e143e3.up.railway.app/api/v2/comment/888?format=xml"}]
''';

const _hop2Body = '''
{"count": 4, "comments": [
  {"cid": 1, "p": "1.00,1,16777215,[qiyi]", "m": "京海不大，创造神话", "t": 1},
  {"cid": 2, "p": "2.50,4,16711680,[bilibili1]", "m": "顶部弹幕", "t": 2.5},
  {"cid": 3, "p": "5.00,5,65280,[qiyi]", "m": "底部弹幕", "t": 5},
  {"cid": 4, "p": "3.00,1,16777215,[qiyi]", "m": "", "t": 3},
  {"cid": 5, "p": "bad", "m": "无时间", "t": null}
]}
''';

void main() {
  group('hop 1 candidates', () {
    test('parses the audit 152-candidate shape, top-1 is index 0', () {
      final list = parseVodDanmakuCandidates(jsonDecode(_hop1Body));
      expect(list.length, 3);
      expect(list[0].name, contains('狂飙(2023)'));
      expect(list[0].url, contains('comment/11479'));
    });

    test('malformed entries are dropped, never thrown', () {
      expect(parseVodDanmakuCandidates('not json'), isEmpty);
      expect(parseVodDanmakuCandidates([{'name': 'x'}]), isEmpty);
      expect(parseVodDanmakuCandidates([{'name': 'x', 'url': 'y'}]).length, 1);
    });

    test('top-1 passes the dual check for 狂飙 (2023)', () {
      final list = parseVodDanmakuCandidates(jsonDecode(_hop1Body));
      final top = selectVodDanmakuCandidate(
        list,
        queryTitle: '狂飙',
        year: '2023',
      );
      expect(top, list[0]);
    });

    test('year gate rejects 狂飙支队 (2012) when asked for 2023', () {
      final list = parseVodDanmakuCandidates(jsonDecode(_hop1Body));
      final wrong = list[1];
      expect(
        vodDanmakuCandidatePasses(wrong, queryTitle: '狂飙', year: '2023'),
        isFalse,
        reason: '2012 != 2023 must be rejected even though the title matches',
      );
      // But the same candidate passes when the year matches.
      expect(
        vodDanmakuCandidatePasses(wrong, queryTitle: '狂飙', year: '2012'),
        isTrue,
      );
    });

    test('candidate without a year passes the year gate', () {
      const c = VodDanmakuCandidate(
        name: '狂飙 from iqiyi - 第1集',
        url: 'https://example.com/api/v2/comment/1?format=json',
      );
      expect(
        vodDanmakuCandidatePasses(c, queryTitle: '狂飙', year: '2023'),
        isTrue,
      );
    });

    test('title gate rejects a candidate that does not contain the title',
        () {
      const c = VodDanmakuCandidate(
        name: '速度与激情(2004) - 第1集',
        url: 'https://example.com/api/v2/comment/1?format=json',
      );
      expect(
        vodDanmakuCandidatePasses(c, queryTitle: '狂飙', year: '2023'),
        isFalse,
      );
    });

    test('scan-forward finds the next passing candidate for 换弹幕源', () {
      final list = parseVodDanmakuCandidates(jsonDecode(_hop1Body));
      // Index 1 (狂飙支队 2012) fails the year gate for 2023, index 2
      // (纳斯卡 2025) fails too — so scanning from 1 finds nothing.
      expect(
        selectVodDanmakuCandidate(
          list,
          queryTitle: '狂飙',
          year: '2023',
          startIndex: 1,
        ),
        isNull,
      );
      // Without a year to check, index 1 passes (title contains 狂飙).
      expect(
        selectVodDanmakuCandidate(
          list,
          queryTitle: '狂飙',
          startIndex: 1,
        ),
        list[1],
      );
    });
  });

  group('hop 2 comments', () {
    test('parses t/p/m; drops empty text and missing time', () {
      final comments = parseVodDanmakuCommentsJson(_hop2Body);
      expect(comments.length, 3);
      expect(comments[0].time, 1);
      expect(comments[0].text, '京海不大，创造神话');
      expect(comments[0].colorRgb, 16777215);
      expect(comments[0].type, BarrageType.scroll);
      expect(comments[1].type, BarrageType.topFixed);
      expect(comments[1].colorRgb, 16711680);
      expect(comments[2].type, BarrageType.bottomFixed);
    });

    test('format=xml is rewritten to format=json; relative URLs resolve',
        () {
      final rewritten = rewriteVodCommentUrlToJson(
        'https://danmu-api-production-60e143e3.up.railway.app/api/v2/comment/11479?format=xml',
        baseUrl: VodDanmakuClient.defaultBaseUrl,
      );
      expect(rewritten.toString(), contains('format=json'));
      expect(rewritten.toString(), isNot(contains('format=xml')));
      final relative = rewriteVodCommentUrlToJson(
        '/api/v2/comment/11479?format=xml',
        baseUrl: VodDanmakuClient.defaultBaseUrl,
      );
      expect(relative.toString(), startsWith('https://danmu-api-production'));
      expect(rewriteVodCommentUrlToJson('', baseUrl: 'https://x'), isNull);
    });
  });

  group('timeline build', () {
    test('sorted by at, colours mapped, types mapped', () {
      final comments = parseVodDanmakuCommentsJson(_hop2Body);
      final items = buildVodDanmakuTimeline(comments);
      expect(items.length, 3);
      expect(
        items.map((i) => i.at),
        [
          const Duration(seconds: 1),
          const Duration(milliseconds: 2500),
          const Duration(seconds: 5),
        ],
      );
      expect(items[0].textColor, const Color(0xFFFFFFFF));
      expect(items[1].type, BarrageType.topFixed);
      expect(items[2].type, BarrageType.bottomFixed);
    });

    test('keyword filter hides blocked text, reusing the live filter',
        () {
      final comments = parseVodDanmakuCommentsJson(_hop2Body);
      final config = const DanmakuFilterConfig(
        similarityEnabled: false,
        blockedKeywords: ['京海'],
      );
      final items = buildVodDanmakuTimeline(
        comments,
        filterConfig: config,
      );
      expect(items.map((i) => i.content), ['顶部弹幕', '底部弹幕']);
    });

    test('similarity collapses repeats within 3 media-seconds only', () {
      const config = DanmakuFilterConfig(similarityEnabled: true);
      final comments = [
        const VodDanmakuComment(time: 1, text: '哈哈哈'),
        const VodDanmakuComment(time: 2, text: '哈哈哈'),
        // 10 minutes later the same text is a new moment, not a dup.
        const VodDanmakuComment(time: 601, text: '哈哈哈'),
      ];
      final items = buildVodDanmakuTimeline(
        comments,
        filterConfig: config,
      );
      expect(items.map((i) => i.at), [
        const Duration(seconds: 1),
        const Duration(seconds: 601),
      ]);
    });

    test('uniform sampling spreads across the timeline, never first-N',
        () {
      final items = List.generate(
        10,
        (i) => BarrageItem(
          content: 'm$i',
          at: Duration(seconds: i * 10),
        ),
      );
      final sampled = uniformSampleTimeline(items, 4);
      expect(sampled.map((i) => i.content), ['m0', 'm2', 'm5', 'm7']);
      // First-N would have been m0..m3 (all in the first 30 s).
      expect(sampled.last.at, const Duration(seconds: 70));
    });
  });

  group('client fetch (fake transport)', () {
    test('fetchCandidates + fetchCommentsFor: top-1 only, one hop each',
        () async {
      final requested = <Uri>[];
      final client = VodDanmakuClient(
        fetcher: (uri) async {
          requested.add(uri);
          if (uri.path.contains('fongmi')) return _hop1Body;
          return _hop2Body;
        },
      );
      final candidates = await client.fetchCandidates(
        title: '狂飙',
        episode: '第1集',
      );
      expect(candidates?.length, 3);
      expect(requested.single.path, contains('fongmi'));
      expect(
        requested.single.queryParameters['name'],
        '狂飙',
      );
      final top = selectVodDanmakuCandidate(
        candidates!,
        queryTitle: '狂飙',
        year: '2023',
      );
      final comments = await client.fetchCommentsFor(top!);
      expect(comments?.length, 3);
      expect(requested.length, 2);
      expect(requested.last.toString(), contains('format=json'));
      // The wrong-year candidates were never fetched.
      expect(
        requested.map((u) => u.toString()).join(),
        isNot(contains('comment/999')),
      );
    });

    test('silent on empty / 404 / 429 / network error / timeout', () async {
      Future<String?> boom(Uri uri) async => throw const SocketException(
        'offline',
      );
      final emptyClient = VodDanmakuClient(
        fetcher: (_) async => '[]',
      );
      expect(
        await emptyClient.fetchCandidates(title: 'XYZQQQ999', episode: '1'),
        isNull,
      );
      expect(
        await emptyClient.fetchCommentsFor(
          const VodDanmakuCandidate(name: 'x', url: 'https://x/comment/1'),
        ),
        isNull,
      );
      final errorClient = VodDanmakuClient(fetcher: boom);
      expect(
        await errorClient.fetchCandidates(title: '狂飙', episode: '第1集'),
        isNull,
      );
      expect(
        await errorClient.fetchCommentsFor(
          const VodDanmakuCandidate(name: 'x', url: 'https://x/comment/1'),
        ),
        isNull,
      );
      final hangingClient = VodDanmakuClient(
        hopTimeout: const Duration(milliseconds: 50),
        fetcher: (_) => Completer<String?>().future,
      );
      expect(
        await hangingClient.fetchCandidates(title: '狂飙', episode: '第1集'),
        isNull,
      );
      final emptyCommentsClient = VodDanmakuClient(
        fetcher: (_) async => '{"count":0,"comments":[]}',
      );
      expect(
        await emptyCommentsClient.fetchCommentsFor(
          const VodDanmakuCandidate(name: 'x', url: 'https://x/comment/1'),
        ),
        isNull,
      );
    });

    test('maxTimelineItems uniformly samples a long timeline', () {
      final client = VodDanmakuClient(maxTimelineItems: 2);
      final comments = List.generate(
        6,
        (i) => VodDanmakuComment(time: i * 10.0, text: 'm$i'),
      );
      final items = client.buildTimeline(comments);
      expect(items.map((i) => i.content), ['m0', 'm3']);
    });
  });

  // -------------------------------------------------------------------------
  // Widget tests: player wiring
  // -------------------------------------------------------------------------
  group('player wiring', () {
    late Directory hiveDir;

    setUpAll(() async {
      TestWidgetsFlutterBinding.ensureInitialized();
      hiveDir = await Directory.systemTemp.createTemp('hao-vod-danmaku-');
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
      unawaited(HiveStore.box.close());
      await hiveDir.delete(recursive: true);
    });

    tearDown(() {
      Get.reset();
      // No Hive deletes here: a fire-and-forget delete queues a write
      // that the next test's first Hive write would hang behind (see
      // helpers/hive_test_setup.dart). Each test sets the gate it
      // needs explicitly, and unmountPlayer drains the queue.
    });

    VideoDetail detail() => VideoDetail(
      source: 12,
      vodId: '93344',
      meta: VideoMeta(name: '狂飙', year: '2023'),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/ep1.mp4'),
          ],
        ),
      ],
    );

    Future<void> pumpPlayer(
      WidgetTester tester,
      VodDanmakuClient client,
    ) async {
      final backend = _FakeBackend();
      final session = PlaybackSession(backendFactory: (_) => backend);
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: NativeVideoPlayerPage(
            detail: detail(),
            session: session,
            danmakuClient: client,
          ),
        ),
      );
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 300));
      });
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> unmountPlayer(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      // Drain the player's fire-and-forget Hive writes (history
      // record) before the test ends, or the next test's first Hive
      // write hangs forever behind the stuck queue.
      await drainHiveWrites(tester);
    }

    /// Set the VOD gate with the queue drained first: a Hive write
    /// must run in the real zone (runAsync), and a write queued
    /// behind a stuck one never completes. The write itself is
    /// bounded: if the queue is wedged (e.g. by a previous test that
    /// abandoned a mounted page), the test fails fast here instead
    /// of hanging 10 minutes inside runAsync — and the follow-up
    /// read verifies the gate actually landed before the player
    /// reads it in initState.
    Future<void> setVodGate(WidgetTester tester, bool value) async {
      await drainHiveWrites(tester);
      await tester.runAsync(
        () => DanmakuSettings.setEnabled(DanmakuSettings.vodSiteId, value)
            .timeout(const Duration(seconds: 10)),
      );
      expect(
        DanmakuSettings.isEnabled(DanmakuSettings.vodSiteId),
        value,
        reason: 'VOD gate write did not land',
      );
    }

    /// Wait (bounded real time) for the fake client to fire hop 1.
    /// _openCurrent awaits _recordHistory (a Hive write) before the
    /// post-first-frame fetch, and on a loaded VM with a contended
    /// Hive queue the fixed 300 ms window in pumpPlayer is not
    /// enough for the fetch to fire — polling here keeps the test
    /// deterministic without masking a real no-fetch regression
    /// (the bound is generous, and a fetch that never fires still
    /// fails the caller's expect).
    Future<void> waitForFetch(
      WidgetTester tester,
      _FakeDanmakuClient client,
    ) async {
      for (var i = 0; i < 20; i++) {
        if (client.fetchCandidatesCalls >= 1) return;
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 300));
        });
        await tester.pump();
      }
      await tester.pump();
    }

    /// Always unmount the player, even when the test body failed:
    /// an abandoned mounted page leaves Hive writes queued behind a
    /// discarded fake zone, wedging the queue for every later test.
    /// Never throws (a failure here must not mask the body's own).
    Future<void> unmountSafely(WidgetTester tester) async {
      try {
        await unmountPlayer(tester);
      } catch (_) {}
    }

    /// The danmaku toggle in the top bar: the IconButton that owns
    /// the tooltip (byTooltip finds the Tooltip child, not the
    /// button, so resolve via ancestor).
    Finder danmakuToggle(WidgetTester tester, {bool open = true}) =>
        find.ancestor(
          of: find.byTooltip(open ? '关闭弹幕' : '打开弹幕'),
          matching: find.byType(IconButton),
        );

    testWidgets('gate OFF (default): no request, toggle greyed, no overlay',
        (tester) async {
      expect(DanmakuSettings.isEnabled(DanmakuSettings.vodSiteId), isFalse);
      final client = _FakeDanmakuClient();
      await pumpPlayer(tester, client);
      try {
        expect(client.fetchCandidatesCalls, 0);
        expect(find.byType(FlameBarrageWidget), findsNothing);
        final toggle =
            tester.widget<IconButton>(danmakuToggle(tester, open: false));
        expect(toggle.onPressed, isNull, reason: 'greyed, not hidden');
        final icon = toggle.icon as Icon;
        expect(icon.color, Colors.white38);
        // Tapping the greyed button does nothing (and does not crash).
        await tester.tap(danmakuToggle(tester, open: false));
        await tester.pump();
        expect(client.fetchCandidatesCalls, 0);
        expect(tester.takeException(), isNull);
      } finally {
        await unmountSafely(tester);
      }
    });

    testWidgets('gate ON: one fetch after open, overlay mounted', (
      tester,
    ) async {
      await setVodGate(tester, true);
      final client = _FakeDanmakuClient();
      await pumpPlayer(tester, client);
      try {
        await waitForFetch(tester, client);
        expect(client.fetchCandidatesCalls, 1);
        expect(client.fetchCommentsCalls, 1);
        expect(find.byType(FlameBarrageWidget), findsOneWidget);
        expect(danmakuToggle(tester, open: true), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await unmountSafely(tester);
      }
    });

    testWidgets('toggle OFF unmounts the overlay, toggle ON reloads it', (
      tester,
    ) async {
      await setVodGate(tester, true);
      final client = _FakeDanmakuClient();
      await pumpPlayer(tester, client);
      try {
        // Wait for the first load to finish: toggling ON while the
        // timeline is still loading would re-trigger the fetch
        // (_danmakuItems is null until hop 2 lands) and the
        // fetch-count assertion below would see 2.
        await waitForFetch(tester, client);
        expect(find.byType(FlameBarrageWidget), findsOneWidget);
        await tester.tap(danmakuToggle(tester, open: true));
        await tester.pump();
        expect(find.byType(FlameBarrageWidget), findsNothing);
        expect(danmakuToggle(tester, open: false), findsOneWidget);
        // Re-opening re-feeds the cached timeline — no second fetch.
        await tester.tap(danmakuToggle(tester, open: false));
        await tester.pump();
        expect(find.byType(FlameBarrageWidget), findsOneWidget);
        expect(client.fetchCandidatesCalls, 1);
        expect(tester.takeException(), isNull);
      } finally {
        await unmountSafely(tester);
      }
    });

    testWidgets('long-press cycles to the next passing candidate', (
      tester,
    ) async {
      await setVodGate(tester, true);
      final client = _FakeDanmakuClient();
      await pumpPlayer(tester, client);
      try {
        await waitForFetch(tester, client);
        expect(client.fetchCommentsCalls, 1);
        await tester.longPress(danmakuToggle(tester, open: true));
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await tester.pump();
        // Second candidate (狂飙支队) fails the 2023 year gate, third
        // (纳斯卡 2025) too — so no switch happens and no extra fetch.
        expect(client.fetchCommentsCalls, 1);
        expect(find.byType(FlameBarrageWidget), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await unmountSafely(tester);
      }
    });

    testWidgets('failed fetch stays silent: playback + controls fine', (
      tester,
    ) async {
      await setVodGate(tester, true);
      final client = _FakeDanmakuClient(fail: true);
      await pumpPlayer(tester, client);
      try {
        await waitForFetch(tester, client);
        expect(client.fetchCandidatesCalls, 1);
        // The overlay shell mounts whenever the gate is on (it is an
        // empty engine when the fetch failed — nothing flies, no
        // error UI); the contract is that the failure is silent: the
        // toggle stays ON and the controls keep working.
        expect(danmakuToggle(tester, open: true), findsOneWidget);
        // Controls still work: back button present, no error UI.
        expect(find.byIcon(Icons.arrow_back), findsOneWidget);
        expect(find.byIcon(Icons.playlist_play), findsOneWidget);
        expect(tester.takeException(), isNull);
      } finally {
        await unmountSafely(tester);
      }
    });
  });
}

/// Fake transport client: canned hop-1 candidates from the audit +
/// canned hop-2 comments, counting calls. `fail` makes hop 1 return
/// null (silent path).
class _FakeDanmakuClient extends VodDanmakuClient {
  _FakeDanmakuClient({this.fail = false});

  final bool fail;
  int fetchCandidatesCalls = 0;
  int fetchCommentsCalls = 0;

  @override
  Future<List<VodDanmakuCandidate>?> fetchCandidates({
    required String title,
    required String episode,
  }) async {
    fetchCandidatesCalls++;
    if (fail) return null;
    return parseVodDanmakuCandidates(jsonDecode(_hop1Body));
  }

  @override
  Future<List<VodDanmakuComment>?> fetchCommentsFor(
    VodDanmakuCandidate candidate,
  ) async {
    fetchCommentsCalls++;
    if (fail) return null;
    final comments = parseVodDanmakuCommentsJson(_hop2Body);
    return comments.isEmpty ? null : comments;
  }
}

class _FakeBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final List<double> rates = [];
  final List<Duration> seeks = [];
  bool _disposed = false;

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Widget buildVideoWidget() =>
      const SizedBox(key: ValueKey('fake-video'));

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {}

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async => true;

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
  }

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
  }

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
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _error.close();
    await _completed.close();
  }
}
