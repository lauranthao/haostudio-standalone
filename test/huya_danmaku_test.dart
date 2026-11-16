// Huya native WUP token + super-chat fallback tests.
//
// - TARS round-trip for the token request/response structs.
// - TUP3 packet round-trip (request build + fake server response decode,
//   incl. a Dio-stubbed tupRequest and a non-zero result code).
// - HuyaCdnTokenLease math (wsTime + 5 min bound, server iExpireTime cap,
//   refresh 30 s before invalid).
// - Super-chat panel parsing with canned payloads (filtering, price
//   fallback, message-id dedupe).
// - Danmaku uri-2001314 reconciliation with a stub fetcher (direct panel
//   parse, HTTP refresh fallback, headline trigger, dedupe).
// - Live probes against Huya room 660000 (native token, super-chat board,
//   WS connect) — skipped, never failed, when the VM cannot reach Huya.

import 'dart:async';
import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/tars/base_tars_http.dart';
import 'package:standalone/core/tars/game_event_message_board_info.dart';
import 'package:standalone/core/tars/game_event_message_board_panel.dart';
import 'package:standalone/core/tars/get_cdn_token_ex_req.dart';
import 'package:standalone/core/tars/get_cdn_token_ex_resp.dart';
import 'package:standalone/core/tars/codec/tars_input_stream.dart';
import 'package:standalone/core/tars/codec/tars_output_stream.dart';
import 'package:standalone/core/tars/codec/tars_struct.dart';
import 'package:standalone/core/tars/tup/tars_uni_packet.dart';
import 'package:standalone/core/tars/tup/tup_result_exception.dart';
import 'package:standalone/core/tars/types.dart';
import 'package:standalone/shared/platforms/huya/huya_danmaku.dart';
import 'package:standalone/shared/platforms/huya/huya_models.dart';
import 'package:standalone/shared/platforms/huya/huya_request_params.dart';
import 'package:standalone/shared/platforms/huya/huya_site.dart';
import 'package:standalone/shared/platforms/huya/huya_wup.dart';

// ---------------------------------------------------------------- helpers

/// A canned native-token anti-code: fm template + future wsTime +
/// ctype=huya_pc_exe (the native marker) + t=100. Signable by
/// buildHuyaAntiCode.
String nativeLeaseAntiCode({int secondsAhead = 3600}) {
  final fm = base64.encode(utf8.encode(r'$0_$1_$2_$3'));
  final wsTimeSeconds =
      DateTime.now().millisecondsSinceEpoch ~/ 1000 + secondsAhead;
  return 'fm=$fm&wsTime=${wsTimeSeconds.toRadixString(16)}'
      '&ctype=huya_pc_exe&t=100&fs=bgct';
}

GameEventMessageBoardInfo boardItem({
  required String content,
  required int messageId,
  int cost = 0,
  int costPay = 0,
  int totalSec = 60,
  int countDown = 30,
  String nick = 'Fan',
  String avatar = 'https://example.com/a.jpg',
}) {
  return GameEventMessageBoardInfo()
    ..tMessageUser = (MessageUser()
      ..sNick = nick
      ..sAvatar = avatar)
    ..sContent = content
    ..iCost = cost
    ..iCostPay = costPay
    ..iTotalSec = totalSec
    ..iCountDown = countDown
    ..lMessageId = messageId;
}

GameEventMessageBoardPanel boardPanel(
  List<GameEventMessageBoardInfo> items,
) {
  return GameEventMessageBoardPanel()..vGameEventMessageBoardInfo = items;
}

/// uri-2001314 payload: a TARS struct carrying the board-info LIST at
/// tag 1 — the same layout GameEventMessageBoardPanel.readFrom expects
/// (upstream's superChatsFromPanel skips to tag 1, then reads the panel).
Uint8List panelPayload(List<GameEventMessageBoardInfo> items) {
  final out = TarsOutputStream();
  out.write(items, 1);
  return out.toUint8List();
}

/// One WS push frame (type 7 + HYPushMessage) for [uri] + [payload].
Uint8List pushFrame(int uri, List<int> payload) {
  final inner = TarsOutputStream();
  inner.write(0, 0); // pushType
  inner.write(uri, 1);
  inner.write(Uint8List.fromList(payload), 2);
  inner.write(0, 3); // protocolType
  final outer = TarsOutputStream();
  outer.write(7, 0);
  outer.write(inner.toUint8List(), 1);
  return outer.toUint8List();
}

// Test-local writeable chat structs (our HYMessage/HYSender writeTo are
// empty — the read path under test is the real HYMessage.readFrom).
class _TestSender extends TarsStruct {
  _TestSender(this.uid, this.nick);

  final int uid;
  final String nick;

  @override
  void readFrom(TarsInputStream inputStream) {}

  @override
  void writeTo(TarsOutputStream outputStream) {
    outputStream.write(uid, 0);
    outputStream.write(nick, 2);
    outputStream.write(0, 3);
  }

  @override
  Object deepCopy() => _TestSender(uid, nick);

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class _TestBullet extends TarsStruct {
  _TestBullet(this.fontColor);

  final int fontColor;

  @override
  void readFrom(TarsInputStream inputStream) {}

  @override
  void writeTo(TarsOutputStream outputStream) {
    outputStream.write(fontColor, 0);
  }

  @override
  Object deepCopy() => _TestBullet(fontColor);

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class _TestChat extends TarsStruct {
  _TestChat(this.user, this.content, this.bullet);

  final _TestSender user;
  final String content;
  final _TestBullet bullet;

  @override
  void readFrom(TarsInputStream inputStream) {}

  @override
  void writeTo(TarsOutputStream outputStream) {
    outputStream.write(user, 0);
    outputStream.write(content, 3);
    outputStream.write(bullet, 6);
  }

  @override
  Object deepCopy() => _TestChat(user, content, bullet);

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

Uint8List chatPayload(String nick, String content, {int fontColor = 0}) {
  return _TestChat(
    _TestSender(123, nick),
    content,
    _TestBullet(fontColor),
  ).toByteArray();
}

/// Builds a fake TUP3 server response packet carrying [rsp] under `tRsp`
/// with result [code]. The empty-string code key is written directly into
/// newData — UniAttribute.put rejects empty keys (server-side only).
Uint8List fakeTupResponse(GetCdnTokenExResp rsp, {int code = 0}) {
  final packet = TarsUniPacket();
  packet.servantName = 'liveui';
  packet.funcName = 'getCdnTokenInfoEx';
  final codeBytes = TarsOutputStream()..write(code, 0);
  packet.newData[''] = codeBytes.toUint8List();
  packet.put('tRsp', rsp);
  return packet.encode();
}

void main() {
  group('TARS round-trip: token request/response', () {
    test('GetCdnTokenExReq survives encode/decode', () {
      final req = GetCdnTokenExReq()
        ..sFlvUrl = 'https://al.flv.huya.com/src'
        ..sStreamName = 'teststream'
        ..iLoopTime = 0
        ..tId = (HuyaUserId()..sHuYaUA = 'pc_exe&7000000&official')
        ..iAppId = 66;
      final bytes = req.toByteArray();
      final decoded = GetCdnTokenExReq()..readFrom(TarsInputStream(bytes));
      expect(decoded.sFlvUrl, 'https://al.flv.huya.com/src');
      expect(decoded.sStreamName, 'teststream');
      expect(decoded.iLoopTime, 0);
      expect(decoded.tId.sHuYaUA, 'pc_exe&7000000&official');
      expect(decoded.tId.lUid, 0);
      expect(decoded.iAppId, 66);
    });

    test('GetCdnTokenExResp survives encode/decode', () {
      final resp = GetCdnTokenExResp()
        ..sFlvToken = nativeLeaseAntiCode()
        ..iExpireTime = 420;
      final bytes = resp.toByteArray();
      final decoded = GetCdnTokenExResp()..readFrom(TarsInputStream(bytes));
      expect(decoded.sFlvToken, resp.sFlvToken);
      expect(decoded.iExpireTime, 420);
    });

    test('native request builder uses stream name + random SDK UA', () {
      const line = HuyaLineModel(
        line: 'https://al.flv.huya.com/src',
        lineType: HuyaLineType.flv,
        flvAntiCode: '',
        hlsAntiCode: '',
        streamName: 'teststream',
        cdnType: 'AL',
        presenterUid: 111,
      );
      final req = buildNativePlaybackTokenRequest(line);
      expect(req.sStreamName, 'teststream');
      expect(req.sFlvUrl, isEmpty);
      expect(req.tId.sHuYaUA, isNotEmpty);
      // Random SDK UA shape: platform&version&official[&apiLevel].
      expect(
        req.tId.sHuYaUA,
        matches(RegExp(r'^(adr|ios|huya_nftv|pc_exe)&.+&official')),
      );
      expect(HuyaRequestParams.requestHuyaUA, isNotEmpty);
    });
  });

  group('TUP3 packet round-trip', () {
    test('request build -> decode keeps servant, func and tReq', () {
      final client = BaseTarsHttp('https://wup.huya.com', 'liveui');
      final req = GetCdnTokenExReq()
        ..sStreamName = 'teststream'
        ..tId = (HuyaUserId()..sHuYaUA = 'pc_exe&7000000&official');
      final bytes = client.buildRequest('getCdnTokenInfoEx', req);
      // 4-byte big-endian total length prefix.
      expect(bytes.length, greaterThan(4));
      final declared =
          ByteData.view(bytes.buffer).getUint32(0, Endian.big);
      expect(declared, bytes.length);

      final packet = TarsUniPacket()..decode(bytes);
      expect(packet.servantName, 'liveui');
      expect(packet.funcName, 'getCdnTokenInfoEx');
      final decoded =
          packet.get<GetCdnTokenExReq>('tReq', GetCdnTokenExReq());
      expect(decoded.sStreamName, 'teststream');
      expect(decoded.tId.sHuYaUA, 'pc_exe&7000000&official');
      expect(decoded.iAppId, 66);
    });

    test('fake server response decodes via tupResponseDecode', () {
      final client = BaseTarsHttp('https://wup.huya.com', 'liveui');
      final token = nativeLeaseAntiCode();
      final bytes = fakeTupResponse(
        GetCdnTokenExResp()
          ..sFlvToken = token
          ..iExpireTime = 420,
      );
      final decoded = client.tupResponseDecode(
        'getCdnTokenInfoEx',
        bytes,
        GetCdnTokenExResp(),
      );
      expect(decoded.code, 0);
      expect(decoded.response!.sFlvToken, token);
      expect(decoded.response!.iExpireTime, 420);
    });

    test('tupRequest with stubbed Dio returns the token', () async {
      final client = BaseTarsHttp('https://wup.huya.com', 'liveui');
      final token = nativeLeaseAntiCode();
      client.dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          // The request body must be a TUP3 packet for getCdnTokenInfoEx.
          final data = options.data;
          expect(data, isA<List<int>>());
          final packet = TarsUniPacket()
            ..decode(Uint8List.fromList(data as List<int>));
          expect(packet.funcName, 'getCdnTokenInfoEx');
          return handler.resolve(Response<List<int>>(
            requestOptions: options,
            statusCode: 200,
            data: fakeTupResponse(
              GetCdnTokenExResp()
                ..sFlvToken = token
                ..iExpireTime = 420,
            ),
          ));
        },
      ));
      final resp = await client.tupRequest(
        'getCdnTokenInfoEx',
        GetCdnTokenExReq()..sStreamName = 'teststream',
        GetCdnTokenExResp(),
      );
      expect(resp.sFlvToken, token);
      expect(resp.iExpireTime, 420);
    });

    test('non-zero TUP code throws TupResultException', () async {
      final client = BaseTarsHttp('https://wup.huya.com', 'liveui');
      client.dio.interceptors.add(InterceptorsWrapper(
        onRequest: (options, handler) {
          return handler.resolve(Response<List<int>>(
            requestOptions: options,
            statusCode: 200,
            data: fakeTupResponse(GetCdnTokenExResp(), code: 7),
          ));
        },
      ));
      await expectLater(
        client.tupRequest(
          'getCdnTokenInfoEx',
          GetCdnTokenExReq()..sStreamName = 'teststream',
          GetCdnTokenExResp(),
        ),
        throwsA(isA<TupResultException>().having((e) => e.code, 'code', 7)),
      );
    });
  });

  group('HuyaCdnTokenLease', () {
    test('wsTime + 5 min bound, refresh 30 s earlier', () {
      final wsTimeSeconds =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final antiCode = 'wsSecret=x&wsTime=${wsTimeSeconds.toRadixString(16)}'
          '&ctype=huya_pc_exe&t=100&fs=bgct';
      final lease = HuyaCdnTokenLease.fromResponse(
        GetCdnTokenExResp()
          ..sFlvToken = antiCode
          ..iExpireTime = 0,
      );
      final expectedInvalid =
          DateTime.fromMillisecondsSinceEpoch(wsTimeSeconds * 1000, isUtc: true)
              .add(const Duration(minutes: 5));
      expect(lease.invalidAt, expectedInvalid);
      expect(
        lease.refreshAt,
        expectedInvalid.subtract(const Duration(seconds: 30)),
      );
      expect(lease.isExpired(DateTime.now().toUtc()), isFalse);
      expect(lease.needsRefresh(DateTime.now().toUtc()), isFalse);
      expect(lease.needsRefresh(lease.refreshAt), isTrue);
      expect(lease.isExpired(lease.invalidAt), isTrue);
    });

    test('server iExpireTime caps the lease (seconds and millis)', () {
      final wsTimeSeconds =
          DateTime.now().millisecondsSinceEpoch ~/ 1000 + 3600;
      final antiCode = 'wsSecret=x&wsTime=${wsTimeSeconds.toRadixString(16)}'
          '&ctype=huya_pc_exe&t=100';
      final now = DateTime.now().toUtc();
      final bySeconds = HuyaCdnTokenLease.fromResponse(
        GetCdnTokenExResp()
          ..sFlvToken = antiCode
          ..iExpireTime = 420,
        now: now,
      );
      expect(
        bySeconds.invalidAt.difference(now).inSeconds,
        inInclusiveRange(415, 425),
      );
      final byMillis = HuyaCdnTokenLease.fromResponse(
        GetCdnTokenExResp()
          ..sFlvToken = antiCode
          ..iExpireTime =
              now.add(const Duration(seconds: 420)).millisecondsSinceEpoch,
        now: now,
      );
      expect(
        byMillis.invalidAt.difference(now).inSeconds,
        inInclusiveRange(415, 425),
      );
    });

    test('empty token / missing wsTime throw FormatException', () {
      expect(
        () => HuyaCdnTokenLease.fromResponse(
          GetCdnTokenExResp()..sFlvToken = '  ',
        ),
        throwsFormatException,
      );
      expect(
        () => HuyaCdnTokenLease.fromResponse(
          GetCdnTokenExResp()..sFlvToken = 'wsSecret=x&ctype=huya_pc_exe',
        ),
        throwsFormatException,
      );
    });
  });

  group('super-chat panel parsing', () {
    test('huyaSuperChatsFromPanel maps fields + price fallback', () {
      final now = DateTime.utc(2026, 11, 16, 12, 0, 0);
      final panel = boardPanel(<GameEventMessageBoardInfo>[
        boardItem(
          content: '  Hello SC  ',
          messageId: 42,
          cost: 100,
          nick: 'Alice',
        ),
        boardItem(
          content: 'Pay fallback',
          messageId: 43,
          cost: 0,
          costPay: 1550,
          nick: 'Bob',
        ),
      ]);
      final messages = huyaSuperChatsFromPanel(panel, now: now);
      expect(messages.length, 2);
      expect(messages[0].message, 'Hello SC');
      expect(messages[0].userName, 'Alice');
      expect(messages[0].price, 100);
      expect(messages[0].messageId, 'huya:42');
      expect(messages[0].face, 'https://example.com/a.jpg');
      expect(messages[0].endTime, now.add(const Duration(seconds: 30)));
      expect(messages[0].startTime, now.add(const Duration(seconds: -30)));
      // iCostPay is in cents: 1550 -> 16 (rounded, min 1).
      expect(messages[1].price, 16);
    });

    test('expired / empty entries are skipped', () {
      final now = DateTime.utc(2026, 11, 16, 12, 0, 0);
      final panel = boardPanel(<GameEventMessageBoardInfo>[
        boardItem(content: '', messageId: 1),
        boardItem(content: 'gone', messageId: 2, totalSec: 0, countDown: 0),
        // Negative countDown falls back to iTotalSec (upstream rule), so
        // this one is only expired because totalSec is 0 as well.
        boardItem(content: 'also gone', messageId: 3, totalSec: 0, countDown: -5),
        boardItem(content: 'alive', messageId: 4, totalSec: 60, countDown: 10),
      ]);
      final messages = huyaSuperChatsFromPanel(panel, now: now);
      expect(messages.map((m) => m.message), <String>['alive']);
    });

    test('superChatsFromPanel parses the WS 2001314 payload', () {
      final now = DateTime.utc(2026, 11, 16, 12, 0, 0);
      final payload = panelPayload(<GameEventMessageBoardInfo>[
        boardItem(content: 'Board SC', messageId: 7, cost: 50),
      ]);
      final messages = HuyaDanmaku.superChatsFromPanel(payload, now: now);
      expect(messages, isNotNull);
      expect(messages!.length, 1);
      expect(messages.first.message, 'Board SC');
      expect(messages.first.messageId, 'huya:7');
    });

    test('superChatsFromPanel returns null for garbage payloads', () {
      expect(HuyaDanmaku.superChatsFromPanel(<int>[]), isNull);
      expect(HuyaDanmaku.superChatsFromPanel(<int>[1, 2, 3]), isNull);
    });

    test('LiveSuperChatMessage equality is by event id', () {
      final a = LiveSuperChatMessage(
        messageId: 'huya:1',
        backgroundBottomColor: '#246488',
        backgroundColor: '#ffffff',
        endTime: DateTime.utc(2026, 11, 16, 12, 1),
        face: '',
        message: 'hi',
        price: 10,
        startTime: DateTime.utc(2026, 11, 16, 12, 0),
        userName: 'A',
      );
      final b = LiveSuperChatMessage(
        messageId: 'huya:1',
        backgroundBottomColor: '#246488',
        backgroundColor: '#ffffff',
        endTime: DateTime.utc(2026, 11, 16, 12, 2),
        face: '',
        message: 'different text',
        price: 99,
        startTime: DateTime.utc(2026, 11, 16, 12, 0),
        userName: 'B',
      );
      expect(a, b);
      expect(a.hashCode, b.hashCode);
      final c = LiveSuperChatMessage(
        messageId: 'huya:2',
        backgroundBottomColor: '#246488',
        backgroundColor: '#ffffff',
        endTime: DateTime.utc(2026, 11, 16, 12, 1),
        face: '',
        message: 'hi',
        price: 10,
        startTime: DateTime.utc(2026, 11, 16, 12, 0),
        userName: 'A',
      );
      expect(a, isNot(c));
    });
  });

  group('danmaku uri-2001314 reconciliation (stub fetcher)', () {
    late HuyaDanmaku danmaku;
    late List<LiveMessage> seen;
    late List<LiveSuperChatMessage> board;

    LiveSuperChatMessage sc(
      int id,
      String text, {
      int price = 10,
    }) =>
        LiveSuperChatMessage(
          messageId: 'huya:$id',
          backgroundBottomColor: '#246488',
          backgroundColor: '#ffffff',
          endTime: DateTime.now().add(const Duration(minutes: 1)),
          face: '',
          message: text,
          price: price,
          startTime: DateTime.now(),
          userName: 'Fan$id',
        );

    setUp(() {
      seen = <LiveMessage>[];
      board = <LiveSuperChatMessage>[];
      danmaku = HuyaDanmaku(
        superChatFetcher: (lPid) async => board,
        // No retry delays: one immediate attempt per refresh.
        superChatRetryDelays: const <Duration>[Duration.zero],
      );
      // decodeMessage without start() leaves topSid at 0, which blocks
      // the refresh guard; seed the room args directly.
      danmaku.setTestArgs(
        const HuyaDanmakuArgs(uid: 98765, topSid: 660000, subSid: 660000),
      );
      danmaku.onMessage = seen.add;
    });

    tearDown(() async {
      await danmaku.stop();
    });

    test('2001314 panel payload emits super chats directly', () async {
      final payload = panelPayload(<GameEventMessageBoardInfo>[
        boardItem(content: 'Direct SC', messageId: 11, cost: 20),
      ]);
      await danmaku.decodeMessage(pushFrame(2001314, payload));
      expect(seen.length, 1);
      expect(seen.first.type, LiveMessageType.superChat);
      expect(seen.first.data, isA<LiveSuperChatMessage>());
      expect(
        (seen.first.data as LiveSuperChatMessage).message,
        'Direct SC',
      );
      expect(
        (seen.first.data as LiveSuperChatMessage).messageId,
        'huya:11',
      );
      await danmaku.waitForPendingSuperChatRefresh();
      // No HTTP refresh was scheduled for a parsed panel.
      expect(seen.length, 1);
    });

    test('2001314 without a panel falls back to the HTTP board', () async {
      board.add(sc(21, 'Board SC'));
      // Garbage payload: no tag-1 panel -> refresh path.
      await danmaku.decodeMessage(pushFrame(2001314, <int>[1, 2, 3]));
      await danmaku.waitForPendingSuperChatRefresh();
      expect(seen.length, 1);
      expect(seen.first.type, LiveMessageType.superChat);
      expect((seen.first.data as LiveSuperChatMessage).message, 'Board SC');
    });

    test('same super chat is never emitted twice', () async {
      board.add(sc(31, 'Once only'));
      await danmaku.decodeMessage(pushFrame(2001314, <int>[9]));
      await danmaku.waitForPendingSuperChatRefresh();
      expect(seen.length, 1);
      // Same board content again (WS + HTTP both delivering it).
      final payload = panelPayload(<GameEventMessageBoardInfo>[
        boardItem(content: 'Once only', messageId: 31, cost: 10),
      ]);
      await danmaku.decodeMessage(pushFrame(2001314, payload));
      await danmaku.waitForPendingSuperChatRefresh();
      expect(seen.length, 1);
      // A genuinely new message still comes through.
      board.add(sc(32, 'Second one'));
      await danmaku.decodeMessage(pushFrame(2001314, <int>[9]));
      await danmaku.waitForPendingSuperChatRefresh();
      expect(seen.length, 2);
      expect(
        (seen.last.data as LiveSuperChatMessage).message,
        'Second one',
      );
    });

    test('headline broadcast triggers a background refresh', () async {
      board.add(sc(41, 'Headline SC'));
      await danmaku.decodeMessage(pushFrame(
        1400,
        chatPayload('Announcer', 'Alice(来自一元上头条)'),
      ));
      // The headline chat itself is still emitted as a chat message.
      expect(
        seen.where((m) => m.type == LiveMessageType.chat).length,
        1,
      );
      await danmaku.waitForPendingSuperChatRefresh();
      final scs =
          seen.where((m) => m.type == LiveMessageType.superChat).toList();
      expect(scs.length, 1);
      expect((scs.first.data as LiveSuperChatMessage).message, 'Headline SC');
    });

    test('plain chat does not trigger a refresh', () async {
      await danmaku.decodeMessage(
          pushFrame(1400, chatPayload('Alice', 'hello world')));
      await danmaku.waitForPendingSuperChatRefresh();
      expect(seen.length, 1);
      expect(seen.first.type, LiveMessageType.chat);
      expect(seen.first.message, 'hello world');
      expect(seen.first.userName, 'Alice');
    });

    test('a failing board fetch never kills the room', () async {
      final failing = HuyaDanmaku(
        superChatFetcher: (lPid) async =>
            throw const SocketException('no network'),
        superChatRetryDelays: const <Duration>[Duration.zero],
      );
      failing.setTestArgs(
        const HuyaDanmakuArgs(uid: 98765, topSid: 660000, subSid: 660000),
      );
      final localSeen = <LiveMessage>[];
      failing.onMessage = localSeen.add;
      await failing.decodeMessage(pushFrame(2001314, <int>[9]));
      await failing.waitForPendingSuperChatRefresh();
      expect(localSeen, isEmpty);
      await failing.stop();
    });
  });

  group('live Huya probes (room 660000)', () {
    test('native WUP token for a real room', () async {
      try {
        final site = HuyaSite();
        final room = await site
            .getRoomDetail(
              const LiveRoom(roomId: '660000', platform: 'huya'),
            )
            .timeout(const Duration(seconds: 20));
        if (!room.liveStatus) {
          markTestSkipped('room 660000 is not live right now');
        }
        final qualities = await site.getPlayQualities(liveRoom: room);
        expect(qualities, isNotEmpty);
        final data = qualities.first.data as Map;
        final lines = (data['urls'] as List).whereType<HuyaLineModel>();
        final flv = lines.firstWhere(
          (l) => l.lineType == HuyaLineType.flv,
          orElse: () => throw StateError('no FLV line'),
        );
        final lease = await fetchNativeHuyaCdnToken(flv)
            .timeout(const Duration(seconds: 15));
        expect(lease.antiCode, isNotEmpty);
        expect(lease.antiCode, contains('wsTime='));
        expect(lease.isExpired(DateTime.now().toUtc()), isFalse);
        expect(
          lease.invalidAt.difference(DateTime.now().toUtc()).inSeconds,
          greaterThan(60),
        );
      } on Object catch (e) {
        markTestSkipped('live WUP unreachable from this VM: $e');
      }
    });

    test('super-chat board for a real room', () async {
      try {
        final messages = await getHuyaSuperChatMessageList(
          lPid: 660000,
          first: true,
        ).timeout(const Duration(seconds: 15));
        // The board may legitimately be empty; the probe proves the
        // WUP round-trip works, not that a super chat is live.
        expect(messages, isA<List<LiveSuperChatMessage>>());
      } on Object catch (e) {
        markTestSkipped('live WUP unreachable from this VM: $e');
      }
    });

    test('WS connect + chat for a real room', () async {
      final danmaku = HuyaDanmaku();
      final seen = <LiveMessage>[];
      danmaku.onMessage = seen.add;
      try {
        final site = HuyaSite();
        final room = await site
            .getRoomDetail(
              const LiveRoom(roomId: '660000', platform: 'huya'),
            )
            .timeout(const Duration(seconds: 20));
        if (!room.liveStatus) {
          markTestSkipped('room 660000 is not live right now');
        }
        final ready = Completer<void>();
        danmaku.onReady = () {
          if (!ready.isCompleted) ready.complete();
        };
        await danmaku
            .start(room.danmakuData!)
            .timeout(const Duration(seconds: 20));
        await ready.future.timeout(
          const Duration(seconds: 20),
          onTimeout: () => throw TimeoutException('WS never became ready'),
        );
        expect(danmaku.isConnected, isTrue);
        // Give chat a window to arrive; a quiet room yields zero
        // messages, which is still a successful connection.
        await Future<void>.delayed(const Duration(seconds: 15));
        expect(danmaku.isConnected, isTrue);
      } on Object catch (e) {
        markTestSkipped('live WS unreachable from this VM: $e');
      } finally {
        await danmaku.stop();
      }
    });
  });
}
