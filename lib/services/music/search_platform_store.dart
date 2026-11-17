// Single search platform (stage 2, Beans `SearchView` provider /
// `RootView` PlatformPickerSheet).
//
// Beans: one provider at a time (netease / qq / kugou — `SearchView`
// providerPicker, SearchView.swift:343-380, and the
// PlatformPickerSheet, RootView.swift:463-530); the choice is stored
// in `@AppStorage("beans.search.provider")` and survives restarts.
// There is NO "all platforms" option in Beans' search, and there is
// none here either: song / album / playlist / artist search, the hot
// words, the plaza and the charts all read this one platform.
//
// The capsule only offers platforms the user still has enabled in
// 音源管理 ([MusicSourcesStore.enabled]) — Beans' picker likewise
// iterates `platformPrefs.enabledSearchProviders`. If the stored
// platform was disabled afterwards, [current] falls back to the
// first enabled platform (never to a disabled one, never to "all").
//
// This store controls the SEARCH/DISCOVER display scope only. Playback
// resolving is untouched: the resolver still asks all sources serially
// and plays the first playable URL (chen's 铁律).

import '../../core/storage/hive_store.dart';
import '../../features/settings/source_stores.dart';
import 'music_models.dart';

class SearchPlatformStore {
  SearchPlatformStore._();

  /// Platforms the capsule can offer, in merge order wy/tx/kg/kw,
  /// restricted to what is still enabled in 音源管理.
  static List<MusicPlatform> options() {
    final enabled = MusicSourcesStore.enabled();
    final list =
        kSearchPlatforms.where((p) => enabled.contains(p)).toList();
    return list.isEmpty ? [MusicPlatform.wy] : list;
  }

  /// Current platform (Hive `musicSearchPlatform`, default wy).
  /// Falls back to the first offered platform when the stored value
  /// is unknown or no longer enabled. Never throws: before Hive is
  /// initialised (or in a test without a box) it reports wy.
  static MusicPlatform current() {
    String stored = 'wy';
    try {
      stored = HiveStore.getString(HiveKeys.musicSearchPlatform, 'wy');
    } catch (_) {}
    final parsed = MusicPlatformX.fromCode(stored);
    final opts = options();
    return opts.contains(parsed) ? parsed : opts.first;
  }

  /// Persist the capsule choice. Returns false (and writes nothing)
  /// when [pf] is not offered (e.g. disabled in 音源管理, or mg
  /// which has no search at all) or the box is unavailable.
  static Future<bool> set(MusicPlatform pf) async {
    if (!options().contains(pf)) return false;
    try {
      await HiveStore.put(HiveKeys.musicSearchPlatform, pf.code);
    } catch (_) {
      return false;
    }
    return true;
  }
}
