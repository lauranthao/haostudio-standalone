// Track-switching plumbing tests (build 28, task E).
//
// PlaybackSession <-> PlayerBackend track contract, driven by fake
// backends (no native player): enumeration forwards, selection
// forwards + is remembered, and a ladder backend swap re-applies the
// remembered selection to the new backend. A fake that does NOT
// override the new methods keeps the contract defaults (empty lists
// / no-op selects), so old fakes keep compiling and working.

import 'dart:async';

import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/features/player/playback_session.dart';

/// Fake backend with track support + call recording.
class _TrackFakeBackend implements TrackCapableBackend {
  _TrackFakeBackend({
    required this.engine,
    this.audio = const [],
    this.subtitles = const [],
  });

  @override
  final PlayerEngine engine;

  final List<PlaybackTrack> audio;
  final List<PlaybackTrack> subtitles;

  final List<String> setAudioCalls = [];
  final List<String> setSubtitleCalls = [];
  final List<double> subtitleDelayCalls = [];
  final List<String> secondarySubtitleCalls = [];
  final List<String> subtitleAppearanceCalls = [];
  final _subtitleLines = StreamController<List<String>>.broadcast();
  bool disposed = false;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

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
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<List<PlaybackTrack>> audioTracks() async => audio;

  @override
  Future<List<PlaybackTrack>> subtitleTracks() async => subtitles;

  @override
  Future<void> setAudioTrack(String id) async {
    setAudioCalls.add(id);
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    setSubtitleCalls.add(id);
  }

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
  Future<void> dispose() async {
    disposed = true;
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _error.close();
    await _completed.close();
    await _subtitleLines.close();
  }
}

/// Minimal fake backend with NO track overrides at all: proves the
/// contract defaults (empty lists / no-op selects) keep old fakes
/// compiling and working — the existing dispose-test fake is the
/// same shape.
class _BareFakeBackend implements PlayerBackend {
  _BareFakeBackend({required this.engine});

  @override
  final PlayerEngine engine;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

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
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

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
  Future<void> dispose() async {
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _error.close();
    await _completed.close();
  }
}

void main() {
  test('PlaybackTrack.displayName prefers title, then language+codec',
      () {
    expect(
      const PlaybackTrack(
        id: '2',
        title: '国语',
        language: 'chi',
        codec: 'truehd',
      ).displayName,
      '国语 · chi · truehd',
    );
    expect(
      const PlaybackTrack(id: '3', language: 'eng').displayName,
      'eng',
    );
    expect(const PlaybackTrack(id: '4').displayName, '轨道 4');
  });

  test('session forwards enumeration + selection, remembers ids',
      () async {
    final backend = _TrackFakeBackend(
      engine: PlayerEngine.mediaKit,
      audio: const [
        PlaybackTrack(id: '1', title: 'English', language: 'eng'),
        PlaybackTrack(
            id: '2', title: '国语', language: 'chi', codec: 'truehd'),
      ],
      subtitles: const [
        PlaybackTrack(id: '3', title: '简体中文', language: 'chi'),
      ],
    );
    final session = PlaybackSession(
      backendFactory: (_) => backend,
    );
    addTearDown(session.dispose);

    final opened = await session.open(
      url: 'https://cdn.example.com/film.mkv',
      isLive: false,
    );
    expect(opened, isTrue);
    expect(session.activeEngine, PlayerEngine.mediaKit);

    expect(await session.audioTracks(), hasLength(2));
    expect((await session.audioTracks())[1].displayName,
        '国语 · chi · truehd');
    expect(await session.subtitleTracks(), hasLength(1));

    await session.setAudioTrack('2');
    await session.setSubtitleTrack('no');
    expect(backend.setAudioCalls, ['2']);
    expect(backend.setSubtitleCalls, ['no']);
    expect(session.currentAudioTrackId, '2');
    expect(session.currentSubtitleTrackId, 'no');
  });

  test('backend swap re-applies the remembered track selection',
      () async {
    final first = _TrackFakeBackend(engine: PlayerEngine.mediaKit);
    final second = _TrackFakeBackend(engine: PlayerEngine.fijk);
    var calls = 0;
    final session = PlaybackSession(
      backendFactory: (_) => ++calls == 1 ? first : second,
    );
    addTearDown(session.dispose);

    expect(
      await session.open(
        url: 'https://cdn.example.com/film.mkv',
        isLive: false,
      ),
      isTrue,
    );
    await session.setAudioTrack('2');
    await session.setSubtitleTrack('3');

    // A second open swaps in a fresh backend: the remembered
    // selection must be re-applied to it.
    expect(
      await session.open(
        url: 'https://cdn.example.com/film.mkv',
        isLive: false,
      ),
      isTrue,
    );
    expect(second.setAudioCalls, contains('2'));
    expect(second.setSubtitleCalls, contains('3'));
    expect(first.disposed, isTrue);
  });

  test('backend without track support yields empty lists, never throws',
      () async {
    final backend = _BareFakeBackend(engine: PlayerEngine.mediaKit);
    final session = PlaybackSession(
      backendFactory: (_) => backend,
    );
    addTearDown(session.dispose);

    expect(
      await session.open(
        url: 'https://cdn.example.com/film.mp4',
        isLive: false,
      ),
      isTrue,
    );
    // No TrackCapableBackend on this fake: the session answers empty
    // lists, and the selection is remembered but does nothing — the
    // same shape as every old `implements PlayerBackend` fake.
    expect(await session.audioTracks(), isEmpty);
    expect(await session.subtitleTracks(), isEmpty);
    // Selecting on a backend without support is a harmless no-op.
    await session.setAudioTrack('2');
    await session.setSubtitleTrack('no');
    expect(session.currentAudioTrackId, '2');
  });
}
