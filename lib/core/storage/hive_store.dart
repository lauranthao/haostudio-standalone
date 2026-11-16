// HAo Studio local storage — Hive, single `app_settings` box.
//
// Mirrors Pure Live's HivePrefUtil shape (one box, typed helpers), without
// its GetX/Rx persistence layer: values are read at startup and written
// explicitly. Settings keys follow Pure Live where the setting is ported
// (videoPlayerKey, preferResolution, preferResolutionCellular).

import 'package:flutter/foundation.dart';
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

  /// Test-only: point the store at an opened test box instead of the
  /// real `app_settings` box. Never used in production code.
  @visibleForTesting
  static void setTestBox(Box<dynamic> box) {
    _box = box;
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
  static const String musicFav = 'hao_fav'; // [{key, song?}] — full Song
  // JSON is stored with each favourite (M-P0-7) so the favourites page
  // can list songs; legacy key-only entries ({key} only) still read.
  static const String musicRecent = 'hao_recent'; // [Song] max 100
  static const String musicListen = 'hao_listen'; // [ListenEvent] max 3000
  static const String musicPlazaPf = 'musicPlazaPf'; // 'wy' default
  static const String musicVolume = 'musicVolume'; // double 0..1
  static const String musicSpeed = 'musicSpeed'; // double 0.6..2.0, default 1.0 (M-P0-2)
  static const String musicQueue = 'musicQueue'; // {songs: [Song], index: int} (M-P0-4)
  static const String musicDownloads = 'musicDownloads'; // [DownloadedSong] (M-P0-5)
  static const String musicResume = 'musicResume'; // {identityKey: seconds}
  static const String musicCurListId = 'curListId';
  static const String musicPlayMode = 'playMode'; // 'seq' | 'loop' | 'one' | 'shuffle' | 'once'

  /// Daily-picks cache key for a day (`hao_daily_YYYY-MM-DD`).
  static String musicDailyKey(String dayKey) => 'hao_daily_$dayKey';

  /// VOD auto-play next episode (`hao_video_auto_next`): bool,
  /// default true. When off, playback stops at the end of the
  /// episode (end state, no advance). Read by the native VOD player
  /// on completion and by the settings toggle.
  static const String videoAutoNext = 'hao_video_auto_next';
  static const String vodPlaybackRate = 'hao_vod_playback_rate';

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

  /// Last applied CMS defaults revision (`hao_sa_video_rev`): when
  /// defaults change (new source / re-prioritised sorts), the store
  /// merges missing defaults into the persisted list once per
  /// revision, so a source the user deliberately deleted is never
  /// resurrected by a later load.
  static const String videoSourcesRevision = 'hao_sa_video_rev';

  /// Music search sources (`hao_music_sources`): JSON list of enabled
  /// platform codes from kSearchPlatforms (wy/tx/kg/kw). Defaults
  /// apply when absent. At least one must remain enabled.
  static const String musicSources = 'hao_music_sources';

  /// Live sources (`hao_live_sources`): JSON list of enabled live
  /// site ids (bilibili/douyu/huya/douyin/kuaishou). Defaults apply
  /// when absent. At least one must remain enabled.
  static const String liveSources = 'hao_live_sources';

  /// Live watch history (L01, `hao_live_hist`): JSON list of
  /// LiveHistoryEntry, most recent first, default max 50.
  static const String liveHistory = 'hao_live_hist';

  /// Live history limit (`hao_live_hist_limit`): int, 0 = unlimited,
  /// default 50. Mirrors the video-history limit pattern.
  static const String liveHistoryLimit = 'hao_live_hist_limit';

  /// Live follows (L03, `hao_live_follows`): JSON list of LiveFollow,
  /// most recently followed first. NOTE: no follow store existed in
  /// the Flutter app before L03 — this is the first one (the web app's
  /// flat follow list was never ported).
  static const String liveFollows = 'hao_live_follows';

  /// Danmaku settings (settings page persists; the live room reads
  /// them once its danmaku wiring lands — see DanmakuSettings).
  /// Per-platform enable map: JSON {siteId: bool}.
  static const String danmakuEnabled = 'hao_danmaku_enabled';

  /// Danmaku list font size (double, 12..20, default 14).
  static const String danmakuFontSize = 'hao_danmaku_font_size';

  /// Danmaku block list (S3/S4, `hao_dm_block`): JSON list of
  /// {id, text, kind} where kind is 'word' (keyword, substring match
  /// on the message) or 'user' (username, substring match). Same
  /// shape and match semantics as the web app's `hao_dm_block`.
  static const String danmakuBlockList = 'hao_dm_block';

  /// Danmaku chat-list style (S2, `hao_danmaku_list_style`):
  /// 'compact' (one line per message, default) or 'card'.
  static const String danmakuListStyle = 'hao_danmaku_list_style';

  /// Danmaku chat-list line spacing (S2, `hao_danmaku_list_spacing`):
  /// 'compact' | 'standard' (default) | 'loose'. Mirrors Pure Live's
  /// ChatSpacing (gaps halved / as-is / x1.5; text height 1.4 / theme
  /// default / 1.7).
  static const String danmakuListSpacing = 'hao_danmaku_list_spacing';

  /// Show the sender name in the danmaku chat list (S2,
  /// `hao_danmaku_show_names`): bool, default true.
  static const String danmakuShowUsernames = 'hao_danmaku_show_names';

  /// Similarity filter on/off (S3, `hao_danmaku_similarity`): bool,
  /// default true (this app's choice — Pure Live defaults it off).
  static const String danmakuSimilarityEnabled = 'hao_danmaku_similarity';

  /// Similarity threshold (S3, `hao_danmaku_similarity_threshold`):
  /// int 0..100 (partial-ratio score), default 85 (Pure Live's
  /// default).
  static const String danmakuSimilarityThreshold =
      'hao_danmaku_similarity_threshold';

  /// Block pure-emoji danmaku (S3, `hao_danmaku_block_emote`): bool,
  /// default false.
  static const String danmakuBlockEmoteOnly = 'hao_danmaku_block_emote';

  /// Block overlong danmaku (S3, `hao_danmaku_block_long`): bool,
  /// default false.
  static const String danmakuBlockLong = 'hao_danmaku_block_long';

  /// Overlong length limit in characters (S3,
  /// `hao_danmaku_block_long_len`): int 10..100, default 30 (Pure
  /// Live's default).
  static const String danmakuBlockLongLength = 'hao_danmaku_block_long_len';

  /// Douyu suspected-automated-message filter (S3,
  /// `hao_danmaku_douyu_bot`): bool, default false. Hides Douyu
  /// chatmsg packets Pure Live tags as suspected automated
  /// (no `dms` field and `if` != '1'); other platforms unaffected.
  static const String danmakuDouyuBotFilter = 'hao_danmaku_douyu_bot';

  /// LX script sources (M-P0-6): disabled script ids (`hao_lx_disabled`,
  /// JSON list; absent = all enabled), user-added custom scripts
  /// (`hao_lx_custom`, JSON list of {id, name, url, code, addedAt}) and
  /// deleted bundled script ids (`hao_lx_deleted_bundled`, JSON list).
  /// A deleted bundled script is never re-seeded or loaded again.
  /// Scripts are additive to the built-in resolvers — no "at least one"
  /// guard, unlike the platform source groups.
  static const String lxScriptDisabled = 'hao_lx_disabled';
  static const String lxCustomScripts = 'hao_lx_custom';
  static const String lxDeletedBundledScripts = 'hao_lx_deleted_bundled';

  /// Danmaku list text opacity (double, 0.3..1.0, default 1.0).
  static const String danmakuOpacity = 'hao_danmaku_opacity';
}
