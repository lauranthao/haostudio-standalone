// Regression tests for the hardened Hive stores (build 31 crash
// hunt). Each test seeds a HOSTILE stored value — the wrong type for
// the key, corrupt JSON, or a list with one bad row — and expects the
// reader to return defaults / keep the good rows instead of throwing
// TypeError the way `(box.get(key) as String?)` used to.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/domains/live/live_follow_store.dart';
import 'package:standalone/domains/live/live_history_store.dart';
import 'package:standalone/features/video/video_history_store.dart';
import 'package:standalone/services/music/bookmarks_store.dart';
import 'package:standalone/services/music/local_music_store.dart';
import 'package:standalone/services/music/music_downloads.dart';
import 'package:standalone/services/music/music_store.dart';
import 'package:standalone/services/video/emby_models.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-b31-crash-stores-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await HiveStore.box.clear();
    });
  });

  Future<void> seed(String key, Object value) async {
    await TestWidgetsFlutterBinding.instance.runAsync(() async {
      await HiveStore.box.put(key, value);
    });
  }

  group('MusicStore lists', () {
    test('non-String stored value reads as empty, never throws', () async {
      await seed(HiveKeys.musicLists, 12345);
      expect(MusicStore.getLists(), isEmpty);
      await seed(HiveKeys.musicRecent, true);
      expect(MusicStore.getRecent(), isEmpty);
      await seed(HiveKeys.musicListen, ['x']);
      expect(MusicStore.getListenLog(), isEmpty);
      await seed(HiveKeys.musicLyrics, 3.14);
      await seed(HiveKeys.musicCoverCache, {'a': 1});
      await seed(HiveKeys.musicResume, 99);
      // Cover/lyrics readers only surface through other getters;
      // the point here is the _readMap/_readList guards do not throw.
      expect(MusicStore.getResumeMap(), isEmpty);
    });

    test('one bad playlist row does not kill the whole list', () async {
      await seed(
        HiveKeys.musicLists,
        jsonEncode([
          {
            'id': 'l1',
            'name': 'L1',
            'tracks': [
              'not a map',
              {'songId': 's1', 'dur': 'bad'},
              42,
            ],
          },
          {'id': 'l2', 'name': 'L2', 'tracks': 'nope'},
          'not a map at all',
        ]),
      );
      final lists = MusicStore.getLists();
      expect(lists.length, 2);
      expect(lists[0].tracks.length, 1);
      expect(lists[0].tracks.first.songId, 's1');
      expect(lists[0].tracks.first.dur, 0);
      expect(lists[1].tracks, isEmpty);
    });

    test('recent / listen log keep good rows, drop bad ones', () async {
      await seed(
        HiveKeys.musicRecent,
        jsonEncode([
          {'songId': 's1'},
          'bad',
          {'songId': 5, 'dur': true},
        ]),
      );
      final recent = MusicStore.getRecent();
      expect(recent.length, 2);
      expect(recent[1].songId, '5');
      expect(recent[1].dur, 0);
      await seed(
        HiveKeys.musicListen,
        jsonEncode([
          {'songId': 's', 'title': 't', 'at': 'yesterday'},
          {'songId': 's2', 'title': 't2', 'at': 1000},
        ]),
      );
      final log = MusicStore.getListenLog();
      expect(log.length, 2);
      // Sorted newest-first: the at=1000 entry comes first.
      expect(log.map((e) => e.at).toSet(), {0, 1000});
      expect(log.first.at, 1000);
      expect(log.last.at, 0);
    });
  });

  group('MusicStore daily / queue / resume', () {
    test('non-String daily value reads as no daily, never throws',
        () async {
      await seed(HiveKeys.musicDailyKey('2026-11-23'), 99);
      expect(MusicStore.getDaily('2026-11-23'), isNull);
      expect(MusicStore.getDailyCold('2026-11-23'), isFalse);
    });

    test('daily tracks as a string reads as no daily', () async {
      await seed(
        HiveKeys.musicDailyKey('2026-11-23'),
        jsonEncode({'tracks': 'nope', 'cold': 'yes'}),
      );
      expect(MusicStore.getDaily('2026-11-23'), isNull);
      expect(MusicStore.getDailyCold('2026-11-23'), isFalse);
    });

    test('queue with String index recovers to the first song', () async {
      await seed(
        HiveKeys.musicQueue,
        jsonEncode({
          'songs': [
            {'songId': 's1'},
          ],
          'index': '3',
        }),
      );
      final q = MusicStore.getQueue();
      expect(q.songs.length, 1);
      expect(q.index, 0);
      await seed(HiveKeys.musicQueue, 7);
      final q2 = MusicStore.getQueue();
      expect(q2.songs, isEmpty);
      expect(q2.index, -1);
    });

    test('resume map drops String values, keeps numeric ones', () async {
      await seed(
        HiveKeys.musicResume,
        jsonEncode({'a|1': '30', 'b|2': 45, 'c|3': -5}),
      );
      expect(MusicStore.getResumeMap(), {'b|2': 45});
      expect(MusicStore.resumeFor('a|1'), 0);
      expect(MusicStore.resumeFor('b|2'), 45);
    });
  });

  group('VideoHistoryStore', () {
    test('non-String history reads as empty', () async {
      await seed(HiveKeys.videoHistory, 123);
      expect(VideoHistoryStore.getAll(), isEmpty);
      await seed(HiveKeys.videoFavs, true);
      expect(VideoHistoryStore.getFavs(), isEmpty);
    });

    test('one bad history row does not discard the rest', () async {
      await seed(
        HiveKeys.videoHistory,
        jsonEncode([
          {
            'source': 1,
            'vodId': 'v1',
            'title': 'Good',
            'position': 'bad',
            'at': 1000,
          },
          'not a map',
          {'source': 1, 'vodId': 'v2', 'title': 5, 'at': 'bad'},
        ]),
      );
      final all = VideoHistoryStore.getAll();
      expect(all.length, 2);
      expect(all[0].title, 'Good');
      expect(all[0].position, 0);
      expect(all[1].title, '');
    });

    test('one bad favourite row does not discard the rest', () async {
      await seed(
        HiveKeys.videoFavs,
        jsonEncode([
          {'source': 1, 'vodId': 'v1', 'name': 'Good', 'hits': 'x'},
          42,
        ]),
      );
      final favs = VideoHistoryStore.getFavs();
      expect(favs.length, 1);
      expect(favs.first.name, 'Good');
      expect(favs.first.hits, 0);
    });

    test('corrupt source rows fall back to defaults, keep good rows',
        () async {
      await seed(
        HiveKeys.videoSources,
        jsonEncode([
          {
            'id': 1,
            'name': 'good',
            'apiUrl': 'https://a.example',
            'enabled': 'yes',
            'sort': 'bad',
          },
          'not a map',
        ]),
      );
      final sources = VideoSourcesStore.getAll();
      expect(sources.any((s) => s.name == 'good'), isTrue);
      expect(sources.length, greaterThan(1)); // defaults merged in
      await seed(HiveKeys.videoSources, 55);
      expect(VideoSourcesStore.getAll().length, greaterThan(1));
    });
  });

  group('Live stores', () {
    test('one bad follow row does not discard the rest', () async {
      await seed(
        HiveKeys.liveFollows,
        jsonEncode([
          {
            'platform': 'bilibili',
            'roomId': '1',
            'followedAt': 'yesterday',
          },
          'not a map',
          {'platform': 'douyu', 'roomId': '2', 'followedAt': 5},
        ]),
      );
      final all = LiveFollowStore.getAll();
      expect(all.length, 2);
      expect(all[0].followedAt, 0);
      expect(all[1].followedAt, 5);
    });

    test('one bad history row does not discard the rest', () async {
      await seed(
        HiveKeys.liveHistory,
        jsonEncode([
          {'platform': 5, 'roomId': '1', 'at': true},
          {'platform': 'huya', 'roomId': '2', 'at': 2000},
        ]),
      );
      final all = LiveHistoryStore.getAll();
      expect(all.length, 2);
      expect(all[0].platform, '5');
      expect(all[0].at, 0);
      expect(all[1].at, 2000);
    });
  });

  group('Bookmarks / downloads / local music', () {
    test('bookmark table with String position skips the row', () async {
      await seed(
        HiveKeys.musicBookmarks,
        jsonEncode({
          'wy|123': [
            {'position': '30', 'label': 'x', 'createdAt': 1},
            {'position': 60, 'label': '1:00', 'createdAt': 2},
          ],
        }),
      );
      final marks = BookmarksStore.forSong('wy|123');
      expect(marks.length, 1);
      expect(marks.first.position, 60);
      await seed(HiveKeys.musicBookmarks, 42);
      expect(BookmarksStore.forSong('wy|123'), isEmpty);
    });

    test('download index with a bad row keeps the good entries',
        () async {
      await seed(
        HiveKeys.musicDownloads,
        jsonEncode([
          'not a map',
          {
            'song': {'songId': 's1'},
            'filePath': '/x.mp3',
            'sizeBytes': '100',
          },
        ]),
      );
      expect(MusicDownloadService().downloadedCount, 1);
      await seed(HiveKeys.musicDownloads, true);
      expect(MusicDownloadService().downloadedCount, 0);
    });

    test('local music index with a non-String value reads empty',
        () async {
      await seed(HiveKeys.musicLocalFiles, 123);
      expect(await LocalMusicStore().list(), isEmpty);
    });
  });

  group('EmbyConfigStore / ThemeController', () {
    test('wrong-typed Emby config falls back, never throws', () async {
      await seed(HiveKeys.embyConfig, 42);
      expect(EmbyConfigStore.load(), isNull);
      await seed(
        HiveKeys.embyConfig,
        jsonEncode({
          'baseUrl': 123,
          'enabled': 'yes',
          'reminderDays': '7',
          'fallbackUrls': 'x',
        }),
      );
      final c = EmbyConfigStore.load();
      expect(c, isNotNull);
      expect(c!.baseUrl, '');
      expect(c.enabled, isTrue);
      expect(c.reminderDays, 0);
      expect(c.fallbackUrls, isEmpty);
    });

    test('wrong-typed theme values keep defaults (app-start path)',
        () async {
      await seed('haoThemeId', 123);
      await seed('haoThemeMode', true);
      await seed('hao_custom_font_family', ['x']);
      final c = ThemeController();
      c.loadFromBox(HiveStore.box);
      expect(c.themeId.value.name, 'appleGlass');
      expect(c.themeMode.value.name, 'system');
      expect(c.customFontFamily.value, '');
    });
  });
}
