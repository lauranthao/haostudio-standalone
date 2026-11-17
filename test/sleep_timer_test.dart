// Sleep timer (M-P0-3) — wall-clock countdown + queue-end + cancel.
//
// Uses fake_async so the 1 s ticker is deterministic: no real waiting.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/sleep_timer.dart';

void main() {
  group('SleepTimer wall-clock countdown', () {
    test('fires once at zero and clears itself', () {
      var fired = 0;
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () => fired++);
        timer.start(SleepTimerOption.min15);
        expect(timer.isActive, isTrue);
        expect(timer.remaining, const Duration(minutes: 15));
        expect(timer.remainingText, '15:00');

        async.elapse(const Duration(minutes: 14, seconds: 59));
        expect(fired, 0);
        expect(timer.isActive, isTrue);
        expect(timer.remaining, const Duration(seconds: 1));
        expect(timer.remainingText, '0:01');

        async.elapse(const Duration(seconds: 1));
        expect(fired, 1);
        expect(timer.isActive, isFalse);
        expect(timer.remaining, isNull);

        // No second firing after more time passes.
        async.elapse(const Duration(minutes: 10));
        expect(fired, 1);
      });
    });

    test('remaining text counts down honestly', () {
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () {});
        timer.start(SleepTimerOption.min30);
        async.elapse(const Duration(seconds: 61));
        expect(timer.remaining, const Duration(minutes: 28, seconds: 59));
        expect(timer.remainingText, '28:59');
      });
    });

    test('all timed options carry the right duration', () {
      expect(SleepTimerOption.min15.duration, const Duration(minutes: 15));
      expect(SleepTimerOption.min30.duration, const Duration(minutes: 30));
      expect(SleepTimerOption.min60.duration, const Duration(minutes: 60));
      expect(SleepTimerOption.min90.duration, const Duration(minutes: 90));
      expect(SleepTimerOption.queueEnd.duration, isNull);
      expect(SleepTimerOption.off.duration, isNull);
    });
  });

  group('cancel', () {
    test('cancel clears the timer and it never fires', () {
      var fired = 0;
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () => fired++);
        timer.start(SleepTimerOption.min30);
        async.elapse(const Duration(minutes: 10));
        timer.cancel();
        expect(timer.isActive, isFalse);
        expect(timer.remaining, isNull);
        async.elapse(const Duration(hours: 1));
        expect(fired, 0);
      });
    });

    test('starting off cancels an active timer', () {
      var fired = 0;
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () => fired++);
        timer.start(SleepTimerOption.min15);
        timer.start(SleepTimerOption.off);
        expect(timer.isActive, isFalse);
        async.elapse(const Duration(hours: 1));
        expect(fired, 0);
      });
    });
  });

  group('queue-end option', () {
    test('is active but has no clock and never fires on its own', () {
      var fired = 0;
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () => fired++);
        timer.start(SleepTimerOption.queueEnd);
        expect(timer.isActive, isTrue);
        expect(timer.isQueueEnd, isTrue);
        expect(timer.remaining, isNull);
        expect(timer.remainingText, '');
        async.elapse(const Duration(hours: 5));
        expect(fired, 0);
      });
    });
  });

  group('restart', () {
    test('starting a new option replaces the old countdown', () {
      fakeAsync((async) {
        final timer = SleepTimer(onFire: () {});
        timer.start(SleepTimerOption.min15);
        async.elapse(const Duration(minutes: 5));
        expect(timer.remaining, const Duration(minutes: 10));
        timer.start(SleepTimerOption.min60);
        expect(timer.remaining, const Duration(minutes: 60));
        async.elapse(const Duration(minutes: 10));
        expect(timer.remaining, const Duration(minutes: 50));
      });
    });

    test('onChanged fires on start, tick and cancel', () {
      fakeAsync((async) {
        var changed = 0;
        final timer = SleepTimer(onFire: () {}, onChanged: () => changed++);
        // start() cancels any previous timer first, then reports start:
        // 2 calls.
        timer.start(SleepTimerOption.min15);
        expect(changed, 2);
        async.elapse(const Duration(seconds: 3));
        expect(changed, 5);
        timer.cancel();
        expect(changed, 6);
      });
    });
  });

  group('option labels', () {
    test('sheet order and labels', () {
      expect(SleepTimerOptionX.all.map((o) => o.label).toList(), [
        '5 分钟',
        '15 分钟',
        '30 分钟',
        '45 分钟',
        '60 分钟',
        '90 分钟',
        '到歌单结束',
        '自定义',
        '关闭',
      ]);
    });

    test('new 5/45 options carry their durations (Beans sleep ladder)', () {
      expect(SleepTimerOption.min5.duration, const Duration(minutes: 5));
      expect(SleepTimerOption.min45.duration, const Duration(minutes: 45));
    });
  });
}
