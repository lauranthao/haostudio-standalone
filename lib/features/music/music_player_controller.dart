// Music player controller — queue + native audio (AVPlayer via just_audio,
// like 歌一刀; was media_kit/MPV before chen 2026-11-17).
//
// - Playback ALWAYS starts at the user's chosen quality (default hires);
//   a song that only resolves lower drops down for that song only, and the
//   next song returns to the chosen tier (rule "fi" — the resolver module
//   holds no downgrade state; the caller passes the chosen tier every time).
// - Candidate fallback on play error: next candidate URL, then next song;
//   one alt-platform attempt (findAltPlatform) before giving up.
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

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'av_music_player.dart';

import '../../core/native/now_playing.dart';
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
  })  : _api = api ?? MusicApi(),
        _resolvers = resolvers ?? MusicResolvers(),
        _nowPlayingOverride = nowPlaying,
        downloads = downloads ?? MusicDownloadService();

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
  final RxDouble volume = 0.8.obs;
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
  var _playGen = 0;
  var _disposed = false;

  // Current-track resolve state.
  List<String> _candidates = [];
  var _candidateIdx = 0;
  var _altTried = false;

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
  var _failStreak = 0;

  // Prefetch cache for the next track.
  ({String key, String url, List<String> candidates, AudioQuality quality})?
      _nextCache;

  @override
  void onInit() {
    super.onInit();
    userQuality.value = MusicStore.quality;
    actualQuality.value = userQuality.value;
    volume.value = MusicStore.volume;
    speed.value = MusicStore.speed;
    playMode.value = MusicStore.playMode;
    // Restore the persisted queue (M-P0-4) — order + current index,
    // but do NOT auto-play: playback only starts on a user tap.
    final savedQueue = MusicStore.getQueue();
    if (savedQueue.songs.isNotEmpty) {
      queue.assignAll(savedQueue.songs);
      currentIndex.value = savedQueue.index;
    }
    // Two crossfade players (A/B, AVPlayer via just_audio). Only on
    // platforms with native audio — on Linux tests there is none, and
    // a just_audio method call there would throw MissingPluginException
    // into the test zone. A player failure only disables playback
    // (_playersReady stays false, rate/play calls no-op) instead of
    // crashing the whole music tab during build.
    if (AvMusicPlayer.isSupported) {
      try {
        _playerA = AvMusicPlayer();
        _playerB = AvMusicPlayer();
        _active = _playerA;
        _playersReady = true;
      } catch (e) {
        debugPrint('[HAo] music players failed to initialise: $e');
        _playersReady = false;
      }
    }
    if (_playersReady) {
      unawaited(_active.setVolume(volume.value));
      unawaited(_active.setRate(speed.value));
      unawaited(_standby.setVolume(0));
      unawaited(_standby.setRate(speed.value));
    }
    WidgetsBinding.instance.addObserver(this);
    if (_playersReady) _attach(_active);
    _nowPlaying = _nowPlayingOverride ?? NowPlayingService();
    _nowPlaying.onRemoteCommand = _onRemoteCommand;
    _sleepTimer = SleepTimer(
      onFire: () {
        // Wall-clock timer fired: STOP playback and clear the timer.
        if (_playersReady) unawaited(_active.pause());
        _syncSleepState();
      },
      onChanged: _syncSleepState,
    );
    _syncSleepState();
    // Publish on track change / play / pause; elapsed time is
    // throttled to 1 s while playing (see _publishNowPlayingThrottled).
    ever(currentIndex, (_) => _publishNowPlaying());
    ever(isPlaying, (_) => _publishNowPlaying());
    ever(position, (_) => _publishNowPlayingThrottled());
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
        if (!isPlaying.value) await _active.play();
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
      if (identical(player, _active)) position.value = p;
    });
    _durSub = player.stream.duration.listen((d) {
      if (identical(player, _active)) duration.value = d;
    });
    _playingSub = player.stream.playing.listen((playing) {
      if (identical(player, _active)) {
        isPlaying.value = playing;
        _listenTracker.setPlaying(playing, DateTime.now());
      }
    });
    _errorSub = player.stream.error.listen((e) {
      if (e.isNotEmpty && identical(player, _active)) {
        _onPlayError();
      }
    });
    _completedSub = player.stream.completed.listen((done) {
      if (done && identical(player, _active)) _onTrackCompleted();
    });
  }

  Future<void> _openOn(AvMusicPlayer player, String url, {double? vol}) async {
    // open() returns false only when the URL was refused before any
    // native call, so no error will arrive on the error stream: fall
    // back to the next candidate here, the same path the error stream
    // uses for a native load failure.
    if (!await player.open(url, play: true)) {
      await _onPlayError();
      return;
    }
    if (vol != null) await player.setVolume(vol);
    // Rate survives an open: re-apply the user's speed every time a
    // track (or a fallback candidate) is opened.
    await player.setRate(speed.value);
  }

  // -- queue / track loading ---------------------------------------------------

  /// Replace the queue and play [index].
  Future<void> playQueue(List<Song> songs, int index, {String label = ''}) async {
    if (songs.isEmpty || index < 0 || index >= songs.length) return;
    queue.assignAll(songs);
    queueLabel.value = label;
    await playIndex(index);
  }

  Future<void> playIndex(int index, {bool auto = false}) async {
    if (index < 0 || index >= queue.length) return;
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
    // Close the previous track's listen session (real seconds only)
    // and start one for this song. The old code recorded the song's
    // FULL duration here, before a second had played.
    unawaited(_finalizeListenSession());
    _listenTracker.begin(song, DateTime.now());
    _candidates = [];
    _candidateIdx = 0;
    _altTried = false;
    lyrics.clear();
    lyricsFailed.value = false;
    position.value = Duration.zero;
    duration.value = Duration.zero;
    unawaited(_loadLyrics(song));

    // Resume position for the SAME song (old web rule: > 5 s in, > 10 s
    // from the end). Only applies when this is a fresh open, not a
    // crossfade continuation.
    final resumeSec = MusicStore.resumeFor(song.identityKey);

    // Offline first (M-P0-5): a downloaded song plays from the local
    // file — no resolve, no network. Otherwise resolve the remote URL
    // at the user's quality (with the prefetch cache).
    String url;
    List<String> candidates;
    AudioQuality quality;
    final localPath = downloads.localPathFor(song);
    if (localPath != null) {
      url = Uri.file(localPath).toString();
      candidates = [url];
      quality = userQuality.value;
    } else {
      final cacheKey =
          '${song.songId}|${song.platform.code}|${userQuality.value.code}';
      PlayUrlResult? r;
      if (_nextCache != null && _nextCache!.key == cacheKey) {
        r = PlayUrlResult(
          url: _nextCache!.url,
          candidates: _nextCache!.candidates,
          quality: _nextCache!.quality,
          via: '',
        );
        _nextCache = null;
      } else {
        r = await _resolvers.resolvePlayUrl(
          song.songId,
          song.platform,
          userQuality.value,
          song.title,
        );
      }
      if (gen != _playGen || _disposed) return;
      if (r == null || r.url.isEmpty) {
        await _tryAltOrNext(song);
        return;
      }
      url = r.url;
      candidates = r.candidates;
      quality = r.quality;
    }
    _candidates = candidates;
    _candidateIdx = 0;
    actualQuality.value = quality;
    _failStreak = 0;
    await MusicStore.addRecent(song);
    if (auto) {
      await _crossfadeTo(url);
    } else {
      await _openOn(_active, url, vol: volume.value);
    }
    if (gen != _playGen || _disposed) return;
    if (resumeSec > 5) {
      // Seek only once the duration is known.
      unawaited(
        _active.stream.duration
            .firstWhere((d) => d > Duration.zero)
            .timeout(const Duration(seconds: 5), onTimeout: () => Duration.zero)
            .then((total) async {
          if (gen != _playGen || _disposed) return;
          if (total.inSeconds > 0 && total.inSeconds - resumeSec > 10) {
            await _active.seek(Duration(seconds: resumeSec));
          }
        }),
      );
    }
    _prefetchNext();
  }

  Future<void> _crossfadeTo(String url) async {
    final outgoing = _active;
    final incoming = _standby;
    _fadeTimer?.cancel();
    // Refused URL: never touched native, so no error stream event
    // will come — fall back on the still-active player instead of
    // swapping in a player with no source.
    if (!await incoming.open(url, play: false)) {
      await _onPlayError();
      return;
    }
    await incoming.setVolume(0);
    await incoming.setRate(speed.value);
    await incoming.play();
    _active = incoming;
    _attach(incoming);
    position.value = Duration.zero;
    duration.value = Duration.zero;
    final start = DateTime.now();
    const step = Duration(milliseconds: 100);
    final targetVol = volume.value;
    _fadeTimer = Timer.periodic(step, (timer) async {
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

  Future<void> _onPlayError() async {
    if (_candidateIdx + 1 < _candidates.length) {
      _candidateIdx++;
      await _openOn(_active, _candidates[_candidateIdx], vol: volume.value);
      return;
    }
    final song = currentSong;
    if (song == null) return;
    _failStreak++;
    if (_failStreak >= 3) {
      _failStreak = 0;
      await _tryAltOrNext(song);
      return;
    }
    await next(auto: true);
  }

  Future<void> _tryAltOrNext(Song song) async {
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
        );
        if (r != null && r.url.isNotEmpty) {
          queue[currentIndex.value] = alt;
          queue.refresh();
          _persistQueue();
          _candidates = r.candidates;
          _candidateIdx = 0;
          actualQuality.value = r.quality;
          await _openOn(_active, r.url, vol: volume.value);
          return;
        }
      }
    }
    await next(auto: true);
  }

  void _onTrackCompleted() {
    final song = currentSong;
    if (song != null) {
      unawaited(MusicStore.clearResume(song.identityKey));
    }
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
    final key = '${tr.songId}|${tr.platform.code}|${userQuality.value.code}';
    if (_nextCache != null && _nextCache!.key == key) return;
    unawaited(
      _resolvers
          .resolvePlayUrl(tr.songId, tr.platform, userQuality.value, tr.title)
          .then((r) {
        if (r != null && r.url.isNotEmpty) {
          _nextCache = (
            key: key,
            url: r.url,
            candidates: r.candidates,
            quality: r.quality,
          );
        }
      }),
    );
  }

  /// Next index honouring the play mode; -1 = stop at the queue end.
  /// Auto-advance and a manual tap differ for single loop / single
  /// play — see nextTrackIndex in play_mode.dart.
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
      await _active.play();
    }
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

  Future<void> setVolume(double v) async {
    volume.value = v.clamp(0.0, 1.0);
    await _active.setVolume(volume.value);
    await MusicStore.setVolume(volume.value);
  }

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

  /// Cycle through the five play modes (顺序播放 → 列表循环 → 单曲循环 →
  /// 随机播放 → 单曲播放) and persist the choice in Hive.
  Future<void> cyclePlayMode() async {
    playMode.value = mode.next.code;
    await MusicStore.setPlayMode(playMode.value);
  }

  /// Back-compat alias: the old two-mode toggle is now the five-mode cycle.
  Future<void> togglePlayMode() => cyclePlayMode();

  // -- sleep timer (M-P0-3) -----------------------------------------------------

  void _syncSleepState() {
    sleepOption.value = _sleepTimer.option;
    sleepRemaining.value = _sleepTimer.remaining;
  }

  /// Start (or replace) the sleep timer. `off` cancels it.
  void setSleepTimer(SleepTimerOption option) {
    _sleepTimer.start(option);
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
    userQuality.value = q;
    await MusicStore.setQuality(q);
    if (song == null) return true;
    final localPath = downloads.localPathFor(song);
    if (localPath != null) {
      // Downloaded song: the file IS the quality — no re-resolve,
      // just re-open the local file at the new (nominal) tier.
      actualQuality.value = q;
      _candidates = [Uri.file(localPath).toString()];
      _candidateIdx = 0;
      _playGen++;
      await _openOn(_active, _candidates[0], vol: volume.value);
      if (pos > Duration.zero) await _active.seek(pos);
      if (wasPlaying) await _active.play();
      return true;
    }
    final r = await _resolvers.resolvePlayUrl(
      song.songId,
      song.platform,
      q,
      song.title,
    );
    if (r == null || r.url.isEmpty) return false;
    _candidates = r.candidates;
    _candidateIdx = 0;
    actualQuality.value = r.quality;
    _playGen++;
    await _openOn(_active, r.url, vol: volume.value);
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
