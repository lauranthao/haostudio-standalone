// Step 2–4 hardening tests (coordinator round):
//
// - formatOf detects FLV/HLS from host/path fragments, not just suffixes
//   (real Huya FLV URLs carry `.flv` in the host: al-game.flv.huya.com).
// - RecoveryLadder never retries the same (engine, url) twice, runs one
//   at a time, and reports exhaustion when everything fails.
// - LiveRecovery identifies lines by URL (CDN + path), not index, across
//   a refresh that re-orders lines (Huya line-identity rule).

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/player/kernel/player_kernel.dart';
import 'package:standalone/core/player/kernel/recovery_ladder.dart';
import 'package:standalone/features/live/live_recovery.dart';
import 'package:standalone/shared/platforms/live_site.dart';

void main() {
  group('formatOf host/path fragments (step 2)', () {
    test('Huya FLV host without .flv suffix', () {
      expect(
        formatOf(url: 'http://al-game.flv.huya.com/src'),
        StreamFormat.flv,
      );
      expect(
        formatOf(url: 'https://tx.flv.huya.com/src/12345.flv?wsSecret=abc'),
        StreamFormat.flv,
      );
    });
    test('Douyin pull-flv host', () {
      expect(
        formatOf(url: 'https://pull-flv-l1.douyin.com/stream/abc'),
        StreamFormat.flv,
      );
    });
    test('m3u8 anywhere in the URL', () {
      expect(
        formatOf(url: 'https://example.com/hls/live.m3u8/segment001.ts'),
        StreamFormat.hls,
      );
    });
    test('declared format still wins over fragments', () {
      expect(
        formatOf(
          url: 'http://al-game.flv.huya.com/src',
          declaredFormat: 'hls',
        ),
        StreamFormat.hls,
      );
    });
    test('Huya FLV host never reaches AVPlayer candidates', () {
      final c = candidatesFor(
        url: 'http://al-game.flv.huya.com/src',
        isLive: true,
        preferred: PlayerEngine.exo,
      );
      expect(c, isNot(contains(PlayerEngine.exo)));
      expect(c.first, PlayerEngine.mediaKit);
    });
    test('unknown URL still offers every engine', () {
      final c = candidatesFor(
        url: 'https://example.com/stream?id=1',
        isLive: true,
        preferred: PlayerEngine.fijk,
      );
      expect(c.first, PlayerEngine.fijk);
      expect(c.length, 3);
    });
  });

  group('RecoveryLadder (step 3)', () {
    test('never retries the same engine+url pair', () async {
      var attempts = 0;
      final ladder = RecoveryLadder(
        engines: const [PlayerEngine.mediaKit, PlayerEngine.fijk],
        urls: const ['https://x/a.flv', 'https://x/b.flv'],
        attempt: ({required engine, required url}) async {
          attempts++;
          return false;
        },
        retryDelays: const [],
      );
      expect(await ladder.run(), isNull);
      // 2 engines × 2 urls, each pair once.
      expect(attempts, 4);
      expect(ladder.status, RecoveryLadderStatus.exhausted);
    });

    test('returns the first verified winner and stops', () async {
      var attempts = 0;
      final ladder = RecoveryLadder(
        engines: const [PlayerEngine.exo, PlayerEngine.mediaKit],
        urls: const ['https://x/a.flv'],
        attempt: ({required engine, required url}) async {
          attempts++;
          // exo cannot play flv in the real selector, but the ladder
          // itself just runs attempts in order; simulate mpv winning.
          return engine == PlayerEngine.mediaKit;
        },
        retryDelays: const [],
      );
      final won = await ladder.run();
      expect(won?.engine, PlayerEngine.mediaKit);
      expect(attempts, 2);
      expect(ladder.status, RecoveryLadderStatus.completed);
    });

    test('second concurrent run returns null', () async {
      final ladder = RecoveryLadder(
        engines: const [PlayerEngine.mediaKit],
        urls: const ['https://x/a.flv'],
        attempt: ({required engine, required url}) async {
          await Future<void>.delayed(const Duration(milliseconds: 50));
          return true;
        },
        retryDelays: const [],
      );
      final first = ladder.run();
      final second = await ladder.run();
      expect(second, isNull);
      expect(await first, isNotNull);
    });

    test('resetBudget allows a fresh run', () async {
      var attempts = 0;
      final ladder = RecoveryLadder(
        engines: const [PlayerEngine.mediaKit],
        urls: const ['https://x/a.flv'],
        attempt: ({required engine, required url}) async {
          attempts++;
          return false;
        },
        retryDelays: const [],
      );
      await ladder.run();
      ladder.resetBudget();
      await ladder.run();
      expect(attempts, 2);
    });

    test('default retryDelays add no dead wait on exhaustion', () async {
      // Was: after the single sweep the ladder waited out the default
      // retry delays (750 ms + 2 s) in a second sweep that could
      // attempt nothing — every pair was already in `_tried` — so a
      // failed open reported exhausted 2.75 s late for no reason.
      var attempts = 0;
      final ladder = RecoveryLadder(
        engines: const [PlayerEngine.mediaKit, PlayerEngine.fijk],
        urls: const ['https://x/a.flv'],
        attempt: ({required engine, required url}) async {
          attempts++;
          return false;
        },
      );
      final sw = Stopwatch()..start();
      expect(await ladder.run(), isNull);
      sw.stop();
      expect(attempts, 2);
      expect(ladder.status, RecoveryLadderStatus.exhausted);
      expect(sw.elapsed, lessThan(const Duration(seconds: 2)));
    });
  });

  group('LiveRecovery line identity by URL (step 4)', () {
    test('advanceLine wraps and needs no network', () {
      final recovery = _FakeRecovery();
      recovery.lines = const [
        'https://tx.flv.huya.com/src/1',
        'https://al.flv.huya.com/src/1',
      ];
      expect(recovery.currentUrl, 'https://tx.flv.huya.com/src/1');
      expect(recovery.advanceLine(), 'https://al.flv.huya.com/src/1');
      expect(recovery.advanceLine(), 'https://tx.flv.huya.com/src/1');
    });

    test('single line has no next line', () {
      final recovery = _FakeRecovery();
      recovery.lines = const ['https://tx.flv.huya.com/src/1'];
      expect(recovery.nextLineUrl, isNull);
      expect(recovery.advanceLine(), isNull);
    });

    test('refresh matches by host+path, not index', () async {
      final site = _FakeSite();
      final recovery = LiveRecovery(site: site, room: _room());
      recovery.lines = const [
        'https://tx.flv.huya.com/src/1?wsSecret=OLD',
        'https://al.flv.huya.com/src/1?wsSecret=OLD',
      ];
      recovery.currentLineIndex = 1; // playing AL line
      // Refresh re-orders: AL first now, TX second, new signatures.
      site.nextUrls = const [
        'https://al.flv.huya.com/src/1?wsSecret=NEW',
        'https://tx.flv.huya.com/src/1?wsSecret=NEW',
      ];
      final res = await recovery.fetchFresh();
      expect(res, isNotNull);
      // Same CDN+path as before (AL), now at index 0 — not the old index 1.
      expect(recovery.currentLineIndex, 0);
      expect(recovery.currentUrl,
          'https://al.flv.huya.com/src/1?wsSecret=NEW');
    });

    test('fetchFresh is throttled to once per 60 s', () async {
      final site = _FakeSite();
      final recovery = LiveRecovery(site: site, room: _room());
      recovery.lines = const ['https://tx.flv.huya.com/src/1'];
      site.nextUrls = const ['https://tx.flv.huya.com/src/2'];
      expect(await recovery.fetchFresh(), isNotNull);
      expect(site.calls, 1);
      expect(await recovery.fetchFresh(), isNull);
      expect(site.calls, 1);
    });

    test('fetchFresh carries stream facts with the lines', () async {
      final site = _FakeSite();
      final recovery = LiveRecovery(site: site, room: _room());
      site.nextUrls = const [
        'https://tx.flv.huya.com/src/1?wsSecret=NEW',
        'https://al.huya.com/src/1.m3u8?wsSecret=NEW',
      ];
      site.nextFacts = const [
        LiveStreamFacts(format: 'flv'),
        LiveStreamFacts(format: 'hls'),
      ];
      expect(await recovery.fetchFresh(), isNotNull);
      // TX line changed FLV -> HLS across the refresh: facts follow the
      // URL at the same index, so the session is told the new format.
      expect(recovery.factsFor(0).format, 'flv');
      expect(recovery.factsFor(1).format, 'hls');
      expect(recovery.factsFor(99).format, 'other');
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

class _FakeRecovery extends LiveRecovery {
  _FakeRecovery() : super(site: _FakeSite(), room: _room());
}

class _FakeSite extends LiveSite {
  List<String> nextUrls = const [];
  List<LiveStreamFacts> nextFacts = const [];
  int calls = 0;

  @override
  String get id => 'huya';

  @override
  String get name => 'Huya';

  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecovery({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    calls++;
    return LivePlayUrlResolution(
      urls: nextUrls,
      issuedAt: DateTime.now(),
      streamFacts: nextFacts,
    );
  }
}
