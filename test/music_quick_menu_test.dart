// Beans-style quick menu + grouped `···` sheet tests.
//
// Long-press on a song row opens an anchored popup (Beans `SongCell`
// context menu) with the four most frequent actions — NOT the full
// `···` sheet. The sheet itself is grouped Beans-style: 播放 / 歌曲 /
// 列表, most-used first.
//
// The controller double overrides playNext so no Hive write happens
// in the widget-test fake zone (see the Hive trap note in
// music_player_layout_test.dart).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/widgets/song_row.dart';
import 'package:standalone/features/music/widgets/track_more_sheet.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/play_mode.dart';

class _MenuTestController extends MusicPlayerController {
  final List<String> playedNext = [];

  @override
  Future<bool> playNext(Song song) async {
    playedNext.add(song.title);
    final at = currentIndex.value < 0 ? 0 : currentIndex.value + 1;
    queue.insert(at, song);
    return true;
  }
}

Song _song(String id, String title) => Song(
  songId: id,
  title: title,
  artist: 'Artist $id',
  cover: '',
  platform: MusicPlatform.wy,
  dur: 200,
);

void main() {
  late Box<dynamic> box;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          (call) async => null,
        );
    Hive.init('test/.hive-music-quick-menu');
    box = await Hive.openBox<dynamic>('music_quick_menu');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    Get.reset();
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          null,
        );
    await box.close();
    await Hive.deleteBoxFromDisk('music_quick_menu');
  });

  Future<_MenuTestController> pumpRow(
    WidgetTester tester, {
    required Song rowSong,
  }) async {
    final c = Get.put<MusicPlayerController>(
      _MenuTestController(),
    ) as _MenuTestController;
    c.queue.assignAll([_song('a', 'Song A')]);
    c.currentIndex.value = 0;
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: Scaffold(
          body: SongRow(
            song: rowSong,
            isFav: false,
            onPlay: () {},
            onToggleFav: () async {},
            onLongPress: (rowCtx) => openSongQuickMenu(rowCtx, rowSong),
          ),
        ),
      ),
    );
    await tester.pump();
    return c;
  }

  group('song quick menu (Beans context menu)', () {
    testWidgets('long-press shows the four frequent actions', (tester) async {
      // Song C is not in the queue and not current: 立即播放 shows.
      await pumpRow(tester, rowSong: _song('c', 'Song C'));
      await tester.longPress(find.byType(SongRow));
      await tester.pump();
      expect(find.text('下一首播放'), findsOneWidget);
      expect(find.text('下载'), findsOneWidget);
      expect(find.text('立即播放'), findsOneWidget);
      expect(find.text('收藏'), findsOneWidget);
    });

    testWidgets('current song hides 立即播放', (tester) async {
      await pumpRow(tester, rowSong: _song('a', 'Song A'));
      await tester.longPress(find.byType(SongRow));
      await tester.pump();
      expect(find.text('下一首播放'), findsOneWidget);
      expect(find.text('立即播放'), findsNothing);
    });

    testWidgets('tap 下一首播放 inserts after current + snackbar', (tester) async {
      final c = await pumpRow(tester, rowSong: _song('c', 'Song C'));
      await tester.longPress(find.byType(SongRow));
      // The popup entrance animation (~250 ms) starts the menu
      // off-screen; wait for it before tapping.
      await tester.pump(const Duration(milliseconds: 300));
      expect(tester.getRect(find.text('下一首播放')).left, greaterThan(0));
      await tester.tap(find.text('下一首播放'));
      // Menu exit animation (300 ms route transition): the route only
      // unmounts after the animation is observed mid-flight, so split
      // the wait into two pumps — one 3 s jump leaves it mounted.
      // (The snackbar is still up, its 4 s auto-dismiss has not fired.)
      await tester.pump(const Duration(seconds: 1));
      await tester.pump(const Duration(seconds: 2));
      expect(find.text('下一首播放'), findsNothing);
      expect(c.playedNext, ['Song C']);
      expect(c.queue.length, 2);
      expect(find.text('已加入下一首播放'), findsOneWidget);
    });
  });

  group('`···` sheet grouping (Beans menu sections)', () {
    Future<_MenuTestController> pumpSheetOpener(WidgetTester tester) async {
      final c = Get.put<MusicPlayerController>(
        _MenuTestController(),
      ) as _MenuTestController;
      c.queue.assignAll([_song('a', 'Song A')]);
      c.currentIndex.value = 0;
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: Builder(
              builder: (ctx) => TextButton(
                onPressed: () => openTrackMoreSheet(ctx, _song('a', 'Song A')),
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      return c;
    }

    testWidgets('sections 播放 / 歌曲 / 列表 in order', (tester) async {
      final c = await pumpSheetOpener(tester);
      expect(find.text('播放'), findsOneWidget);
      expect(find.text('歌曲'), findsOneWidget);
      expect(find.text('列表'), findsOneWidget);
      double y(String s) => tester.getTopLeft(find.text(s)).dy;
      // Playback actions first, then the song itself, then the list.
      expect(y('播放'), lessThan(y('下一首播放')));
      expect(y('下一首播放'), lessThan(y('歌曲')));
      expect(y('歌曲'), lessThan(y('歌曲信息')));
      expect(y('歌曲信息'), lessThan(y('列表')));
      expect(y('列表'), lessThan(y('播放列表')));
      // Every item still present (regrouping moved, never removed).
      // The play-mode row shows the current mode's label, not the
      // words '播放模式'.
      for (final item in [
        '下一首播放',
        c.mode.label,
        '倍速',
        '歌曲信息',
        '评论',
        '播放列表',
        '睡眠定时',
        '下载',
        '取消',
      ]) {
        expect(find.text(item), findsOneWidget, reason: item);
      }
    });
  });
}
