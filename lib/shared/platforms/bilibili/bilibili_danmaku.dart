// Bilibili danmaku — binary packet protocol over WebSocket.
//
// Port of Pure Live 3.x `lib/shared/platforms/bilibili/bilibili_danmaku.dart`
// (769 lines):
//   WS wss://broadcastlv.chat.bilibili.com/sub (or a host from
//   getDanmuInfo's host_list)
//   16-byte big-endian frame header:
//     [packetLen:u32][headerLen:u16][protover:u16][operation:u32][seq:u32]
//   auth packet (op 7): {uid, roomid, protover: 3, buvid, key: token, …}
//   heartbeat (op 2, empty body) every 30 s
//   op 3: popularity heartbeat; op 5: notification (plain JSON, or a
//   zlib (protover 2) / brotli (protover 3) compressed packet stream);
//   op 8: auth ack — only after code == 0 is the transport connected.
//
// Credentials come from `danmakuData` (`token`, `serverUrls`/`hostList`,
// `buvid`, `uid`, `cookie`) when the room detail supplied them; otherwise
// they are discovered here via
//   GET https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo?id=<roomId>&type=0
// (unsigned — the public endpoint answers anonymous requests; Pure Live
// additionally WBI-signs, which the adapter phase can add later).
// Credentials are re-discovered on reconnect (max 3 refreshes).
//
// Our [LiveMessage] model carries chat text only (no gift / super-chat /
// audience payloads), so gifts, guards and super chats are rendered as
// plain chat text and popularity counts are skipped.

import 'dart:async';
import 'dart:io';
import 'dart:convert';
import 'dart:math';
import 'dart:typed_data';

import 'package:brotli/brotli.dart';
import 'package:dio/dio.dart';

import '../../../core/models/live_models.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/web_socket_util.dart';
import '../live_site.dart';

class BiliBiliDanmakuArgs {
  const BiliBiliDanmakuArgs({
    required this.roomId,
    required this.token,
    this.serverUrls = const <String>[],
    this.buvid = '',
    this.uid = 0,
    this.cookie = '',
  });

  final int roomId;
  final String token;
  final List<String> serverUrls;
  final String buvid;
  final int uid;
  final String cookie;

  /// Build from a `danmakuData` map (room detail) — missing fields are
  /// empty and trigger credential discovery in [BiliBiliDanmaku.start].
  factory BiliBiliDanmakuArgs.fromMap(Map<String, dynamic> args) {
    final serverUrls = <String>[];
    final rawUrls = args['serverUrls'];
    if (rawUrls is List) {
      for (final u in rawUrls) {
        final s = u?.toString() ?? '';
        if (s.isNotEmpty) serverUrls.add(s);
      }
    }
    // host_list entries: {host, wss_port} -> wss://host:port/sub
    final hostList = args['hostList'];
    if (hostList is List) {
      for (final h in hostList) {
        if (h is! Map) continue;
        final host = h['host']?.toString() ?? '';
        final port = h['wss_port']?.toString() ?? '';
        if (host.isNotEmpty && port.isNotEmpty) {
          serverUrls.add('wss://$host:$port/sub');
        }
      }
    }
    return BiliBiliDanmakuArgs(
      roomId: int.tryParse(args['roomId']?.toString() ?? '') ?? 0,
      token: args['token']?.toString() ?? '',
      serverUrls: serverUrls,
      buvid: args['buvid']?.toString() ?? '',
      uid: int.tryParse(args['uid']?.toString() ?? '') ?? 0,
      cookie: args['cookie']?.toString() ?? '',
    );
  }
}

class BiliBiliDanmaku extends LiveDanmaku {
  BiliBiliDanmaku();

  static const int _packetHeaderLength = 16;
  static const int _maxTransportMessageBytes = 8 * 1024 * 1024;
  static const int _maxDecompressedMessageBytes = 16 * 1024 * 1024;
  static const int _maxPacketsPerMessage = 4096;
  static const int _maxCompressedNestingDepth = 2;
  static const int _heartbeatMs = 30 * 1000;

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  WebSocketUtils? _socket;
  BiliBiliDanmakuArgs _args =
      const BiliBiliDanmakuArgs(roomId: 0, token: '');
  bool _stopped = false;
  bool _refreshingCredentials = false;
  int _credentialRefreshCount = 0;
  Timer? _authTimer;
  int _generation = 0;

  @override
  Future<void> start(Map<String, dynamic> args) async {
    final generation = ++_generation;
    await _socket?.close();
    _socket = null;
    _args = BiliBiliDanmakuArgs.fromMap(args);
    _stopped = false;
    _credentialRefreshCount = 0;
    _connected = false;
    if (_args.roomId == 0) {
      onClose?.call();
      return;
    }
    if (_args.token.isEmpty) {
      for (var attempt = 0; attempt < 3 && !_stopped; attempt++) {
        try {
          final refreshed = await _discoverCredentials(_args.roomId);
          if (refreshed != null && refreshed.token.isNotEmpty) {
            _args = refreshed;
            break;
          }
        } catch (_) {
          // Best-effort: retry discovery, then give up quietly.
        }
        if (attempt < 2) {
          await Future<void>.delayed(
            Duration(milliseconds: 500 * (attempt + 1)),
          );
        }
      }
      if (_stopped || _args.token.isEmpty) {
        if (generation == _generation) {
          onClose?.call();
        }
        return;
      }
    }
    if (generation != _generation) return;
    await _connect(_args);
  }

  Future<void> _connect(BiliBiliDanmakuArgs args) async {
    if (_stopped) return;
    final generation = _generation;
    final endpoints = args.serverUrls.isEmpty
        ? const ['wss://broadcastlv.chat.bilibili.com/sub']
        : args.serverUrls;
    final socket = WebSocketUtils(
      url: endpoints.first,
      serverUrls: endpoints,
      headers: args.cookie.isEmpty
          ? null
          : <String, dynamic>{'cookie': args.cookie},
      heartBeatTime: _heartbeatMs,
      onMessage: (data) {
        if (generation == _generation) decodeMessage(_asBytes(data));
      },
      onReady: () {
        if (generation != _generation) return;
        _joinRoom(args);
        _authTimer?.cancel();
        _authTimer = Timer(const Duration(seconds: 8), () {
          if (!_stopped && !_connected) _socket?.reconnect();
        });
      },
      onHeartBeat: () {
        if (generation == _generation) heartbeat();
      },
      onReconnect: () {
        if (generation != _generation) return;
        _authTimer?.cancel();
        _connected = false;
        onReconnect?.call();
      },
      onClose: (_) {
        if (generation != _generation) return;
        _authTimer?.cancel();
        _connected = false;
        onClose?.call();
      },
    );
    _socket = socket;
    await socket.connect();
  }

  Future<void> _refreshCredentialsAndReconnect() async {
    if (_stopped ||
        _refreshingCredentials ||
        _credentialRefreshCount >= 3 ||
        _args.roomId == 0) {
      return;
    }
    _refreshingCredentials = true;
    _credentialRefreshCount++;
    try {
      final refreshed = await _discoverCredentials(_args.roomId);
      if (_stopped || refreshed == null || refreshed.token.isEmpty) return;
      _args = refreshed;
      await _socket?.close();
      if (_stopped) return;
      await _connect(refreshed);
    } catch (_) {
      // Best-effort: the socket's own reconnect keeps trying.
    } finally {
      _refreshingCredentials = false;
    }
  }

  /// Fetch token + host_list from getDanmuInfo. Returns null on failure.
  static Future<BiliBiliDanmakuArgs?> _discoverCredentials(int roomId) async {
    try {
      final dio = sharedDio();
      final response = await dio.get<Map<String, dynamic>>(
        'https://api.live.bilibili.com/xlive/web-room/v1/index/getDanmuInfo',
        queryParameters: <String, dynamic>{'id': roomId, 'type': 0},
        options: Options(
          headers: <String, String>{
            'Referer': 'https://live.bilibili.com/$roomId',
          },
        ),
      );
      final body = response.data;
      if (body == null || body['code'] != 0) return null;
      final data = body['data'];
      if (data is! Map) return null;
      final token = data['token']?.toString() ?? '';
      if (token.isEmpty) return null;
      return BiliBiliDanmakuArgs(
        roomId: roomId,
        token: token,
        serverUrls: _hostListUrls(data['host_list']),
      );
    } catch (_) {
      return null;
    }
  }

  static List<String> _hostListUrls(dynamic hostList) {
    final urls = <String>[];
    if (hostList is List) {
      for (final h in hostList) {
        if (h is! Map) continue;
        final host = h['host']?.toString() ?? '';
        final port = h['wss_port']?.toString() ?? '';
        if (host.isNotEmpty && port.isNotEmpty) {
          urls.add('wss://$host:$port/sub');
        }
      }
    }
    return urls;
  }

  void _joinRoom(BiliBiliDanmakuArgs args) {
    _sendPacket(encodeData(json.encode(buildJoinPayload(args)), 7));
  }

  /// Auth payload (op 7). `queueUuid` is injectable for tests.
  static Map<String, dynamic> buildJoinPayload(
    BiliBiliDanmakuArgs args, {
    String? queueUuid,
  }) {
    return {
      'uid': args.uid,
      'roomid': args.roomId,
      'protover': 3,
      'buvid': args.buvid,
      'support_ack': true,
      'queue_uuid': queueUuid ?? _newQueueUuid(),
      'scene': 'room',
      'platform': 'web',
      'type': 2,
      'key': args.token,
    };
  }

  static String _newQueueUuid() {
    final random = Random.secure();
    return List<String>.generate(
      8,
      (_) => random.nextInt(16).toRadixString(16),
    ).join();
  }

  void _sendPacket(List<int> packet) {
    _socket?.sendMessage(packet);
  }

  @override
  Future<void> heartbeat() async {
    _sendPacket(encodeData('', 2));
  }

  @override
  Future<void> stop() async {
    _generation++;
    _stopped = true;
    _authTimer?.cancel();
    _authTimer = null;
    _connected = false;
    onMessage = null;
    onReconnect = null;
    onClose = null;
    onReady = null;
    await _socket?.close();
    _socket = null;
  }

  /// Encode one frame: 16-byte big-endian header + UTF-8 body.
  static List<int> encodeData(String msg, int action) {
    final data = utf8.encode(msg);
    final buffer = Uint8List(data.length + 16);
    final view = ByteData.view(buffer.buffer);
    view.setUint32(0, buffer.length, Endian.big);
    view.setUint16(4, 16, Endian.big);
    view.setUint16(6, 0, Endian.big);
    view.setUint32(8, action, Endian.big);
    view.setUint32(12, 1, Endian.big);
    buffer.setRange(16, buffer.length, data);
    return buffer;
  }

  /// Decode one inbound WebSocket message (possibly several frames,
  /// possibly compressed). Malformed input is skipped, never thrown.
  void decodeMessage(List<int> data) {
    try {
      if (data.length > _maxTransportMessageBytes) return;
      _decodePacketStream(data, depth: 0);
    } catch (_) {
      // Best-effort: a bad frame must not kill the room.
    }
  }

  void _decodePacketStream(List<int> data, {required int depth}) {
    if (depth > _maxCompressedNestingDepth) {
      throw const FormatException('Bilibili danmaku packet nesting too deep');
    }
    var offset = 0;
    var packetCount = 0;
    while (offset + _packetHeaderLength <= data.length) {
      packetCount++;
      if (packetCount > _maxPacketsPerMessage) {
        throw const FormatException('Bilibili danmaku message has too many packets');
      }
      final view = ByteData.sublistView(Uint8List.fromList(data), offset);
      final packetLength = view.getUint32(0, Endian.big);
      final headerLength = view.getUint16(4, Endian.big);
      final protocolVersion = view.getUint16(6, Endian.big);
      final operation = view.getUint32(8, Endian.big);
      if (headerLength < _packetHeaderLength ||
          packetLength < headerLength ||
          packetLength > _maxTransportMessageBytes ||
          offset + packetLength > data.length) {
        throw FormatException(
          'Invalid Bilibili danmaku frame: offset=$offset, '
          'packet=$packetLength, header=$headerLength, total=${data.length}',
        );
      }
      final body = data.sublist(offset + headerLength, offset + packetLength);
      _decodePacket(protocolVersion, operation, body, depth: depth);
      offset += packetLength;
    }
    if (offset != data.length) {
      throw FormatException(
        'Incomplete Bilibili danmaku frame: parsed=$offset, total=${data.length}',
      );
    }
  }

  void _decodePacket(
    int protocolVersion,
    int operation,
    List<int> body, {
    required int depth,
  }) {
    if (operation == 3) {
      // Popularity heartbeat — no field for it in LiveMessage; skip.
      return;
    }
    if (operation == 5) {
      if (protocolVersion == 2 || protocolVersion == 3) {
        final decoded = _decodeCompressedBody(body, protocolVersion);
        _decodePacketStream(decoded, depth: depth + 1);
      } else {
        final text = utf8.decode(body, allowMalformed: true).trim();
        if (text.isNotEmpty) parseMessage(text);
      }
      return;
    }
    if (operation == 8) {
      // Auth ack — the transport is usable only after code == 0.
      final text = utf8.decode(body, allowMalformed: true).trim();
      final dynamic decoded =
          text.isEmpty ? const <String, dynamic>{'code': 0} : json.decode(text);
      final auth = decoded is Map ? decoded : const <String, dynamic>{};
      final code = int.tryParse(auth['code']?.toString() ?? '') ?? -1;
      if (code == 0 && !_connected) {
        _authTimer?.cancel();
        _connected = true;
        unawaited(heartbeat());
        onReady?.call();
      } else if (code != 0) {
        _authTimer?.cancel();
        _connected = false;
        unawaited(_refreshCredentialsAndReconnect());
      }
    }
  }

  static List<int> _decodeCompressedBody(List<int> body, int protocolVersion) {
    if (protocolVersion == 2) {
      return zlib.decode(body);
    }
    final sink = _BoundedBytesSink(_maxDecompressedMessageBytes);
    final conversion = brotli.decoder.startChunkedConversion(sink);
    conversion.add(body);
    conversion.close();
    return sink.takeBytes();
  }

  /// Parse one notification JSON object (`cmd` dispatch). Only chat-like
  /// commands produce a [LiveMessage]; gifts / super chat become chat text.
  void parseMessage(String jsonMessage) {
    try {
      final obj = json.decode(jsonMessage);
      if (obj is! Map) return;
      final cmd = obj['cmd']?.toString() ?? '';
      if (cmd.contains('DANMU_MSG')) {
        final info = obj['info'];
        if (info is List && info.length >= 3) {
          final message = info[1]?.toString() ?? '';
          if (message.isEmpty) return;
          final meta = info[0] is List ? info[0] as List : const <dynamic>[];
          final color = meta.isNotEmpty
              ? (int.tryParse(meta[3]?.toString() ?? '') ?? 0)
              : 0;
          final user = info[2] is List ? info[2] as List : const <dynamic>[];
          final userName = user.length > 1 ? user[1]?.toString() ?? '' : '';
          onMessage?.call(
            LiveMessage(
              userName: userName,
              message: message,
              color: color == 0 ? 0xFFFFFFFF : (0xFF000000 | (color & 0xFFFFFF)),
            ),
          );
        }
      } else if (cmd == 'SEND_GIFT' || cmd == 'COMBO_SEND') {
        final data = obj['data'];
        if (data is Map) {
          final name = (cmd == 'COMBO_SEND' ? data['gift_name'] : data['giftName'])
                  ?.toString()
                  .trim() ??
              '';
          if (name.isEmpty) return;
          final count = int.tryParse(
                (cmd == 'COMBO_SEND' ? data['total_num'] : data['num'])
                        ?.toString() ??
                    '',
              ) ??
              1;
          onMessage?.call(
            LiveMessage(
              userName: data['uname']?.toString() ?? '',
              message: '送出 $name ×$count',
              color: 0xFFFFFFFF,
            ),
          );
        }
      } else if (cmd == 'SUPER_CHAT_MESSAGE') {
        final data = obj['data'];
        if (data is Map) {
          final userInfo = data['user_info'];
          final userName = userInfo is Map
              ? userInfo['uname']?.toString() ?? ''
              : '';
          final text = data['message']?.toString() ?? '';
          if (text.isEmpty) return;
          onMessage?.call(
            LiveMessage(
              userName: userName,
              message: '💰 ${data['price'] ?? ''} $text',
              color: 0xFFFFFFFF,
            ),
          );
        }
      } else if (cmd == 'WARNING' || cmd == 'CUT_OFF') {
        final reason = obj['msg']?.toString().trim() ?? '';
        final lead = cmd == 'WARNING' ? '直播间收到警告' : '直播被切断';
        onMessage?.call(
          LiveMessage(
            userName: '',
            message: reason.isEmpty ? lead : '$lead：$reason',
            color: 0xFFFFFFFF,
          ),
        );
      }
    } catch (_) {
      // Best-effort: a bad notification must not kill the room.
    }
  }

  static List<int> _asBytes(dynamic data) {
    if (data is List<int>) return data;
    if (data is String) return utf8.encode(data);
    return const <int>[];
  }
}

/// Accumulates decompressed bytes while enforcing a hard output cap, so a
/// highly-compressible frame is rejected before it materializes an
/// unbounded output list.
class _BoundedBytesSink implements Sink<List<int>> {
  _BoundedBytesSink(this.limit);

  final int limit;
  final BytesBuilder _builder = BytesBuilder(copy: false);
  int _length = 0;
  bool _closed = false;

  @override
  void add(List<int> data) {
    if (_closed) throw StateError('Bilibili decompression sink is closed');
    if (data.length > limit - _length) {
      throw FormatException('Bilibili decompressed message exceeds $limit bytes');
    }
    _length += data.length;
    _builder.add(data);
  }

  @override
  void close() {
    _closed = true;
  }

  Uint8List takeBytes() => _builder.takeBytes();
}
