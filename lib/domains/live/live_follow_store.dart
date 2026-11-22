// Live follow store (L03) — Hive-backed (`hao_live_follows`).
//
// NOTE: no follow store existed in the Flutter app before this file
// — the task's "flat follow list" was the web app's `haoLiveFollows`
// (localStorage), which was never ported. This store is the Flutter
// follow data the follows page reuses; the follow toggle lives on the
// live tab's room cards and on history cards (the live room page
// itself is owned by another agent and is not touched here).
//
// Pure Live reference: features/favorite/favorite_page.dart,
// favorite_rules.dart (`roomsOf`, `groupOf`). Web equivalents
// translated: localStorage -> Hive, `#/live/follows` -> LiveFollowsPage.

import 'dart:convert';

import '../../core/models/live_models.dart';
import '../../core/storage/hive_store.dart';

/// One followed anchor / room.
class LiveFollow {
  const LiveFollow({
    required this.platform,
    required this.roomId,
    this.title = '',
    this.nick = '',
    this.cover = '',
    required this.followedAt,
    // Follow group / tag (build 29, item 5): free-form, '' = 未分组.
    // Old stored follows have no `group` key and read as ''.
    this.group = '',
  });

  factory LiveFollow.fromRoom(LiveRoom room, {DateTime? at}) =>
      LiveFollow(
        platform: room.platform,
        roomId: room.roomId,
        title: room.title,
        nick: room.nick,
        cover: room.cover,
        followedAt: (at ?? DateTime.now()).millisecondsSinceEpoch,
      );

  factory LiveFollow.fromJson(Map<String, dynamic> json) => LiveFollow(
    platform: json['platform']?.toString() ?? '',
    roomId: json['roomId']?.toString() ?? '',
    title: json['title']?.toString() ?? '',
    nick: json['nick']?.toString() ?? '',
    cover: json['cover']?.toString() ?? '',
    followedAt: (json['followedAt'] as num?)?.toInt() ?? 0,
    group: json['group']?.toString() ?? '',
  );

  final String platform;
  final String roomId;
  final String title;
  final String nick;
  final String cover;

  /// When the follow was added, epoch milliseconds.
  final int followedAt;

  /// Follow group / tag, '' = 未分组.
  final String group;

  /// `platform|roomId` — the identity key for add / remove / lookup.
  String get identityKey => '$platform|$roomId';

  Map<String, dynamic> toJson() => {
    'platform': platform,
    'roomId': roomId,
    'title': title,
    'nick': nick,
    'cover': cover,
    'followedAt': followedAt,
    'group': group,
  };

  LiveFollow copyWith({String? group}) => LiveFollow(
    platform: platform,
    roomId: roomId,
    title: title,
    nick: nick,
    cover: cover,
    followedAt: followedAt,
    group: group ?? this.group,
  );

  LiveRoom toRoom() => LiveRoom(
    roomId: roomId,
    platform: platform,
    title: title,
    nick: nick,
    cover: cover,
  );
}

/// Follow store (`hao_live_follows`, most recently followed first).
class LiveFollowStore {
  static List<LiveFollow> getAll() {
    final raw = HiveStore.box.get(HiveKeys.liveFollows);
    if (raw is! String || raw.isEmpty) return const [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(LiveFollow.fromJson)
            .toList();
      }
    } catch (_) {}
    return const [];
  }

  static Future<void> _save(List<LiveFollow> follows) async {
    await HiveStore.put(
      HiveKeys.liveFollows,
      jsonEncode(follows.map((f) => f.toJson()).toList()),
    );
  }

  static bool isFollowed(String platform, String roomId) =>
      getAll().any((f) => f.identityKey == '$platform|$roomId');

  static bool isFollowedRoom(LiveRoom room) =>
      isFollowed(room.platform, room.roomId);

  static Future<void> add(LiveRoom room) async {
    final follow = LiveFollow.fromRoom(room);
    final list = getAll()
        .where((f) => f.identityKey != follow.identityKey)
        .toList();
    list.insert(0, follow);
    await _save(list);
  }

  static Future<void> remove(String platform, String roomId) async {
    final key = '$platform|$roomId';
    await _save(getAll().where((f) => f.identityKey != key).toList());
  }

  /// Toggle follow; returns the new state (true = now followed).
  static Future<bool> toggle(LiveRoom room) async {
    if (isFollowedRoom(room)) {
      await remove(room.platform, room.roomId);
      return false;
    }
    await add(room);
    return true;
  }

  /// Platforms that have at least one follow, in first-seen order.
  static List<String> followedPlatforms() {
    final seen = <String>[];
    for (final f in getAll()) {
      if (!seen.contains(f.platform)) seen.add(f.platform);
    }
    return seen;
  }

  /// Follow groups in use, in first-seen order ('' excluded — the
  /// 未分组 group is shown separately by the page, never as a tag).
  static List<String> groups() {
    final seen = <String>[];
    for (final f in getAll()) {
      if (f.group.isNotEmpty && !seen.contains(f.group)) {
        seen.add(f.group);
      }
    }
    return seen;
  }

  /// Move one follow into [group] ('' = 未分组). The follow's other
  /// fields are untouched; a missing follow is a no-op.
  static Future<void> setGroup(
    String platform,
    String roomId,
    String group,
  ) async {
    final key = '$platform|$roomId';
    final list = getAll();
    final at = list.indexWhere((f) => f.identityKey == key);
    if (at < 0) return;
    list[at] = list[at].copyWith(group: group.trim());
    await _save(list);
  }

  /// Rename a group (all its follows move together). No-op when the
  /// old name is unused or the new name is blank.
  static Future<void> renameGroup(String oldName, String newName) async {
    final next = newName.trim();
    if (oldName.isEmpty || next.isEmpty || oldName == next) return;
    final list = getAll()
        .map((f) => f.group == oldName ? f.copyWith(group: next) : f)
        .toList();
    await _save(list);
  }

  static Future<void> clear() async {
    await HiveStore.put(HiveKeys.liveFollows, '[]');
  }
}
