// Danmaku transport unit tests — pure-protocol parsing from canned
// frames/bytes, no network. Covers:
// - Douyu text-protocol framing + STT parsing + chatmsg decode.
// - Bilibili binary frame parsing (plain, multi-packet, zlib, brotli,
//   auth ack) + DANMU_MSG dispatch.
// - Kuaishou poll response parsing (+ transport with a canned fetcher).
// - TARS encode/decode round-trip + Huya join/push framing.
// - Douyin X-Bogus signature shape, server-URL building, PushFrame /
//   ChatMessage protobuf round-trip through decodeMessage.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:fixnum/fixnum.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/models/live_models.dart';
import 'package:standalone/core/tars/codec/tars_input_stream.dart';
import 'package:standalone/core/tars/codec/tars_output_stream.dart';
import 'package:standalone/core/tars/codec/tars_struct.dart';
import 'package:standalone/shared/platforms/bilibili/bilibili_danmaku.dart';
import 'package:standalone/shared/platforms/douyin/douyin_danmaku.dart';
import 'package:standalone/shared/platforms/douyin/proto/douyin.pb.dart';
import 'package:standalone/shared/platforms/douyu/douyu_danmaku.dart';
import 'package:standalone/shared/platforms/huya/huya_danmaku.dart';
import 'package:standalone/shared/platforms/kuaishou/kuaishou_danmaku.dart';

void main() {
  group('Douyu text protocol', () {
    test('serialize/deserialize round-trip', () {
      const body = 'type@=chatmsg/nn@=Alice/txt@=hello/col@=2/';
      final frame = DouyuDanmaku.serializeDouyu(body);
      expect(DouyuDanmaku.deserializeDouyu(frame), body);
    });

    test('malformed frame decodes to null', () {
      expect(DouyuDanmaku.deserializeDouyu(const <int>[]), isNull);
      expect(DouyuDanmaku.deserializeDouyu(const <int>[1, 2, 3]), isNull);
      // Declared length far beyond the buffer.
      final bad = Uint8List(16);
      ByteData.view(bad.buffer).setUint32(0, 9999, Endian.little);
      expect(DouyuDanmaku.deserializeDouyu(bad), isNull);
    });

    test('STT parsing handles nesting and @S/@A escapes', () {
      final parsed = DouyuDanmaku.sttToJObject(
        'type@=chatmsg/nn@=Bob/txt@=hi@Sthere@Ayou/',
      );
      expect(parsed, isA<Map>());
      expect(parsed['type'], 'chatmsg');
      expect(parsed['nn'], 'Bob');
      expect(parsed['txt'], 'hi/there@you');
    });

    test('decodeMessage emits chatmsg with mapped colour', () {
      final danmaku = DouyuDanmaku();
      final seen = <LiveMessage>[];
      danmaku.onMessage = seen.add;
      final frame = DouyuDanmaku.serializeDouyu(
        'type@=chatmsg/nn@=Alice/txt@=hello/col@=2/',
      );
      danmaku.decodeMessage(frame);
      expect(seen, hasLength(1));
      expect(seen.single.userName, 'Alice');
      expect(seen.single.message, 'hello');
      expect(seen.single.color, 0xFF1E87F0);
    });

    test('decodeMessage renders super chat as text', () {
      final danmaku = DouyuDanmaku();
      final seen = <LiveMessage>[];
      danmaku.onMessage = seen.add;
      // Nested STT values escape '/' as @S and '@=' as @A=.
      final frame = DouyuDanmaku.serializeDouyu(
        'type@=comm_chatmsg/chatmsg@=nn@A=Carol@Stxt@A=nice@Sshow@Scprice@A=50000/',
      );
      danmaku.decodeMessage(frame);
      expect(seen, hasLength(1));
      expect(seen.single.userName, 'Carol');
      expect(seen.single.message, contains('¥500'));
      // NOTE: the recursive STT parser (as in Pure Live) splits the
      // unescaped nested value on '/', so an @S inside nested text
      // truncates at the slash — 'nice' survives, 'show' does not.
      expect(seen.single.message, contains('nice'));
    });

    test('colour table', () {
      expect(DouyuDanmaku.douyuColorArgb(1), 0xFFFF0000);
      expect(DouyuDanmaku.douyuColorArgb(99), 0xFFFFFFFF);
    });
  });

  group('Bilibili binary protocol', () {
    const danmuJson =
        '{"cmd":"DANMU_MSG","info":[[0,0,16777215,0,1700000000,"abc123"],"hello world",[123,"Alice"],[],[],[],0,0]}';

    List<int> op5Frame(String json, {int protover = 0}) {
      final body = utf8.encode(json);
      final frame = Uint8List(body.length + 16);
      final view = ByteData.view(frame.buffer);
      view.setUint32(0, frame.length, Endian.big);
      view.setUint16(4, 16, Endian.big);
      view.setUint16(6, protover, Endian.big);
      view.setUint32(8, 5, Endian.big);
      view.setUint32(12, 1, Endian.big);
      frame.setRange(16, frame.length, body);
      return frame;
    }

    test('plain op-5 frame decodes to chat', () {
      final danmaku = BiliBiliDanmaku();
      final seen = <LiveMessage>[];
      danmaku.onMessage = seen.add;
      danmaku.decodeMessage(op5Frame(danmuJson));
      expect(seen, hasLength(1));
      expect(seen.single.userName, 'Alice');
      expect(seen.single.message, 'hello world');
      expect(seen.single.color, 0xFFFFFFFF);
    });

    test('two frames in one WebSocket message both decode', () {
      final danmaku = BiliBiliDanmaku();
      final seen = <LiveMessage>[];
      danmaku.onMessage = seen.add;
      final combined = <int>[
        ...op5Frame(danmuJson),
        ...op5Frame(danmuJson.replaceAll('Alice', 'Bob')),
      ];
      danmaku.decodeMessage(combined);
      expect(seen.map((m) => m.userName), ['Alice', 'Bob']);
    });

    test('zlib (protover 2) compressed frame decodes', () {
      final danmaku = BiliBiliDanmaku();
      final seen = <LiveMessage>[];
      danmaku.onMessage = seen.add;
      final inner = op5Frame(danmuJson);
      final compressed = zlib.encode(inner);
      danmaku.decodeMessage(_wrapCompressed(compressed, 2));
      expect(seen, hasLength(1));
      expect(seen.single.message, 'hello world');
    });

    test('brotli (protover 3) compressed frame decodes', () {
      final danmaku = BiliBiliDanmaku();
      final seen = <LiveMessage>[];
      danmaku.onMessage = seen.add;
      // The `brotli` package is decode-only, so the compressed payload
      // below is canned: the op-5 frame for `danmuJson` above,
      // brotli-compressed with Python's brotli module (119 bytes).
      const compressed = <int>[
        27, 121, 0, 0, 156, 5, 118, 172, 25, 90, 141, 79, 6, 135, 245, 218,
        92, 196, 56, 96, 25, 198, 61, 36, 4, 91, 31, 132, 107, 75, 253, 242,
        194, 246, 207, 187, 252, 32, 152, 222, 34, 166, 33, 162, 211, 96, 48,
        89, 116, 186, 116, 114, 160, 7, 244, 203, 249, 219, 33, 209, 0, 180,
        45, 8, 243, 28, 70, 14, 143, 83, 105, 223, 58, 6, 163, 126, 57, 249,
        63, 196, 220, 215, 177, 159, 99, 91, 192, 189, 39, 69, 168, 168, 216,
        228, 238, 197, 26, 227, 138, 81, 184, 238, 180, 82, 25, 79, 146, 243,
        133, 40, 54, 161, 247, 229, 203, 34, 82, 249, 24,
      ];
      danmaku.decodeMessage(_wrapCompressed(compressed, 3));
      expect(seen, hasLength(1));
      expect(seen.single.message, 'hello world');
    });

    test('op-8 auth ack marks connected and fires onReady', () {
      final danmaku = BiliBiliDanmaku();
      var ready = false;
      danmaku.onReady = () => ready = true;
      expect(danmaku.isConnected, isFalse);
      danmaku.decodeMessage(BiliBiliDanmaku.encodeData('{"code":0}', 8));
      expect(danmaku.isConnected, isTrue);
      expect(ready, isTrue);
      // Non-zero code must not connect.
      final danmaku2 = BiliBiliDanmaku();
      danmaku2.decodeMessage(BiliBiliDanmaku.encodeData('{"code":-101}', 8));
      expect(danmaku2.isConnected, isFalse);
    });

    test('encodeData round-trips through the frame header', () {
      final packet = BiliBiliDanmaku.encodeData('{"code":0}', 8);
      final view = ByteData.view(Uint8List.fromList(packet).buffer);
      expect(view.getUint32(0, Endian.big), packet.length);
      expect(view.getUint16(4, Endian.big), 16);
      expect(view.getUint32(8, Endian.big), 8);
      expect(utf8.decode(packet.sublist(16)), '{"code":0}');
    });

    test('gift becomes chat text; malformed input is skipped', () {
      final danmaku = BiliBiliDanmaku();
      final seen = <LiveMessage>[];
      danmaku.onMessage = seen.add;
      danmaku.parseMessage(
        '{"cmd":"SEND_GIFT","data":{"giftName":"小花花","num":3,"uname":"Dave"}}',
      );
      expect(seen.single.message, '送出 小花花 ×3');
      expect(() => danmaku.decodeMessage(const <int>[0, 1, 2]), returnsNormally);
      expect(() => danmaku.parseMessage('not json'), returnsNormally);
    });

    test('BiliBiliDanmakuArgs.fromMap builds host_list URLs', () {
      final args = BiliBiliDanmakuArgs.fromMap({
        'roomId': '123',
        'token': 'tok',
        'hostList': [
          {'host': 'broadcastlv.chat.bilibili.com', 'wss_port': 443},
        ],
      });
      expect(args.roomId, 123);
      expect(args.token, 'tok');
      expect(args.serverUrls, ['wss://broadcastlv.chat.bilibili.com:443/sub']);
    });
  });

  group('Kuaishou feed parsing', () {
    const canned = {
      'result': 1,
      'cursor': 'c1',
      'pullCycleSeconds': 2,
      'liveStreamFeeds': [
        {
          'type': 'comment',
          'content': 'hello',
          'author': {'userName': 'Eve', 'userId': 'u1'},
        },
        {'type': 'gift', 'content': 'gift should be skipped'},
        {'type': 'comment', 'content': '   ', 'author': {}},
        {
          'type': 'COMMENT',
          'content': 'second',
          'author': {'userName': ''},
        },
      ],
    };

    test('parses map payload, skips non-comments and blanks', () {
      final batch = KuaishouDanmaku.parseFeedPayload(canned);
      expect(batch.cursor, 'c1');
      expect(batch.pullDelay, const Duration(seconds: 2));
      expect(batch.messages.map((m) => m.message), ['hello', 'second']);
      expect(batch.messages.first.userName, 'Eve');
      expect(batch.messages.last.userName, '快手用户');
    });

    test('parses JSON string and double-encoded string payloads', () {
      final asString = KuaishouDanmaku.parseFeedPayload(jsonEncode(canned));
      expect(asString.messages, hasLength(2));
      final doubleEncoded = KuaishouDanmaku.parseFeedPayload(
        jsonEncode(jsonEncode(canned)),
      );
      expect(doubleEncoded.messages, hasLength(2));
      final nested = KuaishouDanmaku.parseFeedPayload({'data': canned});
      expect(nested.messages, hasLength(2));
    });

    test('rejects non-1 result and invalid shapes', () {
      expect(
        () => KuaishouDanmaku.parseFeedPayload({'result': 0}),
        throwsStateError,
      );
      expect(
        () => KuaishouDanmaku.parseFeedPayload('not json'),
        throwsFormatException,
      );
      expect(
        () => KuaishouDanmaku.parseFeedPayload(<int>[1, 2]),
        throwsFormatException,
      );
    });

    test('transport with canned fetcher emits messages and polls', () async {
      var calls = 0;
      final fast = <String, dynamic>{
        ...canned,
        'pullCycleSeconds': 1,
      };
      final danmaku = KuaishouDanmaku(
        fetcher: (liveStreamId, cursor, cookie, cancelToken) async {
          calls++;
          expect(liveStreamId, 'ls123');
          return fast;
        },
        minimumPollDelay: const Duration(milliseconds: 10),
      );
      final seen = <LiveMessage>[];
      danmaku.onMessage = seen.add;
      await danmaku.start({'liveStreamId': 'ls123'});
      expect(danmaku.isConnected, isTrue);
      expect(seen, hasLength(2));
      await Future<void>.delayed(const Duration(milliseconds: 1300));
      expect(calls, greaterThan(1)); // timer scheduled the next poll
      await danmaku.stop();
      expect(danmaku.isConnected, isFalse);
      final callsAfterStop = calls;
      await Future<void>.delayed(const Duration(milliseconds: 50));
      expect(calls, callsAfterStop); // no polls after stop
    });

    test('start without an id reports close instead of throwing', () async {
      final danmaku = KuaishouDanmaku(
        fetcher: (_, _, _, _) async => canned,
      );
      var closed = false;
      danmaku.onClose = () => closed = true;
      await danmaku.start(<String, dynamic>{});
      expect(closed, isTrue);
    });
  });

  group('TARS codec + Huya framing', () {
    test('output/input round-trip for int, string, bytes, list', () {
      final out = TarsOutputStream();
      out.write(42, 0);
      out.write('hello', 1);
      out.write(Uint8List.fromList(const <int>[1, 2, 3]), 2);
      out.write(<String>['a', 'b'], 3);
      final bytes = out.toUint8List();
      final input = TarsInputStream(bytes);
      expect(input.read(0, 0, false), 42);
      expect(input.read('', 1, false), 'hello');
      expect(input.readBytes(2, false), Uint8List.fromList(const <int>[1, 2, 3]));
      expect(
        input.readList<String>(<String>[''], 3, false),
        ['a', 'b'],
      );
    });

    test('Huya join data decodes to live:/chat: groups', () {
      final join = HuyaDanmaku.getJoinData(660000);
      final input = TarsInputStream(Uint8List.fromList(join));
      expect(input.read(0, 0, false), 16); // RegisterGroupReq
      final groupBytes = input.readBytes(1, false);
      final group = TarsInputStream(groupBytes);
      expect(
        group.readList<String>(<String>[''], 0, false),
        ['live:660000', 'chat:660000'],
      );
      expect(group.read('', 1, false), '');
    });

    test('Huya heartbeat data decodes to command 20', () {
      final hb = HuyaDanmaku.heartbeatData;
      final input = TarsInputStream(Uint8List.fromList(hb));
      expect(input.read(0, 0, false), 20);
      expect(input.readBytes(1, false), isEmpty);
    });

    test('Huya type-7 push with uri 1400 decodes to chat', () async {
      // Hand-build HYMessage bytes (writeTo is a no-op in the reference,
      // so the test builds the struct with TarsOutputStream directly):
      // userInfo{uid:7, nickName:"Frank"} tag 0, content tag 3,
      // bulletFormat{fontColor:0xFF0000} tag 6.
      final sender = TarsOutputStream();
      sender.write(7, 0);
      sender.write('Frank', 2);
      final bullet = TarsOutputStream();
      bullet.write(0xFF0000, 0);
      final messageOut = TarsOutputStream();
      messageOut.write(_TestSenderBytes(sender.toUint8List()), 0);
      messageOut.write('hi huya', 3);
      messageOut.write(_TestBulletBytes(bullet.toUint8List()), 6);
      final push = TarsOutputStream();
      push.write(0, 0);
      push.write(1400, 1);
      push.write(messageOut.toUint8List(), 2);
      push.write(0, 3);
      final outer = TarsOutputStream();
      outer.write(7, 0);
      outer.write(push.toUint8List(), 1);
      final danmaku = HuyaDanmaku();
      final seen = <LiveMessage>[];
      danmaku.onMessage = seen.add;
      await danmaku.decodeMessage(outer.toUint8List());
      expect(seen, hasLength(1));
      expect(seen.single.userName, 'Frank');
      expect(seen.single.message, 'hi huya');
      expect(seen.single.color, 0xFFFF0000);
    });
  });

  group('Douyin signing + protobuf', () {
    test('getSignature returns a 16-char X-Bogus string', () {
      final sig = DouyinDanmaku.getSignature('123456', '7300000000000000001');
      expect(sig, hasLength(16));
      // Randomised per call (random1/random2 in the payload).
      final sig2 = DouyinDanmaku.getSignature('123456', '7300000000000000001');
      expect(sig2, hasLength(16));
    });

    test('buildServerUrls signs both hosts', () {
      final base = Uri.parse(
        'wss://webcast100-ws-web-lq.douyin.com/webcast/im/push/v2/?room_id=1',
      );
      final urls = DouyinDanmaku.buildServerUrls(base, signature: 'ab+cd/ef==');
      expect(urls, hasLength(2));
      for (final url in urls) {
        final uri = Uri.parse(url);
        expect(uri.queryParameters['signature'], 'ab+cd/ef==');
        expect(uri.queryParameters['room_id'], '1');
      }
      expect(urls[0], contains('webcast100-ws-web-lq.douyin.com'));
      expect(urls[1], contains('webcast100-ws-web-hl.douyin.com'));
    });

    test('handshake headers carry cookie + origin/referer', () {
      final headers = DouyinDanmaku.buildHandshakeHeaders(
        const DouyinDanmakuArgs(
          webRid: 'abc',
          roomId: '123',
          userId: 'u1',
          cookie: 'ttwid=xyz; msToken=abc',
        ),
      );
      expect(headers['Cookie'], 'ttwid=xyz; msToken=abc');
      expect(headers['Origin'], 'https://live.douyin.com');
      expect(headers['Referer'], 'https://live.douyin.com/abc');
    });

    test('PushFrame/ChatMessage round-trip through decodeMessage', () {
      final danmaku = DouyinDanmaku();
      // common.roomId '0' passes the room filter (decodeMessage drops
      // chat whose common roomId differs from the started room id).
      final chat = ChatMessage()
        ..common = (Common()..roomId = Int64(0))
        ..user = (User()
          ..id = Int64(99)
          ..nickName = 'Grace')
        ..content = 'hello douyin';
      final response = Response()
        ..messagesList.add(
          Message()
            ..method = 'WebcastChatMessage'
            ..msgId = Int64(1)
            ..payload = chat.writeToBuffer(),
        );
      final gzipped = gzip.encode(response.writeToBuffer());
      final frame = PushFrame()
        ..payloadType = 'msg'
        ..payloadEncoding = 'gzip'
        ..payload = gzipped;
      final seen = <LiveMessage>[];
      danmaku.onMessage = seen.add;
      danmaku.decodeMessage(frame.writeToBuffer());
      expect(seen, hasLength(1));
      expect(seen.single.userName, 'Grace');
      expect(seen.single.message, 'hello douyin');
    });
  });
}

/// Wrap compressed bytes in an op-5 frame with the given protover.
List<int> _wrapCompressed(List<int> compressed, int protover) {
  final frame = Uint8List(compressed.length + 16);
  final view = ByteData.view(frame.buffer);
  view.setUint32(0, frame.length, Endian.big);
  view.setUint16(4, 16, Endian.big);
  view.setUint16(6, protover, Endian.big);
  view.setUint32(8, 5, Endian.big);
  view.setUint32(12, 1, Endian.big);
  frame.setRange(16, frame.length, compressed);
  return frame;
}

/// Test helper: a TarsStruct whose writeTo emits pre-built bytes, so
/// readTarsStruct can decode a hand-built struct in tests.
class _TestSenderBytes extends TarsStruct {
  _TestSenderBytes(this.bytes);
  final Uint8List bytes;
  @override
  void readFrom(TarsInputStream inputStream) {}
  @override
  void writeTo(TarsOutputStream outputStream) {
    outputStream.bw.writeBytes(bytes);
  }

  @override
  Object deepCopy() => _TestSenderBytes(bytes);
  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class _TestBulletBytes extends TarsStruct {
  _TestBulletBytes(this.bytes);
  final Uint8List bytes;
  @override
  void readFrom(TarsInputStream inputStream) {}
  @override
  void writeTo(TarsOutputStream outputStream) {
    outputStream.bw.writeBytes(bytes);
  }

  @override
  Object deepCopy() => _TestBulletBytes(bytes);
  @override
  void displayAsString(StringBuffer sb, int level) {}
}
