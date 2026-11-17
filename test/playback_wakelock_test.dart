// Regression tests: the screen must stay on while live / VOD is playing.
//
// chen 2026-11-17: "看直播的时候系统会自动熄屏" + "估计影视也一样".
// Root cause: no code in lib/ ever called WakelockPlus. The only
// wakelock in the stack came from the player libraries, and each had a
// hole — media_kit_video's Video widget drives its wakelock from a
// playing subscription on its controller, which goes stale across
// backend swaps (didUpdateWidget only refreshes view params); IJK
// (FijkView) has none at all; BetterPlayer only holds it in
// fullscreen. So any engine reached by user choice or ladder fallback
// left the screen free to auto-lock. The fix: PlaybackSession owns
// the wakelock for every engine (see playback_session.dart), and the
// Video widget is told wakelock: false.
//
// The fake below intercepts WakelockPlus calls by swapping the
// @visibleForTesting platform-instance variable — no real platform
// channel is touched.

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
import 'package:wakelock_plus/wakelock_plus.dart';
import 'package:wakelock_plus_platform_interface/wakelock_plus_platform_interface.dart';

/// Records every wakelock toggle instead of touching the platform.
class _FakeWakelock extends WakelockPlusPlatformInterface {
  final calls = <bool>[];

  @override
  Future<void> toggle({required bool enable}) async {
    calls.add(enable);
  }

  @override
  Future<bool> get enabled async => calls.isNotEmpty && calls.last;
}

/// Fake backend: opens instantly, first frame succeeds unless told not
/// to, records play/pause.
class _FakeBackend implements PlayerBackend {
  _FakeBackend({this.firstFrameOk = true});

  final bool firstFrameOk;
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  bool _disposed = false;
  int plays = 0;
  int pauses = 0;

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
      firstFrameOk;

  @override
  Future<void> play() async {
    plays++;
    _playing.add(true);
  }

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
  late _FakeWakelock fakeWakelock;
  late WakelockPlusPlatformInterface savedWakelock;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-wakelock-test-');
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
    savedWakelock = wakelockPlusPlatformInstance;
    fakeWakelock = _FakeWakelock();
    wakelockPlusPlatformInstance = fakeWakelock;
  });

  tearDownAll(() async {
    wakelockPlusPlatformInstance = savedWakelock;
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  setUp(() {
    fakeWakelock.calls.clear();
  });

  PlaybackSession makeSession({bool firstFrameOk = true}) {
    return PlaybackSession(
      backendFactory: (_) => _FakeBackend(firstFrameOk: firstFrameOk),
    );
  }

  group('PlaybackSession wakelock', () {
    test('playing holds the wakelock, pause releases it, play re-holds',
        () async {
      final session = makeSession();
      try {
        expect(
          await session.open(
            url: 'https://example.com/room.flv',
            isLive: true,
          ),
          isTrue,
        );
        expect(fakeWakelock.calls, [true]);

        await session.pause();
        expect(fakeWakelock.calls, [true, false]);

        await session.play();
        expect(fakeWakelock.calls, [true, false, true]);
      } finally {
        await session.dispose();
      }
    });

    test('redundant play() does not spam the platform channel', () async {
      final session = makeSession();
      try {
        expect(
          await session.open(
            url: 'https://example.com/room.flv',
            isLive: true,
          ),
          isTrue,
        );
        await session.play();
        await session.play();
        expect(fakeWakelock.calls, [true]);
      } finally {
        await session.dispose();
      }
    });

    test('room switch never drops the wakelock', () async {
      final session = makeSession();
      try {
        expect(
          await session.open(
            url: 'https://example.com/room-a.flv',
            isLive: true,
          ),
          isTrue,
        );
        expect(
          await session.open(
            url: 'https://example.com/room-b.flv',
            isLive: true,
          ),
          isTrue,
        );
        // Opening the second room must not release in between.
        expect(fakeWakelock.calls, [true]);
      } finally {
        await session.dispose();
      }
    });

    test('failed open enables during opening, releases on error', () async {
      final session = makeSession(firstFrameOk: false);
      try {
        expect(
          await session.open(
            url: 'https://example.com/dead.flv',
            isLive: true,
          ),
          isFalse,
        );
        expect(fakeWakelock.calls, [true, false]);
      } finally {
        await session.dispose();
      }
    });

    test('audio-only mode releases, clearing it re-holds while playing',
        () async {
      final session = makeSession();
      try {
        expect(
          await session.open(
            url: 'https://example.com/room.flv',
            isLive: true,
          ),
          isTrue,
        );
        await session.setAudioOnly(true);
        expect(fakeWakelock.calls, [true, false]);
        await session.setAudioOnly(false);
        expect(fakeWakelock.calls, [true, false, true]);
      } finally {
        await session.dispose();
      }
    });

    test('background releases, foreground re-holds while still playing',
        () async {
      final session = makeSession();
      try {
        expect(
          await session.open(
            url: 'https://example.com/ep1.mp4',
            isLive: false,
          ),
          isTrue,
        );
        session.setForeground(false);
        expect(fakeWakelock.calls, [true, false]);
        session.setForeground(true);
        expect(fakeWakelock.calls, [true, false, true]);
      } finally {
        await session.dispose();
      }
    });

    test('dispose releases and nothing re-enables after', () async {
      final session = makeSession();
      expect(
        await session.open(
          url: 'https://example.com/ep1.mp4',
          isLive: false,
        ),
        isTrue,
      );
      await session.dispose();
      expect(fakeWakelock.calls, [true, false]);
      expect(
        await session.open(
          url: 'https://example.com/ep2.mp4',
          isLive: false,
        ),
        isFalse,
      );
      expect(fakeWakelock.calls, [true, false]);
    });
  });
}
