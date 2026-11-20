// Live history tests (L01).
//
// Store: record (dedup + newest-first), day grouping (today /
// yesterday / 2–6 days ago / earlier), filter (title / anchor /
// roomId / platform), single delete, clear, limit (presets + shrink
// warning count + unlimited).
// Status refresh: per-item timeout / throw -> unknown, never stale-live.
// Page: grouped sections render, filter box filters, single delete
// works, clear-all confirms, refresh shows LIVE / 已下播 / 状态未知.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/live_history_store.dart';
import 'package:standalone/domains/live/live_status.dart';
import 'package:standalone/domains/live/presentation/live_history_page.dart';
import 'package:standalone/shared/platforms/live_site.dart';

import 'helpers/hive_test_setup.dart';

LiveRoom _room(String roomId, {String platform = 'bilibili'}) =>
    LiveRoom(
      roomId: roomId,
      platform: platform,
      title: '标题 $roomId',
      nick: '主播 $roomId',
      cover: 'https://example.com/cover-$roomId.jpg',
    );

LiveHistoryEntry _entry(
  String roomId, {
  String platform = 'bilibili',
  String title = '',
  String nick = '',
  DateTime? at,
}) => LiveHistoryEntry(
  platform: platform,
  roomId: roomId,
  title: title.isEmpty ? '标题 $roomId' : title,
  nick: nick.isEmpty ? '主播 $roomId' : nick,
  cover: 'https://example.com/cover-$roomId.jpg',
  at: (at ?? DateTime(2026, 11, 16, 10)).millisecondsSinceEpoch,
);

/// Fake adapter for status refresh: canned live rooms, throwable
/// rooms, and rooms that never answer (to exercise the timeout).
class FakeStatusSite extends LiveSite {
  FakeStatusSite({
    this.liveIds = const {},
    this.throwIds = const {},
    this.hangIds = const {},
  });

  @override
  final String id = 'fake';

  @override
  final String name = 'Fake';

  final Set<String> liveIds;
  final Set<String> throwIds;
  final Set<String> hangIds;

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async {
    if (hangIds.contains(room.roomId)) {
      await Future.delayed(const Duration(seconds: 30));
    }
    if (throwIds.contains(room.roomId)) throw Exception('boom');
    return room.copyWith(liveStatus: liveIds.contains(room.roomId));
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init(prefix: 'hao-live-hist-test-');
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  tearDown(() {
    Get.reset();
  });

  /// Hive writes are real disk I/O: awaiting them inside the
  /// fake-async zone never resolves. Run them on the real clock.
  /// Plain `test`s run on the real clock already, so they delete
  /// directly; widget tests go through these helpers.
  Future<void> clearHistoryKeys() async {
    await HiveStore.delete(HiveKeys.liveHistory);
    await HiveStore.delete(HiveKeys.liveHistoryLimit);
  }

  Future<void> resetHistory(WidgetTester tester) =>
      tester.runAsync(clearHistoryKeys);

  Future<void> recordHistory(WidgetTester tester, LiveHistoryEntry e) =>
      tester.runAsync(() => LiveHistoryStore.recordEntry(e));

  /// Drain the Dio receive-timeout timers left by RefererImage cover
  /// fetches (10 s). The cards fetch real poster URLs that never
  /// answer in a widget test, so the timeout Timer stays pending on
  /// the fake clock and the binding fails the test at the end ("A
  /// Timer is still pending"). Must run inside the test body.
  Future<void> drainImageTimers(WidgetTester tester) =>
      pumpFor(tester, const Duration(seconds: 11));

  group('LiveHistoryStore', () {
    test('record dedups and moves re-entry to the front', () async {
      await clearHistoryKeys();
      await LiveHistoryStore.record(_room('1'));
      await LiveHistoryStore.record(_room('2'));
      await LiveHistoryStore.record(
        _room('1').copyWith(title: '新标题'),
      );
      final all = LiveHistoryStore.getAll();
      expect(all.length, 2);
      expect(all.first.roomId, '1');
      expect(all.first.title, '新标题');
    });

    test('grouped splits today / yesterday / 2-6 days / earlier', () {
      final now = DateTime(2026, 11, 16, 12);
      final entries = [
        _entry('today', at: DateTime(2026, 11, 16, 9)),
        _entry('yest', at: DateTime(2026, 11, 15, 9)),
        _entry('recent', at: DateTime(2026, 11, 12, 9)),
        _entry('old', at: DateTime(2026, 11, 1, 9)),
      ];
      final groups = LiveHistoryStore.grouped(entries, now: now);
      expect(groups.length, 4);
      expect(groups[0].$1, LiveHistorySection.today);
      expect(groups[0].$2.single.roomId, 'today');
      expect(groups[1].$1, LiveHistorySection.yesterday);
      expect(groups[2].$1, LiveHistorySection.recent);
      expect(groups[3].$1, LiveHistorySection.earlier);
    });

    test('filter matches title / anchor / roomId / platform', () {
      final entries = [
        _entry('100', title: '英雄联盟'),
        _entry('200', nick: '小明'),
        _entry('300', platform: 'douyu'),
      ];
      expect(
        LiveHistoryStore.filter(entries, '英雄').map((e) => e.roomId),
        ['100'],
      );
      expect(
        LiveHistoryStore.filter(entries, '小明').map((e) => e.roomId),
        ['200'],
      );
      expect(
        LiveHistoryStore.filter(entries, '300').map((e) => e.roomId),
        ['300'],
      );
      expect(
        LiveHistoryStore.filter(entries, 'douyu').map((e) => e.roomId),
        ['300'],
      );
      expect(LiveHistoryStore.filter(entries, '').length, 3);
    });

    test('remove deletes one entry, clear deletes all', () async {
      await clearHistoryKeys();
      await LiveHistoryStore.record(_room('1'));
      await LiveHistoryStore.record(_room('2'));
      await LiveHistoryStore.remove('bilibili', '1');
      expect(
        LiveHistoryStore.getAll().map((e) => e.roomId),
        ['2'],
      );
      await LiveHistoryStore.clear();
      expect(LiveHistoryStore.getAll(), isEmpty);
    });

    test('limit: shrink deletes oldest, unlimited keeps all', () async {
      await clearHistoryKeys();
      expect(LiveHistoryStore.limit, LiveHistoryStore.defaultLimit);
      await LiveHistoryStore.record(_room('1'));
      await LiveHistoryStore.record(_room('2'));
      await LiveHistoryStore.record(_room('3'));
      expect(LiveHistoryStore.wouldDeleteCount(2), 1);
      expect(LiveHistoryStore.wouldDeleteCount(0), 0);
      final deleted = await LiveHistoryStore.setLimit(2);
      expect(deleted, 1);
      expect(
        LiveHistoryStore.getAll().map((e) => e.roomId),
        ['3', '2'],
      );
      await LiveHistoryStore.setLimit(0);
      await LiveHistoryStore.record(_room('4'));
      expect(LiveHistoryStore.getAll().length, 3);
    });
  });

  group('refreshRoomStatuses', () {
    test('live / offline / throw / timeout -> unknown, never stale-live',
        () async {
      final rooms = [
        _room('live'),
        _room('off'),
        _room('boom'),
        _room('hang'),
      ];
      final statuses = await refreshRoomStatuses(
        rooms,
        siteOf: (_) => FakeStatusSite(
          liveIds: {'live'},
          throwIds: {'boom'},
          hangIds: {'hang'},
        ),
        perItemTimeout: const Duration(milliseconds: 100),
      );
      expect(statuses['bilibili|live'], LiveStatus.live);
      expect(statuses['bilibili|off'], LiveStatus.offline);
      expect(statuses['bilibili|boom'], LiveStatus.unknown);
      expect(statuses['bilibili|hang'], LiveStatus.unknown);
    });
  });

  group('LiveHistoryPage', () {
    Future<void> pumpHistory(
      WidgetTester tester, {
      LiveSite Function(String)? siteOf,
      List<String> opened = const [],
    }) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveHistoryPage(
            siteOf: siteOf,
            onOpenRoom: (entry) => opened.add(entry.roomId),
          ),
        ),
      );
      await tester.pump();
    }

    testWidgets('groups entries by day, newest first', (tester) async {
      final now = DateTime.now();
      await resetHistory(tester);
      await recordHistory(
        tester,
        _entry('old', at: now.subtract(const Duration(days: 10))),
      );
      await recordHistory(
        tester,
        _entry('today', at: now.subtract(const Duration(hours: 1))),
      );
      await recordHistory(
        tester,
        _entry('yest', at: now.subtract(const Duration(days: 1))),
      );
      await pumpHistory(tester);

      expect(find.text('今天'), findsOneWidget);
      expect(find.text('昨天'), findsOneWidget);
      expect(find.text('更早'), findsOneWidget);
      expect(find.text('标题 today'), findsOneWidget);
      expect(find.text('标题 yest'), findsOneWidget);
      expect(find.text('标题 old'), findsOneWidget);
      await drainImageTimers(tester);
    });

    testWidgets('filter box narrows by anchor', (tester) async {
      await resetHistory(tester);
      await recordHistory(tester, _entry('1', nick: '小明'));
      await recordHistory(tester, _entry('2', nick: '小红'));
      await pumpHistory(tester);

      await tester.enterText(find.byType(TextField), '小明');
      await tester.pump();
      expect(find.text('小明 · 哔哩哔哩'), findsOneWidget);
      expect(find.text('小红 · 哔哩哔哩'), findsNothing);
      await drainImageTimers(tester);
    });

    testWidgets('single delete removes only that card', (tester) async {
      await resetHistory(tester);
      await recordHistory(tester, _entry('1'));
      await recordHistory(tester, _entry('2'));
      await pumpHistory(tester);

      // Newest first: the first card is entry 2. The delete handler
      // awaits the Hive remove; drain the whole queue (a single
      // settle only drains one queued write and leaves the rest to
      // poison the next test) — the page's setState after `await
      // remove()` only runs once the write completes.
      await tester.tap(find.byIcon(Icons.close).first);
      await drainHiveWrites(tester);
      expect(LiveHistoryStore.getAll().length, 1);
      expect(find.text('标题 2'), findsNothing);
      expect(find.text('标题 1'), findsOneWidget);
      await drainImageTimers(tester);
    });

    testWidgets('clear-all confirms then empties', (tester) async {
      await resetHistory(tester);
      await recordHistory(tester, _entry('1'));
      await pumpHistory(tester);

      await tester.tap(find.byIcon(Icons.delete_outline));
      await tester.pump();
      expect(find.text('清空直播历史？'), findsOneWidget);
      await tester.tap(find.text('清空'));
      await drainHiveWrites(tester);
      expect(find.text('还没有直播观看记录'), findsOneWidget);
      expect(LiveHistoryStore.getAll(), isEmpty);
      await drainImageTimers(tester);
    });

    testWidgets('refresh shows LIVE / 已下播 / 状态未知', (tester) async {
      await resetHistory(tester);
      await recordHistory(tester, _entry('live'));
      await recordHistory(tester, _entry('off'));
      await recordHistory(tester, _entry('boom'));
      await pumpHistory(
        tester,
        siteOf: (_) => FakeStatusSite(
          liveIds: {'live'},
          throwIds: {'boom'},
        ),
      );

      await tester.tap(find.byIcon(Icons.refresh));
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.text('LIVE'), findsOneWidget);
      expect(find.text('已下播'), findsOneWidget);
      expect(find.text('状态未知'), findsOneWidget);
      expect(find.text('1 个状态获取失败'), findsOneWidget);
      await drainImageTimers(tester);
    });

    testWidgets('empty state is honest', (tester) async {
      await resetHistory(tester);
      await pumpHistory(tester);
      expect(find.text('还没有直播观看记录'), findsOneWidget);
    });

    testWidgets('tapping a card opens the room', (tester) async {
      final opened = <String>[];
      await resetHistory(tester);
      await recordHistory(tester, _entry('1'));
      await pumpHistory(tester, opened: opened);

      await tester.tap(find.text('标题 1'));
      await tester.pump();
      expect(opened, ['1']);
      await drainImageTimers(tester);
    });
  });
}
