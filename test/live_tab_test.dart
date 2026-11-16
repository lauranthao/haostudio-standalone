// Live tab tests — the tab's data layer driven by fake LiveSite
// implementations (no network, no real adapters).
//
// Covered:
// - First load: rooms + categories land, status ready, hasMore math.
// - Pagination: pages append, short page ends the list, concurrent
//   loadMore calls collapse to one fetch, a failed page keeps the rooms
//   already shown and offers a retry.
// - Platform switch: resets rooms/page and fetches the new platform.
// - Honest states: empty list -> empty (never fake rooms); first-page
//   failure -> error with a retry that can succeed; a categories
//   failure never fails the room list.
// - Stale-response guard: a slow platform-A response arriving after a
//   switch to B never overwrites B's rooms.
// - Category select switches the source to getCategoryRooms; "全部"
//   returns to the recommend list.
// - Widget: the grid renders real rooms (title / nick / watching /
//   LIVE badge), and the empty / error states render with a retry.

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
import 'package:standalone/domains/live/presentation/live_tab_controller.dart';
import 'package:standalone/domains/live/presentation/live_tab_page.dart';
import 'package:standalone/shared/platforms/live_site.dart';

LiveRoom fakeRoom(
  int i, {
  String platform = 'fake',
  int watching = 12345,
  bool liveStatus = true,
}) =>
    LiveRoom(
      roomId: 'room-$i',
      platform: platform,
      title: '直播间 $i',
      nick: '主播 $i',
      cover: 'https://example.com/cover-$i.jpg',
      watching: watching,
      liveStatus: liveStatus,
    );

/// Controllable fake adapter: canned pages per method, call tracking,
/// and injectable failures / async hooks.
class FakeLiveSite extends LiveSite {
  FakeLiveSite({
    this.id = 'fake',
    this.name = 'Fake',
    Map<int, List<LiveRoom>>? recommendPages,
    Map<String, Map<int, List<LiveRoom>>>? categoryPages,
    List<LiveArea>? categories,
    Set<int>? failRecommendPages,
    this.failCategories = false,
    this.recommendHook,
  })  : _recommendPages = recommendPages ?? {},
        _categoryPages = categoryPages ?? {},
        _categories = categories ?? const [],
        failRecommendPages = failRecommendPages ?? {};

  @override
  final String id;

  @override
  final String name;

  final Map<int, List<LiveRoom>> _recommendPages;
  final Map<String, Map<int, List<LiveRoom>>> _categoryPages;
  final List<LiveArea> _categories;

  /// Mutable so tests can fail a page, then let it succeed on retry.
  final Set<int> failRecommendPages;
  final bool failCategories;
  final Future<List<LiveRoom>> Function(int page)? recommendHook;

  /// Test-only: replace one canned recommend page.
  void setRecommendPage(int page, List<LiveRoom> rooms) {
    _recommendPages[page] = rooms;
  }

  /// Test-only: drop one canned recommend page (the adapter then returns []).
  void clearRecommendPage(int page) {
    _recommendPages.remove(page);
  }

  final List<int> recommendCalls = [];
  final List<(String, int)> categoryCalls = [];
  final List<int> categoriesCalls = [];

  @override
  Future<List<LiveRoom>> getRecommendRooms({
    int page = 1,
    int pageSize = 30,
  }) async {
    recommendCalls.add(page);
    final hook = recommendHook;
    if (hook != null) return hook(page);
    if (failRecommendPages.contains(page)) {
      throw StateError('recommend page $page failed');
    }
    return _recommendPages[page] ?? const <LiveRoom>[];
  }

  @override
  Future<List<LiveArea>> getCategories({
    int page = 1,
    int pageSize = 30,
  }) async {
    categoriesCalls.add(page);
    if (failCategories) throw StateError('categories failed');
    return _categories;
  }

  @override
  Future<List<LiveRoom>> getCategoryRooms(
    LiveArea area, {
    int page = 1,
    int pageSize = 30,
  }) async {
    categoryCalls.add((area.areaId, page));
    return _categoryPages[area.areaId]?[page] ?? const <LiveRoom>[];
  }
}

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-live-tab-test-');
    // HiveStore.init() goes through path_provider; point it at a temp
    // dir so the live tab page (follow/history stores) can use Hive.
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
    // Memory-backed box for the whole file: a Hive file write issued
    // inside a widget test's fake-async zone never completes within
    // that test, so fire-and-forget writes wedge hive_ce's serialized
    // write lock and the NEXT test's Hive put hangs forever.
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

  tearDown(() {
    Get.reset();
  });

  group('LiveTabController — first load', () {
    test('rooms + categories land, status ready, full page means more', () async {
      final site = FakeLiveSite(
        recommendPages: {
          1: List.generate(30, (i) => fakeRoom(i)),
        },
        categories: const [
          LiveArea(areaId: 'g1', areaName: '英雄联盟'),
        ],
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      expect(controller.status, LiveTabStatus.loading);
      await controller.loadInitial();

      expect(controller.status, LiveTabStatus.ready);
      expect(controller.rooms.length, 30);
      expect(controller.rooms.first.title, '直播间 0');
      expect(controller.hasMore, isTrue);
      expect(controller.categories.map((a) => a.areaName), ['英雄联盟']);
      expect(site.recommendCalls, [1]);
    });

    test('empty recommend list is an honest empty state, never fake rooms',
        () async {
      final site = FakeLiveSite();
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await controller.loadInitial();

      expect(controller.status, LiveTabStatus.empty);
      expect(controller.rooms, isEmpty);
      expect(controller.hasMore, isFalse);
    });

    test('first-page failure is an error state; retry can succeed', () async {
      final site = FakeLiveSite(
        recommendPages: {
          1: [fakeRoom(1)],
        },
        failRecommendPages: {1},
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await controller.loadInitial();
      expect(controller.status, LiveTabStatus.error);
      expect(controller.errorMessage, isNotNull);
      expect(controller.rooms, isEmpty);

      site.failRecommendPages.remove(1);
      await controller.retry();
      expect(controller.status, LiveTabStatus.ready);
      expect(controller.rooms.length, 1);
    });

    test('a categories failure never fails the room list', () async {
      final site = FakeLiveSite(
        recommendPages: {
          1: [fakeRoom(1)],
        },
        failCategories: true,
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await controller.loadInitial();

      expect(controller.status, LiveTabStatus.ready);
      expect(controller.rooms.length, 1);
      expect(controller.categories, isEmpty);
    });
  });

  group('LiveTabController — pagination', () {
    test('pages append; a short page ends the list; no fetch after the end',
        () async {
      final site = FakeLiveSite(
        recommendPages: {
          1: List.generate(30, (i) => fakeRoom(i)),
          2: List.generate(5, (i) => fakeRoom(100 + i)),
        },
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await controller.loadInitial();
      expect(controller.hasMore, isTrue);

      await controller.loadMore();
      expect(controller.rooms.length, 35);
      expect(controller.rooms.last.roomId, 'room-104');
      expect(controller.hasMore, isFalse);

      await controller.loadMore();
      expect(site.recommendCalls, [1, 2]);
    });

    test('concurrent loadMore calls collapse to one fetch', () async {
      final page2 = Completer<List<LiveRoom>>();
      var hookCalls = 0;
      final site = FakeLiveSite(
        recommendPages: {
          1: List.generate(30, (i) => fakeRoom(i)),
        },
        recommendHook: (page) async {
          if (page == 1) {
            return List.generate(30, (i) => fakeRoom(i));
          }
          hookCalls++;
          return page2.future;
        },
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await controller.loadInitial();
      final first = controller.loadMore();
      final second = controller.loadMore();
      page2.complete([fakeRoom(99)]);
      await Future.wait([first, second]);

      expect(hookCalls, 1);
      expect(controller.rooms.length, 31);
      expect(controller.loadingMore, isFalse);
    });

    test('a failed page keeps the rooms shown and offers a retry', () async {
      final site = FakeLiveSite(
        recommendPages: {
          1: List.generate(30, (i) => fakeRoom(i)),
          2: [fakeRoom(99)],
        },
        failRecommendPages: {2},
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await controller.loadInitial();
      await controller.loadMore();

      expect(controller.status, LiveTabStatus.ready);
      expect(controller.rooms.length, 30);
      expect(controller.loadMoreFailed, isTrue);
      expect(controller.hasMore, isTrue);

      site.failRecommendPages.remove(2);
      await controller.loadMore();
      expect(controller.loadMoreFailed, isFalse);
      expect(controller.rooms.length, 31);
      expect(controller.hasMore, isFalse);
    });

    test('loadMore is a no-op before the first page is ready', () async {
      final site = FakeLiveSite(
        recommendPages: {
          1: [fakeRoom(1)],
        },
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      // Status is loading and hasMore is false: nothing to page through.
      await controller.loadMore();
      expect(site.recommendCalls, isEmpty);
    });
  });

  group('LiveTabController — platform + category switching', () {
    test('switching platform resets rooms/page and fetches the new one',
        () async {
      final siteA = FakeLiveSite(
        id: 'a',
        recommendPages: {
          1: List.generate(30, (i) => fakeRoom(i, platform: 'a')),
          2: [fakeRoom(99, platform: 'a')],
        },
      );
      final siteB = FakeLiveSite(
        id: 'b',
        recommendPages: {
          1: [fakeRoom(1, platform: 'b')],
        },
      );
      final controller = LiveTabController(
        siteOf: (id) => id == 'a' ? siteA : siteB,
        initialPlatform: 'a',
      );
      addTearDown(controller.dispose);

      await controller.loadInitial();
      await controller.loadMore();
      expect(controller.rooms.length, 31);

      await controller.selectPlatform('b');
      expect(controller.platform, 'b');
      expect(controller.rooms.length, 1);
      expect(controller.rooms.first.platform, 'b');
      expect(controller.hasMore, isFalse);
      expect(siteB.recommendCalls, [1]);
      // A was never asked for a fresh page 1 after the switch.
      expect(siteA.recommendCalls, [1, 2]);
    });

    test('selecting the current platform is a no-op', () async {
      final site = FakeLiveSite(
        recommendPages: {
          1: [fakeRoom(1)],
        },
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await controller.loadInitial();
      await controller.selectPlatform('fake');
      expect(site.recommendCalls, [1]);
    });

    test('a slow response from the old platform never overwrites the new one',
        () async {
      final slowCompleter = Completer<List<LiveRoom>>();
      final slow = FakeLiveSite(
        recommendHook: (_) => slowCompleter.future,
      );
      final fast = FakeLiveSite(
        recommendPages: {
          1: [fakeRoom(1)],
        },
      );
      final controller = LiveTabController(
        siteOf: (id) => id == 'a' ? slow : fast,
        initialPlatform: 'a',
      );
      addTearDown(controller.dispose);

      final firstLoad = controller.loadInitial();
      await controller.selectPlatform('b');
      expect(controller.rooms.map((r) => r.roomId), ['room-1']);

      slowCompleter.complete([fakeRoom(99)]);
      await firstLoad;
      await Future<void>.delayed(Duration.zero);

      expect(controller.platform, 'b');
      expect(controller.rooms.map((r) => r.roomId), ['room-1']);
    });

    test('category select switches the source; 全部 returns to recommend',
        () async {
      const area = LiveArea(areaId: 'g1', areaName: '英雄联盟');
      final site = FakeLiveSite(
        recommendPages: {
          1: [fakeRoom(1)],
        },
        categories: const [area],
        categoryPages: {
          'g1': {
            1: [fakeRoom(7), fakeRoom(8)],
          },
        },
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await controller.loadInitial();
      expect(controller.categories.length, 1);

      await controller.selectCategory(area);
      expect(controller.selectedArea?.areaId, 'g1');
      expect(site.categoryCalls, [('g1', 1)]);
      expect(controller.rooms.map((r) => r.roomId), ['room-7', 'room-8']);

      await controller.selectCategory(null);
      expect(controller.selectedArea, isNull);
      expect(site.recommendCalls, [1, 1]);
      expect(controller.rooms.map((r) => r.roomId), ['room-1']);
    });
  });

  group('formatWatching', () {
    test('formats counts', () {
      expect(formatWatching(0), '0');
      expect(formatWatching(999), '999');
      expect(formatWatching(9999), '9999');
      expect(formatWatching(10000), '1.0万');
      expect(formatWatching(12345), '1.2万');
      expect(formatWatching(1234567), '123.5万');
    });
  });

  group('LiveTabPage widget', () {
    Future<void> pumpTab(
      WidgetTester tester,
      LiveTabController controller,
    ) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveTabPage(controller: controller),
        ),
      );
    }

    testWidgets('renders real rooms with title, nick, watching and LIVE badge',
        (tester) async {
      final site = FakeLiveSite(
        recommendPages: {
          1: [fakeRoom(1), fakeRoom(2, watching: 500, liveStatus: false)],
        },
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await pumpTab(tester, controller);
      await tester.pumpAndSettle();

      expect(find.text('直播间 1'), findsOneWidget);
      expect(find.text('主播 1'), findsOneWidget);
      expect(find.text('1.2万'), findsOneWidget);
      expect(find.text('500'), findsOneWidget);
      // Only the live room carries the badge.
      expect(find.text('LIVE'), findsOneWidget);
      // Platform chips for the Big-5 are present.
      expect(find.text('虎牙'), findsOneWidget);
      expect(find.text('哔哩哔哩'), findsOneWidget);
    });

    testWidgets('shows the skeleton while loading, then the rooms',
        (tester) async {
      final completer = Completer<List<LiveRoom>>();
      final site = FakeLiveSite(recommendHook: (_) => completer.future);
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await pumpTab(tester, controller);
      await tester.pump();

      expect(find.text('直播间 1'), findsNothing);
      // The skeleton grid is on screen (a GridView with no room text).
      expect(find.byType(GridView), findsOneWidget);

      completer.complete([fakeRoom(1)]);
      await tester.pumpAndSettle();
      expect(find.text('直播间 1'), findsOneWidget);
    });

    testWidgets('empty state is honest and retry reloads', (tester) async {
      final site = FakeLiveSite(
        recommendPages: {
          1: [fakeRoom(1)],
        },
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await pumpTab(tester, controller);
      await tester.pumpAndSettle();
      expect(find.text('直播间 1'), findsOneWidget);

      // The platform stops returning rooms: a refresh lands on an
      // honest empty state — never on stale or fake rooms.
      site.clearRecommendPage(1);
      await controller.refresh();
      await tester.pumpAndSettle();
      expect(find.text('暂无直播间'), findsOneWidget);
      expect(find.text('直播间 1'), findsNothing);

      // The 重新加载 button brings the rooms back once they return.
      site.setRecommendPage(1, [fakeRoom(1)]);
      await tester.tap(find.text('重新加载'));
      await tester.pumpAndSettle();
      expect(find.text('直播间 1'), findsOneWidget);
    });

    testWidgets('error state offers a retry that can succeed', (tester) async {
      final site = FakeLiveSite(
        recommendPages: {
          1: [fakeRoom(1)],
        },
        failRecommendPages: {1},
      );
      final controller = LiveTabController(
        siteOf: (_) => site,
        initialPlatform: 'fake',
      );
      addTearDown(controller.dispose);

      await pumpTab(tester, controller);
      await tester.pumpAndSettle();

      expect(find.text('加载失败'), findsOneWidget);
      expect(find.text('重试'), findsOneWidget);

      site.failRecommendPages.remove(1);
      await tester.tap(find.text('重试'));
      await tester.pumpAndSettle();

      expect(find.text('直播间 1'), findsOneWidget);
    });

    testWidgets('tapping a platform chip re-fetches for that platform',
        (tester) async {
      final siteA = FakeLiveSite(
        recommendPages: {
          1: [fakeRoom(1, platform: 'bilibili')],
        },
      );
      final siteB = FakeLiveSite(
        recommendPages: {
          1: [fakeRoom(2, platform: 'huya')],
        },
      );
      final controller = LiveTabController(
        siteOf: (id) => id == 'bilibili' ? siteA : siteB,
        initialPlatform: 'bilibili',
      );
      addTearDown(controller.dispose);

      await pumpTab(tester, controller);
      await tester.pumpAndSettle();
      expect(find.text('直播间 1'), findsOneWidget);

      await tester.tap(find.text('虎牙'));
      await tester.pumpAndSettle();
      expect(find.text('直播间 2'), findsOneWidget);
      expect(find.text('直播间 1'), findsNothing);
    });
  });
}
