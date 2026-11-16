// Live background playback: the room must NOT pause when the app
// backgrounds.
//
// Root cause (chen's v1.0.6 phone report): nothing in Dart pauses
// the session — mpv itself pauses when its video output is suspended
// in background (vo=libmpv cannot present frames). Music keeps
// playing because it has no video track. The fix is Pure Live's
// audio-only background mode: on background the live room drops the
// video track (setVideoTrack(VideoTrack.no())), the audio keeps
// flowing; on foreground the track is restored and playback resumes
// if mpv paused natively anyway.
//
// Session tests (fake backend, no widgets): setAudioOnly delegates,
// survives a ladder swap, and applies to a backend that swaps in
// after the flag was set.
// Widget tests (fake site + fake backend, no network): the room
// switches to audio-only on background while playing and restores
// video + resumes on foreground; a user-paused room is left alone.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/shared/platforms/live_site.dart';

/// Fake backend that records audio-only switches and play/pause calls.
class _RecordingFakeBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  final audioOnlyCalls = <bool>[];
  int playCount = 0;
  int pauseCount = 0;
  bool _disposed = false;

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
  }) async {}

  @override
  Future<bool> waitForFirstFrame({
    Duration timeout = const Duration(seconds: 15),
  }) async =>
      true;

  @override
  Future<void> play() async {
    playCount++;
    _playing.add(true);
  }

  @override
  Future<void> pause() async {
    pauseCount++;
    _playing.add(false);
  }

  @override
  Future<void> setVolume(double volume) async {}

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {
    audioOnlyCalls.add(audioOnly);
  }

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
    // Do NOT await the broadcast close() calls: inside a widget
    // test's fake-async zone a broadcast StreamController.close()
    // future never completes, so awaiting it stalls the session
    // dispose chain (see playback_session_dispose_test.dart).
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
    hiveDir = await Directory.systemTemp.createTemp('hao-bg-audio-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
  });

  group('PlaybackSession.setAudioOnly', () {
    test('delegates to the current backend', () async {
      final created = <_RecordingFakeBackend>[];
      final session = PlaybackSession(
        backendFactory: (engine) {
          final backend = _RecordingFakeBackend();
          created.add(backend);
          return backend;
        },
      );
      addTearDown(session.dispose);

      expect(
        await session.open(
          url: 'https://example.com/live.m3u8',
          isLive: true,
        ),
        isTrue,
      );
      expect(session.isAudioOnly, isFalse);

      await session.setAudioOnly(true);
      expect(session.isAudioOnly, isTrue);
      expect(created.single.audioOnlyCalls, [true]);

      await session.setAudioOnly(false);
      expect(session.isAudioOnly, isFalse);
      expect(created.single.audioOnlyCalls, [true, false]);
    });

    test('set before open is applied when the backend swaps in',
        () async {
      final created = <_RecordingFakeBackend>[];
      final session = PlaybackSession(
        backendFactory: (engine) {
          final backend = _RecordingFakeBackend();
          created.add(backend);
          return backend;
        },
      );
      addTearDown(session.dispose);

      // No backend yet: must not throw, flag is remembered.
      await session.setAudioOnly(true);
      expect(session.isAudioOnly, isTrue);

      expect(
        await session.open(
          url: 'https://example.com/live.m3u8',
          isLive: true,
        ),
        isTrue,
      );
      expect(created.single.audioOnlyCalls, [true]);
    });

    test('audio-only survives a ladder swap', () async {
      final created = <_RecordingFakeBackend>[];
      final session = PlaybackSession(
        backendFactory: (engine) {
          final backend = _RecordingFakeBackend();
          created.add(backend);
          return backend;
        },
      );
      addTearDown(session.dispose);

      expect(
        await session.open(
          url: 'https://example.com/live.m3u8',
          isLive: true,
        ),
        isTrue,
      );
      await session.setAudioOnly(true);
      expect(created.single.audioOnlyCalls, [true]);

      // Engine switch rebuilds the backend (ladder re-open).
      await session.switchEngine(PlayerEngine.fijk);
      expect(created.length, 2);
      expect(created.first.isDisposed, isTrue);
      // The new backend must be audio-only from the moment it is
      // installed, or its suspended vo pauses the stream again.
      expect(created.last.audioOnlyCalls, [true]);
      expect(session.isAudioOnly, isTrue);
      expect(session.status, PlaybackStatus.playing);
    });
  });

  group('LiveRoomPage background lifecycle', () {
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<List<_RecordingFakeBackend>> pumpRoom(
      WidgetTester tester,
    ) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final created = <_RecordingFakeBackend>[];
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveRoomPage(
            room: const LiveRoom(
              roomId: '660000',
              platform: 'huya',
              title: 'test room',
              nick: 'tester',
              liveStatus: true,
              watching: 1234,
            ),
            site: _FakeSite(),
            backendFactory: (_) {
              final backend = _RecordingFakeBackend();
              created.add(backend);
              return backend;
            },
          ),
        ),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      return created;
    }

    Future<void> disposeRoom(WidgetTester tester) async {
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    Future<void> background(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.paused,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    Future<void> foreground(WidgetTester tester) async {
      tester.binding.handleAppLifecycleStateChanged(
        AppLifecycleState.resumed,
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
    }

    testWidgets(
        'background while playing goes audio-only; foreground restores video + resumes',
        (tester) async {
      final created = await pumpRoom(tester);
      addTearDown(() => disposeRoom(tester));
      expect(created, hasLength(1));
      final backend = created.single;
      expect(backend.audioOnlyCalls, isEmpty);

      await background(tester);
      expect(backend.audioOnlyCalls, [true]);

      await foreground(tester);
      expect(backend.audioOnlyCalls, [true, false]);
      // play() on foreground is the resume for an mpv that paused
      // natively anyway; a no-op when already playing.
      expect(backend.playCount, 1);
    });

    testWidgets(
        'background while user-paused leaves the room alone',
        (tester) async {
      final created = await pumpRoom(tester);
      addTearDown(() => disposeRoom(tester));
      final backend = created.single;

      // User pauses from the bottom bar.
      await tester.tap(find.byTooltip('暂停'));
      await tester.pump();
      expect(backend.pauseCount, 1);

      await background(tester);
      expect(backend.audioOnlyCalls, isEmpty);

      await foreground(tester);
      expect(backend.audioOnlyCalls, isEmpty);
      expect(backend.playCount, 0);
    });
  });
}

class _FakeSite extends LiveSite {
  final _FakeDanmaku danmaku = _FakeDanmaku();

  @override
  String get id => 'huya';

  @override
  String get name => 'Huya';

  @override
  LiveDanmaku getDanmaku() => danmaku;

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async => room;

  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async =>
      const [LivePlayQuality(quality: '原画', id: '10000')];

  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final issued = DateTime.now();
    return LivePlayUrlResolution(
      urls: const ['https://example.com/live.m3u8'],
      issuedAt: issued,
      refreshAt: issued.add(const Duration(seconds: 100)),
      invalidAt: issued.add(const Duration(seconds: 125)),
      streamFacts: const [LiveStreamFacts(format: 'hls')],
    );
  }
}

/// Fake danmaku transport: records start/stop, emits nothing.
class _FakeDanmaku extends LiveDanmaku {
  int startCount = 0;
  int stopCount = 0;

  @override
  bool get isConnected => startCount > stopCount;

  @override
  Future<void> heartbeat() async {}

  @override
  Future<void> start(Map<String, dynamic> args) async {
    startCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}
