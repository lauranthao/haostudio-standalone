// 最近播放实时刷新 (bug3, chen 2026-11-20: “下面的最近播放也不会实时变化”)。
//
// Regression: 播了新歌之后，音乐首页的「最近播放」栏必须立刻出现
// 刚播的歌 — 不用切页面、不用重进、不用进出子页面。旧行为：
// _recent 只在 initState / _push() 返回后的 _refresh() 里读一次，
// 首页 tab 在 tab 栈里一直活着，所以新歌一播栏位就 stale。
//
// Harness: 内存 Hive 盒 (HiveStore.setTestBox) + 离线封面 API，
// 与 music_home_kumone_test.dart 同一套；播歌用真控制器 +
// 假解析器 / 假播放器（music_playback_reliability_test.dart 的
// 构造器注入 seam），不碰网络、不碰真音频。

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/features/music/av_music_player.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_tab_page.dart';
import 'package:standalone/features/music/widgets/song_row.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';
import 'package:standalone/services/music/music_store.dart';

/// Offline cover fetch for the home's lazy first-cover fill: the
/// home must never hit the real network from a test.
class _EmptyCoverApi extends MusicApi {
  @override
  Future<List<PlaylistSummary>> plaza(MusicPlatform pf) async => [];

  @override
  Future<List<PlaylistSummary>> neteaseCharts() async => [];
}

/// Every resolve returns a playable URL for the requested song id —
/// no network, no LX script.
class _AlwaysOkResolvers extends MusicResolvers {
  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
  }) async => PlayUrlResult(
    url: 'https://example.com/$songId.mp3',
    candidates: ['https://example.com/$songId.mp3'],
    quality: quality,
    via: 'test',
  );
}

class _FakePlayer extends AvMusicPlayer {
  final List<String> openedUrls = [];

  @override
  Future<bool> open(String url, {bool play = true}) async {
    openedUrls.add(url);
    return true;
  }

  @override
  Future<bool> preload(String url) async => true;

  @override
  bool isPreloadedFor(String url) => false;

  @override
  ProcessingState get processingState => ProcessingState.ready;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> dispose() async {}
}

Song _song(String id, String title) => Song(
  songId: id,
  title: title,
  artist: '陈奕迅',
  platform: MusicPlatform.wy,
  dur: 245,
);

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-music-recent-live-');
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
      'test_music_recent_live',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  // NOTE (same as danmaku_settings_effect_test.dart): do NOT await
  // the Hive box close — pending fire-and-forget writes never resolve
  // in the widget-test fake zone, so awaiting close() hangs.
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

  /// Let real async work drain: Hive writes must run in the real zone
  /// (runAsync) and the box listenable/watch events arrive
  /// asynchronously — real 200 ms + pump, same pattern as
  /// danmaku_settings_effect_test.dart's settle().
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  Future<MusicPlayerController> pumpHome(
    WidgetTester tester, {
    MusicPlayerController? controller,
  }) async {
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    await MusicStore.clearRecent();
    await MusicStore.saveLists([]);
    // Register under the BASE type: MusicPlayerController.ensure()
    // looks up MusicPlayerController, and Get.put(double) alone would
    // register under the subclass type.
    final c =
        controller ??
        MusicPlayerController(
          api: _EmptyCoverApi(),
          resolvers: _AlwaysOkResolvers(),
          playerA: _FakePlayer(),
          playerB: _FakePlayer(),
        );
    Get.put<MusicPlayerController>(c);
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
    return c;
  }

  testWidgets('addRecent 后最近播放实时出现，不用重进页面', (tester) async {
    await pumpHome(tester);
    expect(find.text('暂无播放记录'), findsOneWidget);

    final fresh = _song('wy-new', '新歌实时出现');
    await tester.runAsync(() => MusicStore.addRecent(fresh));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));

    // Same pumped page, never re-pumped / re-entered: the new song
    // must already be listed under 最近播放.
    expect(find.text('新歌实时出现'), findsOneWidget);
    expect(find.text('暂无播放记录'), findsNothing);
    expect(tester.takeException(), isNull);
  });

  testWidgets('播一首歌后最近播放第一项变成刚播的歌', (tester) async {
    final controller = await pumpHome(tester);
    expect(find.text('暂无播放记录'), findsOneWidget);

    final first = _song('wy-a', '第一首');
    final second = _song('wy-b', '第二首');
    // First song plays (resolve -> addRecent -> open on fake player).
    await tester.runAsync(() => controller.playQueue([first, second], 0));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
    // Scope to the SongRow rows: the mini player bar shows the same
    // playing title, so a bare find.text would match twice.
    Finder inRecent(String title) =>
        find.descendant(of: find.byType(SongRow), matching: find.text(title));
    expect(inRecent('第一首'), findsOneWidget);

    // 切歌：第二首播起后，它必须顶到最近播放第一位，同样不用
    // 切页面 / 重进。
    await tester.runAsync(() => controller.next());
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 300));
    expect(inRecent('第二首'), findsOneWidget);
    // 第二首在第一位：它在列表里先出现（SongRow 行顺序即 _recent
    // 顺序），且第一首仍在后面。
    expect(inRecent('第一首'), findsOneWidget);
    final secondOffset = tester.getTopLeft(inRecent('第二首')).dy;
    final firstOffset = tester.getTopLeft(inRecent('第一首')).dy;
    expect(secondOffset, lessThan(firstOffset));
    expect(tester.takeException(), isNull);
  });
}
