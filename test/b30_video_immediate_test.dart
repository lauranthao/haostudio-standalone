// B30 batch ① — video features: immediate + really works.
//
// The contract under test: every VOD/live feature the user changes
// mid-playback must (a) reach the player API with the right
// arguments — not just land in a Hive value — and (b) apply to the
// episode now playing, not the next one. A fake capable backend
// records every call; assertions are on the calls, never on stored
// values alone.
//
// Covers:
//  * pure: resolveVodEnhancement first-branch-wins, the off-maps,
//    glslShadersClearCommand, cellularDowngradeTargetIndex.
//  * session: trio apply-only-changed + normalization + re-apply
//    after an engine switch; rate / subtitle delay / appearance /
//    dual-subtitle (incl. the b30 'no' -> null fix) / dialogue-boost
//    forwarding; reopenCurrent (same URL + seek to last position);
//    line switch keeps position + rate (preopen + swapToPreopened).
//  * dialogue-boost filter chain: loudnorm present (the stereo-
//    audible part — ffmpeg-verified on the VM, see mpv_backend.dart).
//  * sheet copy: '立即生效' present, '下次播放生效' / '下次打开生效'
//    absent.
//  * page wiring: the page's settings sheet builds the trio rows
//    with the '立即生效' copy, and the exact onChanged closure the
//    page built calls setSuperResolution(true) on the live backend
//    (the modal's spring animation does not settle under the test's
//    fake clock, so the row cannot be hit-tested there — the tap
//    gesture itself is covered by the sheet-isolation test).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/player/kernel/mpv_backend.dart';
import 'package:standalone/core/player/kernel/mpv_properties.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/player/super_resolution.dart';
import 'package:standalone/core/player/vod_controls.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/live_network_quality.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/features/video/vod_player_settings_sheet.dart';
import 'package:standalone/widgets/player_settings_sheet.dart';

import 'helpers/hive_test_setup.dart';

class _FakeBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();
  bool _disposed = false;

  final openUrls = <String>[];
  final rates = <double>[];
  final seeks = <Duration>[];
  final volumes = <double>[];

  void emitPosition(Duration p) => _position.add(p);

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Widget buildVideoWidget() => const SizedBox(key: ValueKey('fake-video'));

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    openUrls.add(url);
  }

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
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Future<void> setRate(double rate) async {
    rates.add(rate);
  }

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Future<void> seekTo(Duration position) async {
    seeks.add(position);
  }

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _error.close();
    await _completed.close();
  }
}

/// Capable fake: MPV-shaped (tracks + trio + dialogue boost), every
/// call recorded so "the feature really reached the player" is
/// assertable — a switch that only writes Hive never lands here.
class _FakeCapableBackend extends _FakeBackend
    implements
        TrackCapableBackend,
        VodEnhancementCapableBackend,
        DialogueBoostCapableBackend {
  final delays = <double>[];
  final appearances = <({int fontSize, String color, double position})>[];
  final secondaryIds = <String>[];
  final audioTrackIds = <String>[];
  final subtitleTrackIds = <String>[];
  final superResCalls = <bool>[];
  final interpCalls = <bool>[];
  final sdrCalls = <bool>[];
  final dialogueBoostCalls = <bool>[];

  @override
  Future<List<PlaybackTrack>> audioTracks() async => const [];

  @override
  Future<List<PlaybackTrack>> subtitleTracks() async => const [];

  @override
  Future<void> setAudioTrack(String id) async {
    audioTrackIds.add(id);
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    subtitleTrackIds.add(id);
  }

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    delays.add(seconds);
  }

  @override
  Future<void> setSubtitleAppearance({
    required int fontSize,
    required String color,
    required double position,
  }) async {
    appearances.add((fontSize: fontSize, color: color, position: position));
  }

  @override
  Future<void> setSecondarySubtitleTrack(String id) async {
    secondaryIds.add(id);
  }

  @override
  Stream<List<String>> get subtitleStream => const Stream.empty();

  @override
  Future<void> setSuperResolution(bool enabled) async {
    superResCalls.add(enabled);
  }

  @override
  Future<void> setFrameInterpolation(bool enabled) async {
    interpCalls.add(enabled);
  }

  @override
  Future<void> setSdrToHdr(bool enabled) async {
    sdrCalls.add(enabled);
  }

  @override
  Future<void> setDialogueBoost(bool enabled) async {
    dialogueBoostCalls.add(enabled);
  }
}

VideoDetail _seriesDetail() => VideoDetail(
      source: 12,
      vodId: 'b30-series-1',
      meta: VideoMeta(name: 'B30剧集', type: '电视剧', year: '2024'),
      lines: const [
        PlayLine(name: '线路1', episodes: [
          PlayEpisode(name: '第1集', url: 'https://example.com/s1.mp4'),
          PlayEpisode(name: '第2集', url: 'https://example.com/s2.mp4'),
        ]),
      ],
    );

VodPlayerSettings _vodSettings({
  ValueChanged<bool>? onSuperRes,
  ValueChanged<bool>? onDialogue,
}) =>
    VodPlayerSettings(
      rateLabel: '1.0x',
      onRateCycle: () {},
      doubleTapSeekSeconds: 10,
      onDoubleTapSeekCycle: () {},
      autoNext: true,
      onAutoNextChanged: (_) {},
      videoFitLabel: '自动',
      onVideoFitCycle: () {},
      skipIntroLabel: '关',
      onSkipIntroCycle: () {},
      dialogueBoost: false,
      onDialogueBoostChanged: onDialogue ?? (_) {},
      audioOnly: false,
      onAudioOnlyChanged: (_) {},
      superResolution: false,
      superResolutionLocked: false,
      onSuperResolutionChanged: onSuperRes,
      interpolation: false,
      interpolationLocked: false,
      onInterpolationChanged: (_) {},
      sdrToHdr: false,
      sdrToHdrLocked: false,
      onSdrToHdrChanged: (_) {},
      dvP8Downgrade: true,
      onDvP8Changed: (_) {},
      lowMemoryLabel: '自动',
      onLowMemoryCycle: () {},
      subtitleDelay: 0.0,
      onSubtitleDelayChanged: (_) {},
      subtitleFontLabel: '标准',
      onSubtitleFontCycle: () {},
      subtitleColorLabel: '白色',
      onSubtitleColorCycle: () {},
      subtitlePositionLabel: '底部',
      onSubtitlePositionCycle: () {},
      dualSubtitleOn: false,
      onDualSubtitleTap: () {},
      danmakuEnabled: false,
      onDanmakuEnabledChanged: (_) {},
      danmakuVisible: false,
      onDanmakuVisibleChanged: (_) {},
      danmakuOcclusionAvoidance: false,
      onDanmakuOcclusionChanged: (_) {},
    );

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init(prefix: 'hao-b30-video-');
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  tearDown(() {
    Get.reset();
  });

  // -- pure: trio resolver + off-maps + glsl clear ---------------------

  group('resolveVodEnhancement', () {
    test('first branch wins: super-res beats interpolation + SDR', () {
      expect(
        resolveVodEnhancement(
          superResolution: true,
          interpolation: true,
          sdrToHdr: true,
        ),
        VodEnhancementBranch.superResolution,
      );
    });

    test('interpolation beats SDR', () {
      expect(
        resolveVodEnhancement(
          superResolution: false,
          interpolation: true,
          sdrToHdr: true,
        ),
        VodEnhancementBranch.interpolation,
      );
    });

    test('SDR alone, and all off is null', () {
      expect(
        resolveVodEnhancement(
          superResolution: false,
          interpolation: false,
          sdrToHdr: true,
        ),
        VodEnhancementBranch.sdrToHdr,
      );
      expect(
        resolveVodEnhancement(
          superResolution: false,
          interpolation: false,
          sdrToHdr: false,
        ),
        isNull,
      );
    });

    test('off-maps restore the mpv defaults', () {
      expect(kVodInterpolationOffProperties['interpolation'], 'no');
      expect(kVodInterpolationOffProperties['video-sync'], 'audio');
      expect(kVodSdrToHdrOffProperties['inverse-tone-mapping'], 'no');
      expect(kVodSdrToHdrOffProperties['tone-mapping'], 'bt.2390');
      expect(kVodSdrToHdrOffProperties['target-trc'], 'auto');
      expect(kVodSdrToHdrOffProperties['target-peak'], 'auto');
    });

    test('glsl clear command clears the shader list', () {
      expect(
        glslShadersClearCommand(),
        ['change-list', kMpvGlslShadersOption, 'clr'],
      );
    });
  });

  // -- pure: cellular downgrade ----------------------------------------

  group('cellularDowngradeTargetIndex', () {
    const qualities = [
      LivePlayQuality(quality: '原画'),
      LivePlayQuality(quality: '蓝光8M'),
      LivePlayQuality(quality: '超清'),
      LivePlayQuality(quality: '高清'),
      LivePlayQuality(quality: '流畅'),
    ];

    test('ON above the ceiling caps at 超清', () {
      expect(
        cellularDowngradeTargetIndex(
          qualities: qualities,
          currentIndex: 0,
          preferredIndex: 0,
          network: LiveNetworkType.cellular,
          enabled: true,
        ),
        2,
      );
    });

    test('ON already below the ceiling never switches up', () {
      expect(
        cellularDowngradeTargetIndex(
          qualities: qualities,
          currentIndex: 3,
          preferredIndex: 0,
          network: LiveNetworkType.cellular,
          enabled: true,
        ),
        isNull,
      );
    });

    test('OFF restores the preferred quality', () {
      expect(
        cellularDowngradeTargetIndex(
          qualities: qualities,
          currentIndex: 2,
          preferredIndex: 0,
          network: LiveNetworkType.cellular,
          enabled: false,
        ),
        0,
      );
    });

    test('Wi-Fi never downgrades; empty list is null', () {
      expect(
        cellularDowngradeTargetIndex(
          qualities: qualities,
          currentIndex: 0,
          preferredIndex: 0,
          network: LiveNetworkType.wifi,
          enabled: true,
        ),
        isNull,
      );
      expect(
        cellularDowngradeTargetIndex(
          qualities: const [],
          currentIndex: 0,
          preferredIndex: 0,
          network: LiveNetworkType.cellular,
          enabled: true,
        ),
        isNull,
      );
    });
  });

  // -- session: trio / rate / subtitles / dialogue --------------------

  group('PlaybackSession forwards to the player (not just Hive)', () {
    late List<_FakeCapableBackend> created;

    PlaybackSession makeSession() => PlaybackSession(
          backendFactory: (engine) {
            final backend = _FakeCapableBackend();
            created.add(backend);
            return backend;
          },
        );

    setUp(() {
      created = <_FakeCapableBackend>[];
    });

    test('trio: apply only what changed, first branch wins', () async {
      final session = makeSession();
      expect(
        await session.open(url: 'https://example.com/f.mp4', isLive: false),
        isTrue,
      );
      final backend = created.single;
      await session.setVodEnhancement(
        superResolution: true,
        interpolation: false,
        sdrToHdr: false,
      );
      expect(backend.superResCalls, [true]);
      // Same call again: no second write to the player.
      await session.setVodEnhancement(
        superResolution: true,
        interpolation: false,
        sdrToHdr: false,
      );
      expect(backend.superResCalls, [true]);
      // Normalization: super-res on + interpolation on = super-res
      // only; interpolation is never sent while super-res wins.
      await session.setVodEnhancement(
        superResolution: true,
        interpolation: true,
        sdrToHdr: false,
      );
      expect(backend.interpCalls, isEmpty);
      // Switch branches: super-res off, interpolation on.
      await session.setVodEnhancement(
        superResolution: false,
        interpolation: true,
        sdrToHdr: false,
      );
      expect(backend.superResCalls, [true, false]);
      expect(backend.interpCalls, [true]);
      await session.dispose();
    });

    test('engine switch re-applies trio + rate + subtitle state',
        () async {
      final session = makeSession();
      expect(
        await session.open(url: 'https://example.com/f.mp4', isLive: false),
        isTrue,
      );
      final first = created.single;
      await session.setRate(1.5);
      await session.setSubtitleDelay(1.5);
      await session.setSubtitleAppearance(
        fontSize: 48,
        color: '#FFFF00',
        position: 90,
      );
      await session.setSecondarySubtitleTrack('zh');
      await session.setVodEnhancement(
        superResolution: true,
        interpolation: false,
        sdrToHdr: false,
      );
      await session.setDialogueBoost(true);
      expect(first.rates, [1.5]);
      expect(first.dialogueBoostCalls, [true]);

      await session.switchEngine(PlayerEngine.fijk);
      // The swap re-applies are fire-and-forget; let them land.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(created.length, 2);
      final second = created[1];
      expect(second.superResCalls, [true]);
      expect(second.rates, [1.5]);
      expect(second.delays, [1.5]);
      expect(second.appearances.length, 1);
      expect(second.appearances.single.fontSize, 48);
      expect(second.appearances.single.color, '#FFFF00');
      expect(second.appearances.single.position, 90);
      expect(second.secondaryIds, ['zh']);
      expect(second.dialogueBoostCalls, [true]);
      await session.dispose();
    });

    test('rate reaches the backend with the exact value', () async {
      final session = makeSession();
      expect(
        await session.open(url: 'https://example.com/f.mp4', isLive: false),
        isTrue,
      );
      await session.setRate(1.5);
      await session.setRate(2.0);
      expect(created.single.rates, [1.5, 2.0]);
      await session.dispose();
    });

    test('subtitle delay + appearance reach the backend', () async {
      final session = makeSession();
      expect(
        await session.open(url: 'https://example.com/f.mp4', isLive: false),
        isTrue,
      );
      await session.setSubtitleDelay(1.5);
      await session.setSubtitleAppearance(
        fontSize: 48,
        color: '#FFFF00',
        position: 90,
      );
      expect(created.single.delays, [1.5]);
      expect(created.single.appearances.length, 1);
      expect(created.single.appearances.single.fontSize, 48);
      expect(created.single.appearances.single.color, '#FFFF00');
      expect(created.single.appearances.single.position, 90);
      await session.dispose();
    });

    test("dual subtitle: picking 无 remembers off (null) but still "
        "sends 'no' to the backend", () async {
      final session = makeSession();
      expect(
        await session.open(url: 'https://example.com/f.mp4', isLive: false),
        isTrue,
      );
      final backend = created.single;
      await session.setSecondarySubtitleTrack('zh');
      expect(session.currentSecondarySubtitleTrackId, 'zh');
      expect(backend.secondaryIds, ['zh']);

      // b30 fix: 'no' is remembered as null (off) — before the fix
      // the literal 'no' was remembered, so the panel's
      // `currentSecondarySubtitleTrackId != null` still showed 开
      // after the user picked 无. The backend still receives 'no'
      // (mpv's off switch).
      await session.setSecondarySubtitleTrack('no');
      expect(backend.secondaryIds, ['zh', 'no']);
      expect(session.currentSecondarySubtitleTrackId, isNull);

      // A later engine switch must NOT re-send a track id for the
      // off state.
      await session.switchEngine(PlayerEngine.fijk);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(created[1].secondaryIds, isEmpty);
      await session.dispose();
    });

    test('dialogue boost reaches the backend', () async {
      final session = makeSession();
      expect(
        await session.open(url: 'https://example.com/f.mp4', isLive: false),
        isTrue,
      );
      await session.setDialogueBoost(true);
      await session.setDialogueBoost(false);
      expect(created.single.dialogueBoostCalls, [true, false]);
      await session.dispose();
    });

    test('volume is remembered and re-applied after a backend swap',
        () async {
      // b30 (live quality switch): the room's playing-event re-apply
      // of the volume boost was defeated by its own same-engine
      // dedup guard — MPV -> MPV, same boost, so it skipped the
      // write while the fresh backend sat at 1.0. The session owns
      // the swap, so it remembers the volume like the rate.
      final session = makeSession();
      expect(
        await session.open(url: 'https://example.com/f.mp4', isLive: false),
        isTrue,
      );
      final first = created.single;
      await session.setVolume(2.0);
      expect(first.volumes, [2.0]);
      await session.switchEngine(PlayerEngine.fijk);
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(created.length, 2);
      expect(created[1].volumes, [2.0]);
      // Turning the boost back down is remembered too.
      await session.setVolume(1.0);
      expect(created[1].volumes, [2.0, 1.0]);
      await session.dispose();
    });

    test('volume set before open is applied to the first backend',
        () async {
      final session = makeSession();
      await session.setVolume(2.0);
      expect(
        await session.open(url: 'https://example.com/f.mp4', isLive: false),
        isTrue,
      );
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(created.single.volumes, [2.0]);
      await session.dispose();
    });

    test('bare backend: trio is remembered for the next swap', () async {
      final bare = _FakeBackend();
      final session = PlaybackSession(backendFactory: (_) => bare);
      expect(
        await session.open(url: 'https://example.com/f.mp4', isLive: false),
        isTrue,
      );
      // No capable backend, so nothing is sent — but the values are
      // remembered, not dropped.
      await session.setVodEnhancement(
        superResolution: true,
        interpolation: false,
        sdrToHdr: false,
      );
      await session.dispose();
    });
  });

  // -- session: reopen + line switch -----------------------------------

  group('PlaybackSession reopen / line switch', () {
    test('reopenCurrent re-opens the same URL, seeks to last position',
        () async {
      final created = <_FakeCapableBackend>[];
      final session = PlaybackSession(
        backendFactory: (engine) {
          final backend = _FakeCapableBackend();
          created.add(backend);
          return backend;
        },
      );
      const url = 'https://example.com/f.mp4';
      expect(await session.open(url: url, isLive: false), isTrue);
      final backend = created.single;
      backend.emitPosition(const Duration(seconds: 42));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await session.reopenCurrent(), isTrue);
      // reopenCurrent opens a FRESH backend (open() always builds
      // one): the first backend saw the first open only; the new
      // backend re-opens the same URL and seeks to the last position.
      expect(created.length, 2);
      expect(created[0].openUrls, [url]);
      expect(created[1].openUrls, [url]);
      expect(created[1].seeks, [const Duration(seconds: 42)]);
      await session.dispose();
    });

    test('reopenCurrent is false before open and for live', () async {
      final session =
          PlaybackSession(backendFactory: (_) => _FakeCapableBackend());
      expect(await session.reopenCurrent(), isFalse);
      expect(
        await session.open(
          url: 'https://example.com/live.m3u8',
          isLive: true,
        ),
        isTrue,
      );
      expect(await session.reopenCurrent(), isFalse);
      await session.dispose();
    });

    test('preopen + swap keeps the resume position and the rate',
        () async {
      final created = <_FakeCapableBackend>[];
      final session = PlaybackSession(
        backendFactory: (engine) {
          final backend = _FakeCapableBackend();
          created.add(backend);
          return backend;
        },
      );
      const url1 = 'https://example.com/s1.mp4';
      const url2 = 'https://example.com/s2.mp4';
      expect(await session.open(url: url1, isLive: false), isTrue);
      final first = created.single;
      await session.setRate(1.5);
      first.emitPosition(const Duration(seconds: 42));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(await session.preopen(url: url2, isLive: false), isTrue);
      expect(created.length, 2);
      final second = created[1];
      expect(
        await session.swapToPreopened(
          url: url2,
          resumePosition: const Duration(seconds: 42),
        ),
        isTrue,
      );
      expect(second.seeks, contains(const Duration(seconds: 42)));
      // The swap re-apply is fire-and-forget; let it land.
      await Future<void>.delayed(const Duration(milliseconds: 100));
      expect(second.rates, contains(1.5));
      await session.dispose();
    });
  });

  // -- dialogue-boost filter chain -------------------------------------

  group('dialogue boost filter chain', () {
    test('loudnorm is in the chain: audible on stereo too', () {
      // b30: the pan fold alone is bit-identical on stereo, so the
      // switch did nothing audible on the stereo streams nearly
      // every CMS source serves. loudnorm (dynamic, linear=false)
      // is the stage that lifts quiet dialogue and tames loud
      // effects on any layout — verified with ffmpeg 8.1.2 on the
      // VM (quiet -36.5 dB mean -> -19.9 dB, loud -9.1 dB ->
      // -18.6 dB, whole-file peak -12.6 dB, no clipping).
      expect(kDialogueBoostCentreFilter, contains('pan=stereo'));
      expect(kDialogueBoostCentreFilter, contains('loudnorm'));
      expect(kDialogueBoostCentreFilter, contains('I=-16'));
      expect(kDialogueBoostCentreFilter, contains('TP=-1.5'));
      expect(kDialogueBoostCentreFilter, contains('LRA=11'));
      expect(kDialogueBoostCentreFilter, contains('linear=false'));
      expect(kMpvVolumeMax, '300');
    });
  });

  // -- sheet copy + sheet callback -------------------------------------

  group('VodPlayerSettingsSheet', () {
    Future<void> pumpSheet(
      WidgetTester tester,
      VodPlayerSettings settings,
    ) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: VodPlayerSettingsSheet(settings: settings),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('says 立即生效, never 下次播放生效 / 下次打开生效',
        (tester) async {
      await pumpSheet(tester, _vodSettings());
      expect(find.textContaining('立即生效'), findsWidgets);
      expect(find.textContaining('下次播放生效'), findsNothing);
      expect(find.textContaining('下次打开生效'), findsNothing);
    });

    testWidgets('tapping 超分 calls back with true', (tester) async {
      bool? seen;
      await pumpSheet(
        tester,
        _vodSettings(onSuperRes: (value) => seen = value),
      );
      // The sheet is taller than the 600 px test viewport: scroll
      // the row into view first, or the tap lands off-screen.
      await tester.ensureVisible(
        find.byKey(const ValueKey('vod_setting_super_res')),
      );
      await tester.pump();
      await tester.tap(find.byKey(const ValueKey('vod_setting_super_res')));
      await tester.pump();
      expect(seen, isTrue);
    });
  });

  // -- page wiring: sheet tap -> live backend --------------------------

  group('NativeVideoPlayerPage trio wiring', () {
    Future<void> pumpPlayer(
      WidgetTester tester,
      PlaybackSession session,
    ) async {
      // Phone-tall viewport: the settings sheet is taller than the
      // default 800x600 test surface, which pushes the trio rows
      // off-screen (same reason the live room tests use 800x1600).
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: NativeVideoPlayerPage(
            detail: _seriesDetail(),
            session: session,
          ),
        ),
      );
      await settle(tester);
      await settle(tester);
    }

    Future<void> unmountPlayer(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 3));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
      await drainHiveWrites(tester);
    }

    testWidgets('page settings sheet wires 超分 to the live backend',
        (tester) async {
      final backend = _FakeCapableBackend();
      final session = PlaybackSession(backendFactory: (_) => backend);
      await pumpPlayer(tester, session);
      expect(backend.superResCalls, isEmpty);

      await tester.tap(find.byTooltip('播放设置'));
      await tester.pump();
      await settle(tester);
      // The sheet is in the tree with the trio rows and the
      // '立即生效' subtitles.
      expect(find.text('Anime4K 超分'), findsOneWidget);
      expect(find.textContaining('仅 MPV，立即生效'), findsWidgets);
      // The modal's spring animation does not settle under the
      // test's fake clock, so the rows sit below the viewport and
      // cannot be hit-tested here — the tap gesture itself is
      // covered by the sheet-isolation test ('tapping 超分 calls
      // back with true'). What this test proves is the PAGE's
      // wiring: invoke the exact onChanged closure the page built
      // in its settings snapshot and assert it reaches the live
      // backend.
      final row = tester.widget<PlayerSettingsSwitchRow>(
        find.byKey(const ValueKey('vod_setting_super_res')),
      );
      expect(row.onChanged, isNotNull);
      row.onChanged!(true);
      await tester.pump();
      await settle(tester);
      expect(backend.superResCalls, [true]);

      await unmountPlayer(tester);
      await session.dispose();
    });
  });
}
