// Online update service (fix 8).
//
// Fetches version.json from Gitee raw FIRST (hosted in mainland China,
// so the check works from chen's phone) and falls back to the shop
// server (Railway US). Compares semver NUMERICALLY (1.0.10 beats 1.0.9)
// AND the build number: a newer build of the same version IS an
// update (1.1.5+22 beats 1.1.5+21 — the old version-only comparison
// reported "already the latest" for every build bump of 1.1.5, chen
// 2026-11-20). A skipped version is never nagged about again — the
// skip is recorded per version+build, so skipping one build never
// skips the next build of the same version.
//
// Fetch failures are classified (timeout / network / HTTP / parse) instead
// of being swallowed into a single null, so the manual check can show a
// different message per failure kind. See [UpdateFetchError].

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';

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
    this.apkUrl,
    this.apkSize,
    this.apkVersion,
    this.apkBuild,
  });

  final String version;
  final int build;
  final String ipaUrl;
  final int? size;
  final String? changelog;

  /// Android APK release (same manifest, alongside the iOS fields):
  /// the APK file URL, its byte size, and its own version/build.
  /// All null on an iOS-only manifest — Android then reports up to
  /// date instead of offering the iOS link.
  final String? apkUrl;
  final int? apkSize;
  final String? apkVersion;
  final int? apkBuild;

  /// The version string this platform compares against [kAppVersion]:
  /// the APK version on Android, the shared version elsewhere.
  String get effectiveVersion =>
      defaultTargetPlatform == TargetPlatform.android
          ? (apkVersion ?? version)
          : version;

  /// The build this platform compares against [kAppBuild]: the APK
  /// build on Android, the shared build elsewhere.
  int get effectiveBuild =>
      defaultTargetPlatform == TargetPlatform.android
          ? (apkBuild ?? build)
          : build;

  /// The download URL this platform installs from: the APK on
  /// Android, the IPA URL elsewhere. Null on Android when the
  /// manifest carries no APK.
  String? get installUrl =>
      defaultTargetPlatform == TargetPlatform.android ? apkUrl : ipaUrl;

  /// Identity of this release for the skip check: effective version
  /// + build ("1.1.5+24"). Skipping one build must not skip the next
  /// build of the same version, so the skip key carries the build.
  /// On iOS this is the shared version+build; on Android the APK's.
  String get id => '$effectiveVersion+$effectiveBuild';
}

class UpdateService {
  UpdateService({Dio? dio, String? versionUrl, String? fallbackUrl})
      : _dio = dio ?? sharedDio(),
        _versionUrl = versionUrl ?? kVersionUrl,
        _fallbackUrl = fallbackUrl ?? kVersionUrlFallback;

  final Dio _dio;

  /// Manifest URLs (constructor-injectable so tests can point at a
  /// local server; production uses [kVersionUrl]/[kVersionUrlFallback]).
  final String _versionUrl;
  final String _fallbackUrl;

  static const Duration autoCheckInterval = Duration(hours: 20);

  /// Total wall-clock cap for one fetch (primary + retry + fallback).
  /// Two 8 s per-attempt timeouts plus a fallback attempt fit inside
  /// 30 s; the old 15 s cap could kill the retry mid-flight.
  static const Duration fetchTimeout = Duration(seconds: 30);

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

  /// Primary with one retry on transient failures, then fallback once.
  /// When both fail, the primary error is reported — it is the source
  /// the user can actually reach.
  Future<(UpdateInfo?, UpdateFetchError?, int?)> _fetchWithFallback() async {
    var last = await _fetchOne(_versionUrl);
    if (last.$1 != null) return last;
    if (_isTransient(last)) {
      last = await _fetchOne(_versionUrl);
      if (last.$1 != null) return last;
    }
    final fallback = await _fetchOne(_fallbackUrl);
    if (fallback.$1 != null) return fallback;
    return last;
  }

  /// Transient: worth one immediate retry on the same host — timeout,
  /// no route to the host, or a 5xx from a server that is restarting
  /// or shedding load (Railway free tier returns 502 while deploying;
  /// the old code retried only timeout/network, so one 502 failed the
  /// whole check even though the retry would have succeeded).
  bool _isTransient((UpdateInfo?, UpdateFetchError?, int?) r) {
    if (r.$2 == UpdateFetchError.timeout ||
        r.$2 == UpdateFetchError.network) {
      return true;
    }
    if (r.$2 == UpdateFetchError.http) {
      final status = r.$3;
      if (status != null && status >= 500 && status < 600) return true;
    }
    return false;
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
          apkUrl: data['apkUrl']?.toString(),
          apkSize: (data['apkSize'] as num?)?.toInt(),
          apkVersion: data['apkVersion']?.toString(),
          apkBuild: (data['apkBuild'] as num?)?.toInt(),
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
  Future<(UpdateCheckResult, UpdateInfo?)> checkManual() async {
    final (info, _, _) = await fetchRemote();
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
    final (info, _, _) = await fetchRemote();
    if (info == null) return null;
    if (_classify(info) != UpdateCheckResult.newerAvailable) return null;
    return info;
  }

  /// A release is newer when its version is newer, or when the
  /// version is equal (neither side newer, so '1.1.05' equals
  /// '1.1.5') and its build is higher. The old version-only
  /// comparison reported upToDate for every 1.1.5 build bump.
  /// The comparison uses the effective version/build: the APK's on
  /// Android, the shared ones elsewhere.
  bool _isNewer(UpdateInfo info) {
    if (isNewerVersion(info.effectiveVersion, kAppVersion)) return true;
    if (isNewerVersion(kAppVersion, info.effectiveVersion)) return false;
    return info.effectiveBuild > kAppBuild;
  }

  UpdateCheckResult _classify(UpdateInfo info) {
    // Android only offers the update when the manifest carries an APK:
    // an iOS-only manifest (no apkUrl) is not an update, it is "up to
    // date" — never offer the IPA link on Android.
    if (defaultTargetPlatform == TargetPlatform.android &&
        (info.apkUrl == null || info.apkUrl!.isEmpty)) {
      return UpdateCheckResult.upToDate;
    }
    if (!_isNewer(info)) {
      return UpdateCheckResult.upToDate;
    }
    final skipped = HiveStore.getString(HiveKeys.skippedVersion, '');
    if (skipped == info.id) return UpdateCheckResult.skipped;
    return UpdateCheckResult.newerAvailable;
  }

  Future<void> recordKnownUpdate(String version) =>
      HiveStore.put(HiveKeys.knownUpdateVersion, version);

  Future<void> clearKnownUpdate() =>
      HiveStore.delete(HiveKeys.knownUpdateVersion);

  Future<void> skipVersion(String version) =>
      HiveStore.put(HiveKeys.skippedVersion, version);
}
