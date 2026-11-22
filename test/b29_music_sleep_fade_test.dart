// build-29 音乐 — 睡眠定时 × 淡化/交叉淡化竞态复现测试。
//
// chen 2026-11-22 18:19: "音乐播放好像还有点小问题"。睡眠定时是
// 1.1.6 的音乐改动，淡入淡出是 build-29 的改动，两处共用同一套
// 淡化状态，查出三处真问题（见各 test 的注释）：
//  A. 睡眠定时到点后，当前歌在 1 s 淡出期间播完 → 自动切歌继续放
//     （_onTrackCompleted 没有"睡眠已触发"检查；_pauseIfSleepFired
//     的 gen 检查在自动切歌 bump gen 后放行；交叉淡化还把睡眠
//     淡出定时器取消了）。
//  B. 睡眠定时在交叉淡化中途触发 → 新歌音量从 _currentNormGain
//     （满格）重新淡出，听感上先跳响再变小；且交叉淡化定时器
//     被睡眠淡出取消（或反过来）。
//  C. 暂停发生在恢复淡入的 400 ms 内 → 淡出从满格开始（跳响），
//     且未完成的淡入 ramp 继续写增量音量，和淡出打架。
//
// Harness: 与 v16_music_sleep_norm_bookmark_test.dart 相同的 fake
// players（constructor seam）+ 即时解析 + fake API。Fake 的 volume
// getter 跟踪最后一次 setVolume（与 just_audio AudioPlayer.volume
// 的语义一致：返回最后一次设置的音量）。

import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:just_audio/just_audio.dart' show AudioPlayer, ProcessingState;
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/av_music_player.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

Song _song(String id, String title, {int dur = 260}) => Song(
      songId: id,
      title: title,
      artist: 'Singer $id',
      platform: MusicPlatform.wy,
      dur: dur,
    );

String _url(String id) => 'https://example.com/$id.mp3';

class _FakeApi extends MusicApi {
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

class _UrlResolvers extends MusicResolvers {
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
    return PlayUrlResult(
      url: _url(songId),
      candidates: [_url(songId)],
      quality: quality,
      via: 'test',
    );
  }
}

class _FakeStreams extends AvMusicPlayerStreams {
  _FakeStreams() : super(AudioPlayer());

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<bool>.broadcast();

  @override
  Stream<Duration> get position => _position.stream;

  @override
  Stream<Duration> get duration => _duration.stream;

  @override
  Stream<bool> get playing => _playing.stream;

  @override
  Stream<String> get error => _error.stream;

  @override
  Stream<bool> get completed => _completed.stream;
}

class _FakePlayer extends AvMusicPlayer {
  _FakePlayer() : streams = _FakeStreams();

  final _FakeStreams streams;
  final List<String> openedUrls = [];
  final List<double> volumes = [];
  var playCalls = 0;
  var pauseCalls = 0;
  double _volume = 1.0;

  @override
  AvMusicPlayerStreams get stream => streams;

  @override
  double get volume => _volume;

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    return true;
  }

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Future<void> play() async {
    playCalls++;
  }

  @override
  Future<void> pause() async {
    pauseCalls++;
  }

  @override
  Future<void> setVolume(double volume) async {
    _volume = volume;
    volumes.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  late Box<dynamic> box;
  late _FakePlayer playerA;
  late _FakePlayer playerB;
  late MusicPlayerController c;

  setUp(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    Hive.init('test/.hive-b29-sleep-fade');
    box = await Hive.openBox<dynamic>('b29_sleep_fade_test');
    await box.clear();
    HiveStore.setTestBox(box);
    playerA = _FakePlayer();
    playerB = _FakePlayer();
    c = MusicPlayerController(
      api: _FakeApi(),
      resolvers: _UrlResolvers(),
      playerA: playerA,
      playerB: playerB,
    );
    c.onInit();
    c.queue.assignAll([_song('1', 'A'), _song('2', 'B'), _song('3', 'C')]);
    c.currentIndex.value = 0;
  });

  tearDown(() async {
    c.onClose();
    Get.reset();
    await box.close();
    await Hive.deleteBoxFromDisk('b29_sleep_fade_test');
  });

  /// Poll until [check] holds (up to ~10 s). Fixed short delays flake
  /// when the VM is loaded — parallel agents starve the event loop.
  Future<void> waitForCondition(bool Function() check) async {
    for (var i = 0; i < 200; i++) {
      if (check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(check(), isTrue);
  }

  Future<void> loadA() async {
    await c.playQueue([_song('1', 'A'), _song('2', 'B'), _song('3', 'C')], 0);
    await waitForCondition(() => playerA.openedUrls.isNotEmpty);
  }

  group('A. sleep fired, then track completes during the 1 s fade', () {
    test('the next song must NOT start after the deadline', () async {
      await loadA();
      expect(c.currentIndex.value, 0);

      // Wall-clock sleep timer fires; the 1 s fade-out starts.
      c.simulateSleepTimerFiredForTest();
      // The track ends while the fade is still running.
      playerA.streams._completed.add(true);

      // A crossfade takes 2.5 s; give any buggy advance time to land
      // and finish, then check the settled state.
      await Future<void>.delayed(const Duration(milliseconds: 4000));

      expect(c.currentIndex.value, 0,
          reason: 'sleep fired: completion must stop, not advance');
      expect(playerB.openedUrls, isEmpty,
          reason: 'the next song must never open after the deadline');
      expect(playerB.playCalls, 0,
          reason: 'the next song must never sound after the deadline');
      expect(playerA.pauseCalls, greaterThanOrEqualTo(1));
    });
  });

  group('B. sleep fires mid-crossfade', () {
    test('the incoming song must not jump up to full volume', () async {
      await loadA();
      await c.next(auto: true);
      await waitForCondition(() => playerB.playCalls == 1);
      // ~1 s into the 2.5 s crossfade: incoming is at ~40% volume.
      await Future<void>.delayed(const Duration(milliseconds: 1000));
      expect(playerB.volumes.last, lessThan(0.6));

      final mark = playerB.volumes.length;
      final volAtFire = playerB.volumes.last;
      c.simulateSleepTimerFiredForTest();

      // The sleep fade ends by pausing both players.
      await waitForCondition(
        () => playerA.pauseCalls >= 1 && playerB.pauseCalls >= 1,
      );

      // After the fire the incoming volume may only go DOWN from
      // where it really was (+0.10 slack for one in-flight crossfade
      // tick). A jump to ~0.9/1.0 is the bug: the sleep fade restarts
      // from _currentNormGain (full) instead of the actual volume.
      final after = playerB.volumes.sublist(mark);
      expect(after, isNotEmpty);
      expect(
        after.every((v) => v <= volAtFire + 0.10),
        isTrue,
        reason: 'volumes after the fire: $after (at fire: $volAtFire)',
      );
      expect(playerA.pauseCalls, greaterThanOrEqualTo(1));
      expect(playerB.pauseCalls, greaterThanOrEqualTo(1));
    });
  });

  group('C. pause during the resume fade-in', () {
    test('the fade-out must start from the actual volume, not full',
        () async {
      await loadA();
      // Playing, then paused (400 ms fade-out, awaited).
      playerA.streams._playing.add(true);
      await waitForCondition(() => c.isPlaying.value);
      await c.pause();
      await waitForCondition(() => playerA.pauseCalls >= 1);
      playerA.streams._playing.add(false);
      await waitForCondition(() => !c.isPlaying.value);

      // Resume: the 400 ms fade-in ramp starts (unawaited).
      await c.togglePlayPause();
      await Future<void>.delayed(const Duration(milliseconds: 150));
      // Mid-ramp: the volume is still well below full.
      expect(playerA.volumes.last, lessThan(0.6));
      playerA.streams._playing.add(true);
      await waitForCondition(() => c.isPlaying.value);

      final mark = playerA.volumes.length;
      await c.pause();
      await waitForCondition(() => playerA.pauseCalls >= 2);

      // After the pause the volume may only go DOWN from mid-ramp.
      // The buggy fade-out restarts from _currentNormGain (1.0):
      // first step ~0.875, restore 1.0 — both above 0.8. The stale
      // fade-in ramp also keeps writing rising volumes while the
      // fade-out runs.
      final after = playerA.volumes.sublist(mark);
      expect(after, isNotEmpty);
      expect(
        after.every((v) => v <= 0.8),
        isTrue,
        reason: 'volumes after the mid-ramp pause: $after',
      );
    });
  });
}
