// ignore_for_file: prefer_initializing_formals
// Live recording to local storage + recording center — item 13
// (build 29, I group).
//
// Nothing in the player kernels records: there is no record API on
// any of the three backends (see live_pip_support.dart — same
// situation as PiP, the kernels expose no capture path). So the
// recorder captures the STREAM itself, in the live domain, with Dio:
//
// - FLV / HTTP-FLV: the response body is copied byte-for-byte to a
//   `.flv` file. No re-encode, no remux — what the CDN sent is what
//   lands on disk.
// - HLS (.m3u8): the playlist is fetched, its segments downloaded in
//   order and appended to a `.ts` file; for a live (sliding-window)
//   playlist the loop re-fetches the playlist and downloads only
//   segments it has not seen yet, until stopped.
//
// Recording is local-only (app documents `live_recordings/`), no
// server, no upload. The recording center lists the files (name /
// size / date), deletes them, and shares them (share_plus — the
// sheet calls Share.shareXFiles; the store itself stays UI-free).
//
// Limits, stated plainly: a recording is only as good as the
// stream — if the room stalls, the file stalls with it; HLS live
// recording starts from the playlist's current window (earlier
// segments are already gone from the CDN); stopping mid-segment
// drops that segment.

import 'dart:async';
import 'dart:io';

import 'package:dio/dio.dart';

/// One recorded file on disk.
class LiveRecording {
  const LiveRecording({
    required this.file,
    required this.size,
    required this.created,
  });

  final File file;
  final int size;
  final DateTime created;

  String get name => file.path.split('/').last;
}

/// Parse one m3u8 playlist body into segment URLs (resolved
/// against [baseUri]) + the variant-playlist URL when this is a
/// master playlist. Pure, unit-testable.
class ParsedM3u8 {
  const ParsedM3u8({
    required this.segments,
    required this.targetDuration,
    this.variantUrl,
  });

  /// Media segments, in playlist order.
  final List<Uri> segments;

  /// #EXT-X-TARGETDURATION in seconds (0 when absent).
  final int targetDuration;

  /// Master playlist only: the first variant's URL (highest
  /// bandwidth when the playlist carries BANDWIDTH tags, else the
  /// first listed).
  final Uri? variantUrl;
}

ParsedM3u8 parseM3u8(String body, Uri baseUri) {
  final lines = body.split('\n').map((l) => l.trim()).toList();
  final segments = <Uri>[];
  var targetDuration = 0;
  Uri? bestVariant;
  var bestBandwidth = -1;
  // The URI line after #EXT-X-STREAM-INF is a variant, not a segment.
  var afterStreamInf = false;
  var pendingBandwidth = -1;
  for (final line in lines) {
    if (line.startsWith('#EXT-X-TARGETDURATION:')) {
      targetDuration = int.tryParse(line.split(':').last.trim()) ?? 0;
      afterStreamInf = false;
    } else if (line.startsWith('#EXT-X-STREAM-INF:')) {
      final m = RegExp(r'BANDWIDTH=(\d+)').firstMatch(line);
      pendingBandwidth = m == null
          ? -1
          : int.tryParse(m.group(1)!) ?? -1;
      afterStreamInf = true;
    } else if (line.isEmpty || line.startsWith('#')) {
      continue;
    } else {
      final uri = baseUri.resolve(line);
      if (afterStreamInf) {
        // Variant line: keep the highest-bandwidth one (first listed
        // when no BANDWIDTH tags exist).
        if (bestVariant == null || pendingBandwidth > bestBandwidth) {
          bestVariant = uri;
          bestBandwidth = pendingBandwidth;
        }
        afterStreamInf = false;
        pendingBandwidth = -1;
      } else {
        segments.add(uri);
      }
    }
  }
  // A master playlist has variants and NO segments.
  if (bestVariant != null) {
    return ParsedM3u8(
      segments: const [],
      targetDuration: targetDuration,
      variantUrl: bestVariant,
    );
  }
  return ParsedM3u8(segments: segments, targetDuration: targetDuration);
}

/// File-safe recording name: `{platform}_{roomId}_{yyyyMMdd_HHmmss}`
/// with anything outside [A-Za-z0-9_-] replaced by `_`.
String recordingFileName(
  String platform,
  String roomId,
  DateTime at,
  String ext,
) {
  String clean(String s) =>
      s.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
  String two(int n) => n.toString().padLeft(2, '0');
  final stamp =
      '${at.year}${two(at.month)}${two(at.day)}_${two(at.hour)}${two(at.minute)}${two(at.second)}';
  return '${clean(platform)}_${clean(roomId)}_$stamp.$ext';
}

/// One recording session. Start with [start]; [stop] ends it and
/// returns the finished file (or null when nothing was written).
/// [onBytes] reports progress (bytes written so far).
class LiveRecorder {
  LiveRecorder({
    required Dio dio,
    required Directory directory,
  }) : _dio = dio,
       _directory = directory;

  final Dio _dio;
  final Directory _directory;

  bool get isRecording => _running;
  int get bytesWritten => _bytesWritten;

  bool _running = false;
  int _bytesWritten = 0;
  CancelToken? _cancel;
  Future<void>? _task;
  File? _file;

  /// Start recording [streamUrl] (FLV or HLS) for [platform]/[roomId].
  /// Returns the target file immediately; the download runs in the
  /// background until [stop]. Throws when the directory cannot be
  /// created or the stream cannot be opened.
  Future<File> start({
    required String streamUrl,
    required String platform,
    required String roomId,
    Map<String, String> headers = const {},
    void Function(int bytes)? onBytes,
  }) async {
    if (_running) throw StateError('already recording');
    await _directory.create(recursive: true);
    final isHls = streamUrl.toLowerCase().split('?').first.endsWith(
      '.m3u8',
    );
    final ext = isHls ? 'ts' : 'flv';
    final file = File(
      '${_directory.path}/${recordingFileName(platform, roomId, DateTime.now(), ext)}',
    );
    final sink = file.openWrite();
    _file = file;
    _cancel = CancelToken();
    _running = true;
    _bytesWritten = 0;
    if (isHls) {
      _task = _recordHls(
        streamUrl,
        headers,
        sink,
        onBytes,
      ).whenComplete(() async {
        await sink.close();
        _running = false;
      });
    } else {
      _task = _recordFlv(
        streamUrl,
        headers,
        sink,
        onBytes,
      ).whenComplete(() async {
        await sink.close();
        _running = false;
      });
    }
    return file;
  }

  Future<void> _recordFlv(
    String url,
    Map<String, String> headers,
    IOSink sink,
    void Function(int)? onBytes,
  ) async {
    try {
      final response = await _dio.get<ResponseBody>(
        url,
        options: Options(
          responseType: ResponseType.stream,
          headers: headers,
        ),
        cancelToken: _cancel,
      );
      await for (final chunk in response.data!.stream) {
        if (!_running) break;
        sink.add(chunk);
        _bytesWritten += chunk.length;
        onBytes?.call(_bytesWritten);
      }
    } catch (_) {
      // A stall / disconnect ends the file, not the app: the bytes
      // written so far stay playable up to the cut.
    }
  }

  Future<void> _recordHls(
    String playlistUrl,
    Map<String, String> headers,
    IOSink sink,
    void Function(int)? onBytes,
  ) async {
    final seen = <Uri>{};
    var playlistUri = Uri.parse(playlistUrl);
    while (_running) {
      ParsedM3u8 parsed;
      try {
        final response = await _dio
            .get<String>(
              playlistUri.toString(),
              options: Options(headers: headers),
              cancelToken: _cancel,
            )
            .timeout(const Duration(seconds: 15));
        parsed = parseM3u8(response.data ?? '', playlistUri);
      } catch (_) {
        break;
      }
      // Master playlist: follow the best variant once, then loop on it.
      if (parsed.variantUrl != null) {
        playlistUri = parsed.variantUrl!;
        continue;
      }
      var wroteAny = false;
      for (final segment in parsed.segments) {
        if (!_running) break;
        if (!seen.add(segment)) continue;
        try {
          final response = await _dio
              .get<List<int>>(
                segment.toString(),
                options: Options(
                  responseType: ResponseType.bytes,
                  headers: headers,
                ),
                cancelToken: _cancel,
              )
              .timeout(const Duration(seconds: 20));
          final bytes = response.data;
          if (bytes != null && bytes.isNotEmpty) {
            sink.add(bytes);
            _bytesWritten += bytes.length;
            onBytes?.call(_bytesWritten);
            wroteAny = true;
          }
        } catch (_) {
          // One bad segment is skipped, not fatal.
        }
      }
      // Live playlist: wait ~one target duration, then re-fetch for
      // new segments. A VOD playlist (no new segments twice) ends.
      final wait = parsed.targetDuration > 0
          ? parsed.targetDuration
          : 4;
      if (!wroteAny && seen.isNotEmpty) break;
      await Future<void>.delayed(Duration(seconds: wait));
    }
  }

  /// Stop and return the finished file (null when nothing was
  /// written or no recording was running).
  Future<File?> stop() async {
    if (!_running && _task == null) return null;
    _running = false;
    _cancel?.cancel();
    try {
      await _task?.timeout(const Duration(seconds: 5));
    } catch (_) {}
    _task = null;
    final file = _file;
    _file = null;
    if (file != null && await file.exists()) {
      if (await file.length() == 0) {
        await file.delete();
        return null;
      }
      return file;
    }
    return null;
  }
}

/// The recording center's file listing for [directory] (newest
/// first). Pure dart:io — no platform channels, so unit tests pass a
/// temp dir directly.
Future<List<LiveRecording>> listRecordings(Directory directory) async {
  if (!await directory.exists()) return const [];
  final out = <LiveRecording>[];
  await for (final entity in directory.list()) {
    if (entity is! File) continue;
    final stat = await entity.stat();
    out.add(
      LiveRecording(file: entity, size: stat.size, created: stat.modified),
    );
  }
  out.sort((a, b) => b.created.compareTo(a.created));
  return out;
}
