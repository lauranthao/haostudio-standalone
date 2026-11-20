// APK self-update installer tests (Android only).
//
// The installer downloads the APK to the app cache and fires the
// system installer through the native channel. No network, no real
// install: the download is a fake that writes bytes, the install
// channel is mocked, the temp dir is injected.

import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/apk_update_installer.dart';
import 'package:standalone/services/update_service.dart';

const _apkInfo = UpdateInfo(
  version: '1.1.5',
  build: 19,
  ipaUrl: 'https://example.com/HAoStudio-standalone-v1.1.5.ipa',
  apkUrl: 'https://example.com/HAoStudio-standalone-v1.1.5.apk',
  apkSize: 12, // fake downloader writes utf8('fake-apk-123') = 12 bytes
  apkVersion: '1.1.5',
  apkBuild: 19,
);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  late Directory testDir;
  late List<String> installedPaths;
  late List<String> downloadedUrls;

  setUp(() async {
    testDir = await Directory.systemTemp.createTemp('hao-apk-installer-');
    installedPaths = [];
    downloadedUrls = [];
    const channel = MethodChannel(apkInstallChannelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'installApk') {
        installedPaths.add((call.arguments as Map)['path'] as String);
        return true;
      }
      return null;
    });
  });

  tearDown(() async {
    const channel = MethodChannel(apkInstallChannelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, null);
    await testDir.delete(recursive: true);
  });

  Future<void> fakeDownloader(
    String url,
    String savePath,
    void Function(int received, int total)? onProgress,
  ) async {
    downloadedUrls.add(url);
    final bytes = utf8.encode('fake-apk-123');
    await File(savePath).writeAsBytes(bytes);
    onProgress?.call(bytes.length ~/ 2, bytes.length);
    onProgress?.call(bytes.length, bytes.length);
  }

  ApkUpdateInstaller installer() => ApkUpdateInstaller(
        downloader: fakeDownloader,
        tempDir: () async => testDir,
      );

  test('downloads the APK, reports progress, fires the installer', () async {
    final seen = <double>[];
    final ok = await installer().downloadAndInstall(
      _apkInfo,
      onProgress: seen.add,
    );
    expect(ok, isTrue);
    expect(downloadedUrls, ['https://example.com/HAoStudio-standalone-v1.1.5.apk']);
    expect(installedPaths, hasLength(1));
    expect(seen.first, lessThan(1.0));
    expect(seen.last, 1.0);
    final file = File(installedPaths.single);
    expect(await file.exists(), isTrue);
    expect(file.path, contains('haostudio-update-1.1.5-19.apk'));
    expect(file.path, contains('updates'));
  });

  test('size mismatch deletes the file and returns false', () async {
    final wrong = UpdateInfo(
      version: '1.1.5',
      build: 19,
      ipaUrl: _apkInfo.ipaUrl,
      apkUrl: _apkInfo.apkUrl,
      apkSize: 999,
      apkVersion: '1.1.5',
      apkBuild: 19,
    );
    final ok = await installer().downloadAndInstall(wrong);
    expect(ok, isFalse);
    expect(installedPaths, isEmpty);
    final updates = Directory('${testDir.path}/updates');
    expect(await updates.exists(), isTrue);
    expect(await updates.list().toList(), isEmpty);
  });

  test('no apkUrl: no download, no install, false', () async {
    const iosOnly = UpdateInfo(
      version: '1.1.5',
      build: 19,
      ipaUrl: 'https://example.com/HAoStudio-standalone-v1.1.5.ipa',
    );
    final ok = await installer().downloadAndInstall(iosOnly);
    expect(ok, isFalse);
    expect(downloadedUrls, isEmpty);
    expect(installedPaths, isEmpty);
  });

  test('download throws: false, no install', () async {
    final throwing = ApkUpdateInstaller(
      downloader: (_, _, _) async => throw const SocketException('offline'),
      tempDir: () async => testDir,
    );
    final ok = await throwing.downloadAndInstall(_apkInfo);
    expect(ok, isFalse);
    expect(installedPaths, isEmpty);
  });

  test('installer channel returns false: false', () async {
    const channel = MethodChannel(apkInstallChannelName);
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async => false);
    final ok = await installer().downloadAndInstall(_apkInfo);
    expect(ok, isFalse);
    // The APK was still downloaded; only the install step refused.
    expect(downloadedUrls, hasLength(1));
  });
}
