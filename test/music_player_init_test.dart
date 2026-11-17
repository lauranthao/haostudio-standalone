// Music player init regression — MediaKit.ensureInitialized() was never
// called anywhere, so the first Player() construction threw
// (NativeLibrary.path not initialised) and the whole music tab rendered
// blank on a real device; live/video MpvBackend had the same failure.
//
// Covers:
// - Get.put(MusicPlayerController()) never throws, even when the native
//   media_kit library was never initialised: onInit catches the Player()
//   failure, leaves _playersReady false, and the controller still
//   initialises (NowPlaying / sleep timer / listeners) and disposes
//   cleanly (late-final players are not touched on close).
// - Pumping the real MusicTabPage renders the music tab instead of a
//   blank screen.

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_tab_page.dart';

void main() {
  late Box<dynamic> box;

  setUp(() async {
    // No native NowPlaying plugin in the test env: onClose calls
    // clearNowPlaying on the channel, so mock it to a no-op or the
    // unawaited Future fails the test with MissingPluginException.
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(nowPlayingChannelName),
      (call) async => null,
    );
    Hive.init('test/.hive-music-init-test');
    box = await Hive.openBox<dynamic>('music_init_test');
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
    await Hive.deleteBoxFromDisk('music_init_test');
  });

  group('MusicPlayerController init without MediaKit', () {
    test('Get.put does not throw when native players cannot be created',
        () {
      expect(() => Get.put(MusicPlayerController()), returnsNormally);
      expect(Get.isRegistered<MusicPlayerController>(), isTrue);
      // onClose must not touch the never-created late-final players.
      expect(() => Get.delete<MusicPlayerController>(), returnsNormally);
    });
  });

  group('MusicTabPage widget', () {
    testWidgets('pumps and renders the music tab', (tester) async {
      // iPhone-ish 390x844 logical @2x: the 最近播放 head sits below
      // the fold in the default 800x600 test viewport and the ListView
      // would not have built it yet.
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const MusicTabPage(),
        ),
      );
      await tester.pump();
      // P0-4 (Kumone redo): the AppBar title '音乐' is gone by design
      // — the tab bar already says 音乐 and the greeting is the page's
      // one large title. Assert on the page's own content instead.
      expect(find.text('我的歌单'), findsOneWidget);
      expect(find.text('最近播放'), findsOneWidget);
      expect(find.text('搜歌'), findsOneWidget);
      expect(find.byType(Scaffold), findsOneWidget);
      await tester.pumpAndSettle();
    });
  });
}
