// Douyin audience counts — port of Pure Live 3.x
// lib/shared/platforms/douyin/douyin_audience.dart (verbatim logic).
//
// `douyinOnlineViewers` = concurrent viewers only; `douyinTotalViewers` =
// cumulative audience for the session. They deliberately stay separate so
// a large cumulative value is never ranked as people online.
//
// This project stores audience as an int on LiveRoom (`watching`), so
// [douyinWatching] parses the same candidates into an int: concurrent
// first, cumulative as fallback. Chinese units (万 = 1e4, 亿 = 1e8) and
// decimals ("1.2万") are expanded; unparseable input yields 0, never a
// thrown error.

/// Concurrent viewers, as the server's raw string ('' when unavailable).
String douyinOnlineViewers(dynamic room) {
  if (room is! Map) return '';
  final viewStats = room['room_view_stats'];
  final roomStats = room['stats'];
  final candidates = <dynamic>[
    // The current anonymous homepage feed exposes the concurrent count on
    // the room itself. Keep these candidates ahead of nested compatibility
    // fields so a stale nested placeholder cannot mask the live value.
    room['user_count'],
    room['user_count_str'],
    room['online_user_count'],
    room['online_user_for_anchor'],
    if (viewStats is Map) viewStats['user_count'],
    if (viewStats is Map) viewStats['online_user_count'],
    if (viewStats is Map) viewStats['online_user_for_anchor'],
    if (roomStats is Map) roomStats['user_count'],
    if (roomStats is Map) roomStats['online_user_count'],
    if (roomStats is Map) roomStats['online_user_for_anchor'],
  ];
  for (final value in candidates) {
    final text = value?.toString().trim() ?? '';
    if (text.isNotEmpty && text != 'null' && RegExp(r'[0-9]').hasMatch(text)) {
      return text;
    }
  }
  return '';
}

/// Cumulative audience for the session, as the server's raw string.
String douyinTotalViewers(dynamic room) {
  if (room is! Map) return '';
  final viewStats = room['room_view_stats'];
  final roomStats = room['stats'];
  final candidates = <dynamic>[
    if (viewStats is Map) viewStats['display_value'],
    if (viewStats is Map) viewStats['total_user_str'],
    if (viewStats is Map) viewStats['total_user'],
    if (roomStats is Map) roomStats['total_user_str'],
    if (roomStats is Map) roomStats['total_user'],
    room['total_user_str'],
    room['total_user'],
  ];
  for (final value in candidates) {
    final text = value?.toString().trim() ?? '';
    if (text.isEmpty || text == 'null' || !RegExp(r'[0-9]').hasMatch(text)) {
      continue;
    }
    final normalized = text.replaceAll(',', '').replaceAll('，', '');
    final number = double.tryParse(
            RegExp(r'[0-9]+(?:\.[0-9]+)?').firstMatch(normalized)?.group(0) ??
                '') ??
        0;
    // A zero `total_user` in the anonymous feed is an unavailable
    // placeholder when `user_count` is already positive. Ignore it so
    // the card can use its explicit concurrent count instead of a
    // false zero.
    if (number > 0) return text;
  }
  return '';
}

/// Audience count for LiveRoom.watching: concurrent viewers first,
/// cumulative audience as fallback, 0 when the server sent nothing usable.
int douyinWatching(dynamic room) {
  final online = douyinOnlineViewers(room);
  if (online.isNotEmpty) return _parseAudience(online);
  return _parseAudience(douyinTotalViewers(room));
}

int _parseAudience(String text) {
  final cleaned = text.replaceAll(',', '').replaceAll('，', '').trim();
  if (cleaned.isEmpty) return 0;
  final match =
      RegExp(r'([0-9]+(?:\.[0-9]+)?)\s*(万|亿|千)?').firstMatch(cleaned);
  if (match == null) return 0;
  final value = double.tryParse(match.group(1) ?? '') ?? 0;
  final unit = match.group(2);
  final multiplier = switch (unit) {
    '亿' => 100000000.0,
    '万' => 10000.0,
    '千' => 1000.0,
    _ => 1.0,
  };
  return (value * multiplier).round();
}
