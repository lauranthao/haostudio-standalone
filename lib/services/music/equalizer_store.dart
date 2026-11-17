// Equalizer store — stage 3.
//
// Dart side of the Beans `BeansEqualizer` port. Owns persistence (Hive,
// keys in HiveKeys) and pushes the live values to the native
// MTAudioProcessingTap engine over the `com.haostudio.standalone/equalizer`
// method channel (`updateSettings` {enabled, gains[10], preamp}).
// The native engine lives in the vendored just_audio fork
// (packages/just_audio_eq, see HAO_PATCH.md): the tap is attached to
// every AVPlayerItem just_audio creates, so BOTH crossfade players
// (A/B) get the EQ — no per-player wiring is needed or exists in Dart.
//
// Values copied 1:1 from Beans `BeansEqualizer.swift`:
//  - bandFrequencies [31,62,125,250,500,1000,2000,4000,8000,16000]
//  - maximumGain 12, gains normalised to 0.5 dB steps (normalizedGain)
//  - presets flat/bass/vocal/pop/rock/classical/jazz/electronic with
//    Beans' exact gain tables (preset.gains), custom = no table
//  - preamp linear gain 10^(dB/20) is native-side (HaoEqualizer.m)
//  - response preview = gains + preamp*0.35, clamped +-12
//    (EqualizerResponseView.responseValues)
//
// Not copied from Beans, with reasons:
//  - 5-band legacy migration (normalizedGains): we never shipped a
//    5-band EQ, so there is no legacy data to migrate.
//  - UserDefaults persistence: Hive is our store; the native side
//    holds live DSP state only and never persists.
//  - 0.25 s persist debounce (schedulePersist): Hive puts are cheap
//    in-memory writes; mutations await the put directly instead.
//
// Scope: music only (AVPlayer via just_audio). Video/live players use
// their own kernels and are untouched — the tap is attached only to
// items just_audio creates, never to video items.
// The music player stays AVPlayer-only: this store never touches the
// settings playback-kernel selector, and playback parsing is untouched
// (first-playable-source iron law lives in the controller).

import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

import '../../core/storage/hive_store.dart';

/// One user-saved custom preset (Beans `BeansEqualizerCustomPreset`).
class EqualizerCustomPreset {
  const EqualizerCustomPreset({
    required this.name,
    required this.gains,
    required this.preamp,
  });

  final String name;
  final List<double> gains;
  final double preamp;

  Map<String, dynamic> toJson() => {
        'name': name,
        'gains': gains,
        'preamp': preamp,
      };

  static EqualizerCustomPreset? fromJson(Map<String, dynamic> json) {
    final name = (json['name'] as String?)?.trim();
    if (name == null || name.isEmpty) return null;
    final gains = EqualizerStore.normalizeGains(json['gains']);
    final preamp = EqualizerStore.normalizeGain(
      (json['preamp'] as num?)?.toDouble() ?? 0,
    );
    return EqualizerCustomPreset(name: name, gains: gains, preamp: preamp);
  }
}

/// Built-in preset ids (Beans `BeansEqualizerPreset`, minus custom).
/// Display names are Chinese, as in Beans' beansLocalized calls.
enum EqualizerPreset {
  flat('默认'),
  bass('低音增强'),
  vocal('人声'),
  pop('流行'),
  rock('摇滚'),
  classical('古典'),
  jazz('爵士'),
  electronic('电子');

  const EqualizerPreset(this.displayName);

  final String displayName;

  /// Beans preset.gains, copied exactly (BeansEqualizer.swift).
  List<double> get gains => switch (this) {
        flat => [0, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        bass => [6, 5, 3, 1, 0, 0, -1, -1, 0, 0],
        vocal => [-2, -1, 0, 2, 4, 4, 3, 2, 0, -1],
        pop => [2, 2, 1, 0, 2, 3, 2, 1, 2, 2],
        rock => [5, 4, 2, -1, -2, 1, 3, 4, 5, 4],
        classical => [3, 2, 1, 0, 0, 1, 2, 3, 4, 4],
        jazz => [3, 2, 1, 2, -1, -1, 0, 2, 3, 3],
        electronic => [5, 4, 1, -2, -1, 2, 4, 3, 5, 4],
      };

  static EqualizerPreset fromId(String? id) => switch (id) {
        'bass' => bass,
        'vocal' => vocal,
        'pop' => pop,
        'rock' => rock,
        'classical' => classical,
        'jazz' => jazz,
        'electronic' => electronic,
        _ => flat,
      };
}

class EqualizerStore extends ChangeNotifier {
  EqualizerStore({MethodChannel? channel})
      : _channel =
            channel ?? const MethodChannel('com.haostudio.standalone/equalizer') {
    _load();
  }

  static EqualizerStore? _instance;

  /// App-wide singleton (main() pushes persisted settings to native
  /// before any playback; settings page + player menu read it).
  static EqualizerStore ensure() => _instance ??= EqualizerStore();

  /// Test-only: drop the singleton so a fresh instance re-reads Hive.
  @visibleForTesting
  static void resetForTest() {
    _instance?.dispose();
    _instance = null;
  }

  static const List<double> bandFrequencies = [
    31, 62, 125, 250, 500, 1000, 2000, 4000, 8000, 16000,
  ];
  static const double maximumGain = 12;

  final MethodChannel _channel;

  bool enabled = false;
  List<double> bandGains = List.filled(10, 0);
  EqualizerPreset selectedPreset = EqualizerPreset.flat;
  String? selectedCustomPresetName;
  double preampGain = 0;
  List<EqualizerCustomPreset> customPresets = [];

  /// Display name of the current preset (custom name wins, then
  /// 自定义 for hand-tuned gains, then the built-in name — Beans
  /// presetCard menu label).
  String get currentPresetName =>
      selectedCustomPresetName ??
      (_custom ? '自定义' : selectedPreset.displayName);

  /// True when the current gains were hand-tuned (not a built-in
  /// preset). Beans tracks this as selectedPreset == .custom; we
  /// persist it as preset id 'custom' in Hive (see _persist/_load).
  bool get isCustom => _custom;

  bool _custom = false;

  /// Beans normalizedGain: clamp +-12, round to 0.5 dB.
  static double normalizeGain(double value) {
    final clamped = value.clamp(-maximumGain, maximumGain);
    return (clamped * 2).round() / 2;
  }

  /// Beans normalizedGains (10-band form; no 5-band migration — see
  /// the file header): pad short lists with 0, normalise each band.
  static List<double> normalizeGains(dynamic values) {
    final list = values is List ? values : const [];
    return List<double>.generate(10, (i) {
      final v = i < list.length ? (list[i] as num?)?.toDouble() ?? 0.0 : 0.0;
      return normalizeGain(v);
    });
  }

  /// Frequency label (Beans EqualizerSettingsView.frequencyLabel):
  /// 31 Hz .. 500 Hz, 1 kHz .. 16 kHz.
  static String frequencyLabel(double frequency) {
    if (frequency >= 1000) {
      final value = frequency / 1000;
      return value == value.roundToDouble()
          ? '${value.toInt()} kHz'
          : '${value.toStringAsFixed(1)} kHz';
    }
    return '${frequency.toInt()} Hz';
  }

  /// Response-preview values (Beans EqualizerResponseView.responseValues):
  /// band gain + 35% of the preamp, clamped +-12.
  List<double> get responseValues => bandGains
      .map((g) => (g + preampGain * 0.35).clamp(-maximumGain, maximumGain))
      .toList();

  void _load() {
    enabled = HiveStore.getBool(HiveKeys.equalizerEnabled, false);
    bandGains = normalizeGains(HiveStore.box.get(HiveKeys.equalizerBandGains));
    final storedPreset =
        HiveStore.getString(HiveKeys.equalizerPreset, 'flat');
    // Persisted 'custom' means hand-tuned gains (Beans .custom):
    // selectedPreset is only a sentinel then; isCustom is the signal.
    _custom = storedPreset == 'custom';
    selectedPreset = EqualizerPreset.fromId(storedPreset);
    final customName =
        HiveStore.getString(HiveKeys.equalizerCustomPresetName, '');
    selectedCustomPresetName = customName.isEmpty ? null : customName;
    preampGain = normalizeGain(
      HiveStore.getDouble(HiveKeys.equalizerPreamp, 0),
    );
    customPresets = _decodeCustomPresets(
      HiveStore.getString(HiveKeys.equalizerCustomPresets, ''),
    );
    // A stored custom selection without a matching saved preset is
    // stale (preset deleted before the name was cleared): fall back
    // to the built-in preset instead of showing a dangling name.
    if (selectedCustomPresetName != null &&
        !customPresets.any((p) => p.name == selectedCustomPresetName)) {
      selectedCustomPresetName = null;
    }
  }

  static List<EqualizerCustomPreset> _decodeCustomPresets(String json) {
    if (json.isEmpty) return [];
    try {
      final raw = jsonDecode(json);
      if (raw is! List) return [];
      return raw
          .whereType<Map<String, dynamic>>()
          .map(EqualizerCustomPreset.fromJson)
          .whereType<EqualizerCustomPreset>()
          .toList();
    } catch (_) {
      return [];
    }
  }

  Future<void> _persist() async {
    await HiveStore.put(HiveKeys.equalizerEnabled, enabled);
    await HiveStore.put(HiveKeys.equalizerBandGains, bandGains);
    // Hand-tuned gains persist as preset id 'custom' (Beans .custom),
    // so a restart still shows 自定义 instead of 默认.
    await HiveStore.put(
      HiveKeys.equalizerPreset,
      _custom ? 'custom' : selectedPreset.name,
    );
    await HiveStore.put(
      HiveKeys.equalizerCustomPresetName,
      selectedCustomPresetName ?? '',
    );
    await HiveStore.put(HiveKeys.equalizerPreamp, preampGain);
    await HiveStore.put(
      HiveKeys.equalizerCustomPresets,
      jsonEncode(customPresets.map((p) => p.toJson()).toList()),
    );
  }

  /// Push the current settings to the native tap engine. Returns true
  /// when the native side acked; false on platforms without the engine
  /// (Android, Linux tests — MissingPluginException) or any other
  /// failure. A false here never blocks the UI: Hive already holds
  /// the truth and the next app start re-pushes.
  Future<bool> syncToNative() async {
    try {
      await _channel.invokeMethod<void>('updateSettings', {
        'enabled': enabled,
        'gains': bandGains,
        'preamp': preampGain,
      });
      return true;
    } catch (_) {
      return false;
    }
  }

  Future<void> _commit() async {
    await _persist();
    notifyListeners();
    await syncToNative();
  }

  /// Beans setEnabled: flip the switch; the native side sets/clears
  /// audioMix on both crossfade players' live items.
  Future<void> setEnabled(bool value) async {
    if (enabled == value) return;
    enabled = value;
    await _commit();
  }

  /// Beans setBandGain: any manual band move makes the preset custom.
  Future<void> setBandGain(int index, double gain) async {
    if (index < 0 || index >= bandGains.length) return;
    final normalized = normalizeGain(gain);
    if (bandGains[index] == normalized) return;
    final updated = List<double>.of(bandGains);
    updated[index] = normalized;
    bandGains = updated;
    _custom = true;
    selectedCustomPresetName = null;
    await _commit();
  }

  /// Beans setPreampGain: also marks the tuning custom.
  Future<void> setPreampGain(double gain) async {
    final normalized = normalizeGain(gain);
    if (preampGain == normalized) return;
    preampGain = normalized;
    _custom = true;
    selectedCustomPresetName = null;
    await _commit();
  }

  /// Beans applyPreset: gains + preamp reset to 0.
  Future<void> applyPreset(EqualizerPreset preset) async {
    bandGains = normalizeGains(preset.gains);
    selectedPreset = preset;
    selectedCustomPresetName = null;
    preampGain = 0;
    _custom = false;
    await _commit();
  }

  /// Beans applyCustomPreset.
  Future<void> applyCustomPreset(EqualizerCustomPreset preset) async {
    bandGains = normalizeGains(preset.gains);
    selectedPreset = EqualizerPreset.flat;
    selectedCustomPresetName = preset.name;
    preampGain = normalizeGain(preset.preamp);
    _custom = true;
    await _commit();
  }

  /// Beans saveCustomPreset: empty name fails; same name (case
  /// insensitive) overwrites. Returns false when the name is blank.
  Future<bool> saveCustomPreset(String name) async {
    final trimmed = name.trim();
    if (trimmed.isEmpty) return false;
    final current = EqualizerCustomPreset(
      name: trimmed,
      gains: List<double>.of(bandGains),
      preamp: preampGain,
    );
    final index = customPresets.indexWhere(
      (p) => p.name.toLowerCase() == trimmed.toLowerCase(),
    );
    if (index >= 0) {
      customPresets[index] = current;
    } else {
      customPresets.add(current);
    }
    selectedCustomPresetName = trimmed;
    _custom = true;
    await _commit();
    return true;
  }

  /// Beans deleteCustomPreset.
  Future<void> deleteCustomPreset(EqualizerCustomPreset preset) async {
    customPresets.removeWhere((p) => p.name == preset.name);
    if (selectedCustomPresetName == preset.name) {
      selectedCustomPresetName = null;
    }
    await _commit();
  }

  /// Beans reset: back to flat (gains 0, preamp 0).
  Future<void> reset() => applyPreset(EqualizerPreset.flat);
}
