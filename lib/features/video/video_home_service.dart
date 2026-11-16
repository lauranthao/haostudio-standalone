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

import '../../core/storage/hive_store.dart';
import '../../services/video/cms_client.dart';
import 'cms_sources.dart';
import 'video_models.dart';

class VideoHomeService {
  VideoHomeService({CmsClient? cms}) : _cms = cms ?? CmsClient();

  final CmsClient _cms;

  /// First-result window 12 s, then 5 s grace for a late result.
  static const Duration firstWindow = Duration(seconds: 12);
  static const Duration lateGrace = Duration(seconds: 5);

  VideoHomeData? loadCached() {
    final raw = HiveStore.box.get(HiveKeys.videoHomeCache);
    if (raw is! String || raw.isEmpty) return null;
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

  /// Fresh home fetch with the 12 s + 5 s windows. Returns null when
  /// nothing usable arrives in time (caller keeps cached data + stale
  /// flag, or shows the error state when nothing was cached).
  Future<VideoHomeData?> fetchFresh() async {
    final pending = _cms.home();
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
    // Grace: a late result may still land within 5 s.
    try {
      result = await pending.timeout(lateGrace);
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
  Future<List<VideoItem>> fetchDaily() async {
    try {
      return await _cms.daily().timeout(
        const Duration(seconds: 12),
        onTimeout: () => <VideoItem>[],
      );
    } catch (_) {
      return <VideoItem>[];
    }
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
