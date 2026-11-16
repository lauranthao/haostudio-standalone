// IJK backend — flv_lzc fork of fijkplayer. Priority 90.
//
// IJK options are raw ijk triples (not mpv properties). Live FLV uses the
// reconnect triple so a dropped live connection recovers inside IJK.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flv_lzc/fijkplayer.dart';

import 'player_backend.dart';
import 'player_engine.dart';

class IjkBackend implements PlayerBackend {
  IjkBackend() {
    _player = FijkPlayer();
  }

  late final FijkPlayer _player;
  final _errorController = StreamController<String>.broadcast();
  final _completedController = StreamController<void>.broadcast();
  bool _disposed = false;
  bool _opened = false;

  @override
  PlayerEngine get engine => PlayerEngine.fijk;

  @override
  Widget buildVideoWidget() => FijkView(player: _player);

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    // IJK reconnect triple for live (headers are not supported by the
    // fijk data source call; live lines carry auth in the URL itself).
    if (isLive) {
      await _player.setOption(FijkOption.formatCategory, 'reconnect', 1);
      await _player.setOption(
        FijkOption.formatCategory,
        'reconnect_streamed',
        1,
      );
      await _player.setOption(
        FijkOption.formatCategory,
        'reconnect_on_network_error',
        1,
      );
      await _player.setOption(FijkOption.playerCategory, 'mediacodec', 1);
    }
    _player.addListener(_onPlayerChanged);
    await _player.setDataSource(url, autoPlay: true);
    await _player.prepareAsync();
    _opened = true;
  }

  void _onPlayerChanged() {
    if (_disposed) return;
    final state = _player.value.state;
    if (state == FijkState.error) {
      _errorController.add('ijk error');
    } else if (state == FijkState.completed) {
      _completedController.add(null);
    }
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!_opened) return false;
    if (_player.value.state == FijkState.started) return true;
    final completer = Completer<bool>();
    void listener() {
      if (completer.isCompleted) return;
      final state = _player.value.state;
      if (state == FijkState.started) {
        completer.complete(true);
      } else if (state == FijkState.error) {
        completer.complete(false);
      }
    }

    _player.addListener(listener);
    try {
      return await completer.future.timeout(timeout, onTimeout: () => false);
    } finally {
      _player.removeListener(listener);
    }
  }

  @override
  Future<void> play() => _player.start();

  @override
  Future<void> pause() => _player.pause();

  @override
  Future<void> setVolume(double volume) => _player.setVolume(volume);

  @override
  Future<void> setRate(double rate) => _player.setSpeed(rate);

  // Audio-only is MPV-only (see PlayerBackend.setAudioOnly): IJK
  // keeps the interface default no-op.
  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Stream<Duration> get positionStream => _player.onCurrentPosUpdate;

  @override
  Stream<Duration> get durationStream => Stream<Duration>.periodic(
        const Duration(milliseconds: 500),
        (_) => _player.value.duration,
      ).distinct();

  @override
  Future<void> seekTo(Duration position) =>
      _player.seekTo(position.inMilliseconds);

  @override
  Stream<bool> get playingStream => Stream<bool>.periodic(
        const Duration(milliseconds: 500),
        (_) => _player.value.state == FijkState.started,
      ).distinct();

  @override
  Stream<String> get errorStream => _errorController.stream;

  @override
  Stream<void> get completedStream => _completedController.stream;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    // Cancel callbacks first (fix 1), then release the native handle.
    _player.removeListener(_onPlayerChanged);
    await _player.stop();
    await _player.release();
    await _errorController.close();
    await _completedController.close();
  }
}
