// 1.1.6 睡眠定时三模式 — SleepTimer 纯逻辑 (fake_async, 无等待).
//
// Covers the two new completion modes:
// - 播完本首后停止 (currentTrackEnd): active, no clock, never fires.
// - 播完 N 首后停止 (afterNTracks): only natural completions count
//   (noteTrackCompleted), target reached reports true, changing N
//   mid-run recounts from zero, clamp 1..10, cancel resets.
// The controller half (stop before single-loop replay, no advance
// at the target, manual next not counting) lives in
// v16_music_sleep_norm_bookmark_test.dart.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/sleep_timer.dart';

void main() {
  group('clampSleepTrackCount (1.1.6)', () {
    test('1..10 pass through, out of range clamps, null falls back to 3', () {
      expect(clampSleepTrackCount(1), 1);
      expect(clampSleepTrackCount(3), 3);
      expect(clampSleepTrackCount(10), 10);
      expect(clampSleepTrackCount(0), 1);
      expect(clampSleepTrackCount(-5), 1);
      expect(clampSleepTrackCount(11), 10);
      expect(clampSleepTrackCount(999), 10);
      expect(clampSleepTrackCount(null), 3);
    });
  });

  group('currentTrackEnd option', () {
    test('is active but has no clock and never fires on its own', () {
      var fired = 0;
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () => fired++);
        timer.start(SleepTimerOption.currentTrackEnd);
        expect(timer.isActive, isTrue);
        expect(timer.isCurrentTrackEnd, isTrue);
        expect(timer.isAfterNTracks, isFalse);
        expect(timer.isQueueEnd, isFalse);
        expect(timer.remaining, isNull);
        expect(timer.remainingText, '');
        expect(SleepTimerOption.currentTrackEnd.duration, isNull);
        expect(SleepTimerOption.currentTrackEnd.label, '播完本首后停止');
        async.elapse(const Duration(hours: 5));
        expect(fired, 0);
      });
    });

    test('noteTrackCompleted is a no-op outside afterNTracks', () {
      final timer = SleepTimer(onFire: () {});
      timer.start(SleepTimerOption.currentTrackEnd);
      expect(timer.noteTrackCompleted(), isFalse);
      expect(timer.tracksCompleted, 0);
    });
  });

  group('afterNTracks option', () {
    test('counts natural completions, reports true exactly at the target',
        () {
      final timer = SleepTimer(onFire: () {});
      timer.startAfterNTracks(2);
      expect(timer.isActive, isTrue);
      expect(timer.isAfterNTracks, isTrue);
      expect(timer.trackTarget, 2);
      expect(timer.tracksCompleted, 0);
      expect(timer.remaining, isNull);
      expect(SleepTimerOption.afterNTracks.duration, isNull);
      expect(SleepTimerOption.afterNTracks.label, '播完 N 首后停止');

      // First completion: counted, not yet reached.
      expect(timer.noteTrackCompleted(), isFalse);
      expect(timer.tracksCompleted, 1);
      // Second completion: reached.
      expect(timer.noteTrackCompleted(), isTrue);
      expect(timer.tracksCompleted, 2);
    });

    test('N=1 is the same as current-track-end (first completion stops)',
        () {
      final timer = SleepTimer(onFire: () {});
      timer.startAfterNTracks(1);
      expect(timer.noteTrackCompleted(), isTrue);
    });

    test('startAfterNTracks clamps before starting', () {
      final timer = SleepTimer(onFire: () {});
      timer.startAfterNTracks(0);
      expect(timer.trackTarget, 1);
      timer.startAfterNTracks(99);
      expect(timer.trackTarget, 10);
    });

    test('start(afterNTracks) replays the last N target', () {
      final timer = SleepTimer(onFire: () {});
      timer.startAfterNTracks(4);
      timer.cancel();
      timer.start(SleepTimerOption.afterNTracks);
      expect(timer.trackTarget, 4);
      expect(timer.tracksCompleted, 0);
    });

    test('changing N mid-run recounts from zero', () {
      final timer = SleepTimer(onFire: () {});
      timer.startAfterNTracks(3);
      expect(timer.noteTrackCompleted(), isFalse);
      expect(timer.tracksCompleted, 1);
      // Change N to 2: the already-counted track does not carry over.
      timer.setTrackTarget(2);
      expect(timer.trackTarget, 2);
      expect(timer.tracksCompleted, 0);
      expect(timer.noteTrackCompleted(), isFalse);
      expect(timer.noteTrackCompleted(), isTrue);
    });

    test('setTrackTarget with no run active only remembers the target',
        () {
      final timer = SleepTimer(onFire: () {});
      timer.setTrackTarget(5);
      expect(timer.trackTarget, 5);
      expect(timer.isActive, isFalse);
      timer.start(SleepTimerOption.afterNTracks);
      expect(timer.trackTarget, 5);
      expect(timer.tracksCompleted, 0);
    });

    test('cancel resets the count; a new run starts from zero', () {
      final timer = SleepTimer(onFire: () {});
      timer.startAfterNTracks(2);
      expect(timer.noteTrackCompleted(), isFalse);
      timer.cancel();
      expect(timer.tracksCompleted, 0);
      expect(timer.isActive, isFalse);
      timer.startAfterNTracks(2);
      expect(timer.tracksCompleted, 0);
      expect(timer.noteTrackCompleted(), isFalse);
      expect(timer.noteTrackCompleted(), isTrue);
    });

    test('switching to a wall-clock option drops the count', () {
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () {});
        timer.startAfterNTracks(2);
        expect(timer.noteTrackCompleted(), isFalse);
        timer.start(SleepTimerOption.min15);
        expect(timer.isAfterNTracks, isFalse);
        expect(timer.tracksCompleted, 0);
        expect(timer.remaining, const Duration(minutes: 15));
      });
    });

    test('new options are in the sheet order, after queue-end', () {
      expect(
        SleepTimerOptionX.all,
        containsAllInOrder([
          SleepTimerOption.queueEnd,
          SleepTimerOption.currentTrackEnd,
          SleepTimerOption.afterNTracks,
          SleepTimerOption.custom,
          SleepTimerOption.off,
        ]),
      );
    });
  });
}
