// Live volume drag smoothness — Dart side of
// ios/Runner/SystemVolumePlugin.swift.
//
// ONE room pump in this file: a second pump hangs on this VM (same
// rule as test/system_volume_test.dart, which owns the other live
// volume test — one widget test per file for the live room).
//
// The mock echoes every set back quantized to 1/16 (real iOS KVO
// behaviour): the HUD must keep showing the dragged value, never the
// lagging echo; and a later drag, after the HUD hid, must not re-read
// the channel inside the update handler.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/native/system_volume.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/live_follow_store.dart';
import 'package:standalone/domains/live/live_history_store.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/features/settings/source_stores.dart';
import 'package:standalone/shared/platforms/live_site.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(systemVolumeChannelName);
  const codec = StandardMethodCodec();

  group('live room drag volume smoothness', () {
    late Directory hiveDir;
    late List<MethodCall> outgoing;
    late double nativeVolume;
    late _RecordingBackend backend;

    setUpAll(() async {
      hiveDir = await Directory.systemTemp.createTemp('hao-live-vol-');
      const pathChannel =
          MethodChannel('plugins.flutter.io/path_provider');
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(pathChannel, (call) async {
        if (call.method == 'getApplicationDocumentsDirectory') {
          return hiveDir.path;
        }
        return null;
      });
      await HiveStore.init();
    });

    tearDownAll(() async {
      unawaited(HiveStore.box.close());
      await hiveDir.delete(recursive: true);
    });

    tearDown(() {
      Get.reset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    const roomA = LiveRoom(
      roomId: '660000',
      platform: 'huya',
      title: 'room A',
      nick: 'anchor A',
      liveStatus: true,
      watching: 100,
    );

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<void> pumpRoom(WidgetTester tester) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      outgoing = <MethodCall>[];
      nativeVolume = 0.6;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        outgoing.add(call);
        if (call.method == 'getVolume') return nativeVolume;
        if (call.method == 'setVolume') {
          final v = (call.arguments as Map)['volume'] as double;
          nativeVolume = v;
          // Real iOS: every MPVolumeView set fires AVAudioSession
          // outputVolume KVO, quantized to 1/16 steps.
          final q = (v * 16).round() / 16.0;
          unawaited(Future(() async {
            await TestDefaultBinaryMessengerBinding
                .instance.defaultBinaryMessenger
                .handlePlatformMessage(
              systemVolumeChannelName,
              codec.encodeMethodCall(
                MethodCall('volumeChanged', <String, Object>{'volume': q}),
              ),
              (_) {},
            );
          }));
          return null;
        }
        return null;
      });
      await tester.runAsync(() async {
        await DanmakuSettings.setEnabled('huya', true);
        await LiveHistoryStore.clear();
        await LiveFollowStore.clear();
      });
      await settle(tester);
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveRoomPage(
            room: roomA,
            playlist: const [roomA],
            site: _FakeSite(),
            backendFactory: (_) => backend = _RecordingBackend(),
          ),
        ),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      expect(find.text('room A'), findsOneWidget);
    }

    testWidgets(
        'quantized KVO echo does not fight the HUD; later drag does not '
        're-read the channel', (tester) async {
      await pumpRoom(tester);
      final getCountBefore =
          outgoing.where((c) => c.method == 'getVolume').length;

      // Right-half upward drag; the mock echoes every set back
      // quantized to 1/16 (real iOS behaviour). The HUD must keep
      // showing the dragged value, never the lagging echo.
      await tester.dragFrom(
        const Offset(600, 200),
        const Offset(0, -100),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 100));
      });
      await tester.pump();

      var systemSets = outgoing
          .where((c) => c.method == 'setVolume')
          .toList();
      expect(systemSets, isNotEmpty);
      var lastSet =
          (systemSets.last.arguments as Map)['volume'] as double;
      expect(lastSet, greaterThan(0.6));
      expect(lastSet, lessThanOrEqualTo(0.72));
      expect(backend.setVolumes, isEmpty);
      expect(find.text('${(lastSet * 100).round()}%'), findsOneWidget);
      final echoValue = (lastSet * 16).round() / 16.0;
      if ((echoValue * 100).round() != (lastSet * 100).round()) {
        expect(find.text('${(echoValue * 100).round()}%'), findsNothing);
      }

      // Let the HUD hide (1 s timer), then drag again: the old code
      // re-read getVolume inside the update handler whenever the HUD
      // was hidden, and the re-read overwrote the drag value.
      await tester.pump(const Duration(seconds: 2));
      await tester.dragFrom(
        const Offset(600, 200),
        const Offset(0, -100),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      expect(
        outgoing.where((c) => c.method == 'getVolume').length,
        getCountBefore,
      );
      // The second drag still raises the volume (no jump back to the
      // entry-time seed).
      systemSets = outgoing
          .where((c) => c.method == 'setVolume')
          .toList();
      expect(systemSets, isNotEmpty);
      lastSet = (systemSets.last.arguments as Map)['volume'] as double;
      expect(lastSet, greaterThan(0.6));
      expect(backend.setVolumes, isEmpty);

      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

class _FakeSite extends LiveSite {
  final danmaku = _FakeDanmaku();

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

/// Fake native backend that records every setVolume call: the drag
/// must never reach it.
class _RecordingBackend implements PlayerBackend {
  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  final setVolumes = <double>[];

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  @override
  Widget buildVideoWidget() =>
      const SizedBox(key: ValueKey('fake-video'));

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
  Future<void> setVolume(double volume) async {
    setVolumes.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> setAudioOnly(bool audioOnly) async {}

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
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}
