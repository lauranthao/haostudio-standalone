// Music unit tests — pure-Dart rules that must never regress:
//
// - Aggregated search merge is round-robin (wy/tx/kg/kw) and dedupes on
//   platform + songId + title (fix 12).
// - Playlist card count is tracks.length, never a stored field (audit P0-1).
// - Listen-report minutes are totalSeconds / 60 (audit P0-3).
// - Quality chain downgrades hires → lossless → 320k → 128k; extraQuality
//   maps Huibq hi tiers to 320k.
// - Daily seeded PRNG is deterministic per day string.

import 'package:dio/dio.dart';
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

  group('backfillCovers (v1.0.6: 酷狗搜歌无封面)', () {
    test('kg row without cover takes the wy cover of the same song', () {
      final songs = [
        Song(songId: '1', title: '葡萄成熟时', artist: '陈奕迅', cover: 'https://x/cover.jpg', platform: MusicPlatform.wy),
        Song(songId: 'h1', title: '葡萄成熟时', artist: '陈奕迅', platform: MusicPlatform.kg),
      ];
      final out = backfillCovers(songs);
      expect(out[1].cover, 'https://x/cover.jpg');
      expect(out[0].cover, 'https://x/cover.jpg');
    });

    test('no donor with the same title+artist: cover stays empty', () {
      final songs = [
        Song(songId: '1', title: '甲', artist: 'A', cover: 'https://x/a.jpg', platform: MusicPlatform.wy),
        Song(songId: 'h1', title: '乙', artist: 'B', platform: MusicPlatform.kg),
      ];
      final out = backfillCovers(songs);
      expect(out[1].cover, isEmpty);
    });

    test('different artist with the same title does not donate', () {
      final songs = [
        Song(songId: '1', title: '同名', artist: 'A', cover: 'https://x/a.jpg', platform: MusicPlatform.wy),
        Song(songId: 'h1', title: '同名', artist: 'B', platform: MusicPlatform.kg),
      ];
      final out = backfillCovers(songs);
      expect(out[1].cover, isEmpty);
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

  group('ListenSessionTracker (real listened time, chen 2026-11-17)', () {
    final t0 = DateTime(2026, 11, 17, 12, 0, 0);

    test('counts only while playing; pause adds nothing', () {
      final tr = ListenSessionTracker();
      tr.begin(_song('1', 'A', MusicPlatform.wy), t0);
      tr.setPlaying(true, t0);
      tr.setPlaying(false, t0.add(const Duration(seconds: 30)));
      tr.setPlaying(true, t0.add(const Duration(seconds: 90)));
      final ev = tr.finish(t0.add(const Duration(seconds: 120)));
      expect(ev, isNotNull);
      // 30 s + 30 s, not the 120 s wall-clock span.
      expect(ev!.dur, 60);
      expect(ev.songId, '1');
    });

    test('duplicate playing=true does not double count', () {
      final tr = ListenSessionTracker();
      tr.begin(_song('1', 'A', MusicPlatform.wy), t0);
      tr.setPlaying(true, t0);
      tr.setPlaying(true, t0.add(const Duration(seconds: 10)));
      final ev = tr.finish(t0.add(const Duration(seconds: 20)));
      expect(ev!.dur, 20);
    });

    test('under 5 s is not a play (finish returns null)', () {
      final tr = ListenSessionTracker();
      tr.begin(_song('1', 'A', MusicPlatform.wy), t0);
      tr.setPlaying(true, t0);
      expect(tr.finish(t0.add(const Duration(seconds: 4))), isNull);
    });

    test('exactly 5 s counts', () {
      final tr = ListenSessionTracker();
      tr.begin(_song('1', 'A', MusicPlatform.wy), t0);
      tr.setPlaying(true, t0);
      final ev = tr.finish(t0.add(const Duration(seconds: 5)));
      expect(ev, isNotNull);
      expect(ev!.dur, 5);
    });

    test('never played -> null; finish twice -> null the second time', () {
      final tr = ListenSessionTracker();
      tr.begin(_song('1', 'A', MusicPlatform.wy), t0);
      expect(tr.finish(t0.add(const Duration(seconds: 30))), isNull);
      expect(tr.finish(t0.add(const Duration(seconds: 31))), isNull);
    });

    test('begin resets a previous unfinished session', () {
      final tr = ListenSessionTracker();
      tr.begin(_song('1', 'A', MusicPlatform.wy), t0);
      tr.setPlaying(true, t0);
      tr.begin(
        _song('2', 'B', MusicPlatform.wy),
        t0.add(const Duration(seconds: 100)),
      );
      tr.setPlaying(true, t0.add(const Duration(seconds: 100)));
      final ev = tr.finish(t0.add(const Duration(seconds: 110)));
      expect(ev!.songId, '2');
      expect(ev.dur, 10);
    });

    test('at is the session start, not the finish', () {
      final tr = ListenSessionTracker();
      tr.begin(_song('1', 'A', MusicPlatform.wy), t0);
      tr.setPlaying(true, t0);
      final ev = tr.finish(t0.add(const Duration(seconds: 30)));
      expect(ev!.at, t0.millisecondsSinceEpoch);
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

    test('NetEase capped at 800y800, never full-res', () {
      // 2026-11-17: a param-less 126.net URL used to mean the
      // ORIGINAL image (measured 8.0 MB for one cover). Now every
      // 126.net cover is normalised to param=800y800.
      expect(
        coverHi('https://music.126.net/x.jpg?param=300y300'),
        'https://music.126.net/x.jpg?param=800y800',
      );
      expect(
        coverHi('https://music.126.net/x.jpg?param=500y500'),
        'https://music.126.net/x.jpg?param=800y800',
      );
      expect(
        coverHi('https://music.126.net/x.jpg'),
        'https://music.126.net/x.jpg?param=800y800',
      );
    });

    test('coverThumb: NetEase 200y200, others unchanged', () {
      expect(
        coverThumb('https://music.126.net/x.jpg'),
        'https://music.126.net/x.jpg?param=200y200',
      );
      expect(
        coverThumb('https://music.126.net/x.jpg?param=800y800'),
        'https://music.126.net/x.jpg?param=200y200',
      );
      expect(
        coverThumb('https://y.gtimg.cn/music/photo_new/T002R800x800M000abc.jpg'),
        'https://y.gtimg.cn/music/photo_new/T002R800x800M000abc.jpg',
      );
      expect(coverThumb(''), '');
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

  group('song comments aggregator (chen 2026-11-17)', () {
    /// Stub Dio: the NetEase comments URL returns [hot]/[list]; every
    /// other URL (alt-platform search) returns an empty map. With
    /// [fail] every request rejects, so the aggregator sees nothing.
    Dio stubCommentsDio({
      required List<Map<String, dynamic>> hot,
      required List<Map<String, dynamic>> list,
      bool fail = false,
    }) {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (fail) {
              return handler.reject(
                DioException(requestOptions: options, error: 'boom'),
              );
            }
            if (options.path.contains('resource/comments')) {
              return handler.resolve(
                Response<dynamic>(
                  requestOptions: options,
                  statusCode: 200,
                  data: {'hotComments': hot, 'comments': list},
                ),
              );
            }
            return handler.resolve(
              Response<dynamic>(
                requestOptions: options,
                statusCode: 200,
                data: <String, dynamic>{},
              ),
            );
          },
        ),
      );
      return dio;
    }

    Map<String, dynamic> c(
      String nick,
      String content,
      int likes,
      int time,
    ) =>
        {
          'user': {'nickname': nick, 'avatarUrl': ''},
          'content': content,
          'likedCount': likes,
          'time': time,
        };

    test('hot sorted by likes desc, latest by time desc, hasMore', () async {
      final hot = [
        c('a', 'ha', 100, 1),
        c('b', 'hb', 500, 2),
        c('c', 'hc', 300, 3),
      ];
      final list =
          List.generate(35, (i) => c('u$i', 'm$i', 0, (i + 1) * 1000));
      final api = MusicApi(dio: stubCommentsDio(hot: hot, list: list));
      final r = await api.comments('66285', MusicPlatform.wy, '', '', 0);
      expect(r.hot.map((x) => x.nick).toList(), ['b', 'c', 'a']);
      expect(r.latest.length, 30);
      expect(r.latest.first.time, 35000);
      expect(r.latest.last.time, 6000);
      expect(r.hasMore, isTrue);
    });

    test('offset page returns hot empty and the tail, hasMore false',
        () async {
      final hot = [c('a', 'ha', 100, 1)];
      final list =
          List.generate(35, (i) => c('u$i', 'm$i', 0, (i + 1) * 1000));
      final api = MusicApi(dio: stubCommentsDio(hot: hot, list: list));
      final r = await api.comments('66285', MusicPlatform.wy, '', '', 30);
      expect(r.hot, isEmpty);
      expect(r.latest.length, 5);
      expect(r.latest.first.time, 5000);
      expect(r.hasMore, isFalse);
    });

    test('empty comments -> empty lists, no throw', () async {
      final api = MusicApi(
        dio: stubCommentsDio(hot: [], list: []),
      );
      final r = await api.comments('66285', MusicPlatform.wy, '', '', 0);
      expect(r.hot, isEmpty);
      expect(r.latest, isEmpty);
      expect(r.hasMore, isFalse);
    });

    test('all platforms fail -> throws', () async {
      final api = MusicApi(
        dio: stubCommentsDio(hot: [], list: [], fail: true),
      );
      await expectLater(
        api.comments('66285', MusicPlatform.wy, '', '', 0),
        throwsException,
      );
    });
  });
}
