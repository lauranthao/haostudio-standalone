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

class MpvBackend implements PlayerBackend {
  MpvBackend() {
    _player = Player(
      configuration: const PlayerConfiguration(title: 'HAo Studio'),
    );
    _videoController = VideoController(_player);
  }

  late final Player _player;
  late final VideoController _videoController;
  bool _disposed = false;
  bool _opened = false;

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Widget buildVideoWidget() => Video(controller: _videoController);

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    // Base tuning first, then per-source properties (per-source wins).
    // NOTE: public Player has no setProperty in media_kit 1.1.11 — the
    // properties go through the underlying NativePlayer (the same call
    // Pure Live's media_kit adapter makes via NativePlayer.setProperty).
    for (final entry in kMpvBaseProperties.entries) {
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
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!_opened) return false;
    final completer = Completer<bool>();
    late final StreamSubscription<int?> widthSub;
    late final StreamSubscription<Duration> posSub;
    late final StreamSubscription<String> errSub;
    late final StreamSubscription<bool> doneSub;
    void finish(bool ok) {
      if (completer.isCompleted) return;
      completer.complete(ok);
      unawaited(widthSub.cancel());
      unawaited(posSub.cancel());
      unawaited(errSub.cancel());
      unawaited(doneSub.cancel());
    }

    widthSub = _player.stream.width.listen((w) {
      if ((w ?? 0) > 0) finish(true);
    });
    posSub = _player.stream.position.listen((p) {
      if (p > Duration.zero) finish(true);
    });
    errSub = _player.stream.error.listen((e) {
      if (e.isNotEmpty) finish(false);
    });
    doneSub = _player.stream.completed.listen((done) {
      if (done) finish(false);
    });
    return completer.future.timeout(timeout, onTimeout: () {
      finish(false);
      return false;
    });
  }

  @override
  Future<void> play() => _player.play();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume * 100);

  @override
  Stream<Duration> get positionStream => _player.stream.position;

  @override
  Stream<Duration> get durationStream => _player.stream.duration;

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
