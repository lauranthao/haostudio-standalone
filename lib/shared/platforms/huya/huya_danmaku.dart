// Huya danmaku — TARS-serialised WebSocket.
//
// Port of Pure Live 3.x `lib/shared/platforms/huya/huya_danmaku.dart`
// (529 lines) + `lib/core/tars/` (vendored under `lib/core/tars/codec/`):
//   WS wss://wsapi.huya.com
//   join: TARS EWSCmdC2S_RegisterGroupReq (16) with groups
//         `live:<topSid>` / `chat:<topSid>`
//   heartbeat: TARS EWSCmdC2S_HeartBeatReq (20) every 60 s
//   inbound: TARS command type 7 (HYPushMessage) or 22 (HYPushMessageV2)
//     uri 1400  -> chat message (HYMessage)
//     uri 8006  -> attendee count (no field in our LiveMessage; skipped)
//     uri 8001  -> presenter uid; stream ended when it matches ours
//     uri 2001314 -> super-chat board notification (see TODO below)
//
// Args for [start] (from the room detail's `danmakuData`):
//   - `uid`: PRESENTER uid (gameLiveInfo['uid']); used only for the
//     uri-8001 stream-ended check. 0 when unknown.
//   - `topSid` / `subSid`: from the room detail's stream info
//     (`lChannelId` / `lSubChannelId`). When absent, the room page
//     `https://www.huya.com/<roomId>` is scraped once for
//     `TT_ROOM_DATA` + `stream:` (the adapter is still a stub).
//   - `roomId`: needed only for that scrape fallback.
//
// TODO (stubbed, per task — after transports 1-4): HTTP WUP super-chat
// fallback (`POST https://wup.huya.com`, TARS/TUP,
// `getHuyaSuperChatMessageList` in Pure Live `huya_utils.dart` L40-70).
// uri-2001314 notifications are currently ignored, so 醒目留言 (super
// chat) does not appear; normal chat is unaffected.
//
// IMPLEMENTED (v1.0.4): the fallback lives in huya_wup.dart
// (`getHuyaSuperChatMessageList` + `huyaSuperChatsFromPanel`) and is
// reconciled here the way Pure Live does it — a 2001314 notification
// first tries to parse the panel straight from the WS payload; when
// that fails (or the board lags the notification) a bounded background
// refresh re-fetches the board with dedupe, so a super chat is never
// lost and never shown twice. The "(来自…上头条)" headline broadcast
// on uri-1400 triggers the same refresh pipeline.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

import '../../../core/models/live_models.dart';
import '../../../core/network/http_client.dart';
import '../../../core/network/web_socket_util.dart';
import '../../../core/tars/codec/tars_input_stream.dart';
import '../../../core/tars/codec/tars_output_stream.dart';
import '../../../core/tars/codec/tars_struct.dart';
import '../../../core/tars/game_event_message_board_panel.dart';
import '../live_site.dart';
import 'huya_models.dart';
import 'huya_wup.dart';

// HuyaDanmakuArgs (uid / topSid / subSid, keys 'uid' / 'topSid' /
// 'subSid') lives in huya_models.dart — the room parser stores it in
// LiveRoom.danmakuData via toDataMap(). NOTE: `uid` is the PRESENTER's
// uid (gameLiveInfo['uid'], as in Pure Live), not the viewer's; it is
// used only for the uri-8001 stream-ended check.

/// Fetches the super-chat board for one room (topSid). Defaults to the
/// live WUP call; tests inject a stub.
typedef HuyaSuperChatFetcher = Future<List<LiveSuperChatMessage>> Function(
  int lPid,
);

/// Wraps one super chat as a [LiveMessage] entry.
///
/// Upstream convention (Pure Live HuyaDanmaku): the userName/message
/// fields carry the `SUPER_CHAT_MESSAGE` placeholder and the real payload
/// rides in [LiveMessage.data] as a [LiveSuperChatMessage]; the room UI
/// renders super chats from `data`, not from the text fields.
LiveMessage huyaSuperChatLiveMessage(LiveSuperChatMessage chat) =>
    LiveMessage(
      type: LiveMessageType.superChat,
      userName: 'SUPER_CHAT_MESSAGE',
      message: 'SUPER_CHAT_MESSAGE',
      color: 0xFFFFFFFF,
      data: chat,
    );

class HuyaDanmaku extends LiveDanmaku {
  HuyaDanmaku({
    HuyaSuperChatFetcher? superChatFetcher,
    List<Duration>? superChatRetryDelays,
  })  : _superChatFetcher = superChatFetcher ??
            ((lPid) =>
                getHuyaSuperChatMessageList(lPid: lPid, first: true)),
        _superChatRetryDelays = List<Duration>.unmodifiable(
            superChatRetryDelays ?? defaultSuperChatRetryDelays);

  static const List<Duration> defaultSuperChatRetryDelays = <Duration>[
    Duration.zero,
    Duration(milliseconds: 600),
    Duration(milliseconds: 1800),
    Duration(milliseconds: 4000),
  ];

  final HuyaSuperChatFetcher _superChatFetcher;
  final List<Duration> _superChatRetryDelays;
  final Set<LiveSuperChatMessage> _emittedSuperChats =
      <LiveSuperChatMessage>{};
  static const int _maxRememberedSuperChats = 512;

  /// 醒目留言在弹幕区的播报形态："xxx(来自一元上头条)"。
  static final RegExp _headlineScRegex = RegExp(r'\(来自.+?上头条\)');

  Future<void>? _superChatRefreshFuture;
  bool _superChatRefreshQueued = false;

  static const String _serverUrl = 'wss://wsapi.huya.com';
  static const int _heartbeatMs = 60 * 1000;

  bool _connected = false;

  @override
  bool get isConnected => _connected;

  WebSocketUtils? _socket;
  HuyaDanmakuArgs _args = const HuyaDanmakuArgs(uid: 0, topSid: 0, subSid: 0);
  int _generation = 0;

  /// Current website heartbeat: `EWSCmdC2S_HeartBeatReq` (20).
  static List<int> get heartbeatData {
    final command = TarsOutputStream();
    command.write(20, 0);
    command.write(Uint8List(0), 1);
    return command.toUint8List();
  }

  @override
  Future<void> start(Map<String, dynamic> args) async {
    final generation = ++_generation;
    _superChatRefreshFuture = null;
    _emittedSuperChats.clear();
    _superChatRefreshQueued = false;
    await _socket?.close();
    _socket = null;
    _args = HuyaDanmakuArgs.fromDataMap(args) ??
        HuyaDanmakuArgs(
          uid: _asInt(args['uid']),
          topSid: _asInt(args['topSid']),
          subSid: _asInt(args['subSid']),
        );
    _connected = false;
    if (_args.topSid == 0) {
      // Fallback: scrape topSid/subSid from the room page.
      final roomId = args['roomId']?.toString().trim() ?? '';
      if (roomId.isEmpty) {
        onClose?.call(); // NOTE: reason string dropped — LiveDanmaku.onClose takes no args
        return;
      }
      final resolved = await _resolveSids(roomId);
      if (generation != _generation) return;
      if (resolved == null) {
        onClose?.call(); // NOTE: reason string dropped — LiveDanmaku.onClose takes no args
        return;
      }
      _args = HuyaDanmakuArgs(
        uid: _args.uid,
        topSid: resolved.topSid,
        subSid: resolved.subSid,
      );
    }
    if (generation != _generation) return;
    final socket = WebSocketUtils(
      url: _serverUrl,
      heartBeatTime: _heartbeatMs,
      onMessage: (data) {
        if (generation == _generation) {
          unawaited(decodeMessage(_asBytes(data)));
        }
      },
      onReady: () {
        if (generation != _generation) return;
        _connected = true;
        onReady?.call();
        _joinRoom();
        unawaited(heartbeat());
      },
      onHeartBeat: () {
        if (generation == _generation) heartbeat();
      },
      onReconnect: () {
        if (generation != _generation) return;
        _connected = false;
        onReconnect?.call(); // NOTE: reason string dropped — LiveDanmaku.onReconnect takes no args
      },
      onClose: (_) {
        if (generation != _generation) return;
        _connected = false;
        onClose?.call(); // NOTE: message dropped — LiveDanmaku.onClose takes no args
      },
    );
    _socket = socket;
    await socket.connect();
  }

  void _joinRoom() {
    _socket?.sendMessage(getJoinData(_args.topSid));
  }

  /// TARS group-join: EWSCmdC2S_RegisterGroupReq (16) with
  /// groups [`live:<topSid>`, `chat:<topSid>`].
  static List<int> getJoinData(int topSid) {
    try {
      final group = TarsOutputStream();
      group.write(<String>['live:$topSid', 'chat:$topSid'], 0);
      group.write('', 1);
      final command = TarsOutputStream();
      command.write(16, 0);
      command.write(group.toUint8List(), 1);
      return command.toUint8List();
    } catch (_) {
      return <int>[];
    }
  }

  @override
  Future<void> heartbeat() async {
    _socket?.sendMessage(heartbeatData);
  }

  @override
  Future<void> stop() async {
    _generation++;
    _superChatRefreshFuture = null;
    _superChatRefreshQueued = false;
    _emittedSuperChats.clear();
    _connected = false;
    onMessage = null;
    onReconnect = null;
    onClose = null;
    onReady = null;
    await _socket?.close();
    _socket = null;
  }

  Future<void> decodeMessage(List<int> data) async {
    try {
      final stream = TarsInputStream(Uint8List.fromList(data));
      final type = stream.read(0, 0, false);
      if (type == 7) {
        final inner = TarsInputStream(stream.readBytes(1, false));
        final pushMessage = HYPushMessage();
        pushMessage.readFrom(inner);
        await _decodePush(pushMessage.uri, pushMessage.msg);
      } else if (type == 22) {
        final push = HYPushMessageV2();
        push.readFrom(TarsInputStream(stream.readBytes(1, false)));
        for (final item in push.items) {
          await _decodePush(item.uri, item.msg, messageId: item.messageId);
        }
      }
    } catch (_) {
      // Best-effort: a bad frame must not kill the room.
    }
  }

  Future<void> _decodePush(int uri, List<int> payload, {int messageId = 0}) async {
    if (uri == 1400) {
      final messageNotice = HYMessage();
      messageNotice.readFrom(
        TarsInputStream(Uint8List.fromList(payload)),
      );
      final color = messageNotice.bulletFormat.fontColor;
      // "xxx(来自 XX 上头条)" 是醒目留言在弹幕区的播报。消息板 WUP 尚未
      // 更新时该播报先到，靠它触发一次后台重拉把这条 SC 补上——与
      // 2001314 通知共用同一条刷新管线（不阻塞解码）。
      if (_headlineScRegex.hasMatch(messageNotice.content)) {
        _scheduleSuperChatRefresh(_generation);
      }
      onMessage?.call(
        LiveMessage(
          userName: messageNotice.userInfo.nickName,
          message: messageNotice.content,
          color: color <= 0
              ? 0xFFFFFFFF
              : (0xFF000000 | (color & 0xFFFFFF)),
        ),
      );
    } else if (uri == 8006) {
      // Attendee count — no field in our LiveMessage; skipped.
      return;
    } else if (uri == 2001314) {
      final fromPanel = HuyaDanmaku.superChatsFromPanel(payload);
      if (fromPanel != null) {
        for (final chat in fromPanel) {
          if (!_rememberSuperChat(chat)) continue;
          onMessage?.call(huyaSuperChatLiveMessage(chat));
        }
        return;
      }
      // The notification can arrive before the message-board WUP result
      // is updated. Fetching once here loses that SC until a manual room
      // refresh; awaiting the HTTP call also serializes unrelated
      // websocket messages. Reconcile in the background with a small
      // bounded retry window instead.
      _scheduleSuperChatRefresh(_generation);
    } else if (uri == 8001) {
      var presenterUid = 0;
      try {
        final raw = TarsInputStream(
          Uint8List.fromList(payload),
        ).read(0, 0, false);
        presenterUid = raw is int ? raw : 0;
      } catch (_) {
        return;
      }
      if (presenterUid == 0 || presenterUid == _args.uid) {
        final close = onClose;
        await stop();
        close?.call(); // NOTE: reason string dropped — LiveDanmaku.onClose takes no args
      }
    }
  }

  /// Parses the super-chat panel straight from a uri-2001314 WS payload.
  /// Returns null when the payload carries no panel at tag 1 (caller
  /// falls back to the HTTP board refresh).
  @visibleForTesting
  static List<LiveSuperChatMessage>? superChatsFromPanel(
    List<int> payload, {
    DateTime? now,
  }) {
    if (payload.isEmpty) return null;
    final GameEventMessageBoardPanel panel;
    try {
      final bytes = Uint8List.fromList(payload);
      if (!TarsInputStream(bytes).skipToTag(1)) return null;
      panel = GameEventMessageBoardPanel()
        ..readFrom(TarsInputStream(bytes));
    } catch (_) {
      return null;
    }
    return huyaSuperChatsFromPanel(panel, now: now);
  }

  void _scheduleSuperChatRefresh(int generation) {
    if (generation != _generation) return;
    if (_superChatRefreshFuture != null) {
      _superChatRefreshQueued = true;
      return;
    }

    _superChatRefreshQueued = false;
    final future = _refreshSuperChats(generation);
    _superChatRefreshFuture = future;
    unawaited(
      future.whenComplete(() {
        if (identical(_superChatRefreshFuture, future)) {
          _superChatRefreshFuture = null;
        }
        if (_superChatRefreshQueued && generation == _generation) {
          _scheduleSuperChatRefresh(generation);
        }
      }),
    );
  }

  Future<void> _refreshSuperChats(int generation) async {
    for (var attempt = 0; attempt < _superChatRetryDelays.length; attempt++) {
      final delay = _superChatRetryDelays[attempt];
      if (delay > Duration.zero) await Future<void>.delayed(delay);
      if (generation != _generation || _args.topSid == 0) return;

      try {
        final messages = await _superChatFetcher(_args.topSid)
            .timeout(const Duration(seconds: 3));
        if (generation != _generation) return;

        final hadKnownMessages = _emittedSuperChats.isNotEmpty;
        var emittedNewMessage = false;
        for (final message in messages) {
          if (!_rememberSuperChat(message)) continue;
          emittedNewMessage = true;
          onMessage?.call(huyaSuperChatLiveMessage(message));
        }

        // Once this transport already has a baseline, an unseen item
        // proves that the delayed WUP board caught up and no later retry
        // is needed.
        if (hadKnownMessages && emittedNewMessage) return;
      } catch (_) {
        // Best-effort: a failed board fetch must not kill the room.
        // Retries are bounded by _superChatRetryDelays.
      }
    }
  }

  bool _rememberSuperChat(LiveSuperChatMessage message) {
    if (!_emittedSuperChats.add(message)) return false;
    while (_emittedSuperChats.length > _maxRememberedSuperChats) {
      _emittedSuperChats.remove(_emittedSuperChats.first);
    }
    return true;
  }

  @visibleForTesting
  Future<void> waitForPendingSuperChatRefresh() async {
    while (_superChatRefreshFuture != null) {
      await _superChatRefreshFuture;
    }
  }

  /// Seeds the room args without connecting (tests only): decodeMessage
  /// paths that need a topSid (super-chat refresh) can be exercised
  /// without a live WebSocket.
  @visibleForTesting
  void setTestArgs(HuyaDanmakuArgs args) {
    _args = args;
  }

  /// Scrape `topSid`/`subSid` from the room page:
  /// `stream: {...}` -> `data[0].gameStreamInfoList[0]`
  /// (`lChannelId` -> topSid, `lSubChannelId` -> subSid).
  /// Best-effort: null on any failure.
  static Future<HuyaDanmakuArgs?> _resolveSids(String roomId) async {
    try {
      final dio = sharedDio();
      final response = await dio.get<String>(
        'https://www.huya.com/$roomId',
        options: Options(
          headers: <String, String>{
            'Origin': 'https://www.huya.com',
            'Referer': 'https://www.huya.com',
            'Accept':
                'text/html,application/xhtml+xml,application/xml;q=0.9,*/*;q=0.8',
          },
          responseType: ResponseType.plain,
        ),
      );
      final html = response.data ?? '';
      final match = RegExp(
        r'stream:\s*(\{[\s\S]*?\n\s*\})',
      ).firstMatch(html);
      if (match == null) return null;
      final stream = jsonDecode(match.group(1)!);
      if (stream is! Map) return null;
      final data = stream['data'];
      if (data is! List || data.isEmpty) return null;
      final first = data[0];
      if (first is! Map) return null;
      final infoList = first['gameStreamInfoList'];
      if (infoList is! List || infoList.isEmpty) return null;
      final info = infoList[0];
      if (info is! Map) return null;
      int asInt(dynamic value) => int.tryParse(value?.toString() ?? '') ?? 0;
      final topSid = asInt(info['lChannelId']);
      final subSid = asInt(info['lSubChannelId']);
      if (topSid == 0) return null;
      return HuyaDanmakuArgs(uid: 0, topSid: topSid, subSid: subSid);
    } catch (_) {
      return null;
    }
  }

  static List<int> _asBytes(dynamic data) {
    if (data is List<int>) return data;
    if (data is String) return utf8.encode(data);
    return const <int>[];
  }

  static int _asInt(dynamic value) =>
      int.tryParse(value?.toString() ?? '') ?? 0;
}

// --- TARS structs (from Pure Live huya_danmaku.dart) ---

class HYPushMessage extends TarsStruct {
  int pushType = 0;
  int uri = 0;
  List<int> msg = <int>[];
  int protocolType = 0;

  @override
  void readFrom(TarsInputStream inputStream) {
    pushType = inputStream.read(pushType, 0, false);
    uri = inputStream.read(uri, 1, false);
    msg = inputStream.readBytes(2, false);
    protocolType = inputStream.read(protocolType, 3, false);
  }

  @override
  void writeTo(TarsOutputStream outputStream) {}

  @override
  Object deepCopy() {
    return HYPushMessage()
      ..pushType = pushType
      ..uri = uri
      ..msg = List<int>.from(msg)
      ..protocolType = protocolType;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class HYPushMessageV2 extends TarsStruct {
  String groupId = '';
  List<HYMessageItem> items = <HYMessageItem>[];

  @override
  void readFrom(TarsInputStream inputStream) {
    groupId = inputStream.read(groupId, 0, false);
    items = inputStream.readList<HYMessageItem>(
      <HYMessageItem>[HYMessageItem()],
      1,
      false,
    );
  }

  @override
  void writeTo(TarsOutputStream outputStream) {
    outputStream.write(groupId, 0);
    outputStream.write(items, 1);
  }

  @override
  Object deepCopy() => HYPushMessageV2()
    ..groupId = groupId
    ..items = items.map((item) => item.deepCopy() as HYMessageItem).toList();

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class HYMessageItem extends TarsStruct {
  int uri = 0;
  List<int> msg = <int>[];
  int messageId = 0;

  @override
  void readFrom(TarsInputStream inputStream) {
    uri = inputStream.read(uri, 0, false);
    msg = inputStream.readBytes(1, false);
    messageId = inputStream.read(messageId, 2, false);
  }

  @override
  void writeTo(TarsOutputStream outputStream) {
    outputStream.write(uri, 0);
    outputStream.write(Uint8List.fromList(msg), 1);
    outputStream.write(messageId, 2);
  }

  @override
  Object deepCopy() => HYMessageItem()
    ..uri = uri
    ..msg = List<int>.from(msg)
    ..messageId = messageId;

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class HYSender extends TarsStruct {
  int uid = 0;
  int lMid = 0;
  String nickName = '';
  int gender = 0;

  @override
  void readFrom(TarsInputStream inputStream) {
    uid = inputStream.read(uid, 0, false);
    // NOTE: Pure Live reads lMid from tag 0 as well (same value as uid);
    // kept as-is to stay byte-identical with the reference.
    lMid = inputStream.read(lMid, 0, false);
    nickName = inputStream.read(nickName, 2, false);
    gender = inputStream.read(gender, 3, false);
  }

  @override
  void writeTo(TarsOutputStream outputStream) {}

  @override
  Object deepCopy() {
    return HYSender()
      ..uid = uid
      ..lMid = lMid
      ..nickName = nickName
      ..gender = gender;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class HYMessage extends TarsStruct {
  HYSender userInfo = HYSender();
  String content = '';
  HYBulletFormat bulletFormat = HYBulletFormat();

  @override
  void readFrom(TarsInputStream inputStream) {
    userInfo = inputStream.readTarsStruct(userInfo, 0, false) as HYSender;
    content = inputStream.read(content, 3, false);
    bulletFormat =
        inputStream.readTarsStruct(bulletFormat, 6, false) as HYBulletFormat;
  }

  @override
  void writeTo(TarsOutputStream outputStream) {}

  @override
  Object deepCopy() {
    return HYMessage()
      ..userInfo = userInfo.deepCopy() as HYSender
      ..content = content
      ..bulletFormat = bulletFormat.deepCopy() as HYBulletFormat;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}

class HYBulletFormat extends TarsStruct {
  int fontColor = 0;
  int fontSize = 4;
  int textSpeed = 0;
  int transitionType = 1;

  @override
  void readFrom(TarsInputStream inputStream) {
    fontColor = inputStream.read(fontColor, 0, false);
    fontSize = inputStream.read(fontSize, 1, false);
    textSpeed = inputStream.read(textSpeed, 2, false);
    transitionType = inputStream.read(transitionType, 3, false);
  }

  @override
  void writeTo(TarsOutputStream outputStream) {}

  @override
  Object deepCopy() {
    return HYBulletFormat()
      ..fontColor = fontColor
      ..fontSize = fontSize
      ..textSpeed = textSpeed
      ..transitionType = transitionType;
  }

  @override
  void displayAsString(StringBuffer sb, int level) {}
}
