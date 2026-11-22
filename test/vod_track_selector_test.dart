// VOD audio/subtitle track picker (build 28, Emby formats) — UI tests.
//
// The plumbing (PlaybackSession.audioTracks/subtitleTracks/
// setAudioTrack/setSubtitleTrack, remembered + re-applied on backend
// swap) is the Emby group's, verified there. These tests pin the UI
// side only, in native_video_player_page.dart:
// - capable backend (MPV): the sheet lists both sections, '自动'
//   returns to the backend default, '关闭' turns subtitles off, the
//   checkmark follows the tap;
// - incapable backend (IJK / AVPlayer): the sheet shows the
//   "无音轨 / 无字幕" empty states, never a broken list;
// - the choice lives in the session: switching episode keeps
//   currentAudioTrackId/currentSubtitleTrackId, and a reopened sheet
//   shows the same checkmarks.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';

import 'helpers/hive_test_setup.dart' as hive_setup;

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-vod-tracks-');
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
    unawaited(HiveStore.box.close());
    await hiveDir.delete(recursive: true);
  });

  tearDown(() {
    Get.reset();
    // No Hive deletes here: a fire-and-forget delete queues a write
    // that the next test's first Hive write would hang behind (see
    // helpers/hive_test_setup.dart); unmountPlayer drains instead.
  });

  VideoDetail detail() => VideoDetail(
    source: 12,
    vodId: '93344',
    meta: VideoMeta(name: '狂飙', year: '2023'),
    lines: [
      PlayLine(
        name: '线路1',
        episodes: const [
          PlayEpisode(name: '第1集', url: 'https://example.com/ep1.mp4'),
          PlayEpisode(name: '第2集', url: 'https://example.com/ep2.mp4'),
        ],
      ),
    ],
  );

  late PlaybackSession session;

  Future<void> pumpPlayer(WidgetTester tester, PlayerBackend backend) async {
    session = PlaybackSession(backendFactory: (_) => backend);
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: NativeVideoPlayerPage(detail: detail(), session: session),
      ),
    );
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 300));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  /// Real-async drain + a bounded fake-time advance (the 5 s
  /// hide timer must not fire mid-test and hide the bottom bar).
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 200));
  }

  Future<void> openTrackSheet(WidgetTester tester) async {
    // Tracks moved into the 更多 menu (build 29, K): open the
    // CupertinoActionSheet first, then the 音轨与字幕 action. Push
    // the clock so the sheet finishes sliding in (its rows start
    // below the fold). Measured: one pump(1500 ms) does NOT move
    // it — the route's animation only starts ticking on the SECOND
    // pump call (the time advance inside the first pump runs before
    // the route's first frame). Two time-advancing pumps land it;
    // the same pair after the tap lets the pop finish (its label
    // otherwise stays in the tree next to the track sheet's title).
    await tester.tap(find.byTooltip('更多'));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    await tester.tap(find.text('音轨与字幕'));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(find.text('音轨与字幕'), findsOneWidget);
  }

  Future<void> closeTrackSheet(WidgetTester tester) async {
    // Tap the barrier above the sheet. The sheet is content-height
    // (taller than the old 0.6 guess), so tap near the top of the
    // viewport; then push the clock twice — the dismiss animation,
    // like the more menu's entrance, only ticks on a second
    // time-advancing pump.
    await tester.tapAt(const Offset(400, 10));
    await settle(tester);
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump(const Duration(milliseconds: 800));
    await tester.pump();
    expect(find.text('音轨与字幕'), findsNothing);
  }

  Future<void> unmountPlayer(WidgetTester tester) async {
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    // Drain the player's fire-and-forget Hive writes before the test
    // ends, or the next test's first Hive write hangs forever.
    await hive_setup.drainHiveWrites(tester);
  }

  /// Whether the row with [keyValue] currently shows the checkmark.
  /// Rows are found by key (not by label + index): the two '自动'
  /// rows share a label. The sheet uses a Column (not a ListView),
  /// so every row stays built and no scrolling is needed to read it.
  bool rowSelectedByKey(WidgetTester tester, String keyValue) {
    final tile = tester.widget<ListTile>(find.byKey(ValueKey(keyValue)));
    final trailing = tile.trailing;
    return trailing is Icon && trailing.icon == Icons.check;
  }

  /// Bring the row into view (it is built but may be below the fold)
  /// and tap it.
  Future<void> tapRowByKey(WidgetTester tester, String keyValue) async {
    await tester.ensureVisible(find.byKey(ValueKey(keyValue)));
    await tester.pump();
    await tester.tap(find.byKey(ValueKey(keyValue)));
    await tester.pump();
  }

  /// Assert the row exists (all rows stay built in the Column).
  void expectRowVisible(WidgetTester tester, String keyValue) {
    expect(find.byKey(ValueKey(keyValue)), findsOneWidget);
  }

  testWidgets('capable backend: sheet lists audio + subtitle tracks', (
    tester,
  ) async {
    await pumpPlayer(tester, _FakeTrackBackend());
    await openTrackSheet(tester);
    expect(find.text('音轨'), findsOneWidget);
    expect(find.text('字幕轨'), findsOneWidget);
    expectRowVisible(tester, 'vod-track-audio-auto');
    expectRowVisible(tester, 'vod-track-audio-1');
    expectRowVisible(tester, 'vod-track-audio-2');
    expectRowVisible(tester, 'vod-track-sub-auto');
    expectRowVisible(tester, 'vod-track-sub-no');
    expectRowVisible(tester, 'vod-track-sub-10');
    expectRowVisible(tester, 'vod-track-sub-11');
    // All rows stay built (Column), so labels are assertable directly.
    expectRowVisible(tester, 'vod-track-audio-1');
    expect(find.text('English · eng · aac'), findsOneWidget);
    expectRowVisible(tester, 'vod-track-audio-2');
    expect(find.text('国语 · chi · ac3'), findsOneWidget);
    expectRowVisible(tester, 'vod-track-sub-10');
    // The track is listed twice: 字幕轨 + 第二字幕 (main is 'auto',
    // so nothing is excluded from the second list).
    expect(find.text('中文字幕 · chi'), findsNWidgets(2));
    expectRowVisible(tester, 'vod-track-sub-11');
    expect(find.text('English · eng'), findsNWidgets(2));
    // Defaults: both on '自动'.
    expect(rowSelectedByKey(tester, 'vod-track-audio-auto'), isTrue);
    expect(rowSelectedByKey(tester, 'vod-track-sub-auto'), isTrue);
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
  });

  testWidgets('tapping tracks selects them; 自动/关闭 return to default', (
    tester,
  ) async {
    final backend = _FakeTrackBackend();
    await pumpPlayer(tester, backend);
    await openTrackSheet(tester);

    await tapRowByKey(tester, 'vod-track-audio-2');
    expect(backend.audioTrackCalls, ['2']);
    expect(session.currentAudioTrackId, '2');
    expect(rowSelectedByKey(tester, 'vod-track-audio-2'), isTrue);
    expect(rowSelectedByKey(tester, 'vod-track-audio-auto'), isFalse);

    await tapRowByKey(tester, 'vod-track-sub-10');
    expect(backend.subtitleTrackCalls, ['10']);
    expect(session.currentSubtitleTrackId, '10');
    expect(rowSelectedByKey(tester, 'vod-track-sub-10'), isTrue);

    await tapRowByKey(tester, 'vod-track-sub-no');
    expect(backend.subtitleTrackCalls, ['10', 'no']);
    expect(session.currentSubtitleTrackId, 'no');
    expect(rowSelectedByKey(tester, 'vod-track-sub-no'), isTrue);

    // Back to defaults: audio '自动', subtitle '自动'.
    await tapRowByKey(tester, 'vod-track-audio-auto');
    expect(backend.audioTrackCalls, ['2', 'auto']);
    expect(session.currentAudioTrackId, 'auto');
    await tapRowByKey(tester, 'vod-track-sub-auto');
    expect(backend.subtitleTrackCalls, ['10', 'no', 'auto']);
    expect(session.currentSubtitleTrackId, 'auto');
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
  });

  testWidgets('incapable backend: empty states, no broken list', (
    tester,
  ) async {
    await pumpPlayer(tester, _FakeBackend());
    await openTrackSheet(tester);
    expect(find.byKey(const ValueKey('vod-track-audio-empty')), findsOneWidget);
    expect(find.byKey(const ValueKey('vod-track-sub-empty')), findsOneWidget);
    expect(find.text('无音轨'), findsOneWidget);
    // Both subtitle sections show the empty state (字幕轨 + 第二字幕).
    expect(find.text('无字幕'), findsNWidgets(2));
    expect(find.byKey(const ValueKey('vod-track-audio-auto')), findsNothing);
    expect(find.byKey(const ValueKey('vod-track-sub-no')), findsNothing);
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
  });

  testWidgets('choice survives an episode switch (session remembers)', (
    tester,
  ) async {
    final backend = _FakeTrackBackend();
    await pumpPlayer(tester, backend);
    await openTrackSheet(tester);
    await tapRowByKey(tester, 'vod-track-audio-2');
    await tapRowByKey(tester, 'vod-track-sub-10');
    expect(session.currentAudioTrackId, '2');
    expect(session.currentSubtitleTrackId, '10');
    await closeTrackSheet(tester);

    // Next episode: same session, so the remembered choice stays.
    // The sheet round-trip burned >5 s of fake time, so the 5 s
    // auto-hide already hid the control bar — wake it with one
    // surface tap first (tap-down re-shows it immediately).
    await tester.tap(find.byKey(const ValueKey('fake-video')));
    await tester.pump();
    await tester.tap(find.byTooltip('下一集'));
    await settle(tester);
    expect(session.currentAudioTrackId, '2');
    expect(session.currentSubtitleTrackId, '10');

    // A reopened sheet shows the same checkmarks on the new episode.
    await openTrackSheet(tester);
    expect(rowSelectedByKey(tester, 'vod-track-audio-2'), isTrue);
    expect(rowSelectedByKey(tester, 'vod-track-sub-10'), isTrue);
    expect(tester.takeException(), isNull);
    await unmountPlayer(tester);
  });
}

/// MPV-shaped fake: enumerates tracks and records selections.
class _FakeTrackBackend implements TrackCapableBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();
  final List<String> audioTrackCalls = [];
  final List<String> subtitleTrackCalls = [];
  bool _disposed = false;

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

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
  }) async => true;

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

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
  Future<List<PlaybackTrack>> audioTracks() async => const [
    PlaybackTrack(id: '1', title: 'English', language: 'eng', codec: 'aac'),
    PlaybackTrack(id: '2', title: '国语', language: 'chi', codec: 'ac3'),
  ];

  @override
  Future<List<PlaybackTrack>> subtitleTracks() async => const [
    PlaybackTrack(id: '10', title: '中文字幕', language: 'chi'),
    PlaybackTrack(id: '11', title: 'English', language: 'eng'),
  ];

  @override
  Future<void> setAudioTrack(String id) async {
    audioTrackCalls.add(id);
  }

  @override
  Future<void> setSubtitleTrack(String id) async {
    subtitleTrackCalls.add(id);
  }

  // VOD control group's newer members (sub-delay / secondary-sid /
  // subtitle text stream): stubs only — this fake's job is track
  // enumeration + selection, not the subtitle overlay.
  @override
  Future<void> setSubtitleDelay(double seconds) async {}

  @override
  Future<void> setSecondarySubtitleTrack(String id) async {}

  @override
  Future<void> setSubtitleAppearance({
    required int fontSize,
    required String color,
    required double position,
  }) async {}

  @override
  Stream<List<String>> get subtitleStream =>
      Stream<List<String>>.empty();

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

/// Plain fake: no track capability (IJK / AVPlayer shape).
class _FakeBackend implements PlayerBackend {
  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();
  bool _disposed = false;

  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

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
  }) async => true;

  @override
  Future<void> play() async => _playing.add(true);

  @override
  Future<void> pause() async => _playing.add(false);

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
