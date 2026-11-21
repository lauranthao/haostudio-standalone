// VOD subtitle delay + dual subtitles (1.1.6) — session tests.
//
// Deliberately imports NO player page: the session contract
// (clamp to ±10 s, remember, re-apply on backend swap) is verified
// here, so this file keeps compiling even when another group's file
// breaks the player page's import chain.
//
// The overlay itself (text lines above danmaku) is covered by the
// widget tests in vod_skip_intro_test.dart.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/features/player/playback_session.dart';

/// Minimal MPV-shaped fake: only the subtitle members + the open
/// handshake matter here.
class _SubtitleFakeBackend implements TrackCapableBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final _subtitleLines = StreamController<List<String>>.broadcast();

  final List<double> subtitleDelayCalls = [];
  final List<String> secondarySubtitleCalls = [];
  final List<String> subtitleAppearanceCalls = [];
  bool _disposed = false;

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Widget buildVideoWidget() => const SizedBox.shrink();

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {}

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      true;

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Future<void> seekTo(Duration position) async {}

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Future<List<PlaybackTrack>> audioTracks() async => const [];

  @override
  Future<List<PlaybackTrack>> subtitleTracks() async => const [];

  @override
  Future<void> setAudioTrack(String id) async {}

  @override
  Future<void> setSubtitleTrack(String id) async {}

  @override
  Future<void> setSubtitleDelay(double seconds) async {
    subtitleDelayCalls.add(seconds);
  }

  @override
  Future<void> setSecondarySubtitleTrack(String id) async {
    secondarySubtitleCalls.add(id);
  }

  @override
  Future<void> setSubtitleAppearance({
    required int fontSize,
    required String color,
    required double position,
  }) async {
    subtitleAppearanceCalls.add('$fontSize|$color|$position');
  }

  @override
  Stream<List<String>> get subtitleStream => _subtitleLines.stream;

  @override
  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _error.close();
    await _completed.close();
    await _subtitleLines.close();
  }
}

void main() {
  test('session clamps subtitle delay and re-applies it on backend swap',
      () async {
    final first = _SubtitleFakeBackend();
    final second = _SubtitleFakeBackend();
    var calls = 0;
    final session = PlaybackSession(
      backendFactory: (_) => ++calls == 1 ? first : second,
    );
    addTearDown(session.dispose);
    expect(
      await session.open(url: 'https://example.com/ep1.mp4', isLive: false),
      isTrue,
    );
    await session.setSubtitleDelay(12.0);
    expect(session.currentSubtitleDelay, 10.0);
    expect(first.subtitleDelayCalls, [10.0]);
    await session.setSecondarySubtitleTrack('11');
    expect(session.currentSecondarySubtitleTrackId, '11');
    expect(first.secondarySubtitleCalls, ['11']);
    // A second open swaps in a fresh backend: delay + secondary
    // track must be re-applied to it.
    expect(
      await session.open(url: 'https://example.com/ep1.mp4', isLive: false),
      isTrue,
    );
    expect(second.subtitleDelayCalls, [10.0]);
    expect(second.secondarySubtitleCalls, ['11']);
  });

  test('session forwards subtitle lines from the capable backend',
      () async {
    final backend = _SubtitleFakeBackend();
    final session = PlaybackSession(backendFactory: (_) => backend);
    addTearDown(session.dispose);
    expect(
      await session.open(url: 'https://example.com/ep1.mp4', isLive: false),
      isTrue,
    );
    final seen = <List<String>>[];
    final sub = session.subtitleStream.listen(seen.add);
    addTearDown(sub.cancel);
    backend._subtitleLines.add(['你好', 'Hello']);
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(seen, [
      ['你好', 'Hello'],
    ]);
  });
}
