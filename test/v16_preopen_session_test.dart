// 1.1.6 换源链路 — PlaybackSession preopen / seamless swap /
// switchEngine position preservation (fake backends, no network).
//
// Pins:
// - preopen never disturbs the playing backend (no status change,
//   no URL change, old backend alive);
// - swapToPreopened seeks to the resume position and re-applies
//   the rate on the new backend, then disposes the old one;
// - a failed preopen leaves the old line playing (fail back to
//   the old line — never a failure card from the session);
// - switchEngine keeps the VOD position instead of restarting
//   from 0; a newer open() retires a staged preopen.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/player/playback_session.dart';

class _FakeBackendConfig {
  bool openSucceeds = true;
  bool firstFrameSucceeds = true;
}

class _FakeBackend implements PlayerBackend {
  _FakeBackend({
    required this.engine,
    required this.log,
    required this.config,
  }) {
    log.add(this);
  }

  @override
  final PlayerEngine engine;
  final List<_FakeBackend> log;
  final _FakeBackendConfig config;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  String? openedUrl;
  final List<Duration> seeks = [];
  final List<double> rates = [];
  bool disposed = false;

  void emitPosition(Duration position) => _position.add(position);

  @override
  Widget buildVideoWidget() => const SizedBox.shrink();

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    openedUrl = url;
    if (!config.openSucceeds) throw StateError('fake open failed');
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      config.firstFrameSucceeds;

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async => rates.add(rate);

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

  @override
  Stream<Duration> get positionStream => _position.stream;

  @override
  Stream<Duration> get durationStream => _duration.stream;

  @override
  Future<void> seekTo(Duration position) async => seeks.add(position);

  @override
  Stream<bool> get playingStream => _playing.stream;

  @override
  Stream<String> get errorStream => _error.stream;

  @override
  Stream<void> get completedStream => _completed.stream;

  @override
  Future<void> dispose() async {
    if (disposed) return;
    disposed = true;
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-v16-preopen-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  late List<_FakeBackend> created;
  late Map<PlayerEngine, _FakeBackendConfig> configs;

  setUp(() {
    created = [];
    configs = {
      for (final e in PlayerEngine.values) e: _FakeBackendConfig(),
    };
  });

  PlaybackSession session() => PlaybackSession(
        backendFactory: (engine) => _FakeBackend(
          engine: engine,
          log: created,
          config: configs[engine]!,
        ),
      );

  const line1 = 'https://example.com/ep1-line1.mp4';
  const line2 = 'https://example.com/ep1-line2.mp4';

  Future<PlaybackSession> playingSession() async {
    final s = session();
    final ok = await s.open(url: line1, isLive: false);
    expect(ok, isTrue);
    expect(s.status, PlaybackStatus.playing);
    expect(s.currentUrl, line1);
    return s;
  }

  group('preopen', () {
    test('does not disturb the playing backend', () async {
      final s = await playingSession();
      final playing = created.single;
      final ok = await s.preopen(url: line2, isLive: false);
      expect(ok, isTrue);
      expect(s.status, PlaybackStatus.playing);
      expect(s.currentUrl, line1);
      expect(playing.disposed, isFalse);
      expect(playing.openedUrl, line1);
      await s.dispose();
    });

    test('failed preopen leaves the old line playing', () async {
      final s = await playingSession();
      final playing = created.single;
      for (final c in configs.values) {
        c.firstFrameSucceeds = false;
      }
      final ok = await s.preopen(url: line2, isLive: false);
      expect(ok, isFalse);
      expect(s.status, PlaybackStatus.playing);
      expect(s.currentUrl, line1);
      expect(playing.disposed, isFalse);
      // Every failed candidate was disposed; the playing backend
      // was never among them.
      expect(created.where((b) => !b.disposed), [playing]);
      await s.dispose();
    });

    test('a newer open retires a staged preopen', () async {
      final s = await playingSession();
      expect(await s.preopen(url: line2, isLive: false), isTrue);
      final staged = created.last;
      expect(staged.openedUrl, line2);
      expect(await s.open(url: line2, isLive: false), isTrue);
      // The staged backend was disposed by the fresh open; the open
      // itself built a new backend for the same URL.
      expect(staged.disposed, isTrue);
      expect(s.currentUrl, line2);
      await s.dispose();
    });
  });

  group('swapToPreopened', () {
    test('seeks to resume, keeps rate, disposes old backend', () async {
      final s = await playingSession();
      final old = created.single;
      await s.setRate(2.0);
      expect(await s.preopen(url: line2, isLive: false), isTrue);
      final staged = created.last;
      final ok = await s.swapToPreopened(
        url: line2,
        resumePosition: const Duration(seconds: 120),
      );
      expect(ok, isTrue);
      expect(staged.seeks, [const Duration(seconds: 120)]);
      expect(staged.rates, [2.0]);
      expect(old.disposed, isTrue);
      expect(s.currentUrl, line2);
      expect(s.status, PlaybackStatus.playing);
      await s.dispose();
    });

    test('nothing staged => false, playing backend untouched', () async {
      final s = await playingSession();
      final ok = await s.swapToPreopened(
        url: line2,
        resumePosition: const Duration(seconds: 10),
      );
      expect(ok, isFalse);
      expect(s.currentUrl, line1);
      expect(s.status, PlaybackStatus.playing);
      await s.dispose();
    });

    test('staged for another URL => false', () async {
      final s = await playingSession();
      expect(await s.preopen(url: line2, isLive: false), isTrue);
      final ok = await s.swapToPreopened(
        url: 'https://example.com/other.mp4',
        resumePosition: Duration.zero,
      );
      expect(ok, isFalse);
      expect(s.currentUrl, line1);
      await s.dispose();
    });
  });

  group('switchEngine', () {
    test('VOD keeps its position instead of restarting from 0',
        () async {
      final s = await playingSession();
      final old = created.single;
      // The playing backend reports position 42 s.
      old.emitPosition(const Duration(seconds: 42));
      await Future<void>.delayed(const Duration(milliseconds: 100));
      await s.switchEngine(PlayerEngine.fijk);
      expect(s.status, PlaybackStatus.playing);
      expect(s.currentUrl, line1);
      // The NEW backend (fijk) was sought back to 42 s.
      final fresh = created.last;
      expect(fresh.engine, PlayerEngine.fijk);
      expect(fresh.seeks, contains(const Duration(seconds: 42)));
      await s.dispose();
    });
  });
}
