// Music speed (M-P0-2) — slider range, persistence, lyrics sync.
//
// Covers: clamp to 0.6–2.0, setSpeed persists like quality (Hive,
// default 1.0), and the lyrics-sync invariant — lyrics are keyed to
// the media clock (lyricIndexFor(position)), so changing the rate
// cannot desync them: the same media position maps to the same lyric
// line at any speed.
//
// The controller is constructed directly (no Get.put, so onInit never
// runs and no native media_kit players are created): speed/queue
// logic is exercised without a player, and setSpeed skips the rate
// application while the players are not ready (see _playersReady).

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

void main() {
  late Box<dynamic> box;

  setUp(() async {
    Hive.init('test/.hive-speed-test');
    box = await Hive.openBox<dynamic>('speed_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('speed_test');
  });

  group('clampSpeed', () {
    test('range is 0.6–2.0', () {
      expect(MusicPlayerController.clampSpeed(0.6), 0.6);
      expect(MusicPlayerController.clampSpeed(2.0), 2.0);
      expect(MusicPlayerController.clampSpeed(1.0), 1.0);
      expect(MusicPlayerController.clampSpeed(1.5), 1.5);
    });

    test('below 0.6 clamps up, above 2.0 clamps down', () {
      expect(MusicPlayerController.clampSpeed(0.3), 0.6);
      expect(MusicPlayerController.clampSpeed(0.0), 0.6);
      expect(MusicPlayerController.clampSpeed(-1.0), 0.6);
      expect(MusicPlayerController.clampSpeed(2.5), 2.0);
      expect(MusicPlayerController.clampSpeed(10.0), 2.0);
    });

    test('slider step 0.05 lands inside the range', () {
      // 28 divisions over 0.6–2.0 (the sheet slider).
      for (var i = 0; i <= 28; i++) {
        final v = 0.6 + (2.0 - 0.6) * i / 28;
        expect(
          MusicPlayerController.clampSpeed(v),
          closeTo(v, 1e-9),
        );
      }
    });
  });

  group('setSpeed persistence', () {
    test('default is 1.0', () {
      expect(MusicStore.speed, 1.0);
    });

    test('setSpeed updates the controller and persists', () async {
      final c = MusicPlayerController();
      await c.setSpeed(1.5);
      expect(c.speed.value, 1.5);
      expect(MusicStore.speed, 1.5);
    });

    test('out-of-range values persist clamped', () async {
      final c = MusicPlayerController();
      await c.setSpeed(0.3);
      expect(c.speed.value, 0.6);
      expect(MusicStore.speed, 0.6);
      await c.setSpeed(2.5);
      expect(c.speed.value, 2.0);
      expect(MusicStore.speed, 2.0);
    });

    test('speed survives a fresh read (restart)', () async {
      final c = MusicPlayerController();
      await c.setSpeed(1.25);
      // A new controller reads the persisted value in onInit; here we
      // verify the store itself, which is what onInit reads.
      expect(MusicStore.speed, 1.25);
    });
  });

  group('lyrics stay in sync at any speed', () {
    late MusicPlayerController c;

    setUp(() {
      c = MusicPlayerController();
      c.lyrics.clear();
      c.lyrics.addAll([
        LyricLine(t: 0, text: 'first'),
        LyricLine(t: 10, text: 'second'),
        LyricLine(t: 20, text: 'third'),
        LyricLine(t: 30, text: 'fourth'),
      ]);
    });

    test('lyricIndexFor maps media positions to lines', () {
      expect(c.lyricIndexFor(Duration.zero), 0);
      expect(c.lyricIndexFor(const Duration(seconds: 9)), 0);
      expect(c.lyricIndexFor(const Duration(seconds: 10)), 1);
      expect(c.lyricIndexFor(const Duration(seconds: 25)), 2);
      expect(c.lyricIndexFor(const Duration(seconds: 30)), 3);
      expect(c.lyricIndexFor(const Duration(minutes: 5)), 3);
    });

    test('no lyrics yet returns -1', () {
      final empty = MusicPlayerController();
      expect(empty.lyricIndexFor(const Duration(seconds: 5)), -1);
    });

    test('same media position, same line — at 0.6×, 1× and 2×', () async {
      // Lyrics are keyed to the media clock, not wall time: the
      // player position stream advances at rate × real time, so the
      // mapping itself must be speed-independent.
      const positions = [
        Duration(seconds: 0),
        Duration(seconds: 5),
        Duration(seconds: 10),
        Duration(seconds: 19, milliseconds: 999),
        Duration(seconds: 20),
        Duration(seconds: 45),
      ];
      final at1x = positions.map(c.lyricIndexFor).toList();
      for (final speed in [0.6, 1.0, 1.25, 2.0]) {
        await c.setSpeed(speed);
        expect(
          positions.map(c.lyricIndexFor).toList(),
          at1x,
          reason: 'lyric mapping must not change at $speed×',
        );
      }
    });
  });
}
