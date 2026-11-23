// Video home service (fix 13).
//
// Port of the web `loadVideoHome` / `fetchVideoHomeOnce` /
// `directVideoHome` behaviour:
// - Render shell + cached data immediately, fetch in background.
// - Per-source race: each category raced against its own 8 s timeout
//   (a slow category yields nothing, it does not block the others).
// - Overall first-result window 12 s plus 5 s grace for a late result.
// - If the fresh fetch fails/times out and cached data was shown, keep
//   the cached data and mark it stale ("内容可能不是最新"); if nothing
//   was cached, the caller shows the error/empty state.
// - Continue Watching history is read locally and must never delay the
//   render; daily recommendations load independently in the background.
// - NO Douban enrichment before first paint.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';

import '../../core/storage/hive_store.dart';
import '../../services/video/cms_client.dart';
import 'cms_sources.dart';
import 'video_models.dart';

class VideoHomeService {
  VideoHomeService({CmsClient? cms}) : _cms = cms ?? CmsClient();

  final CmsClient _cms;

  /// First-result window 9 s (V-P2-1): this used to be 12 s + a 5 s
  /// grace, but `CmsClient.home()` settles on its own 9 s total
  /// budget, so the second window only ever waited on an already
  /// settled future — dead numbers. One 9 s window, no grace.
  static const Duration firstWindow = Duration(seconds: 9);

  /// Freshness window for the Hive home cache (G-P1-1): inside it a
  /// background refresh is skipped — the page was just rebuilt after
  /// a tab switch and the cached rows are still fresh. A forced
  /// refresh (pull-to-refresh / error retry) bypasses it.
  static const Duration cacheFreshTtl = Duration(seconds: 60);

  /// A Hive failure on read must never fail the caller either (same
  /// rule as [_saveCache] on write): no cache is just "no cache".
  /// G-P1-1 made fetchFresh read the cache first, so an uninitialised
  /// / closed box used to throw LateInitializationError out of the
  /// fetch instead of returning fresh data.
  VideoHomeData? loadCached() {
    String? raw;
    try {
      raw = HiveStore.box.get(HiveKeys.videoHomeCache) is String
          ? HiveStore.box.get(HiveKeys.videoHomeCache) as String
          : null;
    } catch (_) {
      return null;
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return VideoHomeData.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  /// Cache persistence must never fail a successful fetch: a Hive
  /// failure (box closed, disk) used to throw out of [fetchFresh]
  /// and turn good data into an error state for the caller.
  Future<void> _saveCache(VideoHomeData data) async {
    try {
      await HiveStore.put(
        HiveKeys.videoHomeCache,
        jsonEncode(data.toJson()),
      );
    } catch (_) {}
  }

  /// Fresh home fetch with the 9 s first-result window. Returns null
  /// when nothing usable arrives in time (caller keeps cached data +
  /// stale flag, or shows the error state when nothing was cached).
  /// [force] skips the fresh-cache shortcut (pull-to-refresh /
  /// error retry are deliberate user actions); [cancelToken] cancels
  /// the in-flight CMS requests on dispose (V-P1-4).
  Future<VideoHomeData?> fetchFresh({
    bool force = false,
    CancelToken? cancelToken,
  }) async {
    if (!force) {
      // G-P1-1: the Hive cache is fresh — the page was just rebuilt
      // after a tab switch. Serve it with no network at all.
      final cached = loadCached();
      if (cached != null &&
          DateTime.now().difference(cached.fetchedAt) < cacheFreshTtl) {
        return cached;
      }
    }
    final pending = _cms.home(cancelToken: cancelToken);
    VideoHomeData? result;
    try {
      result = await pending.timeout(firstWindow);
    } on TimeoutException {
      result = null;
    } catch (_) {
      result = null;
    }
    if (result != null) {
      await _saveCache(result);
      return result;
    }
    return null;
  }

  /// Daily picks, independent background load (returns empty on
  /// failure — never blocks home).
  Future<List<VideoItem>> fetchDaily({CancelToken? cancelToken}) async {
    try {
      return await _cms.daily(cancelToken: cancelToken).timeout(
        const Duration(seconds: 12),
        onTimeout: () => <VideoItem>[],
      );
    } catch (_) {
      return <VideoItem>[];
    }
  }

  /// Re-scan ONE CMS source (I-影视 item 11) — only that source's
  /// rows are re-fetched, nothing else.
  ///
  /// How it stays single-source: the type map is read from its
  /// 10-min cache (no `?ac=list` round-trip when fresh), and only
  /// the types whose PRIMARY entry belongs to [source] are
  /// re-fetched via homeRowOne (one `?ac=videolist` per type, same
  /// as a home load). The refreshed rows replace their same-name
  /// rows in the cached home data in place (order kept); a row
  /// whose re-fetch fails keeps its old items instead of going
  /// blank. The merged data is saved to the Hive home cache, so
  /// the next tab entry renders it with no network.
  ///
  /// Returns the updated home data, or null when there is nothing
  /// to re-scan (no cached home yet — caller falls back to
  /// fetchFresh(force: true) — or this source owns no home row,
  /// e.g. a search-only source, whose rows never appear on home).
  Future<VideoHomeData?> rescanSource(
    VideoSource source, {
    CancelToken? cancelToken,
  }) async {
    final cached = loadCached();
    if (cached == null) return fetchFresh(force: true);
    late final Map<String, CmsTypeEntry> map;
    try {
      map = await _cms.typeMap(cancelToken: cancelToken);
    } catch (_) {
      return null;
    }
    final names = map.entries
        .where((e) => e.value.source.toString() == source.idKey)
        .map((e) => e.key)
        .toList();
    if (names.isEmpty) return null;
    final rows = List<VideoHomeRow>.of(cached.rows);
    var changed = false;
    for (final name in names) {
      VideoHomeRow? fresh;
      try {
        fresh = await _cms.homeRowOne(
          name,
          map[name]!,
          cancelToken: cancelToken,
        );
      } catch (_) {
        fresh = null;
      }
      if (fresh == null) continue;
      final idx = rows.indexWhere((r) => r.name == name);
      if (idx >= 0) {
        rows[idx] = fresh;
      } else {
        rows.add(fresh);
      }
      changed = true;
    }
    if (!changed) return null;
    final updated = VideoHomeData(
      rows: rows,
      fetchedAt: DateTime.now(),
    );
    await _saveCache(updated);
    return updated;
  }

  /// Type names for the category rows (from the cached type map).
  Future<List<String>> typeNames() async {
    try {
      final map = await _cms.typeMap();
      final names = map.keys.toList()
        ..sort((a, b) {
          final ia = kVideoTypePriority.indexOf(a);
          final ib = kVideoTypePriority.indexOf(b);
          if (ia >= 0 && ib >= 0) return ia - ib;
          if (ia >= 0) return -1;
          if (ib >= 0) return 1;
          return 0;
        });
      return names;
    } catch (_) {
      return const [];
    }
  }
}
