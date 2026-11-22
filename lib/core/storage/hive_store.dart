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
  ///
  /// [path] is test-only: point Hive at a temp directory instead of
  /// the app documents dir. Production always calls init() with no
  /// args.
  static Future<void> init({String? path}) async {
    if (path != null) {
      Hive.init(path);
    } else {
      await Hive.initFlutter();
    }
    try {
      _box = await Hive.openBox<dynamic>(boxName);
    } catch (e) {
      // Corrupted box (a previous crash killed the app mid-write):
      // without this, main() throws before runApp and the app crashes
      // on EVERY launch until the data is wiped. Drop the box files
      // and reopen fresh — settings are lost, the app starts.
      debugPrint('HiveStore: box corrupt ($e), rebuilding $boxName');
      try {
        await Hive.deleteBoxFromDisk(boxName);
      } catch (_) {}
      _box = await Hive.openBox<dynamic>(boxName);
    }
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

  /// Preferred quality (all networks — there is no separate
  /// cellular preference: the key for one was defined but never read,
  /// written or shown, so it was deleted rather than left dead).
  /// Default '原画'.
  static const String preferResolution = 'preferResolution';

  /// Last live crash breadcrumb stage (fix 1). Empty = no record.
  static const String liveCrashStage = 'liveCrashStage';

  /// Online-update state (fix 8).
  static const String skippedVersion = 'skippedVersion';
  static const String lastUpdateCheckAt = 'lastUpdateCheckAt';

  /// "启动时自动检查更新" (build 28): bool, default true.
  /// Gates only the automatic check in main.dart warm-up;
  /// the manual check in Settings is never gated.
  static const String autoUpdateCheck = 'autoUpdateCheck';

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
  static const String musicLyrics = 'hao_lyrics'; // {identityKey: [LyricLine]} max 100 (P1-P7)
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
  /// tabs away) and restarts.
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

  /// Volume normalization (1.1.6, strategy A): bool, default false.
  /// Attenuation-only per-track gain, measured during playback in
  /// the EQ tap, takes effect from the second play of the same
  /// track. Never boosts, never pre-downloads for loudness.
  static const String musicNormalizationEnabled =
      'hao_music_normalization_enabled';

  /// Volume normalization strength (1.1.6): int 0..2, default 1.
  /// Three attenuation levels around the -14 LUFS target.
  static const String musicNormalizationStrength =
      'hao_music_normalization_strength';

  /// Music bookmarks (1.1.6): {identityKey: [{position, label,
  /// createdAt}]} — multiple bookmarks per song, local only.
  static const String musicBookmarks = 'hao_music_bookmarks';

  /// Measured loudness cache (1.1.6): {identityKey: LUFS double} —
  /// written by the EQ tap measurement, read by normalization on the
  /// next play (second-play effect). No pre-download, no server.
  static const String musicLoudnessCache = 'hao_music_loudness_cache';

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

  /// One-time v1.1.5 migration flag (see
  /// AppearanceStore.migrateWallpaperOffOnce): true once the stored
  /// wallpaper-on has been turned off once, so a later user choice
  /// is never overridden.
  static const String wallpaperV115Migration = 'hao_wallpaper_v115_off_once';

  /// Custom background colour (stage 2, Beans `ThemeStore`
  /// backgroundHexLight/Dark, single value here — see
  /// AppearanceStore): enabled flag + '#RRGGBB' hex ('' = none).
  static const String bgColorEnabled = 'hao_bgcolor_enabled';
  static const String bgColorHex = 'hao_bgcolor_hex';

  /// Tab-bar selected colour (icon + label of the selected tab),
  /// user-chosen in settings → 自定义强调色. Int ARGB, stored with
  /// its opacity; absent = no custom colour, the theme's own accent
  /// shows (see TabBarAccentController).
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

  /// I-影视 (build 29): one key per new VOD feature, each read in
  /// exactly one place (vod_features.dart) and written only from
  /// Settings → 影视播放 (or the player toggle that owns the same
  /// key — never a second key for the same switch). All default
  /// OFF (or the neutral value) so no existing default behaviour
  /// changes: a fresh install plays exactly like build 28 until
  /// the user turns something on.
  ///
  /// 1. 双击快进秒数: int, default 10, options 5/10/15/30/60.
  static const String vodDoubleTapSeekSeconds =
      'hao_vod_double_tap_seconds';

  /// 3. 对白增强: bool, default false. UI/logic/prefs only — the
  /// mpv `volume-max=300` + centre-channel cap is K 组's
  /// (mpv_backend.dart); this key only gates
  /// PlaybackSession.setDialogueBoost, which no-ops on backends
  /// without the DialogueBoostCapableBackend capability.
  static const String vodDialogueBoost = 'hao_vod_dialogue_boost';

  /// 5. 防剧透: hide the synopsis / blur the cover poster of
  /// unwatched titles on the detail page. Both bool, default false.
  static const String vodSpoilerHideSynopsis =
      'hao_vod_spoiler_hide_synopsis';
  static const String vodSpoilerBlurUnwatched =
      'hao_vod_spoiler_blur_unwatched';

  /// 9. 纯音频后台模式 default: bool, default false. The player
  /// toggle writes this same key; the next open reads it.
  static const String vodAudioOnly = 'hao_vod_audio_only';

  /// 8. VOD sleep timer: custom minutes (int 1..720, default 30)
  /// and "播完 N 集" count (int 1..10, default 3). Same clamps as
  /// the music timer (SleepTimer) — the state machine is shared,
  /// only the persisted values are separate keys.
  static const String vodSleepCustomMinutes =
      'hao_vod_sleep_custom_minutes';
  static const String vodSleepEpisodeCount = 'hao_vod_sleep_episode_count';

  /// 4. 元数据手动纠错: JSON map `'<source>|<vodId>'` →
  /// `{title?, year?, poster?}`. Local override only; Douban stays
  /// the only metadata source (no TMDB anywhere).
  static const String vodMetadataOverrides = 'hao_vod_metadata_overrides';

  /// 10. 影视分类显示/隐藏/重排: JSON `{hidden: [name],
  /// order: [name]}`. Names are home-row (CMS type) names.
  static const String vodCategoryPrefs = 'hao_video_category_prefs';

  /// VOD picture fit (`hao_vod_video_fit`): 'auto' | 'fill' | 'cover',
  /// default 'auto' (contain). PiliPlus VideoFitType + Kazumi
  /// PlayerAspectRatio intersection — see `VideoFitMode`.
  static const String vodVideoFit = 'hao_vod_video_fit';

  /// Anime4K real-time super-resolution (build 28): bool,
  /// default false. VOD only, MPV only; never live. Switch lives
  /// in Settings → 影视播放. Dropped from build 28 if the audit
  /// finds a hard blocker (media_kit cannot set glsl-shaders).
  static const String vodSuperResolution = 'hao_vod_super_resolution';

  /// VOD skip intro/outro mode (1.1.6): String, default 'off'.
  /// 'off' | 'manual' | 'auto3s' (auto-skip after 3s) |
  /// 'autoNow' (auto-skip immediately). CMS has no markers —
  /// per-episode seconds come from [vodSkipIntroDurations];
  /// Emby markers come from Chapters (IntroStart/IntroEnd/
  /// CreditsStart). Switch lives in Settings → 影视播放.
  static const String vodSkipIntroMode = 'hao_vod_skip_intro_mode';

  /// Per-episode skip-intro seconds (1.1.6): map
  /// `'<normalizedTitle>|<episodeName>'` → seconds (int, 0–300).
  /// Edited by long-pressing an episode chip on the detail page.
  static const String vodSkipIntroDurations =
      'hao_vod_skip_intro_durations';

  /// VOD frame interpolation (1.1.6): bool, default false.
  /// MPV only, VOD only; `video-sync=display-resample` +
  /// `interpolation=yes` + `tscale=oversample`. Whether it takes
  /// effect on the libmpv render path is unverified on a real
  /// device (chen's phone decides); if it does nothing, the
  /// switch is dropped. Mutually exclusive with super-res and
  /// SDR→HDR (gate layer runs only the first passing branch).
  static const String vodInterpolation = 'hao_vod_interpolation';

  /// VOD SDR→HDR (1.1.6): bool, default false. MPV only, VOD
  /// only; `--inverse-tone-mapping` (vo=gpu-next only per mpv
  /// manual — our vo is libmpv, so real-device effect is
  /// unverified, chen's phone decides; if it does nothing, the
  /// switch is dropped). Mutually exclusive with super-res and
  /// interpolation.
  static const String vodSdrToHdr = 'hao_vod_sdr_to_hdr';

  /// VOD subtitle time offset (1.1.6): double seconds,
  /// default 0.0, range ±10s, step 0.1s. Applied via mpv
  /// `sub-delay`. Setting lives in Settings → 影视播放.
  static const String vodSubtitleDelay = 'hao_vod_subtitle_delay';

  /// VOD subtitle appearance (1.1.6): three tiers each, stored as
  /// tier keys ('small' | 'medium' | 'large', 'white' | 'yellow' |
  /// 'cyan', 'bottom' | 'middle' | 'top'); the mpv values live in
  /// vod_controls.dart. Applied via mpv `sub-font-size` /
  /// `sub-color` / `sub-pos` at open; a change applies at the next
  /// open, same as the subtitle delay row. VOD only, never live.
  static const String vodSubtitleFontSize = 'hao_vod_subtitle_font_size';
  static const String vodSubtitleColor = 'hao_vod_subtitle_color';
  static const String vodSubtitlePosition = 'hao_vod_subtitle_position';

  /// Danmaku person-occlusion avoidance (1.1.6): bool, default
  /// false. MPV only, VOD + live; on-device Vision person
  /// segmentation (iOS 15+, single mask for all people) over
  /// low-frequency snapshot frames, whole-layer ShaderMask on
  /// the danmaku layer. True per-pixel real-time cutout is a
  /// hard block (no frame outlet, no mask entry in flame_barrage)
  /// — this is the reduced version only. Performance numbers
  /// unverified until chen's phone; if unusable, the switch
  /// stays off / the feature is cut. Switch lives in Settings →
  /// 弹幕设置, below 影视弹幕.
  static const String danmakuOcclusionAvoidance =
      'hao_danmaku_occlusion_avoidance';

  /// DV Profile 8 downgrade-to-HDR switch (1.1.6): bool,
  /// default true. ON → P8 content is routed to AVPlayer
  /// (native DV); OFF → normal kernel ladder. The final
  /// default is bound to real-device verification: if both
  /// kernels shift colour or fail on real P8 files, the
  /// default is reworked and reported back — never silently
  /// changed. Switch lives in Settings → 影视播放.
  static const String vodDvP8Downgrade = 'hao_vod_dv_p8_downgrade';

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

  /// Emby server config (build 28): JSON string of
  /// EmbyServerConfig {baseUrl, apiKey, userId, enabled,
  /// movieLibraryId, tvLibraryId}. Independent key — resetting
  /// the CMS source list never clears it. Credentials live only
  /// in this local Hive box; never logged, never in toString().
  static const String embyConfig = 'hao_emby_config';

  /// Video tab mode (build 28): 'cms' | 'emby', default 'cms'.
  /// Persists which page of the video tab was last selected.
  static const String videoTabMode = 'hao_video_tab_mode';

  /// Emby home cache (build 28): cached Emby library rows JSON,
  /// same pattern as [videoHomeCache]. Never mixed with CMS cache.
  static const String embyHomeCache = 'hao_emby_home';

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

  /// Danmaku stroke on/off (`hao_danmaku_stroke`): bool, default
  /// true (the flame_barrage engine default). Fullscreen flying
  /// danmaku only — the portrait list is plain Text and has no
  /// stroke to draw.
  static const String danmakuStroke = 'hao_danmaku_stroke';

  /// Danmaku stroke width (`hao_danmaku_stroke_width`): double
  /// 0.5..2.0, default 1.0 (the engine default). Fullscreen flying
  /// danmaku only. Stroke colour is fixed black (a legibility
  /// floor, not decoration) — no colour choice.
  static const String danmakuStrokeWidth = 'hao_danmaku_stroke_width';

  /// Danmaku flying-speed multiplier (`hao_danmaku_speed`): double
  /// 0.5..2.0, default 1.0. Fullscreen flying danmaku only:
  /// BarrageConfig.baseSpeed = 120 * speed. This is NOT playback
  /// rate — live has no speed control and playbackRate stays 1.0.
  static const String danmakuSpeed = 'hao_danmaku_speed';

  /// Danmaku maximum count (`hao_danmaku_max_count`): int 20..200,
  /// default 80 (the engine's maxVisibleCount default). Caps the
  /// portrait list AND the fullscreen flying danmaku; the flying
  /// side is additionally clamped to the engine object-pool ceiling
  /// (72) — see DanmakuSettings.flyingMaxVisibleCount.
  static const String danmakuMaxCount = 'hao_danmaku_max_count';

  /// Danmaku colour mode (`hao_danmaku_color_mode`): 'uniform'
  /// (default — theme text in the portrait list, white flying
  /// danmaku) or 'platform' (the platform's own colour from
  /// LiveMessage.color, where the adapter provides one).
  /// Portrait-list body + fullscreen flying danmaku only; the
  /// username stays theme-coloured in both modes.
  static const String danmakuColorMode = 'hao_danmaku_color_mode';

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
