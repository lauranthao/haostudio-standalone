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
//   starts on a second music player at volume 0 while the current fades
//   out (~2.5 s overlap). Manual next/prev switch immediately, no fade.
// - Progress is saved ONLY when the app is killed from the background
//   (AppLifecycleState.detached — the pagehide equivalent), never while
//   merely backgrounded. A saved position only resumes when > 5 s in and
//   > 10 s from the end (old web rule).
// - Prefetch: the next track's URL is resolved ahead of time.
// - Next/previous advance exactly one track (fix 14 Dart-side rule).

import 'dart:async';
import 'dart:io' show Platform;

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'av_music_player.dart';
import 'mpv_music_player.dart';
import 'music_player_adapter.dart';

import '../../core/logging/app_log.dart';
import '../../core/native/now_playing.dart';
import '../../core/storage/hive_store.dart';
import '../../core/storage/local_paths.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_downloads.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_quality.dart';
import '../../services/music/music_resolvers.dart';
import '../../services/music/music_store.dart';
import '../../services/music/play_mode.dart';
import '../../services/music/sleep_timer.dart';

const Duration _crossfadeDuration = Duration(milliseconds: 2500);

class MusicPlayerController extends GetxController
    with WidgetsBindingObserver {
  MusicPlayerController({
    MusicApi? api,
    MusicResolvers? resolvers,
    NowPlayingService? nowPlaying,
    MusicDownloadService? downloads,
    MusicPlayerAdapter? playerA,
    MusicPlayerAdapter? playerB,
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
  final RxDouble speed = 1.0.obs; // M-P0-2: 0.6..2.0, persisted
  final RxString playMode = 'seq'.obs; // five modes, see play_mode.dart
  final RxList<LyricLine> lyrics = <LyricLine>[].obs;
  final RxBool lyricsFailed = false.obs;
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

  Song? get currentSong {
    final i = currentIndex.value;
    if (i < 0 || i >= queue.length) return null;
    return queue[i];
  }

  // Two players (AVPlayer on mobile, MPV on Windows — see the
  // onInit gate): active + standby (crossfade partner). Volume is
  // 0.0..1.0 here, not media_kit's 0..100.
  late final MusicPlayerAdapter _playerA;
  late final MusicPlayerAdapter _playerB;
  late MusicPlayerAdapter _active;
  MusicPlayerAdapter get _standby =>
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
  var _playGen = 0;
  var _disposed = false;

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
  /// is the single source of truth tests assert on. Get.snackbar is a
  /// best-effort side effect on top (it throws without a GetMaterialApp
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
  /// [lastNotice] (observable + testable); Get.snackbar on top,
  /// best-effort. [withActions] adds 重试 / 下一首 buttons for a
  /// manual-load failure (the song stays put; the user decides).
  void _notice(String message, {bool withActions = false}) {
    lastNotice.value = message;
    try {
      // No overlay (unit tests) or no binding yet: the recorded
      // notice is enough. Get.overlayContext itself throws when the
      // binding is not initialized, so the check lives in the try.
      if (Get.overlayContext == null) return;
      // Get.snackbar's mainButton only takes a single TextButton, so
      // the two actions (重试 / 下一首) ride in messageText instead.
      final color = Get.theme.colorScheme.onSurface;
      Get.snackbar(
        '播放提示',
        withActions ? '' : message,
        snackPosition: SnackPosition.BOTTOM,
        backgroundColor: Get.theme.colorScheme.surface,
        colorText: color,
        duration: const Duration(seconds: 4),
        messageText: withActions
            ? Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(message, style: TextStyle(color: color)),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      TextButton(
                        onPressed: () {
                          if (Get.isSnackbarOpen) {
                            Get.closeCurrentSnackbar();
                          }
                          unawaited(retryCurrent());
                        },
                        child: const Text('重试'),
                      ),
                      TextButton(
                        onPressed: () {
                          if (Get.isSnackbarOpen) {
                            Get.closeCurrentSnackbar();
                          }
                          unawaited(next());
                        },
                        child: const Text('下一首'),
                      ),
                    ],
                  ),
                ],
              )
            : null,
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
    }
    // Two crossfade players (A/B). Mobile: AVPlayer via just_audio.
    // Windows: MPV via media_kit (there is no AVPlayer on Windows).
    // Only on platforms with native audio — on Linux tests there is
    // none, and a just_audio method call there would throw
    // MissingPluginException into the test zone. A player failure only
    // disables playback (_playersReady stays false, rate/play calls
    // no-op) instead of crashing the whole music tab during build.
    // Injected players (constructor seam) are never overwritten here.
    if (!_playersReady &&
        (MpvMusicPlayer.isSupported || AvMusicPlayer.isSupported)) {
      try {
        if (Platform.isWindows) {
          _playerA = MpvMusicPlayer();
          _playerB = MpvMusicPlayer();
        } else {
          _playerA = AvMusicPlayer();
          _playerB = AvMusicPlayer();
        }
        _active = _playerA;
        _playersReady = true;
      } catch (e) {
        AppLog.error('音乐播放器初始化失败：$e');
        _playersReady = false;
      }
    }
    if (_playersReady) {
      unawaited(_active.setVolume(_targetVolume));
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
    _sleepTimer.cancel();
    WidgetsBinding.instance.removeObserver(this);
    _fadeTimer?.cancel();
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

  void _attach(MusicPlayerAdapter player) {
    unawaited(_posSub?.cancel());
    unawaited(_durSub?.cancel());
    unawaited(_playingSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_completedSub?.cancel());
    _posSub = player.stream.position.listen((p) {
      if (identical(player, _active)) position.value = p;
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

  // Player volume is always full (1.0): the music player has no volume
  // control of its own (chen 2026-11-17) — volume is the system volume
  // (hardware buttons / Control Center). Every open re-asserts 1.0 so
  // a crossfade partner that was faded to 0 never stays silent.
  Future<void> _openOn(
    MusicPlayerAdapter player,
    String url, {
    bool auto = false,
    int gen = -1,
  }) async {
    // The open attempt belongs to this gen: a native error that
    // arrives during/after it is this load's error (see [_activeGen]).
    // gen -1 (trial retry) leaves the stamp alone — the retry opens
    // for the current load, whose gen is already stamped.
    if (gen >= 0) _activeGen = gen;
    // open() returns false only when the URL was refused before any
    // native call, so no error will arrive on the error stream: fall
    // back to the next candidate here, the same path the error stream
    // uses for a native load failure.
    if (!await player.open(url, play: true)) {
      await _onPlayError(auto: auto, gen: gen);
      return;
    }
    await player.setVolume(_targetVolume);
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
  Future<void> _resumeLoaded() async {
    if (!isPlaying.value && _playersReady) await _active.play();
  }

  /// Replace the queue and play [index].
  Future<void> playQueue(List<Song> songs, int index, {String label = ''}) async {
    if (songs.isEmpty || index < 0 || index >= songs.length) return;
    // Same song already loaded (checked BEFORE the queue is
    // replaced — currentSong is derived from the old queue): do not
    // restart it. The queue still switches to the tapped list so
    // "play all" and up-next follow the list the user tapped, but
    // playback continues untouched.
    if (_isLoadedCurrent(songs[index])) {
      queue.assignAll(songs);
      queueLabel.value = label;
      currentIndex.value = index;
      _persistQueue();
      await _resumeLoaded();
      return;
    }
    queue.assignAll(songs);
    queueLabel.value = label;
    await playIndex(index);
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
  void _persistQueue() {
    unawaited(MusicStore.saveQueue(queue.toList(), currentIndex.value));
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

  Future<void> _loadCurrent({bool auto = false}) async {
    final gen = ++_playGen;
    final song = currentSong;
    if (song == null) return;
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
    // the wrong player when it ends.
    if (!auto) _fadeTimer?.cancel();
    // LX identity stamp (player.ts createGettingUrlId / setMusicUrl):
    // the URL this load resolves belongs to THIS song only. The gen
    // check below catches a newer load; the identity check catches a
    // queue-slot replacement that did not bump the gen.
    final loadKey = song.identityKey;
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
    position.value = Duration.zero;
    duration.value = Duration.zero;
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
      quality = userQuality.value;
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
    if (resumeSec > 5) {
      // Seek only once the duration is known.
      unawaited(
        _active.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 5), onTimeout: () => Duration.zero)
            .then((total) async {
          if (gen != _playGen || _disposed) return;
          // Only seek when the user has not already moved the
          // position (a manual seek in the seconds before the
          // duration arrived must not be jumped back).
          if (total.inSeconds > 0 &&
              total.inSeconds - resumeSec > 10 &&
              position.value < const Duration(seconds: 5)) {
            await _active.seek(Duration(seconds: resumeSec));
          }
        }),
      );
    }
    _prefetchNext();
  }

  Future<void> _crossfadeTo(String url, int gen) async {
    final outgoing = _active;
    final incoming = _standby;
    _fadeTimer?.cancel();
    // The standby may already hold this URL buffered from _prefetchNext:
    // reuse it instead of opening cold (the open would re-buffer from
    // scratch and the track change would stutter). A preloaded player
    // that has since gone idle still runs the idle check below.
    if (!incoming.isPreloadedFor(url)) {
      // Refused URL: never touched native, so no error stream event
      // will come — fall back on the still-active player instead of
      // swapping in a player with no source.
      if (!await incoming.open(url, play: false)) {
        await _onPlayError(auto: true, gen: gen);
        return;
      }
    }
    await incoming.setVolume(0);
    await incoming.setRate(speed.value);
    await incoming.play();
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
    final start = DateTime.now();
    const step = Duration(milliseconds: 100);
    final targetVol = _targetVolume;
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
      await outgoing.setVolume(targetVol * (1 - t));
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
    // let it trigger trial handling for the new song. (Residual: a
    // genuine trial duration that arrives during the open's own await
    // is also skipped; the trial then plays out its 15 s and advances,
    // the pre-v1.0.9 behaviour for that fast-load edge case.)
    if (isResolving.value) return;
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
    // The resolving flag stays up while the alt lookup runs (up to 5 s
    // after the findAltPlatform cap). try/finally so a throw in the
    // lookup / open still clears the flag; the gen guard makes the
    // clear a no-op if a newer load owns it by then.
    final g = gen < 0 ? _playGen : gen;
    _setResolving(true, g);
    try {
      if (!_altTried) {
        _altTried = true;
        final alt = await _api.findAltPlatform(
          song.title,
          song.artist,
          song.platform,
          song.album,
        );
        if (alt != null) {
          final r = await _resolvers.resolvePlayUrl(
            alt.songId,
            alt.platform,
            userQuality.value,
            alt.title,
            artist: alt.artist,
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
    // Sleep timer, 到歌单结束: the queue ends here — stop, do not
    // advance or loop, and clear the timer.
    if (_sleepTimer.isQueueEnd) {
      _sleepTimer.cancel();
      unawaited(_active.pause());
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
  /// Deliberate divergence from [nextTrackIndex]: for a one-song
  /// queue the pure function returns current (single loop replays),
  /// but this method returns -1 — the failure path depends on -1
  /// (never retry the same dead song), and single-loop replay is
  /// handled separately in _onTrackCompleted via _replayCurrent.
  int _peekNextIndex({required bool auto}) {
    if (queue.length <= 1) {
      // A one-song queue: single loop replays on auto-advance (handled
      // in _onTrackCompleted via _replayCurrent); anything else stops.
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
    if (queue.length <= 1) return -1;
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
      await _active.pause();
    } else {
      await _playCurrentOrResume();
    }
  }

  /// Play when a track is loaded; on a fresh launch (or after a
  /// failed load) nothing is in the player yet, so a bare play() is
  /// a no-op — the adapter's play() returns early without a source —
  /// and the tap does nothing (chen 2026-11-20: 刚进 app 点播放歌曲
  /// 不播放，要切到下一首歌才播放). Load the restored current song
  /// through the normal path instead. A load already in flight is
  /// left alone (it plays when it lands); a loaded-but-paused track
  /// still resumes without reloading.
  Future<void> _playCurrentOrResume() async {
    if (isPlaying.value) return;
    if (_playersReady &&
        _loadedIdentityKey.isEmpty &&
        currentSong != null &&
        !isResolving.value) {
      await playIndex(currentIndex.value);
      return;
    }
    await _active.play();
  }

  /// Pause playback if currently playing; no-op when already paused.
  /// Used by the VOD player page and the live room to silence music
  /// the moment a film / live stream starts playing (never on
  /// browsing the video tab / live list / detail page). No
  /// auto-resume: the user resumes music manually.
  Future<void> pause() async {
    if (!isPlaying.value) return;
    await _active.pause();
  }

  Future<void> seek(Duration pos) => _active.seek(pos);

  // -- playback speed (M-P0-2) ------------------------------------------------

  /// Clamp a speed to the supported range (slider 0.6–2.0).
  static double clampSpeed(double v) => v.clamp(0.6, 2.0);

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

  // -- app-internal gain (Windows only) --------------------------------------

  /// The player-volume target: the Windows app-internal gain
  /// (HiveKeys.appVolume, 0..1, default 1.0) on Windows; exactly 1.0
  /// everywhere else — the music player has no volume control of its
  /// own on mobile (volume is the system volume), so no stored value
  /// can ever lower it there.
  double get _targetVolume => Platform.isWindows
      ? HiveStore.getDouble(HiveKeys.appVolume, 1.0).clamp(0.0, 1.0)
      : 1.0;

  /// Set the Windows app-internal gain (0..1). Takes effect
  /// immediately on the active player (the standby stays at 0; a
  /// crossfade in flight reads [_targetVolume] when it starts, so a
  /// change mid-fade finishes at the old target and the next fade
  /// uses the new one). Persists to Hive unless [persist] is false
  /// (the Settings slider calls with persist: false per tick and
  /// persists once on release).
  Future<void> setAppVolume(double v, {bool persist = true}) async {
    final value = v.clamp(0.0, 1.0);
    if (persist) await HiveStore.put(HiveKeys.appVolume, value);
    if (_playersReady) {
      // Apply the live value (not the stored one): during a slider
      // drag persist is false, so the stored value is still the old
      // one. Off Windows the target is always 1.0 (see
      // [_targetVolume]) — the slider is hidden there anyway.
      unawaited(_active.setVolume(Platform.isWindows ? value : 1.0));
    }
  }

  /// Cycle through the five play modes (顺序播放 → 列表循环 → 单曲循环 →
  /// 随机播放 → 单曲播放) and persist the choice in Hive.
  Future<void> cyclePlayMode() async {
    playMode.value = mode.next.code;
    await MusicStore.setPlayMode(playMode.value);
  }

  /// Back-compat alias: the old two-mode toggle is now the five-mode cycle.
  Future<void> togglePlayMode() => cyclePlayMode();

  // -- sleep timer (M-P0-3) -----------------------------------------------------

  /// Wall-clock timer fired: STOP playback and clear the timer. A
  /// load in flight (previous song ended, next still resolving)
  /// must not sound when it lands: record its gen so the landing
  /// open pauses instead (see [_pauseIfSleepFired]). The fire's own
  /// pause covers what is sounding now; the flag covers what lands
  /// next.
  void _onSleepTimerFired() {
    _sleepFiredGen = _playGen;
    if (_playersReady) unawaited(_active.pause());
    _syncSleepState();
  }

  /// Pause [player] if the sleep timer fired while its load was in
  /// flight. The flag is consumed on the first check either way: a
  /// NEWER load (gen bumped after the fire) is the user's explicit
  /// play and is untouched. Called after every landing open on the
  /// active player ([_openOn] and the crossfade landing in
  /// [_loadCurrent]).
  Future<void> _pauseIfSleepFired(MusicPlayerAdapter player) async {
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
  }

  /// Human label for the active sleep timer, with the custom
  /// minutes filled in ("自定义 45 分钟" — the enum label alone is
  /// just "自定义").
  String get sleepLabel {
    if (sleepOption.value == SleepTimerOption.custom) {
      return '自定义 ${sleepCustomMinutes.value} 分钟';
    }
    return sleepOption.value.label;
  }

  /// Start (or replace) the sleep timer. `off` cancels it.
  /// `custom` replays the persisted custom minutes (the sheet writes
  /// them first via [setSleepTimerMinutes]).
  void setSleepTimer(SleepTimerOption option) {
    if (option == SleepTimerOption.custom) {
      setSleepTimerMinutes(MusicStore.sleepCustomMinutes);
      return;
    }
    _sleepTimer.start(option);
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
      // just re-open the local file at the new (nominal) tier.
      userQuality.value = q;
      await MusicStore.setQuality(q);
      actualQuality.value = q;
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
  int lyricIndexFor(Duration pos) {
    final lines = lyrics;
    if (lines.isEmpty) return -1;
    var idx = -1;
    for (var i = 0; i < lines.length; i++) {
      if (lines[i].t <= pos.inMilliseconds / 1000) {
        idx = i;
      } else {
        break;
      }
    }
    return idx;
  }

  static MusicPlayerController get instance => Get.find<MusicPlayerController>();

  static MusicPlayerController ensure() {
    if (Get.isRegistered<MusicPlayerController>()) {
      return Get.find<MusicPlayerController>();
    }
    return Get.put(MusicPlayerController());
  }
}
