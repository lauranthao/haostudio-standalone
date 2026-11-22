// Data-network quality — item 3 (build 29, I group).
//
// Mobile data auto-drops a notch, Wi-Fi uses the highest quality.
// No connectivity_plus dependency exists in this project, so the
// transport is detected from `NetworkInterface.list()`: iOS names
// its interfaces `en0` (Wi-Fi) and `pdp_ip0` (cellular); Android
// uses `wlan0` / `rmnet*`. The mapping is a heuristic — when no
// interface can be classified, the network is [LiveNetworkType.unknown]
// and the quality is NOT downgraded (never punish the user on a
// guess).
//
// The quality rule is pure and unit-testable: on cellular the
// initial quality is capped at the first quality at or below the
// cellular ceiling ("超清" when the room offers it, else the lowest
// quality above 流畅, else the lowest quality outright — never
// 原画/蓝光 on mobile data); on Wi-Fi / unknown the preferred
// quality applies unchanged. This only sets the ENTRY quality: the
// user can still switch up manually in the room (their explicit
// choice always wins).

import 'dart:io';

import '../../core/models/live_models.dart';
import '../../core/storage/hive_store.dart';

/// What the device is on, as far as the interface list can tell.
enum LiveNetworkType {
  /// Wi-Fi (en0 / wlan0).
  wifi,

  /// Mobile data (pdp_ip0 / rmnet*).
  cellular,

  /// No classifiable interface (offline, VPN-only, or a name we do
  /// not recognise) — treated as "do not downgrade".
  unknown,
}

/// Classify one interface name. Case-insensitive; anything else is
/// null (unclassifiable).
LiveNetworkType? classifyInterfaceName(String name) {
  final n = name.toLowerCase();
  if (n.startsWith('en') || n.startsWith('wlan')) {
    return LiveNetworkType.wifi;
  }
  if (n.startsWith('pdp_ip') || n.startsWith('rmnet')) {
    return LiveNetworkType.cellular;
  }
  return null;
}

/// Classify a list of interface names: cellular wins over Wi-Fi
/// when both are present (the stream would use the metered route),
/// Wi-Fi wins over unknown, unknown when nothing classifies.
LiveNetworkType classifyInterfaces(Iterable<String> names) {
  var sawWifi = false;
  for (final name in names) {
    final type = classifyInterfaceName(name);
    if (type == LiveNetworkType.cellular) return LiveNetworkType.cellular;
    if (type == LiveNetworkType.wifi) sawWifi = true;
  }
  return sawWifi ? LiveNetworkType.wifi : LiveNetworkType.unknown;
}

/// Best-effort live detection from the OS interface list. Never
/// throws; any failure reads as [LiveNetworkType.unknown].
Future<LiveNetworkType> detectNetworkType() async {
  try {
    final interfaces = await NetworkInterface.list(
      includeLinkLocal: false,
      type: InternetAddressType.any,
    );
    return classifyInterfaces(interfaces.map((i) => i.name));
  } catch (_) {
    return LiveNetworkType.unknown;
  }
}

/// Cellular ceiling, by label (first match wins): "超清" is the
/// highest mobile-data quality. Labels are matched exactly — a
/// platform that names its tiers differently falls through to the
/// index rule below.
const List<String> _cellularCeilingLabels = ['超清', '高清', '流畅'];

/// Entry-quality index for [qualities] on [network], starting from
/// the user's [preferredIndex]. Wi-Fi / unknown: preferred unchanged.
/// Cellular: capped at the ceiling label when present, else at the
/// middle tier (never the top tier), else the lowest quality.
int entryQualityIndex(
  List<LivePlayQuality> qualities,
  int preferredIndex, {
  required LiveNetworkType network,
}) {
  if (qualities.isEmpty) return 0;
  final preferred = preferredIndex.clamp(0, qualities.length - 1);
  if (network != LiveNetworkType.cellular) return preferred;
  for (final label in _cellularCeilingLabels) {
    final at = qualities.indexWhere((q) => q.quality == label);
    if (at >= 0) return at;
  }
  // No known ceiling label: middle tier (never the top one).
  if (qualities.length >= 3) return (qualities.length / 2).floor();
  return qualities.length - 1;
}

/// Target quality index when the cellular-downgrade switch flips
/// mid-room (b30), or null when no switch is needed. [currentIndex]
/// is the quality now playing; [preferredIndex] is the user's saved
/// preference (what turning the switch OFF restores). Wi-Fi /
/// unknown: null — the downgrade never applies there. Turning it ON
/// caps at the cellular ceiling via [entryQualityIndex] — but never
/// switches UP: a room already below the ceiling (the user manually
/// dropped to 高清) stays put, so the ceiling is a cap, not a
/// target. Turning it OFF restores the preferred quality. Both
/// paths are no-ops when the target already equals the current
/// quality, so a flip that changes nothing never re-opens the stream.
int? cellularDowngradeTargetIndex({
  required List<LivePlayQuality> qualities,
  required int currentIndex,
  required int preferredIndex,
  required LiveNetworkType network,
  required bool enabled,
}) {
  if (qualities.isEmpty) return null;
  if (network != LiveNetworkType.cellular) return null;
  final current = currentIndex.clamp(0, qualities.length - 1);
  final target = enabled
      ? _cellularCeilingIndex(qualities, current)
      : preferredIndex.clamp(0, qualities.length - 1);
  return target == current ? null : target;
}

/// The cellular ceiling as an index, capped at the current index:
/// the ceiling is the highest quality mobile data may use, so a
/// room already at or below it keeps its quality.
int _cellularCeilingIndex(
  List<LivePlayQuality> qualities,
  int currentIndex,
) {
  final ceiling = entryQualityIndex(
    qualities,
    0,
    network: LiveNetworkType.cellular,
  );
  return ceiling > currentIndex ? ceiling : currentIndex;
}

// -- Cellular-downgrade opt-out (build 29, D 组) -------------------------
//
// The downgrade above is automatic at room entry and had no switch:
// a user on an unlimited mobile plan could not keep 原画 on
// cellular. One Hive key, default ON (today's behaviour exactly —
// a fresh install downgrades on cellular until the user turns this
// off in the live settings panel). The room gates the
// entryQualityIndex call on this; the panel is the only writer, and
// there is no settings-page row for it (Settings has no live
// group) — the panel row states the default plainly instead of
// pretending a settings row exists.
const String liveCellularDowngradeKey = 'hao_live_cellular_downgrade';

/// Whether the cellular entry downgrade applies (default true).
bool liveCellularDowngradeEnabled() {
  try {
    return HiveStore.getBool(liveCellularDowngradeKey, true);
  } catch (_) {
    return true;
  }
}

/// Persist the cellular-downgrade choice.
Future<void> saveLiveCellularDowngrade(bool enabled) =>
    HiveStore.put(liveCellularDowngradeKey, enabled);
