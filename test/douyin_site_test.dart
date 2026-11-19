// Douyin adapter tests — pure-Dart rules that must never regress:
//
// - SM3 test vectors (GB/T 32905-2016) — the A-Bogus signer depends on it.
// - A-Bogus signing shape (a_bogus present, msToken/aid injected).
// - Anonymous visitor id: 19 digits in 7.3e18–8e18.
// - Quality parsing: joined by sdk_key (never position), sorted by
//   level/rank NOT v_bit_rate, FLV+HLS merged per quality, audio-only
//   `ao` excluded, identical URL sets deduped, no invented qualities.
// - Feed parsing: both legacy `data.data` and new envelope generations.
// - Search parsing: live/general payloads + partition room lists.
// - End-to-end room detail -> qualities -> URLs -> recovery with a
//   stubbed Dio (no real network).
// - Best-effort LIVE tests (real Douyin, VM reaches it): feed/search/
//   room detail must not throw; when a room is live its qualities and
//   URLs must be non-empty. These print what they found and never fail
//   on an empty-but-healthy response — Douyin may serve an empty feed
//   to an anonymous client.

import 'dart:convert';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/shared/platforms/douyin/abogus.dart';
import 'package:standalone/shared/platforms/douyin/douyin_audience.dart';
import 'package:standalone/shared/platforms/douyin/douyin_search.dart';
import 'package:standalone/shared/platforms/douyin/douyin_site.dart';
import 'package:standalone/shared/platforms/douyin/douyin_utils.dart';
import 'package:standalone/shared/platforms/douyin/sm3.dart';

/// Canned `stream_url` (legacy maps only).
Map<String, dynamic> cannedStreamUrl() => <String, dynamic>{
      'flv_pull_url': <String, dynamic>{
        'ORIGIN': 'https://flv.example.com/origin.flv',
        'HD1': 'https://flv.example.com/hd.flv',
        'SD1': 'https://flv.example.com/sd.flv',
        'ao': 'https://flv.example.com/ao.flv?only_audio=1',
      },
      'hls_pull_url_map': <String, dynamic>{
        'ORIGIN': 'https://hls.example.com/origin.m3u8',
        'HD1': 'https://hls.example.com/hd.m3u8',
        'SD1': 'https://hls.example.com/sd.m3u8',
      },
      'resolution_name': <String, dynamic>{
        'ORIGIN': '原画',
        'HD1': '超清',
        'SD1': '标清',
      },
    };

/// Canned room-enter API envelope (`result["data"]`).
Map<String, dynamic> cannedEnterEnvelope({int status = 2}) =>
    <String, dynamic>{
      'status_code': 0,
      'data': <String, dynamic>{
        'data': [
          <String, dynamic>{
            'id_str': '7381234567890123456',
            'title': 'Test Live',
            'status': status,
            'cover': {
              'url_list': ['https://example.com/cover.jpg'],
            },
            'owner': {
              'nickname': 'Tester',
              'avatar_thumb': {
                'url_list': ['https://example.com/avatar.jpg'],
              },
              'signature': 'hi',
            },
            'stream_url': cannedStreamUrl(),
          },
        ],
        'user': {
          'nickname': 'OfflineNick',
          'avatar_thumb': {
            'url_list': ['https://example.com/offline.jpg'],
          },
        },
        'partition_road_map': {},
      },
    };

/// Canned reflow/info envelope for a long numeric room id.
Map<String, dynamic> cannedReflowEnvelope({int status = 2}) =>
    <String, dynamic>{
      'status_code': 0,
      'data': <String, dynamic>{
        'room': <String, dynamic>{
          'status': status,
          'title': 'Reflow Live',
          'cover': {
            'url_list': ['https://example.com/cover2.jpg'],
          },
          'owner': {
            'web_rid': 'testroom',
            'nickname': 'ReflowTester',
            'avatar_thumb': {
              'url_list': ['https://example.com/avatar2.jpg'],
            },
          },
          'stream_url': cannedStreamUrl(),
        },
      },
    };

/// Canned legacy feed payload (`data.data`).
Map<String, dynamic> cannedLegacyFeed() => <String, dynamic>{
      'status_code': 0,
      'data': <String, dynamic>{
        'data': [
          <String, dynamic>{
            'web_rid': 'roomA',
            'room': <String, dynamic>{
              'title': 'Room A',
              'cover': {
                'url_list': ['https://example.com/a.jpg'],
              },
              'owner': {
                'nickname': 'AnchorA',
                'avatar_thumb': {
                  'url_list': ['https://example.com/aa.jpg'],
                },
              },
              'user_count_str': '1234',
            },
          },
        ],
      },
    };

void main() {
  group('SM3 (GB/T 32905-2016 vectors)', () {
    test('empty input', () {
      expect(
        SM3.hashBytes(Uint8List(0)),
        '1ab21d8355cfa17f8e61194831e81a8f22bec8c728fefb747ed035eb5082aa2b',
      );
    });

    test('"abc"', () {
      expect(
        SM3.hashBytes(Uint8List.fromList(utf8.encode('abc'))),
        '66c7f0f462eeedd9d1f2d46bdc10e4e24167c4875cf2f7a2297da02b8f4ba8e0',
      );
    });

    test('64-byte block boundary input is stable', () {
      final input = Uint8List.fromList(List<int>.filled(64, 0x61));
      final first = SM3.hashBytes(input);
      expect(first, SM3.hashBytes(input));
      expect(first.length, 64);
    });
  });

  group('ABogus + DouyinUtils', () {
    test('generateAbogus appends a_bogus', () {
      final signed =
          ABogus(userAgent: 'Mozilla/5.0 test').generateAbogus('aid=6383&x=1');
      expect(signed.length, 4);
      expect(signed.first, contains('aid=6383&x=1&a_bogus='));
      expect(signed[1], isNotEmpty);
    });

    test('buildRequestUrl injects aid/msToken/a_bogus', () {
      final url = DouyinUtils.buildRequestUrl(
        'https://live.douyin.com/webcast/room/web/enter/',
        {'web_rid': 'abc'},
      );
      final uri = Uri.parse(url);
      expect(uri.queryParameters['aid'], '6383');
      expect(uri.queryParameters['msToken'], isNotEmpty);
      expect(uri.queryParameters['a_bogus'], isNotEmpty);
      expect(uri.queryParameters['web_rid'], 'abc');
      expect(uri.queryParameters['device_platform'], 'web');
    });

    test('getMSToken length + charset', () {
      final token = DouyinUtils.getMSToken();
      expect(token.length, 184);
      expect(
        RegExp(r'^[A-Za-z0-9=]+$').hasMatch(token),
        isTrue,
      );
      expect(DouyinUtils.getMSToken(), isNot(DouyinUtils.getMSToken()));
    });
  });

  group('anonymous visitor id', () {
    test('19 digits in 7.3e18–8e18', () {
      for (var i = 0; i < 20; i++) {
        final id = DouyinSite.generateAnonymousUserUniqueId();
        expect(id.length, 19);
        expect(RegExp(r'^\d{19}$').hasMatch(id), isTrue);
        final value = BigInt.parse(id);
        expect(value >= BigInt.from(7300000000000000000), isTrue);
        expect(value < BigInt.from(8000000000000000000), isTrue);
      }
    });
  });

  group('audience parsing', () {
    test('online wins over total; 万 expands', () {
      expect(
        douyinWatching({'user_count_str': '1.2万', 'total_user_str': '999'}),
        12000,
      );
      expect(douyinWatching({'total_user_str': '5千'}), 5000);
      expect(douyinWatching({'user_count': 0, 'total_user': 0}), 0);
      expect(douyinWatching({}), 0);
      expect(douyinWatching('not-a-map'), 0);
    });

    test('zero total_user placeholder is ignored', () {
      expect(douyinTotalViewers({'total_user': 0, 'user_count': '42'}), '');
      expect(douyinOnlineViewers({'user_count': '42'}), '42');
    });
  });

  group('parseStreamQualities', () {
    test('legacy maps: labels, order, FLV+HLS merged', () {
      final qualities = DouyinSite.parseStreamQualities(cannedStreamUrl());
      expect(qualities.map((q) => q.quality), ['原画', '超清', '标清']);
      expect(qualities.map((q) => q.id), ['origin', 'hd1', 'sd1']);
      for (final quality in qualities) {
        final urls = quality.data as List;
        expect(urls.length, 2);
        expect(urls.any((u) => u.toString().endsWith('.flv')), isTrue);
        expect(urls.any((u) => u.toString().endsWith('.m3u8')), isTrue);
      }
    });

    test('audio-only ao entry is excluded', () {
      final qualities = DouyinSite.parseStreamQualities(cannedStreamUrl());
      expect(qualities.map((q) => q.id), isNot(contains('ao')));
    });

    test('sort is by level/rank, NOT v_bit_rate', () {
      // ORIGIN has a LOWER instantaneous bitrate than HD1 here; a
      // bitrate sort would put HD1 first. The rank sort must not.
      final streamUrl = <String, dynamic>{
        'flv_pull_url': <String, dynamic>{
          'ORIGIN': 'https://flv.example.com/origin.flv',
          'HD1': 'https://flv.example.com/hd.flv',
        },
        'hls_pull_url_map': <String, dynamic>{
          'ORIGIN': 'https://hls.example.com/origin.m3u8',
          'HD1': 'https://hls.example.com/hd.m3u8',
        },
        'live_core_sdk_data': <String, dynamic>{
          'pull_data': <String, dynamic>{
            'options': <String, dynamic>{
              'qualities': [
                {'sdk_key': 'ORIGIN', 'v_bit_rate': '500000', 'level': 5},
                {'sdk_key': 'HD1', 'v_bit_rate': '2000000', 'level': 3},
              ],
            },
          },
        },
      };
      final qualities = DouyinSite.parseStreamQualities(streamUrl);
      expect(qualities.map((q) => q.id), ['origin', 'hd1']);
    });

    test('identical URL sets under two keys dedupe to one entry', () {
      final streamUrl = <String, dynamic>{
        'flv_pull_url': <String, dynamic>{
          'FULL_HD1': 'https://flv.example.com/fhd.flv',
          'UHD': 'https://flv.example.com/fhd.flv',
        },
        'hls_pull_url_map': <String, dynamic>{
          'FULL_HD1': 'https://hls.example.com/fhd.m3u8',
          'UHD': 'https://hls.example.com/fhd.m3u8',
        },
      };
      final qualities = DouyinSite.parseStreamQualities(streamUrl);
      expect(qualities.length, 1);
      expect(qualities.first.quality, '蓝光');
    });

    test('modern stream_data payload joins by key + aspect ratio', () {
      final streamUrl = <String, dynamic>{
        'live_core_sdk_data': <String, dynamic>{
          'pull_data': <String, dynamic>{
            'options': <String, dynamic>{
              'qualities': [
                {'sdk_key': 'FULL_HD1', 'name': '蓝光', 'level': 4},
              ],
            },
            'stream_data': json.encode({
              'data': {
                'FULL_HD1': {
                  'main': {
                    'flv': 'https://flv.example.com/fhd.flv',
                    'hls': 'https://hls.example.com/fhd.m3u8',
                    'sdk_params': '{"resolution":"1920x1080"}',
                  },
                },
              },
            }),
          },
        },
      };
      final qualities = DouyinSite.parseStreamQualities(streamUrl);
      expect(qualities.length, 1);
      expect(qualities.first.quality, '蓝光');
      expect(qualities.first.declaredAspectRatio, closeTo(16 / 9, 0.001));
      expect((qualities.first.data as List).length, 2);
    });

    test('no stream_url -> no qualities (nothing invented)', () {
      expect(DouyinSite.parseStreamQualities(null), isEmpty);
      expect(DouyinSite.parseStreamQualities({}), isEmpty);
      expect(
        DouyinSite.parseStreamQualities({'flv_pull_url': {}}),
        isEmpty,
      );
    });
  });

  group('parseRecommendRooms', () {
    test('legacy data.data generation', () {
      final rooms = DouyinSite.parseRecommendRooms(cannedLegacyFeed());
      expect(rooms.length, 1);
      expect(rooms.first.roomId, 'roomA');
      expect(rooms.first.title, 'Room A');
      expect(rooms.first.nick, 'AnchorA');
      expect(rooms.first.watching, 1234);
      expect(rooms.first.liveStatus, isTrue);
      expect(rooms.first.link, 'https://live.douyin.com/roomA');
    });

    test('new envelope generation (data list, room in data field)', () {
      final rooms = DouyinSite.parseRecommendRooms(<String, dynamic>{
        'status_code': 0,
        'data': [
          <String, dynamic>{
            'web_rid': 'roomB',
            'data': <String, dynamic>{
              'title': 'Room B',
              'cover': {
                'url_list': ['https://example.com/b.jpg'],
              },
              'owner': {
                'nickname': 'AnchorB',
                'avatar_thumb': {
                  'url_list': ['https://example.com/bb.jpg'],
                },
              },
              'user_count_str': '77',
            },
          },
          // Duplicate web_rid is dropped.
          <String, dynamic>{
            'web_rid': 'roomB',
            'data': {'title': 'Room B dup'},
          },
        ],
      });
      expect(rooms.length, 1);
      expect(rooms.first.roomId, 'roomB');
      expect(rooms.first.watching, 77);
    });

    test('non-zero status_code throws; missing list throws', () {
      expect(
        () => DouyinSite.parseRecommendRooms({'status_code': 1000}),
        throwsStateError,
      );
      expect(
        () => DouyinSite.parseRecommendRooms({'status_code': 0}),
        throwsFormatException,
      );
      expect(
        () => DouyinSite.parseRecommendRooms('nope'),
        throwsFormatException,
      );
    });
  });

  group('categories + partition rooms', () {
    test('parseCategories from a canned homepage blob', () {
      const html =
          '{"pathname":"/","categoryData":[{"partition":{"id_str":"1","type":1,"title":"游戏"},"sub_partition":[{"partition":{"id_str":"2","type":1,"title":"英雄联盟"}}]}]}';
      final areas = DouyinSite.parseCategories('prefix $html suffix');
      expect(areas.map((a) => a.areaId), ['1,1', '2,1']);
      expect(areas.map((a) => a.areaName), ['游戏', '英雄联盟']);
    });

    test('parseCategories without the blob returns empty', () {
      expect(DouyinSite.parseCategories('<html></html>'), isEmpty);
    });

        test('parseCategories from the real escaped SSR blob', () {
      // The live page embeds the blob with every quote escaped as
      // backslash-backslash-quote, the form Pure Live matches.
      // Built with char codes so the test source carries no escapes.
      const inner =
          '{"pathname":"/","categoryData":[{"partition":{"id_str":"1","type":1,"title":"游戏"},"sub_partition":[{"partition":{"id_str":"2","type":1,"title":"英雄联盟"}}]}]}';
      final bs = String.fromCharCode(92);
      final page = 'prefix ${inner.replaceAll('"', '$bs$bs"')} suffix';
      final areas = DouyinSite.parseCategories(page);
      expect(areas.map((a) => a.areaId), ['1,1', '2,1']);
      expect(areas.map((a) => a.areaName), ['游戏', '英雄联盟']);
    });

    test('parseCategoryRooms maps data.data[]', () {
      final rooms = DouyinSite.parseCategoryRooms(<String, dynamic>{
        'status_code': 0,
        'data': <String, dynamic>{
          'data': [
            <String, dynamic>{
              'web_rid': 'roomC',
              'room': <String, dynamic>{
                'title': 'Room C',
                'cover': {
                  'url_list': ['https://example.com/c.jpg'],
                },
                'owner': {
                  'nickname': 'AnchorC',
                  'avatar_thumb': {
                    'url_list': ['https://example.com/cc.jpg'],
                  },
                },
                'user_count_str': '55',
              },
            },
          ],
        },
      });
      expect(rooms.length, 1);
      expect(rooms.first.roomId, 'roomC');
      expect(rooms.first.watching, 55);
    });
  });

  group('search parsing', () {
    test('parseSearchVideos maps a live-API item', () {
      final rooms = DouyinSearch.parseSearchVideos([
        <String, dynamic>{
          'lives': <String, dynamic>{
            'rawdata': json.encode(<String, dynamic>{
              'id_str': '7380000000000000001',
              'title': '唱歌直播',
              'status': 2,
              'cover': {
                'url_list': ['https://example.com/cover.jpg'],
              },
              'owner': {
                'web_rid': 'singer1',
                'nickname': 'Singer',
                'avatar_thumb': {
                  'url_list': ['https://example.com/av.jpg'],
                },
              },
              'room': {
                'user_count_str': '321',
              },
            }),
          },
        },
      ]);
      expect(rooms.length, 1);
      expect(rooms.first.roomId, 'singer1');
      expect(rooms.first.title, '唱歌直播');
      expect(rooms.first.liveStatus, isTrue);
      expect(rooms.first.watching, 321);
    });

    test('parseSearchVideos drops items without an id', () {
      expect(DouyinSearch.parseSearchVideos([{'foo': 'bar'}]), isEmpty);
      expect(DouyinSearch.parseSearchVideos('nope'), isEmpty);
    });

    test('parsePartitionRoomList maps room lists', () {
      final rooms = DouyinSearch.parsePartitionRoomList([
        <String, dynamic>{
          'web_rid': 'roomD',
          'room': <String, dynamic>{
            'id_str': '7380000000000000002',
            'title': 'Room D',
            'cover': {
              'url_list': ['https://example.com/d.jpg'],
            },
            'owner': {
              'nickname': 'AnchorD',
              'avatar_thumb': {
                'url_list': ['https://example.com/dd.jpg'],
              },
            },
            'user_count_str': '9',
          },
        },
      ]);
      expect(rooms.length, 1);
      expect(rooms.first.roomId, 'roomD');
      expect(rooms.first.watching, 9);
    });
  });

  group('DouyinSite end-to-end with stubbed Dio', () {
    late Dio stubDio;
    var enterCalls = 0;
    var reflowCalls = 0;

    setUp(() {
      enterCalls = 0;
      reflowCalls = 0;
      stubDio = Dio();
      stubDio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          final url = options.uri.toString();
          if (url.contains('room/web/enter')) {
            enterCalls++;
            return handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: cannedEnterEnvelope(),
            ));
          }
          if (url.contains('room/reflow/info')) {
            reflowCalls++;
            return handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: cannedReflowEnvelope(),
            ));
          }
          if (url.contains('webcast/feed')) {
            return handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: cannedLegacyFeed(),
            ));
          }
          if (url == 'https://live.douyin.com/?from_nav=1' ||
              url == 'https://live.douyin.com/') {
            return handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{},
              headers: Headers.fromMap({
                'set-cookie': ['ttwid=stub-ttwid; Path=/; Domain=.douyin.com'],
              }),
            ));
          }
          return handler.next(options);
        },
      ));
    });

    test('web_rid detail -> qualities -> URLs -> resolution facts', () async {
      final site = DouyinSite(dio: stubDio);
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: 'testroom', platform: 'douyin'),
      );
      expect(room.liveStatus, isTrue);
      expect(room.title, 'Test Live');
      expect(room.nick, 'Tester');
      expect(room.cover, 'https://example.com/cover.jpg');
      expect(room.link, 'https://live.douyin.com/testroom');
      // Danmaku credentials: long room id + webRid + user id + cookie.
      final danmaku = room.danmakuData!;
      expect(danmaku['webRid'], 'testroom');
      expect(danmaku['roomId'], '7381234567890123456');
      expect((danmaku['userId'] as String).length, 19);
      expect(danmaku['cookie'], contains('ttwid=stub-ttwid'));

      final qualities = await site.getPlayQualities(liveRoom: room);
      expect(qualities.map((q) => q.quality), ['原画', '超清', '标清']);

      final origin = qualities.firstWhere((q) => q.id == 'origin');
      final urls = await site.getPlayUrls(liveRoom: room, quality: origin);
      expect(urls.length, 2);
      expect(urls.first, contains('.flv'));
      expect(urls.last, contains('.m3u8'));

      final resolution =
          await site.resolvePlayUrls(liveRoom: room, quality: origin);
      expect(resolution.urls, urls);
      expect(resolution.appliedQualityData, 'origin');
      expect(resolution.streamFacts.map((f) => f.format), ['flv', 'hls']);
      // Douyin pull URLs carry no lease: no proactive refresh/expiry.
      expect(resolution.refreshAt, isNull);
      expect(resolution.invalidAt, isNull);

      // Null quality resolves the first (best) quality.
      final defaultUrls = await site.getPlayUrls(liveRoom: room);
      expect(defaultUrls, urls);
    });

    test('long numeric roomId goes through reflow/info', () async {
      final site = DouyinSite(dio: stubDio);
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: '7381234567890123456', platform: 'douyin'),
      );
      expect(reflowCalls, 1);
      expect(enterCalls, 0);
      expect(room.liveStatus, isTrue);
      expect(room.roomId, 'testroom');
      expect(room.title, 'Reflow Live');
      final qualities = await site.getPlayQualities(liveRoom: room);
      expect(qualities.map((q) => q.quality), ['原画', '超清', '标清']);
    });

    test('recovery re-fetches (never cached URLs)', () async {
      final site = DouyinSite(dio: stubDio);
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: 'testroom', platform: 'douyin'),
      );
      final qualities = await site.getPlayQualities(liveRoom: room);
      final hd = qualities.firstWhere((q) => q.id == 'hd1');
      final before = enterCalls;
      final recovered = await site.resolvePlayUrlsForRecovery(
          liveRoom: room, quality: hd);
      expect(enterCalls, greaterThan(before));
      expect(recovered.urls.length, 2);
      expect(recovered.appliedQualityData, 'hd1');
      expect(recovered.streamFacts.map((f) => f.format), ['flv', 'hls']);
    });

    test('offline room: liveStatus false, no qualities', () async {
      stubDio.interceptors.clear();
      stubDio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          final url = options.uri.toString();
          if (url.contains('room/web/enter')) {
            return handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: cannedEnterEnvelope(status: 1),
            ));
          }
          return handler.resolve(Response<dynamic>(
            requestOptions: options,
            statusCode: 200,
            data: <String, dynamic>{},
          ));
        },
      ));
      final site = DouyinSite(dio: stubDio);
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: 'testroom', platform: 'douyin'),
      );
      expect(room.liveStatus, isFalse);
      expect(await site.getPlayQualities(liveRoom: room), isEmpty);
      expect(await site.getPlayUrls(liveRoom: room), isEmpty);
    });

    test('searchAnchors no longer throws (P1-19)', () async {
      final site = DouyinSite(dio: stubDio);
      // Empty keyword short-circuits in DouyinSearch without any
      // network; the full reuse behaviour (anchors == rooms, anchor
      // fields populated, all-stages-fail -> []) is pinned in
      // test/douyin_search_anchors_test.dart.
      expect(await site.searchAnchors(''), isEmpty);
    });

    test('recommend feed parses through the stub', () async {
      final site = DouyinSite(dio: stubDio);
      final rooms = await site.getRecommendRooms();
      expect(rooms.length, 1);
      expect(rooms.first.roomId, 'roomA');
    });
  });

  group('live Douyin (best-effort, real network)', () {
    test('recommend feed does not throw', () async {
      final site = DouyinSite();
      final rooms = await site.getRecommendRooms();
      // ignore: avoid_print
      print('LIVE feed rooms: ${rooms.length}');
      for (final room in rooms.take(3)) {
        // ignore: avoid_print
        print('  ${room.roomId} ${room.nick} ${room.title}');
      }
      expect(rooms, isA<List<LiveRoom>>());
    }, timeout: const Timeout(Duration(seconds: 60)));

    test('search does not throw', () async {
      final site = DouyinSite();
      final rooms = await site.searchRooms('唱歌', pageSize: 10);
      // ignore: avoid_print
      print('LIVE search rooms: ${rooms.length}');
      for (final room in rooms.take(3)) {
        // ignore: avoid_print
        print('  ${room.roomId} ${room.nick} ${room.title}');
      }
      expect(rooms, isA<List<LiveRoom>>());
    }, timeout: const Timeout(Duration(seconds: 90)));

    test('feed room detail resolves qualities when live', () async {
      final site = DouyinSite();
      final rooms = await site.getRecommendRooms();
      if (rooms.isEmpty) {
        // ignore: avoid_print
        print('LIVE feed empty — cannot exercise room detail live');
        return;
      }
      final detail = await site.getRoomDetail(rooms.first);
      // ignore: avoid_print
      print('LIVE detail: ${detail.roomId} live=${detail.liveStatus} '
          'title=${detail.title}');
      if (!detail.liveStatus) return;
      final qualities = await site.getPlayQualities(liveRoom: detail);
      // ignore: avoid_print
      print('LIVE qualities: ${qualities.map((q) => q.quality).toList()}');
      expect(qualities, isNotEmpty);
      final resolution = await site.resolvePlayUrls(
          liveRoom: detail, quality: qualities.first);
      // ignore: avoid_print
      print('LIVE urls: ${resolution.urls}');
      expect(resolution.urls, isNotEmpty);
      for (final url in resolution.urls) {
        expect(url, startsWith('http'));
      }
      expect(
        resolution.streamFacts.map((f) => f.format),
        everyElement(isIn(['flv', 'hls', 'other'])),
      );
    }, timeout: const Timeout(Duration(seconds: 90)));
  });
}
