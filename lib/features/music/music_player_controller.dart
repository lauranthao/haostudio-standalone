// Music player controller — queue + native audio (media_kit).
//
// - Playback ALWAYS starts at the user's chosen quality (default hires);
//   a song that only resolves lower drops down for that song only, and the
//   next song returns to the chosen tier (rule "fi" — the resolver module
//   holds no downgrade state; the caller passes the chosen tier every time).
// - Candidate fallback on play error: next candidate URL, then next song;
//   one alt-platform attempt (findAltPlatform) before giving up.
// - Song crossfade (Apple Music-style): on AUTO-advance the next track
//   starts on a second Player at volume 0 while the current fades out
//   (~2.5 s overlap). Manual next/prev switch immediately, no fade.
// - Progress is saved ONLY when the app is killed from the background
//   (AppLifecycleState.detached — the pagehide equivalent), never while
//   merely backgrounded. A saved position only resumes when > 5 s in and
//   > 10 s from the end (old web rule).
// - Prefetch: the next track's URL is resolved ahead of time.
// - Next/previous advance exactly one track (fix 14 Dart-side rule).

import 'dart:async';
import 'dart:math';

import 'package:flutter/widgets.dart';
import 'package:get/get.dart';
import 'package:media_kit/media_kit.dart';

import '../../core/native/now_playing.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_quality.dart';
import '../../services/music/music_resolvers.dart';
import '../../services/music/music_store.dart';

const Duration _crossfadeDuration = Duration(milliseconds: 2500);

class MusicPlayerController extends GetxController
    with WidgetsBindingObserver {
  MusicPlayerController({MusicApi? api, MusicResolvers? resolvers, NowPlayingService? nowPlaying})
      : _api = api ?? MusicApi(),
        _resolvers = resolvers ?? MusicResolvers(),
        _nowPlayingOverride = nowPlaying;

  final MusicApi _api;
  final MusicResolvers _resolvers;
  final NowPlayingService? _nowPlayingOverride;

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
  final RxString playMode = 'seq'.obs; // 'seq' | 'shuffle'
  final RxList<LyricLine> lyrics = <LyricLine>[].obs;
  final RxBool lyricsFailed = false.obs;
  final RxBool showQueuePanel = false.obs;
  final RxString queueLabel = ''.obs;

  Song? get currentSong {
    final i = currentIndex.value;
    if (i < 0 || i >= queue.length) return null;
    return queue[i];
  }

  // Two media_kit Players: active + standby (crossfade partner).
  late final Player _playerA;
  late final Player _playerB;
  late Player _active;
  Player get _standby => identical(_active, _playerA) ? _playerB : _playerA;

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
    playMode.value = MusicStore.playMode;
    _playerA = Player(configuration: const PlayerConfiguration(title: 'HAo Studio'));
    _playerB = Player(configuration: const PlayerConfiguration(title: 'HAo Studio'));
    _active = _playerA;
    unawaited(_active.setVolume(volume.value * 100));
    unawaited(_standby.setVolume(0));
    WidgetsBinding.instance.addObserver(this);
    _attach(_active);
    _nowPlaying = _nowPlayingOverride ?? NowPlayingService();
    _nowPlaying.onRemoteCommand = _onRemoteCommand;
    // Publish on track change / play / pause; elapsed time is
    // throttled to 1 s while playing (see _publishNowPlayingThrottled).
    ever(currentIndex, (_) => _publishNowPlaying());
    ever(isPlaying, (_) => _publishNowPlaying());
    ever(position, (_) => _publishNowPlayingThrottled());
  }

  @override
  void onClose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    _fadeTimer?.cancel();
    unawaited(_nowPlaying.clear());
    _nowPlaying.dispose();
    unawaited(_posSub?.cancel());
    unawaited(_durSub?.cancel());
    unawaited(_playingSub?.cancel());
    unawaited(_errorSub?.cancel());
    unawaited(_completedSub?.cancel());
    unawaited(_playerA.dispose());
    unawaited(_playerB.dispose());
    super.onClose();
  }

  // -- lifecycle: save progress ONLY on kill (detached) ----------------------

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.detached) {
      _saveResumeOnKill();
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

  void _attach(Player player) {
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
      if (identical(player, _active)) isPlaying.value = playing;
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

  Future<void> _openOn(Player player, String url, {double? vol}) async {
    await player.open(Media(url), play: true);
    if (vol != null) await player.setVolume(vol * 100);
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
    await _loadCurrent(auto: auto);
  }

  Future<void> _loadCurrent({bool auto = false}) async {
    final gen = ++_playGen;
    final song = currentSong;
    if (song == null) return;
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

    final cacheKey = '${song.songId}|${song.platform.code}|${userQuality.value.code}';
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
    _candidates = r.candidates;
    _candidateIdx = 0;
    actualQuality.value = r.quality;
    _failStreak = 0;
    await MusicStore.addRecent(song);
    await MusicStore.recordListen(song);
    if (auto) {
      await _crossfadeTo(r.url);
    } else {
      await _openOn(_active, r.url, vol: volume.value);
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
    await incoming.open(Media(url), play: false);
    await incoming.setVolume(0);
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
        await incoming.setVolume(targetVol * 100);
        return;
      }
      await incoming.setVolume(targetVol * t * 100);
      await outgoing.setVolume(targetVol * (1 - t) * 100);
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
    unawaited(next(auto: true));
  }

  void _prefetchNext() {
    final next = _peekNextIndex();
    if (next < 0) return;
    final tr = queue[next];
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

  int _peekNextIndex() {
    if (queue.length <= 1) return -1;
    if (playMode.value == 'shuffle') {
      var n = currentIndex.value;
      while (n == currentIndex.value) {
        n = Random().nextInt(queue.length);
      }
      return n;
    }
    return (currentIndex.value + 1) % queue.length;
  }

  int _peekPrevIndex() {
    if (queue.length <= 1) return -1;
    if (playMode.value == 'shuffle') {
      var n = currentIndex.value;
      while (n == currentIndex.value) {
        n = Random().nextInt(queue.length);
      }
      return n;
    }
    return (currentIndex.value - 1 + queue.length) % queue.length;
  }

  // -- transport ---------------------------------------------------------------

  Future<void> next({bool auto = false}) async {
    final n = _peekNextIndex();
    if (n < 0) return;
    currentIndex.value = n;
    await _loadCurrent(auto: auto);
  }

  Future<void> prev() async {
    // Restart the current track when more than 3 s in (established
    // in-app behaviour), else go to the previous track.
    if (position.value > const Duration(seconds: 3)) {
      await _active.seek(Duration.zero);
      return;
    }
    final n = _peekPrevIndex();
    if (n < 0) return;
    currentIndex.value = n;
    await _loadCurrent();
  }

  Future<void> togglePlayPause() async {
    if (isPlaying.value) {
      await _active.pause();
    } else {
      await _active.play();
    }
  }

  Future<void> seek(Duration pos) => _active.seek(pos);

  Future<void> setVolume(double v) async {
    volume.value = v.clamp(0.0, 1.0);
    await _active.setVolume(volume.value * 100);
    await MusicStore.setVolume(volume.value);
  }

  Future<void> togglePlayMode() async {
    playMode.value = playMode.value == 'shuffle' ? 'seq' : 'shuffle';
    await MusicStore.setPlayMode(playMode.value);
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
