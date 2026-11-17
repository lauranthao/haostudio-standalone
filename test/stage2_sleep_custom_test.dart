// Stage 2 item 2 — custom-minutes sleep timer (Beans
// `SleepTimerSheet` 自定义时长, SleepTimerSheet.swift:61:
// `min(max(Int(text) ?? 30, 1), 720)`).
//
// Timer behaviour uses fake_async (no real waiting); persistence goes
// through MusicStore on a throwaway Hive box.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/music_store.dart';
import 'package:standalone/services/music/sleep_timer.dart';

void main() {
  group('clampSleepCustomMinutes (Beans clamp, copied exactly)', () {
    test('1..720 pass through, out of range clamps', () {
      expect(clampSleepCustomMinutes(1), 1);
      expect(clampSleepCustomMinutes(45), 45);
      expect(clampSleepCustomMinutes(720), 720);
      expect(clampSleepCustomMinutes(0), 1);
      expect(clampSleepCustomMinutes(-5), 1);
      expect(clampSleepCustomMinutes(721), 720);
      expect(clampSleepCustomMinutes(9999), 720);
    });

    test('null / unparseable input falls back to 30', () {
      expect(clampSleepCustomMinutes(null), 30);
      expect(clampSleepCustomMinutes(int.tryParse('abc')), 30);
      expect(clampSleepCustomMinutes(int.tryParse('')), 30);
    });
  });

  group('SleepTimer.startCustom', () {
    test('fires once at the custom minute count and clears itself', () {
      var fired = 0;
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () => fired++);
        timer.startCustom(45);
        expect(timer.option, SleepTimerOption.custom);
        expect(timer.customMinutes, 45);
        expect(timer.isActive, isTrue);
        expect(timer.remaining, const Duration(minutes: 45));
        async.elapse(const Duration(minutes: 44, seconds: 59));
        expect(fired, 0);
        async.elapse(const Duration(seconds: 1));
        expect(fired, 1);
        expect(timer.isActive, isFalse);
        expect(timer.remaining, isNull);
      });
    });

    test('startCustom clamps before starting', () {
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () {});
        timer.startCustom(0);
        expect(timer.customMinutes, 1);
        expect(timer.remaining, const Duration(minutes: 1));
        timer.startCustom(999);
        expect(timer.customMinutes, 720);
        expect(timer.remaining, const Duration(minutes: 720));
      });
    });

    test('start(custom) replays the last custom minutes', () {
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () {});
        timer.startCustom(20);
        timer.cancel();
        timer.start(SleepTimerOption.custom);
        expect(timer.remaining, const Duration(minutes: 20));
      });
    });

    test('custom option has no fixed duration and a distinct label', () {
      expect(SleepTimerOption.custom.duration, isNull);
      expect(SleepTimerOption.custom.label, '自定义');
      expect(SleepTimerOptionX.all, contains(SleepTimerOption.custom));
    });
  });

  group('MusicStore.sleepCustomMinutes persistence', () {
    late Box<dynamic> box;

    setUp(() async {
      Hive.init('test/.hive-stage2-sleep-custom');
      box = await Hive.openBox<dynamic>('stage2_sleep_custom_test');
      await box.clear();
      HiveStore.setTestBox(box);
    });

    tearDown(() async {
      await box.close();
      await Hive.deleteBoxFromDisk('stage2_sleep_custom_test');
    });

    test('defaults to 30, round-trips, clamps on write', () async {
      expect(MusicStore.sleepCustomMinutes, 30);
      await MusicStore.setSleepCustomMinutes(45);
      expect(MusicStore.sleepCustomMinutes, 45);
      await MusicStore.setSleepCustomMinutes(0);
      expect(MusicStore.sleepCustomMinutes, 1);
      await MusicStore.setSleepCustomMinutes(999);
      expect(MusicStore.sleepCustomMinutes, 720);
    });
  });
}
