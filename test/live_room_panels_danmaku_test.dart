// Live-room panels + danmaku P0 (L04, L05, S2, S3, S4).
//
// Unit tests (pure, no widgets):
// - partialRatio / similarity filter (near-duplicate punctuation and
//   number variants hidden, different text shown, cache expiry).
// - Pure-emoji / overlong / Douyu suspected-automated / keyword and
//   username blocks, incl. the block store's add/remove/dedupe.
// - Deep links for all five platforms + the open fallback order.
// - Douyu transport tags suspected-automated chatmsg packets
//   (Pure Live's rule: no `dms` and `if` != '1').
//
// Widget tests (fakes only, no network):
// - S2: line spacing + show-username take effect in the open room;
//   card style renders cards.
// - S4: tap highlights an item; long-press menu blocks the user /
//   the message in place.
// - L04: switch panel opens with its groups; tapping a room in the
//   current list switches to it.
// - L05: detail sheet opens; follow toggles; room number + copy /
//   share / open-in-App rows are present.

import 'dart:async';
import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/player/kernel/player_backend.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/live_follow_store.dart';
import 'package:standalone/domains/live/live_history_store.dart';
import 'package:standalone/domains/live/presentation/playback/danmaku_block_store.dart';
import 'package:standalone/domains/live/presentation/playback/danmaku_filter.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_links.dart';
import 'package:standalone/domains/live/presentation/playback/live_room_page.dart';
import 'package:standalone/features/settings/source_stores.dart';
import 'package:standalone/shared/platforms/douyu/douyu_danmaku.dart';
import 'package:standalone/shared/platforms/live_site.dart';

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-panels-test-');
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

  tearDown(() {
    Get.reset();
  });

  // -- S3: similarity -------------------------------------------------

  group('partialRatio', () {
    test('identical texts score 100', () {
      expect(partialRatio('hello world', 'hello world'), 100);
    });

    test('punctuation variant scores at/above the default threshold', () {
      expect(partialRatio('666', '666!!!'), greaterThanOrEqualTo(85));
      expect(partialRatio('主播好帅', '主播好帅！！'), greaterThanOrEqualTo(85));
    });

    test('number variant scores at/above the default threshold', () {
      expect(partialRatio('666', '6666'), greaterThanOrEqualTo(85));
    });

    test('unrelated texts score low', () {
      expect(partialRatio('hello world', 'goodbye moon'), lessThan(50));
    });

    test('two empty texts score 0', () {
      expect(partialRatio('', ''), 0);
    });
  });

  group('DanmakuSimilarityFilter', () {
    test('exact repeat hidden, different text shown', () {
      final filter = DanmakuSimilarityFilter();
      expect(filter.shouldDisplay('hello'), isTrue);
      expect(filter.shouldDisplay('hello'), isFalse);
      expect(filter.shouldDisplay('something else entirely'), isTrue);
    });

    test('punctuation / number variant hidden within the cache window', () {
      final filter = DanmakuSimilarityFilter();
      expect(filter.shouldDisplay('666'), isTrue);
      expect(filter.shouldDisplay('666!!!'), isFalse);
      expect(filter.shouldDisplay('6666'), isFalse);
    });

    test('repeat shown again after the cache expires', () {
      var now = DateTime(2026, 11, 16, 12, 0, 0);
      final filter = DanmakuSimilarityFilter(clock: () => now);
      expect(filter.shouldDisplay('hello'), isTrue);
      expect(filter.shouldDisplay('hello'), isFalse);
      now = now.add(const Duration(seconds: 4));
      expect(filter.shouldDisplay('hello'), isTrue);
    });

    test('empty text never shown', () {
      expect(DanmakuSimilarityFilter().shouldDisplay('   '), isFalse);
    });
  });

  // -- S3: shape + bot + block list -----------------------------------

  group('danmakuTextShape / isPureEmoji', () {
    test('emoji-only true, mixed false', () {
      expect(isPureEmoji('😂😂😂'), isTrue);
      expect(isPureEmoji('😂好笑'), isFalse);
      expect(isPureEmoji('hello'), isFalse);
      expect(isPureEmoji(''), isFalse);
      expect(isPureEmoji('   '), isFalse);
    });

    test('bracketed platform emotes count as emotes', () {
      expect(isPureEmoji('[笑哭]'), isTrue);
      expect(isPureEmoji('[笑哭][doge]'), isTrue);
      expect(isPureEmoji('[笑哭]好笑'), isFalse);
    });

    test('length counts code points', () {
      expect(danmakuTextShape('😂😂').length, 2);
      expect(danmakuTextShape('hello').length, 5);
    });
  });

  group('DanmakuContentFilter', () {
    LiveMessage msg(String text, {String user = 'Alice'}) =>
        LiveMessage(message: text, userName: user);

    test('overlong blocked only when enabled and over the limit', () {
      const long = '这是一条超过三十个字的超长弹幕这是一条超过三十个字的超长弹幕啊';
      expect(long.runes.length, greaterThan(30));
      final off = DanmakuContentFilter(
        config: const DanmakuFilterConfig(),
      );
      expect(off.shouldShow(msg(long), platform: 'huya'), isTrue);
      final on = DanmakuContentFilter(
        config: const DanmakuFilterConfig(
          blockLong: true,
          blockLongLength: 30,
        ),
      );
      expect(on.shouldShow(msg(long), platform: 'huya'), isFalse);
      expect(
        on.shouldShow(msg('short'), platform: 'huya'),
        isTrue,
      );
    });

    test('pure-emoji blocked only when enabled', () {
      final off = DanmakuContentFilter(
        config: const DanmakuFilterConfig(),
      );
      expect(off.shouldShow(msg('😂😂'), platform: 'huya'), isTrue);
      final on = DanmakuContentFilter(
        config: const DanmakuFilterConfig(blockEmoteOnly: true),
      );
      expect(on.shouldShow(msg('😂😂'), platform: 'huya'), isFalse);
      expect(on.shouldShow(msg('😂好笑'), platform: 'huya'), isTrue);
    });

    test('Douyu suspected-automated blocked only on Douyu when enabled', () {
      const tagged = LiveMessage(
        message: 'bot spam',
        userName: 'bot',
        suspectedAutomated: true,
      );
      final on = DanmakuContentFilter(
        config: const DanmakuFilterConfig(
          filterDouyuSuspectedAutomated: true,
        ),
      );
      expect(on.shouldShow(tagged, platform: 'douyu'), isFalse);
      expect(on.shouldShow(tagged, platform: 'huya'), isTrue);
      final off = DanmakuContentFilter(
        config: const DanmakuFilterConfig(),
      );
      expect(off.shouldShow(tagged, platform: 'douyu'), isTrue);
    });

    test('keyword / username blocks are substring matches', () {
      final filter = DanmakuContentFilter(
        config: const DanmakuFilterConfig(
          blockedKeywords: ['spam'],
          blockedUsers: ['Bob'],
        ),
      );
      expect(
        filter.shouldShow(msg('this is spammy'), platform: 'huya'),
        isFalse,
      );
      expect(
        filter.shouldShow(msg('clean', user: 'Bob123'), platform: 'huya'),
        isFalse,
      );
      expect(
        filter.shouldShow(msg('clean', user: 'Alice'), platform: 'huya'),
        isTrue,
      );
    });

    test('super chat: block list applies, similarity does not', () {
      const gift = LiveMessage(
        message: '粉丝荧光棒 ×10',
        userName: 'Alice',
        type: LiveMessageType.superChat,
      );
      final filter = DanmakuContentFilter(
        config: const DanmakuFilterConfig(
          blockedKeywords: ['荧光棒'],
        ),
      );
      expect(filter.shouldShow(gift, platform: 'huya'), isFalse);
      final similar = DanmakuContentFilter(
        config: const DanmakuFilterConfig(
          similarityEnabled: true,
        ),
      );
      expect(similar.shouldShow(gift, platform: 'huya'), isTrue);
      // A repeated gift is NOT hidden by similarity (it repeats on
      // purpose).
      expect(similar.shouldShow(gift, platform: 'huya'), isTrue);
    });
  });

  group('DanmakuBlockStore', () {
    setUp(() async {
      await HiveStore.put(HiveKeys.danmakuBlockList, '[]');
    });

    test('add / dedupe / remove round-trip', () async {
      expect(await DanmakuBlockStore.add('spam', 'word'), isTrue);
      expect(await DanmakuBlockStore.add('spam', 'word'), isFalse);
      expect(await DanmakuBlockStore.add('spam', 'user'), isTrue);
      expect(await DanmakuBlockStore.add('  ', 'word'), isFalse);
      expect(DanmakuBlockStore.keywords(), ['spam']);
      expect(DanmakuBlockStore.usernames(), ['spam']);
      final id = DanmakuBlockStore.getAll().first.id;
      await DanmakuBlockStore.remove(id);
      expect(DanmakuBlockStore.getAll().length, 1);
    });

    test('blocksMessage follows web substring semantics', () async {
      await DanmakuBlockStore.add('spam', 'word');
      await DanmakuBlockStore.add('Bob', 'user');
      expect(
        DanmakuBlockStore.blocksMessage('a spammy line', 'Alice'),
        isTrue,
      );
      expect(
        DanmakuBlockStore.blocksMessage('clean', 'Bob123'),
        isTrue,
      );
      expect(
        DanmakuBlockStore.blocksMessage('clean', 'Alice'),
        isFalse,
      );
    });
  });

  // -- L05: deep links --------------------------------------------------

  group('externalTargetFor', () {
    test('bilibili', () {
      final target = externalTargetFor(
        const LiveRoom(roomId: '12345', platform: 'bilibili'),
      )!;
      expect(target.native, 'bilibili://live/12345');
      expect(target.web, 'https://live.bilibili.com/12345');
    });

    test('douyin uses danmakuData roomId for native, webRid for web', () {
      final target = externalTargetFor(
        const LiveRoom(
          roomId: 'web-rid-1',
          platform: 'douyin',
          danmakuData: {'roomId': '987654321', 'webRid': 'web-rid-1'},
        ),
      )!;
      expect(
        target.native,
        'snssdk1128://webcast_room?room_id=987654321',
      );
      expect(target.web, 'https://live.douyin.com/web-rid-1');
    });

    test('douyin without danmakuData has no native link, web only', () {
      final target = externalTargetFor(
        const LiveRoom(roomId: 'web-rid-1', platform: 'douyin'),
      )!;
      expect(target.native, isNull);
      expect(target.web, 'https://live.douyin.com/web-rid-1');
    });

    test('huya needs a positive subSid for the native link', () {
      final withSub = externalTargetFor(
        const LiveRoom(
          roomId: '660000',
          platform: 'huya',
          danmakuData: {'subSid': 123},
        ),
      )!;
      expect(withSub.native, contains('yykiwi://'));
      expect(withSub.native, contains('channelid%3D123'));
      expect(withSub.web, 'https://www.huya.com/660000');
      final withoutSub = externalTargetFor(
        const LiveRoom(roomId: '660000', platform: 'huya'),
      )!;
      expect(withoutSub.native, isNull);
      expect(withoutSub.web, 'https://www.huya.com/660000');
    });

    test('douyu', () {
      final target = externalTargetFor(
        const LiveRoom(roomId: '226037', platform: 'douyu'),
      )!;
      expect(
        target.native,
        'douyulink://?type=90001&schemeUrl=douyuapp%3A%2F%2Froom%3FliveType%3D0%26rid%3D226037',
      );
      expect(target.web, 'https://www.douyu.com/226037');
    });

    test('kuaishou uses room.link as the liveStreamId', () {
      final target = externalTargetFor(
        const LiveRoom(
          roomId: 'abc123',
          platform: 'kuaishou',
          link: 'stream-xyz',
        ),
      )!;
      expect(target.native, contains('kwai://liveaggregatesquare'));
      expect(target.native, contains('liveStreamId=stream-xyz'));
      expect(target.web, 'https://live.kuaishou.com/u/abc123');
    });

    test('bad room ids yield no target, never an injected URL', () {
      expect(
        externalTargetFor(const LiveRoom(roomId: '', platform: 'bilibili')),
        isNull,
      );
      expect(
        externalTargetFor(
          const LiveRoom(roomId: '12/34?x=1', platform: 'bilibili'),
        ),
        isNull,
      );
      expect(
        externalTargetFor(const LiveRoom(roomId: '1', platform: 'unknown')),
        isNull,
      );
    });
  });

  group('openInPlatformApp', () {
    test('native first; web fallback when native fails', () async {
      const room = LiveRoom(roomId: '12345', platform: 'bilibili');
      final attempted = <String>[];
      final result = await openInPlatformApp(
        room,
        launch: (url) async {
          attempted.add(url);
          return url.startsWith('https://');
        },
      );
      expect(result, RoomExternalOpenResult.opened);
      expect(attempted, [
        'bilibili://live/12345',
        'https://live.bilibili.com/12345',
      ]);
    });

    test('unavailable when there is no target', () async {
      final result = await openInPlatformApp(
        const LiveRoom(roomId: '', platform: 'bilibili'),
      );
      expect(result, RoomExternalOpenResult.unavailable);
    });
  });

  // -- Douyu suspected-automated tagging --------------------------------

  group('DouyuDanmaku suspectedAutomated', () {
    LiveMessage? decodeOne(String body) {
      LiveMessage? got;
      final danmaku = DouyuDanmaku();
      danmaku.onMessage = (m) => got = m;
      danmaku.decodeMessage(DouyuDanmaku.serializeDouyu(body));
      return got;
    }

    test('chatmsg without dms and if != 1 is tagged', () {
      final m = decodeOne('type@=chatmsg/nn@=Alice/txt@=hi/col@=0/');
      expect(m, isNotNull);
      expect(m!.suspectedAutomated, isTrue);
    });

    test('chatmsg with dms is not tagged', () {
      final m = decodeOne(
        'type@=chatmsg/nn@=Alice/txt@=hi/col@=0/dms@=1/',
      );
      expect(m, isNotNull);
      expect(m!.suspectedAutomated, isFalse);
    });

    test('chatmsg with if=1 is not tagged', () {
      final m = decodeOne(
        'type@=chatmsg/nn@=Alice/txt@=hi/col@=0/if@=1/',
      );
      expect(m, isNotNull);
      expect(m!.suspectedAutomated, isFalse);
    });
  });

  // -- Widget tests: S2 / S4 / L04 / L05 -------------------------------

  group('LiveRoomPage panels + danmaku', () {
    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    Future<void> resetRoomSettings(WidgetTester tester) async {
      await tester.runAsync(() async {
        await DanmakuSettings.setEnabled('huya', true);
        await DanmakuSettings.setFontSize(14);
        await DanmakuSettings.setOpacity(1.0);
        await DanmakuSettings.setListStyle('compact');
        await DanmakuSettings.setListSpacing('standard');
        await DanmakuSettings.setShowUsernames(true);
        await DanmakuSettings.setSimilarityEnabled(false);
        await DanmakuSettings.setBlockEmoteOnly(false);
        await DanmakuSettings.setBlockLong(false);
        await DanmakuSettings.setDouyuBotFilter(false);
        await HiveStore.put(HiveKeys.danmakuBlockList, '[]');
        await LiveHistoryStore.clear();
        await LiveFollowStore.clear();
      });
      await settle(tester);
    }

    Future<_FakeSite> pumpRoom(
      WidgetTester tester, {
      List<LiveRoom> playlist = const [],
    }) async {
      tester.view.physicalSize = const Size(800, 1600);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      final site = _FakeSite();
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveRoomPage(
            room: const LiveRoom(
              roomId: '660000',
              platform: 'huya',
              title: 'test room',
              nick: 'tester',
              liveStatus: true,
              watching: 1234,
            ),
            playlist: playlist,
            site: site,
            backendFactory: (_) => _FakeBackend(),
          ),
        ),
      );
      await settle(tester);
      await tester.pump(const Duration(milliseconds: 200));
      await settle(tester);
      return site;
    }

    Future<void> disposeRoom(WidgetTester tester) async {
      await tester.pump(const Duration(seconds: 5));
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump();
    }

    testWidgets('S2: show-username off hides the sender name', (
      tester,
    ) async {
      await resetRoomSettings(tester);
      final site = await pumpRoom(tester);
      site.danmaku.emit(
        const LiveMessage(userName: 'Alice', message: 'hello'),
      );
      await tester.pump();
      expect(find.text('Alice: hello'), findsOneWidget);
      await tester.runAsync(
        () => DanmakuSettings.setShowUsernames(false),
      );
      await settle(tester);
      expect(find.text('hello'), findsOneWidget);
      expect(find.text('Alice: hello'), findsNothing);
      await disposeRoom(tester);
    });

    testWidgets('S2: line spacing + card style apply live', (
      tester,
    ) async {
      await resetRoomSettings(tester);
      final site = await pumpRoom(tester);
      site.danmaku.emit(
        const LiveMessage(userName: 'Alice', message: 'hello'),
      );
      await tester.pump();
      var text = tester.widget<Text>(find.text('Alice: hello'));
      expect(text.style?.height, isNull);
      // Fire-and-forget, do NOT await: a Hive put started in the
      // widget-test fake zone can stall behind the room-open
      // history record (same box, fire-and-forget) — the Future
      // never resolves here even though the value lands in the box
      // synchronously (proven by the L05 follow-toggle case). The
      // room's Hive listenable fires off the landed value, so the
      // restyle still applies on the next pump.
      unawaited(DanmakuSettings.setListSpacing('loose'));
      unawaited(DanmakuSettings.setListStyle('card'));
      await settle(tester);
      text = tester.widget<Text>(find.text('Alice: hello'));
      expect(text.style?.height, 1.7);
      // Card style wraps the row in a rounded container (radius 14
      // in the room page).
      expect(
        find.byWidgetPredicate(
          (w) =>
              w is Container &&
              w.decoration is BoxDecoration &&
              (w.decoration as BoxDecoration).borderRadius ==
                  BorderRadius.circular(14),
        ),
        findsWidgets,
      );
      await disposeRoom(tester);
    });

    testWidgets('S4: tap highlights, tap again clears', (tester) async {
      await resetRoomSettings(tester);
      final site = await pumpRoom(tester);
      site.danmaku.emit(
        const LiveMessage(userName: 'Alice', message: 'hello'),
      );
      await tester.pump();
      // The highlight is the theme accent wash (accentSoft). Match that
      // exact color: the room also has other colored containers (the
      // black video surface from the v1.0.6 landscape fix), so "any
      // non-transparent color" counts those too.
      final highlightColor =
          HaoTheme.of(tester.element(find.byType(LiveRoomPage))).accentSoft;
      await tester.tap(find.text('Alice: hello'));
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.color == highlightColor,
        ),
        findsOneWidget,
      );
      await tester.tap(find.text('Alice: hello'));
      await tester.pump();
      expect(
        find.byWidgetPredicate(
          (w) => w is Container && w.color == highlightColor,
        ),
        findsNothing,
      );
      await disposeRoom(tester);
    });

    testWidgets('S4: long-press blocks the user in place', (tester) async {
      await resetRoomSettings(tester);
      final site = await pumpRoom(tester);
      site.danmaku.emit(
        const LiveMessage(userName: 'Alice', message: 'hello'),
      );
      site.danmaku.emit(
        const LiveMessage(userName: 'Alice', message: 'again'),
      );
      site.danmaku.emit(
        const LiveMessage(userName: 'Bob', message: 'hi'),
      );
      await tester.pump();
      await tester.longPress(find.text('Alice: hello'));
      await tester.pumpAndSettle();
      expect(find.text('屏蔽该用户 (Alice)'), findsOneWidget);
      expect(find.text('屏蔽这句话'), findsOneWidget);
      await tester.tap(find.text('屏蔽该用户 (Alice)'));
      await tester.pump();
      await settle(tester);
      expect(find.text('Alice: hello'), findsNothing);
      expect(find.text('Alice: again'), findsNothing);
      expect(find.text('Bob: hi'), findsOneWidget);
      expect(DanmakuBlockStore.usernames(), contains('Alice'));
      // A later message from the blocked user never renders.
      site.danmaku.emit(
        const LiveMessage(userName: 'Alice', message: 'back'),
      );
      await tester.pump();
      expect(find.text('Alice: back'), findsNothing);
      await disposeRoom(tester);
    });

    testWidgets('S4: long-press blocks the message text', (tester) async {
      await resetRoomSettings(tester);
      final site = await pumpRoom(tester);
      site.danmaku.emit(
        const LiveMessage(userName: 'Alice', message: 'buy now'),
      );
      site.danmaku.emit(
        const LiveMessage(userName: 'Bob', message: 'buy now!'),
      );
      await tester.pump();
      await tester.longPress(find.text('Alice: buy now'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('屏蔽这句话'));
      await tester.pump();
      await settle(tester);
      expect(find.text('Alice: buy now'), findsNothing);
      // Same keyword in another message is removed too.
      expect(find.text('Bob: buy now!'), findsNothing);
      expect(DanmakuBlockStore.keywords(), contains('buy now'));
      await disposeRoom(tester);
    });

    testWidgets('L04: switch panel lists groups; tap switches room', (
      tester,
    ) async {
      await resetRoomSettings(tester);
      const other = LiveRoom(
        roomId: '660001',
        platform: 'huya',
        title: 'other room',
        nick: 'other',
        liveStatus: true,
        watching: 99,
      );
      await pumpRoom(tester, playlist: [other]);
      await tester.tap(find.byIcon(Icons.swap_horiz));
      await tester.pumpAndSettle();
      expect(find.text('切换直播间'), findsOneWidget);
      expect(find.text('关注'), findsOneWidget);
      expect(find.text('当前列表'), findsOneWidget);
      expect(find.text('历史'), findsOneWidget);
      expect(find.text('回放关注'), findsOneWidget);
      expect(find.text('other room'), findsOneWidget);
      // The current room is highlighted in the current list.
      expect(find.text('当前'), findsOneWidget);
      await tester.tap(find.text('other room'));
      await tester.pump();
      await settle(tester);
      // Switched: the new room's title is the AppBar title.
      expect(find.text('other room'), findsOneWidget);
      await disposeRoom(tester);
    });

    testWidgets('L05: detail sheet shows room number; follow toggles', (
      tester,
    ) async {
      await resetRoomSettings(tester);
      await pumpRoom(tester);
      await tester.tap(find.text('详情'));
      await tester.pumpAndSettle();
      expect(find.text('房间号 660000'), findsOneWidget);
      expect(find.text('复制'), findsOneWidget);
      expect(find.text('分享'), findsOneWidget);
      expect(find.textContaining('App 中打开'), findsOneWidget);
      expect(find.text('关注'), findsOneWidget);
      await tester.tap(find.text('关注'));
      await tester.pump();
      await settle(tester);
      expect(find.text('已关注'), findsOneWidget);
      expect(
        LiveFollowStore.isFollowedRoom(
          const LiveRoom(roomId: '660000', platform: 'huya'),
        ),
        isTrue,
      );
      await tester.tap(find.text('已关注'));
      await tester.pump();
      await settle(tester);
      expect(find.text('关注'), findsOneWidget);
      expect(
        LiveFollowStore.isFollowedRoom(
          const LiveRoom(roomId: '660000', platform: 'huya'),
        ),
        isFalse,
      );
      await disposeRoom(tester);
    });
  });
}

/// Fake LiveSite with one quality + one line and a fake danmaku
/// transport. [danmaku] is exposed so tests can assert start/stop
/// counts and emit messages on demand.
class _FakeSite extends LiveSite {
  final _FakeDanmaku danmaku = _FakeDanmaku();

  @override
  String get id => 'huya';

  @override
  String get name => 'Huya';

  @override
  LiveDanmaku getDanmaku() => danmaku;

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async => room;

  @override
  Future<List<LivePlayQuality>> getPlayQualities({
    required LiveRoom liveRoom,
  }) async =>
      const [LivePlayQuality(quality: '原画', id: '10000')];

  @override
  Future<LivePlayUrlResolution> resolvePlayUrls({
    required LiveRoom liveRoom,
    LivePlayQuality? quality,
  }) async {
    final issued = DateTime.now();
    return LivePlayUrlResolution(
      urls: const ['https://example.com/live.m3u8'],
      issuedAt: issued,
      refreshAt: issued.add(const Duration(seconds: 100)),
      invalidAt: issued.add(const Duration(seconds: 125)),
      streamFacts: const [LiveStreamFacts(format: 'hls')],
    );
  }
}

/// Fake danmaku transport: records start/stop and emits messages
/// through onMessage on demand.
class _FakeDanmaku extends LiveDanmaku {
  int startCount = 0;
  int stopCount = 0;

  @override
  bool get isConnected => startCount > stopCount;

  void emit(LiveMessage message) => onMessage?.call(message);

  @override
  Future<void> heartbeat() async {}

  @override
  Future<void> start(Map<String, dynamic> args) async {
    startCount++;
  }

  @override
  Future<void> stop() async {
    stopCount++;
  }
}

/// Minimal fake native backend: instant open / first frame, no
/// tickers, no timers — the session health watch only fires after
/// 4 s of no positions, which no test here pumps past while mounted.
class _FakeBackend implements PlayerBackend {
  @override
  PlayerEngine get engine => PlayerEngine.mediaKit;

  final _position = StreamController<Duration>.broadcast();
  final _duration = StreamController<Duration>.broadcast();
  final _playing = StreamController<bool>.broadcast();
  final _error = StreamController<String>.broadcast();
  final _completed = StreamController<void>.broadcast();

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
    // Do NOT await the broadcast close() calls: inside a widget test's
    // fake-async zone a broadcast StreamController.close() future never
    // completes, so awaiting it stalls the session dispose chain.
    unawaited(_position.close());
    unawaited(_duration.close());
    unawaited(_playing.close());
    unawaited(_error.close());
    unawaited(_completed.close());
  }
}
