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

import 'dart:math' as math;
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart' hide Response;
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/comments_page.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_player_sheet.dart';
import 'package:standalone/features/music/widgets/music_image.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/play_mode.dart';

/// Test double: advances the index like next() but skips the real load
/// (URL resolve + lyrics fetch create Dio fake-timers that never fire in
/// the widget-test zone and would trip teardown's !timersPending — and
/// pump(Duration) over them never returns). The gesture routing
/// (cover-only) is what the swipe group verifies; audio loading is the
/// controller's business, covered by music_test.dart.
class _NoLoadController extends MusicPlayerController {
  /// Recorded seek targets (lyric tap-to-seek tests).
  final List<Duration> seeks = [];

  @override
  Future<void> seek(Duration pos) async {
    seeks.add(pos);
  }

  @override
  Future<void> next({bool auto = false}) async {
    if (queue.length <= 1) return;
    final n = nextTrackIndex(
      mode,
      currentIndex.value,
      queue.length,
      auto: auto,
    );
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
    // In-memory box (same pattern as render_music_player_test.dart):
    // a DISK box hangs testWidgets — Hive's disk-IO Futures never
    // resolve inside the FakeAsync zone (put/close/clear all stall,
    // and runAsync cannot drain a write queued behind a body-created
    // one), so the star test never flips and the shuffle test times
    // out in tearDown's box.close(). The memory backend has no disk
    // IO, so puts complete via microtask and close() returns. The
    // app code under test is unchanged (controller -> MusicStore ->
    // HiveStore.put -> box); only the harness box is memory-backed.
    Hive.init('test/.hive-music-player-layout');
    box = await Hive.openBox<dynamic>(
      'music_player_layout',
      bytes: Uint8List(0),
    );
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
  });

  group('MusicPlayerPage layout', () {
    testWidgets('controls sit on-screen (no 100000pt title row)', (
      tester,
    ) async {
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
          cover: 'https://p2.music.126.net/5KJI2mq0G0OQHQaAfAJfwg==/109951173289563385.jpg',
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
      // Kumone classic has no centre "正在播放" text (removed 2026-11-18);
      // the top bar is collapse + sound-effects + lyrics-toggle circles.
      expect(find.text('正在播放'), findsNothing);
      expect(find.byIcon(Icons.keyboard_arrow_down), findsOneWidget);
      expect(find.byIcon(Icons.format_quote), findsOneWidget);
      // PL-P1-6: tune only in the top bar now (one, not two).
      expect(find.byIcon(Icons.tune), findsOneWidget);
      final screen = tester.getSize(find.byType(Scaffold).first);
      for (final icon in [
        Icons.skip_previous,
        Icons.skip_next,
        Icons.queue_music,
      ]) {
        final rect = tester.getRect(find.byIcon(icon).first);
        expect(rect.top, greaterThanOrEqualTo(0.0));
        expect(rect.bottom, lessThanOrEqualTo(screen.height));
      }
      // No volume slider anymore (chen 2026-11-17): the player has no
      // volume control of its own — volume is the system volume.
      expect(find.byType(Slider), findsNothing);
      // Cover uses the Dio-backed provider, not Image.network.
      final image = tester.widget<Image>(find.byType(Image).first);
      expect(image.image, isA<MusicImageProvider>());
    });
  });

  group('AirPlay button: opens the system route picker (chen 2026-11-17)', () {
    Future<void> pumpPage(WidgetTester tester) async {
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
          cover: 'https://p2.music.126.net/5KJI2mq0G0OQHQaAfAJfwg==/109951173289563385.jpg',
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
    }

    testWidgets('tap AirPlay with no native picker -> honest failure toast', (
      tester,
    ) async {
      await pumpPage(tester);
      // setUp mocks the channel to reply null: native cannot open the
      // picker, so the button reports the failure instead of the old
      // dead text ("当前设备不支持隔空播放" was never a real check).
      await tester.tap(find.byIcon(Icons.airplay));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('无法打开隔空播放选择器'), findsOneWidget);
      expect(find.text('当前设备不支持隔空播放'), findsNothing);
    });

    testWidgets('tap AirPlay when native opens the picker -> no toast', (
      tester,
    ) async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
            const MethodChannel(nowPlayingChannelName),
            (call) async => call.method == 'showAirPlayPicker' ? true : null,
          );
      await pumpPage(tester);
      await tester.tap(find.byIcon(Icons.airplay));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('无法打开隔空播放选择器'), findsNothing);
      expect(find.text('当前设备不支持隔空播放'), findsNothing);
    });
  });

  group('musicImageReferer', () {
    test('NetEase / QQ / Kuwo hosts get their Referer', () {
      expect(
        musicImageReferer('https://p1.music.126.net/x.jpg'),
        'https://music.163.com/',
      );
      expect(
        musicImageReferer('https://p2.music.126.net/x.jpg'),
        'https://music.163.com/',
      );
      expect(
        musicImageReferer(
          'https://y.gtimg.cn/music/photo_new/T002R300x300M000x.jpg',
        ),
        'https://y.qq.com/',
      );
      expect(
        musicImageReferer('https://img1.kuwo.cn/star/x.jpg'),
        'https://www.kuwo.cn/',
      );
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

    test('solid red image -> red tint (brightness clamped 0.32-0.5)', () async {
      final bytes = await solidPng(const Color(0xFFD43A2F));
      final tint = await dominantCoverColor(bytes);
      expect(tint, isNotNull);
      // HSV(~4 deg, 0.72, 0.5): red-dominant but dark — the clamp caps
      // value at 0.5, so r is ~128, not ~212.
      expect((tint!.r * 255).round(), inInclusiveRange(110, 145));
      expect((tint.g * 255).round(), lessThan(110));
      expect((tint.b * 255).round(), lessThan(110));
    });

    test('solid black image -> tint lightness >= 0.32 (Kumone clamp)', () async {
      final bytes = await solidPng(const Color(0xFF000000));
      final tint = await dominantCoverColor(bytes);
      expect(tint, isNotNull);
      expect(HSLColor.fromColor(tint!).lightness, greaterThanOrEqualTo(0.32));
    });

    test('solid white image -> tint lightness <= 0.5 (Kumone clamp)', () async {
      final bytes = await solidPng(const Color(0xFFFFFFFF));
      final tint = await dominantCoverColor(bytes);
      expect(tint, isNotNull);
      // 0.5 * 255 = 127.5 rounds to 128 in 8-bit, so allow 0.51.
      expect(HSLColor.fromColor(tint!).lightness, lessThanOrEqualTo(0.51));
    });

    test('garbage bytes -> null (fallback)', () async {
      expect(await dominantCoverColor(Uint8List.fromList([1, 2, 3])), isNull);
      expect(await dominantCoverColor(Uint8List(0)), isNull);
    });
  });

  group('MusicPlayerPage background fallback', () {
    testWidgets('empty cover -> theme gradient, no grey block', (tester) async {
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
        final isLightGrey =
            color.a >= 0.8 &&
            r > 150 &&
            g > 150 &&
            b > 150 &&
            (r - b).abs() < 20 &&
            size.width >= 100 &&
            size.height >= 100;
        expect(
          isLightGrey,
          isFalse,
          reason: 'grey block painted by $e: $color size=$size',
        );
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
      await tester.drag(find.byIcon(Icons.music_note), const Offset(-200, 0));
      await tester.pump();
      expect(find.text('Song Two'), findsOneWidget);
    });

    testWidgets('drag left on title -> no switch', (tester) async {
      await pumpTwoSongs(tester);
      await tester.drag(find.text('Song One'), const Offset(-200, 0));
      await tester.pump();
      expect(find.text('Song One'), findsOneWidget);
    });

    testWidgets('drag left on lyrics face -> no switch', (tester) async {
      await pumpTwoSongs(tester);
      // Lyrics live behind the cover: flip to the lyrics side first.
      await tester.tap(find.byKey(const ValueKey('playerCover')));
      await tester.pump(const Duration(milliseconds: 300));
      final lyricsText = find.byWidgetPredicate(
        (w) => w is Text && (w.data == '歌词加载中…' || w.data == '暂无歌词'),
      );
      expect(lyricsText, findsOneWidget);
      await tester.drag(lyricsText, const Offset(-200, 0));
      await tester.pump();
      expect(find.text('Song One'), findsOneWidget);
    });
  });

  group(
    'progress bar scrub: one seek on release, none mid-drag (chen 2026-11-17)',
    () {
      Future<_NoLoadController> pumpPlayer(WidgetTester tester) async {
        tester.view.physicalSize = const Size(1260, 2736);
        tester.view.devicePixelRatio = 3.0;
        addTearDown(tester.view.resetPhysicalSize);
        addTearDown(tester.view.resetDevicePixelRatio);

        final c = Get.put<MusicPlayerController>(
          _NoLoadController(),
        ) as _NoLoadController;
        c.queue.assignAll([
          Song(
            songId: 's1',
            title: 'Song One',
            artist: 'A',
            cover: '',
            platform: MusicPlatform.wy,
            dur: 200,
          ),
        ]);
        c.currentIndex.value = 0;
        c.duration.value = const Duration(seconds: 200);
        c.position.value = Duration.zero;

        await tester.pumpWidget(
          GetMaterialApp(
            theme: HaoThemes.of(HaoThemeId.appleGlass).light,
            home: const MusicPlayerPage(),
          ),
        );
        await tester.pump();
        await tester.pump(const Duration(milliseconds: 100));
        return c;
      }

      testWidgets('drag across the bar seeks exactly once, on release', (
        tester,
      ) async {
        final c = await pumpPlayer(tester);
        final bar = find.byKey(const ValueKey('progressBar'));
        expect(bar, findsOneWidget);
        final rect = tester.getRect(bar);
        // 10% -> 60% across the bar: release at 60% of 200 s = 120 s.
        final start = Offset(rect.left + rect.width * 0.1, rect.center.dy);
        final end = Offset(rect.left + rect.width * 0.6, rect.center.dy);
        await tester.timedDragFrom(
          start,
          end - start,
          const Duration(milliseconds: 300),
        );
        await tester.pump();
        // Before the fix the drag seeked on every move event (a native
        // seek per frame, stuttering the audio) plus the press-down
        // tap: ~10 seeks. Now: one, on release.
        expect(c.seeks, hasLength(1));
        expect(c.seeks.single.inSeconds, closeTo(120, 5));
      });

      testWidgets(
        'dragging previews the time in the elapsed label, no bubble (Kumone)',
        (tester) async {
          final c = await pumpPlayer(tester);
          final bar = find.byKey(const ValueKey('progressBar'));
          expect(bar, findsOneWidget);
          final rect = tester.getRect(bar);
          // Hold at 10%, drag to 60% of 200 s: the elapsed label (10.5pt
          // tabular) previews 2:00 while no seek has fired yet. Kumone
          // has no drag bubble — the old black bubble above the thumb
          // was removed 2026-11-18, so no 11pt preview text exists.
          final start = Offset(rect.left + rect.width * 0.1, rect.center.dy);
          final gesture = await tester.startGesture(start);
          await gesture.moveBy(Offset(rect.width * 0.5, 0));
          await tester.pump();
          final preview = find.byWidgetPredicate(
            (w) => w is Text && w.data == '2:00' && w.style?.fontSize == 10.5,
          );
          expect(preview, findsOneWidget);
          final bubble = find.byWidgetPredicate(
            (w) => w is Text && w.data == '2:00' && w.style?.fontSize == 11,
          );
          expect(bubble, findsNothing);
          expect(c.seeks, isEmpty);
          await gesture.up();
          await tester.pump();
          expect(c.seeks, hasLength(1));
        },
      );

      testWidgets('tap on the bar seeks immediately to the tap point', (
        tester,
      ) async {
        final c = await pumpPlayer(tester);
        final bar = find.byKey(const ValueKey('progressBar'));
        final rect = tester.getRect(bar);
        await tester.tapAt(
          Offset(rect.left + rect.width * 0.6, rect.center.dy),
        );
        await tester.pump();
        expect(c.seeks, hasLength(1));
        expect(c.seeks.single.inSeconds, closeTo(120, 5));
      });
    },
  );

  group('lyrics behind cover: tap cover to flip, tap line to seek (chen 2026-11-17)', () {
    Future<_NoLoadController> pumpLyrics(
      WidgetTester tester, {
      List<LyricLine>? lines,
    }) async {
      tester.view.physicalSize = const Size(1260, 2736);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final c = Get.put<MusicPlayerController>(
        _NoLoadController(),
      ) as _NoLoadController;
      c.queue.assignAll([
        Song(
          songId: 's1',
          title: 'Lyric Song',
          artist: 'A',
          cover: '',
          platform: MusicPlatform.wy,
          dur: 200,
        ),
      ]);
      c.currentIndex.value = 0;
      c.lyrics.assignAll(
        lines ??
            [
              LyricLine(t: 10, text: '第一句'),
              LyricLine(t: 25.5, text: '第二句'),
              LyricLine(t: 40, text: '第三句'),
            ],
      );

      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const MusicPlayerPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      // Cover side shows by default (lyrics live behind it); flip first.
      expect(c.showLyrics.value, isFalse);
      expect(find.byKey(const ValueKey('playerCover')), findsOneWidget);
      await tester.tap(find.byKey(const ValueKey('playerCover')));
      await tester.pump(const Duration(milliseconds: 300));
      if (lines == null) {
        expect(find.text('第二句'), findsOneWidget);
      }
      return c;
    }

    testWidgets('tap a lyric line seeks to its timestamp, stays on lyrics', (
      tester,
    ) async {
      final c = await pumpLyrics(tester);
      await tester.tap(find.text('第二句'));
      await tester.pump();
      expect(c.seeks, [const Duration(milliseconds: 25500)]);
      // Inner (line) tap wins over the outer (face) tap: still on lyrics.
      expect(c.showLyrics.value, isTrue);
      expect(find.text('第二句'), findsOneWidget);
    });

    testWidgets(
      'tap empty lyrics padding flips back to cover; tap cover flips to lyrics again',
      (tester) async {
        final c = await pumpLyrics(tester);
        // Top 12 px of the lyrics face is ListView padding (empty space).
        final topLeft = tester.getTopLeft(
          find.byKey(const ValueKey('playerLyrics')),
        );
        await tester.tapAt(topLeft + const Offset(100, 4));
        // Flip-back fades the lyrics out (420 ms); settle so the outgoing
        // child is actually removed before asserting it is gone.
        await tester.pumpAndSettle();
        expect(c.showLyrics.value, isFalse);
        expect(find.text('第二句'), findsNothing);
        expect(find.byKey(const ValueKey('playerCover')), findsOneWidget);

        await tester.tap(find.byKey(const ValueKey('playerCover')));
        await tester.pump(const Duration(milliseconds: 300));
        expect(c.showLyrics.value, isTrue);
        expect(find.text('第二句'), findsOneWidget);
      },
    );

    testWidgets('bottom lyrics toggle flips cover/lyrics (PL-P0-3 + PL-P2-5)', (
      tester,
    ) async {
      final c = await pumpLyrics(tester);
      // On the lyrics side the bottom key shows music.note in accent;
      // tap it -> back to cover. Wait out the 420ms flip fade first:
      // the outgoing cover face still holds its music.note placeholder
      // until the fade finishes, so the icon is ambiguous before that.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.byIcon(Icons.music_note));
      // Flip-back fades the lyrics out (420 ms); settle so the outgoing
      // child is actually removed before asserting it is gone.
      await tester.pumpAndSettle();
      expect(c.showLyrics.value, isFalse);
      expect(find.text('第二句'), findsNothing);
      // On the cover side: tap the icon -> lyrics again.
      await tester.tap(find.byIcon(Icons.format_quote));
      await tester.pump(const Duration(milliseconds: 500));
      expect(c.showLyrics.value, isTrue);
      expect(find.text('第二句'), findsOneWidget);
    });

    testWidgets(
      'lyrics face: no background box, bigger text, near-full width (chen 2026-11-17)',
      (tester) async {
        final c = await pumpLyrics(tester);
        final face = find.byKey(const ValueKey('playerLyrics'));
        expect(face, findsOneWidget);
        // No box: the face itself is a SizedBox, and no descendant
        // Container paints any background color, gradient or decoration.
        expect(face.evaluate().single.widget, isA<SizedBox>());
        final painted = find.descendant(
          of: face,
          matching: find.byWidgetPredicate((w) {
            if (w is Container) {
              final d = w.decoration;
              if (d is BoxDecoration &&
                  (d.color != null || d.gradient != null)) {
                return true;
              }
              if (w.color != null) return true;
            }
            return false;
          }),
        );
        expect(painted, findsNothing);
        // Width: near full screen (420pt - 32pt margins = 388); height
        // still the cover square (Kumone classic: min(420-64, 912×0.38,
        // 300) = 300).
        final rect = tester.getRect(face);
        expect(rect.width, closeTo(388, 1));
        expect(rect.height, closeTo(300, 1));
        // Font sizes (Kumone regular column): move the clock to 12s so
        // line 1 (t:10) is current. The spring auto-scroll starts in a
        // post-frame callback after the position change, and an
        // AnimationController's FIRST ticker tick only sets the
        // baseline — the simulation does not advance until a later
        // tick with a nonzero delta. So: 500 ms (frame that starts
        // the spring) + 500 ms (baseline tick) + 500 ms (the spring
        // runs to settled ~65) + a bare pump to apply the rebuild.
        // With fewer frames the offset stays 0 and line 3 sits just
        // below the face viewport, where find.text skips it as
        // offstage (the line IS built; the dump proves it).
        c.position.value = const Duration(seconds: 12);
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump(const Duration(milliseconds: 500));
        await tester.pump();
        Text textOf(String s) => tester.widget<Text>(find.text(s));
        expect(textOf('第一句').style?.fontSize, 26);
        expect(textOf('第二句').style?.fontSize, 20);
        expect(textOf('第三句').style?.fontSize, 20);
        // Every line carries the faint readability shadow.
        for (final s in ['第一句', '第二句', '第三句']) {
          expect(textOf(s).style?.shadows, isNotEmpty);
        }
      },
    );

    testWidgets(
      'translation shows under the current line only (Beans tlyric)',
      (tester) async {
        final c = await pumpLyrics(
          tester,
          lines: [
            LyricLine(t: 10, text: '第一句', translation: 'First line'),
            LyricLine(t: 25.5, text: '第二句', translation: 'Second line'),
            LyricLine(t: 40, text: '第三句'),
          ],
        );
        // Line 1 is current at 12 s: only its translation shows.
        c.position.value = const Duration(seconds: 12);
        await tester.pump();
        expect(find.text('First line'), findsOneWidget);
        expect(find.text('Second line'), findsNothing);
        // Move to line 2: its translation replaces line 1's.
        c.position.value = const Duration(seconds: 26);
        await tester.pump();
        expect(find.text('First line'), findsNothing);
        expect(find.text('Second line'), findsOneWidget);
      },
    );

    testWidgets(
      'lyrics face has a top/bottom fade mask (Beans viewport fade)',
      (tester) async {
        await pumpLyrics(tester);
        final face = find.byKey(const ValueKey('playerLyrics'));
        expect(
          find.descendant(of: face, matching: find.byType(ShaderMask)),
          findsOneWidget,
        );
      },
    );

    testWidgets(
      'user drag pauses auto-follow and snaps to the nearest line (Beans)',
      (tester) async {
        final c = await pumpLyrics(
          tester,
          lines: List.generate(
            20,
            (i) => LyricLine(t: i * 10.0, text: '第${i + 1}句'),
          ),
        );
        final face = find.byKey(const ValueKey('playerLyrics'));
        // 20 lines: content 20*32+24 = 664 pt > 285.6 pt viewport, so the
        // list can actually scroll (3 lines cannot).
        final scrollable = tester.state<ScrollableState>(
          find.descendant(of: face, matching: find.byType(Scrollable)),
        );
        expect(scrollable.position.pixels, 0);
        // Drag the list up 100 px: auto-follow pauses, offset ~100.
        await tester.timedDragFrom(
          tester.getCenter(face),
          const Offset(0, -100),
          const Duration(milliseconds: 300),
        );
        // Release snaps to the nearest row boundary in 300 ms — but the
        // drag's ballistic tail runs first, and the deferred snap needs
        // a frame to start ticking, so allow ~900 ms total. The snap
        // target is the nearest row's measured centre (PL-P1-4), so
        // the line nearest the face centre must sit within 2pt of it.
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        await tester.pump(const Duration(milliseconds: 300));
        final px = scrollable.position.pixels;
        expect(px, greaterThan(0));
        final faceRect = tester.getRect(face);
        var best = double.infinity;
        for (var i = 1; i <= 20; i++) {
          final line = find.text('第$i句');
          if (line.evaluate().isEmpty) continue;
          final r = tester.getRect(line);
          best = math.min(best, (r.center.dy - faceRect.center.dy).abs());
        }
        expect(best, lessThan(2.0));
        // Drain the 5 s resume timer so teardown sees no pending timers.
        await tester.pump(const Duration(seconds: 6));
        expect(c.showLyrics.value, isTrue);
      },
    );

    testWidgets(
      'auto-scroll centres the current line within 2pt, with translations (PL-P1-4)',
      (tester) async {
        // Every line has a translation, but only the current line shows
        // it — so the current row is ~74pt and the rest ~50pt. The old
        // fixed 50pt stride put every line after the current one ~24pt
        // off-centre; measured offsets must land within 2pt.
        final c = await pumpLyrics(
          tester,
          lines: List.generate(
            10,
            (i) => LyricLine(
              t: i * 10.0,
              text: '第${i + 1}句',
              translation: 'Line ${i + 1}',
            ),
          ),
        );
        Future<void> checkLine(int lineNo, Duration pos) async {
          c.position.value = pos;
          // Same pump pattern as the font-size test: 500 ms (frame
          // that starts the spring) + 500 ms (baseline tick) + 500 ms
          // (spring runs to settled) + a bare pump to apply the
          // rebuild. One extra 500 ms for the longer jump to line 10.
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();
          final faceRect = tester.getRect(
            find.byKey(const ValueKey('playerLyrics')),
          );
          // The ROW centre is what scrolls to the viewport centre
          // (Kumone scrollTo anchor:.center centres the whole cell).
          // The row is Padding(13) + Column[main line + translation],
          // so its centre is (main-line top + translation bottom) / 2.
          // (The main line itself sits ~13pt above the row centre
          // while its translation hangs below — that is the cell
          // shape, not a scroll error.)
          final lineRect = tester.getRect(find.text('第$lineNo句'));
          final transRect = tester.getRect(find.text('Line $lineNo'));
          final rowCentre = (lineRect.top + transRect.bottom) / 2;
          expect(
            (rowCentre - faceRect.center.dy).abs(),
            lessThan(2.0),
            reason: 'line $lineNo row must sit at the viewport centre',
          );
        }

        await checkLine(5, const Duration(seconds: 42));
        await checkLine(10, const Duration(seconds: 92));
      },
    );
  });

  group('song comments page (chen 2026-11-17)', () {
    /// Stub Dio: the NetEase comments URL returns 2 hot + 35 latest;
    /// every other URL (alt-platform search) returns an empty map.
    Dio stubCommentsDio() {
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.contains('resource/comments')) {
              final hot = [
                {
                  'user': {'nickname': '热评甲', 'avatarUrl': ''},
                  'content': '这首歌绝了',
                  'likedCount': 500,
                  'time': 1700000000000,
                },
                {
                  'user': {'nickname': '热评乙', 'avatarUrl': ''},
                  'content': '单曲循环中',
                  'likedCount': 300,
                  'time': 1700000001000,
                },
              ];
              final list = List.generate(
                35,
                (i) => {
                  'user': {'nickname': 'u$i', 'avatarUrl': ''},
                  'content': '评论 $i',
                  'likedCount': 0,
                  'time': (i + 1) * 1000,
                },
              );
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

    testWidgets('hot on top, latest below, load more appends the tail', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(1170, 2532);
      tester.view.devicePixelRatio = 3.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: SongCommentsPage(
            song: Song(
              songId: '66285',
              title: '葡萄成熟时',
              artist: '陈奕迅',
              platform: MusicPlatform.wy,
            ),
            api: MusicApi(dio: stubCommentsDio()),
          ),
        ),
      );
      // The aggregator also searches the other platforms for the same
      // song (alt-platform comments); the stubbed Kuwo search returns
      // empty and retries after an 800 ms delay, so the page needs
      // ~1 s of fake time before the list appears.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));

      expect(find.text('评论'), findsOneWidget);
      expect(find.text('精彩评论'), findsOneWidget);
      expect(find.text('热评甲'), findsOneWidget);
      expect(find.text('最新评论'), findsOneWidget);

      await tester.scrollUntilVisible(find.text('加载更多'), 300);
      await tester.tap(find.text('加载更多'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.scrollUntilVisible(find.text('没有更多了'), 300);
      expect(find.text('没有更多了'), findsOneWidget);
      expect(find.text('u0'), findsOneWidget);
    });
  });

  group('Kumone redo design values (2026-11-18)', () {
    Future<MusicPlayerController> pumpPlayer(
      WidgetTester tester, {
      Size physicalSize = const Size(1260, 2736),
      double devicePixelRatio = 3.0,
    }) async {
      tester.view.physicalSize = physicalSize;
      tester.view.devicePixelRatio = devicePixelRatio;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final c = Get.put(MusicPlayerController());
      c.queue.assignAll([
        Song(
          songId: 's1',
          title: 'Song One',
          artist: 'A',
          cover: '',
          platform: MusicPlatform.wy,
          dur: 200,
        ),
      ]);
      c.currentIndex.value = 0;
      c.duration.value = const Duration(seconds: 200);
      c.position.value = const Duration(seconds: 65);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const MusicPlayerPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return c;
    }

    testWidgets('time row: elapsed left, REMAINING right (PL-P1-7)', (
      tester,
    ) async {
      await pumpPlayer(tester);
      expect(find.text('1:05'), findsOneWidget);
      // 200 s total - 65 s elapsed = 135 s remaining -> '-2:15'.
      expect(find.text('-2:15'), findsOneWidget);
      expect(find.text('3:20'), findsNothing);
      expect(find.text('-0:00'), findsNothing);
      // 10.5pt tabular figures, white 0.55.
      final style = tester.widget<Text>(find.text('-2:15')).style!;
      expect(style.fontSize, 10.5);
      expect(style.fontFeatures, contains(FontFeature.tabularFigures()));
      expect((style.color!.a * 255).round(), closeTo(0.55 * 255, 2));
    });

    testWidgets(
      'title left-aligned, 21 bold / artist 13.5 white 0.65 (PL-P0-2)',
      (tester) async {
        await pumpPlayer(tester);
        final title = tester.widget<Text>(find.text('Song One'));
        expect(title.style?.fontSize, 21);
        expect(title.style?.fontWeight, FontWeight.w700);
        expect(title.textAlign, TextAlign.left);
        final artist = tester.widget<Text>(find.text('A'));
        expect(artist.style?.fontSize, 13.5);
        expect(
          (artist.style!.color!.a * 255).round(),
          closeTo(0.65 * 255, 2),
        );
        // Star + more sit on the title row's right (44x44 each).
        expect(find.byIcon(Icons.star_border), findsOneWidget);
        expect(find.byIcon(Icons.more_horiz), findsOneWidget);
      },
    );

    testWidgets('cover is the Kumone classic square (300 at 420x912)', (
      tester,
    ) async {
      await pumpPlayer(tester);
      final rect = tester.getRect(find.byKey(const ValueKey('playerCover')));
      expect(rect.width, closeTo(300, 1));
      expect(rect.height, closeTo(300, 1));
    });

    testWidgets('transport row is three bare white triangles (PL-P0-1)', (
      tester,
    ) async {
      await pumpPlayer(tester);
      // Kumone CompactTransportControls: prev/next 25, play 36, all
      // pure white, no background circles.
      final play = tester.widget<Icon>(find.byIcon(Icons.play_arrow));
      expect(play.size, 36);
      expect(play.color, Colors.white);
      expect(tester.widget<Icon>(find.byIcon(Icons.skip_previous)).size, 25);
      expect(tester.widget<Icon>(find.byIcon(Icons.skip_next)).size, 25);
      final whiteCircle = find.byWidgetPredicate(
        (w) =>
            w is Container &&
            w.decoration is BoxDecoration &&
            (w.decoration as BoxDecoration).color == Colors.white &&
            (w.decoration as BoxDecoration).shape == BoxShape.circle,
      );
      expect(whiteCircle, findsNothing);
    });

    testWidgets('star in the title row really toggles favourite (PL-P0-2)', (
      tester,
    ) async {
      final c = await pumpPlayer(tester);
      expect(find.byIcon(Icons.star_border), findsOneWidget);
      await tester.tap(find.byIcon(Icons.star_border));
      // toggleFav is an async Hive write + setState. The box is
      // in-memory (see setUp), so the put completes via microtask and
      // two pumps are enough for setState to land.
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byIcon(Icons.star), findsOneWidget);
      expect(c.isFav(c.currentSong!), isTrue);
    });

    testWidgets(
      'shuffle lives in the more sheet: mode row cycles to shuffle (PL-P0-1)',
      (tester) async {
        final c = await pumpPlayer(tester);
        expect(c.mode, PlayMode.sequential);
        // Cycle order: sequential -> listLoop -> singleLoop -> shuffle.
        // Each tap on the mode row pops the sheet, so reopen it per tap.
        for (final label in ['顺序播放', '列表循环', '单曲循环']) {
          await tester.tap(find.byIcon(Icons.more_horiz));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 500));
          await tester.tap(find.text(label));
          // Sheet exit: 500 ms (baseline tick) + 500 ms (runs to
          // dismissed) + a bare pump for the removal frame — same as
          // the quality-sheet tests.
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump(const Duration(milliseconds: 500));
          await tester.pump();
          // The mode-change snackbar lives 4 s; let it dismiss so the
          // next iteration's find.text(label) is unique.
          await tester.pump(const Duration(seconds: 5));
        }
        expect(c.mode, PlayMode.shuffle);
      },
    );

    testWidgets('quality badge opens the quality sheet (GlassContainer)', (
      tester,
    ) async {
      await pumpPlayer(tester);
      expect(find.text('Hi-Res'), findsOneWidget);
      await tester.tap(find.text('Hi-Res'));
      await tester.pump();
      // Entry animation (~300 ms): the sheet slides up; at 100 ms its
      // 取消 button is still below the viewport and the tap misses.
      // Pump 500 ms so the sheet is fully on-screen first.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('音质'), findsOneWidget);
      expect(find.text('Master'), findsOneWidget);
      await tester.tap(find.text('取消'));
      // Exit transition: pop() restarts the route animation's ticker,
      // whose FIRST tick only sets the baseline — the animation does
      // not advance until a later tick with a nonzero delta. So one
      // pump is never enough: 500 ms (baseline tick) + 500 ms (the
      // animation runs to dismissed) + a bare pump for the removal
      // frame that takes the route out of the tree.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('音质'), findsNothing);
    });

    // Regression (chen 2026-11-18, same bug as glass_dialog 18b03fe):
    // the dialog route has no Material ancestor, so Text fell back to
    // the framework debug style (double yellow underline). The sheet
    // now wraps its content in Material(transparency); the title and
    // a row label must carry no underline.
    testWidgets('quality sheet text has no fallback underline', (
      tester,
    ) async {
      await pumpPlayer(tester);
      await tester.tap(find.text('Hi-Res'));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      for (final label in <String>['音质', 'Master']) {
        final rich = tester.widget<RichText>(
          find.descendant(
            of: find.text(label),
            matching: find.byType(RichText),
          ),
        );
        expect(
          rich.text.style?.decoration?.contains(TextDecoration.underline),
          isNot(true),
          reason: '$label must not inherit the fallback underline',
        );
      }
    });

    testWidgets('sleep timer lives in the more sheet (PL-P0-3)', (
      tester,
    ) async {
      await pumpPlayer(tester);
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('睡眠定时'));
      await tester.pump();
      // Entry animation (~300 ms): pump 500 ms so the sheet is fully
      // on-screen and its 取消 button is hittable.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('睡眠定时'), findsOneWidget);
      await tester.tap(find.text('取消'));
      // Exit transition: first tick only sets the animation baseline,
      // so it needs 500 ms + 500 ms + a bare removal-frame pump.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('睡眠定时'), findsNothing);
    });

    // Regression (chen 2026-11-18, same bug as glass_dialog 18b03fe):
    // the dialog route has no Material ancestor, so Text fell back to
    // the framework debug style (double yellow underline). The sheet
    // now wraps its content in Material(transparency); the title must
    // carry no underline.
    testWidgets('sleep sheet text has no fallback underline', (
      tester,
    ) async {
      await pumpPlayer(tester);
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 500));
      await tester.tap(find.text('睡眠定时'));
      await tester.pump();
      // Let the track sheet finish exiting (its own 睡眠定时 row must
      // be gone) and the sleep sheet finish entering, so find.text
      // below is the sheet title only.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      final rich = tester.widget<RichText>(
        find.descendant(
          of: find.text('睡眠定时'),
          matching: find.byType(RichText),
        ),
      );
      expect(
        rich.text.style?.decoration?.contains(TextDecoration.underline),
        isNot(true),
        reason: '睡眠定时 must not inherit the fallback underline',
      );
    });

    testWidgets('more icon opens the track sheet (GlassContainer)', (
      tester,
    ) async {
      await pumpPlayer(tester);
      await tester.tap(find.byIcon(Icons.more_horiz));
      await tester.pump();
      // Entry animation (~300 ms): the track sheet is the tallest of
      // the three — at 100 ms its 取消 sits below the viewport (hit
      // test misses at y≈1076). Pump 500 ms so it is fully on-screen.
      await tester.pump(const Duration(milliseconds: 500));
      expect(find.text('下一首播放'), findsOneWidget);
      await tester.tap(find.text('取消'));
      // Exit transition: first tick only sets the animation baseline,
      // so it needs 500 ms + 500 ms + a bare removal-frame pump.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('下一首播放'), findsNothing);
    });

    testWidgets('transport row does not overflow at 320pt wide (SE 1st gen)', (
      tester,
    ) async {
      // Three equal slots (compact): no fixed-width children, so the
      // row cannot overflow at 320pt.
      await pumpPlayer(tester, physicalSize: const Size(960, 1704));
      expect(find.byIcon(Icons.play_arrow), findsOneWidget);
      expect(tester.widget<Icon>(find.byIcon(Icons.play_arrow)).size, 36);
      expect(find.byIcon(Icons.skip_previous), findsOneWidget);
      expect(find.byIcon(Icons.skip_next), findsOneWidget);
      // A RenderFlex overflow raises a FlutterError during pump.
      expect(tester.takeException(), isNull);
    });
  });

  group('flex gaps capped at 24pt, excess pools to bottom padding (PL-P1-1c + PL-P2-6)', () {
    Future<MusicPlayerController> pumpSized(
      WidgetTester tester, {
      required Size logicalSize,
    }) async {
      tester.view.physicalSize = Size(
        logicalSize.width * 2,
        logicalSize.height * 2,
      );
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      final c = Get.put(MusicPlayerController());
      c.queue.assignAll([
        Song(
          songId: 's1',
          title: 'Song One',
          artist: 'A',
          cover: '',
          platform: MusicPlatform.wy,
          dur: 200,
        ),
      ]);
      c.currentIndex.value = 0;
      c.duration.value = const Duration(seconds: 200);
      c.position.value = const Duration(seconds: 65);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const MusicPlayerPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      return c;
    }

    // Top-bar bottom edge: the top bar is Padding(horizontal 20,
    // vertical 20) around the 36pt buttons.
    double topBarBottom(WidgetTester tester) {
      final bar = find.byWidgetPredicate(
        (w) =>
            w is Padding &&
            w.padding ==
                const EdgeInsets.symmetric(horizontal: 20, vertical: 20),
      );
      return tester.getRect(bar).bottom;
    }

    testWidgets('390x844: gaps capped at 24, bottom row pinned 24 + excess up', (
      tester,
    ) async {
      await pumpSized(tester, logicalSize: const Size(390, 844));
      // gap 1: cover top - top-bar bottom = 24 (capped; slack is 155).
      final coverTop = tester
          .getRect(find.byKey(const ValueKey('playerCover')))
          .top;
      expect(coverTop - topBarBottom(tester), closeTo(24, 1.5));
      // gap 2: progress top - title ROW bottom = 20 fixed + 24 gap.
      // (The row bottom is the artist line — the song title sits at
      // the top of the row, ~21pt above the row bottom.)
      final titleBottom = tester.getRect(find.text('A')).bottom;
      final progressTop =
          tester.getRect(find.byKey(const ValueKey('progressBar'))).top;
      expect(progressTop - titleBottom, closeTo(44, 1.5));
      // Bottom row: bottomPad = 24 + (155 - 72) = 107, so the row
      // bottom sits 107pt above the screen bottom. Two font notes:
      // getRect(find.byIcon(...)) returns the tight 44pt button box,
      // not the 17pt glyph (the Icon's paragraph fills its parent's
      // tight constraints), so no +13.5 offset. And the test font
      // (Ahem) renders the title ~8pt taller than the audit's 46pt
      // estimate (21pt -> 30pt line, 13.5pt -> 19pt), so the row
      // lands ~8pt lower here than on a phone — hence the 12pt
      // tolerance. The gap assertions above are the tight checks.
      final rowBottom = tester.getRect(find.byIcon(Icons.queue_music)).bottom;
      expect(rowBottom, closeTo(844 - 107, 12));
    });

    testWidgets('375x667: small screen gaps shrink together, no overflow', (
      tester,
    ) async {
      await pumpSized(tester, logicalSize: const Size(375, 667));
      final coverTop = tester
          .getRect(find.byKey(const ValueKey('playerCover')))
          .top;
      // slack ~24.5 -> gap ~8.2 (badge/title height estimates move
      // this by a few pt; the cap is what matters, not the digit).
      expect(coverTop - topBarBottom(tester), inInclusiveRange(4, 14));
      expect(tester.takeException(), isNull);
    });
  });

  group('long title stays left-aligned with ellipsis, star + more stay put (PL-P0-2)', () {
    testWidgets('24-char title ellipsizes, buttons never squeezed', (
      tester,
    ) async {
      tester.view.physicalSize = const Size(780, 1688);
      tester.view.devicePixelRatio = 2.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);

      const longTitle = '这是一个超过二十个字的很长很长的歌曲标题用来测试';
      final c = Get.put(MusicPlayerController());
      c.queue.assignAll([
        Song(
          songId: 's1',
          title: longTitle,
          artist: 'A',
          cover: '',
          platform: MusicPlatform.wy,
          dur: 200,
        ),
      ]);
      c.currentIndex.value = 0;
      c.duration.value = const Duration(seconds: 200);
      c.position.value = const Duration(seconds: 65);

      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: const MusicPlayerPage(),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final title = tester.widget<Text>(find.text(longTitle));
      expect(title.maxLines, 1);
      expect(title.overflow, TextOverflow.ellipsis);
      expect(title.textAlign, TextAlign.left);
      // The title rect ends before the star button starts (no squeeze,
      // no overlap); both right-hand keys are present.
      final titleRect = tester.getRect(find.text(longTitle));
      final starRect = tester.getRect(find.byIcon(Icons.star_border));
      final moreRect = tester.getRect(find.byIcon(Icons.more_horiz));
      expect(titleRect.right, lessThanOrEqualTo(starRect.left));
      expect(starRect.right, lessThanOrEqualTo(moreRect.left));
      expect(tester.takeException(), isNull);
    });
  });
}
