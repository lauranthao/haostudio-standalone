// HAo Studio local storage — Hive, single `app_settings` box.
//
// Mirrors Pure Live's HivePrefUtil shape (one box, typed helpers), without
// its GetX/Rx persistence layer: values are read at startup and written
// explicitly. Settings keys follow Pure Live where the setting is ported
// (videoPlayerKey, preferResolution).

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

  /// Player-engine section expanded state on the settings page:
  /// bool, default false (collapsed). Persisted across restarts.
  static const String engineSectionExpanded = 'engineSectionExpanded';

  /// Haptic feedback master switch (Beans `BeansHaptics.enabledKey`,
  /// `beans.haptics.enabled`, default true). Every haptic call in the
  /// app goes through [HaoHaptics], which reads this key first.
  static const String hapticsEnabled = 'hapticsEnabled';

  /// "与其他音频同时播放" (Beans `beans.audio.mixothers.v1`,
  /// default false). Applied to AVAudioSession by
  /// [AvMusicPlayer.applyMixWithOthers].
  static const String audioMixWithOthers = 'audioMixWithOthers';

  /// "启动时自动播放上次歌曲" (Beans
  /// `beans.playback.autoResumeLast`, default false). Only reads the
  /// resume map that is saved on app kill — it never changes the
  /// "杀后台才存进度" rule.
  static const String autoResumeLastPlayback = 'autoResumeLastPlayback';

  /// Playback-settings section expanded state on the settings page:
  /// bool, default false (collapsed). Same pattern as
  /// [engineSectionExpanded].
  static const String playbackSectionExpanded = 'playbackSectionExpanded';

  /// Preferred quality (all networks — there is no separate
  /// cellular preference: the key for one was defined but never read,
  /// written or shown, so it was deleted rather than left dead).
  /// Default '原画'.
  static const String preferResolution = 'preferResolution';

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
  static const String musicSearchHist = 'hao_music_search_hist'; // [String] max 20
  static const String musicCoverCache = 'hao_cover_cache'; // {normTitle|normArtist: coverUrl} max 500
  static const String musicPlazaPf = 'musicPlazaPf'; // 'wy' default
  static const String musicSpeed = 'musicSpeed'; // double 0.6..2.0, default 1.0 (M-P0-2)
  static const String musicQueue = 'musicQueue'; // {songs: [Song], index: int} (M-P0-4)
  static const String musicDownloads = 'musicDownloads'; // [DownloadedSong] (M-P0-5)
  static const String musicResume = 'musicResume'; // {identityKey: seconds}
  static const String musicCurListId = 'curListId';
  static const String musicPlayMode = 'playMode'; // 'seq' | 'loop' | 'one' | 'shuffle' | 'once'

  /// Music home section expanded states (我的歌单 / 最近播放): bool,
  /// default true (expanded). Persisted so a collapse survives tab
  /// switches (the PageView drops the music page State when you go 2
  /// tabs away) and restarts. Same pattern as
  /// [playbackSectionExpanded].
  static const String musicPlaylistsExpanded = 'musicPlaylistsExpanded';
  static const String musicRecentExpanded = 'musicRecentExpanded';

  /// Personal FM disliked song identityKeys (never recommend again).
  static const String fmDislikedIds = 'fmDislikedIds';

  /// Daily-picks cache key for a day (`hao_daily_YYYY-MM-DD`).
  static String musicDailyKey(String dayKey) => 'hao_daily_$dayKey';

  /// First-cover URLs for the music-home feature cards (plaza /
  /// charts), cached so the home never re-fetches them on open.
  /// The report card needs no key — it is computed live from the
  /// local listen log on every build.
  static const String featureCoverPlaza = 'hao_feature_cover_plaza';
  static const String featureCoverCharts = 'hao_feature_cover_charts';

  /// Sleep timer custom minutes (stage 2, Beans `SleepTimerSheet`
  /// customMinutesText, clamped 1..720, default 30). Persisted so the
  /// next open remembers the last custom value.
  static const String musicSleepCustomMinutes = 'musicSleepCustomMinutes';

  /// Single search platform capsule (stage 2, Beans `SearchView`
  /// provider / `RootView` PlatformPickerSheet): 'wy' | 'tx' | 'kg' |
  /// 'kw', default 'wy'. No 'all' option — one platform at a time.
  static const String musicSearchPlatform = 'musicSearchPlatform';

  /// Local audio files (stage 2): JSON list of Song (with localPath
  /// as a RELATIVE name `local_music/<file>`), newest first. Files
  /// live in app docs `local_music/`.
  static const String musicLocalFiles = 'hao_local_music';

  /// Wallpaper (stage 2, Beans `ThemeStore` wallpaperPaths /
  /// backgroundImagePath): enabled flag, JSON list of RELATIVE names
  /// (`wallpapers/<file>`), current path (relative). Files live in
  /// app docs `wallpapers/`.
  static const String wallpaperEnabled = 'hao_wallpaper_enabled';
  static const String wallpaperPaths = 'hao_wallpaper_paths';
  static const String wallpaperCurrent = 'hao_wallpaper_current';

  /// Custom background colour (stage 2, Beans `ThemeStore`
  /// backgroundHexLight/Dark, single value here — see
  /// AppearanceStore): enabled flag + '#RRGGBB' hex ('' = none).
  static const String bgColorEnabled = 'hao_bgcolor_enabled';
  static const String bgColorHex = 'hao_bgcolor_hex';

  /// Tab-bar selected colour (icon + label of the selected tab),
  /// user-chosen in settings → 自定义强调色. Int ARGB, stored with
  /// its opacity; default NetEase red (see TabBarAccentController).
  /// Only the tab-bar selected state reads it — nothing else.
  static const String tabBarAccentColor = 'hao_tabbar_accent';

  /// Custom accent-colour presets (user-added via the colour
  /// sheet's + button): `List<int>` ARGB, in the order added. The 5
  /// defaults (black/blue/green/yellow/red) are built in, not
  /// stored — only customs persist here.
  static const String tabBarAccentPresets = 'hao_tabbar_accent_presets';

  /// Custom font (stage 2, Beans `FontManager`): registered family
  /// name ('HaoCustomFont' when installed, '' = system default),
  /// the installed file's display name, and its RELATIVE path
  /// (`fonts/<file>`).
  static const String customFontFamily = 'hao_custom_font_family';
  static const String customFontName = 'hao_custom_font_name';
  static const String customFontPath = 'hao_custom_font_path';

  /// VOD auto-play next episode (`hao_video_auto_next`): bool,
  /// default true. When off, playback stops at the end of the
  /// episode (end state, no advance). Read by the native VOD player
  /// on completion and by the settings toggle.
  static const String videoAutoNext = 'hao_video_auto_next';
  static const String vodPlaybackRate = 'hao_vod_playback_rate';

  /// VOD picture fit (`hao_vod_video_fit`): 'auto' | 'fill' | 'cover',
  /// default 'auto' (contain). PiliPlus VideoFitType + Kazumi
  /// PlayerAspectRatio intersection — see `VideoFitMode`.
  static const String vodVideoFit = 'hao_vod_video_fit';

  /// Kazumi low-memory mode (`hao_low_memory_mode`): 'auto' |
  /// 'always' | 'never', default 'auto'. See `LowMemoryMode`.
  static const String lowMemoryMode = 'hao_low_memory_mode';

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

  /// Live search history (`hao_live_search_hist`): JSON list of
  /// keywords, most recent first, max 20. Mirrors the video/music
  /// search-history pattern (VideoHistoryStore / MusicStore).
  static const String liveSearchHist = 'hao_live_search_hist';

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
  /// (`hao_lx_custom`, JSON list of {id, name, url, code, addedAt}),
  /// deleted bundled script ids (`hao_lx_deleted_bundled`, JSON list)
  /// and the manual script order (`hao_lx_order`, JSON list of script
  /// ids in the user's drag order, first = tried first among LX
  /// script jobs; chen 2026-11-18).
  /// A deleted bundled script is never re-seeded or loaded again.
  /// Scripts are additive to the built-in resolvers — no "at least one"
  /// guard, unlike the platform source groups.
  static const String lxScriptDisabled = 'hao_lx_disabled';
  static const String lxScriptExplicitlyEnabled = 'hao_lx_explicit_enabled';
  static const String lxCustomScripts = 'hao_lx_custom';
  static const String lxDeletedBundledScripts = 'hao_lx_deleted_bundled';
  static const String lxScriptOrder = 'hao_lx_order';

  /// Danmaku list text opacity (double, 0.3..1.0, default 1.0).
  static const String danmakuOpacity = 'hao_danmaku_opacity';

  /// Fullscreen floating-danmaku area (`hao_danmaku_area`): 'full'
  /// (whole video, default) | 'half' (top half) | 'third' (top third).
  /// The live room maps it to the flame_barrage BarrageConfig.area
  /// fraction; see DanmakuSettings.
  static const String danmakuArea = 'hao_danmaku_area';

  /// Equalizer (stage 3, Beans `BeansEqualizer` UserDefaults keys
  /// `beans.equalizer.*`): enabled bool (default false), 10 band gains
  /// in dB as a 10-item double list (default all 0), selected preset id
  /// (default 'flat'), selected custom preset name ('' = none), preamp
  /// gain in dB (default 0), custom presets as JSON list of
  /// {name, gains[10], preamp}. Persisted in Hive; the native tap
  /// engine is pushed the same values over the equalizer method
  /// channel on every change (see EqualizerStore).
  static const String equalizerEnabled = 'hao_eq_enabled';
  static const String equalizerBandGains = 'hao_eq_band_gains';
  static const String equalizerPreset = 'hao_eq_preset';
  static const String equalizerCustomPresetName = 'hao_eq_custom_name';
  static const String equalizerPreamp = 'hao_eq_preamp';
  static const String equalizerCustomPresets = 'hao_eq_custom_presets';
}
