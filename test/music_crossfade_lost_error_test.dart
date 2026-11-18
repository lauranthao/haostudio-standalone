// Crossfade lost-error window (chen 2026-11-17: fix the narrow window
// where an incoming load failure during crossfade is silently lost).
//
// The window: _crossfadeTo opens the URL on the STANDBY player, whose
// error stream has no subscriber until _attach(incoming) runs after
// the open. just_audio's errorStream is a PublishSubject (no replay —
// just_audio 0.10.6 line 142), and AvMusicPlayer.open() swallows the
// PlayerException and returns true, so a native load failure is
// reported ONLY on that stream: an error emitted before _attach is
// gone for good, the fade runs into silence (incoming has no source,
// outgoing gets paused), and no failure path runs.
//
// The fix: after open()+play(), before swapping _active, check the
// incoming player's processingState — a failed load leaves it idle,
// and the state is readable synchronously with no subscription. Idle
// there runs the normal error path (_onPlayError), exactly like the
// refused-URL return. An error still in flight at the check is caught
// after _attach by _onStreamError (same idle test), and a healthy
// load is never idle (ready / buffering / playing).
//
// Tests drive the controller with fake players injected through the
// constructor seam (same pattern as the api/resolvers overrides) —
// no native audio on Linux. The fake's open() "succeeds" (returns
// true) while its processingState reports idle, which is exactly what
// the real player looks like after a lost native load error.
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/av_music_player.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

Song _song(String id, String title) =>
    Song(songId: id, title: title, artist: 'Singer $id');

String _url(String id) => 'https://example.com/$id.flac';

/// Fake AvMusicPlayer: open() always returns true (the URL was not
/// refused before any native call), but the load can be failed — the
/// player then reports idle, which is what the real player looks like
/// after a native load error whose error-stream event was lost.
class _FakePlayer extends AvMusicPlayer {
  _FakePlayer({required this.failUrls});

  final Set<String> failUrls;
  final List<String> openedUrls = [];
  var playCalls = 0;
  var pauseCalls = 0;
  var _failed = false;

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    _failed = failUrls.contains(url);
    return true;
  }

  @override
  ProcessingState get processingState =>
      // just_audio has no `playing` state (playing is a separate
      // bool on PlayerState): a loaded player is `ready`.
      _failed ? ProcessingState.idle : ProcessingState.ready;

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose() async {}
}

/// Resolver that answers instantly and records every resolve, so the
/// test can tell a failure-path advance (resolve for the next song)
/// from a prefetch.
class _UrlResolvers extends MusicResolvers {
  _UrlResolvers() : super(dio: Dio());

  final List<String> resolvedIds = [];

  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
  }) async {
    resolvedIds.add(songId);
    return PlayUrlResult(
      url: _url(songId),
      candidates: [_url(songId)],
      quality: quality,
      via: 'test',
    );
  }
}

void main() {
  late Box<dynamic> box;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init('test/.hive-crossfade-test');
    box = await Hive.openBox<dynamic>('crossfade_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('crossfade_test');
  });

  MusicPlayerController makeController({
    required _FakePlayer playerA,
    required _FakePlayer playerB,
    required _UrlResolvers resolvers,
  }) {
    final c = MusicPlayerController(
      resolvers: resolvers,
      playerA: playerA,
      playerB: playerB,
    );
    c.queue.clear();
    c.queue.addAll([_song('1', 'A'), _song('2', 'B'), _song('3', 'C')]);
    c.currentIndex.value = 0;
    return c;
  }

  group('crossfade lost-error window', () {
    test('failed incoming runs the failure path, not silence', () async {
      // Both crossfade loads fail (lost error): B's, then C's.
      final playerA = _FakePlayer(failUrls: const {});
      final playerB = _FakePlayer(failUrls: {_url('2'), _url('3')});
      final resolvers = _UrlResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
      );

      await c.next(auto: true);

      // Give a pre-fix fade timer (2.5 s) time to pause the outgoing
      // if one had started — it must not have.
      await Future<void>.delayed(const Duration(milliseconds: 2600));

      // The failure path advanced past the failed song (twice), to
      // the end of the queue — it did not sit silent on song B. And
      // the give-up PAUSES the previous song (chen 2026-11-18: a
      // failed song must not leave the previous song playing — the
      // old crossfade fallback left it sounding).
      expect(c.currentIndex.value, 2);
      expect(resolvers.resolvedIds, ['2', '3']);
      // Both crossfade opens were attempted (B, then C after the
      // failure path advanced); neither started a fade.
      expect(playerB.openedUrls, [_url('2'), _url('3')]);
      expect(playerA.pauseCalls, 1);
      expect(c.lastNotice.value, contains('已是最后一首'));
      expect(c.isResolving.value, isFalse);
    });

    test('successful crossfade still swaps and fades (regression)',
        () async {
      final playerA = _FakePlayer(failUrls: const {});
      final playerB = _FakePlayer(failUrls: const {});
      final resolvers = _UrlResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
      );

      await c.next(auto: true);

      expect(c.currentIndex.value, 1);
      expect(playerB.openedUrls, [_url('2')]);
      expect(playerB.playCalls, 1);
      // Fade just started (2.5 s): the outgoing is not paused yet.
      // (The fade timer keeps running in the background after this
      // test; it only touches this test's fake players.)
      expect(playerA.pauseCalls, 0);
      expect(c.isResolving.value, isFalse);
    });
  });

  group('sibling paths (no window)', () {
    test('manual cut opens on the attached active player', () async {
      final playerA = _FakePlayer(failUrls: const {});
      final playerB = _FakePlayer(failUrls: const {});
      final resolvers = _UrlResolvers();
      final c = makeController(
        playerA: playerA,
        playerB: playerB,
        resolvers: resolvers,
      );

      await c.playIndex(1);

      expect(c.currentIndex.value, 1);
      expect(playerA.openedUrls, [_url('2')]);
      expect(c.isResolving.value, isFalse);
    });
  });
}
