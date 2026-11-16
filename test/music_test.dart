// Music unit tests — pure-Dart rules that must never regress:
//
// - Aggregated search merge is round-robin (wy/tx/kg/kw) and dedupes on
//   platform + songId + title (fix 12).
// - Playlist card count is tracks.length, never a stored field (audit P0-1).
// - Listen-report minutes are totalSeconds / 60 (audit P0-3).
// - Quality chain downgrades hires → lossless → 320k → 128k; extraQuality
//   maps Huibq hi tiers to 320k.
// - Daily seeded PRNG is deterministic per day string.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_store.dart';
import 'package:standalone/services/music/song_search_service.dart';

Song _song(String id, String title, MusicPlatform pf) =>
    Song(songId: id, title: title, platform: pf);

void main() {
  group('mergeSearchResults (fix 12)', () {
    test('round-robin across platforms in wy/tx/kg/kw order', () {
      final wy = [_song('1', 'A', MusicPlatform.wy), _song('2', 'B', MusicPlatform.wy)];
      final tx = [_song('3', 'C', MusicPlatform.tx)];
      final kg = [_song('4', 'D', MusicPlatform.kg)];
      final kw = [_song('5', 'E', MusicPlatform.kw)];
      final merged = mergeSearchResults([wy, tx, kg, kw]);
      expect(merged.map((s) => s.title).toList(), ['A', 'C', 'D', 'E', 'B']);
    });

    test('dedupe only on same platform + songId + title', () {
      final wy = [_song('1', 'A', MusicPlatform.wy), _song('1', 'A', MusicPlatform.wy)];
      final tx = [_song('1', 'A', MusicPlatform.tx)];
      final merged = mergeSearchResults([wy, tx, [], []]);
      // Same songId+title on a different platform is a different result.
      expect(merged.length, 2);
      expect(merged[0].platform, MusicPlatform.wy);
      expect(merged[1].platform, MusicPlatform.tx);
    });

    test('empty platforms contribute nothing', () {
      expect(mergeSearchResults([[], [], [], []]), isEmpty);
      expect(
        mergeSearchResults([[_song('1', 'A', MusicPlatform.wy)], [], [], []]).length,
        1,
      );
    });
  });

  group('playlist count (audit P0-1)', () {
    test('trackCount is tracks.length', () {
      final list = UserPlaylist(
        id: 'l1',
        name: 'test',
        tracks: [_song('1', 'A', MusicPlatform.wy), _song('2', 'B', MusicPlatform.tx)],
      );
      expect(list.trackCount, 2);
      list.tracks.add(_song('3', 'C', MusicPlatform.kg));
      expect(list.trackCount, 3);
      expect(list.trackCount, list.tracks.length);
    });
  });

  group('listen report minutes (audit P0-3)', () {
    test('total minutes = totalSeconds / 60, not / 1000', () {
      final events = [
        ListenEvent(songId: '1', title: 'A', dur: 180, at: DateTime.now().millisecondsSinceEpoch),
        ListenEvent(songId: '2', title: 'B', dur: 240, at: DateTime.now().millisecondsSinceEpoch),
        ListenEvent(songId: '1', title: 'A', dur: 180, at: DateTime.now().millisecondsSinceEpoch),
      ];
      final report = ListenReport.compute(events, 'all');
      expect(report.totalSeconds, 600);
      expect(report.totalMinutes, 10);
      expect(report.totalPlays, 3);
      expect(report.topSongs.first.plays, 2);
    });

    test('durations in seconds are not treated as milliseconds', () {
      final events = [
        ListenEvent(songId: '1', title: 'A', dur: 3600, at: DateTime.now().millisecondsSinceEpoch),
      ];
      final report = ListenReport.compute(events, 'all');
      // 3600 seconds = 60 minutes. If treated as ms it would be ~0.
      expect(report.totalMinutes, 60);
      expect(report.totalTimeText, '1小时0分');
    });
  });

  group('quality chain', () {
    test('downgrade order hires -> lossless -> 320k -> 128k', () {
      expect(
        qualityChainFrom(AudioQuality.hires).map((q) => q.code).toList(),
        ['hires', 'lossless', '320k', '128k'],
      );
      expect(
        qualityChainFrom(AudioQuality.q320k).map((q) => q.code).toList(),
        ['320k', '128k'],
      );
      expect(qualityChainFrom(AudioQuality.q128k).length, 1);
    });

    test('extraQuality: huibq hi tiers cap at 320k', () {
      expect(extraQuality('huibq', AudioQuality.hires, 'wy'), AudioQuality.q320k);
      expect(extraQuality('huibq', AudioQuality.q320k, 'wy'), AudioQuality.q320k);
      expect(extraQuality('gd', AudioQuality.hires, 'wy'), AudioQuality.hires);
      expect(extraQuality('wwwweb', AudioQuality.hires, 'wy'), AudioQuality.lossless);
      expect(extraQuality('wwwweb', AudioQuality.hires, 'kw'), AudioQuality.lossless);
      expect(extraQuality('lzm', AudioQuality.hires, 'wy'), AudioQuality.q320k);
    });

    test('labels match the old qLabel strings', () {
      expect(AudioQuality.hires.label, 'Hi-Res 24bit');
      expect(AudioQuality.lossless.label, '无损 FLAC');
      expect(AudioQuality.q320k.label, '高品质 320k');
      expect(AudioQuality.q128k.label, '标准 128k');
    });
  });

  group('daily seeded PRNG', () {
    test('same day string gives the same sequence', () {
      final a = SeededRandom('2026-11-16');
      final b = SeededRandom('2026-11-16');
      final seqA = List.generate(10, (_) => a.nextDouble());
      final seqB = List.generate(10, (_) => b.nextDouble());
      expect(seqA, seqB);
      final c = SeededRandom('2026-11-17');
      final seqC = List.generate(10, (_) => c.nextDouble());
      expect(seqC, isNot(seqA));
    });

    test('shuffle is stable for the same seed', () {
      final input = [1, 2, 3, 4, 5, 6, 7, 8, 9, 10];
      final a = SeededRandom('2026-11-16').shuffle(input);
      final b = SeededRandom('2026-11-16').shuffle(input);
      expect(a, b);
      expect(a.toSet(), input.toSet());
    });
  });

  group('coverHi', () {
    test('QQ 300 -> 800', () {
      expect(
        coverHi('https://y.gtimg.cn/music/photo_new/T002R300x300M000abc.jpg'),
        'https://y.gtimg.cn/music/photo_new/T002R800x800M000abc.jpg',
      );
    });

    test('NetEase small param dropped', () {
      expect(
        coverHi('https://music.126.net/x.jpg?param=300y300'),
        'https://music.126.net/x.jpg',
      );
      expect(
        coverHi('https://music.126.net/x.jpg?param=500y500'),
        'https://music.126.net/x.jpg?param=500y500',
      );
    });

    test('http upgraded to https', () {
      expect(coverHi('http://example.com/a.jpg'), 'https://example.com/a.jpg');
    });
  });

  group('parseLrc', () {
    test('parses timed lines, drops metadata', () {
      final lines = MusicApi.parseLrc(
        '[ti:Test]\n[00:01.00]hello\n[00:02.50]world\n[ar:X]\n',
      );
      expect(lines.length, 2);
      expect(lines[0].t, 1.0);
      expect(lines[0].text, 'hello');
      expect(lines[1].t, 2.5);
    });

    test('drops 暂无歌词 lines', () {
      expect(MusicApi.parseLrc('[00:01.00]暂无歌词'), isEmpty);
    });
  });

  group('Kuwo single-quote parse', () {
    test('quote-swap JSON parses', () {
      const txt =
          "{'abslist':[{'MUSICRID':'MUSIC_123','NAME':'Song','ARTIST':'Singer','DURATION':'200','ALBUM':'Al','web_albumpic_short':'pic.jpg'}]}";
      final songs = MusicApi.parseKwSongs(txt);
      expect(songs.length, 1);
      expect(songs.first.songId, '123');
      expect(songs.first.title, 'Song');
      expect(songs.first.platform, MusicPlatform.kw);
    });

    test('regex fallback zips fields by index', () {
      const txt =
          "'MUSICRID':'MUSIC_1','NAME':'A','ARTIST':'X' 'MUSICRID':'MUSIC_2','NAME':'B','ARTIST':'Y'";
      final songs = MusicApi.parseKwSongs(txt);
      expect(songs.map((s) => s.songId).toList(), ['1', '2']);
      expect(songs.map((s) => s.title).toList(), ['A', 'B']);
    });
  });
}
