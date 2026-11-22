// 年度回顾 (build 29, music) — year-in-review from the local listen
// log. Pure compute over ListenEvents, same shapes as ListenReport
// (TopSong / TopArtist) so the report page reuses its rows. A year
// with no plays reports zero everything — the page shows the empty
// state instead of inventing a summary.

import 'music_models.dart';
import 'music_store.dart';

class YearReview {
  YearReview({
    required this.year,
    required this.totalPlays,
    required this.totalSeconds,
    required this.topSongs,
    required this.topArtists,
    required this.monthlyPlays,
    required this.topMonth,
    required this.daysListened,
  });

  /// Total listening time in whole minutes (seconds / 60, rounded).
  int get totalMinutes => (totalSeconds / 60).round();

  String get totalTimeText {
    final m = totalMinutes;
    if (m >= 60) return '${m ~/ 60}小时${m % 60}分';
    return '$m分钟';
  }

  final int year;
  final int totalPlays;
  final int totalSeconds;
  final List<TopSong> topSongs;
  final List<TopArtist> topArtists;

  /// Plays per month, index 0 = January.
  final List<int> monthlyPlays;

  /// 1..12 = the busiest month, 0 = no plays at all.
  final int topMonth;

  /// Distinct days with at least one play.
  final int daysListened;

  static YearReview compute(List<ListenEvent> all, int year) {
    final evs =
        all.where((e) => DateTime.fromMillisecondsSinceEpoch(e.at).year == year).toList();
    var totalSec = 0;
    final bySong = <String, TopSong>{};
    final byArtist = <String, int>{};
    final monthly = List<int>.filled(12, 0);
    final days = <String>{};
    for (final e in evs) {
      totalSec += e.dur;
      final date = DateTime.fromMillisecondsSinceEpoch(e.at);
      monthly[date.month - 1]++;
      days.add(dayKeyOf(date));
      final sk = '${e.platform.code}|${e.songId}';
      final prev = bySong[sk];
      bySong[sk] = TopSong(
        song: Song(
          songId: e.songId,
          title: e.title,
          artist: e.artist,
          platform: e.platform,
          cover: e.cover,
          dur: e.totalDur,
        ),
        plays: (prev?.plays ?? 0) + 1,
      );
      byArtist[e.artist.isEmpty ? '—' : e.artist] =
          (byArtist[e.artist.isEmpty ? '—' : e.artist] ?? 0) + 1;
    }
    final topSongs = bySong.values.toList()
      ..sort((a, b) => b.plays.compareTo(a.plays));
    final topArtists = byArtist.entries
        .map((e) => TopArtist(artist: e.key, plays: e.value))
        .toList()
      ..sort((a, b) => b.plays.compareTo(a.plays));
    var topMonth = 0;
    var topCount = 0;
    for (var i = 0; i < 12; i++) {
      if (monthly[i] > topCount) {
        topCount = monthly[i];
        topMonth = i + 1;
      }
    }
    return YearReview(
      year: year,
      totalPlays: evs.length,
      totalSeconds: totalSec,
      topSongs: topSongs.take(5).toList(),
      topArtists: topArtists.take(5).toList(),
      monthlyPlays: monthly,
      topMonth: topMonth,
      daysListened: days.length,
    );
  }
}
