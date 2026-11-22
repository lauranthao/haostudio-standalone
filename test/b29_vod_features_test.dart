// I-影视 (build 29) — vod_features pure-logic + prefs tests.
//
// Covers the single-Hive-key prefs and every pure helper in
// lib/core/player/vod_features.dart: double-tap step, pinch fit,
// two-finger tracker, seek haptic ticks, dialogue gate, metadata
// overrides, category prefs, screenshot I/O, GIF + timeline
// thumbnail assessments, VOD sleep labels. No widgets here — the
// player widget tests live in b29_vod_player_features_test.dart.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/player/kernel/video_fit.dart';
import 'package:standalone/core/player/vod_features.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/features/video/vod_sleep_timer_sheet.dart';
import 'package:standalone/services/music/sleep_timer.dart';

void main() {
  late Directory hiveDir;
  late Directory docsDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-b29-vodfeat-');
    docsDir = await Directory.systemTemp.createTemp('hao-b29-voddocs-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
    await docsDir.delete(recursive: true);
  });

  tearDown(() {
    unawaited(HiveStore.delete(HiveKeys.vodDoubleTapSeekSeconds));
    unawaited(HiveStore.delete(HiveKeys.vodDialogueBoost));
    unawaited(HiveStore.delete(HiveKeys.vodSpoilerHideSynopsis));
    unawaited(HiveStore.delete(HiveKeys.vodSpoilerBlurUnwatched));
    unawaited(HiveStore.delete(HiveKeys.vodAudioOnly));
    unawaited(HiveStore.delete(HiveKeys.vodMetadataOverrides));
    unawaited(HiveStore.delete(HiveKeys.vodCategoryPrefs));
  });

  group('1. double-tap seek step', () {
    test('default is 10 s', () {
      expect(vodDoubleTapSeekSeconds(), 10);
    });

    test('clamp: null/0/garbage read as a real step', () {
      expect(clampDoubleTapSeekSeconds(null), 10);
      expect(clampDoubleTapSeekSeconds(0), 5);
      expect(clampDoubleTapSeekSeconds(12), 10);
      expect(clampDoubleTapSeekSeconds(7), 5);
      expect(clampDoubleTapSeekSeconds(100), 60);
    });

    test('cycle 5 -> 10 -> 15 -> 30 -> 60 -> 5', () {
      expect(nextDoubleTapSeekSeconds(5), 10);
      expect(nextDoubleTapSeekSeconds(10), 15);
      expect(nextDoubleTapSeekSeconds(15), 30);
      expect(nextDoubleTapSeekSeconds(30), 60);
      expect(nextDoubleTapSeekSeconds(60), 5);
    });

    test('resolve clamps to [0, duration]; zero duration seeks nowhere',
        () {
      expect(
        resolveDoubleTapSeek(
          position: 100,
          duration: 600,
          forward: true,
          seconds: 10,
        ),
        110,
      );
      expect(
        resolveDoubleTapSeek(
          position: 100,
          duration: 600,
          forward: false,
          seconds: 10,
        ),
        90,
      );
      expect(
        resolveDoubleTapSeek(
          position: 595,
          duration: 600,
          forward: true,
          seconds: 30,
        ),
        600,
      );
      expect(
        resolveDoubleTapSeek(
          position: 5,
          duration: 600,
          forward: false,
          seconds: 30,
        ),
        0,
      );
      expect(
        resolveDoubleTapSeek(
          position: 100,
          duration: 0,
          forward: true,
          seconds: 10,
        ),
        100,
      );
    });

    test('persisted step round-trips through Hive', () async {
      await HiveStore.put(HiveKeys.vodDoubleTapSeekSeconds, 30);
      expect(vodDoubleTapSeekSeconds(), 30);
    });
  });

  group('2. gestures', () {
    test('pinch out -> cover, pinch in -> auto, small pinch -> null',
        () {
      expect(pinchFitTarget(1.3), VideoFitMode.cover);
      expect(pinchFitTarget(1.2), VideoFitMode.cover);
      expect(pinchFitTarget(0.8), VideoFitMode.auto);
      expect(pinchFitTarget(0.85), VideoFitMode.auto);
      expect(pinchFitTarget(1.0), isNull);
      expect(pinchFitTarget(1.19), isNull);
      expect(pinchFitTarget(0.86), isNull);
    });

    test('two-finger tap completes on two quick downs + ups', () {
      final t = TwoFingerTapTracker();
      final at = DateTime(2026, 11, 22, 12, 0, 0);
      t.pointerDown(1, 100, 200, at);
      t.pointerDown(2, 300, 200, at.add(const Duration(milliseconds: 50)));
      expect(t.pointerUp(1, at.add(const Duration(milliseconds: 150))),
          isFalse);
      expect(t.pointerUp(2, at.add(const Duration(milliseconds: 200))),
          isTrue);
    });

    test('two-finger tap: single finger never completes', () {
      final t = TwoFingerTapTracker();
      final at = DateTime(2026, 11, 22, 12, 0, 0);
      t.pointerDown(1, 100, 200, at);
      expect(t.pointerUp(1, at.add(const Duration(milliseconds: 100))),
          isFalse);
    });

    test('two-finger tap: movement over 24 px disqualifies', () {
      final t = TwoFingerTapTracker();
      final at = DateTime(2026, 11, 22, 12, 0, 0);
      t.pointerDown(1, 100, 200, at);
      t.pointerDown(2, 300, 200, at.add(const Duration(milliseconds: 50)));
      t.pointerMove(2, 340, 200);
      t.pointerUp(1, at.add(const Duration(milliseconds: 150)));
      expect(t.pointerUp(2, at.add(const Duration(milliseconds: 200))),
          isFalse);
    });

    test('two-finger tap: late second finger / long hold disqualify',
        () {
      final late = TwoFingerTapTracker();
      final at = DateTime(2026, 11, 22, 12, 0, 0);
      late.pointerDown(1, 100, 200, at);
      late.pointerDown(2, 300, 200, at.add(const Duration(milliseconds: 300)));
      late.pointerUp(1, at.add(const Duration(milliseconds: 350)));
      expect(late.pointerUp(2, at.add(const Duration(milliseconds: 400))),
          isFalse);

      final held = TwoFingerTapTracker();
      held.pointerDown(1, 100, 200, at);
      held.pointerDown(2, 300, 200, at.add(const Duration(milliseconds: 50)));
      held.pointerUp(1, at.add(const Duration(milliseconds: 300)));
      expect(held.pointerUp(2, at.add(const Duration(milliseconds: 500))),
          isFalse);
    });

    test('seek-drag haptic ticks every 10 s boundary', () {
      expect(shouldTickSeekHaptic(lastTickTarget: 0, target: 9), isFalse);
      expect(shouldTickSeekHaptic(lastTickTarget: 0, target: 10), isTrue);
      expect(shouldTickSeekHaptic(lastTickTarget: 100, target: 95), isFalse);
      expect(shouldTickSeekHaptic(lastTickTarget: 100, target: 89), isTrue);
    });

    test('pinch tracker: out -> >1, in -> <1, tap -> ~1.0', () {
      final out = PinchTracker();
      out.pointerDown(1, 100, 200);
      out.pointerDown(2, 200, 200);
      out.pointerMove(1, 50, 200);
      out.pointerMove(2, 250, 200);
      final scaleOut = out.pointerUp(1);
      expect(scaleOut, isNotNull);
      expect(scaleOut!, greaterThan(1.2));

      final pinchIn = PinchTracker();
      pinchIn.pointerDown(1, 100, 200);
      pinchIn.pointerDown(2, 300, 200);
      pinchIn.pointerMove(1, 150, 200);
      pinchIn.pointerMove(2, 250, 200);
      final scaleIn = pinchIn.pointerUp(1);
      expect(scaleIn, isNotNull);
      expect(scaleIn!, lessThan(0.85));

      final tap = PinchTracker();
      tap.pointerDown(1, 100, 200);
      tap.pointerDown(2, 200, 200);
      final scaleTap = tap.pointerUp(1);
      expect(scaleTap, closeTo(1.0, 0.001));
      expect(pinchFitTarget(scaleTap!), isNull);
    });

    test('pinch tracker: single pointer never returns a scale', () {
      final t = PinchTracker();
      t.pointerDown(1, 100, 200);
      expect(t.pointerUp(1), isNull);
    });
  });

  group('3. dialogue boost gate', () {
    test('VOD + on -> apply; live never; off never', () {
      expect(
        shouldApplyDialogueBoost(isLive: false, switchOn: true),
        isTrue,
      );
      expect(
        shouldApplyDialogueBoost(isLive: true, switchOn: true),
        isFalse,
      );
      expect(
        shouldApplyDialogueBoost(isLive: false, switchOn: false),
        isFalse,
      );
    });

    test('default off, persists', () async {
      expect(vodDialogueBoostEnabled(), isFalse);
      await HiveStore.put(HiveKeys.vodDialogueBoost, true);
      expect(vodDialogueBoostEnabled(), isTrue);
    });
  });

  group('4. metadata overrides', () {
    test('save / read / apply / clear round-trip', () async {
      const source = 12;
      const vodId = '93344';
      expect(metadataOverrideFor(source, vodId), isNull);
      await saveMetadataOverride(
        source: source,
        vodId: vodId,
        override: const VodMetadataOverride(
          title: '流浪地球 2（修正）',
          year: '2023',
        ),
      );
      final o = metadataOverrideFor(source, vodId);
      expect(o?.title, '流浪地球 2（修正）');
      expect(o?.year, '2023');
      expect(o?.poster, isNull);

      final meta = VideoMeta(name: '流浪地球2', year: '2022', pic: 'a.jpg');
      final fixed = applyMetadataOverride(meta, o);
      expect(fixed.name, '流浪地球 2（修正）');
      expect(fixed.year, '2023');
      expect(fixed.pic, 'a.jpg', reason: 'untouched field keeps source');
      expect(meta.name, '流浪地球2', reason: 'copy does not mutate');

      final inplace = VideoMeta(name: '流浪地球2', year: '2022');
      applyMetadataOverrideInPlace(inplace, o);
      expect(inplace.name, '流浪地球 2（修正）');
      expect(inplace.year, '2023');

      await saveMetadataOverride(
        source: source,
        vodId: vodId,
        override: const VodMetadataOverride(),
      );
      expect(metadataOverrideFor(source, vodId), isNull);
    });

    test('override key is source-scoped, not title-scoped', () async {
      await saveMetadataOverride(
        source: 12,
        vodId: '1',
        override: const VodMetadataOverride(title: 'A'),
      );
      expect(metadataOverrideFor(13, '1'), isNull);
      expect(metadataOverrideFor(12, '2'), isNull);
    });

    test('empty-string fields read as no correction', () {
      final o = VodMetadataOverride.fromJson(
        {'title': '  ', 'year': '', 'poster': 'p.jpg'},
      );
      expect(o.title, isNull);
      expect(o.year, isNull);
      expect(o.poster, 'p.jpg');
      expect(o.isEmpty, isFalse);
      expect(const VodMetadataOverride().isEmpty, isTrue);
    });
  });

  group('5. spoiler prefs default off', () {
    test('both default false', () {
      expect(vodSpoilerHideSynopsis(), isFalse);
      expect(vodSpoilerBlurUnwatched(), isFalse);
    });
  });

  group('9. audio-only default', () {
    test('default off, persists', () async {
      expect(vodAudioOnlyDefault(), isFalse);
      await HiveStore.put(HiveKeys.vodAudioOnly, true);
      expect(vodAudioOnlyDefault(), isTrue);
    });
  });

  group('10. category prefs', () {
    List<VideoHomeRow> rows() => const [
          VideoHomeRow(name: '电影', count: 10, items: []),
          VideoHomeRow(name: '电视剧', count: 20, items: []),
          VideoHomeRow(name: '综艺', count: 5, items: []),
          VideoHomeRow(name: '动漫', count: 8, items: []),
        ];

    test('hide drops rows, order reorders, unknown names keep place',
        () {
      final prefs = VideoCategoryPrefs(
        hidden: {'综艺'},
        order: ['动漫', '电影'],
      );
      final out = applyCategoryPrefs(rows(), prefs);
      expect(out.map((r) => r.name).toList(), ['动漫', '电影', '电视剧']);
    });

    test('no prefs -> fetched order untouched', () {
      expect(
        applyCategoryPrefs(rows(), const VideoCategoryPrefs())
            .map((r) => r.name)
            .toList(),
        ['电影', '电视剧', '综艺', '动漫'],
      );
    });

    test('editor entries: manual order first, hidden flagged', () {
      final prefs = VideoCategoryPrefs(
        hidden: {'综艺'},
        order: ['动漫', '电影'],
      );
      final entries = categoryEditorEntries(
        ['电影', '电视剧', '综艺', '动漫'],
        prefs,
      );
      expect(
        entries.map((e) => e.name).toList(),
        ['动漫', '电影', '电视剧', '综艺'],
      );
      expect(entries.last.hidden, isTrue);
    });

    test('persist round-trip', () async {
      const prefs = VideoCategoryPrefs(
        hidden: {'综艺'},
        order: ['动漫', '电影'],
      );
      await saveCategoryPrefs(prefs);
      final back = readCategoryPrefs();
      expect(back.hidden, {'综艺'});
      expect(back.order, ['动漫', '电影']);
    });
  });

  group('6. screenshot', () {
    test('file name format', () {
      expect(
        vodScreenshotFileName(DateTime(2026, 11, 22, 12, 4, 30)),
        'vod_20261122_120430.jpg',
      );
    });

    test('save writes bytes under screenshots/', () async {
      final file = await saveVodScreenshot(
        jpeg: Uint8List.fromList([1, 2, 3, 4]),
        documentsDir: docsDir,
        now: DateTime(2026, 11, 22, 12, 4, 30),
      );
      expect(file.path, endsWith('screenshots/vod_20261122_120430.jpg'));
      expect(await file.readAsBytes(), [1, 2, 3, 4]);
    });

    test('GIF is honestly not feasible', () {
      final verdict = assessGifRecording();
      expect(verdict.feasible, isFalse);
      expect(verdict.reason, contains('GIF'));
    });
  });

  group('8. VOD sleep labels reuse the music timer', () {
    test('labels are VOD words; queueEnd is not offered', () {
      expect(
        vodSleepOptionLabel(
          SleepTimerOption.currentTrackEnd,
          customMinutes: 30,
          trackCount: 3,
        ),
        '播完本集后停止',
      );
      expect(
        vodSleepOptionLabel(
          SleepTimerOption.afterNTracks,
          customMinutes: 30,
          trackCount: 3,
        ),
        '播完 3 集后停止',
      );
      expect(kVodSleepOptions, isNot(contains(SleepTimerOption.queueEnd)));
    });

    test('same SleepTimer machine: afterNTracks counts completions',
        () {
      final timer = SleepTimer(onFire: () {});
      timer.startAfterNTracks(2);
      expect(timer.noteTrackCompleted(), isFalse);
      expect(timer.noteTrackCompleted(), isTrue);
      timer.cancel();
    });
  });

  group('12. timeline thumbnails', () {
    test('no track / no sprite / no seek-free capture -> not feasible',
        () {
      final r = assessTimelineThumbnails(
        hasThumbnailTrack: false,
        hasSpriteApi: false,
        canCaptureWithoutSeek: false,
      );
      expect(r.verdict, TimelineThumbnailVerdict.notFeasible);
      expect(r.reason, contains('seek'));
    });

    test('any real per-timestamp source flips the verdict', () {
      expect(
        assessTimelineThumbnails(
          hasThumbnailTrack: true,
          hasSpriteApi: false,
          canCaptureWithoutSeek: false,
        ).verdict,
        TimelineThumbnailVerdict.feasible,
      );
      expect(
        assessTimelineThumbnails(
          hasThumbnailTrack: false,
          hasSpriteApi: true,
          canCaptureWithoutSeek: false,
        ).verdict,
        TimelineThumbnailVerdict.feasible,
      );
    });
  });
}
