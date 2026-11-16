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

  static Future<void> write(String stage) =>
      HiveStore.put(HiveKeys.liveCrashStage, stage);

  static Future<void> clear() => HiveStore.delete(HiveKeys.liveCrashStage);
}
