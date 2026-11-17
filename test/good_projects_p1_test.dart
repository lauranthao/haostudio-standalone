// Good-projects P1 (2026-11-18 report) — PiliPlus video fit,
// Kazumi low-memory mode. PiliPlus double-tap seek was tried and
// REVERTED: it delays the wake-tap by ~300 ms (see the comment above
// _onSurfaceTap in native_video_player_page.dart); its tests were
// removed with it, not left as orphans.
//
// Sources (read-only reference clones under ~/workspace/research/):
// - PiliPlus `lib/plugin/pl_player/models/video_fit_type.dart` —
//   fill/contain/cover (+ fitWidth/fitHeight/none/scaleDown/4:3/16:9,
//   NOT shipped — see video_fit.dart).
// - PiliPlus `lib/plugin/pl_player/controller.dart:1373-1440` +
//   `view.dart:1107-1121` + `storage_pref.dart:614-615` — double-tap
//   quarters, 10 s default step, clamp to [0, duration].
// - Kazumi `lib/services/player/low_memory_mode.dart` — auto/always/
//   never; `lib/pages/settings/low_memory_mode_settings.dart` —
//   labels. Kazumi's auto trigger is metered-network; ours is the
//   existing <= 4 CPU-core rule (documented in mpv_properties.dart).
//
// No GPL/AGPL code was copied: modes, numbers and behaviours only,
// re-implemented in our own structure.
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/player/kernel/mpv_properties.dart';
import 'package:standalone/core/player/kernel/video_fit.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/video/video_history_store.dart';

void main() {
  late Box<dynamic> box;

  setUp(() async {
    Hive.init('test/.hive-good-p1-test');
    box = await Hive.openBox<dynamic>('good_p1_test');
    await box.clear();
    HiveStore.setTestBox(box);
  });

  tearDown(() async {
    await box.close();
    await Hive.deleteBoxFromDisk('good_p1_test');
  });

  group('VideoFitMode (PiliPlus VideoFitType + Kazumi PlayerAspectRatio)', () {
    test('unknown / garbage storage values fall back to auto', () {
      expect(VideoFitMode.fromStorageValue(null), VideoFitMode.auto);
      expect(VideoFitMode.fromStorageValue('stretch'), VideoFitMode.auto);
      expect(VideoFitMode.fromStorageValue(42), VideoFitMode.auto);
      expect(VideoFitMode.fromStorageValue('fill'), VideoFitMode.fill);
      expect(VideoFitMode.fromStorageValue('cover'), VideoFitMode.cover);
    });

    test('cycle order is auto -> fill -> cover -> auto', () {
      expect(VideoFitMode.auto.next, VideoFitMode.fill);
      expect(VideoFitMode.fill.next, VideoFitMode.cover);
      expect(VideoFitMode.cover.next, VideoFitMode.auto);
    });

    test('BoxFit mapping matches both sources', () {
      expect(VideoFitMode.auto.boxFit, BoxFit.contain);
      expect(VideoFitMode.fill.boxFit, BoxFit.fill);
      expect(VideoFitMode.cover.boxFit, BoxFit.cover);
    });

    test('labels are the PiliPlus/Kazumi words', () {
      expect(VideoFitMode.auto.label, '自动');
      expect(VideoFitMode.fill.label, '拉伸');
      expect(VideoFitMode.cover.label, '裁剪');
    });

    test('VideoPlaybackSettings.videoFit defaults to auto, round-trips', () async {
      expect(VideoPlaybackSettings.videoFit, VideoFitMode.auto);
      await VideoPlaybackSettings.setVideoFit(VideoFitMode.cover);
      expect(VideoPlaybackSettings.videoFit, VideoFitMode.cover);
      await VideoPlaybackSettings.setVideoFit(VideoFitMode.fill);
      expect(VideoPlaybackSettings.videoFit, VideoFitMode.fill);
      // Stored garbage -> auto (never a crash, never a stuck mode).
      await box.put(HiveKeys.vodVideoFit, 'ratio_4x3');
      expect(VideoPlaybackSettings.videoFit, VideoFitMode.auto);
    });
  });

  group('LowMemoryMode (Kazumi)', () {
    test('unknown / garbage storage values fall back to auto', () {
      expect(LowMemoryMode.fromStorageValue(null), LowMemoryMode.auto);
      expect(LowMemoryMode.fromStorageValue('sometimes'), LowMemoryMode.auto);
      expect(LowMemoryMode.fromStorageValue('always'), LowMemoryMode.always);
      expect(LowMemoryMode.fromStorageValue('never'), LowMemoryMode.never);
    });

    test('cycle order is auto -> always -> never -> auto', () {
      expect(LowMemoryMode.auto.next, LowMemoryMode.always);
      expect(LowMemoryMode.always.next, LowMemoryMode.never);
      expect(LowMemoryMode.never.next, LowMemoryMode.auto);
    });

    test('labels are the Kazumi words', () {
      expect(LowMemoryMode.auto.label, '自动');
      expect(LowMemoryMode.always.label, '始终开启');
      expect(LowMemoryMode.never.label, '始终关闭');
    });

    test('isEffective: always on, never off, auto follows cores', () {
      expect(LowMemoryMode.always.isEffective(), isTrue);
      expect(LowMemoryMode.never.isEffective(), isFalse);
      expect(LowMemoryMode.auto.isEffective(cpuCores: 2), isTrue);
      expect(LowMemoryMode.auto.isEffective(cpuCores: 4), isTrue);
      expect(LowMemoryMode.auto.isEffective(cpuCores: 8), isFalse);
    });

    test('persisted mode round-trips, garbage falls back to auto', () async {
      expect(LowMemoryMode.current, LowMemoryMode.auto);
      await LowMemoryMode.save(LowMemoryMode.never);
      expect(LowMemoryMode.current, LowMemoryMode.never);
      await box.put(HiveKeys.lowMemoryMode, 'sometimes');
      expect(LowMemoryMode.current, LowMemoryMode.auto);
    });

    test('always forces the low-end property set', () {
      final props = mpvBaseProperties(mode: LowMemoryMode.always);
      expect(props['demuxer-max-bytes'], (40 * 1024 * 1024).toString());
      expect(props['demuxer-max-back-bytes'], (5 * 1024 * 1024).toString());
      expect(props['audio-buffer'], '0.4');
      expect(props['vd-lavc-threads'], '2');
      expect(props['vd-lavc-o'], 'lowres=1');
      // Untouched Pure Live values stay identical.
      expect(props['cache-secs'], '30');
      expect(props['demuxer-readahead-secs'], '8');
    });

    test('never forces the full property set', () {
      final props = mpvBaseProperties(mode: LowMemoryMode.never);
      expect(props['demuxer-max-bytes'], (96 * 1024 * 1024).toString());
      expect(props['demuxer-max-back-bytes'], (8 * 1024 * 1024).toString());
      expect(props.containsKey('audio-buffer'), isFalse);
      expect(props.containsKey('vd-lavc-threads'), isFalse);
      expect(props['vd-lavc-o'], 'lowres=0');
      expect(props['cache-secs'], '30');
    });
  });
}
