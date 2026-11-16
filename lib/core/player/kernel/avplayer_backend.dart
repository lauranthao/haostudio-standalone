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
      const BetterPlayerConfiguration(
        autoPlay: true,
        controlsConfiguration: BetterPlayerControlsConfiguration(
          showControls: false,
        ),
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
      _playingController.add(value.isPlaying);
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
  Stream<Duration> get positionStream => _positionController.stream;

  @override
  Stream<Duration> get durationStream => _durationController.stream;

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
