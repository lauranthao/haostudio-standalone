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

import '../../core/storage/hive_store.dart';
import '../../core/storage/local_paths.dart';
import 'music_models.dart';
import 'music_quality.dart';
import 'music_resolvers.dart';
import 'music_store.dart';

/// Subdirectory under Documents holding the downloaded files.
const String kMusicDownloadsSubdir = 'music_downloads';

enum DownloadStatus { notDownloaded, downloading, downloaded, failed }

/// One downloaded song: the full Song JSON + the local file name.
/// [filePath] is a RELATIVE name (`music_downloads/<file>`), never an
/// absolute path: iOS changes the app container UUID on every
/// (re)install, so an absolute path stored in Hive dies with the old
/// container — and the old code then pruned the index entry itself
/// (1.1.0 -> 1.1.1 upgrade lost every download, chen 2026-11-18).
/// The absolute path is rebuilt from the CURRENT Documents directory
/// on every read ([LocalPaths]); old absolute entries are repaired
/// in place by [MusicDownloadService.refresh], and the directory is
/// rescanned before anything is pruned.
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
    this.stallTimeout = const Duration(seconds: 30),
    this.stallCheckInterval = const Duration(seconds: 5),
  })  : _dio = dio ??
            Dio(
              BaseOptions(
                connectTimeout: const Duration(seconds: 15),
              ),
            ),
        _resolvers = resolvers ?? MusicResolvers(),
        _directoryOverride = directory;

  final Dio _dio;
  final MusicResolvers _resolvers;
  final Directory? _directoryOverride;
  final AudioQuality quality;

  /// A download whose server stops sending bytes for [stallTimeout]
  /// is cancelled instead of hanging forever. Dio 5's receiveTimeout
  /// only guards the response HEADERS (request.close()); the body
  /// stream in Dio's download() has no timeout at all, so without
  /// this watchdog a mid-body stall left the UI on "下载中…" with no
  /// retry path. Tests pass short values to keep the suite fast.
  final Duration stallTimeout;
  final Duration stallCheckInterval;

  /// In-flight downloads by song key. Two taps on 下载 for the same
  /// song used to start two Dio downloads writing the SAME tmp file
  /// (`.$safeKey.tmp`) — the bytes interleaved and the result was a
  /// corrupt file. The second caller now shares the first download's
  /// future instead of starting a second one.
  final Map<String, Future<bool>> _inFlight = {};

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
    final basePath = await LocalPaths.ensureDocumentsPath();
    final dir = Directory('$basePath/$kMusicDownloadsSubdir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  // ---- index (Hive) ------------------------------------------------------

  /// Parsed index, cached in memory. [_readIndex] is called on the
  /// playback hot path ([localPathFor]) and per row ([statusFor]) and
  /// from [downloadedCount] on every music-home build; a full JSON
  /// decode of the whole index per call is pure waste — the index
  /// only ever changes through [_writeIndex] below, which refreshes
  /// this cache. Callers get a copy, so nobody can mutate the cache.
  List<DownloadedSong>? _indexCache;

  List<DownloadedSong> _readIndex() {
    final cached = _indexCache;
    if (cached != null) return List.of(cached);
    final raw = HiveStore.box.get(HiveKeys.musicDownloads) as String?;
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        final parsed = decoded
            .whereType<Map<String, dynamic>>()
            .map(DownloadedSong.fromJson)
            .toList();
        _indexCache = parsed;
        return List.of(parsed);
      }
    } catch (_) {}
    return [];
  }

  Future<void> _writeIndex(List<DownloadedSong> entries) async {
    await HiveStore.put(
      HiveKeys.musicDownloads,
      jsonEncode(entries.map((e) => e.toJson()).toList()),
    );
    // Only cache after the write succeeded — a failed put must not
    // leave the cache claiming entries Hive does not have.
    _indexCache = List.of(entries);
  }

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

  /// Resolve a stored file value to an existing absolute path:
  /// the stored value as-is when it is absolute and still valid,
  /// else `<current Documents>/music_downloads/<basename>`.
  /// Synchronous so the playback hot path stays synchronous; the
  /// Documents cache is warmed at startup (main.dart) and every
  /// [_dir] call, and tests pass a directory override.
  String? _resolveStored(String stored) => LocalPaths.resolveSync(
    stored,
    kMusicDownloadsSubdir,
    directoryOverride: _directoryOverride,
  );

  /// Local file path for [song], or null when it is not downloaded.
  /// A stale index entry (file gone) returns null. Purely synchronous
  /// so the player can check it on the playback hot path.
  String? localPathFor(Song song) {
    final entry = _readIndex().where(
      (e) => e.key == song.identityKey,
    );
    if (entry.isEmpty || entry.first.filePath.isEmpty) return null;
    return _resolveStored(entry.first.filePath);
  }

  /// Rebuild an index entry for a file found on disk with no index
  /// entry (its index was destroyed by the 1.1.1 prune). The file
  /// name carries the identity (`<platform>_<songId>.<ext>`); the
  /// title/artist are recovered from the recent list / play queue
  /// when the song is still there, and fall back to the song id —
  /// never invented. Returns null when the name does not parse.
  DownloadedSong? _rebuildFromFile(File file) {
    final name = file.path.split('/').last;
    final dot = name.lastIndexOf('.');
    if (dot <= 0) return null;
    final ext = name.substring(dot + 1).toLowerCase();
    if (!_kAudioExtensions.contains(ext)) return null;
    final stem = name.substring(0, dot);
    final us = stem.indexOf('_');
    if (us <= 0) return null;
    final code = stem.substring(0, us);
    final songId = stem.substring(us + 1);
    if (songId.isEmpty) return null;
    MusicPlatform? platform;
    for (final p in MusicPlatform.values) {
      if (p.code == code) {
        platform = p;
        break;
      }
    }
    if (platform == null) return null;
    final key = '${platform.code}|$songId';
    var song = _recoverSong(key);
    song ??= Song(songId: songId, title: songId, platform: platform);
    var size = 0;
    var modified = 0;
    try {
      size = file.lengthSync();
      modified = file.statSync().modified.millisecondsSinceEpoch;
    } catch (_) {}
    return DownloadedSong(
      song: song,
      filePath: LocalPaths.storedName(kMusicDownloadsSubdir, name),
      sizeBytes: size,
      downloadedAt: modified,
    );
  }

  /// A song the user has played / queued, by identity key — used to
  /// restore the title of a rescan-rebuilt download. Null when the
  /// song is nowhere on record (the caller then falls back to the
  /// song id as the title).
  Song? _recoverSong(String key) {
    try {
      for (final s in MusicStore.getRecent()) {
        if (s.identityKey == key) return s;
      }
      for (final s in MusicStore.getQueue().songs) {
        if (s.identityKey == key) return s;
      }
    } catch (_) {}
    return null;
  }

  /// Re-read the index, repair old absolute entries to the relative
  /// form, rescan the directory for files with no index entry, and
  /// publish the surviving list to [downloaded]. Returns the
  /// surviving list.
  ///
  /// Repair + rescan run BEFORE any pruning: an entry is dropped
  /// only when its file is missing in all three places (stored path,
  /// current-dir basename, directory rescan).
  Future<List<DownloadedSong>> refresh() async {
    final dir = await _dir;
    final entries = _readIndex();
    final kept = <DownloadedSong>[];
    final seenNames = <String>{};
    var changed = false;
    for (final e in entries) {
      if (e.filePath.isEmpty) continue;
      final resolved = _resolveStored(e.filePath);
      if (resolved == null) continue;
      final stored = LocalPaths.storedName(
        kMusicDownloadsSubdir,
        LocalPaths.baseName(e.filePath),
      );
      final fixed = e.filePath == stored
          ? e
          : DownloadedSong(
              song: e.song,
              filePath: stored,
              sizeBytes: e.sizeBytes,
              downloadedAt: e.downloadedAt,
            );
      if (fixed.filePath != e.filePath) changed = true;
      kept.add(fixed);
      seenNames.add(LocalPaths.baseName(e.filePath));
    }
    // Rescan the directory: re-add audio files with no index entry
    // (in-flight `.$safeKey.tmp` files are skipped — they are not
    // downloads yet).
    final rescanned = <DownloadedSong>[];
    try {
      final files = <File>[];
      for (final entity in dir.listSync()) {
        if (entity is! File) continue;
        final name = entity.path.split('/').last;
        if (name.startsWith('.')) continue;
        if (seenNames.contains(name)) continue;
        files.add(entity);
      }
      files.sort((a, b) {
        DateTime ma;
        DateTime mb;
        try {
          ma = a.statSync().modified;
        } catch (_) {
          ma = DateTime.fromMillisecondsSinceEpoch(0);
        }
        try {
          mb = b.statSync().modified;
        } catch (_) {
          mb = DateTime.fromMillisecondsSinceEpoch(0);
        }
        return mb.compareTo(ma);
      });
      for (final f in files) {
        final rebuilt = _rebuildFromFile(f);
        if (rebuilt == null) continue;
        rescanned.add(rebuilt);
        seenNames.add(f.path.split('/').last);
      }
    } catch (_) {
      // A directory that cannot be listed rescans to nothing — the
      // index entries above still stand on their own.
    }
    if (rescanned.isNotEmpty) {
      kept.insertAll(0, rescanned);
      changed = true;
    }
    if (changed || kept.length != entries.length) {
      await _writeIndex(kept);
    }
    downloaded.assignAll(kept);
    return kept;
  }

  // ---- download ------------------------------------------------------------

  /// Resolve the play URL at the user's quality and download the song.
  /// Returns true on success. Already-downloaded songs return true
  /// immediately without re-downloading. Never throws: a resolver
  /// failure (or any other error) is a failed download, not a crash
  /// in the tap handler — both call sites (track sheet, downloads
  /// page retry) await this with no try/catch of their own.
  Future<bool> download(Song song) async {
    if (localPathFor(song) != null) {
      status[song.identityKey] = DownloadStatus.downloaded;
      return true;
    }
    try {
      final r = await _resolvers.resolvePlayUrl(
        song.songId,
        song.platform,
        quality,
        song.title,
        artist: song.artist,
      );
      if (r == null || r.url.isEmpty) {
        status[song.identityKey] = DownloadStatus.failed;
        return false;
      }
      // await (not bare return) so a failure inside the download is
      // caught by the catch below instead of escaping to the caller.
      return await downloadFromUrl(song, r.url);
    } catch (_) {
      status[song.identityKey] = DownloadStatus.failed;
      return false;
    }
  }

  /// Download [song] from an already-resolved [url]. Testable without
  /// the resolver: point [url] at a local server. A second call for
  /// the same song while one is in flight shares the first download
  /// instead of writing the same tmp file twice (see [_inFlight]).
  Future<bool> downloadFromUrl(Song song, String url) {
    final key = song.identityKey;
    final existing = _inFlight[key];
    if (existing != null) return existing;
    final fut = _downloadFromUrlInner(song, url);
    _inFlight[key] = fut;
    return fut.whenComplete(() => _inFlight.remove(key));
  }

  Future<bool> _downloadFromUrlInner(Song song, String url) async {
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
    // Stall watchdog: cancel the download when no bytes arrive for
    // [stallTimeout] (Dio's receiveTimeout does not cover the body).
    var lastProgress = DateTime.now();
    final cancelToken = CancelToken();
    final watchdog = Timer.periodic(stallCheckInterval, (_) {
      if (DateTime.now().difference(lastProgress) > stallTimeout) {
        cancelToken.cancel('download stalled');
      }
    });
    try {
      final response = await _dio.download(
        url,
        tmpFile.path,
        cancelToken: cancelToken,
        options: Options(connectTimeout: const Duration(seconds: 15)),
        onReceiveProgress: (received, total) {
          lastProgress = DateTime.now();
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
          filePath: LocalPaths.storedName(kMusicDownloadsSubdir, fileName),
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
    } finally {
      watchdog.cancel();
    }
  }

  /// Delete one downloaded song (file + index entry).
  Future<bool> delete(Song song) async {
    final key = song.identityKey;
    final entries = _readIndex();
    final entry = entries.where((e) => e.key == key);
    if (entry.isEmpty) return false;
    final resolved = _resolveStored(entry.first.filePath);
    try {
      if (resolved != null) await File(resolved).delete();
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
      final resolved = _resolveStored(e.filePath);
      if (resolved == null) continue;
      final file = File(resolved);
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
      final resolved = _resolveStored(e.filePath);
      if (resolved == null) continue;
      try {
        final file = File(resolved);
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
