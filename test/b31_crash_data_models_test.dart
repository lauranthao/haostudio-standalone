// Regression tests for the hardened fromJson factories (build 31
// crash hunt). Each test feeds a map whose values are the WRONG type
// for every field — the exact shape that used to throw TypeError via
// `(j['x'] as num?)` / `(j['x'] as String?)` — and expects the factory
// to return an object with defaults instead of throwing.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/player/vod_features.dart';
import 'package:standalone/domains/live/live_follow_store.dart';
import 'package:standalone/domains/live/live_history_store.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/music/bookmarks_store.dart';
import 'package:standalone/services/music/equalizer_store.dart';
import 'package:standalone/services/music/lx_script_store.dart';
import 'package:standalone/services/music/multi_queue_store.dart';
import 'package:standalone/services/music/music_downloads.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/video/emby_models.dart';

void main() {
  group('Song.fromJson', () {
    test('wrong-typed fields fall back, never throw', () {
      final s = Song.fromJson({
        'songId': 123,
        'title': true,
        'dur': '180',
        'albumYear': '2024',
        'platform': 5,
      });
      expect(s.songId, '123');
      // `?.toString()` fields coerce (pre-existing, never threw);
      // the crash-relevant fields are the numeric ones below.
      expect(s.title, 'true');
      expect(s.dur, 0);
      expect(s.albumYear, 0);
    });

    test('well-typed data is unchanged', () {
      final s = Song.fromJson({
        'songId': 's1',
        'title': 'T',
        'dur': 180.5,
        'albumYear': 2024,
      });
      expect(s.dur, 180);
      expect(s.albumYear, 2024);
    });
  });

  group('UserPlaylist.fromJson', () {
    test('tracks as a string, bad track entries dropped', () {
      final p = UserPlaylist.fromJson({
        'id': 1,
        'name': true,
        'tracks': 'nope',
      });
      expect(p.tracks, isEmpty);
      final p2 = UserPlaylist.fromJson({
        'id': 'l1',
        'name': 'L',
        'tracks': [
          'not a map',
          {'songId': 's1', 'dur': 'bad'},
          42,
        ],
      });
      expect(p2.tracks.length, 1);
      expect(p2.tracks.first.songId, 's1');
      expect(p2.tracks.first.dur, 0);
    });
  });

  group('PlaylistSummary / LyricLine / ListenEvent', () {
    test('numeric fields as strings fall back', () {
      final ps = PlaylistSummary.fromJson({
        'playCount': '100',
        'trackCount': true,
      });
      expect(ps.playCount, 0);
      expect(ps.trackCount, 0);
      final ll = LyricLine.fromJson({'t': '1.5', 'text': 7});
      expect(ll.t, 0);
      expect(ll.text, '7');
      final ev = ListenEvent.fromJson({
        'songId': 's',
        'title': 't',
        'dur': '60',
        'totalDur': [],
        'at': 'x',
      });
      expect(ev.dur, 0);
      expect(ev.totalDur, 0);
      expect(ev.at, 0);
    });
  });

  group('VideoSource.fromJson', () {
    test('wrong-typed enabled/sort fall back to defaults', () {
      final v = VideoSource.fromJson({
        'id': 1,
        'name': 2,
        'apiUrl': 3,
        'enabled': 'yes',
        'sort': '5',
      });
      expect(v.name, '');
      expect(v.enabled, isTrue);
      expect(v.sort, 999);
    });
  });

  group('VideoItem.fromJson', () {
    test('wrong-typed numerics/bools/strings fall back', () {
      final v = VideoItem.fromJson({
        'source': 1,
        'hits': '10',
        'progressSeconds': '5',
        'progressFraction': true,
        'played': 'yes',
        'isFavorite': 1,
        'likes': 'up',
        'seasonIndex': '2',
        'year': 2024,
        'score': 8.3,
      });
      expect(v.hits, 0);
      expect(v.progressSeconds, 0);
      expect(v.progressFraction, 0);
      expect(v.played, isFalse);
      expect(v.isFavorite, isFalse);
      expect(v.likes, isNull);
      expect(v.seasonIndex, isNull);
      expect(v.year, '');
      expect(v.score, '');
    });
  });

  group('VideoMeta / VideoDetail / VideoHomeData', () {
    test('douban as a string, meta as a string, rows as strings', () {
      final m = VideoMeta.fromJson({
        'name': 1,
        'runtime': '120',
        'douban': 'not a map',
      });
      expect(m.name, '');
      expect(m.runtime, isNull);
      expect(m.douban, isNull);
      final d = VideoDetail.fromJson({
        'vodId': 9,
        'meta': 'not a map',
        'lines': ['bad', {'name': 'L1', 'episodes': 'nope'}],
      });
      expect(d.vodId, '');
      expect(d.meta.name, '');
      expect(d.lines.length, 1);
      final h = VideoHomeData.fromJson({
        'rows': 'nope',
      });
      expect(h.rows, isEmpty);
    });
  });

  group('WatchHistoryEntry.fromJson', () {
    test('wrong-typed position/duration/at fall back', () {
      final e = WatchHistoryEntry.fromJson({
        'vodId': 1,
        'lineIdx': '0',
        'epIdx': true,
        'position': '100',
        'duration': [],
        'totalEpisodes': '12',
        'at': 'x',
      });
      expect(e.vodId, '');
      expect(e.lineIdx, 0);
      expect(e.epIdx, 0);
      expect(e.position, 0);
      expect(e.duration, 0);
      expect(e.totalEpisodes, isNull);
      expect(e.at.millisecondsSinceEpoch, 0);
    });
  });

  group('ResumeInfo.fromStored', () {
    test('wrong-typed line/ep/position/duration never throw', () {
      final lines = [
        PlayLine(name: 'L1', episodes: [PlayEpisode(name: 'E1', url: 'u')]),
      ];
      expect(
        ResumeInfo.fromStored({
          'lineIdx': '0',
          'epIdx': 'x',
          'position': '100',
          'duration': '200',
        }, lines),
        isNull,
      );
      final ok = ResumeInfo.fromStored({
        'lineIdx': 0,
        'epIdx': 0,
        'position': 100,
        'duration': 200,
        'epName': 5,
      }, lines);
      expect(ok, isNotNull);
      expect(ok!.position, 100);
      expect(ok.epName, '');
    });
  });

  group('EmbyServerConfig.fromJson', () {
    test('wrong-typed stored config falls back, never throws', () {
      final c = EmbyServerConfig.fromJson({
        'baseUrl': 123,
        'apiKey': true,
        'enabled': 'yes',
        'movieLibraryId': 5,
        'reminderDays': '7',
        'lastPlayedAtMs': 'x',
        'fallbackUrls': 'notalist',
        'reportProgress': 'on',
        'strmDirect': 1,
      });
      expect(c.baseUrl, '');
      expect(c.enabled, isTrue);
      expect(c.movieLibraryId, isNull);
      expect(c.reminderDays, 0);
      expect(c.lastPlayedAtMs, isNull);
      expect(c.fallbackUrls, isEmpty);
      expect(c.reportProgress, isTrue);
      expect(c.strmDirect, isFalse);
    });
  });

  group('EmbyStreamFacts.fromMediaSources', () {
    test('malformed media sources return empty facts', () {
      expect(
        EmbyStreamFacts.fromMediaSources('notalist').container,
        isNull,
      );
      expect(
        EmbyStreamFacts.fromMediaSources([
          {'Container': 123, 'MediaStreams': 'nope'},
        ]).videoCodec,
        isNull,
      );
      final f = EmbyStreamFacts.fromMediaSources([
        {
          'Container': 'mkv',
          'MediaStreams': [
            {
              'Type': 'Video',
              'Codec': 'hevc',
              'Width': '1920',
              'Height': 1080,
              'BitRate': 'x',
            },
          ],
          'Size': 'big',
        },
      ]);
      expect(f.container, 'mkv');
      expect(f.videoCodec, 'hevc');
      expect(f.width, isNull);
      expect(f.height, 1080);
      expect(f.bitRate, isNull);
      expect(f.size, isNull);
    });
  });

  group('LiveFollow / LiveHistoryEntry', () {
    test('followedAt/at as strings fall back to 0', () {
      final f = LiveFollow.fromJson({
        'platform': 'bilibili',
        'roomId': 123,
        'followedAt': 'yesterday',
      });
      expect(f.roomId, '123');
      expect(f.followedAt, 0);
      final h = LiveHistoryEntry.fromJson({
        'platform': 5,
        'at': true,
      });
      expect(h.platform, '5');
      expect(h.at, 0);
    });
  });

  group('MusicBookmark / QueueMemoryEntry / DownloadedSong', () {
    test('bad bookmark values return null (row skipped)', () {
      expect(
        MusicBookmark.fromJson({'position': '30', 'createdAt': 1}),
        isNull,
      );
      expect(
        MusicBookmark.fromJson({'position': -1, 'createdAt': 1}),
        isNull,
      );
      expect(
        MusicBookmark.fromJson({'position': 30, 'createdAt': 'x'}),
        isNull,
      );
      expect(
        MusicBookmark.fromJson({'position': 30, 'createdAt': 1})?.position,
        30,
      );
    });

    test('bad queue index/songs fall back', () {
      final q = QueueMemoryEntry.fromJson({
        'songs': 'nope',
        'index': '3',
      });
      expect(q.songs, isEmpty);
      expect(q.index, 0);
    });

    test('bad download song/size fall back', () {
      final d = DownloadedSong.fromJson({
        'song': 'not a map',
        'filePath': 5,
        'sizeBytes': '100',
        'downloadedAt': true,
      });
      expect(d.song.songId, '');
      expect(d.filePath, '5');
      expect(d.sizeBytes, 0);
      expect(d.downloadedAt, 0);
    });
  });

  group('EqualizerCustomPreset / LxCustomScript', () {
    test('bad name/preamp/gains fall back', () {
      expect(
        EqualizerCustomPreset.fromJson({'name': 123}),
        isNull,
      );
      final p = EqualizerCustomPreset.fromJson({
        'name': 'My EQ',
        'gains': ['loud', 3, null],
        'preamp': '2',
      });
      expect(p, isNotNull);
      expect(p!.gains[0], 0);
      expect(p.gains[1], 3);
      expect(p.gains[2], 0);
      expect(p.preamp, 0);
    });

    test('bad addedAt falls back', () {
      final s = LxCustomScript.fromJson({
        'id': 1,
        'addedAt': 'yesterday',
      });
      expect(s.id, '1');
      expect(s.addedAt, 0);
    });
  });

  group('VodMetadataOverride.fromJson', () {
    test('wrong-typed fields read as empty (keep source value)', () {
      final o = VodMetadataOverride.fromJson({
        'title': 123,
        'year': true,
        'poster': ['x'],
      });
      expect(o.title, isNull);
      expect(o.year, isNull);
      expect(o.poster, isNull);
      final o2 = VodMetadataOverride.fromJson({
        'title': '  Fixed Title  ',
      });
      expect(o2.title, 'Fixed Title');
    });
  });
}
