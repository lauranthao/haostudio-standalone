// Video history page tests (V-P0-1).
//
// - Lists watched videos from VideoHistoryStore with progress +
//   remaining time; finished entries show 已看完.
// - Exactly one continue-playing affordance per item: the row tap
//   (no second "继续播放" button on the row).
// - Tapping a row opens the detail page (with autoResume).
// - Empty state is honest: "还没有观看记录".
// - Clear-all empties the list (and the stored history).

import 'dart:convert';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/features/video/video_detail_page.dart';
import 'package:standalone/features/video/video_history_page.dart';
import 'package:standalone/features/video/video_history_store.dart';

Map<String, dynamic> _entry({
  required String vodId,
  required String title,
  required String epName,
  required double position,
  required double duration,
}) =>
    {
      'source': 12,
      'vodId': vodId,
      'title': title,
      'pic': 'https://example.com/cover-$vodId.jpg',
      'picAlt': '',
      'lineIdx': 0,
      'epIdx': 2,
      'epName': epName,
      'position': position,
      'duration': duration,
      'at': DateTime(2026, 11, 16).millisecondsSinceEpoch,
    };

Future<void> _seedHistory() async {
  await HiveStore.put(
    HiveKeys.videoHistory,
    jsonEncode([
      // Mid-watch: 600/1800 s -> 还剩 20 分钟.
      _entry(
        vodId: '93344',
        title: '流浪地球2',
        epName: '第3集',
        position: 600,
        duration: 1800,
      ),
      // Finished: 1790/1800 s -> 已看完.
      _entry(
        vodId: '93345',
        title: '长津湖',
        epName: '正片',
        position: 1790,
        duration: 1800,
      ),
    ]),
  );
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-history-test-');
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

  tearDown(() async {
    Get.reset();
    await HiveStore.delete(HiveKeys.videoHistory);
  });

  Future<void> pumpHistory(WidgetTester tester) async {
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: const VideoHistoryPage(),
      ),
    );
    await tester.pump();
  }

  /// Real-zone settle (repo pattern: danmaku/live tests). Clear-all
  /// awaits Hive deletes; real I/O hangs inside the fake-async zone,
  /// so let it land on the real clock, then pump a frame.
  Future<void> settle(WidgetTester tester) async {
    await tester.runAsync(() async {
      await Future<void>.delayed(const Duration(milliseconds: 200));
    });
    await tester.pump();
  }

  testWidgets('lists watched videos with progress + remaining time',
      (tester) async {
    await _seedHistory();
    await pumpHistory(tester);

    expect(find.text('流浪地球2'), findsOneWidget);
    expect(find.text('长津湖'), findsOneWidget);
    expect(find.text('第3集 · 还剩 20 分钟'), findsOneWidget);
    expect(find.text('正片 · 已看完'), findsOneWidget);
  });

  testWidgets('one continue-playing affordance per item (audit P2)',
      (tester) async {
    await _seedHistory();
    await pumpHistory(tester);

    // The row tap is the only resume affordance: no "继续播放" button
    // text anywhere on the page, one play cue icon per row.
    expect(find.text('继续播放'), findsNothing);
    expect(find.byIcon(Icons.play_circle_outline), findsNWidgets(2));
  });

  testWidgets('tapping a row opens the detail page', (tester) async {
    await _seedHistory();
    await pumpHistory(tester);

    await tester.tap(find.text('流浪地球2'));
    await settle(tester);

    expect(find.byType(VideoDetailPage), findsOneWidget);

    // Leave the detail page (it is mid-load) before the test ends.
    await tester.pageBack();
    await tester.pump();
  });

  testWidgets('empty state is honest', (tester) async {
    await pumpHistory(tester);

    expect(find.text('还没有观看记录'), findsOneWidget);
    expect(find.text('流浪地球2'), findsNothing);
  });

  testWidgets('clear-all empties the list', (tester) async {
    await _seedHistory();
    await pumpHistory(tester);
    expect(find.text('流浪地球2'), findsOneWidget);

    await tester.tap(find.byIcon(Icons.delete_outline));
    await tester.pump();
    expect(find.text('清空历史记录？'), findsOneWidget);

    await tester.tap(find.text('清空'));
    await settle(tester);

    expect(find.text('还没有观看记录'), findsOneWidget);
    expect(VideoHistoryStore.getAll(), isEmpty);
  });
}
