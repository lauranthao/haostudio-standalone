// AppLog unit tests: levels, ring cap, clear, file persistence, format.

import 'dart:io';

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/logging/app_log.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late Directory dir;

  setUp(() async {
    dir = await Directory.systemTemp.createTemp('hao-applog-test-');
    AppLog.resetForTest();
  });

  tearDown(() async {
    AppLog.resetForTest();
    await dir.delete(recursive: true);
  });

  test('levels keep their labels and round-trip through a line', () {
    for (final level in AppLogLevel.values) {
      final entry = AppLogEntry(
        time: DateTime(2026, 11, 20, 13, 19, 45, 620),
        level: level,
        message: 'm',
      );
      final parsed = AppLogEntry.tryParse(entry.toLine());
      expect(parsed?.level, level);
      expect(parsed?.message, 'm');
      expect(parsed?.time, entry.time);
    }
    expect(AppLogEntry.tryParse('garbage'), isNull);
    expect(AppLogEntry.tryParse('[2026-11-20 13:19:45.620] [NOPE] m'), isNull);
  });

  test('formatTime renders yyyy-MM-dd HH:mm:ss.SSS', () {
    expect(
      AppLog.formatTime(DateTime(2026, 11, 20, 13, 19, 45, 620)),
      '2026-11-20 13:19:45.620',
    );
    expect(
      AppLog.formatTime(DateTime(2026, 1, 2, 3, 4, 5, 6)),
      '2026-01-02 03:04:05.006',
    );
  });

  test('ring buffer caps at 1000, oldest dropped first', () {
    for (var i = 0; i < 1005; i++) {
      AppLog.debug('entry $i');
    }
    expect(AppLog.entries.length, AppLog.maxEntries);
    expect(AppLog.entries.first.message, 'entry 5');
    expect(AppLog.entries.last.message, 'entry 1004');
  });

  test('clear empties memory and deletes the persisted file', () async {
    await AppLog.init(directory: dir.path);
    AppLog.info('one');
    AppLog.error('two');
    await AppLog.flushForTest();
    expect(File('${dir.path}/${AppLog.fileName}').existsSync(), isTrue);
    await AppLog.clear();
    expect(AppLog.entries, isEmpty);
    expect(File('${dir.path}/${AppLog.fileName}').existsSync(), isFalse);
  });

  test('init loads persisted history from the file', () async {
    await AppLog.init(directory: dir.path);
    AppLog.info('first');
    AppLog.warn('second');
    await AppLog.flushForTest();
    AppLog.resetForTest();
    await AppLog.init(directory: dir.path);
    expect(
      AppLog.entries.map((e) => e.message),
      ['first', 'second'],
    );
    expect(
      AppLog.entries.map((e) => e.level),
      [AppLogLevel.info, AppLogLevel.warn],
    );
  });

  test('formatText joins entries one per line', () {
    AppLog.info('a');
    AppLog.error('b');
    final text = AppLog.formatText(AppLog.entries);
    expect(text, contains('[INFO] a'));
    expect(text, contains('[ERROR] b'));
    expect(text.split('\n').length, 2);
  });

  test('multiline messages are flattened to one line', () {
    AppLog.info('line1\nline2');
    expect(AppLog.entries.single.message, 'line1 line2');
    expect(AppLog.entries.single.toLine().split('\n').length, 1);
  });
}
