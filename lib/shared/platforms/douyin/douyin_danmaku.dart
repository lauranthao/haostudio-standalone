// Douyin danmaku — protobuf over WebSocket.
//
// Port of Pure Live 3.x `lib/shared/platforms/douyin/douyin_danmaku.dart`
// (333 lines) + `proto/douyin.proto` (generated Dart vendored under
// `proto/`) + `douyin_xbogus.dart` (WS URL signature):
//   WS wss://webcast100-ws-web-lq.douyin.com/webcast/im/push/v2/
//   (alt host webcast100-ws-web-hl.douyin.com)
//   PushFrame / Response / ChatMessage protobuf; payload usually gzip.
//   WS URL signed by getSignature(roomId, userId) — md5 of the param
//   string, then X-Bogus.
//   Handshake headers: Cookie (ttwid / msToken / …), Origin + Referer
//   https://live.douyin.com.
//
// The WS handshake REQUIRES the `ttwid` cookie. A browser/WKWebView JS
// WebSocket cannot send Cookie headers — only a native WS can. In
// Flutter this is directly portable via `IOWebSocketChannel` with
// headers (see `core/network/web_socket_util.dart`).
//
// Args for [start] (from the room detail's `danmakuData`):
//   - `roomId`: long numeric room id (required).
//   - `webRid`: short room id (defaults to `roomId`).
//   - `userId`: anonymous viewer id; generated (7.3e18–8e18) if absent.
//   - `cookie`: session cookie; when absent a HEAD request to
//     https://live.douyin.com/<webRid> warms it up from `set-cookie`
//     (ttwid / __ac_nonce / msToken).
//
// Best-effort: handshake/signing failure reports [LiveDanmaku.onClose];
// the video keeps playing.

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart' hide Response;
import 'package:fixnum/fixnum.dart';

import '../../../core/models/live_models.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/web_socket_util.dart';
import '../live_site.dart';
import 'douyin_request_params.dart';
import 'douyin_xbogus.dart';
import 'proto/douyin.pb.dart';

class DouyinDanmakuArgs {
  const DouyinDanmakuArgs({
    required this.webRid,
    required this.roomId,
    required this.userId,
    this.cookie = '',
  });

  final String webRid;
  final String roomId;
  final String userId;
  final String cookie;

  factory DouyinDanmakuArgs.fromMap(Map<String, dynamic> args) {
    final roomId = args['roomId']?.toString() ?? '';
    return DouyinDanmakuArgs(
      webRid: args['webRid']?.toString() ?? roomId,
      roomId: roomId,
      userId: args['userId']?.toString() ?? '',
      cookie: args['cookie']?.toString() ?? '',
    );
  }
}

class DouyinDanmaku extends LiveDanmaku {
  DouyinDanmaku();

  static const String _webSocketPath = '/webcast/im/push/v2/';
  static const List<String> _webSocketHosts = <String>[
    'webcast100-ws-web-lq.douyin.com',
    'webcast100-ws-web-hl.douyin.com',
  ];
  static const int _heartbeatMs = 10 * 1000;

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  WebSocketUtils? _socket;
  DouyinDanmakuArgs _args =
      const DouyinDanmakuArgs(webRid: '', roomId: '', userId: '');
  int _generation = 0;

  @override
  Future<void> start(Map<String, dynamic> args) async {
    final generation = ++_generation;
    await _socket?.close();
    _socket = null;
    _args = DouyinDanmakuArgs.fromMap(args);
    _connected = false;
    if (_args.roomId.isEmpty) {
      onClose?.call();
      return;
    }
    // Anonymous viewer id (Pure Live douyin_site L975-990: 7.3e18–8e18).
    // Built digit-by-digit: Random.nextInt caps at 2^32.
    if (_args.userId.isEmpty) {
      final random = Random.secure();
      final digits = StringBuffer('7')..write(3 + random.nextInt(7));
      for (var i = 0; i < 17; i++) {
        digits.write(random.nextInt(10));
      }
      _args = DouyinDanmakuArgs(
        webRid: _args.webRid,
        roomId: _args.roomId,
        userId: digits.toString(),
        cookie: _args.cookie,
      );
    }
    // Warm up the ttwid cookie when the room detail did not supply one.
    var cookie = _args.cookie;
    if (cookie.trim().isEmpty) {
      cookie = await _warmUpCookie(_args.webRid);
      if (cookie.isNotEmpty) {
        _args = DouyinDanmakuArgs(
          webRid: _args.webRid,
          roomId: _args.roomId,
          userId: _args.userId,
          cookie: cookie,
        );
      }
    }
    if (generation != _generation) return;

    final ts = DateTime.now().millisecondsSinceEpoch;
    final baseUri = Uri.parse('wss://${_webSocketHosts.first}$_webSocketPath')
        .replace(
          queryParameters: {
            'app_name': 'douyin_web',
            'version_code': DouyinRequestParams.versionCodeValue,
            'webcast_sdk_version': DouyinRequestParams.sdkVersion,
            'update_version_code': DouyinRequestParams.sdkVersion,
            'compress': 'gzip',
            'cursor': 'h-1_t-${ts}_r-1_d-1_u-1',
            'host': 'https://live.douyin.com',
            'aid': '6383',
            'live_id': '1',
            'did_rule': '3',
            'debug': 'false',
            'maxCacheMessageNumber': '20',
            'endpoint': 'live_pc',
            'support_wrds': '1',
            'im_path': '/webcast/im/fetch/',
            'user_unique_id': _args.userId,
            'device_platform': 'web',
            'cookie_enabled': 'true',
            'screen_width': '1920',
            'screen_height': '1080',
            'browser_language': 'zh-CN',
            'browser_platform': 'Win32',
            'browser_name': 'Mozilla',
            'browser_version': DouyinRequestParams.browserVersion,
            'browser_online': 'true',
            'tz_name': 'Asia/Shanghai',
            'identity': 'audience',
            'room_id': _args.roomId,
            'need_persist_msg_count': '15',
            'heartbeatDuration': '0',
          },
        );
    final sign = getSignature(_args.roomId, _args.userId);
    if (generation != _generation) return;
    final serverUrls = buildServerUrls(baseUri, signature: sign);
    final socket = WebSocketUtils(
      url: serverUrls.first,
      serverUrls: serverUrls,
      headers: buildHandshakeHeaders(_args),
      heartBeatTime: _heartbeatMs,
      inactivityTimeout: const Duration(seconds: 45),
      onMessage: (data) {
        if (generation != _generation) return;
        try {
          decodeMessage(_asBytes(data));
        } catch (_) {
          // Best-effort: a bad frame must not kill the room.
        }
      },
      onReady: () {
        if (generation != _generation) return;
        _connected = true;
        onReady?.call();
        _joinRoom();
      },
      onHeartBeat: () {
        if (generation == _generation) heartbeat();
      },
      onReconnect: () {
        if (generation != _generation) return;
        _connected = false;
        onReconnect?.call();
      },
      onClose: (_) {
        if (generation != _generation) return;
        _connected = false;
        onClose?.call();
      },
    );
    _socket = socket;
    await socket.connect();
  }

  /// Equivalent signed URLs for every current web IM edge. The signature
  /// alphabet contains `+` and `/`, so it must go through query encoding
  /// (appending it raw turns `+` into a space on some stacks).
  static List<String> buildServerUrls(Uri baseUri, {required String signature}) {
    final signed = baseUri.replace(
      path: _webSocketPath,
      queryParameters: <String, String>{
        ...baseUri.queryParameters,
        'signature': signature,
      },
    );
    return List<String>.unmodifiable(
      _webSocketHosts.map((host) => signed.replace(scheme: 'wss', host: host).toString()),
    );
  }

  static Map<String, dynamic> buildHandshakeHeaders(DouyinDanmakuArgs args) {
    return <String, dynamic>{
      'User-Agent': DouyinRequestParams.kDefaultUserAgent,
      if (args.cookie.trim().isNotEmpty) 'Cookie': args.cookie,
      'Origin': 'https://live.douyin.com',
      'Referer': 'https://live.douyin.com/${args.webRid}',
    };
  }

  @override
  Future<void> heartbeat() async {
    final frame = PushFrame()..payloadType = 'hb';
    _socket?.sendMessage(frame.writeToBuffer());
  }

  void _joinRoom() {
    final frame = PushFrame()..payloadType = 'hb';
    _socket?.sendMessage(frame.writeToBuffer());
  }

  void decodeMessage(List<int> data) {
    final wssPackage = PushFrame.fromBuffer(data);
    final logId = wssPackage.logId;
    final encodedPayload = wssPackage.payload;
    final isGzip = wssPackage.payloadEncoding.toLowerCase() == 'gzip' ||
        (encodedPayload.length >= 2 &&
            encodedPayload[0] == 0x1f &&
            encodedPayload[1] == 0x8b);
    final decompressed = isGzip ? gzip.decode(encodedPayload) : encodedPayload;
    final payloadPackage = Response.fromBuffer(decompressed);
    if (payloadPackage.needAck) {
      _sendAck(logId, payloadPackage.internalExt);
    }
    for (final msg in payloadPackage.messagesList) {
      if (msg.method == 'WebcastChatMessage') {
        _unpackChatMessage(msg.payload, envelopeMessageId: msg.msgId.toString());
      }
      // WebcastRoomUserSeqMessage (online count) has no field in our
      // LiveMessage model; skip it.
    }
  }

  void _unpackChatMessage(List<int> payload, {String envelopeMessageId = ''}) {
    final chatMessage = ChatMessage.fromBuffer(payload);
    final commonRoomId =
        chatMessage.hasCommon() ? chatMessage.common.roomId.toString() : '';
    if (commonRoomId.isNotEmpty &&
        commonRoomId != '0' &&
        commonRoomId != _args.roomId) {
      return;
    }
    final text = chatMessage.content;
    if (text.isEmpty) return;
    onMessage?.call(
      LiveMessage(
        userName: chatMessage.user.nickName,
        message: text,
        color: 0xFFFFFFFF,
      ),
    );
  }

  void _sendAck(Int64 logId, String internalExt) {
    final frame = PushFrame()
      ..payloadType = 'ack'
      ..logId = logId
      ..payload = utf8.encode(internalExt);
    _socket?.sendMessage(frame.writeToBuffer());
  }

  @override
  Future<void> stop() async {
    _generation++;
    _connected = false;
    onMessage = null;
    onReconnect = null;
    onClose = null;
    onReady = null;
    await _socket?.close();
    _socket = null;
  }

  /// X-Bogus signature for the WS URL (Pure Live L304-311).
  static String getSignature(String roomId, String uniqueId) {
    try {
      final params = <String, dynamic>{
        'live_id': '1',
        'aid': '6383',
        'version_code': DouyinRequestParams.versionCodeValue,
        'webcast_sdk_version': DouyinRequestParams.sdkVersion,
        'room_id': roomId,
        'sub_room_id': '',
        'sub_channel_id': '',
        'did_rule': '3',
        'user_unique_id': uniqueId,
        'device_platform': 'web',
        'device_type': '',
        'ac': '',
        'identity': 'audience',
      };
      final sigParam =
          params.entries.map((e) => '${e.key}=${e.value}').join(',');
      final md5SigParam = md5.convert(utf8.encode(sigParam)).toString();
      return generateXBogus(md5SigParam, 1);
    } catch (_) {
      return '';
    }
  }

  /// HEAD `https://live.douyin.com/<webRid>` and collect ttwid /
  /// __ac_nonce / msToken from `set-cookie`. Best-effort: '' on failure
  /// (the handshake may still succeed without a cookie for some rooms).
  static Future<String> _warmUpCookie(String webRid) async {
    try {
      final dio = sharedDio();
      final response = await dio.head<dynamic>(
        'https://live.douyin.com/$webRid',
        options: Options(
          headers: <String, String>{
            'User-Agent': DouyinRequestParams.kDefaultUserAgent,
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          },
        ),
      );
      final parts = <String>[];
      final setCookies = response.headers.map['set-cookie'];
      if (setCookies != null) {
        for (final line in setCookies) {
          final kv = line.split(';').first.trim();
          if (kv.startsWith('ttwid=') ||
              kv.startsWith('__ac_nonce=') ||
              kv.startsWith('msToken=')) {
            parts.add(kv);
          }
        }
      }
      return parts.join('; ');
    } catch (_) {
      return '';
    }
  }

  static List<int> _asBytes(dynamic data) {
    if (data is List<int>) return data;
    if (data is String) return utf8.encode(data);
    return const <int>[];
  }
}
