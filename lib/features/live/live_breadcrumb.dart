// Live crash breadcrumb (fix 1).
//
// Written at exactly 8 stages of live entry, in order, persisted durably
// in Hive (not memory) on every write so it survives a crash. Read on
// every app launch. Settings → About shows the stored stage, or "无记录 /
// No record" when empty.
//
// Stages: live-msg, live-present, live-viewDidLoad, live-ijk-ok (keep the
// stage NAME even though the backend is now media_kit), live-prepared,
// live-first-frame, live-playing, live-closed.

import '../../core/storage/hive_store.dart';

class LiveBreadcrumb {
  LiveBreadcrumb._();

  static const List<String> stages = [
    'live-msg',
    'live-present',
    'live-viewDidLoad',
    'live-ijk-ok',
    'live-prepared',
    'live-first-frame',
    'live-playing',
    'live-closed',
  ];

  static String get current =>
      HiveStore.getString(HiveKeys.liveCrashStage, '');

  /// Best-effort crash telemetry: a breadcrumb write must NEVER throw
  /// or block playback — if storage is unavailable the write is dropped
  /// silently and the player carries on.
  static Future<void> write(String stage) async {
    try {
      await HiveStore.put(HiveKeys.liveCrashStage, stage);
    } catch (_) {
      // Dropped breadcrumb; playback continues.
    }
  }

  static Future<void> clear() => HiveStore.delete(HiveKeys.liveCrashStage);
}
