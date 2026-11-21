// Player backend contract — one backend per engine.
//
// The native player (media_kit / fijk / BetterPlayer) IS the player for
// live AND VOD. The web page is only a browsing shell and must never render
// a web <video> player inside the app.
//
// Dispose discipline (fix 1, Dart spelling of the Swift C-string /
// render-queue crashes): every dispose first cancels/awaits pending frame
// or render callbacks, then releases the native handle, then nulls the
// reference; never release while a callback may still hold it, and never
// dispose twice. Dispose is idempotent and safe from any lifecycle path.

import 'package:flutter/widgets.dart';

import 'player_engine.dart';

/// Result of a staged open: the backend is only swapped in after it has
/// PROVEN it can play (first frame or position movement), never merely
/// because open() returned.
enum BackendOpenResult { playing, failed }

/// Seed a duration stream with the value the backend already knows.
///
/// Duration is a ONE-SHOT signal: mpv reports it once, when the
/// playlist is parsed, and it never changes for a VOD. The session only
/// subscribes to the backend's durationStream after the first frame is
/// verified — by then the event has already fired into a plain broadcast
/// stream with no listener, so it is lost. A lost duration means the
/// progress bar (gated on duration > 0) never appears at all (chen
/// v1.0.8: "根本没有进度条"). Seeding the already-known value when the
/// stream is first listened to closes the race: a late subscriber still
/// gets the duration, and later live events still flow through
/// unchanged. A zero/unknown duration seeds nothing, so live (which
/// never has a duration) is unaffected.
Stream<Duration> seedKnownDuration(
  Duration known,
  Stream<Duration> source,
) async* {
  if (known > Duration.zero) yield known;
  yield* source;
}

/// One audio/subtitle track of the current source, as enumerated by
/// the active backend. [id] is backend-native (mpv track id);
/// 'auto' = backend default, 'no' = off (subtitles; audio 'no'
/// mutes). Backends that cannot enumerate tracks (IJK, AVPlayer)
/// return empty lists — the session surfaces "no tracks" instead of
/// a broken picker.
class PlaybackTrack {
  const PlaybackTrack({
    required this.id,
    this.title,
    this.language,
    this.codec,
  });

  final String id;
  final String? title;
  final String? language;
  final String? codec;

  /// Picker label: title first, then language + codec, then the id.
  String get displayName {
    final parts = <String>[
      if (title != null && title!.isNotEmpty) title!,
      if (language != null && language!.isNotEmpty) language!,
      if (codec != null && codec!.isNotEmpty) codec!,
    ];
    if (parts.isEmpty) return '轨道 $id';
    return parts.join(' · ');
  }
}

/// Optional capability: backends that can enumerate and switch
/// EMBEDDED audio/subtitle tracks implement this IN ADDITION to
/// [PlayerBackend]. It is a separate interface on purpose: the old
/// fakes (and the other two engines) use `implements PlayerBackend`,
/// and any method added to that class — even with a default body —
/// breaks every `implements` fake at compile time. MPV implements
/// this (media_kit track API); IJK has no track API in flv_lzc and
/// AVPlayer (BetterPlayer) only switches audio on HLS/DASH and only
/// loads subtitles from external files — both stay without it, and
/// the session surfaces "no tracks" on them.
///
/// It EXTENDS [PlayerBackend] on purpose, not just for the
/// contract: Dart only narrows an `is` test when the tested type
/// is a subtype of the variable's type, so an unrelated interface
/// would never promote (`backend is TrackCapableBackend` would
/// leave `backend` typed as `PlayerBackend`). With the extends,
/// `is TrackCapableBackend` narrows and the session can call the
/// track methods directly.
abstract class TrackCapableBackend extends PlayerBackend {
  /// Audio tracks of the current source (embedded).
  Future<List<PlaybackTrack>> audioTracks();

  /// Subtitle tracks of the current source (embedded).
  Future<List<PlaybackTrack>> subtitleTracks();

  /// Select an audio track by [PlaybackTrack.id] ('auto' = backend
  /// default).
  Future<void> setAudioTrack(String id);

  /// Select a subtitle track by [PlaybackTrack.id] ('auto' = backend
  /// default, 'no' = off).
  Future<void> setSubtitleTrack(String id);

  /// Shift the main subtitle track in time (MPV `sub-delay`, seconds,
  /// negative = earlier). 1.1.6, VOD only. Backends without the
  /// capability do not implement this interface at all — the session
  /// only calls it on a [TrackCapableBackend].
  Future<void> setSubtitleDelay(double seconds);

  /// Set the subtitle appearance (MPV `sub-font-size` / `sub-color` /
  /// `sub-pos`). 1.1.6, VOD only. Same MPV-only scope as
  /// [setSubtitleDelay]: `fontSize` is the mpv point size, `color`
  /// a 6-digit `#RRGGBB`, `position` the mpv `sub-pos` (0 = top,
  /// 100 = bottom). Default is a no-op on purpose (not abstract):
  /// only MPV implements it, and the test fakes implementing this
  /// interface must keep compiling without a stub.
  Future<void> setSubtitleAppearance({
    required int fontSize,
    required String color,
    required double position,
  }) async {}

  /// Select the SECOND subtitle track for dual subtitles (MPV
  /// `secondary-sid`, shown as toptitle above the main track).
  /// 'no' = dual subtitles off. Same MPV-only scope as
  /// [setSubtitleDelay].
  Future<void> setSecondarySubtitleTrack(String id);

  /// Text subtitle lines from mpv, `[main, secondary]` — the
  /// `sub-text` / `secondary-sub-text` property observations. The
  /// page draws these in its own overlay (above the danmaku layer);
  /// bitmap subtitles (PGS) have no text event and are not in here.
  Stream<List<String>> get subtitleStream;
}

abstract class PlayerBackend {
  PlayerEngine get engine;

  /// The native video surface for this backend (16:9 via AspectRatio at
  /// the call site).
  Widget buildVideoWidget();

  /// Open a URL. Applies per-source properties (live: cache-pause=no,
  /// force-seekable=no; HLS: demuxer-lavf-format=hls) before playback.
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  });

  /// Verify real playback: first frame or position movement within
  /// [timeout]. `open` returning is NOT success.
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  });

  Future<void> play();
  Future<void> pause();
  Future<void> setVolume(double volume);

  /// Audio-only mode (Pure Live background playback): disable the
  /// video track so a suspended video output cannot pause the whole
  /// stream when the app backgrounds (mpv pauses when vo=libmpv can
  /// no longer present frames; a music player has no video track and
  /// is unaffected — that is why music keeps playing in background
  /// while live stops). MPV implements it via
  /// setVideoTrack(VideoTrack.no()/auto()); other engines keep the
  /// default no-op. Default is a no-op so fakes keep compiling.
  Future<void> setAudioOnly(bool audioOnly) async {}

  /// Playback speed (VOD only; live never sets it). Default is a
  /// no-op so fakes keep compiling; the three real backends override
  /// it (MPV setRate / IJK setSpeed / AVPlayer setSpeed).
  Future<void> setRate(double rate) async {}

  /// Position stream — health is judged by POSITION movement, not by
  /// player flags (`playing` only means "not paused").
  Stream<Duration> get positionStream;

  /// Total duration when known (VOD). Live streams report Duration.zero
  /// (or never emit). Emits when the duration becomes known / changes,
  /// so the UI can build a progress bar once the value exists.
  Stream<Duration> get durationStream;

  /// Seek to [position] (VOD only). Live backends ignore it (live is
  /// not seekable); the session never calls it for live.
  Future<void> seekTo(Duration position);

  /// True while the backend reports playing.
  Stream<bool> get playingStream;

  /// Fatal playback errors (empty string payloads are ignored by callers).
  Stream<String> get errorStream;

  /// Normal end of a VOD source (live EOF is an error, not completion).
  Stream<void> get completedStream;

  /// Idempotent dispose: cancel callbacks first, then release the handle.
  Future<void> dispose();
}
