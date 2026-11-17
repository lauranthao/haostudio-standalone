// Listen-report tests (v1.0.9 fixes for chen's "听歌报告有bug").
//
// Pure-Dart behaviour of the report chain:
// - top-song duration is the FULL song length (totalDur), not the
//   seconds actually heard (BUG 1);
// - week/month are CALENDAR ranges: Monday 00:00 / 1st 00:00 local
//   to now (BUG 4);
// - the in-progress session is visible as a snapshot without being
//   persisted or double-counted (BUG 5);
// - bar labels are sparse when there are many bars (BUG 3);
// - the empty-state message names the selected range (BUG 6).
// BUG 2 (last song in the queue never recorded) is a one-line move
// in _onTrackCompleted; double-finalise safety is already covered by
// music_test.dart ('finish twice -> null the second time').

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/music/listen_report_page.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

Song _song(String id, String title, {int dur = 240}) =>
    Song(songId: id, title: title, platform: MusicPlatform.wy, dur: dur);

ListenEvent _ev(
  String id,
  String title, {
  int dur = 0,
  int totalDur = 240,
  required DateTime at,
}) =>
    ListenEvent(
      songId: id,
      title: title,
      dur: dur,
      totalDur: totalDur,
      at: at.millisecondsSinceEpoch,
    );

void main() {
  // Tue 2026-11-17 12:00 local — the day chen reported the bug.
  final now = DateTime(2026, 11, 17, 12, 0, 0);

  group('BUG 1: top-song duration is the song length', () {
    test('240 s song heard 47 s shows dur 240, not 47', () {
      final report = ListenReport.compute(
        [_ev('1', 'A', dur: 47, totalDur: 240, at: now)],
        'all',
        now: now,
      );
      expect(report.topSongs.single.song.dur, 240);
    });

    test('legacy event without totalDur shows dur 0 (row hides it)', () {
      final report = ListenReport.compute(
        [_ev('1', 'A', dur: 47, totalDur: 0, at: now)],
        'all',
        now: now,
      );
      expect(report.topSongs.single.song.dur, 0);
    });

    test('tracker finish() records totalDur = song.dur', () {
      final tr = ListenSessionTracker();
      final t0 = DateTime(2026, 11, 17, 12, 0, 0);
      tr.begin(_song('1', 'A', dur: 240), t0);
      tr.setPlaying(true, t0);
      final ev = tr.finish(t0.add(const Duration(seconds: 47)));
      expect(ev!.dur, 47);
      expect(ev.totalDur, 240);
    });
  });

  group('BUG 4: calendar week / month', () {
    test('week excludes last Friday, includes Monday', () {
      final friday = DateTime(2026, 11, 13, 20, 0, 0); // last Fri
      final monday = DateTime(2026, 11, 16, 20, 0, 0);
      final report = ListenReport.compute(
        [
          _ev('1', 'Fri', at: friday),
          _ev('2', 'Mon', at: monday),
        ],
        'week',
        now: now,
      );
      expect(report.totalPlays, 1);
      expect(report.topSongs.single.song.title, 'Mon');
      // Bars run Monday..today (2 bars), not 7 rolling days.
      expect(report.perDay.length, 2);
      expect(report.perDay.map((d) => d.label), ['11-16', '11-17']);
    });

    test('month excludes Oct 31, includes Nov 1', () {
      final oct31 = DateTime(2026, 10, 31, 20, 0, 0);
      final nov1 = DateTime(2026, 11, 1, 20, 0, 0);
      final report = ListenReport.compute(
        [
          _ev('1', 'Oct', at: oct31),
          _ev('2', 'Nov', at: nov1),
        ],
        'month',
        now: now,
      );
      expect(report.totalPlays, 1);
      // Bars run 1st..today (17 bars).
      expect(report.perDay.length, 17);
      expect(report.perDay.first.label, '11-01');
      expect(report.perDay.last.label, '11-17');
    });

    test('all is unaffected by the range change', () {
      final old = DateTime(2026, 1, 5, 12, 0, 0);
      final report = ListenReport.compute(
        [_ev('1', 'Old', at: old)],
        'all',
        now: now,
      );
      expect(report.totalPlays, 1);
    });
  });

  group('BUG 5: in-progress session snapshot', () {
    test('playing 47 s of a 240 s song snapshots dur 47 / totalDur 240', () {
      final tr = ListenSessionTracker();
      final t0 = DateTime(2026, 11, 17, 12, 0, 0);
      tr.begin(_song('1', 'A', dur: 240), t0);
      tr.setPlaying(true, t0);
      final snap = tr.currentEvent(t0.add(const Duration(seconds: 47)));
      expect(snap, isNotNull);
      expect(snap!.dur, 47);
      expect(snap.totalDur, 240);
      expect(snap.at, t0.millisecondsSinceEpoch);
    });

    test('paused session snapshots only the accumulated seconds', () {
      final tr = ListenSessionTracker();
      final t0 = DateTime(2026, 11, 17, 12, 0, 0);
      tr.begin(_song('1', 'A', dur: 240), t0);
      tr.setPlaying(true, t0);
      tr.setPlaying(false, t0.add(const Duration(seconds: 10)));
      final snap = tr.currentEvent(t0.add(const Duration(seconds: 100)));
      expect(snap, isNotNull);
      expect(snap!.dur, 10);
    });

    test('under 5 s heard -> null; no session -> null', () {
      final tr = ListenSessionTracker();
      final t0 = DateTime(2026, 11, 17, 12, 0, 0);
      tr.begin(_song('1', 'A', dur: 240), t0);
      tr.setPlaying(true, t0);
      expect(tr.currentEvent(t0.add(const Duration(seconds: 4))), isNull);
      expect(ListenSessionTracker().currentEvent(t0), isNull);
    });

    test('snapshot does not close the session (finish still returns it)', () {
      final tr = ListenSessionTracker();
      final t0 = DateTime(2026, 11, 17, 12, 0, 0);
      tr.begin(_song('1', 'A', dur: 240), t0);
      tr.setPlaying(true, t0);
      expect(tr.currentEvent(t0.add(const Duration(seconds: 10))), isNotNull);
      final ev = tr.finish(t0.add(const Duration(seconds: 10)));
      expect(ev, isNotNull);
      expect(ev!.dur, 10);
    });
  });

  group('BUG 3: sparse bar labels', () {
    test('short ranges show every label', () {
      for (var total = 1; total <= 10; total++) {
        for (var i = 0; i < total; i++) {
          expect(showBarLabel(i, total), isTrue);
        }
      }
    });

    test('30 bars show only every 5th + the last', () {
      final shown = [for (var i = 0; i < 30; i++) if (showBarLabel(i, 30)) i];
      expect(shown, [0, 5, 10, 15, 20, 25, 29]);
    });
  });

  group('BUG 6: range-aware empty message', () {
    test('week / month / all each name their range', () {
      expect(listenReportEmptyText('week'), '本周还没有听歌记录');
      expect(listenReportEmptyText('month'), '本月还没有听歌记录');
      expect(
        listenReportEmptyText('all'),
        '还没有听歌记录，统计从现在开始累计',
      );
    });
  });
}
