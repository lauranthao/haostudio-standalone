// MPV backend — media_kit (libmpv). Default engine on every platform.
//
// Applies the mpv tuning table (mpv_properties.dart): base 5.6.5
// first-frame numbers + per-source live properties (cache-pause=no,
// force-seekable=no, demuxer-lavf-format=hls for HLS). iOS: vo libmpv,
// hwdec videotoolbox, ao default — no iOS-specific tuning.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import 'mpv_properties.dart';
import 'player_backend.dart';
import 'player_engine.dart';
import 'player_kernel.dart';
import 'video_fit.dart';

class MpvBackend implements PlayerBackend {
  MpvBackend() {
    // Defensive: the native media_kit library must be initialised
    // before Player() is created. main() does this, but backends can
    // be constructed from tests or before runApp — ensureInitialized
    // is idempotent, so calling it again is safe.
    MediaKit.ensureInitialized();
    _player = Player(
      configuration: const PlayerConfiguration(title: 'HAo Studio'),
    );
    _videoController = VideoController(_player);
  }

  late final Player _player;
  late final VideoController _videoController;
  bool _disposed = false;
  bool _opened = false;

  /// Set by open(): whether this backend is serving a live room.
  /// buildVideoWidget() only ever runs after a successful open (the
  /// session returns SizedBox.shrink until the ladder swaps a backend
  /// in), so this is always accurate when the Video widget is built.
  bool _isLive = false;

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Widget buildVideoWidget() {
    // The VOD page draws its own Pure Live-style control bar (seek
    // Slider, speed, exit-fullscreen) — media_kit's Video defaults
    // `controls` to AdaptiveVideoControls, which draws a SECOND seek
    // bar + play/pause + fullscreen button on top of it (chen:
    // "看电影为什么有两个进度条"). Suppress the built-in controls so
    // exactly one control bar remains. The live room draws its own
    // Pure Live-style bars too (top + bottom, in the room page), so
    // live gets the SAME suppression: the built-in seek bar is
    // meaningless for live (no seek), and its fullscreen button is
    // wired to media_kit's own native fullscreen
    // (defaultEnterNativeFullscreen) — a SECOND fullscreen path that
    // bypasses FullscreenController's whole-app rotation (chen:
    // "全屏也有问题").
    // wakelock: false — the PlaybackSession owns the screen-on state
    // for every engine (see playback_session.dart): the Video widget's
    // own wakelock is driven by a playing subscription on its
    // controller, which goes stale across backend swaps (didUpdateWidget
    // only refreshes view params), and a stale event from the disposed
    // player can switch the screen off mid-playback.
    // fit: contain, explicit — the same fit IJK uses, and AVPlayer's
    // backend is pinned to contain too, so all three kernels render a
    // 16:9 stream into the 16:9 container identically (and a non-16:9
    // stream is letterboxed, never stretched).
    if (_isLive) {
      return Video(
        controller: _videoController,
        wakelock: false,
        controls: (_) => const SizedBox.shrink(),
        // The room owns background behaviour: leaving the app switches
        // the session to audio-only (vid=no, audio keeps flowing).
        // The Video widget's default pauseUponEnteringBackgroundMode
        // would pause the native player behind the session's back —
        // background live audio dies and the room keeps showing
        // "playing" while paused (same bug family as the VOD
        // background fix, but here it breaks a feature, not just
        // state honesty).
        pauseUponEnteringBackgroundMode: false,
        resumeUponEnteringForegroundMode: false,
        fit: BoxFit.contain,
      );
    }
    // fit: VOD honours the persisted VideoFitMode (自动/拉伸/裁剪,
    // PiliPlus VideoFitType + Kazumi PlayerAspectRatio); live stays
    // contain — the room is portrait 16:9 and must never stretch.
    // A change applies LIVE: media_kit Video re-applies fit in
    // didUpdateWidget, and the VOD page rebuilds after cycling.
    return Video(
      controller: _videoController,
      wakelock: false,
      controls: (_) => const SizedBox.shrink(),
      fit: VideoFitMode.current.boxFit,
    );
  }

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    _isLive = isLive;
    // Base tuning first, then per-source properties (per-source wins).
    // NOTE: public Player has no setProperty in media_kit 1.1.11 — the
    // properties go through the underlying NativePlayer (the same call
    // Pure Live's media_kit adapter makes via NativePlayer.setProperty).
    for (final entry in mpvBaseProperties().entries) {
      await _setProperty(entry.key, entry.value);
    }
    final format = formatOf(url: url, declaredFormat: declaredFormat);
    final sourceProps = isLive
        ? mpvLiveSourceProperties(isHls: format == StreamFormat.hls)
        : kMpvVodSourceProperties;
    for (final entry in sourceProps.entries) {
      await _setProperty(entry.key, entry.value);
    }
    await _player.open(
      Media(url, httpHeaders: headers),
      play: true,
    );
    _opened = true;
  }

  Future<void> _setProperty(String key, String value) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.setProperty(key, value);
    }
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 18),
  }) async {
    if (!_opened) return false;
    // Pure Live media_core `live_playback_sweep.dart` _verifyPlayback,
    // verbatim logic (the media_core package itself cannot be vendored
    // — separate package with its own adapter tree — so the algorithm
    // is ported, not the file):
    //
    // The success bar is *any* positive position progress, not a jump:
    // some live sources (huya FLV, for one) start their demuxer clock
    // near zero and only creep forward a few tens of milliseconds while
    // the picture is in fact playing. Requiring a 400ms jump used to
    // condemn exactly those healthy streams, and the sweep then tore
    // down engine after engine that was already on screen. A stream
    // that moves at all has passed verification; if it later stops
    // moving, the position-stall watchdog is the detector for that,
    // not this gate.
    //
    // The deadline is the 18 s sourceReadyTimeout — the tolerance the
    // module declares for "opened but not playing", of which this is
    // the first phase. It used to be a private, tighter constant, which
    // meant one question with two deadlines and the stricter one
    // winning: engines that were demonstrably still working (fetching
    // the renditions of a multi-variant HLS master) were reported as
    // frozen. Silence at this point is not evidence of death, because
    // there is no signal that says "still probing" — no position and no
    // buffering report exist until the demuxer has finished opening.
    //
    // Poll the position VALUE every 250 ms (no stream subscription, so
    // no missed-event race). The error signal is discrete, so it is
    // still observed from the error stream and fails fast, exactly as
    // Pure Live's `_sweepAdapterError` does.
    final until = DateTime.now().add(timeout);
    var last = _player.state.position;
    String? adapterError;
    final errorSub = _player.stream.error.listen((e) {
      if (e.isNotEmpty) adapterError ??= e;
    });
    try {
      while (DateTime.now().isBefore(until)) {
        if (_disposed) return false;
        if (adapterError != null) return false;
        if (_player.state.completed) return false;
        final position = _player.state.position;
        // A reopen restarts the demuxer clock: the mirror still holds
        // the previous playback's position (18s of the old session,
        // say), and the fresh stream starts near zero. Without
        // re-baselining, every new sample is "smaller than last" and a
        // perfectly healthy reopen is condemned as frozen at the stale
        // value.
        if (position < last) {
          last = position;
          continue;
        }
        if (position > last) return true;
        await Future<void>.delayed(const Duration(milliseconds: 250));
      }
      return false;
    } finally {
      await errorSub.cancel();
    }
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> setAudioOnly(bool audioOnly) async {
    // Pure Live media_kit adapter `_applyAudioOnly`, verbatim:
    // vid=no drops the video track (no decode, no vo) while the
    // audio keeps flowing; vid=auto restores the picture on
    // foreground return. Best-effort: a failed set must never break
    // playback (e.g. a disposed player throws AssertionError).
    try {
      await _player.setVideoTrack(
        audioOnly ? VideoTrack.no() : VideoTrack.auto(),
      );
    } catch (_) {}
  }

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume * 100);

  @override
  Future<void> setRate(double rate) => _player.setRate(rate);

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  // Seed the duration mpv already knows (state.duration is updated on
  // every duration property event, independent of stream listeners):
  // the one-shot duration event fires while open()/waitForFirstFrame
  // are still running, before the session subscribes to this stream,
  // and a plain broadcast stream drops it — without the seed the
  // progress bar (gated on duration > 0) never appears at all (chen
  // v1.0.8: "根本没有进度条"). Live reports Duration.zero, so the seed
  // is a no-op there.
  Stream<Duration> get durationStream =>
      seedKnownDuration(_player.state.duration, _player.stream.duration);

  @override
  Future<void> seekTo(Duration position) => _player.seek(position);

  @override
  Stream<bool> get playingStream => _player.stream.playing;

  @override
  Stream<String> get errorStream => _player.stream.error;

  @override
  Stream<void> get completedStream =>
      _player.stream.completed.where((done) => done).map((_) {});

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Cancel/await pending callbacks first (fix 1 discipline), then
    // release the native handle. Player.dispose is itself idempotent.
    await _player.dispose();
  }
}
