// Build-29 live group (I) tests — 15 items.
//
// Pure-logic tests run without Hive; store-backed tests use a
// memory box (same pattern as live_search_test.dart); widget tests
// use the settle() drain for Hive writes in the fake-async zone.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:hive_ce/hive_ce.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/core/theme/hao_themes.dart';
import 'package:standalone/domains/live/live_audio_sleep.dart';
import 'package:standalone/domains/live/live_follow_refresh.dart';
import 'package:standalone/domains/live/live_follow_store.dart';
import 'package:standalone/domains/live/live_follow_visibility.dart';
import 'package:standalone/domains/live/live_history_retention.dart';
import 'package:standalone/domains/live/live_history_store.dart';
import 'package:standalone/domains/live/live_link_parser.dart';
import 'package:standalone/domains/live/live_metrics.dart';
import 'package:standalone/domains/live/live_multiview.dart';
import 'package:standalone/domains/live/live_network_quality.dart';
import 'package:standalone/domains/live/live_pip_support.dart';
import 'package:standalone/domains/live/live_power_saving.dart';
import 'package:standalone/domains/live/live_recorder.dart';
import 'package:standalone/domains/live/live_search_progressive.dart';
import 'package:standalone/domains/live/live_volume_boost.dart';
import 'package:standalone/domains/live/presentation/live_follows_page.dart';
import 'package:standalone/domains/live/presentation/live_search_page.dart';
import 'package:standalone/domains/live/presentation/playback/live_fullscreen_clock.dart';
import 'package:standalone/shared/platforms/live_site.dart';

LiveRoom _room({
  required String roomId,
  String platform = 'huya',
  String title = '',
  String nick = '',
  bool live = true,
  int watching = 0,
}) => LiveRoom(
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
    hiveDir = await Directory.systemTemp.createTemp('hao-b29-live-i-test-');
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

  tearDownAll(() {
    unawaited(HiveStore.box.close());
    unawaited(hiveDir.delete(recursive: true));
  });

  tearDown(() async {
    Get.reset();
    await HiveStore.delete(HiveKeys.liveFollows);
    await HiveStore.delete(HiveKeys.liveHistory);
    await HiveStore.delete(HiveKeys.liveSearchHist);
    await HiveStore.delete(liveHiddenPlatformsKey);
    await HiveStore.delete(liveHistoryRetentionKey);
    await HiveStore.delete(liveVolumeBoostKey);
    await HiveStore.delete(liveClockCornerKey);
  });

  // -- Item 6: metric kinds -------------------------------------------
  group('item 6: audience metric kinds', () {
    test('bilibili + kuaishou are online, douyu + huya are heat', () {
      expect(metricForPlatform('bilibili').kind, LiveMetricKind.online);
      expect(metricForPlatform('kuaishou').kind, LiveMetricKind.online);
      expect(metricForPlatform('douyu').kind, LiveMetricKind.heat);
      expect(metricForPlatform('huya').kind, LiveMetricKind.heat);
      expect(metricForPlatform('douyin').kind, LiveMetricKind.views);
      // Unknown platform never claims 在线.
      expect(metricForPlatform('nope').kind, LiveMetricKind.views);
    });

    test('labels: online shows 人, heat shows 热度, douyin never 在线', () {
      expect(metricLabelFor('bilibili', 1234), '在线 1234人');
      expect(metricLabelFor('kuaishou', 1234), '在线 1234人');
      expect(metricLabelFor('douyu', 12345), '热度 1.2万');
      expect(metricLabelFor('huya', 12345), '热度 1.2万');
      expect(metricLabelFor('douyin', 12345), '观看 1.2万');
      expect(metricLabelFor('douyin', 1234), isNot(contains('在线')));
    });

    test('zero / unknown shows nothing, never a fabricated 0', () {
      expect(metricLabelFor('bilibili', 0), isEmpty);
      expect(metricLabelFor('douyu', -5), isEmpty);
    });

    test('formatAudience keeps the old 万 rule', () {
      expect(formatAudience(9999), '9999');
      expect(formatAudience(10000), '1.0万');
      expect(formatAudience(12345), '1.2万');
    });
  });

  // -- Item 1: follow refresh state machine ---------------------------
  group('item 1: follow refresh state machine', () {
    test('starts unknown (preview), one snapshot per round', () async {
      var calls = 0;
      final now = DateTime(2026, 11, 22, 10, 0);
      final ctl =
          LiveFollowRefreshController<int>(
            fetch: () async {
              calls++;
              return ({'a': 1}, 0);
            },
            now: () => now,
          );
      expect(ctl.phase, FollowRefreshPhase.unknown);
      expect(await ctl.tryStartRound(), isTrue);
      expect(calls, 1);
      expect(ctl.phase, FollowRefreshPhase.ready);
      expect(ctl.snapshot?.values, {'a': 1});
      expect(ctl.roundsStarted, 1);
    });

    test('second trigger while running is dropped, never queued', () async {
      final gate = Completer<(Map<String, int>, int)>();
      final ctl = LiveFollowRefreshController<int>(
        fetch: () => gate.future,
      );
      final first = ctl.tryStartRound();
      expect(await ctl.tryStartRound(), isFalse);
      expect(ctl.roundsStarted, 1);
      expect(ctl.triggersDropped, 1);
      gate.complete((<String, int>{}, 0));
      expect(await first, isTrue);
    });

    test('failed round starts a cooldown; auto triggers drop, manual bypasses',
        () async {
      var now = DateTime(2026, 11, 22, 10, 0);
      var calls = 0;
      final ctl = LiveFollowRefreshController<int>(
        fetch: () async {
          calls++;
          return (<String, int>{}, 1); // 1 failed
        },
        now: () => now,
      );
      expect(await ctl.tryStartRound(), isTrue);
      expect(ctl.inCooldown, isTrue);
      expect(await ctl.tryStartRound(), isFalse);
      expect(calls, 1);
      // Manual pull bypasses the cooldown.
      expect(await ctl.tryStartRound(manual: true), isTrue);
      expect(calls, 2);
      // 60 s later the cooldown is over for auto triggers too.
      now = now.add(const Duration(seconds: 61));
      expect(await ctl.tryStartRound(), isTrue);
      expect(calls, 3);
    });

    test('clean round clears the cooldown', () async {
      var calls = 0;
      final ctl = LiveFollowRefreshController<int>(
        fetch: () async {
          calls++;
          return (<String, int>{}, calls == 1 ? 1 : 0);
        },
      );
      await ctl.tryStartRound();
      expect(ctl.inCooldown, isTrue);
      await ctl.tryStartRound(manual: true);
      expect(ctl.inCooldown, isFalse);
    });
  });

  // -- Item 2: progressive search --------------------------------------
  group('item 2: progressive search', () {
    test('each platform shows as it completes; slow one does not block',
        () async {
      final seen = <String>[];
      final search = LiveProgressiveSearch(
        search: (platform, keyword) async {
          if (platform == 'huya') {
            await Future<void>.delayed(const Duration(milliseconds: 150));
          }
          return [_room(roomId: 'r-$platform', platform: platform)];
        },
      );
      final done = search.run(
        'test',
        ['bilibili', 'huya'],
        onPlatformDone: (r) => seen.add(r.platform),
      );
      // Bilibili lands first while Huya is still slow.
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(seen, ['bilibili']);
      final rooms = await done;
      expect(seen, ['bilibili', 'huya']);
      expect(rooms.map((r) => r.roomId), ['r-bilibili', 'r-huya']);
    });

    test('per-platform 12 s timeout fails alone', () async {
      final search = LiveProgressiveSearch(
        search: (platform, keyword) async {
          if (platform == 'douyu') {
            await Future<void>.delayed(const Duration(seconds: 30));
          }
          return [_room(roomId: 'ok', platform: platform)];
        },
        perPlatformTimeout: const Duration(milliseconds: 100),
      );
      final failed = <String>[];
      final rooms = await search.run(
        'test',
        ['bilibili', 'douyu'],
        onPlatformDone: (r) {
          if (r.failed) failed.add(r.platform);
        },
      );
      expect(failed, ['douyu']);
      expect(rooms.map((r) => r.roomId), ['ok']);
    });

    test('stale generation drops late results', () async {
      var gen = 1;
      final slow = Completer<List<LiveRoom>>();
      final search = LiveProgressiveSearch(
        search: (platform, keyword) async {
          if (keyword == 'slow') return slow.future;
          return [_room(roomId: 'fast')];
        },
      );
      final emitted = <String>[];
      final first = search.run(
        'slow',
        ['huya'],
        generation: () => gen,
        onPlatformDone: (r) => emitted.add(r.platform),
      );
      gen = 2;
      await search.run(
        'fast',
        ['huya'],
        generation: () => gen,
        onPlatformDone: (r) => emitted.add(r.platform),
      );
      slow.complete([_room(roomId: 'slow')]);
      await first;
      expect(emitted, ['huya']); // only the fast round emitted
    });

    test('dedupe by platform|roomId', () async {
      final search = LiveProgressiveSearch(
        search: (platform, keyword) async => [
          _room(roomId: 'dup', platform: platform),
          _room(roomId: 'dup', platform: platform),
        ],
      );
      final rooms = await search.run(
        'x',
        ['huya'],
        onPlatformDone: (_) {},
      );
      expect(rooms.length, 1);
    });

    test('include-offline filter hides offline rooms when off', () {
      final rooms = [
        _room(roomId: 'live', live: true),
        _room(roomId: 'off', live: false),
      ];
      expect(
        applyOfflineFilter(rooms, includeOffline: true).length,
        2,
      );
      expect(
        applyOfflineFilter(
          rooms,
          includeOffline: false,
        ).map((r) => r.roomId),
        ['live'],
      );
    });
  });

  // -- Item 3: data-network quality ------------------------------------
  group('item 3: data-network quality', () {
    List<LivePlayQuality> qualities(List<String> labels) =>
        labels.map((l) => LivePlayQuality(quality: l)).toList();

    test('interface classification', () {
      expect(classifyInterfaceName('en0'), LiveNetworkType.wifi);
      expect(classifyInterfaceName('wlan0'), LiveNetworkType.wifi);
      expect(classifyInterfaceName('pdp_ip0'), LiveNetworkType.cellular);
      expect(classifyInterfaceName('rmnet_data0'), LiveNetworkType.cellular);
      expect(classifyInterfaceName('lo0'), isNull);
      expect(
        classifyInterfaces(['lo0', 'en0']),
        LiveNetworkType.wifi,
      );
      expect(
        classifyInterfaces(['en0', 'pdp_ip0']),
        LiveNetworkType.cellular,
      );
      expect(classifyInterfaces(['lo0']), LiveNetworkType.unknown);
    });

    test('wifi keeps the preferred quality', () {
      final qs = qualities(['原画', '蓝光8M', '超清', '流畅']);
      expect(
        entryQualityIndex(qs, 0, network: LiveNetworkType.wifi),
        0,
      );
      expect(
        entryQualityIndex(qs, 0, network: LiveNetworkType.unknown),
        0,
      );
    });

    test('cellular caps at 超清, never 原画/蓝光', () {
      final qs = qualities(['原画', '蓝光8M', '超清', '流畅']);
      expect(
        entryQualityIndex(qs, 0, network: LiveNetworkType.cellular),
        2,
      );
      expect(
        qs[entryQualityIndex(qs, 0, network: LiveNetworkType.cellular)]
            .quality,
        '超清',
      );
    });

    test('cellular without a ceiling label drops to the middle tier', () {
      final qs = qualities(['4K', '2K', '720p', '480p']);
      final at = entryQualityIndex(qs, 0, network: LiveNetworkType.cellular);
      expect(at, greaterThan(0));
      expect(qs[at].quality, isNot('4K'));
    });
  });

  // -- Item 4: pure audio + sleep timer ---------------------------------
  group('item 4: sleep timer', () {
    test('arm / re-arm replaces / off cancels / expiry fires once', () {
      var fired = 0;
      var scheduled = <({Duration d, void Function() cb})>[];
      final timer = LiveSleepTimer(
        onExpire: () => fired++,
        timerFactory: (d, cb) {
          scheduled.add((d: d, cb: cb));
          return _FakeTimer(() => scheduled.removeAt(0));
        },
      );
      expect(timer.current, LiveSleepDuration.off);
      timer.set(LiveSleepDuration.min30);
      expect(timer.isArmed, isTrue);
      expect(timer.current, LiveSleepDuration.min30);
      // Re-arming replaces the timer.
      timer.set(LiveSleepDuration.min15);
      expect(scheduled.length, 1);
      expect(scheduled.first.d, const Duration(minutes: 15));
      // Fire it: exactly once, then off.
      scheduled.first.cb();
      expect(fired, 1);
      expect(timer.current, LiveSleepDuration.off);
      expect(timer.isArmed, isFalse);
      timer.set(LiveSleepDuration.off);
      expect(timer.isArmed, isFalse);
    });

    test('cancel never fires', () {
      var fired = 0;
      final timer = LiveSleepTimer(
        onExpire: () => fired++,
        timerFactory: (d, cb) => _FakeTimer(() {}),
      );
      timer.set(LiveSleepDuration.min60);
      timer.cancel();
      expect(timer.isArmed, isFalse);
      expect(fired, 0);
    });
  });

  // -- Item 5: follow groups -------------------------------------------
  group('item 5: follow groups', () {
    test('setGroup / groups / renameGroup, old follows read as 未分组',
        () async {
      await LiveFollowStore.add(_room(roomId: '1', platform: 'bilibili'));
      await LiveFollowStore.add(_room(roomId: '2', platform: 'douyu'));
      // Old stored JSON without a group key reads as ''.
      await LiveFollowStore.setGroup('bilibili', '1', '游戏');
      expect(LiveFollowStore.groups(), ['游戏']);
      expect(
        LiveFollowStore.getAll().firstWhere((f) => f.roomId == '1').group,
        '游戏',
      );
      expect(
        LiveFollowStore.getAll().firstWhere((f) => f.roomId == '2').group,
        '',
      );
      await LiveFollowStore.renameGroup('游戏', '电竞');
      expect(LiveFollowStore.groups(), ['电竞']);
      await LiveFollowStore.setGroup('bilibili', '1', '');
      expect(LiveFollowStore.groups(), isEmpty);
    });
  });

  // -- Item 8: volume boost --------------------------------------------
  group('item 8: volume boost', () {
    test('mapping clamps to the engine ceiling', () {
      // MPV: base 1.0 x 200% -> 200% (K 组已接 volume-max=300，
      // D 组把 Dart 侧 ceiling 从 1.3 抬到 3.0，131–300% 段打通)。
      expect(
        effectiveSessionVolume(
          baseVolume: 1.0,
          boostPct: 200,
          engine: PlayerEngine.mediaKit,
        ),
        2.0,
      );
      // MPV 300% now reaches the full 300%.
      expect(
        effectiveSessionVolume(
          baseVolume: 1.0,
          boostPct: 300,
          engine: PlayerEngine.mediaKit,
        ),
        3.0,
      );
      // IJK / AVPlayer: no gain path, ceiling 1.0.
      expect(
        effectiveSessionVolume(
          baseVolume: 1.0,
          boostPct: 300,
          engine: PlayerEngine.fijk,
        ),
        1.0,
      );
      expect(
        effectiveSessionVolume(
          baseVolume: 1.0,
          boostPct: 300,
          engine: PlayerEngine.exo,
        ),
        1.0,
      );
      // 0 base stays 0 (boost never un-mutes); 100% is a no-op.
      expect(
        effectiveSessionVolume(
          baseVolume: 0,
          boostPct: 300,
          engine: PlayerEngine.mediaKit,
        ),
        0,
      );
      expect(
        effectiveSessionVolume(
          baseVolume: 0.8,
          boostPct: 100,
          engine: PlayerEngine.mediaKit,
        ),
        0.8,
      );
    });

    test('effective percent shown to the user is honest', () {
      expect(
        effectiveBoostPct(
          baseVolume: 1.0,
          boostPct: 300,
          engine: PlayerEngine.mediaKit,
        ),
        300,
      );
      expect(
        effectiveBoostPct(
          baseVolume: 1.0,
          boostPct: 300,
          engine: PlayerEngine.exo,
        ),
        100,
      );
    });

    test('boost percent clamps + persists', () async {
      expect(clampBoostPct(50), 100);
      expect(clampBoostPct(999), 300);
      await saveBoostPct(250);
      expect(loadBoostPct(), 250);
    });
  });

  // -- Item 9: link toolbox --------------------------------------------
  group('item 9: link toolbox', () {
    test('parses all five platforms', () {
      expect(
        parseLiveLink('https://live.bilibili.com/12345')?.toString(),
        'bilibili:12345',
      );
      expect(
        parseLiveLink('https://www.douyu.com/999')?.toString(),
        'douyu:999',
      );
      expect(
        parseLiveLink('https://www.huya.com/abc123')?.toString(),
        'huya:abc123',
      );
      expect(
        parseLiveLink('https://live.douyin.com/777')?.toString(),
        'douyin:777',
      );
      expect(
        parseLiveLink('https://live.kuaishou.com/u/xyz_1')?.toString(),
        'kuaishou:xyz_1',
      );
    });

    test('rejects non-room pages + garbage, never guesses', () {
      expect(parseLiveLink('https://www.douyu.com/directory/all'), isNull);
      expect(parseLiveLink('https://www.bilibili.com/video/BV123'), isNull);
      expect(parseLiveLink('hello world'), isNull);
      expect(parseLiveLink(''), isNull);
      expect(parseLiveLink('https://live.bilibili.com/'), isNull);
    });

    test('extracts a link from surrounding text', () {
      final parsed = parseLiveLink('看看这个 https://live.bilibili.com/55 很精彩');
      expect(parsed?.toString(), 'bilibili:55');
    });

    test('short links need resolution; unresolvable returns null', () async {
      expect(isShortLiveLink('https://v.douyin.com/abc/'), isTrue);
      expect(isShortLiveLink('https://live.bilibili.com/1'), isFalse);
      final dio = Dio();
      dio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) =>
              handler.reject(DioException(requestOptions: options)),
        ),
      );
      expect(
        await parseOrResolveLiveLink('https://v.douyin.com/abc/', dio: dio),
        isNull,
      );
    });
  });

  // -- Item 10: power saving -------------------------------------------
  group('item 10: power saving', () {
    test('enter picks the lowest tier and remembers; exit restores', () {
      final ps = LivePowerSaving();
      expect(ps.enter(qualityCount: 4, currentQualityIndex: 0), 3);
      expect(ps.isOn, isTrue);
      expect(ps.enter(qualityCount: 4, currentQualityIndex: 0), isNull);
      expect(ps.exit(), 0);
      expect(ps.isOn, isFalse);
      expect(ps.exit(), isNull);
    });

    test('0/1 qualities: nothing to switch', () {
      final ps = LivePowerSaving();
      expect(ps.enter(qualityCount: 1, currentQualityIndex: 0), isNull);
      expect(ps.isOn, isFalse);
    });
  });

  // -- Item 11: visibility + retention ---------------------------------
  group('item 11: follow visibility + history retention', () {
    test('hidden platforms filter follows without deleting', () async {
      await LiveFollowStore.add(_room(roomId: '1', platform: 'bilibili'));
      await LiveFollowStore.add(_room(roomId: '2', platform: 'douyu'));
      await LiveFollowVisibility.setHidden('douyu', true);
      expect(LiveFollowVisibility.isHidden('douyu'), isTrue);
      final visible = LiveFollowVisibility.visibleFollows(
        LiveFollowStore.getAll(),
        LiveFollowVisibility.hiddenPlatforms(),
        platformOf: (f) => f.platform,
      );
      expect(visible.map((f) => f.roomId), ['1']);
      expect(LiveFollowStore.getAll().length, 2); // nothing deleted
      await LiveFollowVisibility.setHidden('douyu', false);
      expect(LiveFollowVisibility.isHidden('douyu'), isFalse);
    });

    test('retention prunes by days, 0 = forever', () async {
      final now = DateTime(2026, 11, 22, 12, 0);
      final entries = [
        LiveHistoryEntry(
          platform: 'huya',
          roomId: 'new',
          at: now.millisecondsSinceEpoch,
        ),
        LiveHistoryEntry(
          platform: 'huya',
          roomId: 'old',
          at: now
              .subtract(const Duration(days: 40))
              .millisecondsSinceEpoch,
        ),
      ];
      expect(applyRetention(entries, 0, now: now).length, 2);
      expect(
        applyRetention(entries, 30, now: now).map((e) => e.roomId),
        ['new'],
      );
      expect(retentionWouldDelete(entries, 30, now: now), 1);
      expect(retentionWouldDelete(entries, 0, now: now), 0);
      // Store-level prune deletes the expired row.
      await LiveHistoryStore.recordEntry(entries[1]);
      await LiveHistoryStore.recordEntry(entries[0]);
      await setLiveHistoryRetention(LiveHistoryRetention.days30);
      expect(liveHistoryRetention(), LiveHistoryRetention.days30);
      expect(
        await LiveHistoryStore.pruneExpired(now: now),
        1,
      );
      expect(
        LiveHistoryStore.getAll().map((e) => e.roomId),
        ['new'],
      );
    });
  });

  // -- Item 12: fullscreen clock ----------------------------------------
  group('item 12: fullscreen clock', () {
    test('format + corner cycle + persistence', () async {
      expect(formatClockTime(DateTime(2026, 11, 22, 9, 5)), '09:05');
      expect(formatClockTime(DateTime(2026, 11, 22, 23, 59)), '23:59');
      expect(LiveClockCorner.topLeft.next, LiveClockCorner.topRight);
      expect(LiveClockCorner.topRight.next, LiveClockCorner.bottomRight);
      expect(LiveClockCorner.bottomRight.next, LiveClockCorner.bottomLeft);
      expect(LiveClockCorner.bottomLeft.next, LiveClockCorner.topLeft);
      expect(LiveClockCorner.fromName('nope'), LiveClockCorner.topRight);
      await saveClockCorner(LiveClockCorner.bottomLeft);
      expect(loadClockCorner(), LiveClockCorner.bottomLeft);
    });
  });

  // -- Item 13: recording ------------------------------------------------
  group('item 13: recording', () {
    test('m3u8 media playlist parses segments + target duration', () {
      const body = '''
#EXTM3U
#EXT-X-TARGETDURATION:4
#EXTINF:4.0,
seg1.ts
#EXTINF:4.0,
https://cdn.example.com/seg2.ts
''';
      final parsed = parseM3u8(body, Uri.parse('https://cdn.example.com/live/'));
      expect(parsed.targetDuration, 4);
      expect(parsed.variantUrl, isNull);
      expect(
        parsed.segments.map((u) => u.toString()),
        [
          'https://cdn.example.com/live/seg1.ts',
          'https://cdn.example.com/seg2.ts',
        ],
      );
    });

    test('m3u8 master playlist picks the highest-bandwidth variant', () {
      const body = '''
#EXTM3U
#EXT-X-STREAM-INF:BANDWIDTH=800000
low.m3u8
#EXT-X-STREAM-INF:BANDWIDTH=4000000
high.m3u8
''';
      final parsed = parseM3u8(body, Uri.parse('https://cdn.example.com/'));
      expect(parsed.segments, isEmpty);
      expect(parsed.variantUrl.toString(), 'https://cdn.example.com/high.m3u8');
    });

    test('recording file name is sanitized', () {
      final name = recordingFileName(
        'douyin',
        'room/1?x=2',
        DateTime(2026, 11, 22, 10, 30, 5),
        'flv',
      );
      expect(name, 'douyin_room_1_x_2_20261122_103005.flv');
    });

    test('recording center lists newest first', () async {
      final dir = await Directory.systemTemp.createTemp('hao-rec-test-');
      try {
        final a = File('${dir.path}/a.flv');
        await a.writeAsBytes([1, 2, 3]);
        await Future<void>.delayed(const Duration(milliseconds: 10));
        final b = File('${dir.path}/b.flv');
        await b.writeAsBytes(List.filled(100, 0));
        final list = await listRecordings(dir);
        expect(list.map((r) => r.name), ['b.flv', 'a.flv']);
        expect(list.first.size, 100);
      } finally {
        await dir.delete(recursive: true);
      }
    });
  });

  // -- Item 14: multi-view ----------------------------------------------
  group('item 14: multi-view', () {
    test('only the focused cell has sound', () {
      final state = LiveMultiViewState(roomCount: 4);
      expect(state.focusedIndex, 0);
      expect(state.volumeFor(0), 1.0);
      expect(state.volumeFor(1), 0.0);
      expect(state.focus(2), isTrue);
      expect(state.volumeFor(2), 1.0);
      expect(state.volumeFor(0), 0.0);
      expect(state.focus(2), isFalse); // already focused: no move
      expect(state.focus(99), isTrue); // clamped to 3, moves there
      expect(state.focusedIndex, 3);
    });

    test('focus clamps to the room range', () {
      final state = LiveMultiViewState(roomCount: 2);
      state.focus(99);
      expect(state.focusedIndex, 1);
    });

    test('low quality prefers 流畅, else the last tier', () {
      final qs = [
        const LivePlayQuality(quality: '原画'),
        const LivePlayQuality(quality: '超清'),
        const LivePlayQuality(quality: '流畅'),
      ];
      expect(lowQualityIndex(qs), 2);
      expect(
        lowQualityIndex([
          const LivePlayQuality(quality: '原画'),
          const LivePlayQuality(quality: '超清'),
        ]),
        1,
      );
      expect(lowQualityIndex([]), 0);
    });
  });

  // -- Item 15: PiP verdicts --------------------------------------------
  group('item 15: PiP per-engine verdicts', () {
    test('AVPlayer needs wiring, MPV/IJK cannot do system PiP', () {
      expect(
        pipSupportFor(PlayerEngine.exo).verdict,
        LivePipVerdict.needsBackendWiring,
      );
      expect(
        pipSupportFor(PlayerEngine.mediaKit).verdict,
        LivePipVerdict.unsupported,
      );
      expect(
        pipSupportFor(PlayerEngine.fijk).verdict,
        LivePipVerdict.unsupported,
      );
      expect(pipAvailableNow(pipWired: false), isFalse);
      expect(pipAvailableNow(pipWired: true), isTrue);
    });
  });

  // -- Item 7: unfollow never triggers a full refresh (widget) ---------
  group('item 7: unfollow widget regression', () {
    testWidgets('unfollow issues zero adapter calls', (tester) async {
      TestWidgetsFlutterBinding.ensureInitialized();
      await tester.runAsync(() => HiveStore.delete(HiveKeys.liveFollows));
      await tester.runAsync(
        () => LiveFollowStore.add(_room(roomId: 'live', platform: 'bilibili')),
      );
      var detailCalls = 0;
      final site = _CountingSite(
        liveIds: {'live'},
        onDetail: () => detailCalls++,
      );
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveFollowsPage(
            siteOf: (_) => site,
            onOpenRoom: (_) {},
            onBrowse: () {},
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      final afterInit = detailCalls;
      expect(afterInit, greaterThan(0));
      await tester.tap(find.byIcon(Icons.favorite).first);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(LiveFollowStore.getAll(), isEmpty);
      expect(detailCalls, afterInit); // no re-refresh from unfollow
    });
  });

  // -- Item 2 (widget): progressive display ------------------------------
  group('item 2 widget: progressive search', () {
    Future<void> pumpSearch(
      WidgetTester tester, {
      required Future<List<LiveRoom>> Function(String platform, String keyword)
      searchFn,
    }) async {
      await tester.pumpWidget(
        GetMaterialApp(
          theme: HaoThemes.of(HaoThemeId.appleGlass).light,
          home: LiveSearchPage(searchFn: searchFn, onOpenRoom: (_) {}),
        ),
      );
      await tester.pump();
    }

    Future<void> settle(WidgetTester tester) async {
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 200));
      });
      await tester.pump();
    }

    testWidgets('first platform shows while the slow one is still pending',
        (tester) async {
      await pumpSearch(
        tester,
        searchFn: (platform, keyword) async {
          // Huya answers 400ms late (a fake-zone timer: the later
          // pump(Duration) advances the fake clock past it). The
          // fast platforms must already be visible by then.
          if (platform == 'huya') {
            await Future<void>.delayed(const Duration(milliseconds: 400));
            return [_room(roomId: 'slow', platform: 'huya', title: 'slow')];
          }
          return [
            _room(
              roomId: 'fast-$platform',
              platform: platform,
              title: 'fast-$platform',
            ),
          ];
        },
      );
      // Tall viewport: all 5 result rows must be built at once, or
      // ListView.builder leaves the 5th below the fold unbuilt and
      // find.text cannot see it (a test-viewport artefact, not a
      // product bug — the merge itself was verified separately).
      tester.view.physicalSize = const Size(800, 1400);
      tester.view.devicePixelRatio = 1.0;
      addTearDown(tester.view.resetPhysicalSize);
      addTearDown(tester.view.resetDevicePixelRatio);
      await tester.enterText(find.byType(TextField), 'test');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      await tester.pump();
      // Fast platforms already visible; Huya still pending.
      expect(find.text('fast-bilibili'), findsOneWidget);
      expect(find.text('slow'), findsNothing);
      await tester.runAsync(() async {
        await Future<void>.delayed(const Duration(milliseconds: 500));
      });
      // Advance the FAKE clock too: if the search runs in the fake
      // zone, the 400ms delay is a fake timer that only fires here.
      await tester.pump(const Duration(milliseconds: 500));
      await tester.pump();
      expect(find.text('slow'), findsOneWidget);
    });

    testWidgets('single-platform failure shows a note, not an error page',
        (tester) async {
      await pumpSearch(
        tester,
        searchFn: (platform, keyword) async {
          if (platform == 'douyu') throw Exception('boom');
          return [
            _room(
              roomId: 'ok-$platform',
              platform: platform,
              title: 'ok-$platform',
            ),
          ];
        },
      );
      await tester.enterText(find.byType(TextField), 'test');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      await tester.pump();
      expect(find.text('ok-bilibili'), findsOneWidget);
      expect(find.text('直播源暂时无法访问'), findsNothing);
      expect(find.textContaining('搜索失败'), findsOneWidget);
    });

    testWidgets('包含未开播 off hides offline rooms', (tester) async {
      await pumpSearch(
        tester,
        searchFn: (_, _) async => [
          _room(roomId: 'on', title: 'on', live: true),
          _room(roomId: 'off', title: 'off', live: false),
        ],
      );
      await tester.enterText(find.byType(TextField), 'test');
      await tester.testTextInput.receiveAction(TextInputAction.search);
      await settle(tester);
      await tester.pump();
      // Default on: both visible (deduped to one copy each).
      expect(find.text('off'), findsOneWidget);
      await tester.tap(find.text('包含未开播'));
      await tester.pump();
      expect(find.text('off'), findsNothing);
      expect(find.text('on'), findsOneWidget);
    });
  });
}

/// Fake timer for the sleep-timer tests: [cancel] runs [onCancel].
class _FakeTimer implements Timer {
  _FakeTimer(this.onCancel);

  final void Function() onCancel;
  bool _active = true;

  @override
  bool get isActive => _active;

  @override
  int get tick => 0;

  @override
  void cancel() {
    _active = false;
    onCancel();
  }
}

/// Counting adapter for the item-7 regression test.
class _CountingSite extends LiveSite {
  _CountingSite({required this.liveIds, required this.onDetail});

  @override
  final String id = 'fake';

  @override
  final String name = 'Fake';

  final Set<String> liveIds;
  final void Function() onDetail;

  @override
  Future<LiveRoom> getRoomDetail(LiveRoom room) async {
    onDetail();
    return room.copyWith(liveStatus: liveIds.contains(room.roomId));
  }
}
