// Music player controller — queue + native audio (AVPlayer via just_audio,
// like 歌一刀; was media_kit/MPV before chen 2026-11-17).
//
// - Playback ALWAYS starts at the user's chosen quality (default hires);
//   a song that only resolves lower drops down for that song only, and the
//   next song returns to the chosen tier (rule "fi" — the resolver module
//   holds no downgrade state; the caller passes the chosen tier every time).
// - Candidate fallback on play error: next candidate URL, then one
//   alt-platform attempt (findAltPlatform) before giving up. A MANUAL
//   load (user tap) never auto-skips on failure: it stops on the song
//   with a notice (retry / next). Only AUTO-advance skips, with a
//   notice naming the song and the reason.
// - Trial clip: the trial URL won the fastest-first race — retry the
//   SAME song from another source (exclude the serving job, max 2
//   retries) before falling back to alt/next. Retrying the same song
//   is not hunting for a higher tier: the first full track at any
//   tier plays immediately.
// - Prefetch: the next track's URL is resolved ahead of time AND its
//   audio is pre-buffered on the standby player (crossfade reuses it).
// - Song crossfade (Apple Music-style): on AUTO-advance the next track
//   starts on a second AvMusicPlayer at volume 0 while the current fades
//   out (~2.5 s overlap). Manual next/prev switch immediately, no fade.
// - Progress is saved ONLY when the app is killed from the background
//   (AppLifecycleState.detached — the pagehide equivalent), never while
//   merely backgrounded. A saved position only resumes when > 5 s in and
//   > 10 s from the end (old web rule).
// - Prefetch: the next track's URL is resolved ahead of time.
// - Next/previous advance exactly one track (fix 14 Dart-side rule).

import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'av_music_player.dart';

import '../../core/logging/app_log.dart';
import '../../core/native/now_playing.dart';
import '../../core/storage/hive_store.dart';
import '../../core/storage/local_paths.dart';
import '../../services/music/ab_loop.dart';
import '../../services/music/bookmarks_store.dart';
import '../../services/music/equalizer_store.dart';
import '../../services/music/lyric_tools.dart';
import '../../services/music/multi_queue_store.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_downloads.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_quality.dart';
import '../../services/music/music_resolvers.dart';
import '../../services/music/music_store.dart';
import '../../services/music/play_mode.dart';
import '../../services/music/sleep_timer.dart';
import '../../services/music/volume_fader.dart';
import '../../widgets/hao_toast.dart';

const Duration _crossfadeDuration = Duration(milliseconds: 2500);

class MusicPlayerController extends GetxController
    with WidgetsBindingObserver {
  MusicPlayerController({
    MusicApi? api,
    MusicResolvers? resolvers,
    NowPlayingService? nowPlaying,
    MusicDownloadService? downloads,
    AvMusicPlayer? playerA,
    AvMusicPlayer? playerB,
  })  : _api = api ?? MusicApi(),
        _resolvers = resolvers ?? MusicResolvers(),
        _nowPlayingOverride = nowPlaying,
        downloads = downloads ?? MusicDownloadService() {
    // Test seam (same pattern as api/resolvers above): injected
    // players let tests drive the A/B crossfade without native
    // audio. Production passes none, so behaviour is unchanged.
    if (playerA != null && playerB != null) {
      _playerA = playerA;
      _playerB = playerB;
      _active = _playerA;
      _playersReady = true;
    }
  }

  final MusicApi _api;
  final MusicResolvers _resolvers;
  final NowPlayingService? _nowPlayingOverride;

  /// Offline downloads (M-P0-5): the player checks this before
  /// resolving a remote URL, so a downloaded song plays from disk.
  final MusicDownloadService downloads;

  // Now Playing shell (Fix 14): publishes the current track to
  // MPNowPlayingInfoCenter and receives Lock Screen / Control Center /
  // Dynamic Island remote commands. Behaviour only — the player look
  // is untouched. No ±10 s skip, no Live Activity.
  late final NowPlayingService _nowPlaying;
  DateTime? _lastNowPlayingPublish;

  // Queue state.
  final RxList<Song> queue = <Song>[].obs;
  final RxInt currentIndex = (-1).obs;
  final RxBool isPlaying = false.obs;
  final Rx<Duration> position = Duration.zero.obs;
  final Rx<Duration> duration = Duration.zero.obs;
  final Rx<AudioQuality> userQuality = AudioQuality.hires.obs;
  final Rx<AudioQuality> actualQuality = AudioQuality.hires.obs;
  final RxDouble speed = 1.0.obs; // M-P0-2: 0.5..2.0, persisted
  /// Speed presets offered in the `···` sheet (0.5–2x, pitch-corrected
  /// — the native fork already pins every AVPlayerItem to
  /// AVAudioTimePitchAlgorithmTimeDomain, UriAudioSource.m:95, so
  /// changing speed never changes pitch; there is no Dart-side
  /// toggle for it because just_audio exposes no such API).
  static const List<double> speedPresets = [0.5, 0.75, 1.0, 1.25, 1.5, 2.0];
  final RxString playMode = 'seq'.obs; // five modes, see play_mode.dart
  final RxList<LyricLine> lyrics = <LyricLine>[].obs;
  final RxBool lyricsFailed = false.obs;
  /// Lyric offset in ms (±5000, persisted): shifts which line is
  /// active, never the seek target (see LyricDisplay).
  final RxInt lyricOffsetMs = 0.obs;

  /// Show the translation line under the active lyric (NetEase
  /// `tlyric` — already fetched, now toggleable). Default on.
  final RxBool showLyricTranslation = true.obs;

  /// Fade in/out on manual pause/resume/track-change (build 29).
  /// Default on. Auto-advance keeps its own 2.5 s crossfade; the
  /// sleep-timer stop keeps its own 1 s fade.
  final RxBool fadeEnabled = true.obs;

  /// A-B loop for the current track (build 29). Cleared on every
  /// track change — a loop never survives to another song.
  /// [abLoopVersion] bumps on every change so the sheet can Obx it.
  final AbLoop abLoop = AbLoop();
  final RxInt abLoopVersion = 0.obs;

  /// Per-source queue memory (build 29): each playlist / album /
  /// artist / daily list remembers its own position. [_currentSourceKey]
  /// is the source the live queue belongs to ('' = ad-hoc queue,
  /// e.g. from search — not remembered).
  final MultiQueueStore queueMemory = MultiQueueStore();
  var _currentSourceKey = '';

  /// Lyrics live BEHIND the cover (chen 2026-11-17): the cover box is
  /// two-sided — front = cover, back = lyrics. `true` = lyrics side
  /// showing, `false` = cover side. Default cover (lyrics are behind).
  /// Tap the cover flips to lyrics, tap lyrics blank flips back; the
  /// state is the user's last choice and is NOT reset on song change.
  final RxBool showLyrics = false.obs;

  /// Flip cover <-> lyrics (cover tap, lyrics-blank tap, bottom icon).
  void toggleLyrics() => showLyrics.value = !showLyrics.value;
  final RxBool showQueuePanel = false.obs;
  final RxString queueLabel = ''.obs;

  /// Current mode as the typed enum (legacy stored codes map through
  /// PlayModeX.fromCode, so old 'seq'/'shuffle' values keep working).
  PlayMode get mode => PlayModeX.fromCode(playMode.value);

  // Sleep timer (M-P0-3): wall-clock countdown, survives track changes.
  // The Rx mirrors let the UI show the active state / remaining time.
  late final SleepTimer _sleepTimer;
  final Rx<SleepTimerOption> sleepOption = SleepTimerOption.off.obs;
  final Rx<Duration?> sleepRemaining = Rx<Duration?>(null);

  /// Last custom sleep minutes (stage 2, persisted — default 30).
  final RxInt sleepCustomMinutes = 30.obs;

  /// "播完 N 首后停止" target + progress (1.1.6). Default N = 3.
  /// Synced from the SleepTimer by [_syncSleepState] so the sheet
  /// can show them honestly.
  final RxInt sleepTrackCount = 3.obs;
  final RxInt sleepTracksCompleted = 0.obs;

  /// Volume normalisation (1.1.6, strategy A — attenuation only).
  /// Defaults: off, standard strength. Read from Hive in onInit
  /// (the settings rows live with the settings group; these are the
  /// read/write API they use).
  final RxBool normalizationEnabled = false.obs;
  final RxInt normalizationStrength = 1.obs;

  /// Per-track measured loudness in LUFS, keyed by identityKey
  /// (in-memory mirror of the Hive cache — see
  /// [noteMeasuredLoudness] / [parseLoudnessCache]; loaded from
  /// Hive in onInit so the second-play effect survives restart).
  final Map<String, double> _measuredLufs = {};

  /// Attenuation actually sounding right now (1.0 = none). Updated
  /// whenever a track's open lands, so a crossfade can fade the
  /// outgoing track out from the volume it is really at.
  var _currentNormGain = 1.0;

  /// Bookmark jump waiting for its song to load (1.1.6): jumping to
  /// a bookmark of a song that is not loaded yet starts the load,
  /// and the seek lands once the duration is known (consumed in
  /// [_loadCurrent]; a newer load for another song drops it).
  ({String key, int seconds})? _pendingBookmarkSeek;

  Song? get currentSong {
    final i = currentIndex.value;
    if (i < 0 || i >= queue.length) return null;
    return queue[i];
  }

  // Two AVPlayer players (just_audio): active + standby (crossfade
  // partner). Volume is 0.0..1.0 here, not media_kit's 0..100.
  late final AvMusicPlayer _playerA;
  late final AvMusicPlayer _playerB;
  late AvMusicPlayer _active;
  AvMusicPlayer get _standby =>
      identical(_active, _playerA) ? _playerB : _playerA;

  /// True once the players exist (end of onInit). Rate application is
  /// a no-op before that, so unit tests can construct the controller
  /// (no Get.put, no onInit) and exercise speed/queue logic without
  /// native players.
  var _playersReady = false;

  StreamSubscription<Duration>? _posSub;
  StreamSubscription<Duration>? _durSub;
  StreamSubscription<bool>? _playingSub;
  StreamSubscription<String>? _errorSub;
  StreamSubscription<bool>? _completedSub;
  Timer? _fadeTimer;

  /// The sleep-timer fade-out's own timer. It MUST NOT share
  /// [_fadeTimer] with the crossfade: the two fades own different
  /// players and run in different directions — sharing one timer let
  /// a crossfade cancel a sleep fade-out (and vice versa), so the
  /// track kept sounding past the sleep deadline.
  Timer? _sleepFadeTimer;

  /// Generation counter for fade-in ramps: a fade-out (pause or
  /// sleep stop) bumps it so a still-running fade-in ramp stops
  /// writing rising volumes instead of fighting the fade-out.
  var _fadeGen = 0;
  var _playGen = 0;
  var _disposed = false;

  /// Early-crossfade trigger (one shot per track): the position
  /// listener starts the next song's load when the current track is
  /// inside the crossfade window and its URL is already prefetched.
  /// Reset in [_loadCurrent].
  var _earlyCrossfadeStarted = false;

  /// User intents that arrived while a load was resolving (the old
  /// song was still sounding): applied to the new song once it lands
  /// (see [_applyPendingIntents]). Cleared at every [_loadCurrent]
  /// start so a stale intent never leaks into a later song.
  var _pendingPause = false;
  Duration? _pendingSeek;

  /// The user moved the position since this song opened (public
  /// [seek] only — internal seeks never set it). The kill-saved
  /// resume seek must not jump such a position back.
  var _userSeekedSinceOpen = false;

  /// Real-duration event that arrived during the open's own await
  /// (see [onRealDuration]): drained once the load lands.
  Duration? _pendingRealDuration;

  /// True while an open call ([_openOn] / [_crossfadeTo]'s incoming
  /// open) is in flight. A duration event in that window belongs to
  /// the song being opened, not the old one.
  var _openStarted = false;

  /// Gen of the load whose audio is currently open in [_active]
  /// (-1 = no load has opened yet). The error stream carries no URL
  /// and no gen, so [_onStreamError] stamps the error with this: an
  /// error that arrives while a NEWER load is still resolving belongs
  /// to the old song — its gen no longer matches [_playGen], and
  /// [_onPlayError] drops it instead of failing the new song. Set
  /// whenever an open is issued on [_active] (see [_openOn]) and when
  /// a crossfade swaps the standby in (see [_crossfadeTo]).
  var _activeGen = -1;

  // Current-track resolve state.
  List<String> _candidates = [];
  var _candidateIdx = 0;
  var _altTried = false;

  /// Trial-clip guard: one check per track load. Set when the
  /// player's real duration for the current track is first known
  /// (see [onRealDuration]); reset in [_loadCurrent] and when an
  /// alt-platform track is opened in [_tryAltOrNext].
  var _trialChecked = false;

  // Real listen-time accounting (chen 2026-11-17: total time in the
  // report was not real). One session per track; seconds accumulate
  // only while the player reports playing. See ListenSessionTracker.
  final ListenSessionTracker _listenTracker = ListenSessionTracker();

  /// Close the current listen session and persist it when at least 5 s
  /// were actually heard. Best-effort: a closed Hive box (app kill)
  /// must never throw into the caller.
  Future<void> _finalizeListenSession() async {
    final event = _listenTracker.finish(DateTime.now());
    if (event == null) return;
    try {
      await MusicStore.recordListenEvent(event);
    } catch (_) {
      // Hive closed (app kill) — the session is lost, not fatal.
    }
  }

  /// Snapshot of the listen session in progress (not yet persisted),
  /// or null when nothing has been heard for 5 s. The report page
  /// merges it so the song playing right now is already counted.
  ListenEvent? get liveListenEvent =>
      _listenTracker.currentEvent(DateTime.now());

  // -- failure / notice state (chen 2026-11-18: no silent skips) --------
  /// Latest notice shown to the user (skip / failure reasons). The
  /// player sheet observes [loadError] for its retry UI; [lastNotice]
  /// is the single source of truth tests assert on. HaoToast is a
  /// best-effort side effect on top (it no-ops without a GetMaterialApp
  /// in tests, so the call is guarded).
  final RxString lastNotice = ''.obs;
  final Rx<({Song song, String reason})?> loadError =
      Rx<({Song song, String reason})?>(null);

  /// The auto-ness of the load currently in flight / playing.
  /// Failure paths that arrive without an explicit `auto` (error
  /// stream, trial detection) read this. Set at every _loadCurrent.
  /// Default true: a failure detected during playback (no load ran
  /// in this controller instance — the unit-test harness) is an
  /// auto-advance context; a real manual load always overwrites it
  /// with false at its start.
  var _lastLoadAuto = true;

  /// Gen of the load in flight when the sleep timer fired (-1 = the
  /// timer has not fired since the last load landed). A load that
  /// lands after the fire must not sound — see [_pauseIfSleepFired].
  /// Stamped with the gen (not a bool) so a NEWER load the user
  /// starts after the fire plays normally.
  var _sleepFiredGen = -1;

  /// Wall-clock sleep timer fired, sticky until the user explicitly
  /// plays something else (manual load / resume / quality change).
  /// The gen flag above only covers a load that was already in
  /// flight when the fire landed; a track that COMPLETES during the
  /// 1 s fade-out starts a fresh auto-advance with a bumped gen, so
  /// the gen flag cannot stop it — this flag can (see
  /// [_onTrackCompleted]).
  var _sleepFired = false;

  /// URL of the source opened for the current song. The trial retry
  /// compares a re-resolved URL against it: the same URL string is
  /// the same content, retrying it is pointless.
  var _openedUrl = '';

  /// Job name ([PlayUrlResult.via]) that served the current track's
  /// URL; the trial retry excludes it.
  var _lastResolveVia = '';

  /// Identity of the song whose audio is actually in the ACTIVE
  /// player. [_isLoadedCurrent] compares against THIS, not against
  /// `queue[currentIndex]`: after playQueue replaces the queue the
  /// old index still points at the new list, so queue+index names
  /// the TAPPED song itself and the same-song shortcut fires for a
  /// different song (chen 2026-11-18: play a song, switch platform,
  /// tap result #1 — index 0 == old index 0 — and nothing plays).
  /// Set when a load's open lands in the active player (see
  /// [_loadCurrent] and the alt branch of [_tryAltOrNext]); '' =
  /// nothing loaded.
  var _loadedIdentityKey = '';

  /// Test seam: simulate a loaded song without a real load.
  /// Same-song tap tests poke isPlaying/position/duration directly
  /// (no native players); the loaded identity is the fourth piece
  /// of that simulated state.
  @visibleForTesting
  set loadedIdentityKeyForTest(String key) => _loadedIdentityKey = key;

  /// Trial-retry state, reset per load: jobs already excluded and the
  /// retry count (cap 2).
  final Set<String> _trialExcluded = <String>{};
  var _trialRetries = 0;

  /// Consecutive AUTO-advance failures (no playable URL for the next
  /// song, again and again). At 3 the chain stops instead of walking
  /// — and toast-spamming — through a dead queue. Reset whenever a
  /// load obtains a playable URL.
  var _consecutiveAutoFailures = 0;

  /// True when the current load ended in a give-up (see
  /// [_giveUpOnSong]). Reset at every _loadCurrent start. An
  /// auto-advance that moved to a song which then failed itself must
  /// not overwrite that song's notice with its own "skipped" notice
  /// (the old code did exactly that: the final notice named the
  /// wrong song).
  var _loadFailed = false;

  /// Surface a playback notice to the user: always recorded in
  /// [lastNotice] (observable + testable); HaoToast banner on top,
  /// best-effort. [withActions] adds 重试 / 下一首 buttons for a
  /// manual-load failure (the song stays put; the user decides).
  void _notice(String message, {bool withActions = false}) {
    lastNotice.value = message;
    try {
      // No overlay (unit tests) or no binding yet: the recorded
      // notice is enough. HaoToast.show swallows that case itself.
      HaoToast.show('播放提示', message: 
        message,
        // The old Get.snackbar call passed 4s explicitly; keep 4s
        // here so a load failure stays readable while the user
        // decides. Every other call site uses the 2.5s default.
        duration: const Duration(seconds: 4),
        actions: withActions
            ? [
                HaoToastAction(
                  label: '重试',
                  onTap: () => unawaited(retryCurrent()),
                ),
                HaoToastAction(
                  label: '下一首',
                  onTap: () => unawaited(next()),
                ),
              ]
            : const [],
      );
    } catch (_) {
      // No GetMaterialApp (unit tests): the recorded notice is enough.
    }
  }

  /// Retry the current song's load (the notice's 重试 button and the
  /// player sheet's retry UI). Only meaningful after a recorded
  /// failure; a no-op otherwise, so it can never restart a playing
  /// song by accident.
  Future<void> retryCurrent() async {
    if (loadError.value == null) return;
    final song = currentSong;
    if (song == null) return;
    loadError.value = null;
    await _loadCurrent();
  }

  // Prefetch cache for the next track. TTL 5 min: play URLs expire,
  // and a stale cached URL fails the open (the old code trusted it
  // forever). `via` is kept so a trial detected on a prefetched URL
  // still knows which job served it.
  ({String key, String url, List<String> candidates, AudioQuality quality, String via, DateTime storedAt})?
      _nextCache;

  /// Prefetch TTL (test seam: pure, unit-testable).
  static const prefetchTtl = Duration(minutes: 5);

  static bool isPrefetchFresh(DateTime storedAt, DateTime now) =>
      now.difference(storedAt) < prefetchTtl;

  /// True while the current track's URL is being resolved / opened
  /// (network). The player page shows a spinner on the play button
  /// while this is true and nothing is sounding yet — without it a
  /// tap looks dead for the 1–6 s a resolve can take. Gen-guarded:
  /// a superseded load must never clear a newer load's flag.
  final RxBool isResolving = false.obs;
  var _resolvingGen = -1;

  void _setResolving(bool v, int gen) {
    if (v) {
      _resolvingGen = gen;
      isResolving.value = true;
    } else if (gen == _resolvingGen) {
      isResolving.value = false;
    }
  }

  /// "启动时自动播放上次歌曲" pref (Beans
  /// `beans.playback.autoResumeLast`, default false). Hive may be
  /// uninitialised in unit tests — then it is off.
  bool get _autoResumeEnabled {
    try {
      return HiveStore.getBool(HiveKeys.autoResumeLastPlayback, false);
    } catch (_) {
      return false;
    }
  }

  @override
  void onInit() {
    super.onInit();
    userQuality.value = MusicStore.quality;
    actualQuality.value = userQuality.value;
    speed.value = MusicStore.speed;
    playMode.value = MusicStore.playMode;
    // Restore the persisted queue (M-P0-4) — order + current index,
    // but do NOT auto-play: playback only starts on a user tap.
    final savedQueue = MusicStore.getQueue();
    if (savedQueue.songs.isNotEmpty) {
      queue.assignAll(savedQueue.songs);
      currentIndex.value = savedQueue.index;
      // A restored downloaded song shows its file's tier, not the
      // requested tier (same rule as the local branch of _loadCurrent).
      final restored = currentSong;
      if (restored != null) {
        actualQuality.value =
            downloads.tierFor(restored) ?? userQuality.value;
      }
    }
    // Two crossfade players (A/B, AVPlayer via just_audio). Only on
    // platforms with native audio — on Linux tests there is none, and
    // a just_audio method call there would throw MissingPluginException
    // into the test zone. A player failure only disables playback
    // (_playersReady stays false, rate/play calls no-op) instead of
    // crashing the whole music tab during build. Injected players
    // (constructor seam) are never overwritten here.
    if (!_playersReady && AvMusicPlayer.isSupported) {
      try {
        _playerA = AvMusicPlayer();
        _playerB = AvMusicPlayer();
        _active = _playerA;
        _playersReady = true;
      } catch (e) {
        AppLog.error('音乐播放器初始化失败：$e');
        _playersReady = false;
      }
    }
    if (_playersReady) {
      unawaited(_active.setVolume(1.0));
      unawaited(_active.setRate(speed.value));
      unawaited(_standby.setVolume(0));
      unawaited(_standby.setRate(speed.value));
    }
    WidgetsBinding.instance.addObserver(this);
    if (_playersReady) _attach(_active);
    _nowPlaying = _nowPlayingOverride ?? NowPlayingService();
    _nowPlaying.onRemoteCommand = _onRemoteCommand;
    _sleepTimer = SleepTimer(
      onFire: _onSleepTimerFired,
      onChanged: _syncSleepState,
    );
    _syncSleepState();
    // Remembered custom minutes (stage 2): the sheet opens with the
    // last value the user typed, not a hardcoded 30.
    try {
      sleepCustomMinutes.value = MusicStore.sleepCustomMinutes;
    } catch (_) {}
    // Normalisation prefs (1.1.6, strategy A): off + standard
    // strength unless the user turned it on. Hive may be
    // uninitialised in unit tests — then the field defaults stand.
    try {
      normalizationEnabled.value = HiveStore.getBool(
        HiveKeys.musicNormalizationEnabled,
        false,
      );
      normalizationStrength.value = HiveStore.getInt(
        HiveKeys.musicNormalizationStrength,
        1,
      ).clamp(0, 2);
    } catch (_) {}
    // Build-29 prefs (literal Hive keys — HiveKeys lives in core
    // storage; see MultiQueueStore's header): fade on, lyric offset
    // 0, translation shown. Hive may be uninitialised in unit tests
    // — then the field defaults stand.
    try {
      fadeEnabled.value = HiveStore.getBool('hao_music_fade_enabled', true);
      lyricOffsetMs.value =
          HiveStore.getInt('hao_music_lyric_offset_ms', 0).clamp(-5000, 5000);
      showLyricTranslation.value =
          HiveStore.getBool('hao_music_lyric_show_translation', true);
    } catch (_) {}
    // Per-source queue memory (build 29): load once at startup.
    try {
      queueMemory.load();
    } catch (_) {}
    // Measured-loudness cache (1.1.6): the EQ tap writes it during
    // playback (see [noteMeasuredLoudness]); reading it back here
    // makes the second-play effect survive a restart. Same
    // try/catch as the prefs above (uninitialised Hive in tests).
    try {
      _measuredLufs.addAll(
        parseLoudnessCache(
          HiveStore.box.get(HiveKeys.musicLoudnessCache),
        ),
      );
    } catch (_) {}
    // Native tap loudness reports land here via the equalizer
    // method channel (EqualizerStore owns the channel; this
    // controller consumes the reports). Registered here — not in
    // main — because playback only exists once this controller
    // does; cleared in onClose so a stale callback can never feed
    // a disposed controller. Best-effort: no Hive / no native
    // engine only loses measurement, never playback.
    try {
      EqualizerStore.ensure().onLoudnessMeasured =
          (key, lufs) => noteMeasuredLoudness(key, lufs);
    } catch (_) {}
    // Publish on track change / play / pause; elapsed time is
    // throttled to 1 s while playing (see _publishNowPlayingThrottled).
    ever(currentIndex, (_) => _publishNowPlaying());
    ever(isPlaying, (_) => _publishNowPlaying());
    ever(position, (_) => _publishNowPlayingThrottled());
    // Auto-resume (Beans `PlayerManager.resumePersistedPlaybackIfEnabled`,
    // PlayerManager.swift: resume once per launch, only when the pref is
    // on — default off). This is the ONLY addition to this file: it
    // calls the existing public playQueue() with the queue restored
    // above; the resume position is applied by _loadCurrent from the
    // kill-saved resume map, so the "save progress only on kill" rule
    // is untouched. No resolve/play logic is changed.
    if (_autoResumeEnabled) {
      final songs = queue.toList();
      final idx = currentIndex.value.clamp(0, songs.length - 1);
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (_disposed) return;
        unawaited(playQueue(songs, idx));
      });
    }
  }

  @override
  void onClose() {
    _disposed = true;
    // Drop the tap loudness registration (see onInit): a report
    // arriving after close must not touch this controller.
    try {
      EqualizerStore.ensure().onLoudnessMeasured = null;
    } catch (_) {}
    _sleepTimer.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _fadeTimer?.cancel();
    _sleepFadeTimer?.cancel();
    // Persist the per-source queue memory (build 29): the in-memory
    // map is updated on every track change, the Hive write happens
    // here and on source switches only — not per track.
    if (_currentSourceKey.isNotEmpty && queue.isNotEmpty) {
      queueMemory.remember(
        _currentSourceKey,
        queue.toList(),
        currentIndex.value,
      );
    }
    unawaited(queueMemory.save());
    unawaited(_finalizeListenSession());
    unawaited(_nowPlaying.clear());
    _nowPlaying.dispose();
    unawaited(_posSub?.cancel());
    unawaited(_durSub?.cancel());
    unawaited(_playingSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_completedSub?.cancel());
    // Players are late final: only dispose when they were created
    // (onInit try/catch may have left them uninitialised).
    if (_playersReady) {
      unawaited(_playerA.dispose());
      unawaited(_playerB.dispose());
    }
    super.onClose();
  }

  // -- lifecycle: save progress ONLY on kill (detached) ----------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _saveResumeOnKill();
      // Flush the current listen session so a kill does not lose
      // the song's real listened seconds.
      unawaited(_finalizeListenSession());
    } else if (state == AppLifecycleState.resumed) {
      // Fresh Now Playing push on foreground: the native side
      // re-publishes from cache, but the cached elapsed time may be
      // stale; push the live position so the card is current and
      // tappable immediately (v1.0.6 follow-up).
      _publishNowPlaying();
    }
  }

  void _saveResumeOnKill() {
    final song = currentSong;
    if (song == null) return;
    final pos = position.value.inSeconds;
    final total = duration.value.inSeconds;
    if (pos <= 10) return;
    if (total > 0 && total - pos < 30) return;
    unawaited(MusicStore.saveResume(song.identityKey, pos));
  }

  // -- Now Playing (Fix 14) ----------------------------------------------------

  /// Open the system AirPlay route picker (iOS AVRoutePickerView).
  /// Returns true when the picker opened. The picker itself lists the
  /// available routes — no device-availability message is invented
  /// here. Never throws from a button tap: if the Now Playing service
  /// is not ready yet, the tap reports failure instead of crashing.
  Future<bool> showAirPlayPicker() async {
    try {
      return await _nowPlaying.showAirPlayPicker();
    } catch (_) {
      return false;
    }
  }

  /// Push the current track to the system Now Playing (Lock Screen /
  /// Control Center / Dynamic Island). Called on track change and on
  /// play/pause; elapsed time is refreshed via the throttled path.
  void _publishNowPlaying() {
    if (_disposed) return;
    final song = currentSong;
    if (song == null) {
      unawaited(_nowPlaying.clear());
      return;
    }
    unawaited(_nowPlaying.updateTrack(
      title: song.title,
      artist: song.artist,
      album: song.album,
      coverUrl: song.cover,
      duration: duration.value,
      position: position.value,
      playing: isPlaying.value,
    ));
  }

  /// Elapsed-time refresh while playing, at most once a second — the
  /// position stream fires far more often than the Lock Screen needs.
  void _publishNowPlayingThrottled() {
    if (!isPlaying.value) return;
    final now = DateTime.now();
    if (_lastNowPlayingPublish != null &&
        now.difference(_lastNowPlayingPublish!) < const Duration(seconds: 1)) {
      return;
    }
    _lastNowPlayingPublish = now;
    _publishNowPlaying();
  }

  /// Remote command from the system (Lock Screen / Control Center /
  /// Dynamic Island / headphones). Drives the player's real transport,
  /// so next/previous advance exactly one track (the service also
  /// dedupes rapid duplicate deliveries). Manual advance: no crossfade.
  Future<void> _onRemoteCommand(
    NowPlayingRemoteCommand command, {
    double? position,
  }) async {
    if (_disposed) return;
    switch (command) {
      case NowPlayingRemoteCommand.play:
        await _playCurrentOrResume();
      case NowPlayingRemoteCommand.pause:
        if (isPlaying.value) await _active.pause();
      case NowPlayingRemoteCommand.toggle:
        await togglePlayPause();
      case NowPlayingRemoteCommand.next:
        await next();
      case NowPlayingRemoteCommand.previous:
        await prev();
      case NowPlayingRemoteCommand.seek:
        if (position != null) {
          await seek(Duration(milliseconds: (position * 1000).round()));
          _publishNowPlaying();
        }
    }
  }

  // -- player plumbing ---------------------------------------------------------

  void _attach(AvMusicPlayer player) {
    unawaited(_posSub?.cancel());
    unawaited(_durSub?.cancel());
    unawaited(_playingSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_completedSub?.cancel());
    _posSub = player.stream.position.listen((p) {
      if (identical(player, _active)) {
        position.value = p;
        _maybeStartEarlyCrossfade(p);
        // A-B loop (build 29): at/past B, jump back to A. The seek
        // is idempotent — a stale position event after the seek just
        // seeks to A again, and the stream then reports A < B.
        final target = abLoop.seekTarget(p);
        if (target != null) unawaited(_active.seek(target));
      }
    });
    _durSub = player.stream.duration.listen((d) {
      if (identical(player, _active)) {
        duration.value = d;
        onRealDuration(d);
      }
    });
    _playingSub = player.stream.playing.listen((playing) {
      if (identical(player, _active)) {
        isPlaying.value = playing;
        _listenTracker.setPlaying(playing, DateTime.now());
      }
    });
    _errorSub = player.stream.error.listen((e) {
      if (e.isNotEmpty && identical(player, _active)) {
        _onStreamError();
      }
    });
    _completedSub = player.stream.completed.listen((done) {
      if (done && identical(player, _active)) _onTrackCompleted();
    });
  }

  // Player volume is full (1.0) unless normalisation (1.1.6,
  // strategy A) attenuates a measured-loud track: the music player
  // has no volume control of its own (chen 2026-11-17) — volume is
  // the system volume (hardware buttons / Control Center). Every
  // open re-asserts the track's gain so a crossfade partner that was
  // faded to 0 never stays silent. Normalisation is an automatic
  // per-track attenuation, not a volume control: no slider, no UI.
  Future<void> _openOn(
    AvMusicPlayer player,
    String url, {
    bool auto = false,
    int gen = -1,
  }) async {
    // The open attempt belongs to this gen: a native error that
    // arrives during/after it is this load's error (see [_activeGen]).
    // gen -1 (trial retry) leaves the stamp alone — the retry opens
    // for the current load, whose gen is already stamped.
    if (gen >= 0) _activeGen = gen;
    // A manual open is the user's explicit play (this also covers
    // setQuality, which re-opens here without going through
    // _loadCurrent): the fired sleep stop no longer owns the
    // players — its fade must not pause the new song when it ends,
    // and a later completion may advance again.
    if (!auto) {
      _sleepFadeTimer?.cancel();
      _sleepFired = false;
    }
    // Stamp the native EQ tap before the open creates its item
    // (see [_pushLoudnessTrackKey]): currentSong IS the song being
    // opened here — the alt branch replaced the queue slot before
    // calling, the trial retry is guarded to the same song, and a
    // candidate retry is the same song on another URL.
    _pushLoudnessTrackKey(currentSong?.identityKey ?? '');
    _openStarted = true;
    try {
      // open() returns false only when the URL was refused before any
      // native call, so no error will arrive on the error stream: fall
      // back to the next candidate here, the same path the error stream
      // uses for a native load failure.
      if (!await player.open(url, play: true)) {
        await _onPlayError(auto: auto, gen: gen);
        return;
      }
    } finally {
      _openStarted = false;
    }
    final gain = normalizationGainFor(currentSong);
    _currentNormGain = gain;
    // Fade-in (build 29): a manual open starts silent and ramps to
    // the track's gain over ~600 ms instead of starting at full
    // volume. The ramp runs in the background, gen-guarded: a newer
    // load bumps [_playGen] and the stale ramp stops itself, so it
    // can never fight the new song's volume. With fading off the old
    // behaviour (immediate full gain) is kept exactly.
    if (fadeEnabled.value && gain > 0) {
      await player.setVolume(0);
      final rampGen = gen >= 0 ? gen : _playGen;
      final fadeGen = _fadeGen;
      unawaited(
        VolumeFader.ramp(
          setVolume: player.setVolume,
          from: 0,
          to: gain,
          duration: const Duration(milliseconds: 600),
          isCancelled: () =>
              rampGen != _playGen || _fadeGen != fadeGen || _disposed,
        ),
      );
    } else {
      await player.setVolume(gain);
    }
    // Rate survives an open: re-apply the user's speed every time a
    // track (or a fallback candidate) is opened.
    await player.setRate(speed.value);
    // A load that lands after the sleep timer fired must not sound.
    await _pauseIfSleepFired(player);
  }

  // -- queue / track loading ---------------------------------------------------

  /// The track already loaded in the player: the same song (same
  /// identity) with playback in progress or paused mid-song. A tap
  /// on it must not reload it from the beginning — tapping the song
  /// that is already playing only opens the player. A failed or
  /// never-loaded track (not playing, position zero) is NOT loaded:
  /// tapping it retries the load. A finished track sits at its
  /// duration (completion already advances the queue, but guard the
  /// race anyway).
  ///
  /// The identity compared here is [_loadedIdentityKey] — the song
  /// whose audio is in the ACTIVE player — never `currentSong`
  /// (queue[currentIndex]): after playQueue swaps the queue, the old
  /// index points at the new list, so currentSong IS the tapped song
  /// and the check would pass for a different song.
  bool _isLoadedCurrent(Song song) {
    if (_loadedIdentityKey != song.identityKey) return false;
    if (isPlaying.value) return true;
    if (position.value <= Duration.zero) return false;
    final total = duration.value;
    return total <= Duration.zero || position.value < total;
  }

  /// Resume a loaded track that is paused (no-op when playing, or
  /// when the players do not exist yet — unit tests construct the
  /// controller without onInit). Only used on the same-song path.
  /// The resume fades in (build 29 — see [_fadeInThenPlay]).
  Future<void> _resumeLoaded() async {
    if (!isPlaying.value && _playersReady) await _fadeInThenPlay();
  }

  /// Replace the queue and play [index].
  ///
  /// [sourceKey] (build 29, QueueSource.*) names the source this
  /// queue belongs to: leaving a remembered source saves its
  /// position first. [resumeFromMemory] (only meaningful with a
  /// [sourceKey]) resumes at the remembered index when the song
  /// order still matches — the "播放全部" path. A row tap passes an
  /// explicit index and always plays exactly that song.
  Future<void> playQueue(
    List<Song> songs,
    int index, {
    String label = '',
    String sourceKey = '',
    bool resumeFromMemory = false,
  }) async {
    if (songs.isEmpty || index < 0 || index >= songs.length) return;
    // Leaving a remembered source: save where we were, then persist
    // the memory (the in-memory map is also updated on every track
    // change — see [_persistQueue] — the Hive write happens here
    // and on close only).
    if (_currentSourceKey.isNotEmpty &&
        _currentSourceKey != sourceKey &&
        queue.isNotEmpty) {
      queueMemory.remember(
        _currentSourceKey,
        queue.toList(),
        currentIndex.value,
      );
      unawaited(queueMemory.save());
    }
    var playIdx = index;
    if (sourceKey.isNotEmpty) {
      if (resumeFromMemory) {
        playIdx = queueMemory.resumeIndexFor(sourceKey, songs) ?? index;
      }
      _currentSourceKey = sourceKey;
    } else {
      _currentSourceKey = '';
    }
    // Same song already loaded (checked BEFORE the queue is
    // replaced — currentSong is derived from the old queue): do not
    // restart it. The queue still switches to the tapped list so
    // "play all" and up-next follow the list the user tapped, but
    // playback continues untouched.
    if (_isLoadedCurrent(songs[playIdx])) {
      queue.assignAll(songs);
      queueLabel.value = label;
      currentIndex.value = playIdx;
      _persistQueue();
      await _resumeLoaded();
      return;
    }
    queue.assignAll(songs);
    queueLabel.value = label;
    await playIndex(playIdx);
  }

  Future<void> playIndex(int index, {bool auto = false}) async {
    if (index < 0 || index >= queue.length) return;
    // Same song already loaded (manual tap only — auto-advance must
    // still replay a duplicate entry): do not restart it.
    if (!auto && _isLoadedCurrent(queue[index])) {
      currentIndex.value = index;
      _persistQueue();
      await _resumeLoaded();
      return;
    }
    currentIndex.value = index;
    _persistQueue();
    await _loadCurrent(auto: auto);
  }

  // -- queue reorder + play next (M-P0-4) -----------------------------------

  /// Persist the queue order + current index (the player playlist).
  /// Also updates the per-source memory (build 29) in memory only —
  /// the Hive write happens on source switch / close.
  void _persistQueue() {
    unawaited(MusicStore.saveQueue(queue.toList(), currentIndex.value));
    if (_currentSourceKey.isNotEmpty && queue.isNotEmpty) {
      queueMemory.remember(
        _currentSourceKey,
        queue.toList(),
        currentIndex.value,
      );
    }
  }

  /// Move the queue item at [from] to [to] (final index). The current
  /// index follows the playing song when the move crosses it.
  void moveQueueItem(int from, int to) {
    if (from < 0 ||
        from >= queue.length ||
        to < 0 ||
        to >= queue.length ||
        from == to) {
      return;
    }
    final song = queue.removeAt(from);
    queue.insert(to, song);
    final cur = currentIndex.value;
    if (cur == from) {
      currentIndex.value = to;
    } else if (from < cur && to >= cur) {
      currentIndex.value = cur - 1;
    } else if (from > cur && to <= cur) {
      currentIndex.value = cur + 1;
    }
    _persistQueue();
  }

  /// Move the item at [index] one slot up (towards the front).
  void moveQueueUp(int index) {
    if (index <= 0 || index >= queue.length) return;
    moveQueueItem(index, index - 1);
  }

  /// Move the item at [index] one slot down (towards the end).
  void moveQueueDown(int index) {
    if (index < 0 || index >= queue.length - 1) return;
    moveQueueItem(index, index + 1);
  }

  /// Clear the queue, keeping ONLY the currently playing song
  /// (stage 2, Beans `PlayerManager.clearQueue`,
  /// PlayerManager.swift:364-375: `queue = [current]`,
  /// `currentIndex = 0`; empty queue is a no-op). The playing song
  /// is untouched — no reload, no pause, no seek — and the queue
  /// panel falls back to its empty state for the rest. Persisted, so
  /// a restart does not resurrect the cleared songs.
  void clearQueue() {
    if (queue.isEmpty) return;
    final current = currentSong;
    if (current == null) {
      queue.clear();
      currentIndex.value = -1;
    } else {
      queue.assignAll([current]);
      currentIndex.value = 0;
    }
    _persistQueue();
  }

  /// Insert [song] right after the current track ("下一首播放").
  /// Returns false when the song is already the one playing (inserting
  /// it after itself would only duplicate it). An empty queue just
  /// starts playing the song.
  Future<bool> playNext(Song song) async {
    final current = currentSong;
    if (current != null && current.identityKey == song.identityKey) {
      return false;
    }
    if (queue.isEmpty) {
      await playQueue([song], 0);
      return true;
    }
    final at = currentIndex.value < 0 ? 0 : currentIndex.value + 1;
    queue.insert(at, song);
    _persistQueue();
    return true;
  }

  /// Pure resume-seek decision (unit-tested): apply the kill-saved
  /// resume / bookmark position only when the user has not already
  /// moved the position themselves since this song opened — a manual
  /// seek in the first seconds must never be jumped back.
  @visibleForTesting
  static bool shouldApplyResumeSeek({
    required bool userSeekedSinceOpen,
    required Duration position,
    required Duration total,
    required int seekSec,
    required bool fromBookmark,
  }) {
    if (userSeekedSinceOpen) return false;
    final inRange = fromBookmark
        ? total.inSeconds > seekSec
        : total.inSeconds > 0 && total.inSeconds - seekSec > 10;
    if (!inRange) return false;
    return position < const Duration(seconds: 5);
  }

  Future<void> _loadCurrent({bool auto = false}) async {
    final gen = ++_playGen;
    final song = currentSong;
    if (song == null) return;
    // A-B loop is per-track (build 29): a new load clears it.
    if (abLoop.hasA || abLoop.hasB) {
      abLoop.clear();
      abLoopVersion.value++;
    }
    // This load owns the failure semantics from here on: a failure
    // during it is manual (user tap) or auto (advance) exactly as
    // [auto] says. A new load also clears a previous failure record
    // and the trial-retry state of the old song.
    _lastLoadAuto = auto;
    loadError.value = null;
    _loadFailed = false;
    _trialRetries = 0;
    _trialExcluded.clear();
    _lastResolveVia = '';
    // A new load drops the previous load's pending intents and
    // per-track flags — a pause/seek from an earlier song must never
    // leak into this one.
    _earlyCrossfadeStarted = false;
    _pendingPause = false;
    _pendingSeek = null;
    _pendingRealDuration = null;
    _userSeekedSinceOpen = false;
    // The badge shows the tier asked for until this song's real tier
    // is known (see the assignment after the resolve): the previous
    // song's tier must not linger through the resolve window.
    actualQuality.value = userQuality.value;
    // P0-1: a MANUAL load does NOT pause the old song up front. The
    // resolve below can take 1–6 s, and pausing first silences the
    // queue for the whole wait (worst case ~8 s of silence on a cold
    // tap). The old song keeps playing while this load resolves; it
    // is only stopped once the new URL is in hand, right before the
    // open below — the same "resolve first, then stop the old song"
    // model as the auto crossfade. A failed resolve therefore leaves
    // the old song sounding; _giveUpOnSong only records the failure.
    // (The v1.0.9 bug this used to guard — position stream reporting
    // the old song's playhead under the new song's name — is covered
    // by the gen/identity guards on the resolve result, not by the
    // up-front pause.) A stale fade timer is still cancelled on a
    // manual load so it cannot fight the new song's volume or pause
    // the wrong player when it ends. The same goes for the sleep
    // fade-out timer, and a manual load is the user's explicit play:
    // the fired sleep stop no longer owns the players.
    if (!auto) {
      // A fade left the standby (the previous outgoing) sounding at
      // a frozen mid-fade volume; with the timer gone nothing will
      // ever stop it — pause it now. Only when a fade was actually
      // running: an idle or preloaded-but-paused standby is not
      // sounding, and pausing it anyway would double-pause it for
      // callers that count (e.g. the sleep-timer landing check).
      // Capture the flag BEFORE cancelling the timer.
      final fadeWasActive = _fadeTimer?.isActive == true;
      _fadeTimer?.cancel();
      if (fadeWasActive && _playersReady) {
        unawaited(_standby.pause());
      }
      _sleepFadeTimer?.cancel();
      _sleepFired = false;
    }
    // LX identity stamp (player.ts createGettingUrlId / setMusicUrl):
    // the URL this load resolves belongs to THIS song only. The gen
    // check below catches a newer load; the identity check catches a
    // queue-slot replacement that did not bump the gen.
    final loadKey = song.identityKey;
    // A bookmark jump that triggered this load: seek there once the
    // duration is known, instead of the kill-saved resume position.
    // Any other song's load drops it — a bookmark never seeks a
    // different song to its position.
    final pendingBookmarkSec = _pendingBookmarkSeek?.key == loadKey
        ? _pendingBookmarkSeek!.seconds
        : null;
    _pendingBookmarkSeek = null;
    // Close the previous track's listen session (real seconds only)
    // and start one for this song. The old code recorded the song's
    // FULL duration here, before a second had played.
    unawaited(_finalizeListenSession());
    _listenTracker.begin(song, DateTime.now());
    _candidates = [];
    _candidateIdx = 0;
    _altTried = false;
    _trialChecked = false;
    lyrics.clear();
    lyricsFailed.value = false;
    // NOTE: position/duration are NOT reset here. The old song is
    // still sounding while this load resolves, so its progress stays
    // on screen until the new song actually opens (reset just before
    // the open below) — zeroing here showed the new title with a
    // dead progress bar and -0:00 remaining for 1–6 s.
    // Local files have no remote lyrics — skip the API call entirely.
    if (!song.isLocal) unawaited(_loadLyrics(song));

    // Resume position for the SAME song (old web rule: > 5 s in, > 10 s
    // from the end). Only applies when this is a fresh open, not a
    // crossfade continuation.
    final resumeSec = MusicStore.resumeFor(song.identityKey);

    // Offline first (M-P0-5): a downloaded song plays from the local
    // file — no resolve, no network. Stage 2 local files use the same
    // branch: Song.localPath (isLocal) is checked first, so an
    // imported file plays through the existing AVPlayer chain with no
    // new playback path. A local entry whose file is gone goes
    // straight to _tryAltOrNext (below) instead of resolving a bogus
    // remote URL.
    String url;
    List<String> candidates;
    AudioQuality quality;
    final localPath = song.isLocal
        ? await LocalPaths.resolve(song.localPath, 'local_music')
        : downloads.localPathFor(song);
    // Local entry whose file is gone: never resolve the bogus
    // 'local:' id remotely — go straight to alt/next.
    if (song.isLocal && localPath == null) {
      await _tryAltOrNext(song, gen, auto: auto, reason: '本地文件不见了');
      return;
    }
    if (localPath != null) {
      url = Uri.file(localPath).toString();
      candidates = [url];
      // The file IS the quality: a downloaded file plays at the tier
      // it was saved at, never at the user's currently requested tier
      // (see [MusicDownloadService.tierFor]). Imported files with no
      // recorded tier fall back to the requested tier.
      quality = downloads.tierFor(song) ?? userQuality.value;
      _lastResolveVia = '';
    } else {
      final cacheKey =
          '${song.songId}|${song.platform.code}|${userQuality.value.code}';
      PlayUrlResult? r;
      // Resolving (or opening a prefetched URL) takes 1–6 s on the
      // network: mark it so the player page can show a spinner.
      _setResolving(true, gen);
      // A cache key is only meaningful with a real song id: two
      // different songs with an empty songId share the key
      // '|platform|quality' and the second would play the first's URL
      // (identityKey now falls back to title+artist, but the raw
      // cache key still uses songId, so the guard stays).
      // A prefetched URL is only trusted while fresh (play URLs
      // expire) and for the exact key. An expired prefetch resolves
      // fresh instead of failing the open on a dead URL.
      if (song.songId.isNotEmpty &&
          _nextCache != null &&
          _nextCache!.key == cacheKey &&
          isPrefetchFresh(_nextCache!.storedAt, DateTime.now())) {
        r = PlayUrlResult(
          url: _nextCache!.url,
          candidates: _nextCache!.candidates,
          quality: _nextCache!.quality,
          via: _nextCache!.via,
        );
        _nextCache = null;
      } else {
        // A resolve throw is a resolve failure, not a crash: fall
        // through to _tryAltOrNext like a null result.
        try {
          r = await _resolvers.resolvePlayUrl(
            song.songId,
            song.platform,
            userQuality.value,
            song.title,
            artist: song.artist,
          );
        } catch (_) {
          AppLog.warn('解析播放地址失败：${song.title}');
          r = null;
        }
      }
      if (gen != _playGen ||
          _disposed ||
          currentSong?.identityKey != loadKey) {
        _setResolving(false, gen);
        return;
      }
      if (r == null || r.url.isEmpty) {
        // _tryAltOrNext keeps the flag (same gen) while it looks for
        // an alt platform, then clears it.
        // A null resolve is only "no source" when every available
        // job was actually tried: if the 8 s budget ran out with
        // jobs still untried, say so instead of claiming no source
        // exists — the retry really does re-try them (a cooled job
        // is only sorted last, never skipped, and the trial
        // exclusion was cleared at the top of this load).
        final reason = _resolvers.lastResolveTruncated
            ? '解析超时，未试完所有音源'
            : '无可用音源';
        await _tryAltOrNext(song, gen, auto: auto, reason: reason);
        return;
      }
      url = r.url;
      candidates = r.candidates;
      quality = r.quality;
      _lastResolveVia = r.via;
    }
    _candidates = candidates;
    _candidateIdx = 0;
    actualQuality.value = quality;
    // A playable URL was obtained: the consecutive-auto-failure
    // chain breaks here (a later open failure is a different song's
    // problem, not this streak's).
    _consecutiveAutoFailures = 0;
    // Best-effort history write: a Hive failure must not break
    // playback (and must not leave isResolving stuck). P1-P4: fire
    // and forget — the write is a whole-table JSON rewrite that must
    // not sit on the track-change hot path. The home page's 最近播放
    // still updates in real time: it listens to hao_recent writes.
    unawaited(
      MusicStore.addRecent(song).catchError((_) {}),
    );
    // P0-1 (continued): the new URL is in hand — only now stop the
    // old song, right before the open. The gen guard: a newer load
    // may have started while this one was resolving, and pausing
    // would then stop a player it already owns.
    if (gen != _playGen || _disposed) {
      _setResolving(false, gen);
      return;
    }
    // The old song stops here, right before the open — and only now
    // does the progress reset for the new song (see the note at the
    // top of this load).
    position.value = Duration.zero;
    duration.value = Duration.zero;
    if (!auto && _playersReady) {
      await _active.pause();
    }
    // try/finally: if the open throws, the spinner must still clear.
    _openedUrl = url;
    try {
      if (auto) {
        await _crossfadeTo(url, gen);
      } else {
        await _openOn(_active, url, auto: auto, gen: gen);
      }
    } finally {
      _setResolving(false, gen);
    }
    if (gen != _playGen || _disposed) return;
    // A real-duration event that arrived during the open's own await
    // was stashed (see [onRealDuration]): process it now that the
    // load has landed.
    _drainPendingRealDuration();
    // Intents the user gave while this load was resolving (pause /
    // seek aimed at the new song): apply them now that it is open.
    await _applyPendingIntents(gen);
    if (gen != _playGen || _disposed) return;
    // The open landed in the active player (manual _openOn, or the
    // crossfade swap in _crossfadeTo): this song is the loaded one
    // now — unless the slot was replaced by an alt-platform song
    // while the open was in flight (the alt branch of
    // _tryAltOrNext already recorded the alt's identity). A failed
    // open diverts into _giveUpOnSong (via _onPlayError) and sets
    // _loadFailed — the failed song must NOT count as loaded, or
    // tapping it again would "resume" instead of retrying.
    if (!_loadFailed && currentSong?.identityKey == loadKey) {
      _loadedIdentityKey = loadKey;
    }
    // The sleep timer may have fired while this load was resolving:
    // the landed song must not sound past the deadline.
    await _pauseIfSleepFired(_active);
    if (resumeSec > 5 || pendingBookmarkSec != null) {
      // Seek only once the duration is known. A bookmark jump wins
      // over the kill-saved resume: the user asked for that exact
      // spot. The resume guard (> 10 s from the end) still applies
      // to the resume path; a bookmark only needs to be inside the
      // track.
      final seekSec = pendingBookmarkSec ?? resumeSec;
      final fromBookmark = pendingBookmarkSec != null;
      unawaited(
        _active.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 5), onTimeout: () => Duration.zero)
            .then((total) async {
          if (gen != _playGen || _disposed) return;
          if (shouldApplyResumeSeek(
            userSeekedSinceOpen: _userSeekedSinceOpen,
            position: position.value,
            total: total,
            seekSec: seekSec,
            fromBookmark: fromBookmark,
          )) {
            await _active.seek(Duration(seconds: seekSec));
          }
        }),
      );
    }
    _prefetchNext();
  }

  /// Process a real-duration event stashed during the open's own
  /// await (see [onRealDuration]). Only called once the load has
  /// landed and [isResolving] is false, so the event is judged
  /// against the song now playing.
  void _drainPendingRealDuration() {
    final pending = _pendingRealDuration;
    _pendingRealDuration = null;
    if (pending != null) onRealDuration(pending);
  }

  /// Apply the pause / seek the user asked for while this load was
  /// resolving. Runs right after the open lands (and after the
  /// gen check, so a superseded load never pauses or seeks the
  /// newer song). A pending seek also marks the position as
  /// user-moved, so the resume seek below never jumps it back.
  Future<void> _applyPendingIntents(int gen) async {
    if (gen != _playGen || _disposed) return;
    final seekTarget = _pendingSeek;
    _pendingSeek = null;
    final pausePending = _pendingPause;
    _pendingPause = false;
    if (seekTarget != null) {
      _userSeekedSinceOpen = true;
      position.value = seekTarget;
      await _active.seek(seekTarget);
    }
    if (pausePending) {
      await _active.pause();
    }
  }

  Future<void> _crossfadeTo(String url, int gen) async {
    final outgoing = _active;
    final incoming = _standby;
    _fadeTimer?.cancel();
    // The envelope multiplies the per-track normalisation gain:
    // the incoming track fades up to ITS gain, the outgoing fades
    // down from the volume it is really at (see _currentNormGain) —
    // never from 1.0, or a normalised track would jump loud at the
    // handover. With normalisation off both are 1.0, exactly the
    // old behaviour.
    final targetVol = normalizationGainFor(currentSong);
    // The outgoing track already ended (the normal auto-advance path:
    // completion fired before the load) — there is nothing to fade
    // out of, so ramping the incoming up from 0 over 2.5 s would only
    // swallow its intro. It starts at full volume instead (see the
    // branch after the swap); the ramp only runs when the outgoing is
    // still sounding (early crossfade).
    final outgoingDone =
        outgoing.processingState == ProcessingState.completed;
    // The standby may already hold this URL buffered from _prefetchNext:
    // reuse it instead of opening cold (the open would re-buffer from
    // scratch and the track change would stutter). A preloaded player
    // that has since gone idle still runs the idle check below.
    _openStarted = true;
    try {
      if (!incoming.isPreloadedFor(url)) {
        // Not preloaded: this open creates the item, so stamp its tap
        // now (the preloaded path was already stamped by
        // _prefetchNext at preload time).
        _pushLoudnessTrackKey(currentSong?.identityKey ?? '');
        // Refused URL: never touched native, so no error stream event
        // will come — fall back on the still-active player instead of
        // swapping in a player with no source.
        if (!await incoming.open(url, play: false)) {
          await _onPlayError(auto: true, gen: gen);
          return;
        }
      }
      if (outgoingDone) {
        await incoming.setVolume(targetVol);
      } else {
        await incoming.setVolume(0);
      }
      await incoming.setRate(speed.value);
      await incoming.play();
    } finally {
      _openStarted = false;
    }
    // The incoming load/play may already have failed before _attach
    // subscribes to its error stream: just_audio's errorStream is a
    // PublishSubject (no replay — just_audio 0.10.6 line 142), and
    // open() swallows the PlayerException and returns true, so a load
    // failure is reported ONLY on that stream — an error emitted
    // before _attach is gone for good, and the fade would run into
    // silence (incoming has no source, outgoing gets paused). A
    // failed load leaves the player idle, and the state
    // (BehaviorSubject-backed, just_audio line 483) is readable
    // synchronously with no subscription, so check it here — BEFORE
    // swapping _active — and run the normal error path, exactly like
    // the refused-URL return above: the candidate opens on the
    // still-active (outgoing) player, no fade starts, nothing goes
    // silent. An error that is still in flight here is caught after
    // _attach by _onStreamError (it checks the same idle state), and
    // a healthy load is never idle at this point (ready / buffering /
    // playing), so the check cannot misfire on a good track.
    if (incoming.processingState == ProcessingState.idle) {
      await _onPlayError(auto: true, gen: gen);
      return;
    }
    // LX generation guard (player.ts diffCurrentMusicInfo): a manual
    // next may have started — and already opened a newer song on the
    // then-active player — while this crossfade's open was in flight.
    // A stale crossfade must never steal _active back or start a fade
    // that pauses the newer song's player.
    if (gen != _playGen || _disposed) return;
    _active = incoming;
    _activeGen = gen;
    _attach(incoming);
    position.value = Duration.zero;
    duration.value = Duration.zero;
    final outgoingStartVol = _currentNormGain;
    _currentNormGain = targetVol;
    if (outgoingDone) {
      await outgoing.pause();
      return;
    }
    final start = DateTime.now();
    const step = Duration(milliseconds: 100);
    _fadeTimer = Timer.periodic(step, (timer) async {
      // A newer load owns the players now: stop touching them (no
      // volume fight, and never pause the newer song's player).
      if (gen != _playGen || _disposed) {
        timer.cancel();
        return;
      }
      final t = DateTime.now().difference(start).inMilliseconds /
          _crossfadeDuration.inMilliseconds;
      if (t >= 1.0 || _disposed) {
        timer.cancel();
        await outgoing.pause();
        await outgoing.setVolume(0);
        await incoming.setVolume(targetVol);
        return;
      }
      await incoming.setVolume(targetVol * t);
      await outgoing.setVolume(outgoingStartVol * (1 - t));
    });
  }

  /// Called when the player's real duration for the current track is
  /// first known (duration subscription in [_attach]; also the seam
  /// tests use to drive the trial path without native audio).
  ///
  /// A track whose real duration is a short clip while the metadata
  /// says it is a full song is a trial/preview URL (NetEase 15 s
  /// preview for VIP songs — chen 2026-11-17): the resolver delivered
  /// a preview, not the song. It plays without error and "completes"
  /// after 15 s, so without this the user hears 15 s and the app
  /// silently moves on. Treat it exactly like a play failure — first
  /// retry the SAME song from another source (see [_handleTrial]),
  /// then fall back to the alt platform, else the next song — instead
  /// of letting the preview play out. See [isTrialClip]
  /// for the false-positive guards (unknown metadata, genuinely
  /// short songs, different-version files).
  void onRealDuration(Duration actual) {
    if (_trialChecked) return;
    if (actual <= Duration.zero) return;
    // LX identity rule for async callbacks: a duration event that
    // arrives while a new song is still resolving belongs to the OLD
    // song (its item was still loading when the user switched) — never
    // let it trigger trial handling for the new song. The one
    // exception is an event that arrives during the open's own await
    // ([_openStarted]): the new item is already loading then, so the
    // event is the NEW song's — stash it and drain it once the load
    // lands (see [_drainPendingRealDuration]) instead of dropping it
    // and letting a 15 s trial clip play out.
    if (isResolving.value) {
      if (_openStarted) _pendingRealDuration = actual;
      return;
    }
    final song = currentSong;
    if (song == null) return;
    _trialChecked = true;
    // A local file's duration is real by definition (and a short
    // download is the user's own file) — never treat it as a trial.
    if (downloads.localPathFor(song) != null) return;
    if (!isTrialClip(metaDurSec: song.dur, actual: actual)) return;
    unawaited(_handleTrial(song));
  }

  Future<void> _handleTrial(Song song) async {
    // The trial URL won the fastest-first race (chen 2026-11-18: Die
    // For You — oiapi served a 30 s clip while lzm/zddyr/gd had the
    // full track). Retry the SAME song from another source first:
    // exclude the job that served the trial URL and re-resolve, up to
    // 2 retries; each retry gets its own trial check. Only when no
    // source yields a full track do we fall through to alt/next.
    // Retrying the same song is NOT hunting for a higher tier (the
    // first-playable law stands): the retry plays the first full
    // track at any tier immediately, it never waits for a better one.
    // Loop while retries remain: each pass excludes the job that
    // served the last URL. A re-resolve that returns the SAME URL
    // string means another job serves the same file — exclude that
    // job too and try again (up to the cap). A different URL is
    // opened immediately.
    while (_trialRetries < 2) {
      final via = _lastResolveVia;
      if (via.isEmpty || _trialExcluded.contains(via)) break;
      _trialExcluded.add(via);
      _trialRetries++;
      _resolvers.evictPlayUrl(
        song.songId,
        song.platform,
        userQuality.value,
      );
      _trialChecked = false;
      PlayUrlResult? r;
      try {
        r = await _resolvers.resolvePlayUrl(
          song.songId,
          song.platform,
          userQuality.value,
          song.title,
          excludeJobs: _trialExcluded,
          artist: song.artist,
        );
      } catch (_) {
        r = null;
      }
      // The user may have moved on while the retry resolved: never
      // open a retry onto a different song.
      if (currentSong?.identityKey != song.identityKey) return;
      if (r == null || r.url.isEmpty) break;
      if (r.url != _openedUrl) {
        _lastResolveVia = r.via;
        _openedUrl = r.url;
        _candidates = r.candidates;
        _candidateIdx = 0;
        actualQuality.value = r.quality;
        // Open directly on the active player (no crossfade): the
        // trial clip is already sounding there — cut it and start
        // the full track from the beginning.
        await _openOn(_active, r.url, auto: _lastLoadAuto);
        return;
      }
      // Same URL from a different job: record its name so the next
      // loop pass excludes it too.
      _lastResolveVia = r.via;
    }
    // Drop the cached preview URL so a replay re-resolves instead of
    // playing the same 15 s clip again.
    _resolvers.evictPlayUrl(song.songId, song.platform, userQuality.value);
    await _tryAltOrNext(song, _playGen, auto: _lastLoadAuto, reason: '只有试听片段');
  }

  /// Error arriving on the active player's error stream (P1-3).
  ///
  /// A late error from a superseded URL must NOT skip the new song:
  /// the error carries no URL, but the player's processing state
  /// tells the two cases apart. just_audio derives the error from
  /// the same playback events that update `processingState`
  /// synchronously, while the error itself is delivered through an
  /// async pipe — so by the time this runs, the state is already
  /// current. A fresh failure leaves the player idle (the native
  /// side sets psIdle when it reports the error); a stale error
  /// arrives while the new source is loading / ready / playing, and
  /// is ignored. Direct `_onPlayError` calls (open() refusing a URL
  /// before any native call) bypass this — there the current track
  /// genuinely cannot play.
  ///
  /// The idle check alone has a hole: while a newer load is still
  /// RESOLVING, the active player is still the old one — idle after
  /// its failure — so a stale error passes the check and, with no
  /// gen, [_onPlayError] used to fail the NEW song (alt-swap or
  /// give-up on a song that never failed). The error is therefore
  /// also stamped with [_activeGen]: when the stamp no longer
  /// matches [_playGen] the error belongs to a superseded load and
  /// is dropped. A genuine error of the current load still matches
  /// (its open stamped this gen before awaiting).
  void _onStreamError() {
    if (!_playersReady) return;
    if (_active.processingState != ProcessingState.idle) return;
    unawaited(_onPlayError(auto: _lastLoadAuto, gen: _activeGen));
  }

  /// A load/open failed for the current track. [auto] is the auto-ness
  /// of the load that failed: a manual load never auto-skips (see
  /// [_giveUpOnSong]); an auto load skips with a notice. [gen] guards
  /// stale crossfades: a superseded load's error must not skip the
  /// new song (its idle check runs after the user already moved on).
  Future<void> _onPlayError({required bool auto, int gen = -1}) async {
    if (gen >= 0 && gen != _playGen) return;
    if (_candidateIdx + 1 < _candidates.length) {
      _candidateIdx++;
      await _openOn(_active, _candidates[_candidateIdx], auto: auto, gen: gen);
      return;
    }
    final song = currentSong;
    if (song == null) return;
    await _tryAltOrNext(song, gen < 0 ? _playGen : gen, auto: auto, reason: '无法播放');
  }

  /// Alt-platform fallback, then give up (see [_giveUpOnSong]).
  /// [auto] decides the give-up behaviour: manual loads stop on the
  /// song with a notice, auto-advance skips with a notice. [reason]
  /// is the failure cause, carried into the notice.
  Future<void> _tryAltOrNext(
    Song song,
    int gen, {
    required bool auto,
    required String reason,
  }) async {
    // The resolving flag stays up while the alt lookup runs (up to
    // 5 s after the findAltPlatform cap, 2 s on the auto path —
    // M-P1-4). try/finally so a throw in the lookup / open still
    // clears the flag; the gen guard makes the clear a no-op if a
    // newer load owns it by then.
    final g = gen < 0 ? _playGen : gen;
    _setResolving(true, g);
    try {
      if (!_altTried) {
        _altTried = true;
        // M-P1-4: the auto path is silent (the previous song already
        // ended), so the alt rescue gets a tight combined budget —
        // 2 s for the lookup + 2 s for the re-resolve — instead of
        // the 5 s + 8 s that used to stretch the silence to ~21 s.
        // Manual loads keep the full budgets: the old song is still
        // playing while they run, so there is no silence to bound.
        final alt = await _api.findAltPlatform(
          song.title,
          song.artist,
          song.platform,
          song.album,
          timeout:
              auto ? const Duration(seconds: 2) : const Duration(seconds: 5),
        );
        if (alt != null) {
          final r = await _resolvers.resolvePlayUrl(
            alt.songId,
            alt.platform,
            userQuality.value,
            alt.title,
            artist: alt.artist,
            totalBudget: auto
                ? const Duration(seconds: 2)
                : const Duration(seconds: 8),
          );
          if (r != null && r.url.isNotEmpty) {
            // The track may have advanced while the alt lookup was in
            // flight (trial path): never replace a different song.
            if (currentSong?.identityKey != song.identityKey) return;
            queue[currentIndex.value] = alt;
            queue.refresh();
            _persistQueue();
            _candidates = r.candidates;
            _candidateIdx = 0;
            actualQuality.value = r.quality;
            _lastResolveVia = r.via;
            _openedUrl = r.url;
            // The alt song is the song now playing: it belongs in
            // Recent exactly like a directly resolved song (the main
            // path records it in _loadCurrent; this branch never did).
            unawaited(
              MusicStore.addRecent(alt).catchError((_) {}),
            );
            // The alt is a new URL for this slot: its real duration
            // gets its own trial check.
            _trialChecked = false;
            // P0-1: same rule as the main path — the old song kept
            // playing through the alt lookup; stop it only now that
            // the alt URL is in hand (manual loads only; auto keeps
            // the crossfade fallback behaviour).
            if (!auto && _playersReady) {
              await _active.pause();
            }
            await _openOn(_active, r.url, auto: auto, gen: g);
            // The alt song's audio is in the active player now (same
            // guards as [_loadCurrent]: a diverted open must not
            // mark the alt as loaded — _onPlayError either starts a
            // newer load (gen bumped) or gives up (_loadFailed)).
            if (!_loadFailed && g == _playGen) {
              _loadedIdentityKey = alt.identityKey;
            }
            // Same post-open steps as the main path: stashed trial
            // duration + pause/seek the user asked for mid-resolve.
            if (g == _playGen) {
              _drainPendingRealDuration();
              await _applyPendingIntents(g);
            }
            return;
          }
        }
      }
      // Stale alt path (a newer load owns the players now): never
      // skip the new song.
      if (g != _playGen) return;
      await _giveUpOnSong(song, auto: auto, reason: reason);
    } finally {
      _setResolving(false, g);
    }
  }

  /// Give up on [song] after every fallback failed (no playable URL,
  /// alt platform failed, trial retries exhausted).
  ///
  /// Manual load (the user tapped this song): NEVER auto-skip — stop
  /// on the song, record the failure for the player UI, and notice
  /// with 重试 / 下一首 actions. The old song keeps playing: a manual
  /// load only pauses it once a new URL is in hand (P0-1), so a
  /// failed resolve never silenced it in the first place.
  ///
  /// Auto-advance (the previous song ended, or a skip chain): advance
  /// to the next DIFFERENT track with a notice naming the skipped
  /// song and the reason. The advance uses manual index semantics:
  /// single-loop's auto-replay would return the SAME index and retry
  /// the dead song forever, and single-play's auto-stop would strand
  /// the queue. After 3 consecutive auto failures the chain stops
  /// instead of walking (and toast-spamming) through a dead queue.
  /// When there is no next track, the active player is paused: the
  /// crossfade fallback leaves the previous song sounding, and the
  /// chain ending must not leave it playing (chen 2026-11-18: a
  /// failed song "直接放的还是上一首歌").
  Future<void> _giveUpOnSong(
    Song song, {
    required bool auto,
    required String reason,
  }) async {
    AppLog.error('无法播放：${song.title}（$reason）');
    _loadFailed = true;
    if (!auto) {
      loadError.value = (song: song, reason: reason);
      _notice('《${song.title}》$reason，点重试可再试一次', withActions: true);
      return;
    }
    _consecutiveAutoFailures++;
    if (_consecutiveAutoFailures >= 3) {
      if (_playersReady) await _active.pause();
      _notice('连续多首$reason，已停止播放');
      return;
    }
    // Advance to the next DIFFERENT track (manual index semantics —
    // see the doc comment above). The new load runs first: only when
    // it is actually playing do we announce the skip. When the new
    // song failed itself, its own give-up already notified, and
    // overwriting it would name the wrong song.
    final n = _peekNextIndex(auto: false);
    if (n < 0) {
      // No next track: stop, so the previous song (crossfade fallback)
      // does not keep sounding after the chain gives up.
      if (_playersReady) await _active.pause();
      _notice('《${song.title}》$reason，已是最后一首');
      return;
    }
    currentIndex.value = n;
    _persistQueue();
    await _loadCurrent(auto: true);
    if (!_loadFailed) {
      _notice('《${song.title}》$reason，已跳到下一首');
    }
  }

  void _onTrackCompleted() {
    // A completion from the old player while a newer load is still
    // resolving belongs to a song the user already left: ignore it
    // entirely. Advancing here would skip the song the user tapped
    // (the index already moved), replay the old song under
    // single-loop, or stop under single-play — and the session
    // finalise / resume-clear below would close the NEW song's
    // just-begun session.
    if (isResolving.value) return;
    final song = currentSong;
    if (song != null) {
      unawaited(MusicStore.clearResume(song.identityKey));
    }
    // The finished song's listen session ends HERE, not when the
    // next track loads: at the end of the queue next() returns early
    // without loading anything, so the last song was never recorded
    // until the app was killed or another song started. Finalising
    // twice is a no-op (finish() returns null once the session is
    // closed), so the single-loop replay and the next() path below —
    // which finalise again via _loadCurrent — stay correct.
    unawaited(_finalizeListenSession());
    // Wall-clock sleep timer already fired: the track ended during
    // the 1 s fade-out — stop here, do not auto-advance. The gen
    // flag ([_pauseIfSleepFired]) cannot catch this: the advance
    // bumps the gen, so the landing load would look like the user's
    // explicit play and keep sounding past the deadline.
    if (_sleepFired) {
      _sleepTimer.cancel();
      if (_playersReady) unawaited(_active.pause());
      _syncSleepState();
      return;
    }
    // Sleep timer, 播完本首后停止 (1.1.6): the track ends here —
    // stop, do not advance or loop, and clear the timer. Checked
    // BEFORE single-loop: under 单曲循环 the track would otherwise
    // never end, so the timer would never stop it.
    if (_sleepTimer.isCurrentTrackEnd) {
      _sleepTimer.cancel();
      if (_playersReady) unawaited(_active.pause());
      _syncSleepState();
      return;
    }
    // Sleep timer, 播完 N 首后停止 (1.1.6): only natural completions
    // reach here — manual next/prev, taps and failed skips never
    // call _onTrackCompleted, so they never count. The track that
    // was playing when the mode started counts when it completes.
    // At the target, stop here: the next track has not started yet
    // (crossfade only starts inside the next _loadCurrent), so there
    // is no half-faded-in track to cut off.
    if (_sleepTimer.isAfterNTracks) {
      final reached = _sleepTimer.noteTrackCompleted();
      if (reached) {
        _sleepTimer.cancel();
        if (_playersReady) unawaited(_active.pause());
        _syncSleepState();
        return;
      }
      _syncSleepState();
    }
    // Sleep timer, 到歌单结束: the queue ends here — stop, do not
    // advance or loop, and clear the timer.
    if (_sleepTimer.isQueueEnd) {
      _sleepTimer.cancel();
      if (_playersReady) unawaited(_active.pause());
      _syncSleepState();
      return;
    }
    // Single loop: replay the same song from the start.
    if (mode == PlayMode.singleLoop) {
      unawaited(_replayCurrent());
      return;
    }
    unawaited(next(auto: true));
  }

  Future<void> _replayCurrent() async {
    final song = currentSong;
    if (song == null) return;
    // Single loop replays from the start: the finished play-through
    // counts as its own session, the replay starts a new one.
    unawaited(_finalizeListenSession());
    _listenTracker.begin(song, DateTime.now());
    await _active.seek(Duration.zero);
    await _active.play();
  }

  /// Start the next song's load early so the crossfade overlaps the
  /// current track's tail instead of starting after it ended. Only
  /// fires once per track, only while playing, and only when the next
  /// track's URL is already prefetched — a slow resolve would land
  /// after the song ends anyway (and the completion path + the
  /// ramp-skip in [_crossfadeTo] cover that), and starting a slow
  /// load early would let a last-second seek-back still change the
  /// song. Single-loop replays at completion instead.
  void _maybeStartEarlyCrossfade(Duration pos) {
    if (!isPlaying.value || isResolving.value) return;
    if (_earlyCrossfadeStarted) return;
    final total = duration.value;
    if (total <= Duration.zero) return;
    if (total - pos > _crossfadeDuration) return;
    if (mode == PlayMode.singleLoop) return;
    final n = _peekNextIndex(auto: true);
    if (n < 0) return;
    final nextSong = queue[n];
    final key =
        '${nextSong.songId}|${nextSong.platform.code}|${userQuality.value.code}';
    if (_nextCache == null || _nextCache!.key != key) return;
    _earlyCrossfadeStarted = true;
    unawaited(next(auto: true));
  }

  void _prefetchNext() {
    final next = _peekNextIndex(auto: true);
    if (next < 0 || next == currentIndex.value) return;
    final tr = queue[next];
    // A downloaded next track plays from disk — nothing to prefetch.
    if (downloads.localPathFor(tr) != null) return;
    // No real song id, no meaningful cache key (see _loadCurrent).
    if (tr.songId.isEmpty) return;
    final key = '${tr.songId}|${tr.platform.code}|${userQuality.value.code}';
    if (_nextCache != null && _nextCache!.key == key) return;
    unawaited(
      _resolvers.resolvePlayUrl(
        tr.songId,
        tr.platform,
        userQuality.value,
        tr.title,
        artist: tr.artist,
        // M-P1-5: background resolve — a prefetch failure must not
        // cool the source or pollute the speed ranking; only a
        // success updates the ranking.
        background: true,
      )
          .then((r) {
        if (r != null && r.url.isNotEmpty) {
          // LX: a fetched URL only lands where it was fetched for.
          // The queue may have moved on while this resolve was in
          // flight — never let a stale prefetch overwrite the cache
          // for a different next song.
          final now = _peekNextIndex(auto: true);
          if (now < 0 || queue[now].identityKey != tr.identityKey) return;
          _nextCache = (
            key: key,
            url: r.url,
            candidates: r.candidates,
            quality: r.quality,
            via: r.via,
            storedAt: DateTime.now(),
          );
          // Pre-buffer the audio on the standby player (the crossfade
          // reuses it — see _crossfadeTo). If a crossfade is still
          // running, the standby IS the fading-outgoing player: wait
          // for the fade to finish first, or replacing its source
          // mid-fade would cut the old song dead instead of fading
          // it out. The queue is re-checked at preload time.
          final delay = _fadeTimer?.isActive == true
              ? _crossfadeDuration
              : Duration.zero;
          unawaited(
            Future.delayed(delay, () async {
              if (_disposed || !_playersReady) return;
              final still = _peekNextIndex(auto: true);
              if (still < 0 ||
                  queue[still].identityKey != tr.identityKey) {
                return;
              }
              if (_nextCache?.key != key) return;
              // Stamp the preload's tap with the NEXT song's key:
              // the tap is created here, before that song's
              // _loadCurrent runs — a stamp pushed only in
              // _loadCurrent would arrive too late and the report
              // would be attributed to the song now playing.
              _pushLoudnessTrackKey(tr.identityKey);
              await _standby.preload(r.url).catchError((_) => false);
            }),
          );
        }
      }),
    );
  }

  /// Next index honouring the play mode; -1 = stop at the queue end.
  /// Auto-advance and a manual tap differ for single loop / single
  /// play — see nextTrackIndex in play_mode.dart.
  ///
  /// A one-song queue in a looping mode (list loop / single loop /
  /// shuffle) replays the only song instead of stopping. The failure
  /// path still terminates: [_giveUpOnSong] stops the chain after 3
  /// consecutive auto failures, so a dead single song is retried at
  /// most twice before the chain stops.
  int _peekNextIndex({required bool auto}) {
    if (queue.length <= 1) {
      // A one-song queue: single loop replays on auto-advance (handled
      // in _onTrackCompleted via _replayCurrent); a looping mode
      // replays the only song instead of stopping; anything else stops.
      if (queue.length == 1 &&
          (mode == PlayMode.listLoop ||
              mode == PlayMode.singleLoop ||
              mode == PlayMode.shuffle)) {
        return 0;
      }
      return -1;
    }
    return nextTrackIndex(
      mode,
      currentIndex.value,
      queue.length,
      auto: auto,
    );
  }

  int _peekPrevIndex() {
    if (queue.length <= 1) {
      if (queue.length == 1 &&
          (mode == PlayMode.listLoop ||
              mode == PlayMode.singleLoop ||
              mode == PlayMode.shuffle)) {
        return 0;
      }
      return -1;
    }
    return prevTrackIndex(mode, currentIndex.value, queue.length);
  }

  // -- transport ---------------------------------------------------------------

  Future<void> next({bool auto = false}) async {
    final n = _peekNextIndex(auto: auto);
    if (n < 0) return;
    currentIndex.value = n;
    _persistQueue();
    await _loadCurrent(auto: auto);
  }

  Future<void> prev() async {
    // Restart the current track when more than 3 s in (established
    // in-app behaviour), else go to the previous track.
    if (position.value > const Duration(seconds: 3)) {
      final song = currentSong;
      if (song != null) {
        unawaited(_finalizeListenSession());
        _listenTracker.begin(song, DateTime.now());
      }
      await _active.seek(Duration.zero);
      return;
    }
    final n = _peekPrevIndex();
    if (n < 0) return;
    currentIndex.value = n;
    _persistQueue();
    await _loadCurrent();
  }

  Future<void> togglePlayPause() async {
    if (isPlaying.value) {
      // Pausing while a load is resolving must stick: the new song
      // lands paused (see [_pendingPause]).
      if (isResolving.value) _pendingPause = true;
      await _fadeOutThenPause();
    } else {
      _pendingPause = false;
      await _playCurrentOrResume();
    }
  }

  /// Fade out (~400 ms) then pause; with fading off, or with no
  /// players yet (unit tests), pause immediately. The volume is
  /// restored to the track's sounding gain afterwards, so a manual
  /// resume is not silent. A newer load (gen bumped mid-fade) stops
  /// the fade touching the new song's player.
  Future<void> _fadeOutThenPause() async {
    if (!_playersReady) return;
    // A crossfade in flight owns the standby (the fading outgoing):
    // stop its ramp now, or it keeps writing volumes and sounding
    // after the pause — and pause the standby with the active below,
    // or its tail plays for up to 2.5 s after the user hit pause.
    _fadeTimer?.cancel();
    if (!fadeEnabled.value) {
      // Pausing mid-fade would freeze the incoming at a mid-ramp
      // volume: snap it to its target first so a later resume plays
      // at full volume.
      await _active.setVolume(_currentNormGain);
      await _active.pause();
      await _standby.pause();
      return;
    }
    final gen = _playGen;
    // Start from the volume it is really at, not the target gain:
    // pausing during the 400 ms resume fade-in would otherwise jump
    // to full before fading out. Bumping _fadeGen stops the
    // still-running fade-in ramp fighting this fade-out.
    final startVol = _active.volume.clamp(0.0, 1.0);
    _fadeGen++;
    await VolumeFader.ramp(
      setVolume: _active.setVolume,
      from: startVol,
      to: 0,
      duration: const Duration(milliseconds: 400),
      isCancelled: () => gen != _playGen || _disposed,
    );
    if (gen != _playGen || _disposed) return;
    await _active.pause();
    await _standby.pause();
    await _active.setVolume(startVol);
  }

  /// Fade a paused, loaded track back in (~400 ms) instead of
  /// resuming at full volume (build 29 — the "恢复" half of fade
  /// in/out; pause fades out, resume fades in). With fading off,
  /// or with no players yet (unit tests), play immediately / no-op.
  /// A newer load (gen bumped mid-fade) stops the ramp touching
  /// the new song's player.
  Future<void> _fadeInThenPlay() async {
    if (!_playersReady) return;
    if (!fadeEnabled.value || _currentNormGain <= 0) {
      await _active.play();
      return;
    }
    final gen = _playGen;
    final fadeGen = _fadeGen;
    await _active.setVolume(0);
    await _active.play();
    unawaited(
      VolumeFader.ramp(
        setVolume: _active.setVolume,
        from: 0,
        to: _currentNormGain,
        duration: const Duration(milliseconds: 400),
        isCancelled: () =>
            gen != _playGen || _fadeGen != fadeGen || _disposed,
      ),
    );
  }

  /// Play when a track is loaded; on a fresh launch (or after a
  /// failed load) nothing is in the player yet, so a bare play is a
  /// no-op (build 29: [_fadeInThenPlay] returns early with no
  /// players — the old bare `_active.play()` threw on the late
  /// [_active] instead) and the tap does nothing (chen 2026-11-20: 刚进 app 点播放歌曲
  /// 不播放，要切到下一首歌才播放). Load the restored current song
  /// through the normal path instead. A load already in flight is
  /// left alone (it plays when it lands); a loaded-but-paused track
  /// still resumes without reloading.
  Future<void> _playCurrentOrResume() async {
    if (isPlaying.value) return;
    // Manual resume after a sleep stop: the user chose to keep
    // listening — the fired flag must not stop the next completion,
    // and a sleep fade still running must not pause the resumed
    // track when it ends.
    _sleepFired = false;
    _sleepFadeTimer?.cancel();
    if (_playersReady &&
        _loadedIdentityKey.isEmpty &&
        currentSong != null &&
        !isResolving.value) {
      await playIndex(currentIndex.value);
      return;
    }
    // Loaded-but-paused: resume with a fade-in (build 29). With no
    // players yet this is a no-op instead of touching the late
    // [_active] (the old bare `_active.play()` threw here).
    await _fadeInThenPlay();
  }

  /// Pause playback if currently playing; no-op when already paused.
  /// Used by the VOD player page and the live room to silence music
  /// the moment a film / live stream starts playing (never on
  /// browsing the video tab / live list / detail page). No
  /// auto-resume: the user resumes music manually.
  Future<void> pause() async {
    if (!isPlaying.value) return;
    // A pause during a resolve must stick past the landing.
    if (isResolving.value) _pendingPause = true;
    await _fadeOutThenPause();
  }

  /// Seek to [pos]. The position updates optimistically so the bar
  /// does not jump back to the pre-drag position while the native
  /// position stream catches up. During a resolve the seek belongs
  /// to the song still loading: it is stored and applied once that
  /// song opens instead of seeking the old song.
  Future<void> seek(Duration pos) async {
    _userSeekedSinceOpen = true;
    position.value = pos;
    if (isResolving.value) {
      _pendingSeek = pos;
      return;
    }
    await _active.seek(pos);
  }

  // -- playback speed (M-P0-2) ------------------------------------------------

  /// Clamp a speed to the supported range (slider 0.5–2.0, build 29 —
  /// was 0.6–2.0; the native fork already pins every AVPlayerItem to
  /// AVAudioTimePitchAlgorithmTimeDomain, so 0.5x stays pitch-correct).
  static double clampSpeed(double v) => v.clamp(0.5, 2.0);

  /// Set the playback speed. Takes effect immediately on the audio
  /// rate (both players, so a crossfade partner keeps the same rate)
  /// and persists like quality. Lyrics need no adjustment: they are
  /// keyed to the media clock (`lyricIndexFor(position)`), and the
  /// media clock advances at the playback rate, so lyrics stay in
  /// sync at any speed.
  Future<void> setSpeed(double v) async {
    final s = clampSpeed(v);
    speed.value = s;
    await MusicStore.setSpeed(s);
    _applyRate();
  }

  void _applyRate() {
    if (!_playersReady) return;
    unawaited(_active.setRate(speed.value));
    unawaited(_standby.setRate(speed.value));
  }

  /// Cycle through the five play modes (顺序播放 → 列表循环 → 单曲循环 →
  /// 随机播放 → 单曲播放) and persist the choice in Hive.
  Future<void> cyclePlayMode() async {
    playMode.value = mode.next.code;
    await MusicStore.setPlayMode(playMode.value);
  }

  /// Back-compat alias: the old two-mode toggle is now the five-mode cycle.
  Future<void> togglePlayMode() => cyclePlayMode();

  // -- fade / A-B loop / lyric display (build 29) ---------------------

  /// Turn fade in/out on/off (persisted; default on). Takes effect
  /// from the next pause / open — the sounding track never jumps.
  Future<void> setFadeEnabled(bool value) async {
    fadeEnabled.value = value;
    try {
      await HiveStore.put('hao_music_fade_enabled', value);
    } catch (_) {}
  }

  /// Set point A of the A-B loop at the current position.
  void setAbPointA() {
    abLoop.setA(position.value);
    abLoopVersion.value++;
  }

  /// Set point B of the A-B loop at the current position. Ignored
  /// without an A, or at/before A (see AbLoop).
  void setAbPointB() {
    abLoop.setB(position.value);
    abLoopVersion.value++;
  }

  /// Clear the A-B loop.
  void clearAbLoop() {
    if (!abLoop.hasA && !abLoop.hasB) return;
    abLoop.clear();
    abLoopVersion.value++;
  }

  /// Set the lyric offset in ms (±5000, persisted).
  Future<void> setLyricOffsetMs(int ms) async {
    lyricOffsetMs.value = LyricDisplay.clampOffsetMs(ms);
    try {
      await HiveStore.put('hao_music_lyric_offset_ms', lyricOffsetMs.value);
    } catch (_) {}
  }

  /// Show/hide the translation line under the active lyric
  /// (persisted; default on).
  Future<void> setShowLyricTranslation(bool value) async {
    showLyricTranslation.value = value;
    try {
      await HiveStore.put('hao_music_lyric_show_translation', value);
    } catch (_) {}
  }

  // -- sleep timer (M-P0-3) -----------------------------------------------------

  /// Wall-clock timer fired: STOP playback and clear the timer. A
  /// load in flight (previous song ended, next still resolving)
  /// must not sound when it lands: record its gen so the landing
  /// open pauses instead (see [_pauseIfSleepFired]). The fire's own
  /// pause covers what is sounding now; the flag covers what lands
  /// next. The stop fades out over 1 s ([_fadeOutAndPause]) instead
  /// of cutting hard — completion-mode stops (current-track-end /
  /// after-N-tracks / queue-end) need no fade: the track already
  /// ended, so there is nothing sounding to fade.
  void _onSleepTimerFired() {
    _sleepFiredGen = _playGen;
    _sleepFired = true;
    // The sleep stop owns the players now: a crossfade in progress
    // must stop fading the incoming song IN — the sleep fade-out
    // takes over from the volume it is really at (see
    // [_fadeOutAndPause]).
    _fadeTimer?.cancel();
    if (_playersReady) unawaited(_fadeOutAndPause());
    _syncSleepState();
  }

  /// Fade the sounding track out over 1 s, then pause. The volume
  /// is restored to the track's sounding gain afterwards, so a
  /// manual resume is not silent. A newer load (gen bumped — the
  /// user tapped another song mid-fade) stops the fade touching
  /// the new song's player. The standby is paused too: if the fire
  /// lands mid-crossfade the outgoing partner is still sounding.
  /// Runs on its own [_sleepFadeTimer], never the shared [_fadeTimer]:
  /// a crossfade starting after the fire must not cancel this fade,
  /// and this fade must not cancel a crossfade's timer either — the
  /// fire itself cancels the crossfade above, in [_onSleepTimerFired].
  Future<void> _fadeOutAndPause() async {
    final gen = _playGen;
    final player = _active;
    // Start from the volume it is really at, not the target gain:
    // mid-crossfade the incoming song is still fading in, and
    // restarting from full jumps loud before fading out.
    final startVol = player.volume.clamp(0.0, 1.0);
    _fadeGen++;
    _sleepFadeTimer?.cancel();
    final start = DateTime.now();
    const step = Duration(milliseconds: 100);
    _sleepFadeTimer = Timer.periodic(step, (timer) async {
      if (gen != _playGen || _disposed) {
        timer.cancel();
        return;
      }
      final t =
          DateTime.now().difference(start).inMilliseconds / 1000.0;
      if (t >= 1.0 || _disposed) {
        timer.cancel();
        await player.pause();
        await _standby.pause();
        await player.setVolume(startVol);
        return;
      }
      await player.setVolume(startVol * (1 - t));
    });
  }

  /// Pause [player] if the sleep timer fired while its load was in
  /// flight. The flag is consumed on the first check either way: a
  /// NEWER load (gen bumped after the fire) is the user's explicit
  /// play and is untouched. Called after every landing open on the
  /// active player ([_openOn] and the crossfade landing in
  /// [_loadCurrent]).
  Future<void> _pauseIfSleepFired(AvMusicPlayer player) async {
    if (_sleepFiredGen < 0) return;
    final firedForCurrent = _playGen == _sleepFiredGen;
    _sleepFiredGen = -1;
    if (firedForCurrent && _playersReady) await player.pause();
  }

  /// Test seam: simulate the sleep timer firing while a load is in
  /// flight. Only the flag is set here — the wall-clock timer and
  /// the pause of the sounding player are SleepTimer's / onFire's
  /// own paths (covered by sleep_timer_test.dart); this seam covers
  /// the resolve-window half: what a landing load does.
  @visibleForTesting
  void fireSleepTimerForTest() {
    _sleepFiredGen = _playGen;
  }

  void _syncSleepState() {
    sleepOption.value = _sleepTimer.option;
    sleepRemaining.value = _sleepTimer.remaining;
    sleepCustomMinutes.value = _sleepTimer.customMinutes;
    sleepTrackCount.value = _sleepTimer.trackTarget;
    sleepTracksCompleted.value = _sleepTimer.tracksCompleted;
  }

  /// Human label for the active sleep timer, with the custom
  /// minutes filled in ("自定义 45 分钟" — the enum label alone is
  /// just "自定义") and the N count for after-N-tracks ("播完 3 首后
  /// 停止" — the enum label alone is just "播完 N 首后停止").
  String get sleepLabel {
    if (sleepOption.value == SleepTimerOption.custom) {
      return '自定义 ${sleepCustomMinutes.value} 分钟';
    }
    if (sleepOption.value == SleepTimerOption.afterNTracks) {
      return '播完 ${sleepTrackCount.value} 首后停止';
    }
    return sleepOption.value.label;
  }

  /// Start (or replace) the sleep timer. `off` cancels it.
  /// `custom` replays the persisted custom minutes (the sheet writes
  /// them first via [setSleepTimerMinutes]); `afterNTracks` replays
  /// the last N target (set via [setSleepTimerAfterNTracks] /
  /// [setSleepTrackCount]).
  void setSleepTimer(SleepTimerOption option) {
    if (option == SleepTimerOption.custom) {
      setSleepTimerMinutes(MusicStore.sleepCustomMinutes);
      return;
    }
    if (option == SleepTimerOption.afterNTracks) {
      setSleepTimerAfterNTracks(_sleepTimer.trackTarget);
      return;
    }
    _sleepTimer.start(option);
    _syncSleepState();
  }

  /// Start a "播完 N 首后停止" run (clamp 1..10, bad input 3). The
  /// count restarts from zero.
  void setSleepTimerAfterNTracks(int count) {
    _sleepTimer.startAfterNTracks(count);
    _syncSleepState();
  }

  /// Change the N target of a running "播完 N 首后停止" timer. The
  /// count restarts from zero ("改 N 从当下重计"); with no run
  /// active the target is just remembered for the next run.
  void setSleepTrackCount(int count) {
    _sleepTimer.setTrackTarget(count);
    _syncSleepState();
  }

  /// Start a custom-minutes sleep timer (stage 2, Beans
  /// `SleepTimerSheet` 自定义时长: clamp 1..720, bad input 30).
  /// The minutes are persisted so the next open remembers them.
  /// The stop-at-fire logic is unchanged (the timer pauses playback).
  void setSleepTimerMinutes(int minutes) {
    final clamped = clampSleepCustomMinutes(minutes);
    unawaited(MusicStore.setSleepCustomMinutes(clamped));
    sleepCustomMinutes.value = clamped;
    _sleepTimer.startCustom(clamped);
    _syncSleepState();
  }

  /// Cancel the sleep timer.
  void cancelSleepTimer() {
    _sleepTimer.cancel();
    _syncSleepState();
  }

  /// Test seam: drive the track-completed path without native audio
  /// (same pattern as [fireSleepTimerForTest]). The counting / stop
  /// branches are what tests exercise here; advancing to the next
  /// track still goes through the normal [next] path.
  @visibleForTesting
  void simulateTrackCompletedForTest() => _onTrackCompleted();

  /// Test seam: drive the position listener's logic without native
  /// audio (the real position stream is silent on Linux test runs).
  @visibleForTesting
  void simulatePositionForTest(Duration p) {
    position.value = p;
    _maybeStartEarlyCrossfade(p);
  }

  /// Test seam: run the real wall-clock fire path (1 s fade-out +
  /// pause) without waiting for a real countdown. The countdown
  /// itself is SleepTimer's (covered by sleep_timer_test.dart).
  @visibleForTesting
  void simulateSleepTimerFiredForTest() => _onSleepTimerFired();

  // -- volume normalisation (1.1.6, strategy A) -------------------------

  /// Target loudness (streaming-standard -14 LUFS). A track louder
  /// than this is attenuated towards it; a quieter track is never
  /// boosted (the player-volume path caps at 1.0 — see
  /// [normalizationGainLinear]).
  static const double normalizationTargetLufs = -14.0;

  /// Max attenuation per strength level (0 = 轻度, 1 = 标准,
  /// 2 = 强力). Fixed -14 LUFS target; no custom target in v1
  /// (one fewer slider, one fewer mis-tap).
  static const List<double> normalizationMaxCutDb = [3.0, 6.0, 12.0];

  /// Pure gain math (unit-tested): attenuation-only linear gain for
  /// a measured [lufs] at [strength] (0..2, clamped). Returns 1.0
  /// when the track is at or below target (never boosts), and never
  /// below the level's max cut. No state, no I/O.
  static double normalizationGainLinear({
    required double lufs,
    required int strength,
  }) {
    if (!lufs.isFinite) return 1.0;
    final maxCut = normalizationMaxCutDb[strength.clamp(0, 2)];
    final db = (normalizationTargetLufs - lufs).clamp(-maxCut, 0.0);
    return math.pow(10, db / 20).toDouble();
  }

  /// The gain the player volume should sit at for [song]: 1.0
  /// unless normalisation is on AND this track has a measured
  /// loudness. A track that has never been measured plays at 1.0 —
  /// measurement happens during playback (see
  /// [noteMeasuredLoudness]), so the first play is never delayed
  /// or changed, and the gain takes effect from the second play.
  /// Applies to the NEXT load, never mid-song (no audible jump).
  double normalizationGainFor(Song? song) {
    if (!normalizationEnabled.value || song == null) return 1.0;
    final lufs = _measuredLufs[song.identityKey];
    if (lufs == null) return 1.0;
    return normalizationGainLinear(
      lufs: lufs,
      strength: normalizationStrength.value,
    );
  }

  /// Record a track's integrated loudness (LUFS), measured during
  /// playback in the EQ tap — the feed-in point for the native tap
  /// wiring (method channel, via EqualizerStore.onLoudnessMeasured).
  /// Only the value is stored here; the gain is applied by
  /// [normalizationGainFor] on the next load. Never pre-downloads
  /// or decodes a track for loudness (that would break the "点播 1
  /// 秒出声" rule), and never touches ffmpeg / loudnorm or any
  /// GPL/AGPL loudness code. Stored in-memory (cap 200, oldest
  /// dropped) AND written through to the Hive cache
  /// ([HiveKeys.musicLoudnessCache], same cap) so the second-play
  /// effect survives a restart; the Hive write is best-effort (a
  /// failure only loses persistence, never the in-memory value).
  /// The in-memory map IS the merged truth, so the write is a plain
  /// put of it — no read-modify-write race between two taps
  /// finalizing close together.
  void noteMeasuredLoudness(String identityKey, double lufs) {
    if (identityKey.isEmpty || !lufs.isFinite) return;
    _measuredLufs.remove(identityKey);
    _measuredLufs[identityKey] = lufs.clamp(-70.0, 0.0);
    while (_measuredLufs.length > 200) {
      _measuredLufs.remove(_measuredLufs.keys.first);
    }
    unawaited(_persistLoudnessCache());
  }

  /// Best-effort write of the in-memory loudness map to Hive.
  Future<void> _persistLoudnessCache() async {
    try {
      await HiveStore.put(
        HiveKeys.musicLoudnessCache,
        Map<String, double>.of(_measuredLufs),
      );
    } catch (_) {}
  }

  /// Parse the persisted loudness cache ({identityKey: LUFS double})
  /// into a clean map. Junk is dropped, not trusted: non-map input
  /// yields empty, non-numeric values and empty keys are skipped,
  /// non-finite values are skipped, values clamp to -70..0, and the
  /// map caps at 200 entries (oldest dropped). Pure, unit-tested.
  static Map<String, double> parseLoudnessCache(dynamic raw) {
    final out = <String, double>{};
    if (raw is Map) {
      for (final entry in raw.entries) {
        final key = entry.key?.toString() ?? '';
        // `as num?` throws on a String value — check first.
        final value =
            entry.value is num ? (entry.value as num).toDouble() : null;
        if (key.isEmpty || value == null || !value.isFinite) continue;
        out[key] = value.clamp(-70.0, 0.0);
      }
    }
    while (out.length > 200) {
      out.remove(out.keys.first);
    }
    return out;
  }

  /// Stamp the native EQ tap with the identityKey of the track
  /// whose item is about to be created (open / preload). The tap's
  /// finalize loudness report is attributed by that stamp — without
  /// it, A/B crossfade overlap would mix two tracks' measurements.
  /// Fire-and-forget, fully guarded: no native engine (tests /
  /// Android / EQ off) only loses that track's measurement, never
  /// playback. Called with the song being opened, never with a
  /// stale one — see the call sites.
  void _pushLoudnessTrackKey(String identityKey) {
    if (identityKey.isEmpty) return;
    try {
      unawaited(EqualizerStore.ensure().setTrackKey(identityKey));
    } catch (_) {}
  }

  /// Turn normalisation on/off (persisted; default off). Takes
  /// effect from the next track load — the sounding track never
  /// jumps mid-song.
  Future<void> setNormalizationEnabled(bool value) async {
    normalizationEnabled.value = value;
    try {
      await HiveStore.put(HiveKeys.musicNormalizationEnabled, value);
    } catch (_) {}
  }

  /// Set the strength level 0..2 (persisted; default 1 = 标准).
  /// Out of range clamps. Takes effect from the next track load.
  Future<void> setNormalizationStrength(int strength) async {
    final clamped = strength.clamp(0, 2);
    normalizationStrength.value = clamped;
    try {
      await HiveStore.put(HiveKeys.musicNormalizationStrength, clamped);
    } catch (_) {}
  }

  // -- bookmarks + breakpoint resume (1.1.6) -----------------------------

  /// Save a bookmark at the current position of [song]. Only the
  /// song now playing has a position to save — any other song
  /// returns null (its progress is unknown). Position 0 is not a
  /// bookmark. The breakpoint-resume rule is untouched: the resume
  /// position is still saved ONLY on app kill (see
  /// [_saveResumeOnKill]); bookmarks are the explicit, user-saved
  /// counterpart and never touch the resume map.
  Future<MusicBookmark?> addBookmark(Song song) async {
    if (currentSong?.identityKey != song.identityKey) return null;
    final pos = position.value.inSeconds;
    if (pos <= 0) return null;
    return BookmarksStore.add(song.identityKey, pos);
  }

  /// This song's bookmarks, earliest position first.
  List<MusicBookmark> bookmarksFor(Song song) =>
      BookmarksStore.forSong(song.identityKey);

  /// Delete one bookmark.
  Future<void> deleteBookmark(Song song, MusicBookmark bookmark) =>
      BookmarksStore.remove(song.identityKey, bookmark);

  /// Jump to [seconds] in [song]. When the song is already loaded,
  /// seek immediately. Otherwise load it first (from the queue when
  /// present, else on its own) and seek once its duration is known
  /// — the pending seek is consumed by [_loadCurrent] and wins over
  /// the kill-saved resume position.
  Future<void> jumpToBookmark(Song song, int seconds) async {
    if (seconds < 0 || !_playersReady) return;
    if (_playersReady &&
        _loadedIdentityKey == song.identityKey &&
        currentSong?.identityKey == song.identityKey) {
      await _active.seek(Duration(seconds: seconds));
      return;
    }
    _pendingBookmarkSeek = (key: song.identityKey, seconds: seconds);
    final idx = queue.indexWhere((s) => s.identityKey == song.identityKey);
    if (idx >= 0) {
      await playIndex(idx);
    } else {
      await playQueue([song], 0);
    }
  }

  // -- quality (setQuality, app.js:2145) ----------------------------------------

  Future<bool> setQuality(AudioQuality q) async {
    if (q == userQuality.value && currentSong == null) return true;
    final wasPlaying = isPlaying.value;
    final pos = position.value;
    final song = currentSong;
    if (song == null) {
      // No song loaded: the preference applies to the next song.
      userQuality.value = q;
      await MusicStore.setQuality(q);
      return true;
    }
    final localPath = downloads.localPathFor(song);
    if (localPath != null) {
      // Downloaded song: the file IS the quality — no re-resolve,
      // just re-open the local file. The badge stays at the file's
      // recorded tier (see [MusicDownloadService.tierFor]), not the
      // newly requested one.
      userQuality.value = q;
      await MusicStore.setQuality(q);
      actualQuality.value = downloads.tierFor(song) ?? q;
      _candidates = [Uri.file(localPath).toString()];
      _candidateIdx = 0;
      _playGen++;
      await _openOn(_active, _candidates[0], auto: false, gen: _playGen);
      if (pos > Duration.zero) await _active.seek(pos);
      if (wasPlaying) await _active.play();
      return true;
    }
    // Resolve FIRST, then write the preference: writing it before
    // the resolve left the UI showing the new tier while the song
    // kept playing the old one (P1-4) when the resolve failed.
    final r = await _resolvers.resolvePlayUrl(
      song.songId,
      song.platform,
      q,
      song.title,
      artist: song.artist,
    );
    if (r == null || r.url.isEmpty) return false;
    userQuality.value = q;
    await MusicStore.setQuality(q);
    _candidates = r.candidates;
    _candidateIdx = 0;
    actualQuality.value = r.quality;
    _playGen++;
    await _openOn(_active, r.url, auto: false, gen: _playGen);
    if (pos > Duration.zero) await _active.seek(pos);
    if (wasPlaying) await _active.play();
    return true;
  }

  // -- favourites ---------------------------------------------------------------

  Future<bool> toggleFav(Song song) => MusicStore.toggleFav(song);

  bool isFav(Song song) => MusicStore.getFavIds().contains(song.identityKey);

  // -- lyrics ---------------------------------------------------------------------

  Future<void> _loadLyrics(Song song) async {
    final lines = await _api.lyrics(song);
    if (_disposed) return;
    // LX (player.ts debouncePlay): every async callback drops its
    // result when the song has moved on — never paste stale lyrics
    // onto the new song.
    if (currentSong?.identityKey != song.identityKey) return;
    if (lines.isEmpty) {
      lyricsFailed.value = true;
    } else {
      lyrics.assignAll(lines);
    }
  }

  /// Index of the lyric line for the current position (-1 = none yet).
  /// The lyric offset shifts which line is active (see LyricDisplay);
  /// tapping a line still seeks to its true timestamp.
  int lyricIndexFor(Duration pos) {
    return LyricDisplay.lyricIndexFor(lyrics, pos, lyricOffsetMs.value);
  }

  static MusicPlayerController get instance => Get.find<MusicPlayerController>();

  static MusicPlayerController ensure() {
    if (Get.isRegistered<MusicPlayerController>()) {
      return Get.find<MusicPlayerController>();
    }
    return Get.put(MusicPlayerController());
  }
}
