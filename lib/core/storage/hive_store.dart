// HAo Studio local storage — Hive, single `app_settings` box.
//
// Mirrors Pure Live's HivePrefUtil shape (one box, typed helpers), without
// its GetX/Rx persistence layer: values are read at startup and written
// explicitly. Settings keys follow Pure Live where the setting is ported
// (videoPlayerKey, preferResolution, preferResolutionCellular).

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

class HiveStore {
  HiveStore._();

  static const String boxName = 'app_settings';

  static late Box<dynamic> _box;

  /// Must be called before runApp (see main.dart).
  static Future<void> init() async {
    await Hive.initFlutter();
    _box = await Hive.openBox<dynamic>(boxName);
  }

  static Box<dynamic> get box => _box;

  static String getString(String key, String defaultValue) =>
      _box.get(key) as String? ?? defaultValue;

  static int getInt(String key, int defaultValue) =>
      _box.get(key) as int? ?? defaultValue;

  static bool getBool(String key, bool defaultValue) =>
      _box.get(key) as bool? ?? defaultValue;

  static double getDouble(String key, double defaultValue) =>
      (_box.get(key) as num?)?.toDouble() ?? defaultValue;

  static Future<void> put(String key, Object? value) => _box.put(key, value);

  static Future<void> delete(String key) => _box.delete(key);
}

/// Hive keys ported from Pure Live (player_settings_controller.dart).
class HiveKeys {
  HiveKeys._();

  /// Preferred player engine key: 'mpv' | 'ijk' | 'exo'. Default 'mpv'.
  static const String videoPlayerKey = 'videoPlayerKey';

  /// Preferred quality (Wi-Fi) / cellular. Default '原画'.
  static const String preferResolution = 'preferResolution';
  static const String preferResolutionCellular = 'preferResolutionCellular';

  /// Last live crash breadcrumb stage (fix 1). Empty = no record.
  static const String liveCrashStage = 'liveCrashStage';

  /// Online-update state (fix 8).
  static const String skippedVersion = 'skippedVersion';
  static const String knownUpdateVersion = 'knownUpdateVersion';
  static const String lastUpdateCheckAt = 'lastUpdateCheckAt';

  /// Music (v1.0.4 music port). Values are JSON strings unless noted.
  /// Durations are stored in SECONDS (audit P0-3).
  static const String musicQuality = 'musicQuality'; // 'hires' default
  static const String musicLists = 'hao_lists'; // [UserPlaylist]
  static const String musicFav = 'hao_fav'; // ['wy|songId', ...]
  static const String musicRecent = 'hao_recent'; // [Song] max 100
  static const String musicListen = 'hao_listen'; // [ListenEvent] max 3000
  static const String musicPlazaPf = 'musicPlazaPf'; // 'wy' default
  static const String musicVolume = 'musicVolume'; // double 0..1
  static const String musicResume = 'musicResume'; // {identityKey: seconds}
  static const String musicCurListId = 'curListId';
  static const String musicPlayMode = 'playMode'; // 'seq' | 'shuffle'

  /// Daily-picks cache key for a day (`hao_daily_YYYY-MM-DD`).
  static String musicDailyKey(String dayKey) => 'hao_daily_$dayKey';

  /// Video home cache (fix 13): cached home rows JSON, rendered
  /// immediately while fresh data loads in the background.
  static const String videoHomeCache = 'hao_video_home';

  /// Video watch history (`hao_video_hist`): JSON list of
  /// WatchHistoryEntry, most recent first, max 20.
  static const String videoHistory = 'hao_video_hist';

  /// Video favourites (`hao_video_fav`): JSON list of VideoItem.
  static const String videoFavs = 'hao_video_fav';

  /// Video search history: JSON list of query strings, max 20.
  static const String videoSearchHist = 'hao_video_search_hist';

  /// Per-video resume: key prefix `haoVodProg:<source>:<vodId>`
  /// (position only counts when > 10 s in and >= 30 s from the end).
  static const String videoResumePrefix = 'haoVodProg:';

  /// Douban caches (permanent, 200-entry cap): detail by id +
  /// title→id map. Suggest-disable flag after 3 consecutive failures.
  static const String doubanDetail = 'hao_douban_detail';
  static const String doubanIdmap = 'hao_douban_idmap';
  static const String doubanNoSuggest = 'hao_douban_no_suggest';

  /// Video source list override (`hao_sa_video`): JSON list of
  /// VideoSource; defaults apply when absent. At least one video
  /// source must remain (delete guard).
  static const String videoSources = 'hao_sa_video';

  /// Music search sources (`hao_music_sources`): JSON list of enabled
  /// platform codes from kSearchPlatforms (wy/tx/kg/kw). Defaults
  /// apply when absent. At least one must remain enabled.
  static const String musicSources = 'hao_music_sources';

  /// Live sources (`hao_live_sources`): JSON list of enabled live
  /// site ids (bilibili/douyu/huya/douyin/kuaishou). Defaults apply
  /// when absent. At least one must remain enabled.
  static const String liveSources = 'hao_live_sources';

  /// Danmaku settings (settings page persists; the live room reads
  /// them once its danmaku wiring lands — see DanmakuSettings).
  /// Per-platform enable map: JSON {siteId: bool}.
  static const String danmakuEnabled = 'hao_danmaku_enabled';

  /// Danmaku list font size (double, 12..20, default 14).
  static const String danmakuFontSize = 'hao_danmaku_font_size';

  /// Danmaku list text opacity (double, 0.3..1.0, default 1.0).
  static const String danmakuOpacity = 'hao_danmaku_opacity';
}
