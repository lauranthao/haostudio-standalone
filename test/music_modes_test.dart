// Five play modes (M-P0-1) — pure queue math + code mapping.
//
// Covers: legacy 'seq'/'shuffle' codes still map, unknown codes fall
// back to sequential, the cycle order, and next/prev behaviour for
// every mode in both auto-advance and manual-tap cases.

import 'dart:math';

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/play_mode.dart';

void main() {
  group('PlayModeX.fromCode', () {
    test('legacy codes keep working', () {
      expect(PlayModeX.fromCode('seq'), PlayMode.sequential);
      expect(PlayModeX.fromCode('shuffle'), PlayMode.shuffle);
    });

    test('new codes map', () {
      expect(PlayModeX.fromCode('loop'), PlayMode.listLoop);
      expect(PlayModeX.fromCode('one'), PlayMode.singleLoop);
      expect(PlayModeX.fromCode('once'), PlayMode.single);
    });

    test('unknown / null falls back to sequential', () {
      expect(PlayModeX.fromCode('bogus'), PlayMode.sequential);
      expect(PlayModeX.fromCode(null), PlayMode.sequential);
      expect(PlayModeX.fromCode(''), PlayMode.sequential);
    });

    test('codes round-trip', () {
      for (final mode in PlayMode.values) {
        expect(PlayModeX.fromCode(mode.code), mode);
      }
    });

    test('all five labels are distinct', () {
      final labels = PlayMode.values.map((m) => m.label).toSet();
      expect(labels.length, 5);
      expect(PlayMode.sequential.label, '顺序播放');
      expect(PlayMode.listLoop.label, '列表循环');
      expect(PlayMode.singleLoop.label, '单曲循环');
      expect(PlayMode.shuffle.label, '随机播放');
      expect(PlayMode.single.label, '单曲播放');
    });
  });

  group('cycle order', () {
    test('seq -> loop -> one -> shuffle -> once -> seq', () {
      expect(
        PlayMode.sequential.next,
        PlayMode.listLoop,
      );
      expect(PlayMode.listLoop.next, PlayMode.singleLoop);
      expect(PlayMode.singleLoop.next, PlayMode.shuffle);
      expect(PlayMode.shuffle.next, PlayMode.single);
      expect(PlayMode.single.next, PlayMode.sequential);
    });

    test('five cycles return to the start', () {
      var mode = PlayMode.sequential;
      for (var i = 0; i < 5; i++) {
        mode = mode.next;
      }
      expect(mode, PlayMode.sequential);
    });
  });

  group('nextTrackIndex auto-advance', () {
    const len = 5;

    test('sequential advances, then stops at the end', () {
      expect(
        nextTrackIndex(PlayMode.sequential, 0, len, auto: true),
        1,
      );
      expect(
        nextTrackIndex(PlayMode.sequential, 3, len, auto: true),
        4,
      );
      expect(
        nextTrackIndex(PlayMode.sequential, 4, len, auto: true),
        -1,
      );
    });

    test('list loop wraps at the end', () {
      expect(
        nextTrackIndex(PlayMode.listLoop, 4, len, auto: true),
        0,
      );
      expect(
        nextTrackIndex(PlayMode.listLoop, 2, len, auto: true),
        3,
      );
    });

    test('single loop replays the same song', () {
      for (var i = 0; i < len; i++) {
        expect(
          nextTrackIndex(PlayMode.singleLoop, i, len, auto: true),
          i,
        );
      }
    });

    test('shuffle picks a different track', () {
      final rng = Random(42);
      for (var i = 0; i < 20; i++) {
        final n = nextTrackIndex(
          PlayMode.shuffle,
          2,
          len,
          auto: true,
          random: rng,
        );
        expect(n, isNot(2));
        expect(n, inInclusiveRange(0, len - 1));
      }
    });

    test('single play stops after the current song', () {
      expect(
        nextTrackIndex(PlayMode.single, 0, len, auto: true),
        -1,
      );
      expect(
        nextTrackIndex(PlayMode.single, 4, len, auto: true),
        -1,
      );
    });
  });

  group('nextTrackIndex manual tap', () {
    const len = 5;

    test('manual next still advances in single play', () {
      expect(
        nextTrackIndex(PlayMode.single, 0, len, auto: false),
        1,
      );
      expect(
        nextTrackIndex(PlayMode.single, 4, len, auto: false),
        -1,
      );
    });

    test('manual next advances in single loop (wraps)', () {
      expect(
        nextTrackIndex(PlayMode.singleLoop, 2, len, auto: false),
        3,
      );
      expect(
        nextTrackIndex(PlayMode.singleLoop, 4, len, auto: false),
        0,
      );
    });

    test('manual next in sequential stops at the end', () {
      expect(
        nextTrackIndex(PlayMode.sequential, 4, len, auto: false),
        -1,
      );
    });
  });

  group('prevTrackIndex', () {
    const len = 5;

    test('steps back and wraps at the start', () {
      expect(prevTrackIndex(PlayMode.sequential, 2, len), 1);
      expect(prevTrackIndex(PlayMode.sequential, 0, len), 4);
      expect(prevTrackIndex(PlayMode.listLoop, 0, len), 4);
      expect(prevTrackIndex(PlayMode.single, 0, len), 4);
    });

    test('shuffle picks a different track', () {
      final rng = Random(7);
      for (var i = 0; i < 20; i++) {
        final n = prevTrackIndex(
          PlayMode.shuffle,
          1,
          len,
          random: rng,
        );
        expect(n, isNot(1));
        expect(n, inInclusiveRange(0, len - 1));
      }
    });
  });

  group('edge cases', () {
    test('empty queue / bad index returns -1', () {
      expect(nextTrackIndex(PlayMode.sequential, 0, 0, auto: true), -1);
      expect(nextTrackIndex(PlayMode.listLoop, -1, 5, auto: true), -1);
      expect(nextTrackIndex(PlayMode.listLoop, 5, 5, auto: true), -1);
      expect(prevTrackIndex(PlayMode.sequential, 0, 0), -1);
    });

    test('one-song queue: shuffle stays, sequential stops', () {
      expect(nextTrackIndex(PlayMode.shuffle, 0, 1, auto: true), 0);
      expect(nextTrackIndex(PlayMode.sequential, 0, 1, auto: true), -1);
      expect(nextTrackIndex(PlayMode.singleLoop, 0, 1, auto: true), 0);
      expect(prevTrackIndex(PlayMode.shuffle, 0, 1), 0);
    });
  });
}
