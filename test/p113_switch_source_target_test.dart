// P1-17: in-player source switch forced line 1.
//
// _trySwitchSource took `altDetail.lines.first.episodes` and wrote
// `_lineIdx = 0`: an episode playing on line 2/3 always landed on the
// backup source's line 1, and the same-name search only ran inside
// that one line (clamped by index otherwise — possibly the wrong
// episode). Fix: resolveSwitchTarget searches ALL of the target's
// lines for the episode name first; with no name match it keeps the
// CURRENT line number (clamped) and clamps the episode index into
// that line. VOD only: no quality selector or orientation logic is
// touched here (VOD has neither).

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/video/native_video_player_page.dart';
import 'package:standalone/features/video/video_models.dart';

List<PlayLine> _lines(List<List<String>> lineEps) => [
      for (var li = 0; li < lineEps.length; li++)
        PlayLine(
          name: '线路${li + 1}',
          episodes: [
            for (final name in lineEps[li])
              PlayEpisode(name: name, url: 'https://x/$name.m3u8'),
          ],
        ),
    ];

void main() {
  group('resolveSwitchTarget', () {
    test('same-name episode on the backup source line 2 wins', () {
      final target = resolveSwitchTarget(
        lines: _lines([
          ['第1集', '第2集'],
          ['第1集', '第2集', '第3集', '第4集'],
          ['第1集'],
        ]),
        epName: '第3集',
        lineIdx: 1,
        epIdx: 2,
      );
      expect(target.lineIdx, 1);
      expect(target.epIdx, 2);
      expect(target.matchedByName, isTrue);
    });

    test('same-name episode on a DIFFERENT line than current', () {
      // Playing line 3 (index 2) on the old source; the backup source
      // carries 第3集 on its line 2 (index 1), not line 3.
      final target = resolveSwitchTarget(
        lines: _lines([
          ['第1集', '第2集'],
          ['第1集', '第2集', '第3集'],
          ['第1集', '第2集'],
        ]),
        epName: '第3集',
        lineIdx: 2,
        epIdx: 2,
      );
      expect(target.lineIdx, 1);
      expect(target.epIdx, 2);
      expect(target.matchedByName, isTrue);
    });

    test('no same-name episode: keep current line, clamp episode',
        () {
      final target = resolveSwitchTarget(
        lines: _lines([
          ['第1集', '第2集'],
          ['A', 'B'],
        ]),
        epName: '第9集',
        lineIdx: 1,
        epIdx: 5,
      );
      expect(target.lineIdx, 1);
      expect(target.epIdx, 1);
      expect(target.matchedByName, isFalse);
    });

    test('current line beyond the target line count clamps, never OOB',
        () {
      final target = resolveSwitchTarget(
        lines: _lines([
          ['第1集', '第2集', '第3集'],
        ]),
        epName: '第9集',
        lineIdx: 2,
        epIdx: 1,
      );
      expect(target.lineIdx, 0);
      expect(target.epIdx, 1);
      expect(target.matchedByName, isFalse);
    });

    test('brother case: single-line backup behaves as before', () {
      final target = resolveSwitchTarget(
        lines: _lines([
          ['第1集', '第2集', '第3集'],
        ]),
        epName: '第2集',
        lineIdx: 0,
        epIdx: 1,
      );
      expect(target, (lineIdx: 0, epIdx: 1, matchedByName: true));
    });

    test('empty lines: (0, 0, false); caller skips the target', () {
      expect(
        resolveSwitchTarget(
          lines: [],
          epName: '第1集',
          lineIdx: 0,
          epIdx: 0,
        ),
        (lineIdx: 0, epIdx: 0, matchedByName: false),
      );
      expect(
        resolveSwitchTarget(
          lines: _lines([[], []]),
          epName: '第1集',
          lineIdx: 0,
          epIdx: 0,
        ),
        (lineIdx: 0, epIdx: 0, matchedByName: false),
      );
    });

    test('corresponding line empty: first non-empty line wins', () {
      final target = resolveSwitchTarget(
        lines: _lines([
          [],
          ['第1集', '第2集'],
        ]),
        epName: '第9集',
        lineIdx: 0,
        epIdx: 1,
      );
      expect(target.lineIdx, 1);
      expect(target.epIdx, 1);
      expect(target.matchedByName, isFalse);
    });
  });
}
