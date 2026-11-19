// 整体交互走查 (2026-11-18) — 流程级 widget 测试，主流程每条一测。
//
// 走查发现修掉的问题由这些测试锁住：
// - 直播封面/头像走 Dio 加载器 (RefererImage)，不再是 Image.network /
//   NetworkImage（v1.0.5 phone bug：原生加载在 chen 手机上空白）。
// - 播放器队列面板是 Stack 浮层不是路由：返回先关队列，再返回才退
//   出播放器（PopScope）。
// - 删除确认全 app 一个做法：玻璃确认框（showGlassConfirmDialog）。
//
// 流程覆盖：音乐首页 -> 搜歌 -> 返回；音乐首页 -> 歌单广场 -> 返回；
// 播放器：封面翻歌词、队列面板返回；玻璃确认框（确认/取消）；直播
// 首页封面 Dio 加载；直播间：切画质/切线路/全屏画质表/返回；
// 设置 -> 音源管理 -> 返回；歌手页 -> 返回；影视历史页（本地，无网络）
// 空态 -> 返回。影视首页本身不能在 widget 测试里 pump（见文件尾注释）。
//
// 约束（抄 live_room_player_audit_test.dart）：直播间一文件只 pump
// 一次——第二次 pump 会挂起；全屏弹幕挂载后只用 plain pump()，不用
// runAsync。网络请求一律只用 plain pump()，不用 pumpAndSettle。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/core/theme/theme_controller.dart';
import 'package:standalone/domains/live/live_follow_store.dart';
import 'package:standalone/domains/live/live_history_store.dart';
import 'package:standalone/domains/live/presentation/live_tab_controller.dart';
import 'package:standalone/domains/live/presentation/live_tab_page.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/features/music/artist_detail_page.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_player_sheet.dart';
import 'package:standalone/features/music/music_tab_page.dart';
import 'package:standalone/features/music/plaza_page.dart';
import 'package:standalone/features/settings/music_sources_page.dart';
import 'package:standalone/features/settings/settings_tab_page.dart';
import 'package:standalone/features/settings/source_stores.dart';
import 'package:standalone/features/player/fullscreen_controller.dart';
import 'package:standalone/features/video/video_history_page.dart';
import 'package:standalone/features/video/widgets/referer_image.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_store.dart';
import 'package:standalone/shared/platforms/live_site.dart';
import 'package:standalone/widgets/glass_dialog.dart';

/// Offline cover fetch for the home's lazy first-cover fill: the
/// home must never hit the real network from a test (flaky + slow).
/// Empty lists keep every card on its gradient.
class _EmptyCoverApi extends MusicApi {
  @override
  Future<List<PlaylistSummary>> plaza(MusicPlatform pf) async => [];

  @override
  Future<List<PlaylistSummary>> neteaseCharts() async => [];
}

/// No-load player double (copied from music_home_kumone_test.dart):
/// playQueue / prev / next / togglePlayPause / cyclePlayMode are
/// recorded no-ops, so no audio URL is ever resolved in the test zone.
class _NoLoadController extends MusicPlayerController {
  final List<(List<Song>, int)> playQueueCalls = [];

  @override
  Future<void> playQueue(
    List<Song> songs,
    int index, {
    String label = '',
  }) async {
    playQueueCalls.add((songs, index));
    queue.assignAll(songs);
    currentIndex.value = index;
  }

  @override
  Future<void> prev() async {}

  @override
  Future<void> next({bool auto = false}) async {}

  @override
  Future<void> togglePlayPause() async {}

  @override
  Future<void> cyclePlayMode() async {}
}

List<Song> _sampleSongs() => [
  Song(
    songId: 'wy-1',
    title: '富士山下',
    artist: '陈奕迅',
    album: "What's Going On...?",
    platform: MusicPlatform.wy,
    dur: 245,
  ),
  Song(
    songId: 'wy-2',
    title: '孤勇者',
    artist: '陈奕迅',
    album: '孤勇者',
    platform: MusicPlatform.wy,
    dur: 256,
  ),
];

LiveRoom _fakeRoom(int i) => LiveRoom(
  roomId: 'room-$i',
  platform: 'fake',
  title: '直播间 $i',
  nick: '主播 $i',
  cover: 'https://example.com/cover-$i.jpg',
  watching: 12345,
  liveStatus: true,
);

/// Minimal fake live site: only the tab's first load is exercised
/// (recommend rooms + categories); the rest keep LiveSite's defaults.
class _FakeTabSite extends LiveSite {
  @override
  String get id => 'fake';

  @override
  String get name => 'Fake';

  @override
  Future<List<LiveRoom>> getRecommendRooms({
    int page = 1,
    int pageSize = 30,
  }) async => [_fakeRoom(1), _fakeRoom(2)];

  @override
  Future<List<LiveArea>> getCategories({
    int page = 1,
    int pageSize = 30,
  }) async => [];
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-walkthrough-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
          if (call.method == 'getApplicationDocumentsDirectory') {
            return hiveDir.path;
          }
          return null;
        });
    await HiveStore.init();
    final memBox = await Hive.openBox<dynamic>(
      'test_interaction_walkthrough',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          (call) async => null,
        );
  });

  // Trap (2026-11-17): never `await` box.close() in tearDownAll — a
  // pending Hive write never resolves in the widget-test fake zone.
  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    HaoHaptics.debugEnabledOverride = false;
  });

  tearDown(() {
    HaoHaptics.debugEnabledOverride = null;
    Get.reset();
  });

  Future<_NoLoadController> pumpHome(WidgetTester tester) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    final songs = _sampleSongs();
    await MusicStore.saveLists([
      UserPlaylist(id: 'p1', name: '我喜欢的音乐', tracks: songs),
    ]);
    await MusicStore.clearRecent();
    for (final s in songs) {
      await MusicStore.addRecent(s);
    }
    final controller = _NoLoadController();
    Get.put<MusicPlayerController>(controller);
    await tester.pumpWidget(
      GetMaterialApp(
        debugShowCheckedModeBanner: false,
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: MusicTabPage(api: _EmptyCoverApi()),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    await tester.pump(const Duration(milliseconds: 500));
    return controller;
  }

  group('music home flows', () {
    testWidgets('home -> search -> back', (tester) async {
      await pumpHome(tester);
      expect(find.text('搜歌'), findsOneWidget);
      // The shelf scrolls horizontally: the tile starts off-screen,
      // so scroll it into view before tapping (a blind tap misses).
      await tester.ensureVisible(find.text('搜歌'));
      await tester.pump();
      await tester.tap(find.text('搜歌'));
      await tester.pump();
      // A navigation tap needs a second pump before the pushed route
      // is in the tree (established by music_home_kumone_test: every
      // tap is followed by pump() + pump(300ms)).
      await tester.pump(const Duration(milliseconds: 300));
      // Search page opened (its field hint), home behind it.
      expect(find.text('搜索歌曲 / 歌手…'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('搜索歌曲 / 歌手…'), findsNothing);
      expect(find.text('搜歌'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('home -> plaza -> back', (tester) async {
      await pumpHome(tester);
      await tester.ensureVisible(find.text('歌单广场'));
      await tester.pump();
      await tester.tap(find.text('歌单广场'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PlazaPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(PlazaPage), findsNothing);
      expect(find.text('歌单广场'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('player flows', () {
    testWidgets('cover flips to lyrics; back closes queue first',
        (tester) async {
      // The player is a PUSHED route (tapping a recent song on the
      // music home opens it): the initial route can never be popped,
      // so pumping the player as `home` would make the back half of
      // this test meaningless.
      await pumpHome(tester);
      await tester.ensureVisible(find.text('富士山下').first);
      await tester.pump();
      await tester.tap(find.text('富士山下').first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MusicPlayerPage), findsOneWidget);
      expect(find.text('富士山下'), findsWidgets);
      final c = Get.find<MusicPlayerController>();

      // Tap the cover flips to the lyrics face (empty lyrics show the
      // loading / no-lyrics line, never a blank face). Each flip gets
      // 300 ms: the AnimatedSwitcher keeps outgoing children for its
      // 250 ms fade, so asserting mid-transition finds two covers.
      await tester.tap(find.byKey(const ValueKey('playerCover')));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(
        find.text('歌词加载中…').evaluate().isNotEmpty ||
            find.text('暂无歌词').evaluate().isNotEmpty,
        isTrue,
      );
      // Tap the empty-lyrics face flips back to the cover.
      final lyricsTap = find.text('歌词加载中…').evaluate().isNotEmpty
          ? find.text('歌词加载中…')
          : find.text('暂无歌词');
      await tester.tap(lyricsTap);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byKey(const ValueKey('playerCover')), findsOneWidget);

      // Queue panel open: the FIRST back closes the panel, the player
      // page stays; the SECOND back leaves the player and returns to
      // the music home. The panel is a Stack overlay with no back
      // button, so the system back is simulated with handlePopRoute,
      // not pageBack (pageBack needs a visible back button and throws
      // without one). A pop transition needs several frames to leave
      // the tree — one pump(400) is not enough (established by the
      // back-pattern experiment: 3x pump(300) completes it).
      c.showQueuePanel.value = true;
      await tester.pump();
      expect(find.text('播放列表 · 2 首'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.text('播放列表 · 2 首'), findsNothing);
      expect(find.byType(MusicPlayerPage), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MusicPlayerPage), findsNothing);
      expect(find.text('搜歌'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('dialog consistency', () {
    Future<bool?> openConfirm(
      WidgetTester tester,
      String tapLabel,
    ) async {
      bool? result;
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () async {
                  result = await showGlassConfirmDialog(
                    tester.element(find.byType(TextButton).first),
                    title: '删除歌单',
                    content: '确定删除这个歌单吗？里面的歌也会一起删除。',
                    confirmLabel: '删除',
                  );
                },
                child: const Text('open'),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
      await tester.tap(find.text('open'));
      await tester.pump();
      // Glass shell, not a raw AlertDialog.
      expect(find.byType(AlertDialog), findsNothing);
      await tester.tap(find.text(tapLabel));
      await tester.pump();
      return result;
    }

    testWidgets('glass confirm: confirm true, cancel false', (tester) async {
      expect(await openConfirm(tester, '删除'), isTrue);
      expect(await openConfirm(tester, '取消'), isFalse);
      expect(tester.takeException(), isNull);
    });
  });

  group('live flows', () {
    testWidgets('live tab room covers use the Dio loader', (tester) async {
      final controller = LiveTabController(siteOf: (_) => _FakeTabSite());
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveTabPage(controller: controller),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('直播间 1'), findsOneWidget);
      // RefererImage (Dio + cache), never Image.network — the v1.0.5
      // phone bug (blank covers) was the live tab still using it.
      expect(find.byType(RefererImage), findsWidgets);
      expect(find.byType(Image), findsNothing);
      expect(tester.takeException(), isNull);
    });

    // ONE room pump in this file (see the file header): the whole
    // portrait -> fullscreen -> portrait + back sequence runs here.
    testWidgets('room: quality chip, line switch, fullscreen sheet, back',
        (tester) async {
      await tester.runAsync(() async {
        await DanmakuSettings.setEnabled('huya', true);
        await LiveHistoryStore.clear();
        await LiveFollowStore.clear();
      });
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      const roomA = LiveRoom(
        roomId: '660000',
        platform: 'huya',
        title: 'room A',
        nick: 'anchor A',
        liveStatus: true,
        watching: 100,
      );
      // The room is a PUSHED route from a harness home: the initial
      // route can never be popped, so pumping the room as `home`
      // would make the back half of this test meaningless.
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(
                    tester.element(find.byType(TextButton).first),
                  ).push(
                    MaterialPageRoute<void>(
                      builder: (_) => LiveRoomPage(
                        room: roomA,
                        playlist: const [roomA],
                        site: _WalkFakeSite(),
                        backendFactory: (_) => _WalkFakeBackend(),
                      ),
                    ),
                  );
                },
                child: const Text('enter room'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('enter room'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      Future<void> settle() async {
        await tester.runAsync(() async {
          await Future<void>.delayed(const Duration(milliseconds: 200));
        });
        await tester.pump();
      }

      await settle();
      await tester.pump(const Duration(milliseconds: 200));
      await settle();
      expect(find.text('room A'), findsOneWidget);
      // Portrait: quality chip + two line chips (fake resolves 2 URLs).
      expect(find.text('原画'), findsOneWidget);
      expect(find.text('线路 1'), findsOneWidget);
      expect(find.text('线路 2'), findsOneWidget);
      // Switch line: stays on the room, second line selected.
      await tester.tap(find.text('线路 2'));
      await tester.pump();
      expect(find.text('room A'), findsOneWidget);

      // Fullscreen (flag flip, plain pump only — the Flame barrage is
      // mounted from here on): no AppBar, overlay top bar, quality +
      // line buttons in the bottom bar. Flip the flag FIRST, then go
      // landscape: the portrait Column in a landscape viewport
      // overflows (the danmaku area is Expanded, so this only happens
      // in the harness's artificial intermediate state — never on a
      // real phone, where rotation and fullscreen change together).
      Get.find<FullscreenController>().isFullscreen.value = true;
      await tester.pump();
      tester.view.physicalSize = const Size(1600, 800);
      await tester.pump();
      expect(find.byType(AppBar), findsNothing);
      expect(find.byTooltip('退出全屏'), findsOneWidget);
      expect(find.text('原画'), findsOneWidget);
      // Quality button opens the glass sheet (button + sheet row both
      // read 原画); picking the row closes it again.
      await tester.tap(find.text('原画'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('原画'), findsNWidgets(2));
      expect(find.byType(ListTile), findsWidgets);
      await tester.tap(find.text('原画').last);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.text('原画'), findsOneWidget);
      // Back in fullscreen exits fullscreen first (canPop false — no
      // AppBar back button up here, so this is the system back via
      // handlePopRoute, not pageBack). Restore the portrait viewport
      // BEFORE the back: the flag flip rebuilds the portrait Column
      // immediately, and in a landscape viewport that Column overflows
      // (16:9 video of a 1600-wide viewport is 900 tall in an
      // 800-tall surface). On a real phone this is the ~300 ms
      // rotation window after exiting fullscreen — release builds do
      // not paint the overflow stripes, the content is just clipped
      // until the rotation lands; see the report for the follow-up.
      tester.view.physicalSize = const Size(800, 1600);
      await tester.pump();
      await tester.binding.handlePopRoute();
      await tester.pump();
      expect(find.byType(AppBar), findsOneWidget);
      expect(
        Get.find<FullscreenController>().isFullscreen.value,
        isFalse,
      );
      // Back in portrait leaves the room and returns to the harness
      // home. A pop needs several frames to leave the tree.
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(LiveRoomPage), findsNothing);
      expect(find.text('enter room'), findsOneWidget);
      // Let the session dispose + any snackbar ticker drain (same as
      // the audit test's disposeRoom).
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      expect(tester.takeException(), isNull);
    });
  });

  group('settings + artist + video flows', () {
    testWidgets('settings -> music sources -> back', (tester) async {
      tester.view.physicalSize = const Size(800, 2400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      Get.put(ThemeController());
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const SettingsTabPage(),
        ),
      );
      await tester.pumpAndSettle();
      await tester.tap(find.text('音源管理'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MusicSourcesPage), findsOneWidget);
      // The pop transition keeps the page in the tree for ~300 ms:
      // pump past it (3x 300 ms) before asserting absence. System back
      // (not pageBack: the settings rows navigate with Get.to).
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(MusicSourcesPage), findsNothing);
      expect(find.byType(SettingsTabPage), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    testWidgets('artist page opens and backs out', (tester) async {
      // Pushed from a harness home: the initial route can never be
      // popped, so pumping the artist page as `home` would make the
      // back half of this test meaningless.
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(
                    tester.element(find.byType(TextButton).first),
                  ).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const ArtistDetailPage(
                        platform: MusicPlatform.wy,
                        artistId: '',
                        artistName: '陈奕迅',
                      ),
                    ),
                  );
                },
                child: const Text('open artist'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open artist'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ArtistDetailPage), findsOneWidget);
      // Either the name is already painted or the page is honestly
      // loading (spinner) while the artist fetch runs — never a crash
      // or a blank page with no state at all.
      final named = find.text('陈奕迅').evaluate().isNotEmpty;
      final loading =
          find.byType(CircularProgressIndicator).evaluate().isNotEmpty;
      expect(named || loading, isTrue);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(ArtistDetailPage), findsNothing);
      expect(find.text('open artist'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });

    // Video home itself cannot be pumped in a widget test: its init
    // fires real CMS requests whose Dio timers never drain in the fake
    // zone and trip teardown's !timersPending (established by the
    // first run of this file). The video-home flow is covered by code
    // walk + the existing video tests instead; what IS hermetic here
    // is the local video-history page (no network on entry).
    testWidgets('video history page: honest empty state, backs out',
        (tester) async {
      // Pushed from a harness home (same initial-route reason as the
      // artist test above).
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: Center(
              child: TextButton(
                onPressed: () {
                  Navigator.of(
                    tester.element(find.byType(TextButton).first),
                  ).push(
                    MaterialPageRoute<void>(
                      builder: (_) => const VideoHistoryPage(),
                    ),
                  );
                },
                child: const Text('open history'),
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.text('open history'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(VideoHistoryPage), findsOneWidget);
      expect(find.text('还没有观看记录'), findsOneWidget);
      await tester.binding.handlePopRoute();
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      await tester.pump(const Duration(milliseconds: 300));
      expect(find.byType(VideoHistoryPage), findsNothing);
      expect(find.text('open history'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });
}

/// Fake room site for the room flow test (copied from
/// live_room_player_audit_test.dart): two URLs so the line row shows
/// two lines; one quality.
class _WalkFakeSite extends LiveSite {
  final danmaku = _WalkFakeDanmaku();

  @override
  String get id => 'huya';

  @override
  String get name => 'Huya';

  @override
  LiveDanmaku getDanmaku() => danmaku;

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async => room;

  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async => const [LivePlayQuality(quality: '原画', id: '10000')];

  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final issued = DateTime.now();
    return LivePlayUrlResolution(
      urls: const [
        'https://example.com/live-1.m3u8',
        'https://example.com/live-2.m3u8',
      ],
      issuedAt: issued,
      refreshAt: issued.add(const Duration(seconds: 100)),
      invalidAt: issued.add(const Duration(seconds: 125)),
      streamFacts: const [LiveStreamFacts(format: 'hls')],
    );
  }
}

/// Fake danmaku transport: records start/stop, never emits.
class _WalkFakeDanmaku extends LiveDanmaku {
  int startCount = 0;
  int stopCount = 0;

  @override
  bool get isConnected => startCount > stopCount;

  @override
  Future<void> heartbeat() async {}

  @override
  Future<void> start(Map<String, dynamic> args) async {
    startCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

/// Minimal fake native backend: instant open / first frame, no
/// tickers, no timers (copied from live_room_player_audit_test.dart).
class _WalkFakeBackend implements PlayerBackend {
  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  @override
  Widget buildVideoWidget() => const SizedBox(key: ValueKey('fake-video'));

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {}

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async => true;

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Future<void> seekTo(Duration position) async {}

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Future<void> dispose() async {
    // Do NOT await the broadcast close() calls: inside a widget test's
    // fake-async zone a broadcast StreamController.close() future never
    // completes, so awaiting it stalls the session dispose chain.
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}
