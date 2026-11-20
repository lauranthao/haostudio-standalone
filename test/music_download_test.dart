// Offline downloads (M-P0-5) — real files on disk.
//
// Covers: downloading an audio file to app storage (Dio + a real
// local HTTP server — no network), the file bytes matching the
// source, the Hive download index surviving a new service instance
// (app restart), play-local lookup (localPathFor), per-song status,
// total size, single delete, clear-all, failed downloads leaving no
// file/index entry, and stale index entries being pruned on refresh.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/services/music/music_downloads.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/music_quality.dart';
import 'package:standalone/services/music/music_resolvers.dart';

final _audioBytes = List<int>.generate(4096, (i) => i % 256);
final _flacBytes = List<int>.generate(2048, (i) => (i * 7) % 256);

Song _song(String id, String title) =>
    Song(songId: id, title: title, artist: 'Singer $id');

void main() {
  late Box<dynamic> box;
  late Directory tmpDir;
  late HttpServer server;
  late int hits;

  setUp(() async {
    Hive.init('test/.hive-dl-test');
    box = await Hive.openBox<dynamic>('dl_test');
    await box.clear();
    HiveStore.setTestBox(box);
    tmpDir = await Directory.systemTemp.createTemp('hao_dl_test_');
    hits = 0;
    server = await HttpServer.bind(InternetAddress.loopbackIPv4, 0);
    server.listen((HttpRequest req) async {
      hits++;
      if (req.uri.path == '/song.mp3') {
        req.response.headers.contentType =
            ContentType('audio', 'mpeg');
        req.response.headers.contentLength = _audioBytes.length;
        req.response.add(_audioBytes);
      } else if (req.uri.path == '/track') {
        // No extension in the URL: the content type decides.
        req.response.headers.contentType =
            ContentType('audio', 'flac');
        req.response.headers.contentLength = _flacBytes.length;
        req.response.add(_flacBytes);
      } else if (req.uri.path == '/stall') {
        // Headers promise 1 MB but the body never arrives: the
        // download must be cancelled by the stall watchdog, not hang
        // forever. The handler must stay alive (never-completing
        // future): dart:io auto-closes the response when the handler
        // returns, which would end the stall immediately.
        req.response.headers.contentType =
            ContentType('audio', 'mpeg');
        req.response.headers.contentLength = 1024 * 1024;
        await req.response.flush();
        await Completer<void>().future;
      } else {
        req.response.statusCode = HttpStatus.notFound;
      }
      await req.response.close();
    });
  });

  tearDown(() async {
    await server.close(force: true);
    await box.close();
    await Hive.deleteBoxFromDisk('dl_test');
    if (await tmpDir.exists()) await tmpDir.delete(recursive: true);
  });

  MusicDownloadService makeService() =>
      MusicDownloadService(dio: Dio(), directory: tmpDir);

  String serverUrl(String path) =>
      'http://${server.address.host}:${server.port}$path';

  group('download + index + play-local', () {
    test('saves the exact audio bytes to disk', () async {
      final svc = makeService();
      final song = _song('1', 'A');
      expect(await svc.downloadFromUrl(song, serverUrl('/song.mp3')), isTrue);
      final path = svc.localPathFor(song);
      expect(path, isNotNull);
      expect(await File(path!).readAsBytes(), _audioBytes);
      expect(path, endsWith('.mp3'));
    });

    test('download state survives a new service instance (restart)',
        () async {
      final song = _song('1', 'A');
      expect(await makeService().downloadFromUrl(song, serverUrl('/song.mp3')),
          isTrue);
      // A fresh instance over the same Hive box + directory sees it.
      final svc2 = makeService();
      final entries = await svc2.refresh();
      expect(entries.length, 1);
      expect(entries.first.song.identityKey, song.identityKey);
      expect(svc2.localPathFor(song), isNotNull);
      expect(svc2.statusFor(song), DownloadStatus.downloaded);
      expect(svc2.downloadedCount, 1);
    });

    test('extension comes from the content type when the URL has none',
        () async {
      final svc = makeService();
      final song = _song('2', 'B');
      expect(await svc.downloadFromUrl(song, serverUrl('/track')), isTrue);
      expect(svc.localPathFor(song), endsWith('.flac'));
      expect(
        await File(svc.localPathFor(song)!).readAsBytes(),
        _flacBytes,
      );
    });

    test('re-downloading an existing song does not hit the server again',
        () async {
      final svc = makeService();
      final song = _song('1', 'A');
      expect(await svc.downloadFromUrl(song, serverUrl('/song.mp3')), isTrue);
      expect(hits, 1);
      expect(await svc.downloadFromUrl(song, serverUrl('/song.mp3')), isTrue);
      expect(hits, 1);
    });

    test('totalBytes sums the downloaded files', () async {
      final svc = makeService();
      expect(await svc.totalBytes(), 0);
      await svc.downloadFromUrl(_song('1', 'A'), serverUrl('/song.mp3'));
      await svc.downloadFromUrl(_song('2', 'B'), serverUrl('/track'));
      expect(
        await svc.totalBytes(),
        _audioBytes.length + _flacBytes.length,
      );
    });
  });

  group('status', () {
    test('not downloaded before, downloaded after', () async {
      final svc = makeService();
      final song = _song('1', 'A');
      expect(svc.statusFor(song), DownloadStatus.notDownloaded);
      expect(svc.localPathFor(song), isNull);
      await svc.downloadFromUrl(song, serverUrl('/song.mp3'));
      expect(svc.statusFor(song), DownloadStatus.downloaded);
    });

    test('failed download leaves no file and no index entry', () async {
      final svc = makeService();
      final song = _song('404', 'Missing');
      expect(await svc.downloadFromUrl(song, serverUrl('/nope')), isFalse);
      expect(svc.statusFor(song), DownloadStatus.failed);
      expect(svc.localPathFor(song), isNull);
      expect(await svc.refresh(), isEmpty);
      expect(tmpDir.listSync(), isEmpty);
    });

    test('stale index entries (file gone) are pruned on refresh',
        () async {
      final svc = makeService();
      final song = _song('1', 'A');
      await svc.downloadFromUrl(song, serverUrl('/song.mp3'));
      expect(svc.downloadedCount, 1);
      // Delete the file behind the service's back.
      await File(svc.localPathFor(song)!).delete();
      expect(svc.localPathFor(song), isNull);
      expect(await svc.refresh(), isEmpty);
      expect(svc.downloadedCount, 0);
    });
  });

  group('delete + clear', () {    test('delete removes one file + its index entry', () async {
      final svc = makeService();
      final a = _song('1', 'A');
      final b = _song('2', 'B');
      await svc.downloadFromUrl(a, serverUrl('/song.mp3'));
      await svc.downloadFromUrl(b, serverUrl('/track'));
      final pathA = svc.localPathFor(a)!;
      expect(await svc.delete(a), isTrue);
      expect(await File(pathA).exists(), isFalse);
      expect(svc.localPathFor(a), isNull);
      expect(svc.localPathFor(b), isNotNull);
      expect(svc.downloadedCount, 1);
      expect(await svc.delete(a), isFalse);
    });

    test('clearAll frees the bytes and empties the index', () async {
      final svc = makeService();
      await svc.downloadFromUrl(_song('1', 'A'), serverUrl('/song.mp3'));
      await svc.downloadFromUrl(_song('2', 'B'), serverUrl('/track'));
      final freed = await svc.clearAll();
      expect(freed, _audioBytes.length + _flacBytes.length);
      expect(svc.downloadedCount, 0);
      expect(await svc.totalBytes(), 0);
      expect(tmpDir.listSync(), isEmpty);
      expect(svc.statusFor(_song('1', 'A')), DownloadStatus.notDownloaded);
    });
  });

  group('concurrency + timeouts (audit 2026-11-17)', () {
    test('concurrent downloads of the same song share one download',
        () async {
      final svc = makeService();
      final song = _song('1', 'A');
      final results = await Future.wait([
        svc.downloadFromUrl(song, serverUrl('/song.mp3')),
        svc.downloadFromUrl(song, serverUrl('/song.mp3')),
      ]);
      expect(results, [true, true]);
      // One server hit: the second caller shared the first download
      // instead of writing the same tmp file twice (corrupt bytes).
      expect(hits, 1);
      expect(await File(svc.localPathFor(song)!).readAsBytes(), _audioBytes);
    });

    test('a stalled download fails via the watchdog instead of hanging',
        () async {
      final svc = MusicDownloadService(
        dio: Dio(),
        directory: tmpDir,
        stallTimeout: const Duration(milliseconds: 600),
        stallCheckInterval: const Duration(milliseconds: 100),
      );
      final song = _song('9', 'Stalled');
      final sw = Stopwatch()..start();
      expect(await svc.downloadFromUrl(song, serverUrl('/stall')), isFalse);
      sw.stop();
      // It waited out the stall window (watchdog fired) instead of
      // failing instantly — and finished in ~1 s instead of hanging.
      expect(sw.elapsedMilliseconds, greaterThanOrEqualTo(600));
      expect(sw.elapsedMilliseconds, lessThan(5000));
      expect(svc.statusFor(song), DownloadStatus.failed);
      expect(svc.localPathFor(song), isNull);
      expect(tmpDir.listSync(), isEmpty);
    });

    test('a throwing resolver is a failed download, not a crash',
        () async {
      final svc = MusicDownloadService(
        dio: Dio(),
        directory: tmpDir,
        resolvers: _ThrowingResolvers(),
      );
      final song = _song('1', 'A');
      expect(await svc.download(song), isFalse);
      expect(svc.statusFor(song), DownloadStatus.failed);
    });
  });
}

/// Resolver double whose resolvePlayUrl always throws, to prove
/// [MusicDownloadService.download] converts it into a failed
/// download instead of letting the exception escape to the tap
/// handler (neither call site catches).
class _ThrowingResolvers extends MusicResolvers {
  @override
  Future<PlayUrlResult?> resolvePlayUrl(
    String songId,
    MusicPlatform platform,
    AudioQuality quality,
    String title, {
    Set<String> excludeJobs = const <String>{},
    String artist = '',
  }) async {
    throw StateError('boom');
  }
}
