// Kuwo search parsing tests (v1.0.9 follow-up: 搜歌大面积没封面).
//
// Real response fragment, trimmed from a live search.kuwo.cn r.s call
// for "张学友" (2026-11-17, VM curl): 14/15 songs have an empty
// web_albumpic_short AND an empty PICPATH — that is why the list was
// almost all placeholders. The same fragment shows the second bug:
// NAME/ARTIST arrive with raw escapes (`&nbsp;`, double-escaped
// `\\u0026`) that no code decoded, so the rows showed them literally
// and backfillCovers' title keys could not match other platforms.
// Run:
//   TMPDIR=$PWD/.tmp flutter test --concurrency=1
//   test/music_kw_parse_test.dart
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/song_search_service.dart';

/// Trimmed live Kuwo response (3 of 15 entries, escapes intact).
const kwSample = r'''{'abslist':[{'MUSICRID':'MUSIC_21765044','NAME':'明天会更好-1985&nbsp;TVB十大劲歌金曲颁奖典礼现场','ARTIST':'梅艳芳\\u0026张学友\\u0026张国荣\\u0026谭咏麟\\u0026苏芮','ALBUM':'','web_albumpic_short':'','PICPATH':'','DURATION':'297'},{'MUSICRID':'MUSIC_21765045','NAME':'吻别&nbsp;(DJ萧子枫版)','ARTIST':'张学友','ALBUM':'','web_albumpic_short':'','PICPATH':'','DURATION':'369'},{'MUSICRID':'MUSIC_21765046','NAME':'只有情永在-《贼公阿牛》无线电视剧主题曲','ARTIST':'张学友\\u0026周慧敏','ALBUM':'','web_albumpic_short':'120/s4s51/57/1776991716.jpg','PICPATH':'','DURATION':'144'}]}''';

/// Same fragment, truncated mid-value so jsonDecode throws and the
/// regex fallback path runs.
const kwBroken = r'''{'abslist':[{'MUSICRID':'MUSIC_1','NAME':'吻别&nbsp;(DJ版)','ARTIST':'张学友\\u0026周慧敏','web_albumpic_short':'','DURATION':'200'},{'MUSICRID':'MUSIC_2','NAME':'偷心''';

void main() {
  group('decodeEntities (Kuwo escapes)', () {
    test('single-backslash \\uXXXX (after jsonDecode) -> &', () {
      expect(
        decodeEntities(r'梅艳芳\u0026张学友'),
        '梅艳芳&张学友',
      );
    });
    test('double-backslash \\\\uXXXX (regex fallback path) -> &', () {
      expect(
        decodeEntities(r'梅艳芳\\u0026张学友'),
        '梅艳芳&张学友',
      );
    });
    test('&nbsp; -> space, &#38; / &#x26; -> &, &quot; -> "', () {
      expect(decodeEntities('明天会更好-1985&nbsp;TVB'), '明天会更好-1985 TVB');
      expect(decodeEntities('A&#38;B'), 'A&B');
      expect(decodeEntities('A&#x26;B'), 'A&B');
      expect(decodeEntities('A&quot;B&quot;'), 'A"B"');
      expect(decodeEntities('A&amp;B'), 'A&B');
    });
  });

  group('baseSongTitle (version suffix strip)', () {
    test('DJ / live / year suffixes are cut', () {
      expect(baseSongTitle('吻别 (DJ萧子枫版)'), '吻别');
      expect(
        baseSongTitle('明天会更好-1985 TVB十大劲歌金曲颁奖典礼现场'),
        '明天会更好',
      );
      expect(baseSongTitle('太阳星辰 (2007光年世界巡回演唱会香港站)'), '太阳星辰');
      expect(baseSongTitle('只有情永在'), '只有情永在');
    });
  });

  group('parseKwSongs (real fragment)', () {
    test('JSON path: clean titles/artists, cover empty/present', () {
      final songs = MusicApi.parseKwSongs(kwSample);
      expect(songs.length, 3);
      expect(songs[0].title, '明天会更好-1985 TVB十大劲歌金曲颁奖典礼现场');
      expect(songs[0].artist, '梅艳芳&张学友&张国荣&谭咏麟&苏芮');
      expect(songs[0].cover, isEmpty); // picShort AND PICPATH empty
      expect(songs[1].title, '吻别 (DJ萧子枫版)');
      expect(songs[1].artist, '张学友');
      expect(songs[1].cover, isEmpty);
      expect(songs[2].artist, '张学友&周慧敏');
      expect(
        songs[2].cover,
        'https://img1.kuwo.cn/star/albumcover/120/s4s51/57/1776991716.jpg',
      );
      // No raw escape survives in any field.
      for (final s in songs) {
        expect(s.title, isNot(contains('&nbsp;')));
        expect(s.title, isNot(contains(r'\u')));
        expect(s.artist, isNot(contains(r'\u')));
      }
    });

    test('regex fallback path decodes too', () {
      final songs = MusicApi.parseKwSongs(kwBroken);
      expect(songs.length, 1);
      expect(songs[0].title, '吻别 (DJ版)');
      expect(songs[0].artist, '张学友&周慧敏');
    });
  });

  group('backfillCovers after unescape', () {
    test('same clean title copies the NetEase cover across platforms', () {
      final songs = [
        Song(
          songId: 'kw1',
          title: '偷心',
          artist: '张学友',
          platform: MusicPlatform.kw,
          dur: 200,
        ),
        Song(
          songId: 'wy1',
          title: '偷心',
          artist: '张学友',
          platform: MusicPlatform.wy,
          cover: 'https://example.com/cover.jpg',
          dur: 200,
        ),
      ];
      final out = backfillCovers(songs);
      expect(out[0].cover, 'https://example.com/cover.jpg');
    });

    test('version-suffixed title does NOT match (why the lookup exists)', () {
      final songs = [
        Song(
          songId: 'kw1',
          title: '吻别 (DJ萧子枫版)',
          artist: '张学友',
          platform: MusicPlatform.kw,
          dur: 200,
        ),
        Song(
          songId: 'wy1',
          title: '吻别',
          artist: '张学友',
          platform: MusicPlatform.wy,
          cover: 'https://example.com/cover.jpg',
          dur: 200,
        ),
      ];
      expect(backfillCovers(songs)[0].cover, isEmpty);
    });
  });
}
