// Watch-history retention period — item 11b (build 29, I group).
//
// The history store already had a COUNT limit (default 50); it had
// no TIME limit. Retention is now a period: entries older than the
// period are pruned. 0 days = keep forever.
//
// Pruning runs on record (new entries push old ones out) and on
// demand ([prune]) — never silently on read, so `getAll()` stays a
// pure read. The setting lives in Hive under a literal key (HiveKeys
// is owned by the settings group — the literal is named here so it
// can move there without changing behaviour).

import '../../core/storage/hive_store.dart';
import 'live_history_store.dart';

/// Hive key for the retention period in days (int, 0 = keep forever).
const String liveHistoryRetentionKey = 'hao_live_hist_retention_days';

/// Retention presets shown in the history page.
enum LiveHistoryRetention {
  forever(0, '永久保留'),
  days7(7, '保留 7 天'),
  days30(30, '保留 30 天'),
  days90(90, '保留 90 天');

  const LiveHistoryRetention(this.days, this.label);

  final int days;
  final String label;

  static LiveHistoryRetention fromDays(int days) {
    for (final r in LiveHistoryRetention.values) {
      if (r.days == days) return r;
    }
    return LiveHistoryRetention.forever;
  }
}

/// Current retention period (days, 0 = forever), default forever.
LiveHistoryRetention liveHistoryRetention() {
  try {
    return LiveHistoryRetention.fromDays(
      HiveStore.getInt(liveHistoryRetentionKey, 0),
    );
  } catch (_) {
    return LiveHistoryRetention.forever;
  }
}

Future<void> setLiveHistoryRetention(LiveHistoryRetention retention) =>
    HiveStore.put(liveHistoryRetentionKey, retention.days);

/// Entries surviving [retentionDays] relative to [now] (pure,
/// unit-testable). 0 / negative = everything survives.
List<LiveHistoryEntry> applyRetention(
  List<LiveHistoryEntry> entries,
  int retentionDays, {
  DateTime? now,
}) {
  if (retentionDays <= 0) return entries;
  final cutoff = (now ?? DateTime.now()).subtract(
    Duration(days: retentionDays),
  );
  final cutoffMs = cutoff.millisecondsSinceEpoch;
  return entries.where((e) => e.at >= cutoffMs).toList();
}

/// How many entries [retentionDays] would delete right now (pure).
int retentionWouldDelete(
  List<LiveHistoryEntry> entries,
  int retentionDays, {
  DateTime? now,
}) {
  if (retentionDays <= 0) return 0;
  return entries.length -
      applyRetention(entries, retentionDays, now: now).length;
}
