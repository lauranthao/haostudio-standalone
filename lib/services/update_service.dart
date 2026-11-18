// Online update service (fix 8).
//
// Fetches version.json from the shop server FIRST (reachable from mainland
// China) and falls back to GitHub raw (blocked/slow there, CDN cache lags
// hours behind a push). Compares semver NUMERICALLY (1.0.10 beats 1.0.9),
// never against a changelog tag or the build number. Automatic check at
// most once per 20 hours; a skipped version is never nagged about again.
//
// Fetch failures are classified (timeout / network / HTTP / parse) instead
// of being swallowed into a single null, so the manual check can show a
// different message per failure kind. See [UpdateFetchError].

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

import '../../app/consts.dart';
import '../core/network/http_client.dart';
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

/// Why a manifest fetch failed. Kept separate so the UI can tell the user
/// what actually happened instead of a generic "check the network".
enum UpdateFetchError {
  /// Connect/receive/send timed out (or the 15 s total cap hit).
  timeout,

  /// Could not reach the server at all (DNS failure, connection refused,
  /// TLS error, offline).
  network,

  /// Server answered with a non-2xx HTTP status ([UpdateService.lastHttpStatus]).
  http,

  /// Response was not a usable manifest (bad JSON, missing version/ipaUrl).
  parse,
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
  UpdateService({Dio? dio}) : _dio = dio ?? sharedDio();

  final Dio _dio;

  static const Duration autoCheckInterval = Duration(hours: 20);

  /// Total wall-clock cap for one fetch (primary + retry + fallback).
  static const Duration fetchTimeout = Duration(seconds: 15);

  /// Kind of the most recent fetch failure, for the manual-check error
  /// message. Null when the last fetch succeeded or none ran yet.
  UpdateFetchError? _lastFetchError;
  UpdateFetchError? get lastFetchError => _lastFetchError;

  /// HTTP status of the most recent fetch failure ([UpdateFetchError.http]).
  int? _lastHttpStatus;
  int? get lastHttpStatus => _lastHttpStatus;

  /// Fetch the remote manifest. Returns (info, error, httpStatus):
  /// on success info is non-null and error is null; on failure info is
  /// null and error says why. Never throws.
  Future<(UpdateInfo?, UpdateFetchError?, int?)> fetchRemote() async {
    try {
      final result = await _fetchWithFallback().timeout(
        fetchTimeout,
        onTimeout: () => (null, UpdateFetchError.timeout, null),
      );
      _lastFetchError = result.$2;
      _lastHttpStatus = result.$3;
      return result;
    } on TimeoutException {
      _lastFetchError = UpdateFetchError.timeout;
      _lastHttpStatus = null;
      return (null, UpdateFetchError.timeout, null);
    }
  }

  /// Primary (shop server) with one retry on transient failures, then
  /// fallback (GitHub raw) once. When both fail, the primary error is
  /// reported — it is the source the user can actually reach.
  Future<(UpdateInfo?, UpdateFetchError?, int?)> _fetchWithFallback() async {
    var last = await _fetchOne(kVersionUrl);
    if (last.$1 != null) return last;
    if (last.$2 == UpdateFetchError.timeout ||
        last.$2 == UpdateFetchError.network) {
      last = await _fetchOne(kVersionUrl);
      if (last.$1 != null) return last;
    }
    final fallback = await _fetchOne(kVersionUrlFallback);
    if (fallback.$1 != null) return fallback;
    return last;
  }

  /// One GET of a manifest URL. Classifies every failure; never throws.
  Future<(UpdateInfo?, UpdateFetchError?, int?)> _fetchOne(String url) async {
    try {
      final res = await _dio.get<Map<String, dynamic>>(
        url,
        options: Options(
          responseType: ResponseType.json,
          // Never throw for HTTP error statuses; inspect statusCode below.
          validateStatus: (_) => true,
        ),
      );
      final status = res.statusCode ?? 0;
      if (status < 200 || status >= 300) {
        return (null, UpdateFetchError.http, status);
      }
      final data = res.data;
      if (data == null) return (null, UpdateFetchError.parse, status);
      final version = data['version']?.toString();
      final ipaUrl = data['ipaUrl']?.toString();
      if (version == null ||
          version.isEmpty ||
          ipaUrl == null ||
          ipaUrl.isEmpty) {
        return (null, UpdateFetchError.parse, status);
      }
      return (
        UpdateInfo(
          version: version,
          build: (data['build'] as num?)?.toInt() ?? 0,
          ipaUrl: ipaUrl,
          size: (data['size'] as num?)?.toInt(),
          changelog: data['changelog']?.toString(),
        ),
        null,
        status,
      );
    } on DioException catch (e) {
      switch (e.type) {
        case DioExceptionType.connectionTimeout:
        case DioExceptionType.receiveTimeout:
        case DioExceptionType.sendTimeout:
        case DioExceptionType.transformTimeout:
          return (null, UpdateFetchError.timeout, null);
        case DioExceptionType.badResponse:
          return (null, UpdateFetchError.http, e.response?.statusCode);
        case DioExceptionType.connectionError:
          return (null, UpdateFetchError.network, null);
        case DioExceptionType.cancel:
        case DioExceptionType.badCertificate:
        case DioExceptionType.unknown:
          // `unknown` wraps SocketException (DNS/connect) and JSON decode
          // errors; tell them apart by the inner error.
          if (e.error is FormatException) {
            return (null, UpdateFetchError.parse, null);
          }
          return (null, UpdateFetchError.network, null);
      }
    } on FormatException {
      return (null, UpdateFetchError.parse, null);
    } catch (_) {
      return (null, UpdateFetchError.network, null);
    }
  }

  /// Manual check (Settings → About → 检查更新). Always reports a result.
  /// Failure detail is exposed via [lastFetchError]/[lastHttpStatus].
  ///
  /// Android v1: disabled — version.json only carries an .ipa
  /// (ipaUrl + minOs 15.0) and the store adds the APK file without
  /// changing version.json, so there is no Android update channel
  /// yet. The Settings row is hidden on Android too, so this is
  /// unreachable there; the guard is the backstop. iOS is unchanged.
  Future<(UpdateCheckResult, UpdateInfo?)> checkManual() async {
    if (Platform.isAndroid) return (UpdateCheckResult.unavailable, null);
    final (info, _, _) = await fetchRemote();
    if (info == null) return (UpdateCheckResult.unavailable, null);
    return (_classify(info), info);
  }

  /// Automatic check. Returns null when it should stay silent (throttled,
  /// up to date, or fetch failed).
  ///
  /// Android v1: disabled, same reason as [checkManual] — the manifest
  /// only describes an iOS build. iOS is unchanged.
  Future<UpdateInfo?> checkAuto() async {
    if (Platform.isAndroid) return null;
    final last = HiveStore.getInt(HiveKeys.lastUpdateCheckAt, 0);
    final now = DateTime.now().millisecondsSinceEpoch;
    if (now - last < autoCheckInterval.inMilliseconds) return null;
    await HiveStore.put(HiveKeys.lastUpdateCheckAt, now);
    final (info, _, _) = await fetchRemote();
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
