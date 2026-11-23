// Render test — live room (LiveRoomPage), light + dark.
// NOT a regression test: it writes golden PNGs (run with
// --update-goldens) of the portrait room: 16:9 video + info +
// danmaku area.
//
// Harness copied from render_music_home_test.dart (Hive temp dir,
// CJK + Material icon fonts from the VM) and system_volume_test.dart
// (_FakeSite + _FakeDanmaku + _RecordingBackend — no network, no
// real adapters).
//
// ONE pump only: a second room pump in the same file hangs on this
// VM (same note as system_volume_test.dart). The dark shot reuses the
// same room State — the test rebuilds the root with the dark theme
// instead of pumping a second room.
import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/native/system_volume.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/core/theme/haptics.dart';
import 'package:standalone/domains/live/live_follow_store.dart';
import 'package:standalone/domains/live/live_history_store.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/features/settings/source_stores.dart';
import 'package:standalone/shared/platforms/live_site.dart';

Future<void> _loadCjkFont() async {
  final loader = FontLoader('NotoSansSC');
  for (final path in const [
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Regular.ttc',
    '/usr/share/fonts/opentype/noto/NotoSansCJK-Bold.ttc',
  ]) {
    final bytes = await File(path).readAsBytes();
    loader.addFont(Future.value(ByteData.view(bytes.buffer)));
  }
  await loader.load();
  final iconLoader = FontLoader('MaterialIcons');
  final iconBytes = await File(
    '/home/hatch/flutter/bin/cache/artifacts/material_fonts/MaterialIcons-Regular.otf',
  ).readAsBytes();
  iconLoader.addFont(Future.value(ByteData.view(iconBytes.buffer)));
  await iconLoader.load();
}

ThemeData _cjkTheme(ThemeData base) {
  final text = base.textTheme.apply(fontFamily: 'NotoSansSC');
  final primary = base.primaryTextTheme.apply(fontFamily: 'NotoSansSC');
  ButtonStyle cjkButton(ButtonStyle? style) {
    final resolved = style?.textStyle?.resolve({});
    return (style ?? const ButtonStyle()).copyWith(
      textStyle: WidgetStatePropertyAll(
        (resolved ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC'),
      ),
    );
  }

  // Literal TextStyles in the sub-themes carry NO fontFamily (the
  // product relies on the system font on a real phone). In widget
  // tests a null family resolves to the Ahem test font — solid bars
  // for Latin, tofu for CJK — and ListTile titles/subtitles plus
  // ChoiceChip labels go through these sub-themes, so force the CJK
  // family here too (probe_font_test.dart proved the mechanism).
  TextStyle cjkStyle(TextStyle? style) =>
      (style ?? const TextStyle()).copyWith(fontFamily: 'NotoSansSC');

  return base.copyWith(
    cupertinoOverrideTheme: haoCupertinoThemeWithFont('NotoSansSC'),
    textTheme: text,
    primaryTextTheme: primary,
    appBarTheme: base.appBarTheme.copyWith(
      titleTextStyle: cjkStyle(base.appBarTheme.titleTextStyle),
    ),
    bottomNavigationBarTheme: base.bottomNavigationBarTheme.copyWith(
      selectedLabelStyle: cjkStyle(
        base.bottomNavigationBarTheme.selectedLabelStyle,
      ),
      unselectedLabelStyle: cjkStyle(
        base.bottomNavigationBarTheme.unselectedLabelStyle,
      ),
    ),
    listTileTheme: base.listTileTheme.copyWith(
      titleTextStyle: cjkStyle(base.listTileTheme.titleTextStyle),
      subtitleTextStyle: cjkStyle(base.listTileTheme.subtitleTextStyle),
    ),
    sliderTheme: base.sliderTheme.copyWith(
      valueIndicatorTextStyle: cjkStyle(
        base.sliderTheme.valueIndicatorTextStyle,
      ),
    ),
    segmentedButtonTheme: base.segmentedButtonTheme.copyWith(
      style: cjkButton(base.segmentedButtonTheme.style),
    ),
    chipTheme: base.chipTheme.copyWith(
      labelStyle: cjkStyle(base.chipTheme.labelStyle),
    ),
    dialogTheme: base.dialogTheme.copyWith(
      titleTextStyle: cjkStyle(base.dialogTheme.titleTextStyle),
      contentTextStyle: cjkStyle(base.dialogTheme.contentTextStyle),
    ),
    filledButtonTheme: FilledButtonThemeData(
      style: cjkButton(base.filledButtonTheme.style),
    ),
    textButtonTheme: TextButtonThemeData(
      style: cjkButton(base.textButtonTheme.style),
    ),
    inputDecorationTheme: base.inputDecorationTheme.copyWith(
      hintStyle: cjkStyle(base.inputDecorationTheme.hintStyle),
      labelStyle: cjkStyle(base.inputDecorationTheme.labelStyle),
    ),
  );
}

class _FakeSite extends LiveSite {
  final danmaku = _FakeDanmaku();

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
  }) async =>
      const [LivePlayQuality(quality: '原画', id: '10000')];

  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final issued = DateTime.now();
    return LivePlayUrlResolution(
      urls: const ['https://example.com/live.m3u8'],
      issuedAt: issued,
      refreshAt: issued.add(const Duration(seconds: 100)),
      invalidAt: issued.add(const Duration(seconds: 125)),
      streamFacts: const [LiveStreamFacts(format: 'hls')],
    );
  }
}

class _FakeDanmaku extends LiveDanmaku {
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

/// Fake native backend: never plays, never touches the network.
class _RecordingBackend implements PlayerBackend {
  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  @override
  Widget buildVideoWidget() =>
      const SizedBox(key: ValueKey('fake-video'));

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
  }) async =>
      true;

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Future<void> setRate(double rate) async {}

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
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(systemVolumeChannelName);

  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('hao-render-room-');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    await _loadCjkFont();
  });

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
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  const roomA = LiveRoom(
    roomId: '660000',
    platform: 'huya',
    title: 'room A',
    nick: 'anchor A',
    liveStatus: true,
    watching: 12345,
  );

  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  testWidgets('render live room light + dark', (tester) async {
    // iPhone-ish 390x844 logical @2x, portrait (live stays portrait
    // until the [ ] button — the room golden is the portrait entry).
    tester.view.physicalSize = const Size(780, 1688);
    tester.view.devicePixelRatio = 2.0;
    addTearDown(tester.view.resetPhysicalSize);
    addTearDown(tester.view.resetDevicePixelRatio);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (MethodCall call) async {
      if (call.method == 'getVolume') return 0.6;
      return null;
    });
    await tester.runAsync(() async {
      await DanmakuSettings.setEnabled('huya', true);
      await LiveHistoryStore.clear();
      await LiveFollowStore.clear();
    });
    await settle(tester);

    Widget app(ThemeData theme) => GetMaterialApp(
          debugShowCheckedModeBanner: false,
          theme: theme,
          home: LiveRoomPage(
            room: roomA,
            playlist: const [roomA],
            site: _FakeSite(),
            backendFactory: (_) => _RecordingBackend(),
          ),
        );

    await tester.pumpWidget(
      app(_cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).light)),
    );
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 200));
    await settle(tester);
    expect(find.text('room A'), findsOneWidget);
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/live_room_light.png'),
    );

    // Same room State, dark theme — a second pumpWidget with the same
    // tree shape reuses the State instead of opening a second room.
    // The dark IconTheme lags the theme switch: at 200 ms + one
    // extra frame it still shows the LIGHT AppBar IconTheme (icons
    // black on dark); after 1 s it is the dark textPrimary. The
    // product itself is correct (icons resolve to textPrimary) — the
    // golden would otherwise capture a stale frame that does NOT
    // exist on a real phone, where the room opens in one theme.
    await tester.pumpWidget(
      app(_cjkTheme(HaoThemes.of(HaoThemeId.appleGlass).dark)),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
    await tester.pump(const Duration(seconds: 1));
    expect(find.text('room A'), findsOneWidget);
    // Regression point: the top-bar icons must resolve to the dark
    // textPrimary (near-white), not the light one.
    final darkTextPrimary = HaoThemes.of(HaoThemeId.appleGlass).dark
        .extension<HaoTheme>()!
        .textPrimary;
    final swapThemes = find.ancestor(
      of: find.byIcon(Icons.swap_horiz),
      matching: find.byType(IconTheme),
    );
    expect(
      tester.widget<IconTheme>(swapThemes.first).data.color,
      darkTextPrimary,
    );
    await expectLater(
      find.byType(GetMaterialApp),
      matchesGoldenFile('goldens/live_room_dark.png'),
    );

    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
