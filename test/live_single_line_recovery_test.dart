// Single-line live-room recovery (P1-8).
//
// A room with one line (Kuaishou by design, Douyin often 1-2 lines)
// must get fresh re-parse attempts (held plan, then live re-parse)
// before the failure card — the old budget `lines.length - 1` was 0
// for one line, so the FIRST session error showed the failure card
// and skipped recovery entirely, and a mid-playback stall (12 s
// watchdog) could only be fixed by a manual retry.
//
// Fakes only — no network. Harness mirrors live_quality_line_test.dart
// (same Hive memory-box + runAsync settle pattern — see the notes
// there; do NOT "simplify" settle() away).

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/shared/platforms/live_site.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-single-line-test-');
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
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  tearDown(() async {
    Get.reset();
    await HiveStore.put(HiveKeys.videoPlayerKey, 'mpv');
  });

  group('autoRecoveryBudget (P1-8)', () {
    test('single line gets freshRounds=2; multi-line keeps lines-1', () {
      expect(LiveRoomPage.autoRecoveryBudget(1), 2);
      expect(LiveRoomPage.autoRecoveryBudget(2), 1);
      expect(LiveRoomPage.autoRecoveryBudget(3), 2);
      expect(LiveRoomPage.autoRecoveryBudget(4), 3);
    });
  });

  group('LiveRoomPage: single-line recovery (widget)', () {
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<void> pumpRoom(
      WidgetTester tester,
      _FakeSite site,
      _BackendLog log,
      Map<PlayerEngine, _FakeBackendConfig> configs,
    ) async {
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
              roomId: '660000',
              platform: 'huya',
              title: 'test room',
              nick: 'tester',
              liveStatus: true,
            ),
            site: site,
            backendFactory: (engine) => _FakeBackend(
              engine: engine,
              log: log,
              config: configs[engine]!,
            ),
          ),
        ),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
    }

    Map<PlayerEngine, _FakeBackendConfig> freshConfigs() => {
          for (final e in PlayerEngine.values) e: _FakeBackendConfig(),
        };

    Future<void> disposeRoom(WidgetTester tester, _BackendLog log) async {
      log.cancelAllTickers();
      Get.closeAllSnackbars();
      for (var i = 0; i < 10; i++) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    testWidgets('single-line stall: fresh re-parse first, no failure card',
        (tester) async {
      final site = _FakeSite()
        ..urlsByQuality = const {
          '10000': [
            'https://tx.flv.huya.com/src/660000.flv?wsSecret=A1',
          ],
        }
        ..recoveryUrlsByQuality = const {
          '10000': [
            'https://tx.flv.huya.com/src/660000.flv?wsSecret=A2',
          ],
        };
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      expect(find.text('▶ 重试'), findsNothing);
      log.backends.last.emitError('boom');
      await settle(tester);
      // P1-8: the first error must spend a fresh recovery, not show
      // the failure card. The stalled line's possibly-expired URL is
      // never re-opened — the fresh signature plays instead.
      expect(site.recoveryCalls, 1);
      expect(
        log.opens.last.url,
        'https://tx.flv.huya.com/src/660000.flv?wsSecret=A2',
      );
      expect(find.text('▶ 重试'), findsNothing);
      await disposeRoom(tester, log);
    });

    testWidgets(
        'single-line stall with a dead fresh source: failure card after fresh is exhausted',
        (tester) async {
      final site = _FakeSite()
        ..urlsByQuality = const {
          '10000': [
            'https://tx.flv.huya.com/src/660000.flv?wsSecret=A1',
          ],
        }
        ..recoveryThrows = true;
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      log.backends.last.emitError('boom');
      await settle(tester);
      // The fresh attempt ran (recoveryCalls 1) and failed, and there
      // is no other line — only now does the failure card show.
      expect(site.recoveryCalls, 1);
      expect(find.text('▶ 重试'), findsOneWidget);
      await disposeRoom(tester, log);
    });

    testWidgets(
        'single-line: consecutive failures end on the failure card, never loop',
        (tester) async {
      final site = _FakeSite()
        ..urlsByQuality = const {
          '10000': [
            'https://tx.flv.huya.com/src/660000.flv?wsSecret=A1',
          ],
        }
        ..recoveryUrlsByQuality = const {
          '10000': [
            'https://tx.flv.huya.com/src/660000.flv?wsSecret=A2',
          ],
        };
      final log = _BackendLog();
      final configs = freshConfigs();
      await pumpRoom(tester, site, log, configs);
      // From here every fresh open fails too: the first recovery's
      // open dies in the ladder, the second error's fetch is 60 s
      // throttled, and there is no next line — the room must fail
      // visibly instead of retrying forever.
      for (final config in configs.values) {
        config.openSucceeds = false;
      }
      log.backends.last.emitError('boom');
      await settle(tester);
      expect(find.text('▶ 重试'), findsOneWidget);
      expect(site.recoveryCalls, 1);
      // No retry storm: more time passes, no further recovery runs.
      await tester.pump(const Duration(seconds: 5));
      await tester.pump();
      expect(site.recoveryCalls, 1);
      expect(find.text('▶ 重试'), findsOneWidget);
      await disposeRoom(tester, log);
    });

    testWidgets('multi-line room recovery unchanged: fresh re-parse first',
        (tester) async {
      final site = _FakeSite();
      final log = _BackendLog();
      await pumpRoom(tester, site, log, freshConfigs());
      log.backends.last.emitError('boom');
      await settle(tester);
      expect(site.recoveryCalls, 1);
      expect(
        log.opens.last.url,
        'https://tx.flv.huya.com/src/660000.flv?wsSecret=A2',
      );
      expect(find.text('▶ 重试'), findsNothing);
      await disposeRoom(tester, log);
    });
  });
}

/// Minimal fake site: one quality (原画), configurable line counts,
/// fresh (new-signature) URLs for the recovery path.
class _FakeSite extends LiveSite {
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

  Map<String, List<String>> recoveryUrlsByQuality = {
    '10000': [
      'https://tx.flv.huya.com/src/660000.flv?wsSecret=A2',
      'https://al.huya.com/src/660000.m3u8?wsSecret=A2',
    ],
    '400': [
      'https://tx.flv.huya.com/src/660000.flv?wsSecret=B2',
      'https://al.huya.com/src/660000.m3u8?wsSecret=B2',
    ],
  };

  bool recoveryThrows = false;
  int recoveryCalls = 0;

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
  }) async {
    recoveryCalls++;
    if (recoveryThrows) {
      throw StateError('recovery resolve failed');
    }
    return _resolution(recoveryUrlsByQuality, quality);
  }
}

/// One recorded backend open.
class _BackendOpen {
  _BackendOpen({required this.engine, required this.url});

  final PlayerEngine engine;
  final String url;
}

/// Shared record of every fake backend the factory built.
class _BackendLog {
  final List<_BackendOpen> opens = [];
  final List<_FakeBackend> backends = [];

  /// Cancel every fake backend's position ticker directly (see
  /// live_quality_line_test.dart — the session dispose chain never
  /// resolves inside a widget test's fake-async zone).
  void cancelAllTickers() {
    for (final backend in backends) {
      backend.cancelTicker();
    }
  }
}

class _FakeBackendConfig {
  bool openSucceeds = true;
  bool firstFrameSucceeds = true;
  bool emitPositions = true;
}

/// Fake native backend: instant open/first-frame, controllable failure,
/// and a position ticker so the session health watch stays happy.
class _FakeBackend implements PlayerBackend {
  _FakeBackend({
    required this.engine,
    required this.log,
    required this.config,
  }) {
    log.backends.add(this);
  }

  @override
  final PlayerEngine engine;

  final _BackendLog log;
  final _FakeBackendConfig config;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

  Timer? _positionTimer;
  int _positionSeconds = 0;
  bool _disposed = false;

  void emitError(String message) => _error.add(message);

  /// Stop the position ticker without going through dispose().
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
    log.opens.add(_BackendOpen(engine: engine, url: url));
    if (!config.openSucceeds) throw StateError('fake open failed');
    if (config.emitPositions) {
      _positionTimer?.cancel();
      _positionTimer = Timer.periodic(const Duration(seconds: 1), (_) {
        _positionSeconds++;
        _position.add(Duration(seconds: _positionSeconds));
      });
    }
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
    // Do NOT await the broadcast close() calls: inside a widget test's
    // fake-async zone a broadcast StreamController.close() future never
    // completes, so awaiting it stalls _swapBackend forever.
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}
