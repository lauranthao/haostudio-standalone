// Regression tests: exiting the video player must stop playback.
//
// The v1.0.5 bug: the film kept playing in the background after the
// player page was popped. Root cause — PlaybackSession.open() holds
// the candidate backend only in a local variable while open() +
// waitForFirstFrame() are in flight (up to 18 s + 18 s for VOD).
// If dispose() ran in that window, it disposed the then-current
// backend (null on first open) and returned; the in-flight attempt
// then succeeded and _swapBackend() installed a live, playing
// backend into a disposed session, and nothing ever stopped it.
//
// The fix: open() checks _disposed at attempt entry, after open(),
// before the swap, and after the ladder — a late candidate is
// disposed instead of installed.

import 'dart:async';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/player/playback_session.dart';

/// Fake backend whose open() / first-frame wait can be held open with
/// completers, so the test can dispose the session mid-flight.
class _GatedFakeBackend implements PlayerBackend {
  _GatedFakeBackend({this.openGate, this.firstFrameGate});

  /// If set, open() waits for this before returning.
  final Completer<void>? openGate;

  /// If set, waitForFirstFrame() waits for this before returning.
  final Completer<bool>? firstFrameGate;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  final enteredOpen = Completer<void>();
  final enteredFirstFrame = Completer<void>();
  bool _disposed = false;
  int pauses = 0;

  bool get isDisposed => _disposed;

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
  }) async {
    if (!enteredOpen.isCompleted) enteredOpen.complete();
    if (openGate != null) await openGate!.future;
  }

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async {
    if (!enteredFirstFrame.isCompleted) enteredFirstFrame.complete();
    if (firstFrameGate != null) return firstFrameGate!.future;
    return true;
  }

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async {
    pauses++;
    _playing.add(false);
  }

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
    if (_disposed) return;
    _disposed = true;
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _error.close();
    await _completed.close();
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-dispose-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    // Memory-backed box: file-backed Hive writes issued inside a
    // test's fake-async zone wedge hive_ce's serialized write lock
    // (see live_quality_line_test.dart).
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  group('PlaybackSession dispose during open (background-audio leak)', () {
    test('dispose during first-frame wait drops the late backend',
        () async {
      final firstFrameGate = Completer<bool>();
      final created = <_GatedFakeBackend>[];
      final session = PlaybackSession(
        backendFactory: (engine) {
          final backend =
              _GatedFakeBackend(firstFrameGate: firstFrameGate);
          created.add(backend);
          return backend;
        },
      );

      final opened = session.open(
        url: 'https://example.com/ep1.mp4',
        isLive: false,
      );
      // Let open() reach the first-frame wait before disposing.
      await created.single.enteredFirstFrame.future;
      await session.dispose();

      // The stream turns out healthy, but the page is already gone:
      // open() must fail and the backend must be released, never
      // installed as the live backend.
      firstFrameGate.complete(true);
      expect(await opened, isFalse);
      expect(created.single.isDisposed, isTrue);
      expect(session.activeEngine, isNull);
    });

    test('dispose during open() drops the candidate', () async {
      final openGate = Completer<void>();
      final created = <_GatedFakeBackend>[];
      final session = PlaybackSession(
        backendFactory: (engine) {
          final backend = _GatedFakeBackend(openGate: openGate);
          created.add(backend);
          return backend;
        },
      );

      final opened = session.open(
        url: 'https://example.com/ep1.mp4',
        isLive: false,
      );
      await created.single.enteredOpen.future;
      await session.dispose();

      openGate.complete();
      expect(await opened, isFalse);
      for (final backend in created) {
        expect(backend.isDisposed, isTrue);
      }
      expect(session.activeEngine, isNull);
    });

    test('dispose after established playback releases the backend',
        () async {
      final created = <_GatedFakeBackend>[];
      final session = PlaybackSession(
        backendFactory: (engine) {
          final backend = _GatedFakeBackend();
          created.add(backend);
          return backend;
        },
      );

      expect(
        await session.open(
          url: 'https://example.com/ep1.mp4',
          isLive: false,
        ),
        isTrue,
      );
      expect(session.activeEngine, isNotNull);

      await session.dispose();
      expect(created.single.isDisposed, isTrue);
      expect(session.activeEngine, isNull);
    });

    test('open after dispose starts nothing', () async {
      final created = <_GatedFakeBackend>[];
      final session = PlaybackSession(
        backendFactory: (engine) {
          final backend = _GatedFakeBackend();
          created.add(backend);
          return backend;
        },
      );

      await session.dispose();
      expect(
        await session.open(
          url: 'https://example.com/ep1.mp4',
          isLive: false,
        ),
        isFalse,
      );
      expect(created, isEmpty);
    });
  });
}
