// VOD controls (1.1.6) — unit tests.
//
// Pins, without a player:
// - skip-mode parsing (unknown/corrupt values read as off —
//   auto-skip must never turn itself on by accident);
// - Emby Chapters parsing (MarkerType IntroStart/IntroEnd/
//   CreditsStart, ticks → seconds; missing/malformed → empty);
// - the intro-window resolution (Emby markers win over the
//   per-episode custom CMS seconds);
// - the custom-durations Hive map (key shape, clamp 0–300, 0
//   removes the entry);
// - subtitle-delay clamping (±10 s);
// - the interpolation / SDR→HDR mutual-exclusion gates + the exact
//   mpv property sets (incl. the direction check: SDR→HDR is
//   `inverse-tone-mapping`, NOT `tone-mapping`).
//
// NOT covered here (needs chen's iPhone): whether interpolation
// actually de-judders under vo=libmpv, and whether
// inverse-tone-mapping produces a real HDR signal.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/player/vod_controls.dart';
import 'package:standalone/core/storage/hive_store.dart';

import 'helpers/hive_test_setup.dart' as hive_setup;

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await hive_setup.HiveTestSetup.init(prefix: 'hao-vod-controls-');
  });

  tearDownAll(() async {
    await hive_setup.HiveTestSetup.dispose(hiveDir);
  });

  group('parseVodSkipIntroMode', () {
    test('all four stored strings parse', () {
      expect(parseVodSkipIntroMode('off'), VodSkipIntroMode.off);
      expect(parseVodSkipIntroMode('manual'), VodSkipIntroMode.manual);
      expect(parseVodSkipIntroMode('auto3s'), VodSkipIntroMode.auto3s);
      expect(parseVodSkipIntroMode('autoNow'), VodSkipIntroMode.autoNow);
    });

    test('unknown / null / empty read as off', () {
      expect(parseVodSkipIntroMode('auto_delay_3s'), VodSkipIntroMode.off);
      expect(parseVodSkipIntroMode('AUTO'), VodSkipIntroMode.off);
      expect(parseVodSkipIntroMode(null), VodSkipIntroMode.off);
      expect(parseVodSkipIntroMode(''), VodSkipIntroMode.off);
    });
  });

  group('SkipMarkers.fromEmbyChapters', () {
    test('full marker set, ticks → seconds', () {
      final markers = SkipMarkers.fromEmbyChapters([
        {
          'Name': 'Intro',
          'MarkerType': 'IntroStart',
          'StartPositionTicks': 50000000,
        },
        {
          'Name': 'Intro',
          'MarkerType': 'IntroEnd',
          'StartPositionTicks': 900000000,
        },
        {
          'Name': 'Credits',
          'MarkerType': 'CreditsStart',
          'StartPositionTicks': 24000000000,
        },
        {
          'Name': 'Chapter 1',
          'MarkerType': 'Chapter',
          'StartPositionTicks': 1200000000,
        },
      ]);
      expect(markers.introStart, 5.0);
      expect(markers.introEnd, 90.0);
      expect(markers.creditsStart, 2400.0);
      expect(markers.isEmpty, isFalse);
    });

    test('IntroStart without IntroEnd: no usable end', () {
      final markers = SkipMarkers.fromEmbyChapters([
        {'MarkerType': 'IntroStart', 'StartPositionTicks': 100000000},
      ]);
      expect(markers.introStart, 10.0);
      expect(markers.introEnd, isNull);
    });

    test('missing / empty / malformed chapters → empty markers', () {
      expect(SkipMarkers.fromEmbyChapters(null).isEmpty, isTrue);
      expect(SkipMarkers.fromEmbyChapters([]).isEmpty, isTrue);
      expect(SkipMarkers.fromEmbyChapters('nope').isEmpty, isTrue);
      expect(
        SkipMarkers.fromEmbyChapters([
          {'MarkerType': 'IntroEnd'},
          {'MarkerType': 'IntroEnd', 'StartPositionTicks': -5},
          {'MarkerType': 'IntroEnd', 'StartPositionTicks': '90'},
          'not-a-map',
        ]).isEmpty,
        isTrue,
      );
    });
  });

  group('resolveIntroWindow', () {
    test('Emby marker end wins over custom seconds', () {
      expect(
        resolveIntroWindow(
          markers: const SkipMarkers(introStart: 3, introEnd: 88),
          customSeconds: 60,
        ),
        (start: 3.0, end: 88.0),
      );
    });

    test('custom seconds only: window starts at 0', () {
      expect(
        resolveIntroWindow(markers: null, customSeconds: 75),
        (start: 0.0, end: 75.0),
      );
      expect(
        resolveIntroWindow(
          markers: const SkipMarkers(creditsStart: 2400),
          customSeconds: 75,
        ),
        (start: 0.0, end: 75.0),
      );
    });

    test('nothing to skip to → null', () {
      expect(
        resolveIntroWindow(markers: null, customSeconds: 0),
        isNull,
      );
      expect(
        resolveIntroWindow(
          markers: const SkipMarkers(introStart: 5),
          customSeconds: 0,
        ),
        isNull,
      );
      expect(
        resolveIntroWindow(
          markers: const SkipMarkers(introStart: 90, introEnd: 90),
          customSeconds: 0,
        ),
        isNull,
      );
      expect(
        resolveIntroWindow(
          markers: const SkipMarkers(introStart: 100, introEnd: 90),
          customSeconds: 0,
        ),
        isNull,
      );
    });
  });

  group('custom intro durations (Hive)', () {
    test('key normalises the title', () {
      expect(
        skipIntroDurationKey(title: '狂飙 (2023)', episodeName: '第1集'),
        skipIntroDurationKey(title: '狂飙', episodeName: '第1集'),
      );
      expect(
        skipIntroDurationKey(title: '狂飙', episodeName: '第1集'),
        '狂飙|第1集',
      );
    });

    test('save / read / remove round-trips, clamped to 0–300', () async {
      await saveSkipIntroDuration(
        title: '狂飙',
        episodeName: '第1集',
        seconds: 90,
      );
      expect(
        readSkipIntroDuration(title: '狂飙', episodeName: '第1集'),
        90,
      );
      // Another episode is untouched.
      expect(
        readSkipIntroDuration(title: '狂飙', episodeName: '第2集'),
        0,
      );
      await saveSkipIntroDuration(
        title: '狂飙',
        episodeName: '第1集',
        seconds: 301,
      );
      expect(
        readSkipIntroDuration(title: '狂飙', episodeName: '第1集'),
        300,
      );
      await saveSkipIntroDuration(
        title: '狂飙',
        episodeName: '第1集',
        seconds: 0,
      );
      expect(
        readSkipIntroDuration(title: '狂飙', episodeName: '第1集'),
        0,
      );
      expect(readSkipIntroDurations(), isEmpty);
    });
  });

  group('subtitle delay', () {
    test('clampSubtitleDelay pins to ±10 s, passes the rest through', () {
      expect(clampSubtitleDelay(0.0), 0.0);
      expect(clampSubtitleDelay(1.2), 1.2);
      expect(clampSubtitleDelay(-0.5), -0.5);
      expect(clampSubtitleDelay(10.0), 10.0);
      expect(clampSubtitleDelay(10.5), 10.0);
      expect(clampSubtitleDelay(-11.0), -10.0);
    });

    test('persisted delay reads back clamped', () async {
      await HiveStore.put(HiveKeys.vodSubtitleDelay, 2.5);
      expect(vodSubtitleDelaySeconds(), 2.5);
      await HiveStore.put(HiveKeys.vodSubtitleDelay, 99.0);
      expect(vodSubtitleDelaySeconds(), 10.0);
    });

    test('persisted mode reads back; default is off', () async {
      expect(vodSkipIntroMode(), VodSkipIntroMode.off);
      await HiveStore.put(HiveKeys.vodSkipIntroMode, 'auto3s');
      expect(vodSkipIntroMode(), VodSkipIntroMode.auto3s);
    });
  });

  group('interpolation / SDR→HDR gates', () {
    test('interpolation: VOD + MPV + on + others off applies', () {
      expect(
        shouldApplyFrameInterpolation(
          isLive: false,
          engine: PlayerEngine.mediaKit,
          switchOn: true,
          superResolutionOn: false,
          sdrToHdrOn: false,
        ),
        isTrue,
      );
    });

    test('interpolation blocked by live / IJK / AVPlayer / switch off', () {
      for (final args in [
        (isLive: true, engine: PlayerEngine.mediaKit, switchOn: true),
        (isLive: false, engine: PlayerEngine.fijk, switchOn: true),
        (isLive: false, engine: PlayerEngine.exo, switchOn: true),
        (isLive: false, engine: PlayerEngine.mediaKit, switchOn: false),
      ]) {
        expect(
          shouldApplyFrameInterpolation(
            isLive: args.isLive,
            engine: args.engine,
            switchOn: args.switchOn,
            superResolutionOn: false,
            sdrToHdrOn: false,
          ),
          isFalse,
        );
      }
    });

    test('interpolation blocked when super-res or SDR→HDR is on', () {
      expect(
        shouldApplyFrameInterpolation(
          isLive: false,
          engine: PlayerEngine.mediaKit,
          switchOn: true,
          superResolutionOn: true,
          sdrToHdrOn: false,
        ),
        isFalse,
      );
      expect(
        shouldApplyFrameInterpolation(
          isLive: false,
          engine: PlayerEngine.mediaKit,
          switchOn: true,
          superResolutionOn: false,
          sdrToHdrOn: true,
        ),
        isFalse,
      );
    });

    test('SDR→HDR: VOD + MPV + on + others off applies', () {
      expect(
        shouldApplySdrToHdr(
          isLive: false,
          engine: PlayerEngine.mediaKit,
          switchOn: true,
          superResolutionOn: false,
          interpolationOn: false,
        ),
        isTrue,
      );
    });

    test('SDR→HDR blocked by live / non-MPV / switch off / trio', () {
      expect(
        shouldApplySdrToHdr(
          isLive: true,
          engine: PlayerEngine.mediaKit,
          switchOn: true,
          superResolutionOn: false,
          interpolationOn: false,
        ),
        isFalse,
      );
      expect(
        shouldApplySdrToHdr(
          isLive: false,
          engine: PlayerEngine.fijk,
          switchOn: true,
          superResolutionOn: false,
          interpolationOn: false,
        ),
        isFalse,
      );
      expect(
        shouldApplySdrToHdr(
          isLive: false,
          engine: PlayerEngine.mediaKit,
          switchOn: false,
          superResolutionOn: false,
          interpolationOn: false,
        ),
        isFalse,
      );
      expect(
        shouldApplySdrToHdr(
          isLive: false,
          engine: PlayerEngine.mediaKit,
          switchOn: true,
          superResolutionOn: true,
          interpolationOn: false,
        ),
        isFalse,
      );
      expect(
        shouldApplySdrToHdr(
          isLive: false,
          engine: PlayerEngine.mediaKit,
          switchOn: true,
          superResolutionOn: false,
          interpolationOn: true,
        ),
        isFalse,
      );
    });

    test('all three switches on: at most one gate passes', () {
      final sr = true;
      final interp = shouldApplyFrameInterpolation(
        isLive: false,
        engine: PlayerEngine.mediaKit,
        switchOn: true,
        superResolutionOn: sr,
        sdrToHdrOn: true,
      );
      final hdr = shouldApplySdrToHdr(
        isLive: false,
        engine: PlayerEngine.mediaKit,
        switchOn: true,
        superResolutionOn: sr,
        interpolationOn: true,
      );
      expect(interp, isFalse);
      expect(hdr, isFalse);
    });
  });

  group('mpv property sets', () {
    test('interpolation needs a display-* video-sync', () {
      expect(
        kVodInterpolationProperties['video-sync'],
        'display-resample',
      );
      expect(kVodInterpolationProperties['interpolation'], 'yes');
      expect(kVodInterpolationProperties['tscale'], 'oversample');
    });

    test('SDR→HDR uses inverse-tone-mapping (not tone-mapping alone)', () {
      // tone-mapping by itself is HDR→SDR — the SDR→HDR direction
      // is inverse-tone-mapping. The curve + target keys ride along.
      expect(kVodSdrToHdrProperties['inverse-tone-mapping'], 'yes');
      expect(kVodSdrToHdrProperties['tone-mapping'], 'spline');
      expect(kVodSdrToHdrProperties['target-trc'], 'pq');
      expect(kVodSdrToHdrProperties['target-peak'], '1000');
      expect(kVodSdrToHdrProperties.containsKey('hdr-compute-peak'),
          isFalse);
    });
  });
}
