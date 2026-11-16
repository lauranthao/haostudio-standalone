// Offline music downloads (M-P0-5) — real files, not a web-only stub.
//
// Audio files are downloaded with Dio into the app documents directory
// (`music_downloads/`) and the index (song + file name + size) is kept
// in Hive (`musicDownloads`), so download state survives app restarts.
// When a song is downloaded, the player plays the local file instead
// of resolving a remote URL (see MusicPlayerController._loadCurrent).
//
// The Hive index is the source of truth for "which songs are
// downloaded"; entries whose file is gone (deleted outside the app)
// are pruned on read, never shown as phantom downloads.

import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:dio/dio.dart';
import 'package:get/get.dart';
import 'package:path_provider/path_provider.dart';

import '../../core/storage/hive_store.dart';
import 'music_models.dart';
import 'music_quality.dart';
import 'music_resolvers.dart';

enum DownloadStatus { notDownloaded, downloading, downloaded, failed }

/// One downloaded song: the full Song JSON + the absolute local file
/// path. The absolute path is stored (not just the file name) so
/// [MusicDownloadService.localPathFor] is a purely synchronous Hive +
/// File.existsSync lookup — no async directory resolution on the
/// playback hot path. The documents directory is stable per install,
/// and the Hive box lives in the same sandbox, so the two cannot drift
/// apart across reinstalls.
class DownloadedSong {
  DownloadedSong({
    required this.song,
    required this.filePath,
    required this.sizeBytes,
    required this.downloadedAt,
  });

  factory DownloadedSong.fromJson(Map<String, dynamic> j) {
    return DownloadedSong(
      song: Song.fromJson(
        (j['song'] as Map<String, dynamic>? ?? const {}),
      ),
      filePath: j['filePath']?.toString() ?? '',
      sizeBytes: (j['sizeBytes'] as num?)?.toInt() ?? 0,
      downloadedAt: (j['downloadedAt'] as num?)?.toInt() ?? 0,
    );
  }

  Map<String, dynamic> toJson() => {
        'song': song.toJson(),
        'filePath': filePath,
        'sizeBytes': sizeBytes,
        'downloadedAt': downloadedAt,
      };

  /// Identity key, same as Song.identityKey (`platform|songId`).
  String get key => song.identityKey;

  /// File name for display (last path segment).
  String get fileName => filePath.split('/').last;

  final Song song;
  final String filePath;
  final int sizeBytes;
  final int downloadedAt;
}

/// Audio extensions we accept from a resolved URL path.
const Set<String> _kAudioExtensions = {
  'mp3',
  'm4a',
  'flac',
  'wav',
  'ogg',
  'aac',
  'opus',
};

String _extensionFor(String url, String? contentType) {
  final path = Uri.tryParse(url)?.path ?? '';
  final dot = path.lastIndexOf('.');
  if (dot >= 0) {
    final ext = path.substring(dot + 1).toLowerCase();
    if (_kAudioExtensions.contains(ext)) return ext;
  }
  switch ((contentType ?? '').split(';').first.trim().toLowerCase()) {
    case 'audio/mpeg':
    case 'audio/mp3':
      return 'mp3';
    case 'audio/flac':
    case 'audio/x-flac':
      return 'flac';
    case 'audio/mp4':
    case 'audio/x-m4a':
      return 'm4a';
    case 'audio/wav':
    case 'audio/x-wav':
      return 'wav';
    case 'audio/ogg':
      return 'ogg';
    case 'audio/aac':
      return 'aac';
  }
  return 'mp3';
}

class MusicDownloadService {
  MusicDownloadService({
    Dio? dio,
    MusicResolvers? resolvers,
    Directory? directory,
    this.quality = AudioQuality.hires,
  })  : _dio = dio ?? Dio(),
        _resolvers = resolvers ?? MusicResolvers(),
        _directoryOverride = directory;

  final Dio _dio;
  final MusicResolvers _resolvers;
  final Directory? _directoryOverride;
  final AudioQuality quality;

  /// Live per-song status + progress (0..1) for in-flight downloads.
  final RxMap<String, DownloadStatus> status =
      <String, DownloadStatus>{}.obs;
  final RxMap<String, double> progress = <String, double>{}.obs;

  /// Songs with an in-flight or failed download, so the Downloads
  /// page can show them (a failed row keeps its song for retry).
  /// Removed once the download succeeds (the song is then in
  /// [downloaded]) or is deleted.
  final RxMap<String, Song> activeSongs = <String, Song>{}.obs;

  /// Downloaded songs, newest first. Refreshed by [refresh].
  final RxList<DownloadedSong> downloaded = <DownloadedSong>[].obs;

  Future<Directory> get _dir async {
    if (_directoryOverride != null) {
      if (!await _directoryOverride.exists()) {
        await _directoryOverride.create(recursive: true);
      }
      return _directoryOverride;
    }
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/music_downloads');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ---- index (Hive) ------------------------------------------------------

  List<DownloadedSong> _readIndex() {
    final raw = HiveStore.box.get(HiveKeys.musicDownloads) as String?;
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(DownloadedSong.fromJson)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _writeIndex(List<DownloadedSong> entries) =>
      HiveStore.put(
        HiveKeys.musicDownloads,
        jsonEncode(entries.map((e) => e.toJson()).toList()),
      );

  /// Number of downloaded songs (index only, no disk check — used for
  /// the music-home card count).
  int get downloadedCount => _readIndex().length;

  // ---- status --------------------------------------------------------------

  /// Synchronous status for UI rows: live map first, then the index +
  /// a file-existence check.
  DownloadStatus statusFor(Song song) {
    final live = status[song.identityKey];
    if (live != null) return live;
    return localPathFor(song) != null
        ? DownloadStatus.downloaded
        : DownloadStatus.notDownloaded;
  }

  /// Local file path for [song], or null when it is not downloaded.
  /// A stale index entry (file gone) returns null. Purely synchronous
  /// so the player can check it on the playback hot path.
  String? localPathFor(Song song) {
    final entry = _readIndex().where(
      (e) => e.key == song.identityKey,
    );
    if (entry.isEmpty || entry.first.filePath.isEmpty) return null;
    final file = File(entry.first.filePath);
    return file.existsSync() ? file.path : null;
  }

  /// Re-read the index, drop entries whose file is gone, and publish
  /// the surviving list to [downloaded]. Returns the surviving list.
  Future<List<DownloadedSong>> refresh() async {
    final entries = _readIndex();
    final kept = <DownloadedSong>[];
    var pruned = false;
    for (final e in entries) {
      if (e.filePath.isNotEmpty && await File(e.filePath).exists()) {
        kept.add(e);
      } else {
        pruned = true;
      }
    }
    if (pruned) await _writeIndex(kept);
    downloaded.assignAll(kept);
    return kept;
  }

  // ---- download ------------------------------------------------------------

  /// Resolve the play URL at the user's quality and download the song.
  /// Returns true on success. Already-downloaded songs return true
  /// immediately without re-downloading.
  Future<bool> download(Song song) async {
    if (localPathFor(song) != null) {
      status[song.identityKey] = DownloadStatus.downloaded;
      return true;
    }
    final r = await _resolvers.resolvePlayUrl(
      song.songId,
      song.platform,
      quality,
      song.title,
    );
    if (r == null || r.url.isEmpty) {
      status[song.identityKey] = DownloadStatus.failed;
      return false;
    }
    return downloadFromUrl(song, r.url);
  }

  /// Download [song] from an already-resolved [url]. Testable without
  /// the resolver: point [url] at a local server.
  Future<bool> downloadFromUrl(Song song, String url) async {
    final key = song.identityKey;
    if (localPathFor(song) != null) {
      status[key] = DownloadStatus.downloaded;
      return true;
    }
    final dir = await _dir;
    status[key] = DownloadStatus.downloading;
    progress[key] = 0;
    activeSongs[key] = song;
    final safeKey = key.replaceAll(RegExp(r'[^A-Za-z0-9_-]'), '_');
    final tmpFile = File('${dir.path}/.$safeKey.tmp');
    try {
      final response = await _dio.download(
        url,
        tmpFile.path,
        onReceiveProgress: (received, total) {
          if (total > 0) progress[key] = received / total;
        },
      );
      final contentType =
          response.headers.value(Headers.contentTypeHeader);
      final ext = _extensionFor(url, contentType);
      final fileName =
          '${song.platform.code}_${song.songId}.$ext';
      final file = await tmpFile.rename('${dir.path}/$fileName');
      final size = await file.length();
      final entries = _readIndex()
          .where((e) => e.key != key)
          .toList();
      entries.insert(
        0,
        DownloadedSong(
          song: song,
          filePath: file.path,
          sizeBytes: size,
          downloadedAt: DateTime.now().millisecondsSinceEpoch,
        ),
      );
      await _writeIndex(entries);
      downloaded.assignAll(entries);
      status[key] = DownloadStatus.downloaded;
      progress.remove(key);
      activeSongs.remove(key);
      return true;
    } catch (_) {
      status[key] = DownloadStatus.failed;
      progress.remove(key);
      try {
        if (await tmpFile.exists()) await tmpFile.delete();
      } catch (_) {}
      return false;
    }
  }

  /// Delete one downloaded song (file + index entry).
  Future<bool> delete(Song song) async {
    final key = song.identityKey;
    final entries = _readIndex();
    final entry = entries.where((e) => e.key == key);
    if (entry.isEmpty) return false;
    final file = File(entry.first.filePath);
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {}
    final kept = entries.where((e) => e.key != key).toList();
    await _writeIndex(kept);
    downloaded.assignAll(kept);
    status.remove(key);
    progress.remove(key);
    activeSongs.remove(key);
    return true;
  }

  /// Total size of the downloaded files on disk, in bytes.
  Future<int> totalBytes() async {
    var total = 0;
    for (final e in _readIndex()) {
      final file = File(e.filePath);
      try {
        if (await file.exists()) total += await file.length();
      } catch (_) {}
    }
    return total;
  }

  /// Delete every downloaded file + the index. Returns bytes freed.
  Future<int> clearAll() async {
    final freed = await totalBytes();
    for (final e in _readIndex()) {
      try {
        final file = File(e.filePath);
        if (await file.exists()) await file.delete();
      } catch (_) {}
    }
    await _writeIndex(<DownloadedSong>[]);
    downloaded.clear();
    status.clear();
    progress.clear();
    activeSongs.clear();
    return freed;
  }
}
