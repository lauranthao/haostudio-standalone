// 1.1.6 音乐 — 响度测量接线测试：缓存读写 + 跨重启 + 通道接线.
//
// Covers the Dart-verifiable surface of the tap loudness wiring
// (HaoEqualizer.m -> equalizer method channel -> EqualizerStore ->
// MusicPlayerController.noteMeasuredLoudness -> Hive cache):
//  - parseLoudnessCache drops junk, clamps, caps at 200
//  - noteMeasuredLoudness writes through to Hive (merge, not
//    overwrite) and the gain follows from the second play
//  - a fresh controller loads the Hive cache in onInit, so the
//    second-play effect survives a restart (no measurement call)
//  - a native 'loudnessMeasured' platform message arriving after
//    onInit feeds normalizationGainFor (end-to-end Dart side)
//  - EqualizerStore routes 'loudnessMeasured' and drops malformed
//    calls; setTrackKey invokes the native method best-effort
//
// The native tap itself (RMS accumulation, finalize report) cannot
// run on the Linux test VM — it is verified by code inspection +
// the iOS build gate + chen's phone, not by these tests. EQ-off
// tracks are never measured (the tap only exists while EQ is on);
// that is covered by the native-side comment, not by a test here.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/services/music/equalizer_store.dart';
import 'package:standalone/services/music/music_models.dart';

const _eqChannelName = 'com.haostudio.standalone/equalizer';
const _eqChannel = MethodChannel(_eqChannelName);

Song _song(String id, String title) => Song(
      songId: id,
      title: title,
      artist: 'Singer $id',
      platform: MusicPlatform.wy,
      dur: 260,
    );

void main() {
  late Directory hiveDir;
  late Box<dynamic> box;
  late MusicPlayerController c;

  /// Poll until [check] holds (up to ~10 s). Same pattern as
  /// v16_music_sleep_norm_bookmark_test.dart: fixed short delays
  /// flake when the VM is loaded, polling only makes the test
  /// slower, never wrong.
  Future<void> waitForCondition(bool Function() check) async {
    for (var i = 0; i < 200; i++) {
      if (check()) return;
      await Future<void>.delayed(const Duration(milliseconds: 50));
    }
    expect(check(), isTrue);
  }

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-loudness-test-');
    Hive.init(hiveDir.path);
    box = await Hive.openBox<dynamic>('v16_loudness_test');
    HiveStore.setTestBox(box);
  });

  tearDownAll(() async {
    EqualizerStore.resetForTest();
    await box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    await box.clear();
    EqualizerStore.resetForTest();
    c = MusicPlayerController();
    c.onInit();
  });

  tearDown(() async {
    c.onClose();
    Get.reset();
    await box.clear();
  });

  group('loudness cache (1.1.6)', () {
    test('parseLoudnessCache drops junk, clamps, caps at 200', () {
      expect(MusicPlayerController.parseLoudnessCache(null), isEmpty);
      expect(MusicPlayerController.parseLoudnessCache('loud'), isEmpty);
      expect(
        MusicPlayerController.parseLoudnessCache({
          'wy|1': -8.0,
          '': -8.0,
          'bad': 'loud',
          'nan': double.nan,
          'inf': double.infinity,
          'hot': 5.0,
          'cold': -80.0,
          'int': -20,
        }),
        {'wy|1': -8.0, 'hot': 0.0, 'cold': -70.0, 'int': -20.0},
      );
      final big = {
        for (var i = 0; i < 205; i++) 'wy|$i': -10.0,
      };
      final parsed = MusicPlayerController.parseLoudnessCache(big);
      expect(parsed.length, 200);
      expect(parsed.containsKey('wy|0'), isFalse);
      expect(parsed['wy|204'], -10.0);
    });

    test('noteMeasuredLoudness writes through to Hive, merging', () async {
      await c.setNormalizationEnabled(true);
      final b = _song('2', 'B');
      c.noteMeasuredLoudness(b.identityKey, -8);
      await waitForCondition(() {
        final raw = box.get(HiveKeys.musicLoudnessCache);
        return raw is Map && raw[b.identityKey] == -8.0;
      });
      // A second track merges into the same map, it does not
      // overwrite the first entry.
      c.noteMeasuredLoudness(_song('3', 'C').identityKey, -20);
      await waitForCondition(() {
        final raw = box.get(HiveKeys.musicLoudnessCache);
        return raw is Map &&
            raw[b.identityKey] == -8.0 &&
            raw[_song('3', 'C').identityKey] == -20.0;
      });
    });

    test('measured track attenuates, unmeasured plays at 1.0', () async {
      await c.setNormalizationEnabled(true);
      final a = _song('1', 'A');
      final b = _song('2', 'B');
      expect(c.normalizationGainFor(a), 1.0);
      expect(c.normalizationGainFor(b), 1.0);
      // Tap measured -8 LUFS during playback: next load attenuates.
      c.noteMeasuredLoudness(b.identityKey, -8);
      expect(c.normalizationGainFor(b), closeTo(0.5012, 0.001));
      expect(c.normalizationGainFor(a), 1.0);
    });

    test('cache survives restart: fresh controller loads Hive', () async {
      // Pre-fill the box as a previous run would have left it:
      // normalisation on + one measured track. The fresh
      // controller must attenuate WITHOUT any noteMeasuredLoudness
      // call of its own.
      await HiveStore.put(HiveKeys.musicNormalizationEnabled, true);
      await HiveStore.put(
        HiveKeys.musicLoudnessCache,
        {'wy|2': -8.0},
      );
      final c2 = MusicPlayerController();
      addTearDown(() => c2.onClose());
      c2.onInit();
      expect(c2.normalizationEnabled.value, isTrue);
      expect(
        c2.normalizationGainFor(_song('2', 'B')),
        closeTo(0.5012, 0.001),
      );
      expect(c2.normalizationGainFor(_song('1', 'A')), 1.0);
    });

    test('clamped measurements: hot cuts at max, quiet stays 1.0',
        () async {
      await c.setNormalizationEnabled(true);
      // +5 LUFS clamps to 0: still louder than the -14 target, so
      // the standard strength cuts the full 6 dB.
      c.noteMeasuredLoudness(_song('9', 'Hot').identityKey, 5);
      expect(
        c.normalizationGainFor(_song('9', 'Hot')),
        closeTo(0.5012, 0.001),
      );
      // -80 LUFS clamps to -70: far below target, never boosts.
      c.noteMeasuredLoudness(_song('8', 'Quiet').identityKey, -80);
      expect(c.normalizationGainFor(_song('8', 'Quiet')), 1.0);
    });

    test('noteMeasuredLoudness ignores empty key / non-finite', () async {
      await c.setNormalizationEnabled(true);
      c.noteMeasuredLoudness('', -8);
      c.noteMeasuredLoudness(_song('2', 'B').identityKey, double.nan);
      c.noteMeasuredLoudness(
        _song('2', 'B').identityKey,
        double.infinity,
      );
      expect(c.normalizationGainFor(_song('2', 'B')), 1.0);
      expect(box.get(HiveKeys.musicLoudnessCache), isNull);
    });

    test('native report after onInit feeds normalizationGainFor',
        () async {
      await c.setNormalizationEnabled(true);
      final b = _song('2', 'B');
      expect(c.normalizationGainFor(b), 1.0);
      // Simulate the native tap finalize report arriving over the
      // equalizer channel (EqualizerStore singleton handler ->
      // controller registration from onInit).
      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _eqChannelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall(
            'loudnessMeasured',
            {'identityKey': 'wy|2', 'lufs': -8.0},
          ),
        ),
        (_) {},
      );
      await waitForCondition(
        () => (c.normalizationGainFor(b) - 0.5012).abs() < 0.001,
      );
      expect(c.normalizationGainFor(b), closeTo(0.5012, 0.001));
    });
  });

  group('equalizer channel loudness wiring', () {
    late EqualizerStore store;

    setUp(() {
      // A fresh instance on the same channel name (the constructor
      // installs the method-call handler); the controller singleton
      // from the outer setUp is not involved in these tests.
      store = EqualizerStore(channel: _eqChannel);
    });

    tearDown(() {
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_eqChannel, null);
    });

    test('loudnessMeasured platform message reaches the callback',
        () async {
      final received = <(String, double)>[];
      store.onLoudnessMeasured =
          (key, lufs) => received.add((key, lufs));
      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        _eqChannelName,
        const StandardMethodCodec().encodeMethodCall(
          const MethodCall(
            'loudnessMeasured',
            {'identityKey': 'wy|2', 'lufs': -8.0},
          ),
        ),
        (_) {},
      );
      expect(received, [('wy|2', -8.0)]);
    });

    test('malformed loudnessMeasured is dropped, unknown ignored',
        () async {
      final received = <(String, double)>[];
      store.onLoudnessMeasured =
          (key, lufs) => received.add((key, lufs));
      final messenger = TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger;
      Future<void> send(MethodCall call) => messenger.handlePlatformMessage(
            _eqChannelName,
            const StandardMethodCodec().encodeMethodCall(call),
            (_) {},
          );
      await send(
        const MethodCall('loudnessMeasured', {'identityKey': 'wy|2'}),
      );
      await send(
        const MethodCall(
          'loudnessMeasured',
          {'identityKey': 'wy|2', 'lufs': 'loud'},
        ),
      );
      await send(
        const MethodCall(
          'loudnessMeasured',
          {'identityKey': '', 'lufs': -8.0},
        ),
      );
      await send(const MethodCall('loudnessMeasured', 'not-a-map'));
      await send(const MethodCall('nonsense', null));
      expect(received, isEmpty);
    });

    test('setTrackKey invokes native, empty key / throw returns false',
        () async {
      final calls = <MethodCall>[];
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_eqChannel, (call) async {
        calls.add(call);
        return null;
      });
      expect(await store.setTrackKey('wy|2'), isTrue);
      expect(calls, hasLength(1));
      expect(calls.single.method, 'setTrackKey');
      expect(
        calls.single.arguments,
        {'identityKey': 'wy|2'},
      );
      expect(await store.setTrackKey(''), isFalse);
      expect(calls, hasLength(1));
      TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .setMockMethodCallHandler(_eqChannel, (call) async {
        throw MissingPluginException();
      });
      expect(await store.setTrackKey('wy|2'), isFalse);
    });
  });
}
