// Volume boost 0–300% — item 8 (build 29, I group).
//
// The room's player volume is the *device-facing* player volume
// (session `setVolume`, 0..1 in every caller in this codebase). The
// boost is a software gain on top of it: effective volume =
// base × boost, where boost is 1.0 (100%) .. 3.0 (300%), persisted
// per the room tools sheet.
//
// Engine ceilings (verified against the kernel sources, not guessed):
// - MPV: `MpvBackend.setVolume` forwards to media_kit's
//   `Player.setVolume`, which sets mpv's `volume` property with NO
//   Dart-side clamp. mpv itself clamps `volume` to `volume-max`,
//   whose mpv default is 130 — so today a session volume of 1.3
//   (130%) is the real ceiling. 131–300% needs `volume-max=300` at
//   mpv init, which lives in `lib/core/player/kernel/mpv_backend.dart`
//   (NOT a live-domain file) — recorded as a gap, not silently
//   pretended. The UI shows the *effective* % so the user sees what
//   actually plays.
// - IJK: `IjkBackend.setVolume` forwards to fijk's `setVolume`,
//   whose contract in this codebase is 0..1 — no >100% path, ceiling
//   1.0. (Whether ijk's native side would honour >1 is unverified;
//   the boost does not send it one.)
// - AVPlayer: BetterPlayer `setVolume` is 0..1 (AVPlayer volume) —
//   no software gain, ceiling 1.0.
//
// The mapping itself is pure and unit-tested; the room page applies
// it through the session after every engine swap.

import '../../core/player/kernel/player_engine.dart';
import '../../core/storage/hive_store.dart';

/// Hive key (literal — HiveKeys lives in hive_store.dart, owned by
/// the settings group; the value is a plain int percent).
const String liveVolumeBoostKey = 'hao_live_volume_boost_pct';

/// Boost as a percent: 100 = off, 300 = 3x. Clamped to 100..300.
int clampBoostPct(int pct) => pct.clamp(100, 300);

/// Real per-engine ceiling for the *session* volume value (1.0 =
/// 100%). MPV 1.3 (mpv volume-max default), IJK / AVPlayer 1.0.
double sessionVolumeCeiling(PlayerEngine engine) {
  switch (engine) {
    case PlayerEngine.mediaKit:
      return 3.0;
    case PlayerEngine.fijk:
    case PlayerEngine.exo:
      return 1.0;
  }
}

/// Effective session volume for [baseVolume] (0..1) at [boostPct]
/// on [engine], clamped to that engine's ceiling. 0 base stays 0
/// (boost never un-mutes).
double effectiveSessionVolume({
  required double baseVolume,
  required int boostPct,
  required PlayerEngine engine,
}) {
  if (baseVolume <= 0) return 0;
  final boost = clampBoostPct(boostPct) / 100;
  return (baseVolume * boost).clamp(0, sessionVolumeCeiling(engine));
}

/// Effective gain actually heard, as a percent of the base volume
/// (100 = no boost). E.g. base 0.8, boost 200%, MPV -> 130%.
int effectiveBoostPct({
  required double baseVolume,
  required int boostPct,
  required PlayerEngine engine,
}) {
  if (baseVolume <= 0) return 100;
  final effective = effectiveSessionVolume(
    baseVolume: baseVolume,
    boostPct: boostPct,
    engine: engine,
  );
  return (effective / baseVolume * 100).round();
}

/// Persisted boost percent (100..300), default 100 (off).
int loadBoostPct() {
  try {
    return clampBoostPct(HiveStore.getInt(liveVolumeBoostKey, 100));
  } catch (_) {
    return 100;
  }
}

Future<void> saveBoostPct(int pct) =>
    HiveStore.put(liveVolumeBoostKey, clampBoostPct(pct));
