// Live audience metrics — item 6 (build 29, I group).
//
// The five adapters all stuff their platform's audience number into
// `LiveRoom.watching`, but the number is NOT the same kind of number
// everywhere. Showing every one of them as "X 人在看" was a lie on
// two platforms:
//
// | platform | source field (verified in the adapter) | kind |
// |---|---|---|
// | bilibili | `online` (bilibili_site.dart detail + search) | 在线人数 |
// | douyu | `hot` (douyu_site.dart detail `room_biz_all.hot`, search `hot`) | 热度 |
// | huya | `totalCount` / `game_total_count` / popularity (huya_room_parser.dart) | 热度 |
// | douyin | concurrent `user_count` first, cumulative `total_user` fallback (douyin_audience.dart `douyinWatching`) | 观看数 (not 在线 — the int alone cannot tell which of the two it is) |
// | kuaishou | `watchingCount` (kuaishou_room_parser.dart) | 在线人数 |
//
// Douyu's hot-page list uses `ol` (online) for the same field — the
// `LiveRoom` carries only the int, so the per-platform kind above is
// the honest label for the value the detail/search paths produce,
// which is what the follow/search/room surfaces show. When a value
// is 0 / unknown, nothing is shown at all (never a fabricated 0).
//
// This file is the single source of truth: every live surface that
// shows the number (tab cards, follow cards, search rows, room info,
// detail sheet, switch panel) formats it through [metricLabelFor].

/// What kind of audience number a platform reports.
enum LiveMetricKind {
  /// Real concurrent viewers (Bilibili `online`, Kuaishou `watchingCount`).
  online,

  /// Platform "heat" — an opaque popularity score, NOT a head count
  /// (Douyu `hot`, Huya `totalCount`).
  heat,

  /// Douyin: concurrent viewers when the server sent them, cumulative
  /// session audience as fallback — the int alone cannot tell which,
  /// so it is never labelled 在线.
  views,
}

/// The audience metric for one platform: kind + the label shown next
/// to the number.
class LiveMetric {
  const LiveMetric(this.kind, this.label);

  final LiveMetricKind kind;

  /// Short label shown with the number, e.g. "在线", "热度", "观看".
  final String label;
}

/// Metric for [platformId]; unknown ids get [LiveMetricKind.views]
/// with the neutral "观看" label — never "在线" for a number whose
/// provenance is unknown.
LiveMetric metricForPlatform(String platformId) {
  switch (platformId) {
    case 'bilibili':
    case 'kuaishou':
      return const LiveMetric(LiveMetricKind.online, '在线');
    case 'douyu':
    case 'huya':
      return const LiveMetric(LiveMetricKind.heat, '热度');
    case 'douyin':
      return const LiveMetric(LiveMetricKind.views, '观看');
    default:
      return const LiveMetric(LiveMetricKind.views, '观看');
  }
}

/// "热度 1.2万" / "在线 1234人" / "观看 3.4万". Empty string when
/// [watching] <= 0 (unknown — never show a fabricated 0).
String metricLabelFor(String platformId, int watching) {
  if (watching <= 0) return '';
  final metric = metricForPlatform(platformId);
  final num = formatAudience(watching);
  return switch (metric.kind) {
    LiveMetricKind.online => '在线 $num人',
    LiveMetricKind.heat => '热度 $num',
    LiveMetricKind.views => '观看 $num',
  };
}

/// Audience count: 12345 -> "1.2万", smaller counts as-is.
/// Same rule as the old formatWatching everywhere (kept so the
/// numbers themselves do not change — only their labels do).
String formatAudience(int watching) {
  if (watching >= 10000) {
    return '${(watching / 10000).toStringAsFixed(1)}万';
  }
  return '$watching';
}
