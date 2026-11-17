// AVPlayer backend — better_player_plus (AVPlayer underneath on iOS).
// Priority 80.
//
// AVFoundation has NO FLV demuxer: this backend can never play FLV, and
// the kernel selector guarantees it is never offered FLV (see
// player_kernel.dart). HLS / MP4 play here. Controls are hidden — the app
// draws its own Pure Live-style control bar, never BetterPlayer's.

import 'dart:async';

import 'package:better_player_plus/better_player_plus.dart';
import 'package:flutter/widgets.dart';

import 'player_backend.dart';
import 'player_engine.dart';
import 'video_fit.dart';

class AvPlayerBackend implements PlayerBackend {
  AvPlayerBackend();

  BetterPlayerController? _controller;
  final _errorController = StreamController<String>.broadcast();
  final _completedController = StreamController<void>.broadcast();
  final _positionController = StreamController<Duration>.broadcast();
  final _playingController = StreamController<bool>.broadcast();
  final _durationController = StreamController<Duration>.broadcast();
  Timer? _pollTimer;
  bool _disposed = false;
  bool _opened = false;
  Duration _lastPosition = Duration.zero;
  Duration _lastDuration = Duration.zero;
  bool _lastPlaying = false;

  @override
  PlayerEngine get engine => PlayerEngine.exo;

  @override
  Widget buildVideoWidget() {
    final controller = _controller;
    if (controller == null) return const SizedBox.shrink();
    return BetterPlayer(controller: controller);
  }

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    // FLV must never reach this backend (selector gate); refuse loudly
    // rather than showing a spinner over a dead stream.
    final lower = url.toLowerCase().split('?').first;
    if (lower.endsWith('.flv') ||
        (declaredFormat?.toLowerCase() == 'flv')) {
      throw StateError('AVPlayer cannot play FLV');
    }
    final dataSource = BetterPlayerDataSource(
      BetterPlayerDataSourceType.network,
      url,
      headers: headers ?? const {},
    );
    _controller = BetterPlayerController(
      // NOT const: `fit` is read from the persisted VideoFitMode at
      // open time. BetterPlayerConfiguration is fixed when the
      // controller is created, so a mid-play fit cycle on this engine
      // takes effect on the NEXT open (MPV/IJK apply it live — see
      // video_fit.dart); the choice is never lost, just deferred.
      // Live always renders contain: this backend serves live rooms
      // too, and a stretched live room is never what the user asked
      // for when they set a VOD fit.
      BetterPlayerConfiguration(
        autoPlay: true,
        controlsConfiguration: BetterPlayerControlsConfiguration(
          showControls: false,
        ),
        // fit: contain, explicit — BetterPlayer defaults to fill
        // (stretches a non-16:9 stream). MPV and IJK both render
        // contain, so all three kernels behave identically in the
        // 16:9 room container: a 16:9 stream fills it, anything else
        // is letterboxed, never distorted.
        fit: isLive ? BoxFit.contain : VideoFitMode.current.boxFit,
      ),
      betterPlayerDataSource: dataSource,
    );
    _opened = true;
    _pollTimer = Timer.periodic(const Duration(milliseconds: 500), (_) {
      if (_disposed) return;
      final vc = _controller?.videoPlayerController;
      if (vc == null) return;
      final value = vc.value;
      if (value.hasError) {
        _errorController.add(value.errorDescription ?? 'avplayer error');
      }
      if (value.position != _lastPosition) {
        _lastPosition = value.position;
        _positionController.add(value.position);
      }
      final duration = value.duration;
      if (duration != null && duration != _lastDuration) {
        _lastDuration = duration;
        _durationController.add(duration);
      }
      // playing: emit only on change, like position/duration below.
      // Was: every 500 ms tick, so any listener rebuilt twice a second
      // forever even while nothing changed.
      if (value.isPlaying != _lastPlaying) {
        _lastPlaying = value.isPlaying;
        _playingController.add(value.isPlaying);
      }
    });
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!_opened) return false;
    final deadline = DateTime.now().add(timeout);
    while (DateTime.now().isBefore(deadline)) {
      if (_disposed) return false;
      final vc = _controller?.videoPlayerController;
      if (vc != null) {
        if (vc.value.hasError) return false;
        // NOTE: better_player_plus vendors its own video_player copy
        // whose value has `initialized` (duration != null), NOT
        // `isInitialized`.
        if (vc.value.initialized && vc.value.isPlaying) return true;
        if (vc.value.initialized && vc.value.position > Duration.zero) {
          return true;
        }
      }
      await Future<void>.delayed(const Duration(milliseconds: 200));
    }
    return false;
  }

  @override
  Future<void> play() async => _controller?.play();

  @override
  Future<void> pause() async => _controller?.pause();

  @override
  Future<void> setVolume(double volume) async =>
      _controller?.setVolume(volume);

  @override
  Future<void> setRate(double rate) async => _controller?.setSpeed(rate);

  // Audio-only is MPV-only (see PlayerBackend.setAudioOnly): AVPlayer
  // keeps the interface default no-op.
  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  // Seed the duration the poll already knows (_lastDuration): the poll
  // only emits on change, so a duration that arrived before the
  // session subscribed is otherwise lost forever — same one-shot race
  // as MPV (chen v1.0.8: "根本没有进度条"). Live keeps _lastDuration at
  // zero, so the seed is a no-op there.
  Stream<Duration> get durationStream =>
      seedKnownDuration(_lastDuration, _durationController.stream);

  @override
  Future<void> seekTo(Duration position) async {
    await _controller?.seekTo(position);
  }

  @override
  Stream<bool> get playingStream => _playingController.stream;

  @override
  Stream<String> get errorStream => _errorController.stream;

  @override
  Stream<void> get completedStream => _completedController.stream;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Cancel callbacks first (fix 1), then release the native handle.
    // BetterPlayerController.dispose is sync void (not a Future).
    _pollTimer?.cancel();
    _pollTimer = null;
    _controller?.dispose();
    _controller = null;
    await _errorController.close();
    await _completedController.close();
    await _positionController.close();
    await _playingController.close();
    await _durationController.close();
  }
}
