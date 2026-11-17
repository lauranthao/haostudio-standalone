// Stage 2 item 8 — album search parsers (pure halves of the four
// platform album searches; the network halves are `_getJson`/`_getText`
// and return [] on failure, so nothing is ever fabricated).
//
// Canned payloads follow the real shapes:
// - wy: cloudsearch type=10 `result.albums[]` (Beans NetEaseAPI.swift:365)
// - tx: client_search_cp t=8 `data.album.list` (Beans QQMusicAPI.swift:304)
// - kg: aggregated from song search (Beans KugouMusicAPI.swift:614)
// - kw: r.s ft=album `abslist` (same fields as artistDetailKw)

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';

void main() {
  group('parseWyAlbums (cloudsearch type=10)', () {
    test('maps id/name/artist/cover/publishTime/size, drops empties', () {
      final out = MusicApi.parseWyAlbums({
        'albums': [
          {
            'id': 123,
            'name': '范特西',
            'artist': {'name': '周杰伦'},
            'picUrl': 'https://p1.music.126.net/abc',
            'publishTime': 1000000000000,
            'size': 10,
          },
          {'id': '', 'name': ''},
          {
            'id': 456,
            'name': '无封面专辑',
            'artist': {'name': '歌手'},
            'picUrl': '',
            'publishTime': 0,
            'size': 0,
          },
        ],
      });
      expect(out.length, 2);
      final first = out.first;
      expect(first.id, '123');
      expect(first.name, '范特西');
      expect(first.artist, '周杰伦');
      expect(first.cover, contains('p1.music.126.net'));
      expect(first.year, 2001);
      expect(first.songCount, 10);
      expect(first.platform, MusicPlatform.wy);
      expect(out[1].cover, isEmpty);
      expect(out[1].year, 0);
    });

    test('missing albums key returns []', () {
      expect(MusicApi.parseWyAlbums({}), isEmpty);
    });
  });

  group('parseTxAlbums (client_search_cp t=8)', () {
    test('maps mid/singer/cover, opaque id when mid is missing', () {
      final out = MusicApi.parseTxAlbums({
        'album': {
          'list': [
            {
              'mid': '001Qu4I30eVFYb',
              'name': '范特西',
              'singer': [
                {'name': '周杰伦'},
              ],
              'id': 123,
              'total': 10,
            },
            {
              'albumname': '无mid专辑',
              'singerName': '歌手',
              'id': 99,
            },
            {'name': ''},
          ],
        },
      });
      expect(out.length, 2);
      expect(out[0].id, '001Qu4I30eVFYb');
      expect(out[0].name, '范特西');
      expect(out[0].artist, '周杰伦');
      expect(out[0].cover, contains('001Qu4I30eVFYb'));
      expect(out[0].songCount, 10);
      expect(out[0].platform, MusicPlatform.tx);
      // No mid -> Beans' opaque fallback id (AlbumDetailPage treats
      // it as "no real id" and falls back to a name search).
      expect(out[1].id, 'qq-album-99-无mid专辑');
      expect(out[1].cover, isEmpty);
    });

    test('missing album key returns []', () {
      expect(MusicApi.parseTxAlbums({}), isEmpty);
    });
  });

  group('parseKgAlbums (song-search aggregation)', () {
    test('dedupes by album|artist, keeps first, skips coverless album', () {
      final songs = [
        Song(songId: 'h1', title: 'A', artist: '周杰伦', album: '范特西', platform: MusicPlatform.kg),
        Song(songId: 'h2', title: 'B', artist: '周杰伦', album: '范特西', platform: MusicPlatform.kg),
        Song(songId: 'h3', title: 'C', artist: '周杰伦', album: '八度空间', platform: MusicPlatform.kg),
        Song(songId: 'h4', title: 'D', artist: '林俊杰', album: '范特西', platform: MusicPlatform.kg),
        Song(songId: 'h5', title: 'E', artist: '周杰伦', album: '', platform: MusicPlatform.kg),
      ];
      final out = MusicApi.parseKgAlbums(songs);
      expect(out.map((a) => a.name).toList(), ['范特西', '八度空间', '范特西']);
      expect(out.map((a) => a.artist).toList(), ['周杰伦', '周杰伦', '林俊杰']);
      expect(out.every((a) => a.platform == MusicPlatform.kg), isTrue);
      // Opaque id is the album|artist key.
      expect(out.first.id, '范特西|周杰伦');
    });
  });

  group('parseKwAlbums (r.s ft=album)', () {
    test('maps ALBUMID/ALBUM/ARTIST/PICPATH, drops empties', () {
      final out = MusicApi.parseKwAlbums(
        "{'abslist':[{'ALBUMID':'123','ALBUM':'范特西','ARTIST':'周杰伦','PICPATH':'https://img.kuwo.cn/x.jpg','SONGNUM':10},{'ALBUMID':'','ALBUM':'','ARTIST':'x'}]}",
      );
      expect(out.length, 1);
      expect(out.first.id, '123');
      expect(out.first.name, '范特西');
      expect(out.first.artist, '周杰伦');
      expect(out.first.cover, contains('img.kuwo.cn'));
      expect(out.first.songCount, 10);
      expect(out.first.platform, MusicPlatform.kw);
    });

    test('garbage payload returns [] (never throws)', () {
      expect(MusicApi.parseKwAlbums('not json at all'), isEmpty);
      expect(MusicApi.parseKwAlbums(''), isEmpty);
    });
  });
}
