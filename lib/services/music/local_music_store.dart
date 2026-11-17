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

import 'package:path_provider/path_provider.dart';

import '../../core/storage/hive_store.dart';
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
    final base = await getApplicationDocumentsDirectory();
    final dir = Directory('${base.path}/local_music');
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

  /// Imported files, newest first. Entries whose file is gone are
  /// pruned (and the pruned index written back) — never shown as
  /// phantom rows.
  Future<List<Song>> list() async {
    final songs = _readIndex();
    final kept = <Song>[];
    var pruned = false;
    for (final s in songs) {
      if (await File(s.localPath).exists()) {
        kept.add(s);
      } else {
        pruned = true;
      }
    }
    if (pruned) await _writeIndex(kept);
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
    for (final s in _readIndex()) {
      if (s.localPath.split('/').last.endsWith(safeName)) {
        final f = File(s.localPath);
        if (await f.exists() && await f.length() == size) return s;
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
      await File(song.localPath).delete();
    } catch (_) {
      // File already gone — the index removal is what matters.
    }
    return true;
  }

  /// Song for an imported file path. Title/artist come from the file
  /// name ("Artist - Title.ext" splits; otherwise the whole name is
  /// the title and the artist is empty — never guessed from metadata
  /// we did not read). The id is `local:` + the stored file name,
  /// stable across restarts because the copy's name never changes.
  static Song songForFile(String path) {
    final fileName = path.split('/').last;
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
      localPath: path,
    );
  }
}
