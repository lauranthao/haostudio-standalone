// Runtime app log (chen 2026-11-20, Beans 日志 page).
//
// A small central logger: in-memory ring buffer (1000 entries) mirrored
// to a capped file in the app Documents directory, so entries survive a
// restart / crash and Settings → 日志 shows history, not just this
// session. The file is plain text, one entry per line, so it doubles as
// the share/export format.
//
// Best-effort throughout: a log call NEVER throws and NEVER blocks the
// caller — file writes are fire-and-forget, storage failures are
// dropped silently, and logging stays off the playback hot path (only
// coarse events are logged: start, play/resolve failures, live
// entry/recovery, update checks, caught native errors).

import 'dart:async';
import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:path_provider/path_provider.dart';

import '../storage/local_paths.dart';

enum AppLogLevel { debug, info, warn, error }

extension AppLogLevelLabel on AppLogLevel {
  String get label => switch (this) {
        AppLogLevel.debug => 'DEBUG',
        AppLogLevel.info => 'INFO',
        AppLogLevel.warn => 'WARN',
        AppLogLevel.error => 'ERROR',
      };

  static AppLogLevel? fromLabel(String label) => switch (label) {
        'DEBUG' => AppLogLevel.debug,
        'INFO' => AppLogLevel.info,
        'WARN' => AppLogLevel.warn,
        'ERROR' => AppLogLevel.error,
        _ => null,
      };
}

class AppLogEntry {
  const AppLogEntry({
    required this.time,
    required this.level,
    required this.message,
  });

  final DateTime time;
  final AppLogLevel level;
  final String message;

  /// One line: `[2026-11-20 13:19:45.620] [INFO] message`.
  String toLine() => '[${AppLog.formatTime(time)}] [${level.label}] $message';

  static final _linePattern =
      RegExp(r'^\[([^\]]+)\] \[([A-Z]+)\] (.*)$', dotAll: true);

  static AppLogEntry? tryParse(String line) {
    final match = _linePattern.firstMatch(line);
    if (match == null) return null;
    final level = AppLogLevelLabel.fromLabel(match.group(2)!);
    final time = _tryParseTime(match.group(1)!);
    if (level == null || time == null) return null;
    return AppLogEntry(time: time, level: level, message: match.group(3)!);
  }

  static DateTime? _tryParseTime(String text) {
    // yyyy-MM-dd HH:mm:ss.SSS — parsed by hand, no intl dependency.
    final match = RegExp(
      r'^(\d{4})-(\d{2})-(\d{2}) (\d{2}):(\d{2}):(\d{2})\.(\d{3})$',
    ).firstMatch(text);
    if (match == null) return null;
    return DateTime(
      int.parse(match.group(1)!),
      int.parse(match.group(2)!),
      int.parse(match.group(3)!),
      int.parse(match.group(4)!),
      int.parse(match.group(5)!),
      int.parse(match.group(6)!),
      int.parse(match.group(7)!),
    );
  }
}

class AppLog {
  AppLog._();

  /// In-memory cap: oldest entries are dropped first.
  static const int maxEntries = 1000;

  /// Persisted file cap: trim to roughly half when exceeded.
  static const int maxFileBytes = 256 * 1024;

  static const String fileName = 'hao_app_log.txt';

  static final List<AppLogEntry> _entries = [];
  static final List<Future<void>> _pendingWrites = [];
  // Appends run strictly one after another: two concurrent
  // File.writeAsString(append) calls can land at the same offset and
  // the second overwrites the first (observed in tests — the first of
  // two rapid entries vanished from the file).
  static Future<void> _writeChain = Future<void>.value();
  static File? _file;
  static bool _trimming = false;

  /// Bumps on every add / clear so the log page can rebuild cheaply.
  static final ValueNotifier<int> version = ValueNotifier<int>(0);

  /// Oldest first. The page reverses for newest-first display.
  static List<AppLogEntry> get entries => List.unmodifiable(_entries);

  /// Load persisted history. Call once at startup (after
  /// [LocalPaths.ensureDocumentsPath]); safe to call before any log.
  /// [directory] is a test override — production always uses the app
  /// Documents directory.
  static Future<void> init({String? directory}) async {
    try {
      final dir = directory ??
          LocalPaths.documentsPathSync ??
          (await getApplicationDocumentsDirectory()).path;
      _file = File('$dir/$fileName');
      await _loadFromFile();
    } catch (_) {
      // Logging must never break startup: memory-only mode.
      _file = null;
    }
  }

  static Future<void> _loadFromFile() async {
    final file = _file;
    if (file == null) return;
    try {
      if (!await file.exists()) return;
      final lines = await file.readAsLines();
      final parsed = lines
          .map(AppLogEntry.tryParse)
          .whereType<AppLogEntry>()
          .toList();
      // Keep only the newest maxEntries.
      final start = parsed.length > maxEntries ? parsed.length - maxEntries : 0;
      _entries
        ..clear()
        ..addAll(parsed.sublist(start));
    } catch (_) {
      // Corrupt / unreadable log file: start empty, keep the file for
      // the next append (which rewrites it only when trimming).
      _entries.clear();
    }
  }

  static void debug(String message) => add(AppLogLevel.debug, message);
  static void info(String message) => add(AppLogLevel.info, message);
  static void warn(String message) => add(AppLogLevel.warn, message);
  static void error(String message) => add(AppLogLevel.error, message);

  /// Never throws, never blocks: the file write is fire-and-forget.
  static void add(AppLogLevel level, String message) {
    final entry = AppLogEntry(
      time: DateTime.now(),
      level: level,
      message: message.replaceAll(RegExp(r'[\r\n]+'), ' '),
    );
    _entries.add(entry);
    if (_entries.length > maxEntries) {
      _entries.removeRange(0, _entries.length - maxEntries);
    }
    version.value++;
    // Console stays working for developers: same [HAo] prefix style
    // as the old scattered debugPrints.
    debugPrint('[HAo] ${level.label}: ${entry.message}');
    final file = _file;
    if (file != null) {
      final pending = _writeChain.then((_) => _appendToFile(file, entry));
      _writeChain = pending;
      _pendingWrites.add(pending);
      unawaited(pending.whenComplete(() => _pendingWrites.remove(pending)));
    }
  }

  static Future<void> _appendToFile(File file, AppLogEntry entry) async {
    try {
      await file.writeAsString('${entry.toLine()}\n', mode: FileMode.append);
      await _trimIfNeeded(file);
    } catch (_) {
      // Dropped write; playback and UI carry on.
    }
  }

  static Future<void> _trimIfNeeded(File file) async {
    if (_trimming) return;
    try {
      if (await file.length() <= maxFileBytes) return;
      _trimming = true;
      final lines = await file.readAsLines();
      // Keep the newest half of the cap, line-aligned.
      final keepFrom = lines.length ~/ 2;
      await file.writeAsString(
        '${lines.sublist(keepFrom).join('\n')}\n',
      );
    } catch (_) {
      // Best-effort only.
    } finally {
      _trimming = false;
    }
  }

  /// Empty the buffer and delete the persisted file. Waits for
  /// in-flight appends first, so a stale write cannot recreate the
  /// file right after the delete.
  static Future<void> clear() async {
    _entries.clear();
    version.value++;
    final file = _file;
    if (file == null) return;
    await _writeChain;
    try {
      if (await file.exists()) await file.delete();
    } catch (_) {
      // Best-effort only.
    }
  }

  /// `yyyy-MM-dd HH:mm:ss.SSS` — hand-rolled, no intl dependency.
  static String formatTime(DateTime time) {
    String two(int v) => v.toString().padLeft(2, '0');
    String three(int v) => v.toString().padLeft(3, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}:${two(time.second)}'
        '.${three(time.millisecond)}';
  }

  /// Share/export text for [entries] (one entry per line).
  static String formatText(Iterable<AppLogEntry> entries) =>
      entries.map((e) => e.toLine()).join('\n');

  /// Test hook: await in-flight file appends, then assert on disk.
  static Future<void> flushForTest() async {
    await Future.wait(List.of(_pendingWrites));
  }

  /// Test hook: drop all state (memory + file handle).
  static void resetForTest() {
    _entries.clear();
    _pendingWrites.clear();
    _writeChain = Future<void>.value();
    _file = null;
    _trimming = false;
    version.value++;
  }
}
