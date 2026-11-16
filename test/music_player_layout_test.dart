// Music player layout + image provider regression tests.
//
// 1. Player layout (v1.0.5 phone bug): the star button was wrapped in an
//    Obx, but isFav() reads Hive — not an Rx observable — so the Obx threw
//    "improper use of GetX" on every build, the title row blew up to
//    100000pt tall, and every control below it (progress, transport,
//    volume, bottom icons) was pushed to y≈100424 (off-screen). On the
//    phone that rendered as a big grey box under the Master badge. The fix
//    removed the Obx (star refreshes via setState in onPressed). This test
//    pumps the real player page and asserts the controls sit on-screen.
// 2. MusicImageProvider Referer mapping per music CDN host.
// 3. Cover background (Apple Music rule): dominantCoverColor extracts the
//    cover tint for the blurred-cover background; an empty cover falls
//    back to the theme gradient, never a grey block.

import 'dart:ui' as ui;

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_player_sheet.dart';
import 'package:standalone/features/music/widgets/music_image.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/play_mode.dart';

/// Test double: advances the index like next() but skips the real load
/// (URL resolve + lyrics fetch create Dio fake-timers that never fire in
/// the widget-test zone and would trip teardown's !timersPending — and
/// pump(Duration) over them never returns). The gesture routing
/// (cover-only) is what the swipe group verifies; audio loading is the
/// controller's business, covered by music_test.dart.
class _NoLoadController extends MusicPlayerController {
  @override
  Future<void> next({bool auto = false}) async {
    if (queue.length <= 1) return;
    final n =
        nextTrackIndex(mode, currentIndex.value, queue.length, auto: auto);
    if (n < 0) return;
    currentIndex.value = n;
  }
}

void main() {
  late Box<dynamic> box;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
      const MethodChannel(nowPlayingChannelName),
      (call) async => null,
    );
    Hive.init('test/.hive-music-player-layout');
    box = await Hive.openBox<dynamic>('music_player_layout');
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
    await Hive.deleteBoxFromDisk('music_player_layout');
  });

  group('MusicPlayerPage layout', () {
    testWidgets('controls sit on-screen (no 100000pt title row)',
        (tester) async {
      tester.view.physicalSize = const Size(1260, 2736);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final c = Get.put(MusicPlayerController());
      c.queue.assignAll([
        Song(
          songId: '1',
          title: 'Test Song',
          artist: 'Test Artist',
          album: 'Test Album',
          cover:
              'https://p2.music.126.net/5KJI2mq0G0OQHQaAfAJfwg==/109951173289563385.jpg',
          platform: MusicPlatform.wy,
          dur: 200,
        ),
      ]);
      c.currentIndex.value = 0;

      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const MusicPlayerPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Title + controls all visible on one screen (912pt tall).
      expect(find.text('Test Song'), findsOneWidget);
      expect(find.text('正在播放'), findsOneWidget);
      final screen = tester.getSize(find.byType(Scaffold).first);
      for (final icon in [
        Icons.skip_previous,
        Icons.skip_next,
        Icons.volume_down,
        Icons.queue_music,
      ]) {
        final rect = tester.getRect(find.byIcon(icon).first);
        expect(rect.top, greaterThanOrEqualTo(0.0));
        expect(rect.bottom, lessThanOrEqualTo(screen.height));
      }
      final sliderRect = tester.getRect(find.byType(Slider).first);
      expect(sliderRect.top, lessThan(screen.height));
      // Cover uses the Dio-backed provider, not Image.network.
      final image = tester.widget<Image>(find.byType(Image).first);
      expect(image.image, isA<MusicImageProvider>());
    });
  });

  group('musicImageReferer', () {
    test('NetEase / QQ / Kuwo hosts get their Referer', () {
      expect(musicImageReferer('https://p1.music.126.net/x.jpg'),
          'https://music.163.com/');
      expect(musicImageReferer('https://p2.music.126.net/x.jpg'),
          'https://music.163.com/');
      expect(
          musicImageReferer(
              'https://y.gtimg.cn/music/photo_new/T002R300x300M000x.jpg'),
          'https://y.qq.com/');
      expect(musicImageReferer('https://img1.kuwo.cn/star/x.jpg'),
          'https://www.kuwo.cn/');
      expect(musicImageReferer('https://example.com/x.jpg'), '');
    });

    test('provider equality is by url', () {
      const a = MusicImageProvider('https://p1.music.126.net/x.jpg');
      const b = MusicImageProvider('https://p1.music.126.net/x.jpg');
      const c = MusicImageProvider('https://p2.music.126.net/y.jpg');
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      expect(a == c, isFalse);
    });
  });

  group('dominantCoverColor', () {
    Future<Uint8List> solidPng(Color color) async {
      final recorder = ui.PictureRecorder();
      final canvas = Canvas(recorder);
      canvas.drawRect(
        const Rect.fromLTWH(0, 0, 16, 16),
        Paint()..color = color,
      );
      final picture = recorder.endRecording();
      final image = await picture.toImage(16, 16);
      final data = await image.toByteData(format: ui.ImageByteFormat.png);
      return data!.buffer.asUint8List();
    }

    test('solid red image -> red tint', () async {
      final bytes = await solidPng(const Color(0xFFD43A2F));
      final tint = await dominantCoverColor(bytes);
      expect(tint, isNotNull);
      expect((tint!.r * 255).round(), greaterThan(180));
      expect((tint.g * 255).round(), lessThan(110));
      expect((tint.b * 255).round(), lessThan(110));
    });

    test('garbage bytes -> null (fallback)', () async {
      expect(
          await dominantCoverColor(Uint8List.fromList([1, 2, 3])), isNull);
      expect(await dominantCoverColor(Uint8List(0)), isNull);
    });
  });

  group('MusicPlayerPage background fallback', () {
    testWidgets('empty cover -> theme gradient, no grey block',
        (tester) async {
      tester.view.physicalSize = const Size(1260, 2736);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final c = Get.put(MusicPlayerController());
      c.queue.assignAll([
        Song(
          songId: '2',
          title: 'No Cover Song',
          artist: 'Nobody',
          cover: '',
          platform: MusicPlatform.wy,
          dur: 120,
        ),
      ]);
      c.currentIndex.value = 0;

      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const MusicPlayerPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      // Page renders; title + controls on-screen.
      expect(find.text('No Cover Song'), findsOneWidget);
      expect(find.byIcon(Icons.skip_previous), findsOneWidget);
      // No grey block: no LARGE near-opaque solid light-grey Container
      // anywhere. (Small white bits like the progress-bar fill, and
      // translucent white chips like the quality badge, do not count —
      // the bug's grey block was ~40% of the screen.)
      final boxes = find.byWidgetPredicate((w) {
        if (w is Container) {
          final d = w.decoration;
          return d is BoxDecoration && d.color != null;
        }
        return false;
      });
      for (final e in boxes.evaluate()) {
        final d = (e.widget as Container).decoration as BoxDecoration;
        final color = d.color!;
        final size = (e.renderObject as RenderBox?)?.size ?? Size.zero;
        final r = (color.r * 255).round();
        final g = (color.g * 255).round();
        final b = (color.b * 255).round();
        final isLightGrey = color.a >= 0.8 &&
            r > 150 &&
            g > 150 &&
            b > 150 &&
            (r - b).abs() < 20 &&
            size.width >= 100 &&
            size.height >= 100;
        expect(isLightGrey, isFalse,
            reason: 'grey block painted by $e: $color size=$size');
      }
    });
  });

  group('cover-only swipe to switch songs', () {
    Future<void> pumpTwoSongs(WidgetTester tester) async {
      tester.view.physicalSize = const Size(1260, 2736);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final c = Get.put<MusicPlayerController>(_NoLoadController());
      c.queue.assignAll([
        Song(
          songId: 's1',
          title: 'Song One',
          artist: 'A',
          cover: '',
          platform: MusicPlatform.wy,
          dur: 120,
        ),
        Song(
          songId: 's2',
          title: 'Song Two',
          artist: 'B',
          cover: '',
          platform: MusicPlatform.wy,
          dur: 120,
        ),
      ]);
      c.currentIndex.value = 0;

      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const MusicPlayerPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('Song One'), findsOneWidget);
    }

    testWidgets('drag left on cover -> next song', (tester) async {
      await pumpTwoSongs(tester);
      // Cover placeholder = the note icon inside the cover square.
      await tester.drag(
          find.byIcon(Icons.music_note), const Offset(-200, 0));
      await tester.pump();
      expect(find.text('Song Two'), findsOneWidget);
    });

    testWidgets('drag left on title -> no switch', (tester) async {
      await pumpTwoSongs(tester);
      await tester.drag(find.text('Song One'), const Offset(-200, 0));
      await tester.pump();
      expect(find.text('Song One'), findsOneWidget);
    });

    testWidgets('drag left on lyrics area -> no switch', (tester) async {
      await pumpTwoSongs(tester);
      final lyricsText = find.byWidgetPredicate((w) =>
          w is Text &&
          (w.data == '歌词加载中…' || w.data == '暂无歌词'));
      await tester.drag(lyricsText, const Offset(-200, 0));
      await tester.pump();
      expect(find.text('Song One'), findsOneWidget);
    });
  });
}
