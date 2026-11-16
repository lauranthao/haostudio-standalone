// Huya adapter unit tests — pure-Dart rules that must never regress:
//
// - Anti-code signing against a known fixture (template substitution +
//   wsSecret, seqid, rotated uid, expiry refusal).
// - Lease math (refresh ~100 s, invalid ~125 s, wsTime+5min bound).
// - vMultiStreamInfo parsing from a canned room-page snippet.
// - Line identity by URL, never by index after refresh.
// - End-to-end room detail -> qualities -> URLs with a stubbed Dio
//   (no real network).

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/tars/get_cdn_token_ex_resp.dart';
import 'package:standalone/shared/platforms/huya/huya_anti_code.dart';
import 'package:standalone/shared/platforms/huya/huya_models.dart';
import 'package:standalone/shared/platforms/huya/huya_room_parser.dart';
import 'package:standalone/shared/platforms/huya/huya_site.dart';
import 'package:standalone/shared/platforms/huya/huya_transport_policy.dart';
import 'package:standalone/shared/platforms/huya/huya_wup.dart';

/// Canned room page. `wsTimeHex` is interpolated into the anti-codes so
/// the fixture never expires during the test run.
String cannedRoomPage(String wsTimeHex) {
  return '''
<html><head><title>test</title></head><body>
<script>
var TT_ROOM_DATA = {"state":"ON","isReplay":false,"profile":{"roomId":660000,"nick":"Tester"},"isPayRoom":0}
</script>
<script>
var STREAM_DATA = {};
stream: {"data":[{"gameLiveInfo":{"screenshot":"https://example.com/cover.jpg","gameFullName":"英雄联盟","introduction":"Test Room","nick":"Tester","avatar180":"https://example.com/avatar.jpg","totalCount":"1234567","userCount":"1234567","uid":"98765","gid":1},"gameStreamInfoList":[{"sStreamName":"teststream","sCdnType":"AL","sFlvUrl":"http://al.flv.huya.com/src","sHlsUrl":"http://al.hls.huya.com/src","sFlvAntiCode":"wsSecret=abc123&wsTime=$wsTimeHex&ratio=800&fs=bgct&ctype=huya_webh5&t=100","sHlsAntiCode":"wsSecret=def456&wsTime=$wsTimeHex&ratio=800&fs=bgct&ctype=huya_webh5&t=100","lChannelId":660000,"lSubChannelId":660000,"presenterUid":111},{"sStreamName":"teststream","sCdnType":"TX","sFlvUrl":"http://tx.flv.huya.com/src","sHlsUrl":"http://tx.hls.huya.com/src","sFlvAntiCode":"wsSecret=abc123&wsTime=$wsTimeHex&ratio=800&fs=bgct&ctype=huya_webh5&t=100","sHlsAntiCode":"wsSecret=def456&wsTime=$wsTimeHex&ratio=800&fs=bgct&ctype=huya_webh5&t=100","lChannelId":660000,"lSubChannelId":660000,"presenterUid":111}]}],"vMultiStreamInfo":[{"iBitRate":0,"sDisplayName":"原画"},{"iBitRate":2000,"sDisplayName":"蓝光8M"},{"iBitRate":800,"sDisplayName":"超清"},{"iBitRate":4000,"sDisplayName":"4K"},{"iBitRate":10000,"sDisplayName":"蓝光HDR"}]
}
</script>
</body></html>
''';
}

String futureWsTimeHex({int secondsAhead = 3600}) {
  final wsTimeSeconds =
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + secondsAhead;
  return wsTimeSeconds.toRadixString(16);
}

void main() {
  group('buildHuyaAntiCode (known fixture)', () {
    // Template "$0_$1_$2_$3" — no '+'/'/' in its base64, so query
    // round-tripping cannot mangle it.
    final fm = base64.encode(utf8.encode(r'$0_$1_$2_$3'));
    const uid = 1400000000001; // realistic anonymous uid (> 2^32)
    const stream = 'teststream';
    final now = DateTime.utc(2026, 11, 16, 12, 0, 0);
    final wsTimeSeconds = now.millisecondsSinceEpoch ~/ 1000 + 60;

    String antiCode() =>
        'fm=$fm&wsTime=${wsTimeSeconds.toRadixString(16)}'
        '&ctype=huya_webh5&t=100&fs=bgct';

    test('signs the documented template substitution', () {
      final signed = buildHuyaAntiCode(stream, uid, antiCode(), now: now);
      final params = Uri(query: signed).queryParameters;

      // Independent re-derivation from the documented algorithm.
      final seqId = uid + now.millisecondsSinceEpoch;
      final secretHash =
          md5.convert(utf8.encode('$seqId|huya_webh5|100')).toString();
      final secretStr =
          '${rotateViewerUid32(uid)}_${stream}_${secretHash}_${wsTimeSeconds.toRadixString(16)}';
      final expectedWsSecret = md5.convert(utf8.encode(secretStr)).toString();

      expect(params['wsSecret'], expectedWsSecret);
      expect(params['seqid'], seqId.toString());
      expect(params['u'], rotateViewerUid32(uid).toString());
      expect(params['wsTime'], wsTimeSeconds.toRadixString(16));
      expect(params['ctype'], 'huya_webh5');
      expect(params['ver'], '1');
      expect(params['fs'], 'bgct');
      expect(params['t'], '100');
      // `fm` is signing material, consumed locally, never in the URL.
      expect(params.containsKey('fm'), isFalse);
      expect(params.containsKey('uid'), isFalse);
      expect(params.containsKey('uuid'), isFalse);
    });

    test('expired lease throws StateError', () {
      expect(
        () => buildHuyaAntiCode(
          stream,
          uid,
          antiCode(),
          now: now.add(const Duration(minutes: 6, seconds: 1)),
        ),
        throwsStateError,
      );
    });

    test('missing wsTime throws FormatException', () {
      expect(
        () => buildHuyaAntiCode(stream, uid, 'fm=$fm&ctype=huya_webh5&t=100',
            now: now),
        throwsFormatException,
      );
    });

    test('template missing a placeholder throws FormatException', () {
      final badFm = base64.encode(utf8.encode(r'$0_$1_$2'));
      expect(
        () => buildHuyaAntiCode(
          stream,
          uid,
          'fm=$badFm&wsTime=${wsTimeSeconds.toRadixString(16)}',
          now: now,
        ),
        throwsFormatException,
      );
    });

    test('anti-code without fm is returned unchanged', () {
      const legacy = 'wsSecret=abc&wsTime=abcdef&ctype=huya_webh5&t=100';
      expect(buildHuyaAntiCode(stream, uid, legacy, now: now), legacy);
    });
  });

  group('rotateViewerUid32', () {
    test('hand-computed low-lane rotation', () {
      expect(rotateViewerUid32(0x01020304), 0x02030401);
      expect(unrotateViewerUid32(0x02030401), 0x01020304);
    });

    test('round-trips and preserves the high lane (> 2^32 uids)', () {
      for (final value in [1400000000001, 1400000000000 + 123456789, 1, 0]) {
        expect(unrotateViewerUid32(rotateViewerUid32(value)), value);
        expect(rotateViewerUid32(value) & ~0xffffffff,
            value & ~0xffffffff);
      }
    });
  });

  group('replaceQueryParameter', () {
    test('replaces ratio in place', () {
      expect(
        replaceQueryParameter('a=1&ratio=800&b=2', 'ratio', '2000'),
        'a=1&ratio=2000&b=2',
      );
    });

    test('removes ratio for 原画', () {
      expect(
        replaceQueryParameter('a=1&ratio=800&b=2', 'ratio', null),
        'a=1&b=2',
      );
    });

    test('appends when absent', () {
      expect(
        replaceQueryParameter('a=1', 'ratio', '2000'),
        'a=1&ratio=2000',
      );
    });
  });

  group('lease math', () {
    const uid = 1400000000001;
    final issuedAt = DateTime.utc(2026, 11, 16, 12, 0, 0);
    final issuedMillis = issuedAt.millisecondsSinceEpoch;
    final issuedSeconds = issuedMillis ~/ 1000;
    // wsTime 120 s after issue: signature valid until issued+420 s,
    // but the transport lease (125 s) binds first.
    final wsTimeHex = (issuedSeconds + 120).toRadixString(16);
    final seqId = uid + issuedMillis;
    late final String url;

    setUpAll(() {
      url = 'https://al.flv.huya.com/src/teststream.flv'
          '?wsSecret=abc&wsTime=$wsTimeHex&seqid=$seqId'
          '&ctype=huya_webh5&ver=1&fs=bgct&t=100&u=${rotateViewerUid32(uid)}';
    });

    test('seqid recovers the issue instant', () {
      expect(huyaSignedSequenceIssuedAt(url), issuedAt);
    });

    test('wsTime + 5 min is the signature bound', () {
      expect(
        huyaSignedUrlInvalidAt(url),
        issuedAt.add(const Duration(seconds: 420)),
      );
    });

    test('invalidAt is transport-bound at issued + 125 s', () {
      expect(
        huyaPlayUrlInvalidAt(url),
        issuedAt.add(const Duration(seconds: 125)),
      );
    });

    test('refreshAt is issued + 100 s while healthy', () {
      expect(
        huyaPlayUrlRefreshAt(url, now: issuedAt.add(const Duration(seconds: 10))),
        issuedAt.add(const Duration(seconds: 100)),
      );
    });

    test('refreshAt never returns a past deadline', () {
      final late = issuedAt.add(const Duration(seconds: 200));
      expect(huyaPlayUrlRefreshAt(url, now: late), late);
    });

    test('URLs without wsTime have no lease', () {
      const bare = 'https://al.flv.huya.com/src/teststream.flv?wsSecret=abc';
      expect(huyaSignedUrlInvalidAt(bare), isNull);
      expect(huyaPlayUrlInvalidAt(bare), isNull);
      expect(huyaPlayUrlRefreshAt(bare), isNull);
    });
  });

  group('room-page parsing (canned snippet)', () {
    test('live room: lines, bitrates, danmaku args', () {
      final room = parseHuyaRoomPage(cannedRoomPage(futureWsTimeHex()), '660000');
      expect(room.liveStatus, isTrue);
      expect(room.title, 'Test Room');
      expect(room.nick, 'Tester');
      expect(room.cover, 'https://example.com/cover.jpg');
      expect(room.avatar, 'https://example.com/avatar.jpg');
      expect(room.watching, 1234567);
      expect(room.link, 'https://www.huya.com/660000');

      final data = huyaDataOf(room)!;
      // 2 CDNs x (flv + hls) = 4 lines, server order kept.
      expect(data.lines.length, 4);
      expect(data.lines[0].cdnType, 'AL');
      expect(data.lines[0].lineType, HuyaLineType.flv);
      expect(data.lines[1].lineType, HuyaLineType.hls);
      expect(data.lines[2].cdnType, 'TX');
      expect(data.lines[0].streamName, 'teststream');
      expect(data.lines[0].presenterUid, 111);
      // HDR bitrate is skipped at room parse; 4K stays until quality parse.
      expect(data.bitRates.map((b) => b.name),
          containsAll(['原画', '蓝光8M', '超清', '4K']));
      expect(data.bitRates.map((b) => b.name), isNot(contains('蓝光HDR')));

      final danmaku = HuyaDanmakuArgs.fromDataMap(room.danmakuData)!;
      expect(danmaku.topSid, 660000);
      expect(danmaku.subSid, 660000);
      expect(danmaku.uid, 98765);
    });

    test('qualities: 4K excluded, no invented 2000, 0 = 原画', () {
      final room = parseHuyaRoomPage(cannedRoomPage(futureWsTimeHex()), '660000');
      final qualities = parseHuyaPlayQualities(huyaDataOf(room)!);
      expect(qualities.map((q) => q.quality), ['原画', '蓝光8M', '超清']);
      expect(qualities.map((q) => q.id), ['0', '2000', '800']);
      expect(qualities.first.data['bitRate'], 0);
      expect(qualities[1].data['bitRate'], 2000);
      // All qualities share the same line list.
      expect((qualities.first.data['urls'] as List).length, 4);
    });

    test('empty bitRates offers a single 原画 entry', () {
      const data = HuyaUrlDataModel(
        bitRates: [],
        lines: [
          HuyaLineModel(
            line: 'http://al.flv.huya.com/src',
            lineType: HuyaLineType.flv,
            flvAntiCode: 'wsSecret=x',
            hlsAntiCode: '',
            streamName: 's',
            cdnType: 'AL',
            presenterUid: 1,
          ),
        ],
        url: '',
        uid: '',
        isXingxiu: false,
      );
      final qualities = parseHuyaPlayQualities(data);
      expect(qualities.length, 1);
      expect(qualities.first.quality, '原画');
      expect(qualities.first.id, '0');
    });

    test('offline room parses without throwing', () {
      final html = cannedRoomPage(futureWsTimeHex())
          .replaceAll('"state":"ON"', '"state":"OFF"');
      final room = parseHuyaRoomPage(html, '660000');
      expect(room.liveStatus, isFalse);
      expect(huyaDataOf(room)!.lines, isEmpty);
      // Upstream quirk: empty bitRates still yields one 原画 entry.
      // Harmless in practice — qualities are only consulted for live
      // rooms, and recovery returns empty URLs for offline rooms first.
      expect(parseHuyaPlayQualities(huyaDataOf(room)!).length, 1);
    });

    test('page without room blobs throws FormatException', () {
      expect(
        () => parseHuyaRoomPage('<html></html>', '660000'),
        throwsFormatException,
      );
    });

    test('nested braces in TT_ROOM_DATA survive extraction', () {
      final room = parseHuyaRoomPage(cannedRoomPage(futureWsTimeHex()), '660000');
      // The canned profile object {"roomId":660000,...} is nested; if the
      // regex's non-greedy `}` had truncated it, parsing would have failed.
      expect(room.liveStatus, isTrue);
    });
  });

  group('cache.php + search parsing', () {
    test('cache list maps datas[] to rooms', () {
      final rooms = parseHuyaCacheList({
        'data': {
          'datas': [
            {
              'profileRoom': '660000',
              'screenshot': 'https://example.com/c.jpg',
              'introduction': 'Hi',
              'nick': 'N',
              'avatar180': 'https://example.com/a.jpg',
              'totalCount': '999',
            },
            {'profileRoom': '660001', 'roomName': 'Fallback Title'},
          ],
        },
      });
      expect(rooms.length, 2);
      expect(rooms[0].title, 'Hi');
      expect(rooms[0].watching, 999);
      expect(rooms[0].cover, contains('x-oss-process=style/w338_h190'));
      expect(rooms[1].title, 'Fallback Title');
    });

    test('dead category API returns an empty list, not faked rooms', () {
      expect(parseHuyaCacheList({'data': {'datas': []}}), isEmpty);
      expect(parseHuyaCacheList({'data': {}}), isEmpty);
    });

    test('search rooms maps response["3"]["docs"]', () {
      final rooms = parseHuyaSearchRooms({
        'response': {
          '3': {
            'docs': [
              {
                'room_id': '660000',
                'game_screenshot': 'https://example.com/c.jpg',
                'game_introduction': 'Found',
                'game_nick': 'N',
                'game_imgUrl': 'https://example.com/a.jpg',
                'game_total_count': '42',
              },
            ],
          },
        },
      });
      expect(rooms.length, 1);
      expect(rooms[0].roomId, '660000');
      expect(rooms[0].title, 'Found');
      expect(rooms[0].watching, 42);
    });
  });

  group('line identity by URL (transport policy)', () {
    const txFlv =
        'https://tx.flv.huya.com/src/s.flv?wsSecret=a&wsTime=aa&seqid=1';
    const txHls =
        'https://tx.hls.huya.com/src/s.m3u8?wsSecret=a&wsTime=aa&seqid=1';
    const alFlv =
        'https://al.flv.huya.com/src/s.flv?wsSecret=a&wsTime=aa&seqid=1';
    const alHls =
        'https://al.hls.huya.com/src/s.m3u8?wsSecret=a&wsTime=aa&seqid=1';

    test('refresh reordering does not move the line', () {
      // Original order [txFlv, txHls, alFlv]; refreshed order shuffled.
      final refreshed = [alHls, txFlv, alFlv, txHls];
      expect(
        HuyaTransportPolicy.selectRefreshedLine(
          urls: refreshed,
          currentUrl: txFlv,
          currentLineIndex: 0,
          advanceLine: false,
        ),
        refreshed.indexOf(txFlv),
      );
    });

    test('advanceLine walks the same-format pool, not the raw index', () {
      final refreshed = [alHls, txFlv, alFlv, txHls];
      final next = HuyaTransportPolicy.selectRefreshedLine(
        urls: refreshed,
        currentUrl: txFlv,
        currentLineIndex: 1,
        advanceLine: true,
      );
      // Same-format (FLV) pool is [txFlv, alFlv] in list order; next
      // after txFlv wraps to alFlv.
      expect(refreshed[next], alFlv);
    });

    test('a rotated stream name still matches by CDN + format', () {
      const txFlvNew =
          'https://tx.flv.huya.com/src/s2.flv?wsSecret=b&wsTime=bb&seqid=2';
      final refreshed = [alFlv, txFlvNew];
      expect(
        HuyaTransportPolicy.selectRefreshedLine(
          urls: refreshed,
          currentUrl: txFlv,
          currentLineIndex: 0,
          advanceLine: false,
        ),
        refreshed.indexOf(txFlvNew),
      );
    });

    test('HLS stays HLS unless it actually failed', () {
      final refreshed = [alFlv, txHls, alHls];
      expect(
        HuyaTransportPolicy.selectRefreshedLine(
          urls: refreshed,
          currentUrl: txHls,
          currentLineIndex: 1,
          advanceLine: false,
        ),
        refreshed.indexOf(txHls),
      );
    });

    test('non-Huya current URL falls back to the legacy index', () {
      expect(
        HuyaTransportPolicy.selectRefreshedLine(
          urls: [alFlv, txFlv],
          currentUrl: 'https://example.com/other.flv',
          currentLineIndex: 1,
          advanceLine: false,
        ),
        1,
      );
    });

    test('native FLV credential marker', () {
      const native =
          'https://tx.flv.huya.com/src/s.flv?ctype=huya_pc_exe&t=100&wsSecret=a';
      const web =
          'https://tx.flv.huya.com/src/s.flv?ctype=huya_webh5&t=100&wsSecret=a';
      expect(HuyaTransportPolicy.hasNativeFlvCredential(native), isTrue);
      expect(HuyaTransportPolicy.hasNativeFlvCredential(web), isFalse);
      expect(HuyaTransportPolicy.hasShortTransportLease(web), isTrue);
      expect(HuyaTransportPolicy.hasShortTransportLease(native), isFalse);
    });
  });

  group('HuyaSite end-to-end with stubbed Dio', () {
    late Dio stubDio;

    setUp(() {
      stubDio = Dio();
      stubDio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('udblgn.huya.com')) {
            return handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'data': {'uid': 1400000000001},
              },
            ));
          }
          if (options.path.contains('www.huya.com/660000')) {
            return handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: cannedRoomPage(futureWsTimeHex()),
            ));
          }
          return handler.next(options);
        },
      ));
    });

    test('room detail -> qualities -> signed URLs -> recovery', () async {
      // Native WUP is stubbed out here so the test stays offline and
      // deterministic; the native path is covered in its own group below.
      final site = HuyaSite(
        dio: stubDio,
        nativeTokenFetcher: (_) async =>
            throw StateError('WUP stubbed out in this test'),
      );
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: '660000', platform: 'huya'),
      );
      expect(room.liveStatus, isTrue);

      final qualities = await site.getPlayQualities(liveRoom: room);
      expect(qualities.map((q) => q.quality), ['原画', '蓝光8M', '超清']);

      final quality2000 =
          qualities.firstWhere((q) => q.id == '2000');
      final urls = await site.getPlayUrls(liveRoom: room, quality: quality2000);
      expect(urls.length, 4);
      for (final url in urls) {
        expect(url, startsWith('https://'));
        expect(url, contains('ratio=2000'));
        expect(url, contains('codec=264'));
      }
      expect(urls.where((u) => u.contains('.flv?')).length, 2);
      expect(urls.where((u) => u.contains('.m3u8?')).length, 2);

      // 原画 removes `ratio`.
      final origin = qualities.firstWhere((q) => q.id == '0');
      final originUrls =
          await site.getPlayUrls(liveRoom: room, quality: origin);
      expect(originUrls.length, 4);
      for (final url in originUrls) {
        expect(url, isNot(contains('ratio=')));
      }

      // Resolution carries lease times + stream facts.
      final resolution =
          await site.resolvePlayUrls(liveRoom: room, quality: quality2000);
      expect(resolution.urls.length, 4);
      expect(resolution.appliedQualityData, '2000');
      expect(resolution.refreshAt, isNotNull);
      expect(resolution.invalidAt, isNotNull);
      expect(
        resolution.refreshAt!.difference(resolution.issuedAt!).inSeconds,
        inInclusiveRange(95, 105),
      );
      expect(
        resolution.invalidAt!.difference(resolution.issuedAt!).inSeconds,
        inInclusiveRange(120, 130),
      );
      expect(resolution.streamFacts.map((f) => f.format),
          ['flv', 'hls', 'flv', 'hls']);
      expect(
        site.getPlayUrlRefreshAt(resolution.urls.first),
        isNotNull,
      );
      expect(
        site.getPlayUrlInvalidAt(resolution.urls.first),
        isNotNull,
      );

      // Recovery re-fetches and rebuilds (stub serves the same page).
      final recovered = await site.resolvePlayUrlsForRecovery(
          liveRoom: room, quality: quality2000);
      expect(recovered.urls.length, 4);
      expect(recovered.appliedQualityData, '2000');
    });

    test('anonymous identity is cached across calls', () async {
      var loginCalls = 0;
      final counting = Dio();
      counting.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('udblgn.huya.com')) {
            loginCalls++;
            return handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'data': {'uid': 1400000000001},
              },
            ));
          }
          return handler.next(options);
        },
      ));
      final site = HuyaSite(dio: counting);
      final first = await site.resolveViewerIdentity();
      final second = await site.resolveViewerIdentity();
      expect(first.uid, 1400000000001);
      expect(second.uid, first.uid);
      expect(loginCalls, 1);
    });
  });

  group('native WUP token (stubbed fetchers)', () {
    late Dio stubDio;

    /// Canned native-token anti-code: fm template + future wsTime +
    /// ctype=huya_pc_exe (the native marker) + t=100. Signable by
    /// buildHuyaAntiCode.
    String nativeAntiCode({int secondsAhead = 3600}) {
      final fm = base64.encode(utf8.encode(r'$0_$1_$2_$3'));
      final wsTimeSeconds =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + secondsAhead;
      return 'fm=$fm&wsTime=${wsTimeSeconds.toRadixString(16)}'
          '&ctype=huya_pc_exe&t=100&fs=bgct';
    }

    HuyaCdnTokenLease cannedNativeLease() =>
        HuyaCdnTokenLease.fromResponse(
          GetCdnTokenExResp()
            ..sFlvToken = nativeAntiCode()
            ..iExpireTime = 420,
        );

    setUp(() {
      stubDio = Dio();
      stubDio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('udblgn.huya.com')) {
            return handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: {
                'data': {'uid': 1400000000001},
              },
            ));
          }
          if (options.path.contains('www.huya.com/660000')) {
            return handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: cannedRoomPage(futureWsTimeHex()),
            ));
          }
          return handler.next(options);
        },
      ));
    });

    Future<HuyaSite> detailedSite({
      HuyaNativeTokenFetcher? nativeTokenFetcher,
      HuyaWebTokenFetcher? webTokenFetcher,
    }) async {
      final site = HuyaSite(
        dio: stubDio,
        nativeTokenFetcher: nativeTokenFetcher,
        webTokenFetcher: webTokenFetcher,
      );
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: '660000', platform: 'huya'),
      );
      expect(room.liveStatus, isTrue);
      return site;
    }

    test('FLV prefers the native token; HLS never uses it', () async {
      var nativeCalls = 0;
      final site = await detailedSite(
        nativeTokenFetcher: (_) async {
          nativeCalls++;
          return cannedNativeLease();
        },
      );
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: '660000', platform: 'huya'),
      );
      final qualities = await site.getPlayQualities(liveRoom: room);
      final urls = await site.getPlayUrls(
        liveRoom: room,
        quality: qualities.firstWhere((q) => q.id == '2000'),
      );
      expect(urls.length, 4);
      final flvUrls = urls.where((u) => u.contains('.flv?')).toList();
      final hlsUrls = urls.where((u) => u.contains('.m3u8?')).toList();
      expect(flvUrls.length, 2);
      expect(hlsUrls.length, 2);
      for (final url in flvUrls) {
        expect(url, contains('ctype=huya_pc_exe'));
        expect(HuyaTransportPolicy.hasNativeFlvCredential(url), isTrue);
        expect(HuyaTransportPolicy.hasShortTransportLease(url), isFalse);
      }
      for (final url in hlsUrls) {
        expect(url, contains('ctype=huya_webh5'));
      }
      // Two FLV lines share one stream name -> one in-flight WUP call.
      expect(nativeCalls, 1);
    });

    test('native token lease drives refresh/invalid (long lease)', () async {
      final site = await detailedSite(
        nativeTokenFetcher: (_) async => cannedNativeLease(),
      );
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: '660000', platform: 'huya'),
      );
      final qualities = await site.getPlayQualities(liveRoom: room);
      final urls = await site.getPlayUrls(
        liveRoom: room,
        quality: qualities.firstWhere((q) => q.id == '2000'),
      );
      final now = DateTime.now().toUtc();
      final flvUrl = urls.firstWhere((u) => u.contains('.flv?'));
      final hlsUrl = urls.firstWhere((u) => u.contains('.m3u8?'));
      // Native lease: invalidAt ~now+420 s, refreshAt ~now+390 s
      // (iExpireTime 420 caps the wsTime+5min bound).
      expect(
        site.getPlayUrlRefreshAt(flvUrl)!.difference(now).inSeconds,
        inInclusiveRange(380, 400),
      );
      expect(
        site.getPlayUrlInvalidAt(flvUrl)!.difference(now).inSeconds,
        inInclusiveRange(410, 430),
      );
      // HLS stays on the short web-template lease (~100 s / ~125 s).
      expect(
        site.getPlayUrlRefreshAt(hlsUrl)!.difference(now).inSeconds,
        inInclusiveRange(90, 105),
      );
      expect(
        site.getPlayUrlInvalidAt(hlsUrl)!.difference(now).inSeconds,
        inInclusiveRange(120, 130),
      );
    });

    test('native WUP failure falls back to the web template', () async {
      final site = await detailedSite(
        nativeTokenFetcher: (_) async =>
            throw const FormatException('WUP down'),
      );
      final room = await site.getRoomDetail(
        const LiveRoom(roomId: '660000', platform: 'huya'),
      );
      final qualities = await site.getPlayQualities(liveRoom: room);
      final urls = await site.getPlayUrls(
        liveRoom: room,
        quality: qualities.firstWhere((q) => q.id == '2000'),
      );
      expect(urls.length, 4);
      final flvUrl = urls.firstWhere((u) => u.contains('.flv?'));
      expect(flvUrl, contains('ctype=huya_webh5'));
      expect(HuyaTransportPolicy.hasNativeFlvCredential(flvUrl), isFalse);
      final now = DateTime.now().toUtc();
      expect(
        site.getPlayUrlRefreshAt(flvUrl)!.difference(now).inSeconds,
        inInclusiveRange(90, 105),
      );
    });

    test('unsignable room template falls back to web-identity WUP',
        () async {
      // fm template whose wsTime already expired: buildHuyaAntiCode
      // throws, so the web-identity WUP token is tried next.
      final expiredFm = base64.encode(utf8.encode(r'$0_$1_$2_$3'));
      final expiredWsTime =
          (DateTime.now().millisecondsSinceEpoch ~/ 1000 - 3600)
              .toRadixString(16);
      const line = HuyaLineModel(
        line: 'http://al.flv.huya.com/src',
        lineType: HuyaLineType.flv,
        flvAntiCode: '',
        hlsAntiCode: '',
        streamName: 'teststream',
        cdnType: 'AL',
        presenterUid: 111,
      );
      final expiredLine = HuyaLineModel(
        line: line.line,
        lineType: line.lineType,
        flvAntiCode: 'fm=$expiredFm&wsTime=$expiredWsTime'
            '&ctype=huya_webh5&t=100&fs=bgct',
        hlsAntiCode: '',
        streamName: line.streamName,
        cdnType: line.cdnType,
        presenterUid: line.presenterUid,
      );
      var webCalls = 0;
      final site = HuyaSite(
        dio: stubDio,
        nativeTokenFetcher: (_) async =>
            throw StateError('native unavailable'),
        webTokenFetcher: (_, _) async {
          webCalls++;
          return cannedNativeLease();
        },
      );
      final url = await site.getPlayUrl(expiredLine, 0);
      expect(webCalls, 1);
      expect(url, contains('ctype=huya_pc_exe'));
      expect(url, startsWith('https://al.flv.huya.com/src/teststream.flv?'));
    });
  });

  group('getSuperChatMessage (stubbed fetcher)', () {
    LiveSuperChatMessage sc(int id, String text) => LiveSuperChatMessage(
          messageId: 'huya:$id',
          backgroundBottomColor: '#246488',
          backgroundColor: '#ffffff',
          endTime: DateTime.now().add(const Duration(minutes: 1)),
          face: '',
          message: text,
          price: 10,
          startTime: DateTime.now(),
          userName: 'Fan$id',
        );

    test('room with danmakuData returns board as LiveMessages', () async {
      final site = HuyaSite(
        superChatFetcher: (lPid) async {
          expect(lPid, 660000);
          return <LiveSuperChatMessage>[sc(1, 'SC one'), sc(2, 'SC two')];
        },
      );
      final room = const LiveRoom(
        roomId: '660000',
        platform: 'huya',
        liveStatus: true,
        danmakuData: <String, dynamic>{
          'uid': 98765,
          'topSid': 660000,
          'subSid': 660000,
        },
      );
      final messages = await site.getSuperChatMessage(liveRoom: room);
      expect(messages.length, 2);
      for (final m in messages) {
        expect(m.type, LiveMessageType.superChat);
        expect(m.data, isA<LiveSuperChatMessage>());
      }
      expect((messages[0].data as LiveSuperChatMessage).message, 'SC one');
      expect((messages[1].data as LiveSuperChatMessage).message, 'SC two');
    });

    test('fetcher failure returns [] instead of throwing', () async {
      final site = HuyaSite(
        superChatFetcher: (lPid) async =>
            throw const FormatException('WUP down'),
      );
      const room = LiveRoom(
        roomId: '660000',
        platform: 'huya',
        liveStatus: true,
        danmakuData: <String, dynamic>{
          'uid': 98765,
          'topSid': 660000,
          'subSid': 660000,
        },
      );
      expect(await site.getSuperChatMessage(liveRoom: room), isEmpty);
    });

    test('room without danmakuData refetches detail first', () async {
      final stubDio = Dio();
      stubDio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          if (options.path.contains('www.huya.com/660000')) {
            return handler.resolve(Response<dynamic>(
              requestOptions: options,
              statusCode: 200,
              data: cannedRoomPage(futureWsTimeHex()),
            ));
          }
          return handler.next(options);
        },
      ));
      final site = HuyaSite(
        dio: stubDio,
        superChatFetcher: (lPid) async {
          expect(lPid, 660000);
          return <LiveSuperChatMessage>[sc(9, 'Refetched SC')];
        },
      );
      const room = LiveRoom(roomId: '660000', platform: 'huya');
      final messages = await site.getSuperChatMessage(liveRoom: room);
      expect(messages.length, 1);
      expect(
        (messages.first.data as LiveSuperChatMessage).message,
        'Refetched SC',
      );
    });
  });

  group('categories (bussLive)', () {
    test('parseHuyaCategories handles double/int/Map/String gids', () {
      final areas = HuyaSite.parseHuyaCategories(<String, dynamic>{
        'status': 200,
        'data': [
          {'gid': 1.0, 'gameFullName': '英雄联盟'},
          {'gid': 862, 'gameFullName': 'CS2'},
          {
            'gid': {'value': '5937,5938'},
            'gameFullName': '无畏契约',
          },
          {'gid': '4', 'gameFullName': '穿越火线'},
          {'gid': '', 'gameFullName': 'NoId'},
          {'gid': 7, 'gameFullName': ''},
          {'gameFullName': 'NoGid'},
        ],
      });
      expect(
        areas.map((a) => a.areaId),
        ['1', '862', '5937', '4'],
      );
      expect(
        areas.map((a) => a.areaName),
        ['英雄联盟', 'CS2', '无畏契约', '穿越火线'],
      );
      expect(areas.first.areaPic, contains('1-MS.jpg'));
      expect(areas.every((a) => a.platform == 'huya'), isTrue);
    });

    test('parseHuyaCategories returns empty on a bad payload', () {
      expect(HuyaSite.parseHuyaCategories(null), isEmpty);
      expect(HuyaSite.parseHuyaCategories({'data': 'nope'}), isEmpty);
    });

    test('getCategories merges bussLive types, falls back when all fail',
        () async {
      final stubDio = Dio();
      stubDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) {
            if (options.path.contains('bussLive')) {
              if (options.queryParameters['bussType'] == '1') {
                return handler.resolve(
                  Response<dynamic>(
                    requestOptions: options,
                    statusCode: 200,
                    data: {
                      'status': 200,
                      'data': [
                        {'gid': 1.0, 'gameFullName': '英雄联盟'},
                      ],
                    },
                  ),
                );
              }
              return handler.reject(
                DioException(requestOptions: options),
              );
            }
            return handler.next(options);
          },
        ),
      );
      final site = HuyaSite(dio: stubDio);
      final areas = await site.getCategories();
      // One live type is enough; the three dead ones must not kill it.
      expect(areas.map((a) => a.areaName), contains('英雄联盟'));

      final deadDio = Dio();
      deadDio.interceptors.add(
        InterceptorsWrapper(
          onRequest: (options, handler) =>
              handler.reject(DioException(requestOptions: options)),
        ),
      );
      final fallback = await HuyaSite(dio: deadDio).getCategories();
      // Verified-popular gids, never blank.
      expect(fallback, isNotEmpty);
      expect(
        fallback.every((a) => int.tryParse(a.areaId) != null),
        isTrue,
      );
      expect(fallback.map((a) => a.areaName), contains('英雄联盟'));
    });
  });
}
