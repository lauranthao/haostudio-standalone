// Headphone AutoEq preset library (build 29, music).
//
// Each preset is a 10-band gain table for the existing native EQ tap
// (bands 31/62/125/250/500/1k/2k/4k/8k/16k — see EqualizerStore):
// applying one just sets those gains through the same channel as a
// hand-tuned preset, so it works on both crossfade players with no
// native change.
//
// HONESTY NOTE: these are community AutoEq-style corrections toward
// the Harman target, approximated onto our 10 fixed bands — NOT
// per-unit measurements, and NOT the full parametric AutoEq curves
// (10 fixed bands cannot express them exactly). Gains are kept
// conservative (max ±3 dB). The EQ page labels them "近似校准" for
// exactly this reason. If a model sounds wrong, the user retunes
// the bands by hand — the preset is only a starting point.
//
// Crossfeed is NOT in this file: it needs L/R sample mixing inside
// the tap, and HaoEqualizer.m's TapProcess runs each channel through
// its own 10 biquads with no cross-channel access
// (processBufferList: per-channel stateOffset = channel * 10). There
// is no Dart-side crossfeed API in just_audio and no AVPlayer
// crossfeed property — it needs new native DSP + a channel field,
// which is the native group's file, not this group's. No dead
// crossfeed toggle is shipped.

class AutoEqPreset {
  const AutoEqPreset({
    required this.id,
    required this.name,
    required this.gains,
  });

  final String id;

  /// Display name (model).
  final String name;

  /// 10 band gains in dB (31 Hz .. 16 kHz). Exactly 10 values.
  final List<double> gains;
}

/// The preset library, most common models first.
const List<AutoEqPreset> kAutoEqPresets = [
  AutoEqPreset(
    id: 'airpods-pro-2',
    name: 'AirPods Pro 2',
    gains: [1.5, 1.0, 0.5, 0.0, 0.0, -0.5, -1.0, -0.5, 0.5, 1.0],
  ),
  AutoEqPreset(
    id: 'airpods-max',
    name: 'AirPods Max',
    gains: [2.0, 1.5, 1.0, 0.0, -0.5, -0.5, 0.0, 0.5, 1.0, 1.5],
  ),
  AutoEqPreset(
    id: 'sony-wh1000xm5',
    name: 'Sony WH-1000XM5',
    gains: [-1.0, -0.5, 0.0, 0.5, 0.5, 0.0, -0.5, -1.0, -0.5, 0.0],
  ),
  AutoEqPreset(
    id: 'sony-wf1000xm5',
    name: 'Sony WF-1000XM5',
    gains: [1.0, 0.5, 0.0, 0.0, -0.5, -0.5, 0.0, 0.5, 1.0, 1.5],
  ),
  AutoEqPreset(
    id: 'bose-qc45',
    name: 'Bose QC45',
    gains: [2.5, 2.0, 1.0, 0.0, 0.0, 0.0, -0.5, 0.0, 0.5, 1.0],
  ),
  AutoEqPreset(
    id: 'sennheiser-hd600',
    name: 'Sennheiser HD 600',
    gains: [3.0, 2.0, 1.0, 0.0, 0.0, -1.0, -1.5, -1.0, 0.0, 1.0],
  ),
  AutoEqPreset(
    id: 'galaxy-buds2-pro',
    name: 'Galaxy Buds2 Pro',
    gains: [1.5, 1.0, 0.5, 0.0, -0.5, -0.5, 0.0, 0.5, 1.0, 0.5],
  ),
  AutoEqPreset(
    id: 'moondrop-aria',
    name: 'Moondrop Aria',
    gains: [2.0, 1.0, 0.5, 0.0, 0.0, 0.0, -0.5, -0.5, 0.0, 0.5],
  ),
];

AutoEqPreset? autoEqPresetById(String? id) {
  if (id == null || id.isEmpty) return null;
  for (final p in kAutoEqPresets) {
    if (p.id == id) return p;
  }
  return null;
}
