// System volume bridge — Dart side of ios/Runner/SystemVolumePlugin.swift.
//
// The video / live players drive the DEVICE volume through this channel
// (`getVolume` / `setVolume`, 0-1), never the player gain: the player
// gain (`PlaybackSession.setVolume`) leaves the system volume bar
// untouched, which is the bug chen reported. The native side pushes
// `volumeChanged` when the level moves outside the app (hardware keys,
// Control Center), so the drag HUD stays on the real value.
//
// Best-effort throughout: a missing native side (unit tests, Android
// until its native side lands) never throws — reads fall back to the
// last known level, writes are dropped.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// MethodChannel name shared with ios/Runner/SystemVolumePlugin.swift.
const String systemVolumeChannelName =
    'com.haostudio.standalone/system_volume';

class SystemVolume {
  SystemVolume({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(systemVolumeChannelName) {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  final MethodChannel _channel;
  final _controller = StreamController<double>.broadcast();

  /// Last level the native side reported (or was set to). 1.0 until
  /// anything is known — the only safe neutral value.
  double _lastKnown = 1.0;

  /// Emits whenever the system volume changes outside the app
  /// (hardware keys, Control Center). Own `setVolume` calls are not
  /// echoed back as a separate event here — the caller already knows
  /// the value it set.
  Stream<double> get volumeChanges => _controller.stream;

  /// Current system volume, 0-1. Falls back to the last known level
  /// when the native side cannot answer.
  Future<double> getVolume() async {
    try {
      final value = await _channel.invokeMethod<double>('getVolume');
      if (value == null) return _lastKnown;
      _lastKnown = value.clamp(0.0, 1.0);
      return _lastKnown;
    } catch (e) {
      debugPrint('[HAo] system_volume getVolume failed: $e');
      return _lastKnown;
    }
  }

  /// Set the system volume, 0-1 (clamped). Best-effort: a missing
  /// native side drops the write instead of throwing.
  Future<void> setVolume(double volume) async {
    final target = volume.clamp(0.0, 1.0);
    try {
      await _channel.invokeMethod<void>('setVolume', <String, Object>{
        'volume': target,
      });
      _lastKnown = target;
    } catch (e) {
      debugPrint('[HAo] system_volume setVolume failed: $e');
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method != 'volumeChanged') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final raw = args['volume'];
    if (raw is! num) return null;
    _lastKnown = raw.toDouble().clamp(0.0, 1.0);
    _controller.add(_lastKnown);
    return null;
  }

  /// Detach the channel handler. Call when the owner is disposed.
  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_controller.close());
  }
}
