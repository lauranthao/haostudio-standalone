// Backup & restore — file-based export/import of ALL local data (step 7).
//
// Scope (chen, frozen): backup management and restore = export/import all
// local data as a file. File-based ONLY, no cloud. The whole Hive box
// (`app_settings`) is the data store, so a backup is a JSON dump of every
// key/value pair plus a schema envelope. Future keys (music playlists,
// listen history, video records) are included automatically because the
// dump is the whole box, not a hand-listed subset.
//
// File picking/sharing is NOT in this service: the UI layer wires
// file_picker (import) / share_plus (export) on top of [exportJson] /
// [importJson]. Until then the settings page writes the file into the app
// documents directory and shows its path.

import 'dart:convert';

import 'package:hive_ce_flutter/hive_ce_flutter.dart';

/// Backup file schema version. Bump only when the envelope changes in a
/// way old backups cannot be read (they are still read: unknown fields
/// are ignored, missing fields get defaults).
const int kBackupSchemaVersion = 1;

/// Result of an import attempt.
enum BackupImportResult {
  ok,
  invalidJson,
  wrongSchema,
  emptyData,
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

  /// Restore from a backup JSON string. Validates the envelope first;
  /// on any validation failure NOTHING is written. Returns the number
  /// of restored entries on success.
  (BackupImportResult, int) importJson(String json) {
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
    var restored = 0;
    for (final entry in data.entries) {
      // Only JSON-native values are stored: strings, numbers, bools,
      // lists and maps. Anything else (shouldn't happen — the export
      // only writes what Hive holds) is skipped, never written raw.
      if (_isJsonNative(entry.value)) {
        box.put(entry.key, entry.value);
        restored++;
      }
    }
    return (BackupImportResult.ok, restored);
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
