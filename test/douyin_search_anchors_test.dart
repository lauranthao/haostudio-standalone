// Douyin searchAnchors (P1-19).
//
// Douyin has no anchor-search endpoint: searchAnchors used to throw
// "抖音暂不支持搜索主播", which breaks any cross-platform unified
// search that calls searchAnchors on all 5 platforms. It now reuses
// searchRooms — a room result already carries its anchor (owner
// nickname/avatar + roomId + liveStatus).
//
// Fakes only — stubbed Dio, no network. The stub answers the live
// search API with one canned room and fails everything else, so the
// fallback stages are exercised without touching the network.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/shared/platforms/douyin/douyin_site.dart';

/// One canned live-search hit: a live room owned by 主播A.
Map<String, dynamic> _cannedHit() {
  final raw = <String, dynamic>{
    'id_str': '987654',
    'status': 2,
    'title': '测试直播',
    'room': <String, dynamic>{
      'id_str': '987654',
      'title': '测试直播',
      'owner': <String, dynamic>{
        'nickname': '主播A',
        'web_rid': '987654',
        'avatar_thumb': <String, dynamic>{
          'url_list': <String>['https://example.com/av.jpg'],
        },
      },
    },
    'owner': <String, dynamic>{
      'nickname': '主播A',
      'web_rid': '987654',
      'avatar_thumb': <String, dynamic>{
        'url_list': <String>['https://example.com/av.jpg'],
      },
    },
    'cover': <String, dynamic>{
      'url_list': <String>['https://example.com/cover.jpg'],
    },
  };
  return <String, dynamic>{
    'live_info': raw,
  };
}

Dio _stubDio({bool failSearch = false}) {
  final dio = Dio();
  dio.interceptors.add(
    InterceptorsWrapper(
      onRequest: (options, handler) {
        if (options.path.contains('live/search') && !failSearch) {
          return handler.resolve(
            Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: <String, dynamic>{
                'status_code': 0,
                'data': <dynamic>[_cannedHit()],
              },
            ),
          );
        }
        // Cookie warm-up + every fallback stage: fail so the search
        // falls through to [] instead of real traffic.
        return handler.reject(
          DioException(
            requestOptions: options,
            error: 'stub: no such endpoint',
            type: DioExceptionType.unknown,
          ),
        );
      },
    ),
  );
  return dio;
}

void main() {
  group('DouyinSite.searchAnchors (P1-19)', () {
    test('does not throw; reuses room search with anchor fields', () async {
      final site = DouyinSite(dio: _stubDio());
      final anchors = await site.searchAnchors('主播A');
      expect(anchors, isNotEmpty);
      final first = anchors.first;
      expect(first.roomId, '987654');
      expect(first.nick, '主播A');
      expect(first.avatar, 'https://example.com/av.jpg');
      expect(first.liveStatus, isTrue);
      expect(first.platform, PlatformIds.douyin);
      // Same result as the room search it reuses.
      final rooms = await site.searchRooms('主播A');
      expect(
        rooms.map((r) => r.roomId).toList(),
        anchors.map((r) => r.roomId).toList(),
      );
    });

    test('returns [] (never throws) when every stage fails', () async {
      final site = DouyinSite(dio: _stubDio(failSearch: true));
      expect(await site.searchAnchors('主播A'), isEmpty);
    });

    test('empty keyword returns [] without throwing', () async {
      final site = DouyinSite(dio: _stubDio());
      expect(await site.searchAnchors(''), isEmpty);
      expect(await site.searchAnchors('   '), isEmpty);
    });
  });
}
