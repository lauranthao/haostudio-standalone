// TEMPORARY probe — delete after diagnosing the widget-test stall.
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
import 'package:standalone/features/live/live_breadcrumb.dart';
import 'package:standalone/shared/platforms/live_site.dart';

void main() {
  testWidgets('probe room load', (tester) async {
    TestWidgetsFlutterBinding.ensureInitialized();
    final dir = await Directory.systemTemp.createTemp('hao-probe-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return dir.path;
      }
      return null;
    });
    await HiveStore.init();
    // ignore: avoid_print
    print('hive ready, breadcrumb=${LiveBreadcrumb.current}');
    await HiveStore.put('probe', 'x');
    // ignore: avoid_print
    print('hive put ok: ${HiveStore.getString('probe', '?')}');

    final site = _ProbeSite();
    final log = _ProbeLog();
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: LiveRoomPage(
          room: const LiveRoom(roomId: '660000', platform: 'huya'),
          site: site,
          backendFactory: (engine) => _ProbeBackend(engine: engine, log: log),
        ),
      ),
    );
    await tester.pump();
    // ignore: avoid_print
    print(
      'after pump: resolve=${site.resolveCalls} quals=${site.qualityCalls} opens=${log.opens} loading=${find.byType(CircularProgressIndicator).evaluate().length} chips=${find.byType(ChoiceChip).evaluate().length} fail=${find.text('▶ 重试').evaluate().length}',
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    // ignore: avoid_print
    print(
      'after runAsync drain: resolve=${site.resolveCalls} quals=${site.qualityCalls} opens=${log.opens} loading=${find.byType(CircularProgressIndicator).evaluate().length} chips=${find.byType(ChoiceChip).evaluate().length} fail=${find.text('▶ 重试').evaluate().length}',
    );
    await tester.pump(const Duration(seconds: 1));
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 500));
    });
    await tester.pump();
    // ignore: avoid_print
    print(
      'after 2nd drain: resolve=${site.resolveCalls} opens=${log.opens} chips=${find.byType(ChoiceChip).evaluate().length}',
    );
    await HiveStore.box.close();
    await dir.delete(recursive: true);
  });
}

class _ProbeLog {
  final List<String> opens = [];
}

class _ProbeSite extends LiveSite {
  int resolveCalls = 0;
  int qualityCalls = 0;
  @override
  String get id => 'huya';
  @override
  String get name => 'Huya';
  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async => room;
  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async {
    qualityCalls++;
    return const [LivePlayQuality(quality: '原画', id: '10000')];
  }

  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    resolveCalls++;
    return LivePlayUrlResolution(
      urls: const ['https://example.com/live.flv'],
      issuedAt: DateTime.now(),
      streamFacts: const [LiveStreamFacts(format: 'flv')],
    );
  }
}

class _ProbeBackend implements PlayerBackend {
  _ProbeBackend({required this.engine, required _ProbeLog log}) : _log = log;
  @override
  final PlayerEngine engine;
  final _ProbeLog _log;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  @override
  Widget buildVideoWidget() => const SizedBox(key: ValueKey('fake-video'));

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    _log.opens.add(url);
  }

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
  Future<void> dispose() async {}
}
