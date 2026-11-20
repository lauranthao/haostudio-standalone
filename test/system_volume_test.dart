// System volume tests — Dart side of ios/Runner/SystemVolumePlugin.swift.
//
// Unit: SystemVolume sends the right method + clamped value to the
// native side, falls back to the last known level when the native
// side cannot answer, and forwards native volumeChanged pushes.
// Widget (ONE room pump in this file — a second pump hangs on this
// VM, same as live_room_player_audit_test.dart): a right-half
// vertical drag in the live room calls the SYSTEM channel with the
// dragged value, never the player session, and the HUD shows the
// system value; a native volumeChanged push (hardware key) updates
// the HUD too.

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

  group('SystemVolume unit', () {
    late List<MethodCall> outgoing;
    late double nativeVolume;
    late bool throwOnGet;
    late bool throwOnSet;
    late SystemVolume service;

    setUp(() {
      outgoing = <MethodCall>[];
      nativeVolume = 0.6;
      throwOnGet = false;
      throwOnSet = false;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        outgoing.add(call);
        if (call.method == 'getVolume') {
          if (throwOnGet) throw PlatformException(code: 'no_native');
          return nativeVolume;
        }
        if (call.method == 'setVolume') {
          if (throwOnSet) throw PlatformException(code: 'no_native');
          nativeVolume =
              (call.arguments as Map)['volume'] as double;
          return null;
        }
        return null;
      });
      service = SystemVolume();
    });

    tearDown(() {
      service.dispose();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, null);
    });

    Future<void> pushVolumeChanged(Object? args) async {
      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        systemVolumeChannelName,
        codec.encodeMethodCall(MethodCall('volumeChanged', args)),
        (_) {},
      );
    }

    test('getVolume returns the native level', () async {
      expect(await service.getVolume(), 0.6);
      expect(outgoing.single.method, 'getVolume');
    });

    test('getVolume clamps an out-of-range native level', () async {
      nativeVolume = 1.5;
      expect(await service.getVolume(), 1.0);
      nativeVolume = -0.2;
      expect(await service.getVolume(), 0.0);
    });

    test('getVolume falls back to the last known level', () async {
      await service.setVolume(0.4);
      throwOnGet = true;
      expect(await service.getVolume(), 0.4);
    });

    test('setVolume sends the clamped value', () async {
      await service.setVolume(0.75);
      expect(nativeVolume, 0.75);
      expect(
        (outgoing.last.arguments as Map)['volume'],
        0.75,
      );
      await service.setVolume(1.5);
      expect(nativeVolume, 1.0);
      await service.setVolume(-0.1);
      expect(nativeVolume, 0.0);
    });

    test('setVolume failure does not throw', () async {
      throwOnSet = true;
      await service.setVolume(0.5);
    });

    test('volumeChanged push reaches the stream + last known', () async {
      final seen = <double>[];
      final sub = service.volumeChanges.listen(seen.add);
      await pushVolumeChanged(<String, Object>{'volume': 0.3});
      expect(seen, <double>[0.3]);
      // The push updates the last known level: with the native side
      // unreachable, getVolume falls back to it.
      throwOnGet = true;
      expect(await service.getVolume(), 0.3);
      await sub.cancel();
    });

    test('rapid setVolume calls coalesce: only latest pending is sent',
        () async {
      // Gate the FIRST native call so the next two arrive while it is
      // still in flight — the middle value must never reach the
      // channel, and the last value must still be flushed.
      final gate = Completer<void>();
      var setCount = 0;
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(channel, (MethodCall call) async {
        outgoing.add(call);
        if (call.method == 'getVolume') return nativeVolume;
        if (call.method == 'setVolume') {
          setCount++;
          if (setCount == 1) await gate.future;
          nativeVolume = (call.arguments as Map)['volume'] as double;
          return null;
        }
        return null;
      });
      final first = service.setVolume(0.5);
      unawaited(service.setVolume(0.6));
      unawaited(service.setVolume(0.7));
      gate.complete();
      await first;
      final sets = outgoing
          .where((c) => c.method == 'setVolume')
          .map((c) => (c.arguments as Map)['volume'] as double)
          .toList();
      expect(sets, <double>[0.5, 0.7]);
      expect(nativeVolume, 0.7);
      // The flushed last value is the last known level.
      throwOnGet = true;
      expect(await service.getVolume(), 0.7);
    });

    test('own-set echo is suppressed, external change passes', () async {
      final seen = <double>[];
      final sub = service.volumeChanges.listen(seen.add);
      await service.setVolume(0.44);
      // iOS quantizes the system volume to 1/16 steps: the native
      // KVO echo of our own 0.44 set arrives as 0.4375. It must not
      // reach the stream (it would yank the drag HUD back a step).
      await pushVolumeChanged(<String, Object>{'volume': 0.4375});
      expect(seen, isEmpty);
      // A genuine hardware-key change to a different level passes.
      await pushVolumeChanged(<String, Object>{'volume': 0.3});
      expect(seen, <double>[0.3]);
      await sub.cancel();
    });

    test('echo of a superseded set is suppressed', () async {
      final seen = <double>[];
      final sub = service.volumeChanges.listen(seen.add);
      await service.setVolume(0.5);
      await service.setVolume(0.6);
      // The native side echoes the first (superseded) set late: it
      // matches a recent own set, so it is dropped, not forwarded.
      await pushVolumeChanged(<String, Object>{'volume': 0.5});
      expect(seen, isEmpty);
      // The latest set's own echo is dropped too.
      await pushVolumeChanged(<String, Object>{'volume': 0.6});
      expect(seen, isEmpty);
      // A different level (hardware key) still passes.
      await pushVolumeChanged(<String, Object>{'volume': 0.3});
      expect(seen, <double>[0.3]);
      await sub.cancel();
    });

    test('malformed volumeChanged is ignored', () async {
      final seen = <double>[];
      final sub = service.volumeChanges.listen(seen.add);
      await pushVolumeChanged(<String, Object>{'volume': 'loud'});
      await pushVolumeChanged('not-a-map');
      await pushVolumeChanged(null);
      expect(seen, isEmpty);
      await sub.cancel();
    });
  });

  group('live room drag volume', () {
    late Directory hiveDir;
    late List<MethodCall> outgoing;
    late double nativeVolume;
    late _RecordingBackend backend;

    setUpAll(() async {
      hiveDir = await Directory.systemTemp.createTemp('hao-sysvol-');
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
          nativeVolume = (call.arguments as Map)['volume'] as double;
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

    testWidgets('right-half drag sets system volume, HUD shows it',
        (tester) async {
      await pumpRoom(tester);

      // Right half of the 16:9 surface (800 wide, 450 tall under the
      // AppBar): upward 100 px. The drag recognizer eats the
      // dead-zone travel (~20 px), so the exact landing depends on
      // the harness — assert direction + range instead of an exact
      // value: the drag must raise the system level from 0.6, and
      // the HUD must show exactly the value sent to the system
      // channel. P1-U2: the live room now shares the VOD
      // sensitivity (300 px = the full 0-1 range), so 100 px up
      // lands near 0.6 + 80/300 ≈ 0.87 — not the old live-room
      // ~0.71. The 0.95 cap allows the dead zone to vary 0-20 px
      // (0.87-0.93) with margin.
      await tester.dragFrom(
        const Offset(600, 200),
        const Offset(0, -100),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));

      final systemSets = outgoing
          .where((c) => c.method == 'setVolume')
          .toList();
      expect(systemSets, isNotEmpty);
      final lastSet =
          (systemSets.last.arguments as Map)['volume'] as double;
      expect(lastSet, greaterThan(0.6));
      expect(lastSet, lessThanOrEqualTo(0.95));
      // The player session is never touched by the drag.
      expect(backend.setVolumes, isEmpty);
      // The HUD shows the system value.
      expect(find.text('${(lastSet * 100).round()}%'), findsOneWidget);

      // Hardware key: native pushes volumeChanged 0.3 — the HUD
      // follows without any drag.
      await TestDefaultBinaryMessengerBinding
          .instance.defaultBinaryMessenger
          .handlePlatformMessage(
        systemVolumeChannelName,
        codec.encodeMethodCall(
          const MethodCall('volumeChanged', <String, Object>{
            'volume': 0.3,
          }),
        ),
        (_) {},
      );
      await tester.pump();
      expect(find.text('30%'), findsOneWidget);
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
