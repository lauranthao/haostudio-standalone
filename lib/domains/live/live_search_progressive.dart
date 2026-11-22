// ignore_for_file: prefer_initializing_formals
// Progressive live search — item 2 (build 29, I group).
//
// The old search page searched ONE platform at a time with a 20 s
// all-or-nothing timeout: a slow platform held the whole page, and
// switching platforms re-ran the query from scratch.
//
// New behaviour:
// - One query fans out to every enabled platform concurrently.
// - Each platform resolves on its own: results appear the moment
//   that platform answers (progressive display), a platform that
//   throws or exceeds [perPlatformTimeout] (12 s) fails alone and
//   never blocks the others.
// - Results merge with dedupe by `platform|roomId` (the same room
//   must never show twice); a later query's generation guard stops
//   stale results overwriting the new query.
// - The page is done when every platform has resolved or failed;
//   the error state only shows when ALL platforms failed AND
//   nothing was found.
//
// The orchestrator is pure Dart (search function + clock injected)
// so the rules are unit-testable without a page.

import 'dart:async';

import '../../core/models/live_models.dart';

/// One platform's outcome inside a progressive search.
class LivePlatformSearchResult {
  const LivePlatformSearchResult({
    required this.platform,
    required this.rooms,
    required this.failed,
  });

  final String platform;
  final List<LiveRoom> rooms;

  /// True when this platform threw or timed out (its absence is
  /// honest, not an empty result).
  final bool failed;
}

/// Progressive multi-platform search. [search] is called once per
/// platform, concurrently; each call gets its own [perPlatformTimeout]
/// (default 12 s). [onPlatformDone] fires per platform as it resolves
/// (success or failure) so the page can display results progressively.
/// The returned future completes when every platform has resolved or
/// failed, with the merged, deduped room list.
class LiveProgressiveSearch {
  LiveProgressiveSearch({
    required Future<List<LiveRoom>> Function(String platform, String keyword)
    search,
    Duration perPlatformTimeout = const Duration(seconds: 12),
  }) : _search = search,
       _perPlatformTimeout = perPlatformTimeout;

  final Future<List<LiveRoom>> Function(String platform, String keyword)
  _search;
  final Duration _perPlatformTimeout;

  /// Run [keyword] on [platforms] concurrently. [generation] guards
  /// staleness: when it changes mid-flight, late platform results are
  /// dropped (the [onPlatformDone] callback is not invoked for them).
  /// Pass a `() => currentGeneration` reader; when null, no guard.
  Future<List<LiveRoom>> run(
    String keyword,
    List<String> platforms, {
    required void Function(LivePlatformSearchResult result) onPlatformDone,
    int Function()? generation,
  }) async {
    final seen = <String>{};
    final merged = <LiveRoom>[];
    final genAtStart = generation?.call();
    void emit(LivePlatformSearchResult result) {
      if (generation != null && generation() != genAtStart) return;
      onPlatformDone(result);
    }

    await Future.wait(
      platforms.map((platform) async {
        List<LiveRoom> rooms;
        var failed = false;
        try {
          rooms = await _search(
            platform,
            keyword,
          ).timeout(_perPlatformTimeout);
        } catch (_) {
          rooms = const [];
          failed = true;
        }
        if (generation != null && generation() != genAtStart) return;
        for (final room in rooms) {
          if (seen.add('${room.platform}|${room.roomId}')) {
            merged.add(room);
          }
        }
        emit(
          LivePlatformSearchResult(
            platform: platform,
            rooms: rooms,
            failed: failed,
          ),
        );
      }),
    );
    return merged;
  }
}

/// "包含未开播" filter (pure): when [includeOffline] is false, only
/// rooms whose [LiveRoom.liveStatus] is true are kept. Default true
/// (old behaviour showed offline rooms too).
List<LiveRoom> applyOfflineFilter(
  List<LiveRoom> rooms, {
  required bool includeOffline,
}) {
  if (includeOffline) return rooms;
  return rooms.where((r) => r.liveStatus).toList();
}
