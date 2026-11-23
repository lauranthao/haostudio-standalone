// b31 crash hunt — UI/navigation/lifecycle layer.
//
// Two regression tests, one per fixed site:
//
// 1. EmbyDetailPage: a malformed server item (wrong-typed field) used
//    to escape _load() as an unhandled async error and strand the page
//    on the loading spinner forever; it must now show the error card.
// 2. FullscreenController: player pages used to share ONE Get
//    registration across stacked rooms (a bare Get.put silently
//    reuses the first registration); each page must now own its
//    controller, so popping the top room cannot delete the bottom
//    room's controller. The Get registration stays, but only as the
//    widget-test seam (the room tests flip isFullscreen via Get.find
//    because the real [ ] tap's SystemChrome awaits never complete
//    in a widget test) — and a page deletes it only when it is its
//    own instance.
//
// Room fakes below are copied from b27_video_live_fixes_test.dart
// (_RoomFakeSite / _RoomFakeBackend / pumpRoom / disposeRoom) —
// trimmed to what these two tests need.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/features/player/fullscreen_controller.dart';
import 'package:standalone/features/video/emby_detail_page.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';
import 'package:standalone/shared/platforms/live_site.dart';

import 'helpers/hive_test_setup.dart';

// Fixture key: explicitly fake, never a real credential (same
// convention as emby_render_test.dart).
const _config = EmbyServerConfig(
  baseUrl: 'http://127.0.0.1:8096',
  apiKey: 'fake-key',
  userId: 'user-1',
);

/// Detail fetch returns a wrong-typed `Type`: the real client's
/// `(item['Type'] as String?)` throws a raw TypeError — neither Dio
/// nor Emby. Anything else 404s.
Future<EmbyResponse> _malformedFetcher(
  String url, {
  Map<String, String>? headers,
  Duration timeout = const Duration(seconds: 8),
  CancelToken? cancelToken,
}) async {
  if (url.contains('/Items/m1')) {
    return const EmbyResponse(
      statusCode: 200,
      json: {'Id': 'm1', 'Type': 12345},
    );
  }
  return const EmbyResponse(statusCode: 404, json: {});
}

class _B31FakeSite extends LiveSite {
  List<LivePlayQuality> qualities = const [
    LivePlayQuality(quality: '原画', id: '10000'),
    LivePlayQuality(quality: '高清', id: '400'),
  ];

  Map<String, List<String>> urlsByQuality = {
    '10000': [
      'https://tx.flv.huya.com/src/660000.flv?wsSecret=A1',
      'https://al.huya.com/src/660000.m3u8?wsSecret=A1',
    ],
    '400': [
      'https://tx.flv.huya.com/src/660000.flv?wsSecret=B1',
      'https://al.huya.com/src/660000.m3u8?wsSecret=B1',
    ],
  };

  @override
  String get id => 'huya';

  @override
  String get name => 'Huya';

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async => room;

  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async =>
      qualities;

  LivePlayUrlResolution _resolution(
    Map<String, List<String>> urls,
    LivePlayQuality? quality,
  ) {
    final id = quality?.selectionId ?? '';
    final issued = DateTime.now();
    final list = urls[id] ?? const <String>[];
    return LivePlayUrlResolution(
      urls: list,
      issuedAt: issued,
      refreshAt: issued.add(const Duration(seconds: 100)),
      invalidAt: issued.add(const Duration(seconds: 125)),
      streamFacts: list
          .map(
            (u) => u.toLowerCase().split('?').first.endsWith('.m3u8')
                ? const LiveStreamFacts(format: 'hls')
                : const LiveStreamFacts(format: 'flv'),
          )
          .toList(growable: false),
    );
  }

  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async =>
      _resolution(urlsByQuality, quality);

  @override
  Future<LivePlayUrlResolution> resolvePlayUrlsForRecovery({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async =>
      _resolution(urlsByQuality, quality);
}

class _B31BackendLog {
  final List<({PlayerEngine engine, String url})> opens = [];
  final List<_B31FakeBackend> backends = [];

  void cancelAllTickers() {
    for (final backend in backends) {
      backend.cancelTicker();
    }
  }
}

class _B31FakeBackend implements PlayerBackend {
  _B31FakeBackend({
    required this.engine,
    required this.log,
  }) {
    log.backends.add(this);
  }

  @override
  final PlayerEngine engine;

  final _B31BackendLog log;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  Timer? _positionTimer;
  int _positionSeconds = 0;
  bool _disposed = false;

  void cancelTicker() => _positionTimer?.cancel();

  @override
  Widget buildVideoWidget() => const SizedBox(key: ValueKey('fake-video'));

  @override
  Future<void> open({
    required String url,
    Map<String, String>? headers,
    required bool isLive,
    String? declaredFormat,
  }) async {
    log.opens.add((engine: engine, url: url));
    _positionTimer?.cancel();
    _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
      _positionSeconds++;
      _position.add(Duration(seconds: _positionSeconds));
    });
  }

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
    if (_disposed) return;
    _disposed = true;
    _positionTimer?.cancel();
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
    hiveDir = await HiveTestSetup.init(prefix: 'hao-b31-crash-ui-');
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  tearDown(() {
    Get.reset();
  });

  group('EmbyDetailPage: B31-1 malformed server data', () {
    testWidgets(
        'wrong-typed detail field shows the error card, never strands the page',
        (tester) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: EmbyDetailPage(
            itemId: 'm1',
            client: EmbyClient(config: _config, fetcher: _malformedFetcher),
          ),
        ),
      );
      var found = false;
      for (var i = 0; i < 20; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        if (find.text('加载失败').evaluate().isNotEmpty) {
          found = true;
          break;
        }
      }
      expect(found, isTrue);
      // Merged behaviour (b31 data layer): the wrong-typed `Type`
      // no longer throws a parse TypeError — the client's safe
      // parsing defaults it, detail() then fails cleanly as an
      // EmbyException, and the page shows the error card with that
      // message. So the exact text is not pinned here; what this
      // test guards is the outcome: an error card with a retry,
      // never a spinner forever and never an unhandled error. The
      // catch-all in _load stays as defense-in-depth for parse
      // throws the safe layer does not cover.
      expect(find.text('重试'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  });

  group('FullscreenController: B31-2 stacked rooms', () {
    Future<void> pumpRoom(
      WidgetTester tester,
      _B31FakeSite site,
      _B31BackendLog log, {
      required String roomId,
    }) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.runAsync(
        () => HiveStore.put(HiveKeys.preferResolution, '原画'),
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveRoomPage(
            room: LiveRoom(
              roomId: roomId,
              platform: 'huya',
              title: 'test room $roomId',
              nick: 'tester',
              liveStatus: true,
            ),
            site: site,
            backendFactory: (engine) =>
                _B31FakeBackend(engine: engine, log: log),
          ),
        ),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
    }

    Future<void> disposeRoom(
      WidgetTester tester,
      _B31BackendLog log,
    ) async {
      log.cancelAllTickers();
      Get.closeAllSnackbars();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    testWidgets(
        'second room on top owns its controller; popping it leaves the first room alive',
        (tester) async {
      final site = _B31FakeSite();
      final log = _B31BackendLog();
      await pumpRoom(tester, site, log, roomId: '660000');
      // The Get registration is the widget-test seam: it must be
      // the FIRST room's own controller.
      expect(Get.isRegistered<FullscreenController>(), isTrue);
      final first = Get.find<FullscreenController>();
      expect(find.byType(LiveRoomPage), findsOneWidget);

      // Multiview onOpenSingle path: a second room on top.
      Get.to(
        () => LiveRoomPage(
          room: const LiveRoom(
            roomId: '660001',
            platform: 'huya',
            title: 'test room 660001',
            nick: 'tester',
            liveStatus: true,
          ),
          site: site,
          backendFactory: (engine) =>
              _B31FakeBackend(engine: engine, log: log),
        ),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      // The old code's bare Get.put left the registration pointing
      // at the shared controller and the top room's dispose deleted
      // it; the fix must leave the first room's registration
      // untouched while both rooms are alive.
      expect(Get.isRegistered<FullscreenController>(), isTrue);
      expect(identical(Get.find<FullscreenController>(), first), isTrue);
      expect(find.byType(LiveRoomPage), findsNWidgets(2));

      // Pop the top room: the bottom room must survive with its own
      // fullscreen controller and its registration intact.
      // System back (tester.pageBack), not Get.back(): Get.back()
      // never pops here — GetX's back() no-ops in this harness
      // (its snackbar/overlay gate), while the production back
      // button (HaoNavBar) and the system gesture both go through
      // the Navigator directly, which is what pageBack exercises.
      await tester.pageBack();
      // The pop transition runs on fake time (~300 ms): a bare pump
      // leaves the popped page mid-transition and the tree still
      // shows two rooms. Pump past the transition first.
      await tester.pump(const Duration(milliseconds: 1000));
      await tester.pump();
      expect(find.byType(LiveRoomPage), findsOneWidget);
      expect(Get.isRegistered<FullscreenController>(), isTrue);
      expect(identical(Get.find<FullscreenController>(), first), isTrue);
      expect(tester.takeException(), isNull);

      await disposeRoom(tester, log);
      await drainHiveWrites(tester);
      // The first room's dispose deletes its own registration.
      expect(Get.isRegistered<FullscreenController>(), isFalse);
    });
  });
}
