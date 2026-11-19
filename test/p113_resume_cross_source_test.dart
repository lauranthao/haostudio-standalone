// P1-15: cross-source resume was lost on a source switch.
//
// VideoDetailPage.loadResume(sourceId, vodId) only knows the WINNING
// source's resume key, and the findByTitle fallback only carried
// line/episode indices, never a position — so after the detail race
// switched sources the big button degraded from
// "继续播放 · 第 N 集 · mm:ss" to a bare episode name, and the player
// started at 0. Fix: VideoHistoryStore.loadResumeForFilm, the
// film-level row (title + year, any source) mapped onto the CURRENT
// detail's lines by episode NAME, with the saved position.
//
// Rules pinned here: only the SAME episode resumes (name must be in
// these lines — a different episode list returns null, never a
// guessed index); the vodLocalLoad rule still applies (> 10 s in,
// >= 30 s from the end); a different KNOWN year never matches.

import 'dart:io';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:get/get.dart';
import 'package:standalone/core/storage/hive_store.dart';
import 'package:standalone/features/video/video_history_store.dart';
import 'package:standalone/features/video/video_models.dart';

WatchHistoryEntry _entry({
  required dynamic source,
  required String vodId,
  required String title,
  String year = '',
  int lineIdx = 0,
  int epIdx = 0,
  String epName = '',
  double position = 600,
  double duration = 1800,
  required DateTime at,
}) =>
    WatchHistoryEntry(
      source: source,
      vodId: vodId,
      title: title,
      pic: '',
      year: year,
      lineIdx: lineIdx,
      epIdx: epIdx,
      epName: epName,
      position: position,
      duration: duration,
      at: at,
    );

/// A detail as the NEW source lists it: two lines, episodes named
/// the same way, but a different line order/count than the source the
/// user originally watched on.
List<PlayLine> _newSourceLines() => [
      PlayLine(name: '线路二', episodes: [
        PlayEpisode(name: '第1集', url: 'https://x/b1.m3u8'),
        PlayEpisode(name: '第2集', url: 'https://x/b2.m3u8'),
        PlayEpisode(name: '第3集', url: 'https://x/b3.m3u8'),
      ]),
      PlayLine(name: '线路一', episodes: [
        PlayEpisode(name: '第1集', url: 'https://x/a1.m3u8'),
        PlayEpisode(name: '第2集', url: 'https://x/a2.m3u8'),
        PlayEpisode(name: '第3集', url: 'https://x/a3.m3u8'),
        PlayEpisode(name: '第4集', url: 'https://x/a4.m3u8'),
      ]),
    ];

void main() {
  late Directory hiveDir;

  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    hiveDir = await Directory.systemTemp.createTemp('hao-p113-resume-');
    const channel = MethodChannel('plugins.flutter.io/path_provider');
    TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
        .setMockMethodCallHandler(channel, (call) async {
      if (call.method == 'getApplicationDocumentsDirectory') {
        return hiveDir.path;
      }
      return null;
    });
    await HiveStore.init();
  });

  tearDownAll(() async {
    await HiveStore.box.close();
    await hiveDir.delete(recursive: true);
  });

  tearDown(() async {
    Get.reset();
    await HiveStore.delete(HiveKeys.videoHistory);
    // Resume keys live under the videoResume prefix; clear them too.
    for (final k in HiveStore.box.keys
        .whereType<String>()
        .where((k) => k.startsWith(HiveKeys.videoResumePrefix))
        .toList()) {
      await HiveStore.delete(k);
    }
  });

  test('cross-source resume: old source position maps by episode name',
      () async {
    // Watched ep3 on source 12 (line 0, epIdx 2) to 600 s.
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '霓裳尽欢',
        year: '2024',
        lineIdx: 0,
        epIdx: 2,
        epName: '第3集',
        position: 600,
        duration: 1800,
        at: DateTime(2026, 11, 19, 10),
      ),
    );

    // The new source has no resume key of its own — loadResume is null.
    expect(
      VideoHistoryStore.loadResume(5, '2002', _newSourceLines()),
      isNull,
    );
    // The film-level fallback finds the position and maps 第3集 onto
    // the new source's lines (first line that carries the name).
    final resume = VideoHistoryStore.loadResumeForFilm(
      title: '霓裳尽欢',
      year: '2024',
      lines: _newSourceLines(),
    );
    expect(resume, isNotNull);
    expect(resume!.epName, '第3集');
    expect(resume.position, 600);
    expect(resume.lineIdx, 0);
    expect(resume.epIdx, 2);
  });

  test('episode name missing from the new lines: no resume, no lie',
      () async {
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '霓裳尽欢',
        year: '2024',
        epIdx: 9,
        epName: '第10集',
        position: 600,
        duration: 1800,
        at: DateTime(2026, 11, 19, 10),
      ),
    );

    // The new source only lists 4 episodes: 第10集 is not there, so
    // no resume — never a clamped index with the old time attached.
    expect(
      VideoHistoryStore.loadResumeForFilm(
        title: '霓裳尽欢',
        year: '2024',
        lines: _newSourceLines(),
      ),
      isNull,
    );
  });

  test('different known year never resumes into another film', () async {
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '霓裳尽欢',
        year: '2019',
        epIdx: 2,
        epName: '第3集',
        position: 600,
        duration: 1800,
        at: DateTime(2026, 11, 19, 10),
      ),
    );

    expect(
      VideoHistoryStore.loadResumeForFilm(
        title: '霓裳尽欢',
        year: '2024',
        lines: _newSourceLines(),
      ),
      isNull,
    );
  });

  test('legacy year-less row still resumes (backward compatible)',
      () async {
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '霓裳尽欢',
        // No year: a row written before P1-16.
        epIdx: 1,
        epName: '第2集',
        position: 300,
        duration: 1800,
        at: DateTime(2026, 11, 19, 10),
      ),
    );

    final resume = VideoHistoryStore.loadResumeForFilm(
      title: '霓裳尽欢',
      year: '2024',
      lines: _newSourceLines(),
    );
    expect(resume, isNotNull);
    expect(resume!.epName, '第2集');
    expect(resume.position, 300);
  });

  test('vodLocalLoad rule still applies to the film-level resume',
      () async {
    // <= 10 s in: no resume.
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '霓裳尽欢',
        year: '2024',
        epIdx: 0,
        epName: '第1集',
        position: 8,
        duration: 1800,
        at: DateTime(2026, 11, 19, 10),
      ),
    );
    expect(
      VideoHistoryStore.loadResumeForFilm(
        title: '霓裳尽欢',
        year: '2024',
        lines: _newSourceLines(),
      ),
      isNull,
    );

    // Within 30 s of the end: finished, no resume.
    await VideoHistoryStore.record(
      _entry(
        source: 12,
        vodId: '1001',
        title: '霓裳尽欢',
        year: '2024',
        epIdx: 0,
        epName: '第1集',
        position: 1780,
        duration: 1800,
        at: DateTime(2026, 11, 19, 11),
      ),
    );
    expect(
      VideoHistoryStore.loadResumeForFilm(
        title: '霓裳尽欢',
        year: '2024',
        lines: _newSourceLines(),
      ),
      isNull,
    );
  });

  test('brother case: same-source resume key behaviour unchanged',
      () async {
    await VideoHistoryStore.saveResume(
      5,
      '2002',
      lineIdx: 1,
      epIdx: 3,
      epName: '第4集',
      position: 900,
      duration: 1800,
    );
    final resume = VideoHistoryStore.loadResume(5, '2002', _newSourceLines());
    expect(resume, isNotNull);
    expect(resume!.lineIdx, 1);
    expect(resume.epIdx, 3);
    expect(resume.position, 900);
    // Another source+vodId still has no key.
    expect(
      VideoHistoryStore.loadResume(12, '1001', _newSourceLines()),
      isNull,
    );
  });
}
