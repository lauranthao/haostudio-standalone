// Quality / line state-machine end-to-end tests (Flutter v1.0.4).
//
// Proves the switching behaviour from the live-site contract
// (lib/shared/platforms/live_site.dart) and the Pure Live study §2.8/§2.9:
// - Line switch opens playUrls[newIndex] directly, NO network request.
// - Quality switch re-parses; a server receipt != request corrects the UI
//   to the receipt quality + toast (Bilibili guest 10000 -> 250; Douyu
//   rate is an opaque id, never sorted).
// - Identical URLs after a quality switch -> toast "清晰度流未变化", abort.
// - Huya recovery order: next line -> fresh re-parse -> 60 s throttle ->
//   10 s fallback; prefetch at the lease refreshAt (~100 s) fetches and
//   HOLDS a fresh plan — never switches the playing stream; recovery
//   spends the held plan first (attempt 0), then live re-parses
//   (attempt 1); lines identified by URL, not index (a refresh can turn
//   a TX FLV line into TX HLS).
// - Kernel ladder: FLV never enters AVPlayer; failure walks the ladder
//   (mpv -> ijk -> avplayer by capability + preference); a manual engine
//   switch does not lose the stream.
// - Playback headers (Pure Live PlaybackHeaderResolver): every open
//   carries UA + Origin + Referer for Huya/Douyu — without them
//   Huya's CDN cuts the FLV after ~7 s (measured with ffmpeg).
// - Stall/failure timing: 4 s stall hint / 12 s failure in PlaybackSession.
//
// Fakes only — no network. Canned resolutions carry refreshAt/invalidAt
// lease times to test the lease logic.

import 'dart:async';
import 'dart:io';

import 'package:fake_async/fake_async.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/player/kernel/player_kernel.dart';
import 'package:standalone/core/player/kernel/recovery_ladder.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/features/live/live_recovery.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/shared/platforms/douyu/douyu_utils.dart';
import 'package:standalone/shared/platforms/huya/huya_request_params.dart';
import 'package:standalone/shared/platforms/live_site.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-quality-test-');
    // HiveStore.init() goes through path_provider; point it at a temp
    // dir so PlaybackSession / LiveRoomPage can use Hive in tests.
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    // Point the store at a MEMORY-backed box for the whole file: a Hive
    // file write issued inside a widget test's fake-async zone never
    // completes within that test (its RandomAccessFile I/O completion
    // needs a fake-microtask flush that the post-test drain loop only
    // performs while a runAsync task is pending), so the room page's
    // fire-and-forget breadcrumb writes wedge hive_ce's serialized
    // write lock and the NEXT test's Hive put hangs forever. The memory
    // backend's writeFrames is Future.value() — no file I/O, no wedge.
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

  tearDown(() async {
    Get.reset();
    // Isolate the persisted engine preference: PlaybackSession.switchEngine
    // persists the choice to Hive (videoPlayerKey), so a test that switches
    // to IJK would otherwise leak fijk into every later test in this file
    // (the 4 session tests that assume MPV first all failed on the leaked
    // preference). Reset to the default ('mpv') after every test.
    await HiveStore.put(HiveKeys.videoPlayerKey, 'mpv');
  });

  group('LiveRecovery lease + prefetch (Huya)', () {
    test('prefetch holds a fresh plan without switching the stream', () {
      fakeAsync((async) {
        final site = _FakeSite();
        final recovery = LiveRecovery(site: site, room: _room());
        // Playing the OLD lines; the lease refreshes at now + 100 s.
        final issued = DateTime.now();
        recovery.lines = const [
          'https://tx.flv.huya.com/src/1?wsSecret=OLD',
          'https://al.flv.huya.com/src/1?wsSecret=OLD',
        ];
        recovery.issuedAt = issued;
        recovery.refreshAt = issued.add(const Duration(seconds: 100));
        recovery.invalidAt = issued.add(const Duration(seconds: 125));
        recovery.schedulePrefetch();
        // The hold fetch returns NEW signatures.
        site.recoveryUrls = const [
          'https://tx.flv.huya.com/src/1?wsSecret=NEW',
          'https://al.flv.huya.com/src/1?wsSecret=NEW',
        ];
        async.elapse(const Duration(seconds: 99));
        expect(site.recoveryCalls, 0);
        async.elapse(const Duration(seconds: 1));
        // One more second: the timer fired at the boundary, and the
        // async hold chain (fetch -> store) needs the turns to settle.
        async.elapse(const Duration(seconds: 1));
        // Fetched once — and the playing lines did NOT change: the
        // stream was never switched, the plan is only held.
        expect(site.recoveryCalls, 1);
        expect(
          recovery.lines,
          const [
            'https://tx.flv.huya.com/src/1?wsSecret=OLD',
            'https://al.flv.huya.com/src/1?wsSecret=OLD',
          ],
        );
        expect(recovery.currentUrl, contains('wsSecret=OLD'));
      });
    });

    test('recovery takes the held plan first (attempt 0)', () {
      fakeAsync((async) {
        final site = _FakeSite();
        final recovery = LiveRecovery(site: site, room: _room());
        final issued = DateTime.now();
        recovery.lines = const [
          'https://tx.flv.huya.com/src/1?wsSecret=OLD',
          'https://al.flv.huya.com/src/1?wsSecret=OLD',
        ];
        recovery.issuedAt = issued;
        recovery.refreshAt = issued.add(const Duration(seconds: 100));
        recovery.invalidAt = issued.add(const Duration(seconds: 125));
        recovery.schedulePrefetch();
        site.recoveryUrls = const [
          'https://tx.flv.huya.com/src/1?wsSecret=NEW',
          'https://al.flv.huya.com/src/1?wsSecret=NEW',
        ];
        async.elapse(const Duration(seconds: 101));
        expect(site.recoveryCalls, 1);
        // No live re-parse was needed: the held plan is spent directly.
        final held = recovery.takeHeld();
        expect(held, isNotNull);
        expect(held!.urls, site.recoveryUrls);
        expect(site.recoveryCalls, 1);
        // Installed like a live re-parse: same line matched by URL
        // identity, new lease armed.
        expect(recovery.lines, site.recoveryUrls);
        expect(recovery.currentUrl, contains('wsSecret=NEW'));
        // One-shot: a second take finds nothing held.
        expect(recovery.takeHeld(), isNull);
      });
    });

    test('expired held plan is never served', () {
      fakeAsync((async) {
        final site = _FakeSite();
        final recovery = LiveRecovery(site: site, room: _room());
        final issued = DateTime.now();
        recovery.lines = const [
          'https://tx.flv.huya.com/src/1?wsSecret=OLD',
        ];
        recovery.issuedAt = issued;
        recovery.refreshAt = issued.add(const Duration(seconds: 100));
        recovery.invalidAt = issued.add(const Duration(seconds: 125));
        recovery.schedulePrefetch();
        // The hold fetch returns a plan already past its hard expiry.
        site.recoveryResolution = LivePlayUrlResolution(
          urls: const ['https://tx.flv.huya.com/src/1?wsSecret=NEW'],
          issuedAt: DateTime.now(),
          refreshAt: DateTime.now().add(const Duration(seconds: 100)),
          invalidAt: DateTime.now().subtract(const Duration(seconds: 1)),
          streamFacts: const [LiveStreamFacts(format: 'flv')],
        );
        async.elapse(const Duration(seconds: 101));
        expect(site.recoveryCalls, 1);
        expect(recovery.takeHeld(), isNull);
        expect(
          recovery.lines,
          const ['https://tx.flv.huya.com/src/1?wsSecret=OLD'],
        );
      });
    });

    test('hold fetch does not stamp the recovery throttle', () {
      fakeAsync((async) {
        var now = DateTime.now();
        final site = _FakeSite();
        final recovery =
            LiveRecovery(site: site, room: _room(), clock: () => now);
        // fetchFresh at T0 stamps the 60 s throttle and arms the hold
        // at the resolution's refreshAt (T0 + 100 s).
        site.recoveryResolution = LivePlayUrlResolution(
          urls: const ['https://tx.flv.huya.com/src/1?wsSecret=NEW1'],
          issuedAt: now,
          refreshAt: now.add(const Duration(seconds: 100)),
          invalidAt: now.add(const Duration(seconds: 125)),
          streamFacts: const [LiveStreamFacts(format: 'flv')],
        );
        LivePlayUrlResolution? first;
        unawaited(recovery.fetchFresh().then((r) => first = r));
        async.elapse(const Duration(milliseconds: 100));
        expect(first, isNotNull);
        expect(site.recoveryCalls, 1);
        // 100 s later the hold fetch runs (a second site call). Its
        // plan carries a far-future refreshAt so the chained hold timer
        // stays far away and cannot fire inside this test.
        site.recoveryResolution = LivePlayUrlResolution(
          urls: const ['https://tx.flv.huya.com/src/1?wsSecret=NEW2'],
          issuedAt: now,
          refreshAt: now.add(const Duration(seconds: 3600)),
          invalidAt: now.add(const Duration(seconds: 3625)),
          streamFacts: const [LiveStreamFacts(format: 'flv')],
        );
        now = now.add(const Duration(seconds: 100));
        async.elapse(const Duration(seconds: 101));
        expect(site.recoveryCalls, 2);
        // 101 s after the first fetch the 60 s throttle has expired —
        // unless the hold stamped it at T0 + 100 s (then only 1 s
        // passed and this would be throttled to null).
        now = now.add(const Duration(seconds: 1));
        LivePlayUrlResolution? second;
        unawaited(recovery.fetchFresh().then((r) => second = r));
        async.elapse(const Duration(milliseconds: 100));
        expect(second, isNotNull);
        expect(site.recoveryCalls, 3);
      });
    });

    test('fetchFresh times out after 10 s and keeps the old lines', () {
      fakeAsync((async) {
        final site = _FakeSite()..recoveryNeverCompletes = true;
        final recovery = LiveRecovery(site: site, room: _room());
        recovery.lines = const ['https://tx.flv.huya.com/src/1'];
        LivePlayUrlResolution? result;
        var done = false;
        unawaited(
          recovery.fetchFresh().then((r) {
            result = r;
            done = true;
          }),
        );
        async.elapse(const Duration(seconds: 9));
        expect(done, isFalse);
        async.elapse(const Duration(seconds: 1));
        expect(done, isTrue);
        expect(result, isNull);
        expect(
          recovery.lines,
          const ['https://tx.flv.huya.com/src/1'],
        );
      });
    });

    test('isExpired at ~125 s after issue', () {
      final recovery = LiveRecovery(site: _FakeSite(), room: _room());
      recovery.issuedAt =
          DateTime.now().subtract(const Duration(seconds: 124));
      expect(recovery.isExpired, isFalse);
      recovery.issuedAt =
          DateTime.now().subtract(const Duration(seconds: 126));
      expect(recovery.isExpired, isTrue);
    });

    test('fetchFresh carries refreshAt/invalidAt lease times', () async {
      final site = _FakeSite();
      final issued = DateTime.now();
      site.recoveryResolution = LivePlayUrlResolution(
        urls: const ['https://tx.flv.huya.com/src/1?wsSecret=NEW'],
        issuedAt: issued,
        refreshAt: issued.add(const Duration(seconds: 100)),
        invalidAt: issued.add(const Duration(seconds: 125)),
        streamFacts: const [LiveStreamFacts(format: 'flv')],
      );
      final recovery = LiveRecovery(site: site, room: _room());
      final res = await recovery.fetchFresh();
      expect(res?.refreshAt, issued.add(const Duration(seconds: 100)));
      expect(res?.invalidAt, issued.add(const Duration(seconds: 125)));
      expect(recovery.issuedAt, issued);
    });

    test('refresh can turn a TX FLV line into TX HLS; identity follows the URL',
        () async {
      final site = _FakeSite();
      final recovery = LiveRecovery(site: site, room: _room());
      // Playing the TX FLV line (index 0); AL FLV at index 1.
      recovery.lines = const [
        'https://tx.flv.huya.com/src/1.flv?wsSecret=OLD',
        'https://al.flv.huya.com/src/1.flv?wsSecret=OLD',
      ];
      recovery.facts = const [
        LiveStreamFacts(format: 'flv'),
        LiveStreamFacts(format: 'flv'),
      ];
      recovery.currentLineIndex = 0;
      // Refresh re-orders AND changes the TX line's format: TX HLS is
      // now at index 1, AL FLV at index 0.
      site.recoveryUrls = const [
        'https://al.flv.huya.com/src/1.flv?wsSecret=NEW',
        'https://tx.hls.huya.com/src/1.m3u8?wsSecret=NEW',
      ];
      site.recoveryFacts = const [
        LiveStreamFacts(format: 'flv'),
        LiveStreamFacts(format: 'hls'),
      ];
      final res = await recovery.fetchFresh();
      expect(res, isNotNull);
      // Same TX line (CDN + media path), now HLS at index 1 — not the
      // old index 0 (which is now the AL line).
      expect(recovery.currentLineIndex, 1);
      expect(
        recovery.currentUrl,
        'https://tx.hls.huya.com/src/1.m3u8?wsSecret=NEW',
      );
      // The session must be told the NEW format, not the old FLV fact.
      expect(recovery.factsFor(1).format, 'hls');
      expect(recovery.factsFor(0).format, 'flv');
    });
  });

  group('Kernel ladder: capability + preference (study §1.2)', () {
    test('FLV never enters AVPlayer even when AVPlayer is preferred', () {
      final c = candidatesFor(
        url: 'http://al-game.flv.huya.com/src',
        isLive: true,
        preferred: PlayerEngine.exo,
      );
      expect(c, isNot(contains(PlayerEngine.exo)));
      expect(c.first, PlayerEngine.mediaKit);
    });

    test('HLS with AVPlayer preferred puts AVPlayer first', () {
      final c = candidatesFor(
        url: 'https://tx.huya.com/src/1.m3u8',
        isLive: true,
        preferred: PlayerEngine.exo,
      );
      expect(c.first, PlayerEngine.exo);
      expect(c.length, 3);
    });

    test('ladder walks mpv -> ijk -> avplayer on failure, in order', () async {
      final tried = <PlayerEngine>[];
      final ladder = RecoveryLadder(
        engines: candidatesFor(
          url: 'https://example.com/live.m3u8',
          isLive: true,
        ),
        urls: const ['https://example.com/live.m3u8'],
        attempt: ({required engine, required url}) async {
          tried.add(engine);
          return engine == PlayerEngine.exo;
        },
        retryDelays: const [],
      );
      final won = await ladder.run();
      expect(won?.engine, PlayerEngine.exo);
      expect(tried, [
        PlayerEngine.mediaKit,
        PlayerEngine.fijk,
        PlayerEngine.exo,
      ]);
    });

    test('ladder never offers AVPlayer an FLV URL', () async {
      final tried = <PlayerEngine>[];
      final ladder = RecoveryLadder(
        engines: candidatesFor(
          url: 'http://al-game.flv.huya.com/src',
          isLive: true,
          preferred: PlayerEngine.exo,
        ),
        urls: const ['http://al-game.flv.huya.com/src'],
        attempt: ({required engine, required url}) async {
          tried.add(engine);
          return false;
        },
        retryDelays: const [],
      );
      expect(await ladder.run(), isNull);
      expect(tried, [PlayerEngine.mediaKit, PlayerEngine.fijk]);
    });
  });

  group('PlaybackSession with fake backends', () {
    late _BackendLog log;
    late Map<PlayerEngine, _FakeBackendConfig> configs;

    setUp(() {
      log = _BackendLog();
      configs = {
        for (final e in PlayerEngine.values) e: _FakeBackendConfig(),
      };
    });

    PlaybackSession session() => PlaybackSession(
          backendFactory: (engine) =>
              _FakeBackend(engine: engine, log: log, config: configs[engine]!),
        );

    test('open walks the ladder: mpv fails -> ijk wins', () async {
      configs[PlayerEngine.mediaKit]!.firstFrameSucceeds = false;
      final s = session();
      final ok = await s.open(
        url: 'https://example.com/live.m3u8',
        isLive: true,
      );
      expect(ok, isTrue);
      expect(s.status, PlaybackStatus.playing);
      expect(s.activeEngine, PlayerEngine.fijk);
      expect(
        log.opens.map((o) => o.engine).toList(),
        [PlayerEngine.mediaKit, PlayerEngine.fijk],
      );
      await s.dispose();
    });

    test('FLV: AVPlayer is never attempted, even after mpv+ijk fail',
        () async {
      configs[PlayerEngine.mediaKit]!.firstFrameSucceeds = false;
      configs[PlayerEngine.fijk]!.firstFrameSucceeds = false;
      final s = session();
      final ok = await s.open(
        url: 'http://al-game.flv.huya.com/src',
        isLive: true,
      );
      expect(ok, isFalse);
      expect(s.status, PlaybackStatus.error);
      expect(
        log.opens.map((o) => o.engine).toList(),
        [PlayerEngine.mediaKit, PlayerEngine.fijk],
      );
      expect(
        log.opens.map((o) => o.engine),
        isNot(contains(PlayerEngine.exo)),
      );
      await s.dispose();
    });

    test('ladder exhausted on live -> fresh re-parse, never the dead URL',
        () async {
      for (final c in configs.values) {
        c.firstFrameSucceeds = false;
      }
      const dead = 'https://tx.flv.huya.com/src/1?wsSecret=OLD';
      const fresh = 'https://tx.flv.huya.com/src/1?wsSecret=NEW';
      var refreshCalls = 0;
      final s = session();
      final ok = await s.open(
        url: dead,
        isLive: true,
        refreshUrls: () async {
          refreshCalls++;
          return [fresh];
        },
      );
      expect(ok, isFalse); // fresh URL also fails (all backends fail)
      // Two fresh fetches: the initial open re-parses once, and the
      // fresh open re-parses once more before the freshRounds bound
      // stops it (the re-parse keeps returning the same dead URL).
      expect(refreshCalls, 2);
      // Dead URL attempted once per capable engine, then the fresh URL
      // once per capable engine — the dead URL is never replayed.
      final deadAttempts =
          log.opens.where((o) => o.url == dead).length;
      final freshAttempts =
          log.opens.where((o) => o.url == fresh).length;
      expect(deadAttempts, 2); // mpv + ijk (FLV: no AVPlayer)
      expect(freshAttempts, 2);
      await s.dispose();
    });

    test('fresh re-parse is bounded: at most 2 fresh rounds', () async {
      for (final c in configs.values) {
        c.firstFrameSucceeds = false;
      }
      var refreshCalls = 0;
      final s = session();
      final ok = await s.open(
        url: 'https://example.com/dead0.m3u8',
        isLive: true,
        refreshUrls: () async {
          refreshCalls++;
          return ['https://example.com/dead$refreshCalls.m3u8'];
        },
      );
      expect(ok, isFalse);
      expect(refreshCalls, 2);
      await s.dispose();
    });

    test('fresh re-parse returning the dead URL does not loop', () async {
      for (final c in configs.values) {
        c.firstFrameSucceeds = false;
      }
      const dead = 'https://example.com/dead.m3u8';
      var refreshCalls = 0;
      final s = session();
      final ok = await s.open(
        url: dead,
        isLive: true,
        refreshUrls: () async {
          refreshCalls++;
          return [dead]; // same URL back: must not re-open forever
        },
      );
      expect(ok, isFalse);
      expect(refreshCalls, 1);
      expect(log.opens.where((o) => o.url == dead).length, 3);
      await s.dispose();
    });

    test('manual engine switch keeps the stream (same URL, new engine)',
        () async {
      final s = session();
      expect(
        await s.open(url: 'https://example.com/live.m3u8', isLive: true),
        isTrue,
      );
      expect(s.activeEngine, PlayerEngine.mediaKit);
      await s.switchEngine(PlayerEngine.fijk);
      expect(s.status, PlaybackStatus.playing);
      expect(s.activeEngine, PlayerEngine.fijk);
      expect(s.currentUrl, 'https://example.com/live.m3u8');
      expect(log.opens.last.url, 'https://example.com/live.m3u8');
      expect(log.opens.last.engine, PlayerEngine.fijk);
      // The old mpv backend was disposed exactly once on the swap.
      expect(log.disposes[PlayerEngine.mediaKit], 1);
      await s.dispose();
    });

    test('manual switch to an engine that cannot play FLV falls back',
        () async {
      final s = session();
      expect(
        await s.open(url: 'http://al-game.flv.huya.com/src', isLive: true),
        isTrue,
      );
      expect(s.activeEngine, PlayerEngine.mediaKit);
      await s.switchEngine(PlayerEngine.exo); // AVPlayer cannot play FLV
      expect(s.status, PlaybackStatus.playing);
      expect(s.activeEngine, isNot(PlayerEngine.exo));
      expect(s.currentUrl, 'http://al-game.flv.huya.com/src');
      expect(
        log.opens.map((o) => o.engine),
        isNot(contains(PlayerEngine.exo)),
      );
      await s.dispose();
    });

    test('live EOF is an error, not completion', () async {
      final s = session();
      expect(
        await s.open(url: 'https://example.com/live.m3u8', isLive: true),
        isTrue,
      );
      final errors = <String>[];
      s.onError.listen(errors.add);
      log.backends.last.emitCompleted();
      // Stream delivery is a microtask; flush it (no real clock here).
      await Future<void>(() {});
      await Future<void>(() {});
      expect(s.status, PlaybackStatus.error);
      expect(errors, contains('live_source_completed'));
      await s.dispose();
    });

    test('VOD EOF is completion', () async {
      final s = session();
      expect(
        await s.open(url: 'https://example.com/vod.mp4', isLive: false),
        isTrue,
      );
      log.backends.last.emitCompleted();
      await Future<void>(() {});
      await Future<void>(() {});
      expect(s.status, PlaybackStatus.completed);
      await s.dispose();
    });

    test('dispose releases the backend and its timers (real clock)', () async {
      final s = session();
      expect(
        await s.open(url: 'https://example.com/live.m3u8', isLive: true),
        isTrue,
      );
      expect(log.backends.length, 1);
      expect(log.backends.single.isDisposed, isFalse);
      await s.dispose();
      expect(log.disposes[PlayerEngine.mediaKit], 1);
      expect(log.backends.single.isDisposed, isTrue);
      expect(log.backends.single.isTickerCancelled, isTrue);
    });

    // Plain test() runs under FakeAsync, so the 4 s / 12 s health watch
    // is exercised on the REAL clock via tester.runAsync.
    testWidgets('4 s stall -> hint; 12 s stall -> failure (real clock)',
        (tester) async {
      configs[PlayerEngine.mediaKit]!.emitPositions = false;
      final s = session();
      await tester.runAsync(() async {
        expect(
          await s.open(url: 'https://example.com/live.m3u8', isLive: true),
          isTrue,
        );
        var notices = 0;
        s.onStallNotice.listen((_) => notices++);
        await Future<void>.delayed(const Duration(seconds: 5));
        expect(notices, 1);
        expect(s.status, PlaybackStatus.playing);
        // Pure Live 5.6.5 bufferingStall is 12 s (the failure point
        // for a moved-then-stalled live source): still playing
        // at 10 s, failed at 13 s.
        await Future<void>.delayed(const Duration(seconds: 5));
        expect(s.status, PlaybackStatus.playing);
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(s.status, PlaybackStatus.error);
        await s.dispose();
      });
    }, timeout: const Timeout(Duration(seconds: 30)));

    testWidgets('position movement resets the stall clock',
        (tester) async {
      configs[PlayerEngine.mediaKit]!.emitPositions = false;
      final s = session();
      await tester.runAsync(() async {
        expect(
          await s.open(url: 'https://example.com/live.m3u8', isLive: true),
          isTrue,
        );
        var notices = 0;
        s.onStallNotice.listen((_) => notices++);
        // Position moves at ~3 s and ~7 s: no hint by 10 s.
        await Future<void>.delayed(const Duration(seconds: 3));
        log.backends.last.emitPosition(const Duration(seconds: 3));
        await Future<void>.delayed(const Duration(seconds: 4));
        log.backends.last.emitPosition(const Duration(seconds: 7));
        await Future<void>.delayed(const Duration(seconds: 3));
        expect(notices, 0);
        expect(s.status, PlaybackStatus.playing);
        // Then it stalls for real: hint ~4 s after the last movement.
        await Future<void>.delayed(const Duration(seconds: 2));
        expect(notices, 1);
        await s.dispose();
      });
    }, timeout: const Timeout(Duration(seconds: 30)));
  });

  group('LiveRoomPage: quality / line switching (widget)', () {
    /// Let real async work drain: PlaybackSession / LiveRoomPage await
    /// Hive writes, and a widget test's fake clock never drains real
    /// async I/O on its own. Without this, _loadRoom stalls at its first
    /// breadcrumb write and the room never resolves. The runAsync is
    /// load-bearing in a second way too: the room fires fire-and-forget
    /// Hive puts (breadcrumbs) inside the fake zone, and only a pending
    /// runAsync task makes the post-test drain flush them — without it
    /// they wedge hive_ce's write lock and the NEXT test's awaited Hive
    /// put hangs (proven 09:25/09:32: fake-only settle wedged the run
    /// for 7+ min). Do NOT remove runAsync again.
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<void> pumpRoom(
      WidgetTester tester,
      _FakeSite site,
      _BackendLog log,
      Map<PlayerEngine, _FakeBackendConfig> configs, {
      String platform = 'huya',
    }) async {
      // Phone-tall viewport: the room Column (16:9 video + info +
      // quality/line rows + danmaku) is ~600 px tall and overflows the
      // default 800x600 test surface, pushing the chip rows off-screen.
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      // Isolate each test from the persisted quality preference: the
      // quality-switch test saves preferResolution='高清' to Hive, and
      // _loadRoom restores it — without this reset every later test
      // would start on 高清 instead of 原画. This put stays in the real
      // zone (runAsync): awaiting a Hive put inside the fake-async zone
      // hangs the test (hive_ce's write-lock future never completes
      // there) — proven by the 09:25 run, which wedged for 7+ min after
      // this was changed to a plain await.
      await tester.runAsync(
        () => HiveStore.put(HiveKeys.preferResolution, '原画'),
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveRoomPage(
            room: LiveRoom(
              roomId: '660000',
              platform: platform,
              title: 'test room',
              nick: 'tester',
              liveStatus: true,
            ),
            site: site,
            backendFactory: (engine) => _FakeBackend(
              engine: engine,
              log: log,
              config: configs[engine]!,
            ),
          ),
        ),
      );
      // Flush _loadRoom: getRoomDetail -> getPlayQualities -> resolve ->
      // session open (fake backends + canned site, real Hive writes).
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
    }

    Map<PlayerEngine, _FakeBackendConfig> freshConfigs() => {
          for (final e in PlayerEngine.values) e: _FakeBackendConfig(),
        };

    ChoiceChip chip(WidgetTester tester, String label) =>
        tester.widget<ChoiceChip>(find.widgetWithText(ChoiceChip, label));

    /// End-of-test cleanup, called explicitly inside the test body
    /// (tearDown runs after the binding's pending-timer check, so it is
    /// too late there): cancel the fake backends' tickers, dismiss any
    /// Get snackbar BEFORE unmounting the Overlay — its
    /// AnimationController ticker outlives the Overlay otherwise
    /// ("OverlayState was disposed with an active Ticker") and a stuck
    /// snackbar also blocks the NEXT test's toast. Small pumps, not one
    /// big jump, so the reverse animation ticks to completion.
    Future<void> disposeRoom(WidgetTester tester, _BackendLog log) async {
      log.cancelAllTickers();
      Get.closeAllSnackbars();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    testWidgets('entry is portrait with an in-page 16:9 video surface', (
      tester,
    ) async {
      final site = _FakeSite();
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      final ratio = tester.widget<AspectRatio>(find.byType(AspectRatio));
      expect(ratio.aspectRatio, 16 / 9);
      // Two fullscreen entries (Pure Live: the header button AND the
      // overlay bottom bar's expand button).
      expect(find.byTooltip('全屏'), findsNWidgets(2));
      expect(find.byKey(const ValueKey('fake-video')), findsOneWidget);
      expect(log.opens.length, 1);
      expect(
        log.opens.single.url,
        'https://tx.flv.huya.com/src/660000.flv?wsSecret=A1',
      );
      await disposeRoom(tester, log);
    });

    testWidgets('line switch opens playUrls[newIndex] with NO new request', (
      tester,
    ) async {
      final site = _FakeSite();
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      expect(site.resolveCalls, 1);
      await tester.tap(find.text('线路 2'));
      await settle(tester);
      // No re-parse: the already-resolved list is reused.
      expect(site.resolveCalls, 1);
      expect(site.recoveryCalls, 0);
      expect(
        log.opens.last.url,
        'https://al.huya.com/src/660000.m3u8?wsSecret=A1',
      );
      // Facts follow the LINE, not index 0: line 2 is HLS.
      expect(log.opens.last.declaredFormat, 'hls');
      expect(chip(tester, '线路 2').selected, isTrue);
      await disposeRoom(tester, log);
    });

    testWidgets('quality switch re-parses once and opens the new stream', (
      tester,
    ) async {
      final site = _FakeSite();
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      await tester.tap(find.text('高清'));
      await settle(tester);
      expect(site.recoveryCalls, 1);
      expect(site.resolveCalls, 1); // initial resolve only
      expect(
        log.opens.last.url,
        'https://tx.flv.huya.com/src/660000.flv?wsSecret=B2',
      );
      expect(chip(tester, '高清').selected, isTrue);
      await disposeRoom(tester, log);
    });

    testWidgets('same quality tap is a no-op', (tester) async {
      final site = _FakeSite();
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      await tester.tap(find.text('原画'));
      await settle(tester);
      expect(site.resolveCalls, 1);
      expect(site.recoveryCalls, 0);
      expect(log.opens.length, 1);
      await disposeRoom(tester, log);
    });

    testWidgets('server ack differs from request: UI corrects + toast (Bilibili)',
        (tester) async {
      final site = _FakeSite();
      // Bilibili guest: requested 原画 (qn 10000), server applied 250.
      site.ackByQuality['10000'] = '250';
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      expect(chip(tester, '流畅').selected, isTrue);
      expect(chip(tester, '原画').selected, isFalse);
      expect(find.textContaining('清晰度已限制为流畅'), findsOneWidget);
      await disposeRoom(tester, log);
    });

    testWidgets('Douyu ack matches the opaque rate id, never a numeric order',
        (tester) async {
      final site = _FakeSite()
        ..qualities = const [
          LivePlayQuality(quality: '原画', id: '0'),
          LivePlayQuality(quality: '超清', id: '3'),
          LivePlayQuality(quality: '高清', id: '2'),
        ]
        ..urlsByQuality = const {
          '0': ['https://tx.douyu.com/src/1?rate=0'],
          '3': ['https://tx.douyu.com/src/1?rate=3'],
          '2': ['https://tx.douyu.com/src/1?rate=2'],
        }
        // Requested 原画 (rate 0), server confirmed opaque rate 3.
        ..ackByQuality = {'0': '3'};
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      // Rate 3 is 超清 (index 1) — not "the third" and not the max id.
      expect(chip(tester, '超清').selected, isTrue);
      expect(find.textContaining('清晰度已限制为超清'), findsOneWidget);
      await disposeRoom(tester, log);
    });

    testWidgets('quality switch: server caps the request, UI corrects + toast',
        (tester) async {
      final site = _FakeSite();
      // Requested 高清 (400), server confirmed 流畅 (250) and returned
      // the 流畅 stream: the switch opens the confirmed stream and the
      // selection follows the CONFIRMED quality, not the requested one
      // (Douyu anonymous 原画 -> 蓝光4M is the same shape).
      site.recoveryUrlsByQuality['400'] = const [
        'https://tx.flv.huya.com/src/660000.flv?wsSecret=C2',
      ];
      site.recoveryFactsByQuality['400'] = const [
        LiveStreamFacts(format: 'flv'),
      ];
      site.ackByQuality['400'] = '250';
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      await tester.tap(find.text('高清'));
      await settle(tester);
      expect(site.recoveryCalls, 1);
      expect(
        log.opens.last.url,
        'https://tx.flv.huya.com/src/660000.flv?wsSecret=C2',
      );
      expect(chip(tester, '流畅').selected, isTrue);
      expect(chip(tester, '高清').selected, isFalse);
      expect(find.textContaining('清晰度已限制为流畅'), findsOneWidget);
      await disposeRoom(tester, log);
    });

    testWidgets(
        'quality switch to a capped quality with identical URLs: cap toast, no reload',
        (tester) async {
      final site = _FakeSite();
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      // Switch to 高清 first (opens the B2 lines).
      await tester.tap(find.text('高清'));
      await settle(tester);
      expect(log.opens.length, 2);
      expect(chip(tester, '高清').selected, isTrue);
      // Now ask for 原画: the server caps it to 高清 and returns the
      // very same lines — the room must say the cap plainly instead of
      // the cryptic "清晰度流未变化", and must not reload.
      site.recoveryUrlsByQuality['10000'] =
          site.recoveryUrlsByQuality['400']!;
      site.ackByQuality['10000'] = '400';
      await tester.tap(find.text('原画'));
      await settle(tester);
      expect(site.recoveryCalls, 2);
      expect(find.textContaining('清晰度已限制为高清'), findsOneWidget);
      expect(find.text('清晰度流未变化'), findsNothing);
      expect(log.opens.length, 2); // no reload
      expect(chip(tester, '高清').selected, isTrue);
      expect(chip(tester, '原画').selected, isFalse);
      await disposeRoom(tester, log);
    });

    testWidgets('quality switch resolve failure: toast, stays on old quality',
        (tester) async {
      final site = _FakeSite()..recoveryThrows = true;
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      await tester.tap(find.text('高清'));
      await settle(tester);
      expect(site.recoveryCalls, 1);
      expect(find.textContaining('切换清晰度失败'), findsOneWidget);
      expect(log.opens.length, 1); // no reload
      expect(chip(tester, '原画').selected, isTrue);
      expect(chip(tester, '高清').selected, isFalse);
      await disposeRoom(tester, log);
    });

    testWidgets('identical URLs after a quality switch: toast + abort, no reload',
        (tester) async {
      final site = _FakeSite();
      // The "高清" re-parse returns the exact same URL list.
      site.recoveryUrlsByQuality['400'] =
          site.urlsByQuality['10000']!;
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      await tester.tap(find.text('高清'));
      await settle(tester);
      expect(site.recoveryCalls, 1); // the re-parse happened
      expect(find.text('清晰度流未变化'), findsOneWidget);
      expect(log.opens.length, 1); // no reload
      expect(chip(tester, '原画').selected, isTrue);
      expect(chip(tester, '高清').selected, isFalse);
      await disposeRoom(tester, log);
    });

    testWidgets('mid-playback failure: fresh re-parse first (Pure Live)', (
      tester,
    ) async {
      final site = _FakeSite();
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      log.backends.last.emitError('boom');
      await settle(tester);
      // Pure Live _runRecoverTask: refresh sources FIRST (fresh
      // signatures), then sweep from the current line — never the
      // stalled line's possibly-expired URL.
      expect(site.recoveryCalls, 1);
      expect(
        log.opens.last.url,
        'https://tx.flv.huya.com/src/660000.flv?wsSecret=A2',
      );
      expect(chip(tester, '线路 1').selected, isTrue);
      await disposeRoom(tester, log);
    });

    testWidgets(
        'single line failure auto-recovers first; manual retry is fetch-throttled',
        (tester) async {
      final site = _FakeSite()
        ..urlsByQuality = const {
          '10000': ['https://tx.flv.huya.com/src/660000.flv?wsSecret=A1'],
        }
        ..recoveryNeverCompletes = true;
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      log.backends.last.emitError('boom');
      await settle(tester);
      // P1-8: a single line no longer fails at once — the first error
      // spends a fresh recovery (fetch in flight), so no failure card
      // yet, and one site call has run.
      expect(find.text('▶ 重试'), findsNothing);
      expect(site.recoveryCalls, 1);
      // 10 s with no new stream -> the fresh fetch times out, the
      // failure card comes back.
      await tester.pump(const Duration(seconds: 10));
      await tester.pump();
      expect(find.text('▶ 重试'), findsOneWidget);
      await tester.tap(find.text('▶ 重试'));
      // settle(), not a bare pump(): the tap's onPressed setState lands
      // mid-frame and needs a second frame to rebuild the failure card
      // away.
      await settle(tester);
      // Manual retry resets the failure budget, but the 60 s fetch
      // throttle (stamped by the auto attempt) means no new fetch runs
      // — the card is back right away and no second site call is made.
      expect(find.text('▶ 重试'), findsOneWidget);
      expect(site.recoveryCalls, 1);
      await disposeRoom(tester, log);
    });

    testWidgets(
      'Huya default follows Pure Live proportional mapping, not 8M',
      (tester) async {
        final site = _FakeSite()
          ..qualities = const [
            LivePlayQuality(quality: '蓝光50M', id: '0'),
            LivePlayQuality(quality: '蓝光20M', id: '20000'),
            LivePlayQuality(quality: '蓝光8M', id: '8000'),
            LivePlayQuality(quality: '蓝光4M', id: '4000'),
            LivePlayQuality(quality: '超清', id: '2000'),
            LivePlayQuality(quality: '流畅', id: '500'),
          ]
          ..urlsByQuality = const {
            '0': ['https://tx.flv.huya.com/src/660000.flv?ratio=0'],
            '20000': ['https://tx.flv.huya.com/src/660000.flv?ratio=20000'],
            '8000': ['https://tx.flv.huya.com/src/660000.flv?ratio=8000'],
            '4000': ['https://tx.flv.huya.com/src/660000.flv?ratio=4000'],
            '2000': ['https://tx.flv.huya.com/src/660000.flv?ratio=2000'],
            '500': ['https://tx.flv.huya.com/src/660000.flv?ratio=500'],
          };
        final log = _BackendLog();
        await pumpRoom(tester, site, log, freshConfigs());
        // Saved preference '原画' has no exact match in Huya's list:
        // Pure Live _setDefaultResolution maps it proportionally
        // ('原画' is index 0 of the system list, so the target is
        // index 0 = 蓝光50M). The old 8M fallback was built on a
        // wrong diagnosis — "蓝光50M" is NOT 50 Mbps (ffprobe: ~8.2
        // Mbps) — and the real few-seconds cause was the missing
        // playback headers, not the bitrate.
        expect(chip(tester, '蓝光50M').selected, isTrue);
        expect(chip(tester, '蓝光8M').selected, isFalse);
        expect(log.opens.last.url, contains('ratio=0'));
        await disposeRoom(tester, log);
      },
    );

    testWidgets(
      'stall with one line recovers via fresh re-parse, never downgrades',
      (tester) async {
        final site = _FakeSite()
          ..urlsByQuality = const {
            '10000': [
              'https://tx.flv.huya.com/src/660000.flv?wsSecret=A1',
            ],
          };
        final log = _BackendLog();
        await pumpRoom(tester, site, log, freshConfigs());
        expect(chip(tester, '原画').selected, isTrue);
        log.backends.last.emitError('buffering_stall');
        await settle(tester);
        // P1-8: a single line now gets a fresh re-parse before failing —
        // the stalled line's possibly-expired URL is replaced by the
        // fresh signature (A2), the room recovers, and quality is NOT
        // downgraded. (The old auto-downgrade could never fire anyway:
        // every successful recovery reset its counter to 0.)
        expect(site.recoveryCalls, 1);
        expect(
          log.opens.last.url,
          'https://tx.flv.huya.com/src/660000.flv?wsSecret=A2',
        );
        expect(chip(tester, '原画').selected, isTrue);
        expect(chip(tester, '高清').selected, isFalse);
        expect(find.text('▶ 重试'), findsNothing);
        expect(
          HiveStore.getString(HiveKeys.preferResolution, ''),
          '原画',
        );
        await disposeRoom(tester, log);
      },
    );

    testWidgets('huya open carries Pure Live playback headers', (
      tester,
    ) async {
      final site = _FakeSite();
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      // Root cause of "只放几秒就放不了": the room used to open the
      // stream with NO headers, and Huya's CDN closes a header-less
      // FLV connection after ~7 s (measured with ffmpeg). Pure Live
      // sends the SDK UA + Origin + Referer on every open.
      expect(log.opens.length, 1);
      final headers = log.opens.single.headers;
      expect(headers, isNotNull);
      expect(headers!['user-agent'], HuyaRequestParams.hysdkUa);
      expect(headers['origin'], 'https://www.huya.com');
      expect(headers['referer'], 'https://www.huya.com/660000');
      await disposeRoom(tester, log);
    });

    testWidgets('douyu open carries Pure Live playback headers', (
      tester,
    ) async {
      final site = _FakeSite()..platformId = 'douyu';
      final log = _BackendLog();
      await pumpRoom(
        tester,
        site,
        log,
        freshConfigs(),
        platform: 'douyu',
      );
      final headers = log.opens.single.headers;
      expect(headers, isNotNull);
      expect(headers!['origin'], 'https://www.douyu.com');
      expect(headers['referer'], 'https://www.douyu.com/660000');
      expect(headers['user-agent'], DouyuUtils.userAgent);
      // The fake site is not a real DouyuSite, so no cookie is
      // attached here; the resolver-level cookie is covered by
      // playback_header_resolver_test.dart.
      expect(headers.containsKey('cookie'), isFalse);
      await disposeRoom(tester, log);
    });

    testWidgets(
      'prefetch: a fresh URL is fetched and held ~100 s after issue, stream not switched',
      (tester) async {
        final site = _FakeSite();
        final log = _BackendLog();
        await pumpRoom(tester, site, log, freshConfigs());
        expect(site.recoveryCalls, 0);
        final firstOpen = log.opens.last.url;
        await tester.pump(const Duration(seconds: 100));
        // The prefetch timer fires at exactly the 100 s boundary; its
        // async chain (hold fetch -> store) starts on microtasks that
        // only flush when fake time advances past the boundary — one
        // more second gives it the turns it needs.
        await tester.pump(const Duration(seconds: 1));
        await settle(tester);
        // The 100 s prefetch fetched a fresh plan and HELD it — the
        // playing stream was never switched: no new session open.
        expect(site.recoveryCalls, 1);
        expect(log.opens.last.url, firstOpen);
        await disposeRoom(tester, log);
      },
    );

    testWidgets('room starting to play pauses music (chen 2026-11-17)', (
      tester,
    ) async {
      final music = _RecordingMusicController();
      Get.put<MusicPlayerController>(music);
      music.isPlaying.value = true;
      final site = _FakeSite();
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      expect(music.pauseCalls, 1);
      await disposeRoom(tester, log);
    });

    testWidgets('line switch mid-room does not pause music again', (
      tester,
    ) async {
      final music = _RecordingMusicController();
      Get.put<MusicPlayerController>(music);
      music.isPlaying.value = true;
      final site = _FakeSite();
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      expect(music.pauseCalls, 1);
      await tester.tap(find.text('线路 2'));
      await settle(tester);
      expect(music.pauseCalls, 1);
      await disposeRoom(tester, log);
    });

    testWidgets('room that never plays leaves music alone', (tester) async {
      final music = _RecordingMusicController();
      Get.put<MusicPlayerController>(music);
      music.isPlaying.value = true;
      final site = _FakeSite();
      final log = _BackendLog();
      final configs = freshConfigs()
        ..updateAll((_, c) => c..openSucceeds = false);
      await pumpRoom(tester, site, log, configs);
      expect(music.pauseCalls, 0);
      await disposeRoom(tester, log);
    });
  });
}

LiveRoom _room() => const LiveRoom(
      roomId: '660000',
      platform: 'huya',
      title: 'test',
      cover: '',
      nick: 'test',
      liveStatus: true,
    );

/// Fake LiveSite with canned resolutions. [urlsByQuality] / [ackByQuality]
/// are keyed by [LivePlayQuality.selectionId] (the opaque platform id).
class _FakeSite extends LiveSite {
  /// Platform id reported by this fake (default huya; the Douyu
  /// header test overrides it — the room page builds playback
  /// headers from the site id).
  String platformId = 'huya';

  List<LivePlayQuality> qualities = const [
    LivePlayQuality(quality: '原画', id: '10000'),
    LivePlayQuality(quality: '高清', id: '400'),
    LivePlayQuality(quality: '流畅', id: '250'),
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
    '250': ['https://tx.flv.huya.com/src/660000.flv?wsSecret=C1'],
  };

  Map<String, List<LiveStreamFacts>> factsByQuality = {
    '10000': [LiveStreamFacts(format: 'flv'), LiveStreamFacts(format: 'hls')],
    '400': [LiveStreamFacts(format: 'flv'), LiveStreamFacts(format: 'hls')],
    '250': [LiveStreamFacts(format: 'flv')],
  };

  /// Fresh (new-signature) URLs per quality, for the recovery path.
  Map<String, List<String>> recoveryUrlsByQuality = {
    '10000': [
      'https://tx.flv.huya.com/src/660000.flv?wsSecret=A2',
      'https://al.huya.com/src/660000.m3u8?wsSecret=A2',
    ],
    '400': [
      'https://tx.flv.huya.com/src/660000.flv?wsSecret=B2',
      'https://al.huya.com/src/660000.m3u8?wsSecret=B2',
    ],
    '250': ['https://tx.flv.huya.com/src/660000.flv?wsSecret=C2'],
  };

  Map<String, List<LiveStreamFacts>> recoveryFactsByQuality = {
    '10000': [LiveStreamFacts(format: 'flv'), LiveStreamFacts(format: 'hls')],
    '400': [LiveStreamFacts(format: 'flv'), LiveStreamFacts(format: 'hls')],
    '250': [LiveStreamFacts(format: 'flv')],
  };

  /// What the server actually applied, per requested quality id.
  Map<String, dynamic> ackByQuality = {};

  /// When set, fetchFresh returns this resolution verbatim (lease test).
  LivePlayUrlResolution? recoveryResolution;

  /// Shorthand for recoveryResolution with only urls (+ facts).
  List<String>? recoveryUrls;
  List<LiveStreamFacts>? recoveryFacts;

  bool recoveryNeverCompletes = false;

  /// When set, the recovery resolve throws (all CDNs failed) instead
  /// of returning a resolution — the switch path must toast, not crash.
  bool recoveryThrows = false;

  int resolveCalls = 0;
  int recoveryCalls = 0;

  @override
  String get id => platformId;

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
    Map<String, List<LiveStreamFacts>> facts,
    LivePlayQuality? quality, {
    dynamic ack,
  }) {
    final id = quality?.selectionId ?? '';
    final issued = DateTime.now();
    return LivePlayUrlResolution(
      urls: urls[id] ?? const [],
      appliedQualityData: ack,
      issuedAt: issued,
      refreshAt: issued.add(const Duration(seconds: 100)),
      invalidAt: issued.add(const Duration(seconds: 125)),
      streamFacts: facts[id] ?? const [],
    );
  }

  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    resolveCalls++;
    return _resolution(
      urlsByQuality,
      factsByQuality,
      quality,
      ack: ackByQuality.containsKey(quality?.selectionId)
          ? ackByQuality[quality!.selectionId]
          : null,
    );
  }

  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecovery({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    recoveryCalls++;
    if (recoveryThrows) {
      throw StateError('recovery resolve failed');
    }
    if (recoveryNeverCompletes) {
      return Completer<LivePlayUrlResolution>().future;
    }
    if (recoveryResolution != null) return recoveryResolution!;
    if (recoveryUrls != null) {
      final issued = DateTime.now();
      return LivePlayUrlResolution(
        urls: recoveryUrls!,
        issuedAt: issued,
        refreshAt: issued.add(const Duration(seconds: 100)),
        invalidAt: issued.add(const Duration(seconds: 125)),
        streamFacts: recoveryFacts ?? const [],
      );
    }
    // The real sites confirm a rate on the recovery path too
    // (Douyu groups by confirmed rate; Huya re-acks the quality id),
    // so the fake applies ackByQuality here exactly like resolvePlayUrls.
    return _resolution(
      recoveryUrlsByQuality,
      recoveryFactsByQuality,
      quality,
      ack: ackByQuality.containsKey(quality?.selectionId)
          ? ackByQuality[quality!.selectionId]
          : null,
    );
  }
}

/// One recorded backend open.
class _BackendOpen {
  _BackendOpen({
    required this.engine,
    required this.url,
    this.declaredFormat,
    this.headers,
  });

  final PlayerEngine engine;
  final String url;
  final String? declaredFormat;

  /// HTTP headers the room passed to the session open (Pure Live
  /// playback headers: Huya/Douyu UA + Origin + Referer).
  final Map<String, String>? headers;
}

/// Shared record of every fake backend the factory built.
/// Music controller double: records pause() calls without touching
/// the (Linux-absent) audio players — the real pause() would hit the
/// uninitialised late `_active` player when isPlaying is true.
class _RecordingMusicController extends MusicPlayerController {
  int pauseCalls = 0;

  @override
  Future<void> pause() async {
    pauseCalls++;
  }
}

class _BackendLog {
  final List<_BackendOpen> opens = [];
  final List<_FakeBackend> backends = [];
  final Map<PlayerEngine, int> disposes = {};

  /// Cancel every fake backend's position ticker directly. The session
  /// dispose chain awaits broadcast-cancel futures that never resolve
  /// inside a widget test's fake-async zone, so the tickers would
  /// otherwise stay pending past the test's end-of-test invariant
  /// check. Production dispose is proven separately (real-time unit
  /// test); this only satisfies the test framework's timer check.
  void cancelAllTickers() {
    for (final backend in backends) {
      backend.cancelTicker();
    }
  }
}

class _FakeBackendConfig {
  bool openSucceeds = true;
  bool firstFrameSucceeds = true;
  bool emitPositions = true;
}

/// Fake native backend: instant open/first-frame, controllable failure,
/// and a position ticker so the session health watch stays happy.
class _FakeBackend implements PlayerBackend {
  _FakeBackend({
    required this.engine,
    required this.log,
    required this.config,
  }) {
    log.backends.add(this);
  }

  @override
  final PlayerEngine engine;

  final _BackendLog log;
  final _FakeBackendConfig config;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  Timer? _positionTimer;
  int _positionSeconds = 0;
  bool _disposed = false;

  bool get isDisposed => _disposed;
  bool get isTickerCancelled => _positionTimer == null || !_positionTimer!.isActive;

  void emitError(String message) => _error.add(message);
  void emitCompleted() => _completed.add(null);
  void emitPosition(Duration position) => _position.add(position);

  /// Stop the position ticker without going through dispose().
  void cancelTicker() => _positionTimer?.cancel();

  @override
  Widget buildVideoWidget() =>
      const SizedBox(key: ValueKey('fake-video'));

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    log.opens.add(
      _BackendOpen(
        engine: engine,
        url: url,
        declaredFormat: declaredFormat,
        headers: headers,
      ),
    );
    if (!config.openSucceeds) throw StateError('fake open failed');
    if (config.emitPositions) {
      _positionTimer?.cancel();
      _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _positionSeconds++;
        _position.add(Duration(seconds: _positionSeconds));
      });
    }
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      config.firstFrameSucceeds;

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  // Audio-only is MPV-only (see PlayerBackend.setAudioOnly).
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
    log.disposes[engine] = (log.disposes[engine] ?? 0) + 1;
    _positionTimer?.cancel();
    // Do NOT await the broadcast close() calls: inside a widget test's
    // fake-async zone a broadcast StreamController.close() future never
    // completes, so awaiting it stalls _swapBackend (and therefore the
    // whole session.open / _switchQuality chain) forever. Closing is
    // best-effort here; the recorded dispose count is the assertion.
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}
