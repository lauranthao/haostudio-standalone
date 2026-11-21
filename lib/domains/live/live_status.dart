// Live room online-status check (L01/L03 shared).
//
// Pure Live's follow refresher verifies each room by loading that
// room's own detail (history_refresh / follow_refresher), never by
// "is it on the hot page". This is the Flutter equivalent: one
// `getRoomDetail` per room, with a per-item timeout.
//
// Honesty rules:
// - Timeout or a thrown error -> [LiveStatus.unknown] ("状态未知").
//   Never stale-live: a room is only [LiveStatus.live] when the
//   adapter's fresh detail says so.
// - Caveat: several adapters' UI-path `getRoomDetail` swallows a
//   transient failure and returns the room as offline (their
//   established contract — a failure must not blank the card). Such a
//   failure therefore reads as [LiveStatus.offline], not unknown.
//   Only a timeout / throw surfaces as unknown.

import '../../core/models/live_models.dart';
import '../../shared/platforms/live_site.dart';
import '../../shared/platforms/sites.dart';

/// Online status of one room after a refresh.
enum LiveStatus {
  /// The adapter's fresh detail says the room is live.
  live,

  /// The adapter's fresh detail says the room is offline.
  offline,

  /// The check timed out or threw — status could not be determined.
  unknown,
}

/// Display name for a platform id; falls back to the id itself for
/// unknown ids (never throws — history/follow entries may outlive a
/// platform's adapter).
String platformName(String id) {
  if (!Sites.isSupported(id)) return id;
  try {
    return Sites.of(id).name;
  } catch (_) {
    return id;
  }
}

/// Re-check the live status of each room in [rooms], keyed by
/// `platform|roomId`. Each room is checked independently with a
/// [perItemTimeout]; a slow room never blocks the others (checks run
/// concurrently via Future.wait).
Future<Map<String, LiveStatus>> refreshRoomStatuses(
  List<LiveRoom> rooms, {
  LiveSite Function(String platformId)? siteOf,
  Duration perItemTimeout = const Duration(seconds: 8),
}) async {
  final withWatching = await refreshRoomStatusesWithWatching(
    rooms,
    siteOf: siteOf,
    perItemTimeout: perItemTimeout,
  );
  return withWatching.map((k, v) => MapEntry(k, v.status));
}

/// Same check as [refreshRoomStatuses], but each entry also carries
/// the room's watching count from the same fresh detail (B-P1-1:
/// the follow card's watching pill needs the number — the detail
/// was already fetched for the status, so it costs no extra request).
/// Watching is 0 when the room is offline or the check failed.
Future<Map<String, ({LiveStatus status, int watching})>>
    refreshRoomStatusesWithWatching(
  List<LiveRoom> rooms, {
  LiveSite Function(String platformId)? siteOf,
  Duration perItemTimeout = const Duration(seconds: 8),
}) async {
  final resolve = siteOf ?? Sites.of;
  final results = await Future.wait(
    rooms.map((room) async {
      final key = '${room.platform}|${room.roomId}';
      try {
        final site = resolve(room.platform);
        final detail = await site
            .getRoomDetail(room)
            .timeout(perItemTimeout);
        return MapEntry(
          key,
          (
            status: detail.liveStatus ? LiveStatus.live : LiveStatus.offline,
            watching: detail.watching,
          ),
        );
      } catch (_) {
        return MapEntry(
          key,
          (status: LiveStatus.unknown, watching: 0),
        );
      }
    }),
  );
  return Map.fromEntries(results);
}
