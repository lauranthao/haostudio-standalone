// Douyu danmaku — `type@=` text protocol over WebSocket.
//
// Port of Pure Live 3.x `lib/shared/platforms/douyu/douyu_danmaku.dart`
// (292 lines):
//   WS wss://danmuproxy.douyu.com:8506
//   login:  `type@=loginreq/roomid@=<roomId>/`
//   join:   `type@=joingroup/rid@=<roomId>/gid@=-9999/`
//   heartbeat: `type@=mrkl/` every 45 s
//   frames: 12-byte little-endian header (len, len, 689, 0, 0) + body
//           + trailing NUL.
// No auth / no cookie — the easiest danmaku of the five.
//
// Args for [start]: a `Map` with `roomId` (or a bare room-id string).
//
// Deviation from Pure Live, deliberate: Pure Live only emits `chatmsg`
// when the `if` field == '1' (room-fan flag). Gating on fan status hides
// most chat, so this port emits every `chatmsg`. Revisit only if spam
// becomes a problem.

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import '../../../core/models/live_models.dart';
import '../../../core/network/web_socket_util.dart';
import '../live_site.dart';

class DouyuDanmaku extends LiveDanmaku {
  DouyuDanmaku({WebSocketUtils? socket}) : _injectedSocket = socket;

  static const String _serverUrl = 'wss://danmuproxy.douyu.com:8506';
  static const int _heartbeatMs = 45 * 1000;

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  WebSocketUtils? _socket;
  final WebSocketUtils? _injectedSocket;
  String _roomId = '';
  int _generation = 0;

  @override
  Future<void> start(Map<String, dynamic> args) async {
    final generation = ++_generation;
    await _socket?.close();
    _socket = null;
    if (generation != _generation) return;
    _roomId = args['roomId']?.toString() ?? '';
    if (_roomId.isEmpty) {
      onClose?.call();
      return;
    }
    _connected = false;
    final socket = _injectedSocket ??
        WebSocketUtils(
          url: _serverUrl,
          heartBeatTime: _heartbeatMs,
          onMessage: (data) {
            if (generation == _generation) decodeMessage(_asBytes(data));
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

  void _joinRoom() {
    _socket?.sendMessage(serializeDouyu('type@=loginreq/roomid@=$_roomId/'));
    _socket?.sendMessage(
      serializeDouyu('type@=joingroup/rid@=$_roomId/gid@=-9999/'),
    );
  }

  @override
  Future<void> heartbeat() async {
    _socket?.sendMessage(serializeDouyu('type@=mrkl/'));
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

  /// Decode one inbound frame into [LiveMessage]s via [onMessage].
  /// A frame may hold several concatenated messages; malformed frames
  /// are skipped, never thrown.
  void decodeMessage(List<int> data) {
    try {
      final text = deserializeDouyu(data);
      if (text == null) return;
      var parsed = sttToJObject(text);
      // A frame holding several '//'-separated messages parses to a
      // List; take the first map (Pure Live drops these entirely).
      if (parsed is List) {
        parsed = parsed.firstWhere(
          (e) => e is Map,
          orElse: () => const <String, dynamic>{},
        );
      }
      if (parsed is! Map) return;
      final type = parsed['type']?.toString();
      if (type == 'rss' && parsed['ss']?.toString() == '0') {
        final close = onClose;
        unawaited(stop());
        close?.call();
        return;
      }
      LiveMessage? liveMsg;
      if (type == 'chatmsg') {
        final color = int.tryParse(parsed['col']?.toString() ?? '') ?? 0;
        liveMsg = LiveMessage(
          userName: parsed['nn']?.toString() ?? '',
          message: parsed['txt']?.toString() ?? '',
          color: douyuColorArgb(color),
        );
      }
      // `comm_chatmsg` / `voice_trlt` (super chat) carry a nested
      // LiveSuperChatMessage in Pure Live; our LiveMessage model has no
      // super-chat payload, so they are rendered as plain chat text.
      else if (type == 'comm_chatmsg') {
        final chat = parsed['chatmsg'];
        if (chat is Map) {
          final price = (int.tryParse(chat['cprice']?.toString() ?? '') ?? 0) ~/ 100;
          liveMsg = LiveMessage(
            userName: chat['nn']?.toString() ?? '',
            message: '💰 ¥$price ${chat['txt']?.toString() ?? ''}',
            color: 0xFFFFFFFF,
          );
        }
      }
      if (liveMsg != null && liveMsg.message.isNotEmpty) {
        onMessage?.call(liveMsg);
      }
    } catch (_) {
      // Best-effort: a bad frame must not kill the room.
    }
  }

  /// Frame one `type@=` body: [len][len][689:u16][0][0] body NUL.
  static List<int> serializeDouyu(String body) {
    final payload = utf8.encode(body);
    final total = 4 + 4 + payload.length + 1;
    final out = BytesBuilder(copy: false);
    final header = ByteData(12);
    header.setUint32(0, total, Endian.little);
    header.setUint32(4, total, Endian.little);
    header.setUint16(8, 689, Endian.little);
    header.setUint8(10, 0);
    header.setUint8(11, 0);
    out.add(header.buffer.asUint8List());
    out.add(payload);
    out.addByte(0);
    return out.takeBytes();
  }

  /// Strip the 12-byte header (+ trailing NUL) and UTF-8 decode the body.
  /// Returns null for a malformed frame.
  static String? deserializeDouyu(List<int> buffer) {
    try {
      if (buffer.length < 13) return null;
      final view = ByteData.sublistView(Uint8List.fromList(buffer));
      final fullLength = view.getUint32(0, Endian.little);
      final bodyLength = fullLength - 9;
      if (bodyLength < 0 || 12 + bodyLength > buffer.length) return null;
      final bytes = buffer.sublist(12, 12 + bodyLength);
      return utf8.decode(bytes);
    } catch (_) {
      return null;
    }
  }

  /// Parse Douyu's `key@=value/key2@=value2/` ("STT") encoding into
  /// nested maps/lists. `@S` -> `/`, `@A` -> `@`.
  static dynamic sttToJObject(String str) {
    if (str.contains('//')) {
      final result = [];
      for (final field in str.split('//')) {
        if (field.isEmpty) continue;
        result.add(sttToJObject(field));
      }
      return result;
    }
    if (str.contains('@=')) {
      final result = <String, dynamic>{};
      for (final field in str.split('/')) {
        if (field.isEmpty) continue;
        final tokens = field.split('@=');
        if (tokens.length < 2) continue;
        result[tokens[0]] = sttToJObject(_unescapeSlashAt(tokens[1]));
      }
      return result;
    } else if (str.contains('@A=')) {
      return sttToJObject(_unescapeSlashAt(str));
    } else {
      return _unescapeSlashAt(str);
    }
  }

  static String _unescapeSlashAt(String str) {
    return str.replaceAll('@S', '/').replaceAll('@A', '@');
  }

  /// Douyu `col` index -> ARGB colour (Pure Live `getColor`).
  static int douyuColorArgb(int type) {
    switch (type) {
      case 1:
        return 0xFFFF0000;
      case 2:
        return 0xFF1E87F0;
      case 3:
        return 0xFF7AC84B;
      case 4:
        return 0xFFFF7F00;
      case 5:
        return 0xFF9B39F4;
      case 6:
        return 0xFFFF69B4;
      default:
        return 0xFFFFFFFF;
    }
  }

  static List<int> _asBytes(dynamic data) {
    if (data is List<int>) return data;
    if (data is String) return utf8.encode(data);
    return const <int>[];
  }
}
