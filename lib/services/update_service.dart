// Online update service (fix 8).
//
// Fetches version.json from GitHub raw (NOT Gitee), compares semver
// NUMERICALLY (1.0.10 beats 1.0.9), never against a changelog tag or the
// build number. Automatic check at most once per 20 hours; a skipped
// version is never nagged about again.

import 'package:dio/dio.dart';

import '../../app/consts.dart';
import '../core/storage/hive_store.dart';

enum UpdateCheckResult {
  /// A newer version is available and was not skipped.
  newerAvailable,

  /// The user skipped exactly this version.
  skipped,

  /// Already on the newest version.
  upToDate,

  /// Fetch failed (non-silent in manual check, silent in auto check).
  unavailable,
}

class UpdateInfo {
  const UpdateInfo({
    required this.version,
    required this.build,
    required this.ipaUrl,
    this.size,
    this.changelog,
  });

  final String version;
  final int build;
  final String ipaUrl;
  final int? size;
  final String? changelog;
}

class UpdateService {
  UpdateService({Dio? dio}) : _dio = dio ?? Dio();

  final Dio _dio;

  static const Duration autoCheckInterval = Duration(hours: 20);
  static const Duration fetchTimeout = Duration(seconds: 8);

  /// Fetch the remote manifest. Returns null on any failure (never throws).
  Future<UpdateInfo?> fetchRemote() async {
    try {
      final res = await _dio
          .get<Map<String, dynamic>>(
            kVersionUrl,
            options: Options(responseType: ResponseType.json),
          )
          .timeout(fetchTimeout);
      final data = res.data;
      if (data == null) return null;
      final version = data['version']?.toString();
      final ipaUrl = data['ipaUrl']?.toString();
      if (version == null || ipaUrl == null) return null;
      return UpdateInfo(
        version: version,
        build: (data['build'] as num?)?.toInt() ?? 0,
        ipaUrl: ipaUrl,
        size: (data['size'] as num?)?.toInt(),
        changelog: data['changelog']?.toString(),
      );
    } catch (_) {
      return null;
    }
  }

  /// Manual check (Settings → About → 检查更新). Always reports a result.
  Future<(UpdateCheckResult, UpdateInfo?)> checkManual() async {
    final info = await fetchRemote();
    if (info == null) return (UpdateCheckResult.unavailable, null);
    return (_classify(info), info);
  }

  /// Automatic check. Returns null when it should stay silent (throttled,
  /// up to date, or fetch failed).
  Future<UpdateInfo?> checkAuto() async {
    final last = HiveStore.getInt(HiveKeys.lastUpdateCheckAt, 0);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < autoCheckInterval.inMilliseconds) return null;
    await HiveStore.put(HiveKeys.lastUpdateCheckAt, now);
    final info = await fetchRemote();
    if (info == null) return null;
    if (_classify(info) != UpdateCheckResult.newerAvailable) return null;
    return info;
  }

  UpdateCheckResult _classify(UpdateInfo info) {
    if (!isNewerVersion(info.version, kAppVersion)) {
      return UpdateCheckResult.upToDate;
    }
    final skipped = HiveStore.getString(HiveKeys.skippedVersion, '');
    if (skipped == info.version) return UpdateCheckResult.skipped;
    return UpdateCheckResult.newerAvailable;
  }

  Future<void> recordKnownUpdate(String version) =>
      HiveStore.put(HiveKeys.knownUpdateVersion, version);

  Future<void> clearKnownUpdate() =>
      HiveStore.delete(HiveKeys.knownUpdateVersion);

  Future<void> skipVersion(String version) =>
      HiveStore.put(HiveKeys.skippedVersion, version);
}
