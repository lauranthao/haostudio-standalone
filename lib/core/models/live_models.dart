// Shared live models — ported from Pure Live 3.x
// (lib/core/models/live_room.dart, live_play_quality.dart, live_message.dart,
// lib/core/consts/platform_ids.dart).

/// Platform ids (platform_ids.dart).
class PlatformIds {
  PlatformIds._();

  static const String bilibili = 'bilibili';
  static const String douyu = 'douyu';
  static const String huya = 'huya';
  static const String douyin = 'douyin';
  static const String kuaishou = 'kuaishou';
}

/// A live room (LiveRoom). `data` is the play descriptor, `danmakuData`
/// the chat credentials — both filled by getRoomDetail.
class LiveRoom {
  const LiveRoom({
    required this.roomId,
    required this.platform,
    this.title = '',
    this.cover = '',
    this.nick = '',
    this.avatar = '',
    this.watching = 0,
    this.liveStatus = false,
    this.link = '',
    this.data,
    this.danmakuData,
  });

  final String roomId;
  final String platform;
  final String title;
  final String cover;
  final String nick;
  final String avatar;
  final int watching;
  final bool liveStatus;
  final String link;

  /// Play descriptor (adapter-specific, e.g. stream info / playUrls).
  final Map<String, dynamic>? data;

  /// Danmaku credentials (adapter-specific).
  final Map<String, dynamic>? danmakuData;

  LiveRoom copyWith({
    String? title,
    String? cover,
    String? nick,
    String? avatar,
    int? watching,
    bool? liveStatus,
    String? link,
    Map<String, dynamic>? data,
    Map<String, dynamic>? danmakuData,
  }) {
    return LiveRoom(
      roomId: roomId,
      platform: platform,
      title: title ?? this.title,
      cover: cover ?? this.cover,
      nick: nick ?? this.nick,
      avatar: avatar ?? this.avatar,
      watching: watching ?? this.watching,
      liveStatus: liveStatus ?? this.liveStatus,
      link: link ?? this.link,
      data: data ?? this.data,
      danmakuData: danmakuData ?? this.danmakuData,
    );
  }
}

/// A quality menu item (LivePlayQuality).
///
/// `id` is the stable platform identifier for server-ack matching — never
/// derive identity from `data`. `rate` ids (Douyu) are opaque, never
/// sorted numerically.
class LivePlayQuality {
  const LivePlayQuality({
    required this.quality,
    this.data,
    this.id,
    this.sort = 0,
    this.isPlaybackUnconfirmed = false,
    this.declaredAspectRatio,
  });

  /// Display label, e.g. 原画 / 蓝光8M / 超清 / 流畅.
  final String quality;

  /// Adapter-specific payload — usually the URL list for this quality.
  final dynamic data;

  /// Stable platform identifier for server-ack matching.
  final String? id;

  final int sort;

  /// Server did not confirm this quality (show as-is, never rename).
  final bool isPlaybackUnconfirmed;

  final double? declaredAspectRatio;

  /// Selection identity: id when present, else the label.
  String get selectionId => id ?? quality;
}

/// Category / area model (LiveArea).
class LiveArea {
  const LiveArea({
    required this.areaId,
    required this.areaName,
    this.areaPic = '',
    this.platform = '',
  });

  final String areaId;
  final String areaName;
  final String areaPic;
  final String platform;
}

/// A super-chat (醒目留言) message — port of Pure Live 3.x
/// `LiveSuperChatMessage` (lib/core/models/live_message.dart).
///
/// Equality is by platform event id when present ([messageId]); the board
/// API rebuilds [startTime] from a countdown on every poll, so time-based
/// equality would make the same paid message look new. Without an id it
/// falls back to user + text + price.
class LiveSuperChatMessage {
  const LiveSuperChatMessage({
    this.messageId = '',
    required this.backgroundBottomColor,
    required this.backgroundColor,
    required this.endTime,
    required this.face,
    required this.message,
    required this.price,
    required this.startTime,
    required this.userName,
  });

  /// Stable platform event identity when the protocol exposes one
  /// (prefixed `huya:<lMessageId>` for Huya).
  final String messageId;
  final String userName;
  final String face;
  final String message;
  final int price;
  final DateTime startTime;
  final DateTime endTime;
  final String backgroundColor;
  final String backgroundBottomColor;

  @override
  bool operator ==(Object other) {
    if (other is! LiveSuperChatMessage) return false;
    if (messageId.isNotEmpty || other.messageId.isNotEmpty) {
      return messageId.isNotEmpty &&
          other.messageId.isNotEmpty &&
          other.messageId == messageId;
    }
    return other.userName == userName &&
        other.message == message &&
        other.price == price;
  }

  @override
  int get hashCode => messageId.isNotEmpty
      ? messageId.hashCode
      : Object.hash(userName, message, price);
}

/// Message kind — port of Pure Live 3.x `LiveMessageType`, only the kinds
/// this project produces so far. Chat is the default everywhere; Huya
/// emits [superChat] for 醒目留言 with the payload in [LiveMessage.data].
enum LiveMessageType {
  chat,
  superChat,
}

/// One normalised danmaku message — all five adapters produce this.
class LiveMessage {
  const LiveMessage({
    required this.message,
    this.userName = '',
    this.color = 0xFFFFFFFF,
    this.isOwn = false,
    this.type = LiveMessageType.chat,
    this.data,
  });

  final String message;
  final String userName;

  /// ARGB colour.
  final int color;
  final bool isOwn;

  final LiveMessageType type;

  /// Kind-specific payload — a [LiveSuperChatMessage] when [type] is
  /// [LiveMessageType.superChat], null otherwise.
  final dynamic data;
}
