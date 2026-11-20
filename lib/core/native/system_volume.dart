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

  /// Own-set echo suppression (chen 2026-11-20: volume drag is
  /// choppy). iOS fires AVAudioSession outputVolume KVO for EVERY
  /// change — including the app's own MPVolumeView sets — and the
  /// system volume is quantized to 1/16 steps. Without suppression,
  /// each drag tick's setVolume echoes back a lagging, stair-stepped
  /// value that overwrites the in-progress drag value, so the HUD
  /// and the real level advance in a sawtooth instead of smoothly.
  /// An incoming volumeChanged is dropped when its value is within
  /// [_echoEpsilon] of any value this class set in the last
  /// [_echoWindow]: a genuine hardware-key / Control Center change
  /// lands on a value no recent set produced (a press moves the level
  /// by exactly 1/16), or on the same value, which is already
  /// displayed — so it still passes through.
  static const Duration _echoWindow = Duration(milliseconds: 150);

  /// iOS quantizes the system volume to 1/16 steps, so an echo of an
  /// own set can sit up to 1/32 (0.03125) away from the value that
  /// was set; 0.04 absorbs that while staying below one hardware-key
  /// step (1/16 = 0.0625), so a real key press is never swallowed.
  static const double _echoEpsilon = 0.04;

  /// (value, wall-clock ms) of recent own sets, pruned to
  /// [_echoWindow] on every access. Bounded: at most ~32 entries.
  final List<({double value, int atMs})> _recentOwnSets = [];

  void _recordOwnSet(double value) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentOwnSets
      ..removeWhere((e) => now - e.atMs > _echoWindow.inMilliseconds)
      ..add((value: value, atMs: now));
    if (_recentOwnSets.length > 32) {
      _recentOwnSets.removeRange(0, _recentOwnSets.length - 32);
    }
  }

  bool _isOwnEcho(double value) {
    final now = DateTime.now().millisecondsSinceEpoch;
    _recentOwnSets.removeWhere(
      (e) => now - e.atMs > _echoWindow.inMilliseconds,
    );
    return _recentOwnSets.any(
      (e) => (e.value - value).abs() <= _echoEpsilon,
    );
  }

  /// Emits whenever the system volume changes outside the app
  /// (hardware keys, Control Center). Echoes of this class's own
  /// [setVolume] calls are suppressed (see [_recentOwnSets]) — the
  /// caller already knows the value it set.
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
  ///
  /// Trailing-edge coalescing (chen 2026-11-20: volume drag is
  /// choppy): a drag fires one set per pointer tick, and each call is
  /// a full platform round-trip. While one call is in flight, newer
  /// targets only replace the pending value — the channel never
  /// carries a queue of stale levels, and the final value is always
  /// flushed (the loop runs until no pending target is left).
  bool _setInFlight = false;
  double? _pendingSet;

  Future<void> setVolume(double volume) async {
    final target = volume.clamp(0.0, 1.0);
    // Record synchronously, before the await: the native KVO echo of
    // this set can arrive while the call is still in flight.
    _recordOwnSet(target);
    if (_setInFlight) {
      _pendingSet = target;
      return;
    }
    _setInFlight = true;
    var current = target;
    try {
      while (true) {
        await _channel.invokeMethod<void>('setVolume', <String, Object>{
          'volume': current,
        });
        _lastKnown = current;
        final next = _pendingSet;
        _pendingSet = null;
        if (next == null || next == current) break;
        current = next;
      }
    } catch (e) {
      // A failed send drops the queued target too: the next drag tick
      // sends a fresh value, and a stale one must never jump the
      // level after a newer one was already applied.
      _pendingSet = null;
      debugPrint('[HAo] system_volume setVolume failed: $e');
    } finally {
      _setInFlight = false;
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method != 'volumeChanged') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final raw = args['volume'];
    if (raw is! num) return null;
    final value = raw.toDouble().clamp(0.0, 1.0);
    // Echo of an own set (see _recentOwnSets): the caller already
    // shows this value — forwarding it would yank the in-progress
    // drag HUD back to a lagging, quantized level.
    if (_isOwnEcho(value)) return null;
    _lastKnown = value;
    _controller.add(value);
    return null;
  }

  /// Detach the channel handler. Call when the owner is disposed.
  void dispose() {
    _channel.setMethodCallHandler(null);
    unawaited(_controller.close());
  }
}
