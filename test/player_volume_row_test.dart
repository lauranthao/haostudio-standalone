// Player volume row (Windows music player) + app-gain controller tests.
//
// The row itself is pure UI (volume in, callbacks out) so it pumps
// directly with a themed app. The controller part checks setAppVolume:
// the live volume01 view, Hive persistence, clamping, and the
// platform gate (off Windows the player always gets 1.0 — the
// Windows value itself can only be verified on a real Windows
// machine / the CI screenshots, so that path is listed as
// "待真机验证" in the audit, not claimed here).
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:just_audio/just_audio.dart' show ProcessingState;
import 'package:standalone/core/native/now_playing.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/music/music_player_adapter.dart';
import 'package:standalone/features/music/music_player_controller.dart';
import 'package:standalone/features/music/widgets/player_volume_row.dart';

class _FakeStreams implements MusicPlayerStreams {
  @override
  Stream<Duration> get position => const Stream<Duration>.empty();
  @override
  Stream<Duration> get duration => const Stream<Duration>.empty();
  @override
  Stream<bool> get playing => const Stream<bool>.empty();
  @override
  Stream<String> get error => const Stream<String>.empty();
  @override
  Stream<bool> get completed => const Stream<bool>.empty();
}

class _FakeAdapter implements MusicPlayerAdapter {
  final List<double> volumes = [];

  @override
  MusicPlayerStreams get stream => _FakeStreams();

  @override
  ProcessingState get processingState => ProcessingState.idle;

  @override
  Future<bool> preload(String url) async => false;

  @override
  bool isPreloadedFor(String url) => false;

  @override
  Future<bool> open(String url, {bool play = true}) async => false;

  @override
  Future<void> play() async {}

  @override
  Future<void> pause() async {}

  @override
  Future<void> seek(Duration position) async {}

  @override
  Future<void> setVolume(double volume) async {
    volumes.add(volume);
  }

  @override
  Future<void> setRate(double rate) async {}

  @override
  Future<void> dispose() async {}
}

void main() {
  group('PlayerVolumeRow widget', () {
    Future<void> pumpRow(
      WidgetTester tester, {
      required double volume,
      required List<double> changed,
      required List<double> committed,
      required List<int> muteTaps,
    }) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: Scaffold(
            body: Center(
              child: SizedBox(
                width: 360,
                child: PlayerVolumeRow(
                  volume: volume,
                  onChanged: changed.add,
                  onChangeEnd: committed.add,
                  onToggleMute: () => muteTaps.add(1),
                ),
              ),
            ),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('shows speaker, slider and percent for the given volume',
        (tester) async {
      final changed = <double>[];
      final committed = <double>[];
      final muteTaps = <int>[];
      await pumpRow(
        tester,
        volume: 0.6,
        changed: changed,
        committed: committed,
        muteTaps: muteTaps,
      );
      expect(find.byIcon(Icons.volume_up), findsOneWidget);
      expect(find.byType(Slider), findsOneWidget);
      expect(find.text('60%'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 0.6);
    });

    testWidgets('speaker icon follows the level', (tester) async {
      final changed = <double>[];
      final committed = <double>[];
      final muteTaps = <int>[];
      await pumpRow(
        tester,
        volume: 0.0,
        changed: changed,
        committed: committed,
        muteTaps: muteTaps,
      );
      expect(find.byIcon(Icons.volume_off), findsOneWidget);
      await pumpRow(
        tester,
        volume: 0.3,
        changed: changed,
        committed: committed,
        muteTaps: muteTaps,
      );
      expect(find.byIcon(Icons.volume_down), findsOneWidget);
    });

    testWidgets('volume is clamped for display', (tester) async {
      final changed = <double>[];
      final committed = <double>[];
      final muteTaps = <int>[];
      await pumpRow(
        tester,
        volume: 1.5,
        changed: changed,
        committed: committed,
        muteTaps: muteTaps,
      );
      expect(find.text('100%'), findsOneWidget);
      expect(tester.widget<Slider>(find.byType(Slider)).value, 1.0);
    });

    testWidgets('tapping the speaker calls onToggleMute', (tester) async {
      final changed = <double>[];
      final committed = <double>[];
      final muteTaps = <int>[];
      await pumpRow(
        tester,
        volume: 0.6,
        changed: changed,
        committed: committed,
        muteTaps: muteTaps,
      );
      await tester.tap(find.byKey(const ValueKey('playerVolumeMute')));
      await tester.pump();
      expect(muteTaps, [1]);
      expect(changed, isEmpty);
    });

    testWidgets('tapping the slider track reports the tapped value',
        (tester) async {
      final changed = <double>[];
      final committed = <double>[];
      final muteTaps = <int>[];
      await pumpRow(
        tester,
        volume: 0.6,
        changed: changed,
        committed: committed,
        muteTaps: muteTaps,
      );
      // Tap the slider centre: the track maps x -> value linearly,
      // so the centre is ~0.5 regardless of the starting value.
      final center = tester.getCenter(find.byType(Slider));
      await tester.tapAt(center);
      await tester.pump();
      expect(changed, isNotEmpty);
      expect(changed.last, closeTo(0.5, 0.1));
      expect(committed, isNotEmpty);
      expect(committed.last, closeTo(0.5, 0.1));
    });

    testWidgets('dragging the slider moves the value up', (tester) async {
      final changed = <double>[];
      final committed = <double>[];
      final muteTaps = <int>[];
      await pumpRow(
        tester,
        volume: 0.5,
        changed: changed,
        committed: committed,
        muteTaps: muteTaps,
      );
      final center = tester.getCenter(find.byType(Slider));
      await tester.dragFrom(center, const Offset(40, 0));
      await tester.pump();
      expect(changed, isNotEmpty);
      expect(changed.last, greaterThan(0.5));
      expect(changed.last, lessThanOrEqualTo(1.0));
      expect(committed, isNotEmpty);
    });
  });

  group('MusicPlayerController.setAppVolume', () {
    late Box<dynamic> box;

    setUp(() async {
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(nowPlayingChannelName),
        (call) async => null,
      );
      Hive.init('test/.hive-player-volume-test');
      box = await Hive.openBox<dynamic>('player_volume_test');
      await box.clear();
      HiveStore.setTestBox(box);
    });

    tearDown(() async {
      Get.reset();
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
          .setMockMethodCallHandler(
        const MethodChannel(nowPlayingChannelName),
        null,
      );
      await box.close();
      await Hive.deleteBoxFromDisk('player_volume_test');
    });

    test('setAppVolume persists and updates the live view', () async {
      final c = Get.put(MusicPlayerController());
      await c.setAppVolume(0.5);
      expect(c.volume01.value, 0.5);
      expect(HiveStore.getDouble(HiveKeys.appVolume, 1.0), 0.5);
    });

    test('setAppVolume with persist:false applies live but does not store',
        () async {
      final c = Get.put(MusicPlayerController());
      await c.setAppVolume(0.5);
      await c.setAppVolume(0.3, persist: false);
      expect(c.volume01.value, 0.3);
      // Stored value is still the committed one.
      expect(HiveStore.getDouble(HiveKeys.appVolume, 1.0), 0.5);
    });

    test('setAppVolume clamps out-of-range values', () async {
      final c = Get.put(MusicPlayerController());
      await c.setAppVolume(1.5);
      expect(c.volume01.value, 1.0);
      await c.setAppVolume(-0.2);
      expect(c.volume01.value, 0.0);
    });

    test(
        'onInit syncs the live view from the stored gain (Windows) / 1.0 elsewhere',
        () async {
      await HiveStore.put(HiveKeys.appVolume, 0.7);
      final c = Get.put(MusicPlayerController());
      // onInit runs on Get.put and syncs from _targetVolume, which is
      // the stored gain on Windows and exactly 1.0 everywhere else —
      // this Linux host exercises the 1.0 branch. The 0.7 branch only
      // runs on Windows (real machine / CI screenshots).
      expect(c.volume01.value, 1.0);
    });

    test('off Windows the player always gets 1.0 (platform gate)',
        () async {
      final a = _FakeAdapter();
      final b = _FakeAdapter();
      final c = Get.put(MusicPlayerController(playerA: a, playerB: b));
      // onInit already pushed _targetVolume (1.0 here) to the fake.
      a.volumes.clear();
      await c.setAppVolume(0.5);
      expect(c.volume01.value, 0.5);
      expect(HiveStore.getDouble(HiveKeys.appVolume, 1.0), 0.5);
      // The fake player got the gated value, not the Windows one.
      expect(a.volumes, [1.0]);
    });
  });
}
