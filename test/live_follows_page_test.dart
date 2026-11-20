// Follow page tests (L03).
//
// - Tabs show live / not-live counts; tapping a tab re-refreshes.
// - Platform chips: 全部 + each platform that has follows; chip
//   filters the list.
// - No replay tab: replay data does not exist yet, so the tab must
//   not be faked.
// - Per-group empty states carry a "去逛逛" action.
// - Unfollow removes the follow; tapping a card opens the room.
// - A failed status check is 状态未知 and never counted as live.

import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/live_follow_store.dart';
import 'package:standalone/domains/live/presentation/live_follows_page.dart';
import 'package:standalone/shared/platforms/live_site.dart';

import 'helpers/hive_test_setup.dart';

LiveRoom _room(String roomId, {String platform = 'bilibili'}) => LiveRoom(
  roomId: roomId,
  platform: platform,
  title: '标题 $roomId',
  nick: '主播 $roomId',
  cover: 'https://example.com/cover-$roomId.jpg',
);

/// Fake adapter: canned live rooms + throwable rooms.
class FakeStatusSite extends LiveSite {
  FakeStatusSite({this.liveIds = const {}, this.throwIds = const {}});

  @override
  final String id = 'fake';

  @override
  final String name = 'Fake';

  final Set<String> liveIds;
  final Set<String> throwIds;

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async {
    if (throwIds.contains(room.roomId)) throw Exception('boom');
    return room.copyWith(liveStatus: liveIds.contains(room.roomId));
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    hiveDir = await HiveTestSetup.init(prefix: 'hao-live-follow-test-');
  });

  tearDownAll(() async {
    await HiveTestSetup.dispose(hiveDir);
  });

  tearDown(() {
    Get.reset();
  });

  /// Hive writes are real disk I/O: they hang inside the fake-async
  /// zone, so run them on the real clock. The in-memory box updates
  /// synchronously, but the returned Future only resolves on real
  /// time — awaiting it in the test body stalls the test.
  Future<void> addFollow(WidgetTester tester, LiveRoom room) =>
      tester.runAsync(() => LiveFollowStore.add(room));

  /// Per-test isolation: the store persists across tests in the same
  /// file, and counts/chips assert exact numbers. Clear on the real
  /// clock at the start of every test that seeds follows.
  Future<void> resetFollows(WidgetTester tester) =>
      tester.runAsync(() => HiveStore.delete(HiveKeys.liveFollows));

  Future<void> pumpFollows(
    WidgetTester tester, {
    required FakeStatusSite site,
    List<String> opened = const [],
    List<bool> browsed = const [],
  }) async {
    await tester.pumpWidget(
      GetMaterialApp(
        theme: HaoThemes.of(HaoThemeId.appleGlass).light,
        home: LiveFollowsPage(
          siteOf: (_) => site,
          onOpenRoom: (follow) => opened.add(follow.roomId),
          onBrowse: () => browsed.add(true),
        ),
      ),
    );
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
  }

  testWidgets('tabs show live / not-live counts', (tester) async {
    await resetFollows(tester);
    await addFollow(tester, _room('live'));
    await addFollow(tester, _room('off'));
    await pumpFollows(
      tester,
      site: FakeStatusSite(liveIds: {'live'}),
    );

    expect(find.text('已开播 (1)'), findsOneWidget);
    expect(find.text('未开播 (1)'), findsOneWidget);
    // Live tab is selected by default: only the live room shows.
    expect(find.text('标题 live'), findsOneWidget);
    expect(find.text('标题 off'), findsNothing);
  });

  testWidgets('tapping the not-live tab shows offline follows',
      (tester) async {
    await resetFollows(tester);
    await addFollow(tester, _room('live'));
    await addFollow(tester, _room('off'));
    await pumpFollows(
      tester,
      site: FakeStatusSite(liveIds: {'live'}),
    );

    await tester.tap(find.text('未开播 (1)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('标题 off'), findsOneWidget);
    expect(find.text('标题 live'), findsNothing);
  });

  testWidgets('tapping a tab re-refreshes statuses', (tester) async {
    await resetFollows(tester);
    await addFollow(tester, _room('a'));
    final site = FakeStatusSite(liveIds: {});
    await pumpFollows(tester, site: site);
    expect(find.text('已开播 (0)'), findsOneWidget);

    // The room goes live; tapping the tab re-checks and the count moves.
    site.liveIds.add('a');
    await tester.tap(find.text('已开播 (0)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('已开播 (1)'), findsOneWidget);
    expect(find.text('标题 a'), findsOneWidget);
  });

  testWidgets('platform chips filter the list', (tester) async {
    await resetFollows(tester);
    await addFollow(tester, _room('b1', platform: 'bilibili'));
    await addFollow(tester, _room('d1', platform: 'douyu'));
    await pumpFollows(
      tester,
      site: FakeStatusSite(liveIds: {'b1', 'd1'}),
    );

    expect(find.text('全部'), findsOneWidget);
    expect(find.text('哔哩哔哩 (1)'), findsOneWidget);
    expect(find.text('斗鱼 (1)'), findsOneWidget);

    await tester.tap(find.text('斗鱼 (1)'));
    await tester.pump();
    expect(find.text('标题 d1'), findsOneWidget);
    expect(find.text('标题 b1'), findsNothing);
  });

  testWidgets('no replay tab is faked', (tester) async {
    await resetFollows(tester);
    await addFollow(tester, _room('live'));
    await pumpFollows(
      tester,
      site: FakeStatusSite(liveIds: {'live'}),
    );
    expect(find.textContaining('录播'), findsNothing);
    expect(find.textContaining('回放'), findsNothing);
  });

  testWidgets('failed check is unknown, never counted as live',
      (tester) async {
    await resetFollows(tester);
    await addFollow(tester, _room('boom'));
    await pumpFollows(
      tester,
      site: FakeStatusSite(throwIds: {'boom'}),
    );

    expect(find.text('已开播 (0)'), findsOneWidget);
    expect(find.text('未开播 (1)'), findsOneWidget);
    await tester.tap(find.text('未开播 (1)'));
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 100));
    expect(find.text('状态未知'), findsOneWidget);
    expect(find.text('1 个状态获取失败'), findsOneWidget);
  });

  testWidgets('empty state is honest with a go-browse action',
      (tester) async {
    await resetFollows(tester);
    final browsed = <bool>[];
    await pumpFollows(
      tester,
      site: FakeStatusSite(),
      browsed: browsed,
    );

    expect(find.text('还没有关注的主播'), findsOneWidget);
    expect(find.text('去逛逛'), findsOneWidget);
    await tester.tap(find.text('去逛逛'));
    expect(browsed, [true]);
  });

  testWidgets('per-group empty state when nobody is live',
      (tester) async {
    await resetFollows(tester);
    await addFollow(tester, _room('off'));
    await pumpFollows(
      tester,
      site: FakeStatusSite(),
    );

    expect(find.text('没有正在开播的关注'), findsOneWidget);
    expect(find.text('去逛逛'), findsOneWidget);
  });

  testWidgets('unfollow removes the follow, card tap opens the room',
      (tester) async {
    final opened = <String>[];
    await resetFollows(tester);
    await addFollow(tester, _room('live'));
    await pumpFollows(
      tester,
      site: FakeStatusSite(liveIds: {'live'}),
      opened: opened,
    );

    await tester.tap(find.text('标题 live'));
    await tester.pump();
    expect(opened, ['live']);

    await tester.tap(find.byIcon(Icons.favorite).first);
    // The unfollow handler awaits the Hive remove; drain the whole
    // queue — a single settle only drains one queued write and the
    // remove is issued on the last pump, after the settle's real-zone
    // yield, so it would otherwise poison the next test.
    await drainHiveWrites(tester);
    expect(LiveFollowStore.getAll(), isEmpty);
    expect(find.text('还没有关注的主播'), findsOneWidget);
  });

  test('follow store: add / toggle / platforms', () async {
    await HiveStore.delete(HiveKeys.liveFollows);
    expect(LiveFollowStore.isFollowed('bilibili', '1'), isFalse);
    expect(await LiveFollowStore.toggle(_room('1')), isTrue);
    expect(await LiveFollowStore.toggle(_room('1')), isFalse);
    // Plain test: real clock here, direct awaits are fine.
    await LiveFollowStore.add(_room('b1', platform: 'bilibili'));
    await LiveFollowStore.add(_room('d1', platform: 'douyu'));
    expect(LiveFollowStore.followedPlatforms(), ['douyu', 'bilibili']);
    await LiveFollowStore.remove('douyu', 'd1');
    expect(
      LiveFollowStore.getAll().map((f) => f.roomId),
      ['b1'],
    );
  });
}
