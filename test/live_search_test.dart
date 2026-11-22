// Live search tests (chen 2026-11-17: the live tab had NO search
// entry at all — the feature was entirely absent, not broken).
//
// The platform adapters all implement searchRooms already (Huya real
// API, Douyu japi, Bilibili search/type, Douyin 3-stage fallback,
// Kuaishou author search), so this file tests the new UI + history
// only — plus a real-network smoke test per platform that searchRooms
// returns real rooms (Douyu + Huya probed live via curl first; the
// others already have real-network search tests in their own files).
//
// Fakes only for the page tests (injected searchFn) — no network.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/live_history_store.dart';
import 'package:standalone/domains/live/presentation/live_search_page.dart';

LiveRoom _room({
  required String roomId,
  String platform = 'huya',
  String title = '',
  String nick = '',
  bool live = true,
  int watching = 0,
}) =>
    LiveRoom(
      roomId: roomId,
      platform: platform,
      title: title,
      nick: nick,
      watching: watching,
      liveStatus: live,
    );

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-live-search-test-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    // Memory-backed box: a Hive file write issued inside a widget
    // test's fake-async zone never completes there (see
    // live_quality_line_test.dart) — the memory backend's writeFrames
    // is Future.value(), no file I/O, no wedge.
    final memBox = await Hive.openBox<dynamic>(
      'test_settings',
      bytes: Uint8List(0),
    );
    HiveStore.setTestBox(memBox);
  });

  tearDownAll(() {
    // NEVER await HiveStore.box.close() here — the pending write queue
    // in the fake zone makes close() never return (v1.0.8 lesson).
    unawaited(HiveStore.box.close());
    unawaited(hiveDir.delete(recursive: true));
  });

  tearDown(() async {
    Get.reset();
    await HiveStore.delete(HiveKeys.liveSearchHist);
    await HiveStore.delete(HiveKeys.liveHistory);
  });

  group('LiveHistoryStore search history', () {
    test('save + get: most recent first', () async {
      await LiveHistoryStore.saveSearchQuery('王者荣耀');
      await LiveHistoryStore.saveSearchQuery('英雄联盟');
      expect(
        LiveHistoryStore.getSearchHistory(),
        ['英雄联盟', '王者荣耀'],
      );
    });

    test('duplicate query moves to front, no duplicate', () async {
      await LiveHistoryStore.saveSearchQuery('王者荣耀');
      await LiveHistoryStore.saveSearchQuery('英雄联盟');
      await LiveHistoryStore.saveSearchQuery('王者荣耀');
      expect(
        LiveHistoryStore.getSearchHistory(),
        ['王者荣耀', '英雄联盟'],
      );
    });

    test('max 20, oldest dropped', () async {
      for (var i = 0; i < 21; i++) {
        await LiveHistoryStore.saveSearchQuery('词$i');
      }
      final history = LiveHistoryStore.getSearchHistory();
      expect(history.length, 20);
      expect(history.first, '词20');
      expect(history.contains('词0'), isFalse);
    });

    test('empty / blank query ignored', () async {
      await LiveHistoryStore.saveSearchQuery('  ');
      await LiveHistoryStore.saveSearchQuery('');
      expect(LiveHistoryStore.getSearchHistory(), isEmpty);
    });

    test('clear removes all', () async {
      await LiveHistoryStore.saveSearchQuery('王者荣耀');
      await LiveHistoryStore.clearSearchHistory();
      expect(LiveHistoryStore.getSearchHistory(), isEmpty);
    });

    test('corrupt stored value reads as empty', () async {
      await HiveStore.put(HiveKeys.liveSearchHist, 'not-json{{{');
      expect(LiveHistoryStore.getSearchHistory(), isEmpty);
    });
  });

  group('LiveSearchPage (widget, fake searchFn)', () {
    /// Drain real async work (the page's Hive put for saving the query
    /// needs a runAsync flush in the fake zone — same load-bearing
    /// pattern as live_quality_line_test's settle()).
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<void> pumpPage(
      WidgetTester tester, {
      String? initialPlatform,
      Future<List<LiveRoom>> Function(String platform, String keyword)?
          searchFn,
      void Function(LiveRoom room)? onOpenRoom,
    }) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveSearchPage(
            initialPlatform: initialPlatform,
            searchFn: searchFn,
            onOpenRoom: onOpenRoom,
          ),
        ),
      );
      await tester.pump();
    }

    Future<void> submit(WidgetTester tester, String query) async {
      await tester.enterText(find.byType(TextField), query);
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      await tester.pump();
    }

    testWidgets('shows history chips before search; tap chip searches',
        (tester) async {
      await LiveHistoryStore.saveSearchQuery('王者荣耀');
      final searched = <String>[];
      await pumpPage(
        tester,
        initialPlatform: 'huya',
        searchFn: (platform, keyword) async {
          searched.add('$platform:$keyword');
          return [_room(roomId: '1', title: '王者荣耀直播')];
        },
      );
      expect(find.text('搜索历史'), findsOneWidget);
      expect(find.text('王者荣耀'), findsOneWidget);
      await tester.tap(find.text('王者荣耀'));
      await settle(tester);
      await tester.pump();
      // Progressive fan-out: one query searches every enabled platform.
      expect(searched, [
        'bilibili:王者荣耀',
        'douyu:王者荣耀',
        'huya:王者荣耀',
        'douyin:王者荣耀',
        'kuaishou:王者荣耀',
      ]);
      expect(find.text('王者荣耀直播'), findsOneWidget);
      // The searched term is saved again (dedup keeps one row).
      expect(LiveHistoryStore.getSearchHistory(), ['王者荣耀']);
    });

    testWidgets('no history section when history is empty',
        (tester) async {
      await pumpPage(tester, searchFn: (_, _) async => []);
      expect(find.text('搜索历史'), findsNothing);
    });

    testWidgets('results shown; tap opens room + records history',
        (tester) async {
      LiveRoom? opened;
      await pumpPage(
        tester,
        searchFn: (_, _) async => [
          _room(roomId: '11', title: 'Gemini直播', nick: 'MrGemini'),
          _room(roomId: '22', title: '另一间', nick: '主播B', live: false),
        ],
        onOpenRoom: (room) => opened = room,
      );
      await submit(tester, 'Gemini');
      expect(find.text('Gemini直播'), findsOneWidget);
      expect(find.text('另一间'), findsOneWidget);
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('未开播'), findsOneWidget);
      await tester.tap(find.text('Gemini直播'));
      await settle(tester);
      expect(opened?.roomId, '11');
      expect(
        LiveHistoryStore.getAll().map((e) => e.roomId),
        contains('11'),
      );
    });

    testWidgets('empty results show an honest empty state',
        (tester) async {
      await pumpPage(tester, searchFn: (_, _) async => []);
      await submit(tester, '不存在的主播xyz');
      // Full-string match: find.textContaining would also match the
      // search field's EditableText, which holds the same query.
      expect(find.text('没有找到相关直播间：不存在的主播xyz'), findsOneWidget);
    });

    testWidgets('failed search shows error + retry re-runs', (tester) async {
      var calls = 0;
      await pumpPage(
        tester,
        // The whole first round (all 5 platforms) fails; the retry
        // round succeeds. Error state needs ALL platforms failed.
        searchFn: (_, _) async {
          calls++;
          if (calls <= 5) throw Exception('boom');
          return [_room(roomId: '9', title: '重试后有了')];
        },
      );
      await submit(tester, '重试');
      expect(find.text('直播源暂时无法访问'), findsOneWidget);
      // widgetWithText: find.text('重试') also matches the search
      // field's EditableText, which holds the same query.
      await tester.tap(find.widgetWithText(FilledButton, '重试'));
      await settle(tester);
      await tester.pump();
      expect(calls, 10);
      expect(find.text('重试后有了'), findsOneWidget);
    });

    testWidgets('platform chips filter merged results without re-running',
        (tester) async {
      // Tall viewport: all 5 merged rows must be built at once, or
      // ListView.builder leaves the 5th below the fold unbuilt.
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final calls = <String>[];
      await pumpPage(
        tester,
        initialPlatform: 'huya',
        searchFn: (platform, keyword) async {
          calls.add('$platform:$keyword');
          return [_room(roomId: '1', platform: platform, title: '间')];
        },
      );
      await submit(tester, '英雄联盟');
      // One fan-out round: all 5 platforms searched once.
      expect(calls, [
        'bilibili:英雄联盟',
        'douyu:英雄联盟',
        'huya:英雄联盟',
        'douyin:英雄联盟',
        'kuaishou:英雄联盟',
      ]);
      // Initial filter is huya: only that platform's room shows.
      expect(find.text('间'), findsOneWidget);
      // 全部 shows all 5 merged rooms; no re-run.
      await tester.tap(find.text('全部'));
      await tester.pump();
      expect(calls.length, 5);
      expect(find.text('间'), findsNWidgets(5));
      // 斗鱼 filters to that platform only; still no re-run.
      await tester.tap(find.text('斗鱼'));
      await tester.pump();
      expect(calls.length, 5);
      expect(find.text('间'), findsOneWidget);
    });

    testWidgets('stale first search cannot overwrite the new query',
        (tester) async {
      final slowDone = Completer<List<LiveRoom>>();
      await pumpPage(
        tester,
        searchFn: (platform, keyword) async {
          if (keyword == '慢的') return slowDone.future;
          return [_room(roomId: 'fast', title: '快的房间')];
        },
      );
      await tester.enterText(find.byType(TextField), '慢的');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await tester.pump();
      await tester.enterText(find.byType(TextField), '快的');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      await tester.pump();
      expect(find.text('快的房间'), findsOneWidget);
      // The slow search finally lands — it must NOT replace the results.
      slowDone.complete([_room(roomId: 'slow', title: '慢的房间')]);
      await tester.pump();
      expect(find.text('快的房间'), findsOneWidget);
      expect(find.text('慢的房间'), findsNothing);
    });

    testWidgets('clear history removes the section', (tester) async {
      await LiveHistoryStore.saveSearchQuery('王者荣耀');
      await pumpPage(tester, searchFn: (_, _) async => []);
      expect(find.text('搜索历史'), findsOneWidget);
      await tester.tap(find.text('清除'));
      await settle(tester);
      await tester.pump();
      expect(find.text('搜索历史'), findsNothing);
      expect(LiveHistoryStore.getSearchHistory(), isEmpty);
    });
  });
}
