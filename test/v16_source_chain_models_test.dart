// 1.1.6 换源链路 — 集号解析 + 多源集并集 (pure, no network).
//
// Pins the red line: episode matching is a heuristic, so automatic
// cross-source continuation only ever fires on a STRONG match
// (same normalised title + EXACT episode number). Anything
// unparseable yields null and never takes part in matching —
// never guessed, never a neighbour episode standing in for the
// missing one.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/video/video_models.dart';

VideoDetail detail(
  dynamic source,
  String vodId,
  List<PlayLine> lines,
) =>
    VideoDetail(
      source: source,
      vodId: vodId,
      meta: VideoMeta(name: '狂飙'),
      lines: lines,
    );

void main() {
  group('parseEpisodeNumber', () {
    test('第N集 / 第0N集', () {
      expect(parseEpisodeNumber('第1集'), 1);
      expect(parseEpisodeNumber('第01集'), 1);
      expect(parseEpisodeNumber('第12集'), 12);
      expect(parseEpisodeNumber('第001集'), 1);
      expect(parseEpisodeNumber('第12话'), 12);
      expect(parseEpisodeNumber('第1集上'), 1);
    });

    test('bare digits (whole name only)', () {
      expect(parseEpisodeNumber('01'), 1);
      expect(parseEpisodeNumber('1'), 1);
      expect(parseEpisodeNumber('001'), 1);
      expect(parseEpisodeNumber('12'), 12);
      expect(parseEpisodeNumber('01集'), 1);
    });

    test('E / EP markers incl. S02E05', () {
      expect(parseEpisodeNumber('E05'), 5);
      expect(parseEpisodeNumber('EP12'), 12);
      expect(parseEpisodeNumber('e3'), 3);
      expect(parseEpisodeNumber('S02E05'), 5);
    });

    test('unparseable yields null — never guessed', () {
      expect(parseEpisodeNumber('正片'), isNull);
      expect(parseEpisodeNumber('预告'), isNull);
      expect(parseEpisodeNumber(''), isNull);
      expect(parseEpisodeNumber('2024'), isNull);
      expect(parseEpisodeNumber('1080P'), isNull);
      expect(parseEpisodeNumber('第0集'), isNull);
      expect(parseEpisodeNumber('第2024集'), isNull);
      expect(parseEpisodeNumber('第1001集'), isNull);
      // A bare number with other text is not a bare-number name.
      expect(parseEpisodeNumber('第1集 1080P'), 1);
      expect(parseEpisodeNumber('花絮01'), isNull);
    });

    test('PlayEpisode.episodeNumber follows the name', () {
      expect(
        const PlayEpisode(name: '第5集', url: 'u').episodeNumber,
        5,
      );
      expect(
        const PlayEpisode(name: '正片', url: 'u').episodeNumber,
        isNull,
      );
    });
  });

  group('findEpisodeByNumber', () {
    test('exact number across lines, name format ignored', () {
      final lines = [
        const PlayLine(name: '线路1', episodes: [
          PlayEpisode(name: '第1集', url: 'a1'),
          PlayEpisode(name: '第2集', url: 'a2'),
        ]),
        const PlayLine(name: '线路2', episodes: [
          PlayEpisode(name: '01', url: 'b1'),
          PlayEpisode(name: '02', url: 'b2'),
        ]),
      ];
      expect(findEpisodeByNumber(lines, 2), (lineIdx: 0, epIdx: 1));
      expect(findEpisodeByNumber(lines, 99), isNull);
    });

    test('unparseable episodes never match', () {
      final lines = [
        const PlayLine(name: '线路1', episodes: [
          PlayEpisode(name: '正片', url: 'a1'),
        ]),
      ];
      expect(findEpisodeByNumber(lines, 1), isNull);
    });
  });

  group('buildEpisodeUnion / missingEpisodeNumbers', () {
    test('base missing ep5, alt has it; base wins ties', () {
      final base = detail(12, 'v1', [
        const PlayLine(name: '线路1', episodes: [
          PlayEpisode(name: '第1集', url: 'a1'),
          PlayEpisode(name: '第2集', url: 'a2'),
          PlayEpisode(name: '第3集', url: 'a3'),
          PlayEpisode(name: '第4集', url: 'a4'),
        ]),
      ]);
      final alt = detail(13, 'v2', [
        const PlayLine(name: '线路1', episodes: [
          PlayEpisode(name: '01', url: 'b1'),
          PlayEpisode(name: '02', url: 'b2'),
          PlayEpisode(name: '03', url: 'b3'),
          PlayEpisode(name: '04', url: 'b4'),
          PlayEpisode(name: '05', url: 'b5'),
          PlayEpisode(name: '06', url: 'b6'),
        ]),
      ]);
      final union = buildEpisodeUnion(base: base, alts: [alt]);
      expect(union.keys.toList()..sort(), [1, 2, 3, 4, 5, 6]);
      // Base wins the shared numbers.
      expect(union[1]!.inBase, isTrue);
      expect(union[1]!.source.toString(), '12');
      // Alt-only numbers are the missing ones.
      expect(union[5]!.inBase, isFalse);
      expect(union[5]!.source.toString(), '13');
      expect(union[5]!.vodId, 'v2');
      expect(missingEpisodeNumbers(union), [5, 6]);
    });

    test('unparseable episodes are excluded from the union', () {
      final base = detail(12, 'v1', [
        const PlayLine(name: '线路1', episodes: [
          PlayEpisode(name: '第1集', url: 'a1'),
          PlayEpisode(name: '正片', url: 'a2'),
        ]),
      ]);
      final union = buildEpisodeUnion(base: base, alts: const []);
      expect(union.keys.toList(), [1]);
      expect(missingEpisodeNumbers(union), isEmpty);
    });

    test('no alt has the number: no invented episodes', () {
      final base = detail(12, 'v1', [
        const PlayLine(name: '线路1', episodes: [
          PlayEpisode(name: '第1集', url: 'a1'),
        ]),
      ]);
      final union = buildEpisodeUnion(base: base, alts: const []);
      expect(missingEpisodeNumbers(union), isEmpty);
      expect(union.containsKey(2), isFalse);
    });

    test('PlayEpisode.isMissing round-trips through JSON', () {
      const ep = PlayEpisode(name: '第5集', url: '', isMissing: true);
      final back = PlayEpisode.fromJson(ep.toJson());
      expect(back.isMissing, isTrue);
      expect(back.episodeNumber, 5);
      expect(
        const PlayEpisode(name: '第1集', url: 'u').toJson().containsKey('isMissing'),
        isFalse,
      );
    });
  });
}
