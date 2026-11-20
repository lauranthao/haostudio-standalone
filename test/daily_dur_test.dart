// Daily picks + favourites must not mistake "listened seconds" for the
// song's length (audit P1-9(a) class).
//
// ListenEvent carries BOTH numbers: `dur` = seconds actually heard in
// that session, `totalDur` = the song's full length. Song.dur is the
// full length everywhere it is displayed (SongRow shows it as the
// song's duration). Two builders passed the wrong one:
// - DailyService.toDaily used `dur: ev.dur` — a daily row for a song
//   heard for 30 s showed "0:30" as its length instead of "4:20".
// - MusicStore.getFavSongs' listen-log fallback used `dur: e.dur` —
//   a legacy key-only favourite resolved from history showed the
//   heard seconds as its length.
// ListenReport.compute already used totalDur for the row (fixed
// earlier); the report's TOTAL time still sums `dur` (heard seconds)
// — that split is the point, and the sibling test below pins it.

import 'package:dio/dio.dart';
import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/daily_service.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';

/// No discovery / hot fill: every platform answers empty, so the daily
/// list is exactly the "because you listened" rows from the log.
class _EmptyApi extends MusicApi {
  @override
  Future<List<Song>> searchWy(
    String q,
    int limit, {
    CancelToken? cancelToken,
  }) async => [];

  @override
  Future<List<Song>> searchTx(
    String q,
    int limit, {
    CancelToken? cancelToken,
  }) async => [];

  @override
  Future<List<PlaylistSummary>> plaza(MusicPlatform pf) async => [];
}

ListenEvent _event({
  required String songId,
  required int heardSec,
  required int songLenSec,
  DateTime? at,
}) => ListenEvent(
  songId: songId,
  title: 'Song $songId',
  artist: 'Singer',
  platform: MusicPlatform.wy,
  cover: '',
  dur: heardSec,
  totalDur: songLenSec,
  at: (at ?? DateTime.now()).millisecondsSinceEpoch,
);

void main() {
  late Box<dynamic> box;

  setUp(() async {
    Hive.init('test/.hive-daily-dur-test');
    box = await Hive.openBox<dynamic>('daily_dur_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('daily_dur_test');
  });

  test('daily pick dur is the song length, not the heard seconds', () async {
    await MusicStore.recordListenEvent(
      _event(songId: '1', heardSec: 30, songLenSec: 260),
    );
    final service = DailyService(api: _EmptyApi());
    final (tracks: tracks, cold: _) = await service.buildDaily();
    expect(tracks.map((s) => s.songId), contains('1'));
    final song = tracks.firstWhere((s) => s.songId == '1');
    expect(song.dur, 260, reason: 'full song length');
    expect(song.dur, isNot(30), reason: 'must not be the heard seconds');
  });

  test('legacy favourite resolved from history carries the song length',
      () async {
    await MusicStore.recordListenEvent(
      _event(songId: '2', heardSec: 45, songLenSec: 200),
    );
    // Legacy key-only entry (no stored Song JSON): the page resolves
    // it from the listen log.
    await HiveStore.put(
      HiveKeys.musicFav,
      jsonEncode([
        {'key': 'wy|2'},
      ]),
    );
    final favs = MusicStore.getFavSongs();
    expect(favs.map((s) => s.songId), contains('2'));
    final song = favs.firstWhere((s) => s.songId == '2');
    expect(song.dur, 200, reason: 'full song length');
    expect(song.dur, isNot(45), reason: 'must not be the heard seconds');
  });

  test('sibling: report total still sums heard seconds, row shows length',
      () async {
    final events = [
      _event(songId: '1', heardSec: 30, songLenSec: 260),
      _event(songId: '1', heardSec: 90, songLenSec: 260),
    ];
    final report = ListenReport.compute(events, 'all');
    // Total time is REAL listened time: 30 + 90 = 120 s.
    expect(report.totalSeconds, 120);
    expect(report.totalPlays, 2);
    // The top-song row shows the song's length, not the heard total.
    expect(report.topSongs.single.song.dur, 260);
  });
}
