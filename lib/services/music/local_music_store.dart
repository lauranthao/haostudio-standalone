// Local audio files (stage 2 item 4).
//
// file_picker picks local audio files; the picked file is COPIED into
// the app documents directory (`local_music/`) and indexed in Hive
// (`hao_local_music`, a JSON list of Song with `localPath`), so the
// list survives restarts and the original file can move or be deleted
// afterwards. Copying (rather than referencing the picked path)
// matches Beans' document-picker-asCopy behaviour
// (ProfileView.swift `FontDocumentPicker`: UIDocumentPicker with
// asCopy) and the download service's app-documents pattern.
//
// The stored `localPath` is a RELATIVE name (`local_music/<file>`),
// never an absolute path: iOS changes the app container UUID on
// every (re)install, so an absolute path stored in Hive dies with
// the old container — and the old code then pruned the index entry
// itself (1.1.0 -> 1.1.1 upgrade lost every imported file, chen
// 2026-11-18). The absolute path is rebuilt from the CURRENT
// Documents directory on every read ([LocalPaths]); old absolute
// entries are repaired in place on first sight, and the directory is
// rescanned before anything is pruned, so files whose index was
// already destroyed by 1.1.1 come back.
//
// Playback reuses the existing chain: [Song.isLocal] makes
// MusicPlayerController._loadCurrent open the file directly through
// the AVPlayer (just_audio) player — no new playback path, no
// resolver call, no lyrics fetch. The stored Song carries
// platform wy only as a placeholder (there is no "local" platform in
// MusicPlatform — adding one would touch every platform switch in
// the app); the `local:` songId prefix + non-empty localPath is what
// marks a song local, never the platform.
//
// Durations are unknown at import (dur 0); SongRow only shows a
// duration when dur > 0, so no fake "0:00" is ever shown. The real
// duration appears in the player once just_audio loads the file.

import 'dart:convert';
import 'dart:io';

import '../../core/storage/hive_store.dart';
import '../../core/storage/local_paths.dart';
import 'music_models.dart';

/// Audio extensions accepted for import (same set as the download
/// service's `_kAudioExtensions`).
const Set<String> kLocalAudioExtensions = {
  'mp3',
  'm4a',
  'flac',
  'wav',
  'ogg',
  'aac',
};

/// Subdirectory under Documents holding the imported copies.
const String kLocalMusicSubdir = 'local_music';

class LocalMusicStore {
  LocalMusicStore({Directory? directory}) : _directoryOverride = directory;

  final Directory? _directoryOverride;

  Future<Directory> get _dir async {
    if (_directoryOverride != null) {
      if (!await _directoryOverride.exists()) {
        await _directoryOverride.create(recursive: true);
      }
      return _directoryOverride;
    }
    final basePath = await LocalPaths.ensureDocumentsPath();
    final dir = Directory('$basePath/$kLocalMusicSubdir');
    if (!await dir.exists()) await dir.create(recursive: true);
    return dir;
  }

  List<Song> _readIndex() {
    final raw = HiveStore.box.get(HiveKeys.musicLocalFiles) as String?;
    if (raw == null || raw.isEmpty) return [];
    try {
      final decoded = jsonDecode(raw);
      if (decoded is List) {
        return decoded
            .whereType<Map<String, dynamic>>()
            .map(Song.fromJson)
            .where((s) => s.isLocal)
            .toList();
      }
    } catch (_) {}
    return [];
  }

  Future<void> _writeIndex(List<Song> songs) => HiveStore.put(
    HiveKeys.musicLocalFiles,
    jsonEncode(songs.map((s) => s.toJson()).toList()),
  );

  /// Resolve an index entry's stored path to an existing absolute
  /// path: the stored value as-is when it is absolute and still
  /// valid, else `<current Documents>/local_music/<basename>`.
  Future<String?> _resolve(String stored) => LocalPaths.resolve(
    stored,
    kLocalMusicSubdir,
    directoryOverride: _directoryOverride,
  );

  /// Imported files, newest first.
  ///
  /// Repair + rescan run BEFORE any pruning:
  /// - an entry whose stored value is an old absolute path is
  ///   resolved through the current container and rewritten to the
  ///   relative form in place;
  /// - files on disk that have no index entry (their index was
  ///   destroyed by the 1.1.1 prune) are rebuilt and added back.
  /// An entry is dropped only when its file is missing in all three
  /// places (stored path, current-dir basename, directory rescan).
  Future<List<Song>> list() async {
    final dir = await _dir;
    final songs = _readIndex();
    final kept = <Song>[];
    final seenNames = <String>{};
    var changed = false;
    for (final s in songs) {
      final resolved = await _resolve(s.localPath);
      if (resolved == null) continue;
      final stored = LocalPaths.storedName(
        kLocalMusicSubdir,
        LocalPaths.baseName(s.localPath),
      );
      final fixed = s.localPath == stored
          ? s
          : s.copyWith(localPath: stored);
      if (fixed.localPath != s.localPath) changed = true;
      kept.add(fixed);
      seenNames.add(LocalPaths.baseName(s.localPath));
    }
    // Rescan the directory: re-add audio files with no index entry.
    final rescanned = <Song>[];
    try {
      final entries = await dir.list().toList();
      final files = <File>[];
      for (final e in entries) {
        if (e is! File) continue;
        final name = e.path.split('/').last;
        if (name.startsWith('.')) continue;
        final ext = name.contains('.')
            ? name.split('.').last.toLowerCase()
            : '';
        if (!kLocalAudioExtensions.contains(ext)) continue;
        if (seenNames.contains(name)) continue;
        files.add(e);
      }
      // Newest first (imports are stamped `<epoch>_<name>`; modified
      // time is the same order without trusting the name).
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
        final name = f.path.split('/').last;
        rescanned.add(
          songForFile(LocalPaths.storedName(kLocalMusicSubdir, name)),
        );
        seenNames.add(name);
      }
    } catch (_) {
      // A directory that cannot be listed rescans to nothing — the
      // index entries above still stand on their own.
    }
    if (rescanned.isNotEmpty) {
      kept.insertAll(0, rescanned);
      changed = true;
    }
    if (changed || kept.length != songs.length) {
      await _writeIndex(kept);
    }
    return kept;
  }

  /// Import [source] (a file picked with file_picker). Returns the
  /// indexed Song, or null when the file is not an accepted audio
  /// type. The same file imported twice returns the existing entry
  /// (matched on file name + size) instead of a duplicate copy.
  Future<Song?> importFile(File source) async {
    final ext = source.path.split('.').last.toLowerCase();
    if (!kLocalAudioExtensions.contains(ext)) return null;
    if (!await source.exists()) return null;
    final dir = await _dir;
    final baseName = source.path.split('/').last;
    // Strip only filesystem-unsafe characters (path separators, `?`,
    // `*`, quotes, `<>`, `|` and control chars). Do NOT use \w here:
    // Dart's \w is ASCII-only, so it would destroy CJK file names
    // ("周杰伦 - 晴天.mp3" became "__ - __.mp3").
    final safeName = baseName.replaceAll(
      RegExp(r'''[/\\?%*:|"<>]'''),
      '_',
    );
    final size = await source.length();
    // Dedup: same file name + same size already indexed.
    final indexed = _readIndex();
    for (var i = 0; i < indexed.length; i++) {
      final s = indexed[i];
      if (!LocalPaths.baseName(s.localPath).endsWith(safeName)) {
        continue;
      }
      final resolved = await _resolve(s.localPath);
      if (resolved == null) continue;
      final f = File(resolved);
      if (await f.exists() && await f.length() == size) {
        // Repair the stored form while we are here.
        final stored = LocalPaths.storedName(
          kLocalMusicSubdir,
          LocalPaths.baseName(s.localPath),
        );
        if (s.localPath != stored) {
          indexed[i] = s.copyWith(localPath: stored);
          await _writeIndex(indexed);
          return indexed[i];
        }
        return s;
      }
    }
    final stamp = DateTime.now().millisecondsSinceEpoch;
    final target = File('${dir.path}/${stamp}_$safeName');
    await source.copy(target.path);
    final song = songForFile(target.path);
    final songs = _readIndex();
    songs.insert(0, song);
    await _writeIndex(songs);
    return song;
  }

  /// Remove [song] from the index AND delete its file. Returns false
  /// when the song was not in the index (nothing deleted).
  Future<bool> remove(Song song) async {
    final songs = _readIndex();
    final before = songs.length;
    songs.removeWhere((s) => s.identityKey == song.identityKey);
    if (songs.length == before) return false;
    await _writeIndex(songs);
    try {
      final resolved = await _resolve(song.localPath);
      if (resolved != null) await File(resolved).delete();
    } catch (_) {
      // File already gone — the index removal is what matters.
    }
    return true;
  }

  /// Song for an imported file. [path] may be the absolute copy path
  /// (import) or the stored relative name (directory rescan). The
  /// stored [Song.localPath] is always the relative form
  /// (`local_music/<file>`). Title/artist come from the file name
  /// ("Artist - Title.ext" splits; otherwise the whole name is
  /// the title and the artist is empty — never guessed from metadata
  /// we did not read). The id is `local:` + the stored file name,
  /// stable across restarts because the copy's name never changes.
  static Song songForFile(String path) {
    final fileName = LocalPaths.baseName(path);
    final withoutStamp = fileName.replaceFirst(
      RegExp(r'^\d+_'),
      '',
    );
    final withoutExt = withoutStamp.contains('.')
        ? withoutStamp.substring(0, withoutStamp.lastIndexOf('.'))
        : withoutStamp;
    final parts = withoutExt.split(' - ');
    final artist = parts.length > 1 ? parts.first.trim() : '';
    final title = parts.length > 1
        ? parts.sublist(1).join(' - ').trim()
        : withoutExt.trim();
    return Song(
      songId: 'local:$fileName',
      title: title.isEmpty ? fileName : title,
      artist: artist,
      platform: MusicPlatform.wy,
      localPath: LocalPaths.storedName(kLocalMusicSubdir, fileName),
    );
  }
}
