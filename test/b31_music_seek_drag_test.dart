// Build 31: music player drag-seek repro (chen 2026-11-23:
// "音乐播放器拖动进度条也不加载了" — dragging the progress bar no
// longer loads/seeks).
//
// Two layers, isolated:
// 1. Widget layer: the real MusicPlayerPage + a no-load controller
//    that only records seeks. A drag from 10% to 50% of the bar must
//    fire exactly ONE seek at ~50% of the track, and a tap at 25%
//    must fire one seek at ~25%.
// 2. Controller layer: the real controller + fake AVPlayers. A direct
//    seek must reach the active fake player (not die in the
//    !_playersReady guard or the isResolving park).

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:just_audio/just_audio.dart';
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/av_music_player.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_player_sheet.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';
import 'package:standalone/services/music/play_mode.dart';

/// No alt platform ever (the recovery under test must come from the
/// next candidate, not from an alt lookup).
class _SeekFakeApi extends MusicApi {
  @override
  Future<Song?> findAltPlatform(
    String title,
    String artist,
    MusicPlatform excludePf,
    String album, {
    Duration timeout = const Duration(seconds: 5),
  }) async =>
      null;

  @override
  Future<List<LyricLine>> lyrics(Song song) async => [];
}

String _seekUrl(String id, int n) => 'https://example.com/$id-$n.mp3';

/// Every resolve hands out two candidates for the same song (the
/// first URL is the one whose seek will fail).
class _SeekScriptedResolvers extends MusicResolvers {
  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
    String artist = '',
    bool background = false,
    Duration totalBudget = const Duration(seconds: 8),
  }) async {
    if (background) return null;
    return PlayUrlResult(
      url: _seekUrl(songId, 1),
      candidates: [_seekUrl(songId, 1), _seekUrl(songId, 2)],
      quality: AudioQuality.hires,
      via: 'test',
    );
  }

  @override
  void evictPlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
  ) {}
}

MusicPlayerController _seekRecoveryController({
  required _SeekFakePlayer a,
  required _SeekFakePlayer b,
  Duration seekLanding = const Duration(milliseconds: 300),
}) =>
    Get.put(
      MusicPlayerController(
        api: _SeekFakeApi(),
        resolvers: _SeekScriptedResolvers(),
        playerA: a,
        playerB: b,
        seekLandingTimeout: seekLanding,
      ),
    );

/// No-load controller: records seeks, never resolves/loads audio
/// (same pattern as music_player_layout_test's _NoLoadController).
class _RecordSeeksController extends MusicPlayerController {
  final List<Duration> seeks = [];

  @override
  Future<void> seek(Duration pos) async {
    seeks.add(pos);
  }

  @override
  Future<void> next({bool auto = false}) async {
    if (queue.length <= 1) return;
    final n = nextTrackIndex(
      mode,
      currentIndex.value,
      queue.length,
      auto: auto,
    );
    if (n < 0) return;
    currentIndex.value = n;
  }
}

/// Fake AVPlayer: records seeks, drives its streams by hand.
class _SeekFakePlayer extends AvMusicPlayer {
  final List<Duration> seeks = [];
  final List<String> openedUrls = [];
  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration>.broadcast();
  final playingCtrl = StreamController<bool>.broadcast();
  final errorCtrl = StreamController<String>.broadcast();
  final completedCtrl = StreamController<bool>.broadcast();

  /// Upcoming seeks to swallow: recorded, but nothing is emitted on
  /// the position stream — the silent native failure chen reported
  /// (an expired URL whose seek the native player refuses without
  /// an error). A swallowed seek is spent after one use.
  var refuseSeeks = 0;

  @override
  AvMusicPlayerStreams get stream => _SeekFakeStreams(this);

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    return true;
  }

  @override
  Future<bool> preload(String url) async => true;

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> seek(Duration position) async {
    seeks.add(position);
    if (refuseSeeks > 0) {
      refuseSeeks--;
      return;
    }
    positionCtrl.add(position);
  }

  @override
  Future<void> dispose() async {}
}

class _SeekFakeStreams extends AvMusicPlayerStreams {
  _SeekFakeStreams(this._p) : super(AudioPlayer());

  final _SeekFakePlayer _p;

  @override
  Stream<Duration> get position => _p.positionCtrl.stream;
  @override
  Stream<Duration> get duration => _p.durationCtrl.stream;
  @override
  Stream<bool> get playing => _p.playingCtrl.stream;
  @override
  Stream<String> get error => _p.errorCtrl.stream;
  @override
  Stream<bool> get completed => _p.completedCtrl.stream;
}

void main() {
  late Box<dynamic> box;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          (call) async => null,
        );
    Hive.init('test/.hive-b31-seek-drag');
    box = await Hive.openBox<dynamic>('b31_seek_drag', bytes: Uint8List(0));
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    Get.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          null,
        );
    await box.close();
  });

  Future<void> pumpPage(
    WidgetTester tester,
    MusicPlayerController c,
  ) async {
    tester.view.physicalSize = const Size(420, 874);
    tester.view.devicePixelRatio = 1.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    c.queue.assignAll([
      Song(
        songId: '1',
        title: 'Test Song',
        artist: 'Test Artist',
        album: 'Test Album',
        cover: '',
        platform: MusicPlatform.wy,
        dur: 200,
      ),
    ]);
    c.currentIndex.value = 0;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: const MusicPlayerPage(),
      ),
    );
    await tester.pump();
  }

  group('widget: drag the progress bar', () {
    testWidgets('drag to 50% fires exactly one seek at ~100s', (
      tester,
    ) async {
      final rec = _RecordSeeksController();
      final c = Get.put<MusicPlayerController>(rec);
      await pumpPage(tester, c);
      expect(find.text('Test Song'), findsOneWidget);
      final bar = find.byKey(const ValueKey('progressBar'));
      expect(bar, findsOneWidget);
      final rect = tester.getRect(bar);
      // Screen 420 wide, _progressInset 40 -> fraction =
      // (x - 40) / 340. Start at 60 (frac ~0.06), end at 210 (0.5).
      final y = rect.center.dy;
      final gesture = await tester.startGesture(Offset(60, y));
      await gesture.moveTo(Offset(210, y));
      await gesture.up();
      await tester.pumpAndSettle();
      expect(rec.seeks.length, 1);
      expect(
        rec.seeks.single.inSeconds,
        inInclusiveRange(95, 105),
        reason: 'one seek at 50% of the 200s track',
      );
      expect(tester.takeException(), isNull);
    });

    testWidgets('tap at 25% fires one seek at ~50s', (tester) async {
      final rec = _RecordSeeksController();
      final c = Get.put<MusicPlayerController>(rec);
      await pumpPage(tester, c);
      final bar = find.byKey(const ValueKey('progressBar'));
      final rect = tester.getRect(bar);
      // x = 40 + 0.25 * 340 = 125.
      await tester.tapAt(Offset(125, rect.center.dy));
      await tester.pumpAndSettle();
      expect(rec.seeks.length, 1);
      expect(
        rec.seeks.single.inSeconds,
        inInclusiveRange(45, 55),
        reason: 'one seek at 25% of the 200s track',
      );
      expect(tester.takeException(), isNull);
    });
  });

  group('controller: seek reaches the native player', () {
    test('direct seek lands on the active fake player', () async {
      final a = _SeekFakePlayer();
      final b = _SeekFakePlayer();
      final c = Get.put(
        MusicPlayerController(playerA: a, playerB: b),
      );
      c.queue.assignAll([
        Song(
          songId: '1',
          title: 'Test Song',
          artist: 'Test Artist',
          album: 'Test Album',
          cover: '',
          platform: MusicPlatform.wy,
          dur: 200,
        ),
      ]);
      c.currentIndex.value = 0;
      await c.seek(const Duration(seconds: 100));
      expect(a.seeks, [const Duration(seconds: 100)]);
      expect(c.position.value, const Duration(seconds: 100));
      c.stopStallWatchdogForTest();
    });
  });

  group('controller: a seek the native player never lands', () {
    Song song() => Song(
          songId: '1',
          title: 'Test Song',
          artist: 'Test Artist',
          album: 'Test Album',
          cover: '',
          platform: MusicPlatform.wy,
          dur: 200,
        );

    test('recovers on the next candidate at the seek target', () async {
      final a = _SeekFakePlayer()..refuseSeeks = 1;
      final b = _SeekFakePlayer()..refuseSeeks = 1;
      final c = _seekRecoveryController(a: a, b: b);
      await c.playQueue([song()], 0);
      expect(a.openedUrls, [_seekUrl('1', 1)]);
      a.durationCtrl.add(const Duration(seconds: 200));
      // The song plays from the old spot while the seek fails: the
      // position keeps advancing, so the generic stall check (which
      // only fires on a FROZEN position) never sees it — the seek
      // target is the only witness. Let the 10 s event land before
      // the seek, or its delivery races the optimistic position.
      a.positionCtrl.add(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(c.position.value, const Duration(seconds: 10));
      await c.seek(const Duration(seconds: 100));
      expect(a.seeks, [const Duration(seconds: 100)]);
      expect(c.position.value, const Duration(seconds: 100));
      for (var i = 11; i <= 13; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        // Once the recovery opens the next candidate, the old URL's
        // position events stop in reality too — feeding them after
        // the recovery would clobber the recovered position.
        if (a.openedUrls.length > 1) break;
        a.positionCtrl.add(Duration(seconds: i));
      }
      // Past the 300 ms landing budget + a 500 ms tick: the recovery
      // opens the next candidate and re-applies the seek on it (the
      // second seek lands — refuseSeeks was spent on the first).
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(a.openedUrls, [_seekUrl('1', 1), _seekUrl('1', 2)]);
      expect(
        a.seeks,
        [
          const Duration(seconds: 100),
          const Duration(seconds: 100),
        ],
        reason: 'the seek is re-applied on the recovered URL',
      );
      expect(c.position.value, const Duration(seconds: 100));
      expect(c.loadError.value, isNull);
      c.stopStallWatchdogForTest();
    });

    test('a landed seek never triggers the recovery', () async {
      final a = _SeekFakePlayer();
      final b = _SeekFakePlayer();
      final c = _seekRecoveryController(a: a, b: b);
      await c.playQueue([song()], 0);
      a.durationCtrl.add(const Duration(seconds: 200));
      a.positionCtrl.add(const Duration(seconds: 10));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await c.seek(const Duration(seconds: 100));
      // The fake seek emits 100 s, so the landing check clears the
      // target. Keep the position advancing so the generic stall
      // check stays quiet too.
      for (var i = 101; i <= 103; i++) {
        await Future<void>.delayed(const Duration(milliseconds: 300));
        a.positionCtrl.add(Duration(seconds: i));
      }
      await Future<void>.delayed(const Duration(seconds: 1));
      expect(a.openedUrls, [_seekUrl('1', 1)]);
      expect(a.seeks, [const Duration(seconds: 100)]);
      expect(c.loadError.value, isNull);
      c.stopStallWatchdogForTest();
    });
  });
}
