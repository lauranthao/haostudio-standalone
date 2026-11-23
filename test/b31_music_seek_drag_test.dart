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
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/play_mode.dart';

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
  final positionCtrl = StreamController<Duration>.broadcast();
  final durationCtrl = StreamController<Duration>.broadcast();
  final playingCtrl = StreamController<bool>.broadcast();
  final errorCtrl = StreamController<String>.broadcast();
  final completedCtrl = StreamController<bool>.broadcast();

  @override
  AvMusicPlayerStreams get stream => _SeekFakeStreams(this);

  @override
  Future<bool> open(String url, {bool play = true}) async => true;

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
}
