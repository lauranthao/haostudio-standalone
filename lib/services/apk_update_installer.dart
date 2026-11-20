// APK self-update installer (Android only).
//
// Downloads the APK from [UpdateInfo.apkUrl] into the app cache
// (`updates/`, covered by the FileProvider paths in
// android/app/src/main/res/xml/file_paths.xml) and fires the system
// installer through the native channel
// (`com.haostudio.standalone/apk_install`, ApkInstallPlugin.kt).
// The system shows its own install prompt and the user confirms
// there; if the app is not yet allowed to install unknown apps, the
// system shows the allow-once settings screen instead.
//
// Best-effort throughout: any failure returns false, never throws,
// and a partial or size-mismatched file is deleted. The iOS path is
// untouched — iOS opens the IPA URL in the browser instead (see
// update_dialog.dart).

import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:path_provider/path_provider.dart';

import 'update_service.dart';

/// MethodChannel name shared with ApkInstallPlugin.kt.
const String apkInstallChannelName = 'com.haostudio.standalone/apk_install';

/// Downloads a URL to a file, reporting progress. Injectable so tests
/// can fake the download without the network.
typedef ApkDownloader = Future<void> Function(
  String url,
  String savePath,
  void Function(int received, int total)? onProgress,
);

Future<void> _dioDownloader(
  Dio dio,
  String url,
  String savePath,
  void Function(int received, int total)? onProgress,
) =>
    dio.download(
      url,
      savePath,
      onReceiveProgress: onProgress,
      deleteOnError: true,
    );

class ApkUpdateInstaller {
  ApkUpdateInstaller({
    Dio? dio,
    MethodChannel? installChannel,
    this._downloader,
    Future<Directory> Function()? tempDir,
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 30),
                receiveTimeout: const Duration(minutes: 30),
              ),
            ),
        _installChannel = installChannel ??
            const MethodChannel(apkInstallChannelName),
        _tempDir = tempDir ?? getTemporaryDirectory;

  final Dio _dio;
  final MethodChannel _installChannel;
  final ApkDownloader? _downloader;
  final Future<Directory> Function() _tempDir;

  /// Download the APK and hand it to the system installer.
  /// Returns true when the installer intent fired; false on any
  /// failure (no URL, download error, size mismatch, install error).
  /// [onProgress] receives 0-1 while downloading.
  Future<bool> downloadAndInstall(
    UpdateInfo info, {
    void Function(double progress)? onProgress,
  }) async {
    final url = info.apkUrl;
    if (url == null || url.isEmpty) return false;
    try {
      final dir = await _tempDir();
      final updatesDir = Directory('${dir.path}/updates');
      await updatesDir.create(recursive: true);
      final targetName =
          'haostudio-update-${info.effectiveVersion}-${info.apkBuild ?? info.build}.apk';
      final file = File('${updatesDir.path}/$targetName');
      // Drop stale downloads from earlier versions so a partial file
      // is never mistaken for the new one.
      await for (final entry in updatesDir.list()) {
        if (entry is File &&
            entry.path != file.path &&
            entry.uri.pathSegments.last.startsWith('haostudio-update-')) {
          await entry.delete().catchError((_) => entry);
        }
      }
      final download = _downloader ??
          (u, p, prog) => _dioDownloader(_dio, u, p, prog);
      await download(url, file.path, (received, total) {
        if (total > 0) {
          onProgress?.call((received / total).clamp(0.0, 1.0));
        }
      });
      if (info.apkSize != null && info.apkSize! > 0) {
        final actual = await file.length();
        if (actual != info.apkSize) {
          await file.delete().catchError((_) => file);
          debugPrint(
            '[HAo] apk download size mismatch: got $actual, want ${info.apkSize}',
          );
          return false;
        }
      }
      onProgress?.call(1.0);
      final ok = await _installChannel.invokeMethod<bool>(
        'installApk',
        <String, Object>{'path': file.path},
      );
      return ok == true;
    } catch (e) {
      debugPrint('[HAo] apk download/install failed: $e');
      return false;
    }
  }
}
