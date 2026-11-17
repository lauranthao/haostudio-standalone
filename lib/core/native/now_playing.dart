// Now Playing bridge (Fix 14) — Dart side of the iOS Now Playing shell.
//
// The Swift side (ios/Runner/NowPlayingPlugin.swift) publishes the current
// track to MPNowPlayingInfoCenter and owns the MPRemoteCommandCenter
// handlers (play / pause / toggle / seek / next / previous). This service
// pushes track state to Swift over the
// `com.haostudio.standalone/now_playing` MethodChannel and receives remote
// commands back over the same channel.
//
// Double-fire guard: there is only ONE remote-command path in the Flutter
// app (media_kit registers no remote commands and there is no web Media
// Session bridge), so one press normally fires exactly once. The service
// additionally dedupes rapid next/previous commands (same command within
// 300 ms), so a stray duplicate delivery can never advance two tracks.
// Play / pause / toggle / seek are idempotent, so no dedupe is needed
// for them.
//
// Behaviour only — the music player LOOK is untouched. No ±10 s skip is
// added to music (video keeps its own ±10 s, untouched). No Live
// Activity is added: tapping the Now Playing card / Dynamic Island /
// Lock Screen opens the app via the audio session + Now Playing info.

import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';

/// MethodChannel name shared with ios/Runner/NowPlayingPlugin.swift.
const String nowPlayingChannelName = 'com.haostudio.standalone/now_playing';

/// Remote commands the system can send (Lock Screen / Control Center /
/// Dynamic Island / headphones).
enum NowPlayingRemoteCommand { play, pause, toggle, next, previous, seek }

/// Handler invoked for a remote command. [position] is set only for
/// [NowPlayingRemoteCommand.seek] (seconds).
typedef NowPlayingRemoteCommandHandler = Future<void> Function(
  NowPlayingRemoteCommand command, {
  double? position,
});

/// Two identical nav commands closer together than this are treated as
/// one press delivered twice, and the second is dropped.
const Duration _navDedupeWindow = Duration(milliseconds: 300);

class NowPlayingService {
  NowPlayingService({MethodChannel? channel})
      : _channel = channel ?? const MethodChannel(nowPlayingChannelName) {
    _channel.setMethodCallHandler(_onMethodCall);
  }

  final MethodChannel _channel;

  NowPlayingRemoteCommandHandler? onRemoteCommand;

  NowPlayingRemoteCommand? _lastNavCommand;
  DateTime? _lastNavAt;

  /// Publish the current track to the system Now Playing. Call on track
  /// change, play/pause, seek, and (throttled to ~1 s) while playing so
  /// the Lock Screen elapsed time stays fresh.
  ///
  /// Failures are logged in debug instead of vanishing into `unawaited`:
  /// a MissingPluginException here means the native plugin never
  /// registered and Now Playing is silently dead (that is how the
  /// v1.0.5 tap-to-open bug hid — no trace anywhere).
  Future<void> updateTrack({
    required String title,
    String artist = '',
    String album = '',
    String coverUrl = '',
    Duration duration = Duration.zero,
    Duration position = Duration.zero,
    required bool playing,
  }) async {
    try {
      await _channel.invokeMethod<void>('updateNowPlaying', <String, Object>{
        'title': title,
        'artist': artist,
        'album': album,
        'coverUrl': coverUrl,
        'duration': duration.inMilliseconds / 1000.0,
        'position': position.inMilliseconds / 1000.0,
        'playing': playing,
      });
    } catch (e) {
      debugPrint('[HAo] now_playing updateTrack failed: $e');
    }
  }

  /// Clear the system Now Playing (no track loaded / player stopped).
  Future<void> clear() async {
    try {
      await _channel.invokeMethod<void>('clearNowPlaying');
    } catch (e) {
      debugPrint('[HAo] now_playing clear failed: $e');
    }
  }

  /// Ask iOS to present the system AirPlay route picker
  /// (AVRoutePickerView). Returns true when the picker opened. The
  /// picker itself lists the available routes — or just this iPhone
  /// when none are around — so this side never invents a "no device"
  /// message. Returns false when the native side could not open the
  /// picker (no key window / picker button not found) or the channel
  /// call fails.
  Future<bool> showAirPlayPicker() async {
    try {
      final opened = await _channel.invokeMethod<bool>('showAirPlayPicker');
      return opened ?? false;
    } catch (e) {
      debugPrint('[HAo] now_playing showAirPlayPicker failed: $e');
      return false;
    }
  }

  Future<dynamic> _onMethodCall(MethodCall call) async {
    if (call.method != 'remoteCommand') return null;
    final args = call.arguments;
    if (args is! Map) return null;
    final raw = args['command'];
    if (raw is! String) return null;
    final command = NowPlayingRemoteCommand.values
        .where((c) => c.name == raw)
        .firstOrNull;
    if (command == null) return null;

    // Dedupe: one physical press must advance exactly one track.
    if (command == NowPlayingRemoteCommand.next ||
        command == NowPlayingRemoteCommand.previous) {
      final now = DateTime.now();
      if (_lastNavCommand == command &&
          _lastNavAt != null &&
          now.difference(_lastNavAt!) < _navDedupeWindow) {
        return null;
      }
      _lastNavCommand = command;
      _lastNavAt = now;
    }

    double? position;
    final rawPos = args['position'];
    if (rawPos is num) position = rawPos.toDouble();
    final handler = onRemoteCommand;
    if (handler != null) {
      await handler(command, position: position);
    }
    return null;
  }

  /// Detach the channel handler. Call when the owner is disposed.
  void dispose() {
    _channel.setMethodCallHandler(null);
  }
}
