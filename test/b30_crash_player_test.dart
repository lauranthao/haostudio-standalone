// build 30 崩溃猎杀回归测试（C4，播放器页 widget 部分，单独文件：
// 泵播放器页会拉起大半个 app，单独编译省内存）。
//
// C4: 播放器收到空 lines / 空 episodes：initState 的 clamp(0, -1)
// 抛 ArgumentError、_episode 抛 RangeError；必须出失败卡片。

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/player/playback_session.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';

import 'helpers/hive_test_setup.dart';

void main() {
  group('C4 NativeVideoPlayerPage with no playable episode', () {
    late Directory hiveDir;

    setUpAll(() async {
      hiveDir = await HiveTestSetup.init(prefix: 'hao-crash-hive-');
    });

    tearDownAll(() async {
      await HiveTestSetup.dispose(hiveDir);
    });

    Future<void> pumpPlayer(
      WidgetTester tester, {
      required VideoDetail detail,
    }) async {
      final session = PlaybackSession(
        backendFactory: (engine) => _CrashFakeBackend(engine: engine),
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: NativeVideoPlayerPage(
            detail: detail,
            session: session,
          ),
        ),
      );
      await settle(tester);
      await settle(tester);
    }

    testWidgets('empty lines -> failure card, no throw', (tester) async {
      await pumpPlayer(
        tester,
        detail: VideoDetail(
          source: 12,
          vodId: '1',
          meta: VideoMeta(name: 'Empty Film'),
          lines: [],
        ),
      );
      expect(find.text('播放失败，请检查网络后重试'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });

    testWidgets('line with zero episodes -> failure card, no throw',
        (tester) async {
      await pumpPlayer(
        tester,
        detail: VideoDetail(
          source: 12,
          vodId: '1',
          meta: VideoMeta(name: 'No Episodes'),
          lines: [
            PlayLine(name: '线路1', episodes: []),
          ],
        ),
      );
      expect(find.text('播放失败，请检查网络后重试'), findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    });
  });
}

/// Minimal fake backend: never opens anything (the C4 guard fails the
/// page before any open is attempted, so open must not be reached).
class _CrashFakeBackend implements PlayerBackend {
  _CrashFakeBackend({required this.engine});

  @override
  final PlayerEngine engine;

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
  }) async {}

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
    await _position.close();
    await _duration.close();
    await _playing.close();
    await _error.close();
    await _completed.close();
  }
}
