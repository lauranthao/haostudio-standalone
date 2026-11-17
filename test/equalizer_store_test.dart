// Equalizer store tests (stage 3).
//
// Covers the Dart-verifiable surface of the Beans `BeansEqualizer` port:
//  - preset gain tables are Beans' exact values (BeansEqualizer.swift)
//  - gain normalisation (clamp +-12, 0.5 dB steps)
//  - every mutation persists to Hive AND pushes the full snapshot to
//    the native engine over the equalizer method channel
//    (updateSettings {enabled, gains[10], preamp}) — the push is what
//    makes the tap real: the native singleton holds the complete state
//    and applies it to every AVPlayerItem just_audio creates, so both
//    A/B crossfade players inherit it (see HAO_PATCH.md; the native
//    hook itself cannot run on the Linux test VM, so it is verified by
//    code inspection + the iOS build gate, not by these tests)
//  - custom presets save/apply/delete, reset, restart round-trip
//  - syncToNative returns false (never throws) where there is no
//    native engine (Android / Linux tests)

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/equalizer_store.dart';

const _eqChannel = MethodChannel('com.haostudio.standalone/equalizer');

void main() {
  late Directory hiveDir;
  late Box<dynamic> box;
  final List<Map<String, dynamic>> channelCalls = [];

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-eq-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    box = await Hive.openBox<dynamic>(
      'test_eq',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(box);
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  setUp(() async {
    channelCalls.clear();
    EqualizerStore.resetForTest();
    for (final key in [
      HiveKeys.equalizerEnabled,
      HiveKeys.equalizerBandGains,
      HiveKeys.equalizerPreset,
      HiveKeys.equalizerCustomPresetName,
      HiveKeys.equalizerPreamp,
      HiveKeys.equalizerCustomPresets,
    ]) {
      await box.delete(key);
    }
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_eqChannel, (call) async {
      channelCalls.add({
        'method': call.method,
        'args': (call.arguments as Map).cast<String, dynamic>(),
      });
      return null;
    });
  });

  tearDown(() {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_eqChannel, null);
    EqualizerStore.resetForTest();
  });

  Map<String, dynamic> lastPush() {
    expect(channelCalls, isNotEmpty, reason: 'expected a native push');
    return channelCalls.last['args'] as Map<String, dynamic>;
  }

  test('defaults are flat/off and sync pushes the full snapshot', () async {
    final store = EqualizerStore();
    expect(store.enabled, isFalse);
    expect(store.bandGains, List.filled(10, 0));
    expect(store.selectedPreset, EqualizerPreset.flat);
    expect(store.preampGain, 0);
    expect(store.customPresets, isEmpty);

    expect(await store.syncToNative(), isTrue);
    final args = lastPush();
    expect(args['enabled'], isFalse);
    expect((args['gains'] as List).length, 10);
    expect((args['gains'] as List).every((g) => g == 0), isTrue);
    expect(args['preamp'], 0);
  });

  test('preset gain tables match Beans exactly', () async {
    final store = EqualizerStore();
    final expected = {
      EqualizerPreset.flat: [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
      EqualizerPreset.bass: [6, 5, 3, 1, 0, 0, -1, -1, 0, 0],
      EqualizerPreset.vocal: [-2, -1, 0, 2, 4, 4, 3, 2, 0, -1],
      EqualizerPreset.pop: [2, 2, 1, 0, 2, 3, 2, 1, 2, 2],
      EqualizerPreset.rock: [5, 4, 2, -1, -2, 1, 3, 4, 5, 4],
      EqualizerPreset.classical: [3, 2, 1, 0, 0, 1, 2, 3, 4, 4],
      EqualizerPreset.jazz: [3, 2, 1, 2, -1, -1, 0, 2, 3, 3],
      EqualizerPreset.electronic: [5, 4, 1, -2, -1, 2, 4, 3, 5, 4],
    };
    for (final entry in expected.entries) {
      await store.applyPreset(entry.key);
      expect(
        store.bandGains,
        entry.value.map((v) => v.toDouble()).toList(),
        reason: '${entry.key.name} gains differ from Beans',
      );
      expect(store.preampGain, 0);
      expect(store.isCustom, isFalse);
      // The push carries the preset's gains to the native tap.
      expect(lastPush()['gains'], entry.value);
    }
  });

  test('gain normalisation clamps to +-12 in 0.5 dB steps', () {
    expect(EqualizerStore.normalizeGain(13), 12);
    expect(EqualizerStore.normalizeGain(-13), -12);
    expect(EqualizerStore.normalizeGain(1.3), 1.5);
    expect(EqualizerStore.normalizeGain(1.2), 1.0);
    expect(EqualizerStore.normalizeGain(-2.26), -2.5);
    expect(EqualizerStore.normalizeGain(0), 0);
    expect(EqualizerStore.normalizeGains([20, -20]), [
      12, -12, 0, 0, 0, 0, 0, 0, 0, 0,
    ]);
    expect(EqualizerStore.normalizeGains(null), List.filled(10, 0));
  });

  test('setEnabled persists and pushes enabled=true', () async {
    final store = EqualizerStore();
    await store.setEnabled(true);
    expect(store.enabled, isTrue);
    expect(HiveStore.getBool(HiveKeys.equalizerEnabled, false), isTrue);
    expect(lastPush()['enabled'], isTrue);
    // No-op re-set sends nothing new.
    channelCalls.clear();
    await store.setEnabled(true);
    expect(channelCalls, isEmpty);
  });

  test('band move marks custom, persists gains + push', () async {
    final store = EqualizerStore();
    await store.applyPreset(EqualizerPreset.rock);
    channelCalls.clear();
    await store.setBandGain(0, 7.3);
    expect(store.bandGains[0], 7.5);
    expect(store.isCustom, isTrue);
    expect(store.currentPresetName, '自定义');
    final args = lastPush();
    expect((args['gains'] as List)[0], 7.5);
    // Out-of-range index is ignored, no push.
    channelCalls.clear();
    await store.setBandGain(10, 5);
    expect(channelCalls, isEmpty);
  });

  test('preamp moves feed responseValues like Beans', () async {
    final store = EqualizerStore();
    await store.setPreampGain(6.3);
    expect(store.preampGain, 6.5);
    expect(store.isCustom, isTrue);
    // Beans responseValues: gains + preamp*0.35, clamped +-12.
    expect(store.responseValues.every((v) => v == 6.5 * 0.35), isTrue);
    expect(lastPush()['preamp'], 6.5);
  });

  test('restart round-trip: enabled, gains, custom flag, preamp',
      () async {
    final store = EqualizerStore();
    await store.setEnabled(true);
    await store.setBandGain(2, -3);
    await store.setPreampGain(2);
    // A fresh instance (new app launch) reads the same Hive box.
    final reloaded = EqualizerStore();
    expect(reloaded.enabled, isTrue);
    expect(reloaded.bandGains[2], -3);
    expect(reloaded.preampGain, 2);
    expect(reloaded.isCustom, isTrue);
    expect(reloaded.currentPresetName, '自定义');
    // And a built-in preset survives a restart as the preset, not custom.
    await reloaded.applyPreset(EqualizerPreset.jazz);
    final reloaded2 = EqualizerStore();
    expect(reloaded2.isCustom, isFalse);
    expect(reloaded2.selectedPreset, EqualizerPreset.jazz);
    expect(reloaded2.currentPresetName, '爵士');
  });

  test('custom presets save/apply/delete/overwrite', () async {
    final store = EqualizerStore();
    expect(await store.saveCustomPreset('  '), isFalse);
    await store.applyPreset(EqualizerPreset.bass);
    expect(await store.saveCustomPreset('我的低音'), isTrue);
    expect(store.customPresets.length, 1);
    expect(store.selectedCustomPresetName, '我的低音');
    // Overwrite by same name (case-insensitive) does not duplicate.
    await store.applyPreset(EqualizerPreset.rock);
    expect(await store.saveCustomPreset('我的低音'), isTrue);
    expect(store.customPresets.length, 1);
    expect(store.customPresets.single.gains[0], 5);
    // Restart keeps the custom preset list.
    final reloaded = EqualizerStore();
    expect(reloaded.customPresets.length, 1);
    await reloaded.applyCustomPreset(reloaded.customPresets.single);
    expect(reloaded.bandGains[0], 5);
    expect(reloaded.selectedCustomPresetName, '我的低音');
    await reloaded.deleteCustomPreset(reloaded.customPresets.single);
    expect(reloaded.customPresets, isEmpty);
    expect(reloaded.selectedCustomPresetName, isNull);
  });

  test('reset returns to flat with preamp 0', () async {
    final store = EqualizerStore();
    await store.applyPreset(EqualizerPreset.electronic);
    await store.setPreampGain(4);
    await store.reset();
    expect(store.bandGains, List.filled(10, 0));
    expect(store.preampGain, 0);
    expect(store.selectedPreset, EqualizerPreset.flat);
    expect(store.isCustom, isFalse);
  });

  test('syncToNative returns false without a native engine, never throws',
      () async {
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(_eqChannel, null);
    final store = EqualizerStore();
    expect(await store.syncToNative(), isFalse);
    // Mutations still persist locally even when the push fails.
    await store.setEnabled(true);
    expect(HiveStore.getBool(HiveKeys.equalizerEnabled, false), isTrue);
  });

  test('frequency labels match Beans', () {
    expect(EqualizerStore.frequencyLabel(31), '31 Hz');
    expect(EqualizerStore.frequencyLabel(500), '500 Hz');
    expect(EqualizerStore.frequencyLabel(1000), '1 kHz');
    expect(EqualizerStore.frequencyLabel(16000), '16 kHz');
    expect(EqualizerStore.bandFrequencies,
        [31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000]);
  });
}
