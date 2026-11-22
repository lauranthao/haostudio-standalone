// MPV backend — media_kit (libmpv). Default engine on every platform.
//
// Applies the mpv tuning table (mpv_properties.dart): base 5.6.5
// first-frame numbers + per-source live properties (cache-pause=no,
// force-seekable=no, demuxer-lavf-format=hls for HLS). iOS: vo libmpv,
// hwdec videotoolbox, ao default — no iOS-specific tuning.

import 'dart:async';
import 'dart:typed_data';

import 'package:flutter/widgets.dart';
import 'package:media_kit/media_kit.dart';
import 'package:media_kit_video/media_kit_video.dart';

import '../super_resolution.dart';
import '../vod_controls.dart';
import 'frame_capable_backend.dart';
import 'mpv_properties.dart';
import 'player_backend.dart';
import 'player_engine.dart';
import 'player_kernel.dart';
import 'video_fit.dart';

/// mpv `volume-max` (K, build 29): 300% ceiling. mpv's default is
/// 130 — without this, any session volume above 1.3 (live volume
/// boost 131–300%) is clamped to 130% inside mpv.
const String kMpvVolumeMax = '300';

/// Dialogue-boost centre fold + loudness normalization (K, build
/// 29; stereo path b30): mpv `af` lavfi graph, front-centre (c2,
/// 5.1 order FL FR FC LFE BL BR) at 0.7 + surrounds (c4/c5) at 0.3
/// folded into L/R, then EBU R128 dynamic normalization. `=` form
/// on purpose for the pan: the `<` renormalized form would
/// attenuate stereo by ~0.59x (a missing c2 still counts in the
/// renormalization sum), while `=` leaves stereo bit-identical
/// through the PAN stage (verified with ffmpeg 8.1.2, see
/// [MpvBackend.setDialogueBoost]).
///
/// Why loudnorm (b30): the pan fold alone does nothing audible on
/// stereo — and almost every CMS stream is stereo AAC — so the
/// switch was a摆设 for the films chen actually watches: wired,
/// set, zero audible effect. loudnorm (dynamic, linear=false)
/// lifts quiet passages and tames loud ones on ANY channel layout:
/// verified with ffmpeg 8.1.2 on a two-level stereo test signal
/// (quiet -36.5 dB mean / loud -9.1 dB mean) through the whole
/// chain — quiet -36.5 → -19.9 dB (+16.6 dB), loud -9.1 → -18.6 dB
/// (-9.5 dB), whole-file peak -12.6 dB (true-peak limiter, no
/// clipping). That is the dialogue effect: quiet dialogue comes up,
/// loud effects stop blowing out. Coefficients / target 待真机验证
/// (loudnorm's CPU cost and lookahead delay on an iPhone are
/// unmeasured here; the switch stays off by default and a rejected
/// filter never breaks playback).
const String kDialogueBoostCentreFilter =
    'lavfi[pan=stereo|c0=1.0*c0+0.7*c2+0.3*c4|c1=1.0*c1+0.7*c2+0.3*c5,'
    'loudnorm=I=-16:TP=-1.5:LRA=11:linear=false]';

class MpvBackend
    implements
        TrackCapableBackend,
        FrameCapableBackend,
        DialogueBoostCapableBackend,
        VodEnhancementCapableBackend {
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
    //
    // subtitleViewConfiguration visible:false (1.1.6, ROUTE A): the
    // built-in Flutter SubtitleView lives INSIDE Video, so it can
    // never paint above the danmaku layer — the VOD page draws the
    // text subtitles itself in a page-level overlay above danmaku,
    // fed by [subtitleStream]. Anything mpv draws into the frame
    // itself is untouched by this flag. (Fork note: with
    // libass=false the fork also sets sub-visibility=no, so bitmap
    // PGS subtitles most likely do not render at all today — that
    // is pre-existing behaviour, untested on a real device, not
    // something this flag changes.)
    return Video(
      controller: _videoController,
      wakelock: false,
      controls: (_) => const SizedBox.shrink(),
      fit: VideoFitMode.current.boxFit,
      subtitleViewConfiguration: const SubtitleViewConfiguration(
        visible: false,
      ),
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
    // K (build 29): mpv `volume-max=300` — the ceiling, not a gain.
    // mpv's default is 130, so a session volume above 1.3 (live
    // volume boost 131–300%, dialogue-boost headroom) is clamped
    // to 130% without this. Set on EVERY open (live + VOD): the
    // playing volume stays 100% until a gain is actually sent, so
    // raising the ceiling alone changes nothing audible.
    await _setProperty('volume-max', kMpvVolumeMax);
    final format = formatOf(url: url, declaredFormat: declaredFormat);
    final sourceProps = isLive
        ? mpvLiveSourceProperties(isHls: format == StreamFormat.hls)
        : kMpvVodSourceProperties;
    for (final entry in sourceProps.entries) {
      await _setProperty(entry.key, entry.value);
    }
    // Anime4K super-resolution (build 28): VOD only — live never
    // reaches this branch, so the live room is untouched. Applied at
    // open() from the Hive switch; a LATER toggle goes through
    // setSuperResolution() on the running player instead (b30).
    if (!isLive) {
      await _applySuperResolution();
      await _applyVodEnhancement();
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

  /// Dialogue boost (I-影视 item 3, VOD only): the mpv half of
  /// [DialogueBoostCapableBackend]. The session remembers the switch
  /// and re-applies it after every ladder swap, so this runs on a
  /// fresh backend as well as mid-playback; `af` is a persistent
  /// player option, so one set covers later episodes on the same
  /// backend instance.
  ///
  /// Two parts, both best-effort (a rejected write never breaks
  /// playback — same defensive pattern as the track setters):
  /// 1. `volume-max=300` (re-asserted here: the ceiling must hold
  ///    even if this backend was created before the open() set).
  /// 2. The centre-channel fold + loudnorm dynamic normalization
  ///    (only when enabling): the front centre (c2) + surrounds
  ///    (c4/c5) are folded into L/R, so dialogue sits louder
  ///    against music/effects, and loudnorm lifts quiet passages
  ///    and tames loud ones. Coefficients / target 待真机验证 (a
  ///    full-scale all-channels passage can clip with `=` gains
  ///    summing past 1.0 — if chen hears distortion, retune to the
  ///    `<` renormalized form; loudnorm's CPU cost and lookahead
  ///    delay on an iPhone are unmeasured here).
  ///
  /// Layout safety — VERIFIED on this VM with ffmpeg 8.1.2 (same
  /// filter engine family as mpv's bundled ffmpeg), not assumed:
  /// the PAN stage alone is bit-identical on stereo (volumedetect
  /// -21.1 dB with and without it — a missing c2 reads as silence)
  /// and folds correctly on 5.1. That is exactly why the pan-only
  /// chain was a摆设 on stereo (nearly every CMS stream): the
  /// switch was wired and set, and did nothing audible at all.
  /// The LOUDNORM stage (b30) is what makes it audible on stereo:
  /// on a two-level stereo test signal (quiet -36.5 dB mean / loud
  /// -9.1 dB mean) the whole chain lifts the quiet part to -19.9
  /// dB (+16.6 dB) and tames the loud part to -18.6 dB (-9.5 dB),
  /// whole-file peak -12.6 dB, no clipping. So the filter is
  /// applied UNCONDITIONALLY when the switch is on: no
  /// channel-count gate (no layout string is exposed by the backend
  /// anyway, and a gate would need one). If mpv's older bundled
  /// ffmpeg ever rejects the set, the throw is swallowed here and
  /// audio keeps playing unfiltered.
  @override
  Future<void> setDialogueBoost(bool enabled) async {
    try {
      await _setProperty('volume-max', kMpvVolumeMax);
      if (!enabled) {
        // Off: drop the centre filter. The ceiling stays 300 —
        // the live volume boost needs it regardless of this switch.
        await _setProperty('af', '');
        return;
      }
      await _setProperty('af', kDialogueBoostCentreFilter);
    } catch (_) {}
  }

  Future<void> _command(List<String> args) async {
    final platform = _player.platform;
    if (platform is NativePlayer) {
      await platform.command(args);
    }
  }

  /// FrameCapableBackend (1.1.6, danmaku occlusion avoidance): one
  /// JPEG snapshot of the current video frame for Vision person
  /// segmentation. Best-effort: null (never a throw) when not opened,
  /// disposed, or the native snapshot fails — the occlusion loop
  /// treats null as "skip this frame".
  @override
  Future<Uint8List?> captureFrameJpeg() async {
    if (_disposed || !_opened) return null;
    try {
      return await _player.screenshot(format: 'image/jpeg');
    } catch (_) {
      return null;
    }
  }

  /// Mounts the Anime4K efficiency chain when the gate passes.
  /// Decoration only: ANY failure (switch read, unpack, missing
  /// chain file, change-list rejection) is swallowed here — the film
  /// plays on without super-resolution and the failure never reaches
  /// the recovery ladder.
  Future<void> _applySuperResolution() async {
    try {
      if (!shouldApplySuperResolution(
        isLive: _isLive,
        engine: engine,
        switchOn: superResolutionSwitchOn(),
      )) {
        return;
      }
      final files = await unpackAnime4kShaders();
      if (files == null) return;
      await _command(glslShadersChangeListCommand(files));
    } catch (_) {}
  }

  /// Frame interpolation / SDR→HDR (1.1.6): the other two branches
  /// of the mutually-exclusive trio, applied at open() like
  /// super-resolution (the open-time fallback — a LATER toggle goes
  /// through setFrameInterpolation() / setSdrToHdr() on the running
  /// player instead, b30).
  /// Order is super-res → interpolation → SDR→HDR and only the
  /// FIRST passing branch runs, so a phone GPU never runs two of
  /// them at once. Decoration only, like [_applySuperResolution]:
  /// ANY failure setting a property is swallowed per property — the
  /// film plays on without the enhancement and the failure never
  /// reaches the recovery ladder or blocks playback.
  ///
  /// Effect is UNVERIFIED on a real device (vo=libmpv may silently
  /// disable interpolation; inverse-tone-mapping is marked
  /// vo=gpu-next only): if chen's phone shows no effect, the
  /// switch is dropped — this method only decides whether the
  /// properties are SET.
  Future<void> _applyVodEnhancement() async {
    try {
      final superResOn = superResolutionSwitchOn();
      final interpolationOn = vodInterpolationSwitchOn();
      final sdrToHdrOn = vodSdrToHdrSwitchOn();
      if (shouldApplyFrameInterpolation(
        isLive: _isLive,
        engine: engine,
        switchOn: interpolationOn,
        superResolutionOn: superResOn,
        sdrToHdrOn: sdrToHdrOn,
      )) {
        await _setPropertiesDefensively(kVodInterpolationProperties);
      } else if (shouldApplySdrToHdr(
        isLive: _isLive,
        engine: engine,
        switchOn: sdrToHdrOn,
        superResolutionOn: superResOn,
        interpolationOn: interpolationOn,
      )) {
        await _setPropertiesDefensively(kVodSdrToHdrProperties);
      }
    } catch (_) {}
  }

  /// Best-effort property writes: one rejected property must not
  /// abort the rest, and a failure here must never break playback.
  Future<void> _setPropertiesDefensively(
    Map<String, String> properties,
  ) async {
    for (final entry in properties.entries) {
      try {
        await _setProperty(entry.key, entry.value);
      } catch (_) {}
    }
  }

  /// VodEnhancementCapableBackend (b30): apply a trio toggle to the
  /// RUNNING player — no reopen, no rebuffer, the current episode
  /// changes at once. Every write is best-effort (a rejected
  /// property / command never breaks playback, same pattern as the
  /// track setters); a backend that is not opened yet simply has
  /// nothing to apply to and the open() path covers it from Hive.
  ///
  /// mpv facts behind the three: `glsl-shaders` is a runtime
  /// change-list (mount / `clr` to unmount); `interpolation`,
  /// `video-sync`, `tscale`, `inverse-tone-mapping`,
  /// `tone-mapping`, `target-trc`, `target-peak` are all runtime
  /// setProperty options. Turning a branch off restores the mpv
  /// defaults (kVodInterpolationOffProperties /
  /// kVodSdrToHdrOffProperties) instead of leaving the "on" values
  /// behind. Whether the picture visibly changes on a real iPhone
  /// (vo=libmpv may silently disable interpolation; inverse
  /// tone mapping is marked vo=gpu-next only) is still 待真机验证 —
  /// these methods only guarantee the properties are SENT to the
  /// running player.
  @override
  Future<void> setSuperResolution(bool enabled) async {
    try {
      if (!enabled) {
        await _command(glslShadersClearCommand());
        return;
      }
      final files = await unpackAnime4kShaders();
      if (files == null) return;
      await _command(glslShadersChangeListCommand(files));
    } catch (_) {}
  }

  @override
  Future<void> setFrameInterpolation(bool enabled) async {
    await _setPropertiesDefensively(
      enabled
          ? kVodInterpolationProperties
          : kVodInterpolationOffProperties,
    );
  }

  @override
  Future<void> setSdrToHdr(bool enabled) async {
    await _setPropertiesDefensively(
      enabled ? kVodSdrToHdrProperties : kVodSdrToHdrOffProperties,
    );
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

  /// TrueHD / DTS-HD fallback is PCM decode, not passthrough — and
  /// there is nothing to configure for it:
  ///
  /// - Routing: the capability gate (player_kernel.dart) already
  ///   excludes TrueHD / DTS from AVPlayer, so such streams reach
  ///   MPV (preferred) or IJK; the track list below enumerates them
  ///   and the player page's audio picker switches them.
  /// - Decode: mpv decodes to multichannel PCM by default. The
  ///   bundled libmpv links ffmpeg's `ff_truehd_decoder` and
  ///   `ff_dca_decoder` (verified on the VM 2026-11-22 via strings on
  ///   the media_kit prebuilt libmpv.so.2 — the iOS xcframework
  ///   itself is not on this VM, so the iOS binary is still
  ///   待真机验证). No SPDIF passthrough is configured anywhere
  ///   (`audio-spdif` is never set) and no channel cap
  ///   (`audio-channels` is never set), so on an iPhone the
  ///   multichannel PCM downmixes to stereo in the OS. There is no
  ///   passthrough to enable on iOS.
  /// - Still unverified on a real film: actual sound output and
  ///   channel behaviour on a TrueHD / DTS-HD track (待真机验证).
  @override
  Future<List<PlaybackTrack>> audioTracks() async {
    // media_kit always seeds the list with the 'auto'/'no' pseudo
    // tracks — a picker must never show those as real tracks.
    return _player.state.tracks.audio
        .where((t) => t.id != 'auto' && t.id != 'no')
        .map(
          (t) => PlaybackTrack(
            id: t.id,
            title: t.title,
            language: t.language,
            codec: t.codec,
          ),
        )
        .toList();
  }

  @override
  Future<List<PlaybackTrack>> subtitleTracks() async {
    return _player.state.tracks.subtitle
        .where((t) => t.id != 'auto' && t.id != 'no')
        .map(
          (t) => PlaybackTrack(
            id: t.id,
            title: t.title,
            language: t.language,
            codec: t.codec,
          ),
        )
        .toList();
  }

  @override
  Future<void> setAudioTrack(String id) async {
    try {
      await _player.setAudioTrack(
        id == 'auto' ? AudioTrack.auto() : AudioTrack(id, null, null),
      );
    } catch (_) {}
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    try {
      if (id == 'no') {
        await _player.setSubtitleTrack(SubtitleTrack.no());
        return;
      }
      await _player.setSubtitleTrack(
        id == 'auto'
            ? SubtitleTrack.auto()
            : SubtitleTrack(id, null, null),
      );
    } catch (_) {}
  }

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    // mpv `sub-delay` (seconds, may be negative): a runtime
    // setProperty, so it applies immediately without reopening.
    // Defensive like the track setters: a rejected write must never
    // break playback.
    try {
      await _setProperty('sub-delay', seconds.toStringAsFixed(1));
    } catch (_) {}
  }

  @override
  Future<void> setSubtitleAppearance({
    required int fontSize,
    required String color,
    required double position,
  }) async {
    // mpv `sub-font-size` / `sub-color` / `sub-pos`: runtime
    // setProperty calls, same defensive pattern as `sub-delay`.
    // `sub-pos` is a float (0 = top, 100 = bottom); the caller
    // passes the tier value from vod_controls.dart.
    try {
      await _setProperty('sub-font-size', fontSize.toString());
      await _setProperty('sub-color', color);
      await _setProperty('sub-pos', position.toStringAsFixed(0));
    } catch (_) {}
  }

  @override
  Future<void> setSecondarySubtitleTrack(String id) async {
    // mpv `secondary-sid`: the second track renders as toptitle
    // above the main track. 'no' turns dual subtitles off. Bitmap
    // subtitles as the secondary track overlap the main track
    // (mpv behaviour) — the picker must say so, not crash.
    try {
      await _setProperty('secondary-sid', id);
    } catch (_) {}
  }

  @override
  Stream<List<String>> get subtitleStream => _player.stream.subtitle;

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
