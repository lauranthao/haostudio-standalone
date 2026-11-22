// Playback settings sub-sheet regression (build 29 fix, 2026-11-22).
//
// The `···` more sheet ran past one screen on chen's phone (sleep
// timer at y=1195, cancel at y=1324 on a 912pt viewport) and the
// speed-preset Row overflowed by 60px. The five adjustment controls
// (speed / A-B loop / lyric offset / translation / fade) moved
// one tap deeper into the 播放设置 sub-sheet; the `···` sheet keeps
// only actions and fits first screen. These tests nail that down:
// rows reachable without scrolling, presets never overflow, preset
// taps apply, and the sub-sheet returns to the more sheet.
import 'package:flutter/cupertino.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/music_player_sheet.dart';
import 'package:standalone/services/music/music_models.dart';

void main() {
  late Box<dynamic> box;

  setUp(() async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(
          const MethodChannel(nowPlayingChannelName),
          (call) async => null,
        );
    Hive.init('test/.hive-playback-settings-sheet');
    box = await Hive.openBox<dynamic>(
      'playback_settings_sheet',
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

  Future<MusicPlayerController> pumpPlayer(WidgetTester tester) async {
    tester.view.physicalSize = const Size(1260, 2736);
    tester.view.devicePixelRatio = 3.0;
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

  Future<void> openMoreSheet(WidgetTester tester) async {
    await tester.tap(find.byIcon(CupertinoIcons.ellipsis));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
  }

  testWidgets('more sheet fits first screen: sleep timer + cancel '
      'visible', (tester) async {
    await pumpPlayer(tester);
    await openMoreSheet(tester);
    for (final label in ['播放列表', '睡眠定时', '下载', '取消']) {
      final rect = tester.getRect(find.text(label));
      expect(rect.bottom, lessThanOrEqualTo(912.0), reason: label);
      expect(rect.top, greaterThanOrEqualTo(0.0), reason: label);
    }
    expect(tester.takeException(), isNull);
  });

  testWidgets('playback settings sub-sheet: blocks moved, presets do '
      'not overflow, preset tap applies', (tester) async {
    final c = await pumpPlayer(tester);
    await openMoreSheet(tester);
    // The adjustments are no longer inline in the more sheet.
    expect(find.text('倍速'), findsNothing);
    expect(find.text('A-B 循环'), findsNothing);
    expect(find.text('歌词偏移'), findsNothing);

    await tester.tap(find.text('播放设置'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 500));
    for (final label in [
      '倍速',
      'A-B 循环',
      '歌词偏移',
      '歌词翻译',
      '淡入淡出',
    ]) {
      expect(find.text(label), findsOneWidget, reason: label);
    }
    // Six preset chips share the row exactly (Expanded + scale-down):
    // no RenderFlex overflow at the Ahem test font.
    expect(tester.takeException(), isNull);

    await tester.tap(find.text('1.5×'));
    await tester.pump();
    expect(c.speed.value, 1.5);

    // The sub-sheet's 取消 is the topmost one (the more sheet's 取消
    // is still in the tree behind the modal).
    await tester.tap(find.text('取消').last);
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(find.text('倍速'), findsNothing);
    // Back on the more sheet, whose 播放设置 row shows the new speed.
    expect(find.text('播放设置'), findsOneWidget);
    expect(find.text('1.50×'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });
}
