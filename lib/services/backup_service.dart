// Backup & restore — file-based export/import of ALL local data (step 7).
//
// Scope (chen, frozen): backup management and restore = export/import all
// local data as a file. File-based ONLY, no cloud. The whole Hive box
// (`app_settings`) is the data store, so a backup is a JSON dump of every
// key/value pair plus a schema envelope. Future keys (music playlists,
// listen history, video records) are included automatically because the
// dump is the whole box, not a hand-listed subset.
//
// P1-L3 (route (a), zip): the old JSON-only export did NOT contain the
// actual files — downloads, local music and wallpapers are stored as
// relative names in Hive with the bytes in the Documents directory, so
// restoring a JSON backup on a fresh install left every file entry
// pointing at nothing. The export is now a .zip: `backup.json` (the
// same envelope as [exportJson]) + the user-file subdirectories under
// Documents ([kBackupFileSubdirs]). Import accepts both the new .zip
// and legacy .json backups ([importZip] / [importJson]).
//
// File picking/sharing is NOT in this service: the UI layer wires
// file_picker (import) / share_plus (export) on top of [exportZip] /
// [importZip] / [importJson]. Until then the settings page writes the
// file into the app documents directory and shows its path.

import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:archive/archive.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// Backup file schema version. Bump only when the envelope changes in a
/// way old backups cannot be read (they are still read: unknown fields
/// are ignored, missing fields get defaults).
const int kBackupSchemaVersion = 1;

/// Name of the Hive JSON envelope inside a backup zip.
const String kBackupZipJsonName = 'backup.json';

/// User-file subdirectories under the Documents directory that a
/// backup zip carries (relative names in Hive resolve into these —
/// see LocalPaths, music_downloads.dart, local_music_store.dart,
/// appearance_store.dart, custom_font_service.dart). The Hive box
/// files themselves are NOT included: the JSON envelope is the data.
const List<String> kBackupFileSubdirs = <String>[
  'music_downloads',
  'local_music',
  'wallpapers',
  'fonts',
];

/// Result of an import attempt.
enum BackupImportResult {
  ok,
  invalidJson,
  wrongSchema,
  emptyData,

  /// A write failed mid-import (disk error, box closed). The pre-import
  /// snapshot was restored in full — the UI reports "已恢复原数据".
  writeFailed,
}

class BackupService {
  BackupService({required this.box});

  final Box<dynamic> box;

  /// Serialize the whole box into a backup JSON string.
  /// Keys are sorted for stable, diffable output.
  String exportJson({DateTime? now}) {
    final timestamp = (now ?? DateTime.now()).toUtc().toIso8601String();
    final data = <String, dynamic>{};
    for (final key in box.keys) {
      data[key.toString()] = box.get(key);
    }
    final keys = data.keys.toList()..sort();
    final ordered = <String, dynamic>{
      for (final k in keys) k: data[k],
    };
    return jsonEncode(<String, dynamic>{
      'schema': kBackupSchemaVersion,
      'app': 'HAo Studio',
      'version': '1.0.4',
      'exportedAt': timestamp,
      'entries': ordered.length,
      'data': ordered,
    });
  }

  /// Export the whole backup as a zip: `backup.json` ([exportJson])
  /// + every file under [kBackupFileSubdirs] of [documentsDir]
  /// (relative paths preserved, so a restore lands them back where
  /// the Hive relative names point). A missing/unreadable subdir
  /// contributes nothing; a missing [documentsDir] means the zip
  /// holds only the JSON (same content as the old export).
  Future<Uint8List> exportZip({Directory? documentsDir, DateTime? now}) async {
    final archive = Archive();
    final jsonBytes = utf8.encode(exportJson(now: now));
    archive.addFile(
      ArchiveFile(kBackupZipJsonName, jsonBytes.length, jsonBytes),
    );
    final docs = documentsDir;
    if (docs != null) {
      for (final sub in kBackupFileSubdirs) {
        final dir = Directory('${docs.path}/$sub');
        if (!await dir.exists()) continue;
        await for (final entity in dir.list(recursive: true)) {
          if (entity is! File) continue;
          try {
            final bytes = await entity.readAsBytes();
            final rel = entity.path.substring(docs.path.length + 1);
            archive.addFile(ArchiveFile(rel, bytes.length, bytes));
          } catch (_) {
            // One unreadable file must not fail the whole export.
          }
        }
      }
    }
    return Uint8List.fromList(ZipEncoder().encode(archive));
  }

  /// Restore from a backup zip ([exportZip] output). The JSON part
  /// goes through the same atomic [importJson] path; the files are
  /// then written back under [documentsDir] (subdirectories created
  /// as needed). Zip-slip entries (absolute paths, `..` segments,
  /// anything outside [kBackupFileSubdirs]) are skipped, never
  /// written. Returns (result, restored Hive entries, restored
  /// files). When [documentsDir] is null the JSON still imports but
  /// the files are skipped (0 files restored).
  ///
  /// A legacy .json backup is NOT handled here — the UI routes it to
  /// [importJson]. Note the asymmetry that remains: a legacy JSON
  /// backup has no files, so its file entries still point at
  /// nothing after import (that is what the zip format fixes).
  Future<(BackupImportResult, int, int)> importZip(
    List<int> bytes, {
    Directory? documentsDir,
  }) async {
    Archive archive;
    try {
      archive = ZipDecoder().decodeBytes(bytes);
    } catch (_) {
      return (BackupImportResult.invalidJson, 0, 0);
    }
    ArchiveFile? jsonFile;
    for (final f in archive.files) {
      if (f.isFile && f.name == kBackupZipJsonName) jsonFile = f;
    }
    if (jsonFile == null) return (BackupImportResult.invalidJson, 0, 0);
    final (result, restored) = await importJson(
      utf8.decode(jsonFile.content as List<int>),
    );
    if (result != BackupImportResult.ok) return (result, 0, 0);
    var restoredFiles = 0;
    final docs = documentsDir;
    if (docs != null) {
      for (final f in archive.files) {
        if (!f.isFile || f.name == kBackupZipJsonName) continue;
        if (!_isSafeBackupPath(f.name)) continue;
        try {
          final out = File('${docs.path}/${f.name}');
          await out.parent.create(recursive: true);
          await out.writeAsBytes(f.content as List<int>, flush: true);
          restoredFiles++;
        } catch (_) {
          // One unwritable file must not fail the whole import; the
          // Hive entries are already restored.
        }
      }
    }
    return (result, restored, restoredFiles);
  }

  /// A zip entry is safe to restore only when it is a relative path
  /// inside one of [kBackupFileSubdirs] (no absolute path, no `..`).
  static bool _isSafeBackupPath(String name) {
    if (name.startsWith('/') || name.contains('..')) return false;
    final first = name.split('/').first;
    return kBackupFileSubdirs.contains(first);
  }

  /// Restore from a backup JSON string. Validates the envelope first;
  /// on any validation failure NOTHING is written. The write itself is
  /// atomic (P1-L4): the current box is snapshotted in memory first,
  /// entries are written one by one, and if any write fails the
  /// snapshot is restored in full and [BackupImportResult.writeFailed]
  /// is returned — the UI reports "已恢复原数据". Import merges: keys
  /// absent from the backup are kept, not deleted. Returns the number
  /// of restored entries on success.
  Future<(BackupImportResult, int)> importJson(String json) async {
    dynamic decoded;
    try {
      decoded = jsonDecode(json);
    } catch (_) {
      return (BackupImportResult.invalidJson, 0);
    }
    if (decoded is! Map<String, dynamic>) {
      return (BackupImportResult.invalidJson, 0);
    }
    final schema = decoded['schema'];
    if (schema is! int || schema != kBackupSchemaVersion) {
      return (BackupImportResult.wrongSchema, 0);
    }
    final data = decoded['data'];
    if (data is! Map<String, dynamic> || data.isEmpty) {
      return (BackupImportResult.emptyData, 0);
    }
    // Snapshot the whole current box in memory before writing.
    final snapshot = <String, dynamic>{};
    for (final key in box.keys) {
      snapshot[key.toString()] = box.get(key);
    }
    var restored = 0;
    try {
      for (final entry in data.entries) {
        // Only JSON-native values are stored: strings, numbers, bools,
        // lists and maps. Anything else (shouldn't happen — the export
        // only writes what Hive holds) is skipped, never written raw.
        if (_isJsonNative(entry.value)) {
          await box.put(entry.key, entry.value);
          restored++;
        }
      }
    } catch (_) {
      await _rollback(snapshot);
      return (BackupImportResult.writeFailed, 0);
    }
    return (BackupImportResult.ok, restored);
  }

  /// Restore the pre-import snapshot: delete keys the import added,
  /// then put back every snapshotted value. Best-effort — if the box
  /// is closed (app kill) there is nothing more that can be done.
  Future<void> _rollback(Map<String, dynamic> snapshot) async {
    try {
      for (final key in box.keys.toList()) {
        if (!snapshot.containsKey(key.toString())) {
          await box.delete(key);
        }
      }
      for (final entry in snapshot.entries) {
        await box.put(entry.key, entry.value);
      }
    } catch (_) {}
  }

  static bool _isJsonNative(Object? value) {
    if (value == null ||
        value is String ||
        value is num ||
        value is bool) {
      return true;
    }
    if (value is List) return value.every(_isJsonNative);
    if (value is Map) {
      return value.entries.every(
        (e) => e.key is String && _isJsonNative(e.value),
      );
    }
    return false;
  }
}
