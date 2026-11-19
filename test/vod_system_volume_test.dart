// VOD system volume — Dart side of ios/Runner/SystemVolumePlugin.swift.
//
// Same contract as the live room (test/system_volume_test.dart): a
// right-half vertical drag in the VOD player calls the SYSTEM channel
// with the dragged value, never the player session, and the HUD shows
// the system value; a native volumeChanged push (hardware key) updates
// the HUD too. The source-switch volume re-apply is gone: after a
// backend swap the player gain stays at full and the system level is
// the only volume.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/native/system_volume.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';

VideoDetail _detail() => VideoDetail(
      source: 12,
      vodId: '93344',
      meta: VideoMeta(name: '流浪地球2'),
      lines: [
        PlayLine(
          name: '线路1',
          episodes: const [
            PlayEpisode(name: '第1集', url: 'https://example.com/ep1.mp4'),
          ],
        ),
      ],
    );

/// Fake native backend that records every setVolume call: the drag
/// must never reach it.
class _RecordingBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  final setVolumes = <double>[];
  bool _disposed = false;

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  @override
  Widget buildVideoWidget() => const SizedBox(key: ValueKey('fake-video'));

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
  TestWidgetsFlutterBinding.ensureInitialized();

  const channel = MethodChannel(systemVolumeChannelName);
  const codec = StandardMethodCodec();

  late Directory hiveDir;
  late List<MethodCall> outgoing;
  late double nativeVolume;
  late _RecordingBackend backend;

  setUpAll(() async {
    hiveDir = await Directory.systemTemp.createTemp('hao-vod-sysvol-');
    const pathChannel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(pathChannel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
  });

  // NOTE: do NOT await the Hive box close here. Pending Hive deletes
  // from tearDown never resolve in the widget-test fake zone, so
  // awaiting close() hangs tearDownAll forever. Fire-and-forget.
  tearDownAll(() async {
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
    unawaited(HiveStore.delete(HiveKeys.videoHistory));
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
  });

  Future<void> pumpPlayer(WidgetTester tester) async {
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
    backend = _RecordingBackend();
    final session = PlaybackSession(backendFactory: (_) => backend);
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: NativeVideoPlayerPage(detail: _detail(), session: session),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  testWidgets('right-half drag sets system volume, HUD shows it',
      (tester) async {
    await pumpPlayer(tester);
    final volumesBeforeDrag = backend.setVolumes.length;

    // Right half, upward 100 px: VOD maps dy/300 onto the level, so
    // the drag must raise the system level from 0.6 and the HUD must
    // show exactly the value sent to the system channel.
    await tester.dragFrom(
      const Offset(600, 200),
      const Offset(0, -100),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));

    final systemSets =
        outgoing.where((c) => c.method == 'setVolume').toList();
    expect(systemSets, isNotEmpty);
    final lastSet = (systemSets.last.arguments as Map)['volume'] as double;
    expect(lastSet, greaterThan(0.6));
    expect(lastSet, lessThanOrEqualTo(1.0));
    // The player session is never touched by the drag.
    expect(backend.setVolumes.length, volumesBeforeDrag);
    // The HUD shows the system value.
    expect(find.text('${(lastSet * 100).round()}%'), findsOneWidget);

    // Hardware key: native pushes volumeChanged 0.3 — the HUD
    // follows without any drag.
    await TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .handlePlatformMessage(
      systemVolumeChannelName,
      codec.encodeMethodCall(
        const MethodCall('volumeChanged', <String, Object>{'volume': 0.3}),
      ),
      (_) {},
    );
    await tester.pump();
    expect(find.text('30%'), findsOneWidget);
    expect(backend.setVolumes.length, volumesBeforeDrag);

    await tester.pump(const Duration(seconds: 5));
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
  });
}
