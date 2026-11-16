// Foundation unit tests — pure-Dart rules that must never regress:
//
// - Semver compare is NUMERIC (1.0.10 beats 1.0.9, fix 8).
// - Declared format wins over URL suffix; unknown excludes nothing.
// - FLV is never offered to AVPlayer; preferred capable engine first.
// - Huya line identity is by URL (CDN + path), not index (study §2.9).

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/app/consts.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/player/kernel/player_kernel.dart';

void main() {
  group('compareSemver (fix 8)', () {
    test('numeric, not lexicographic', () {
      expect(compareSemver('1.0.10', '1.0.9'), greaterThan(0));
      expect(compareSemver('1.0.9', '1.0.10'), lessThan(0));
    });
    test('equal is not newer', () {
      expect(compareSemver('1.0.4', '1.0.4'), 0);
      expect(isNewerVersion('1.0.4', '1.0.4'), isFalse);
    });
    test('missing parts count as 0', () {
      expect(compareSemver('1.0', '1.0.0'), 0);
      expect(isNewerVersion('1.0.5', '1.0.4'), isTrue);
    });
    test('non-numeric falls back without throwing', () {
      expect(() => compareSemver('1.0.x', '1.0.4'), returnsNormally);
    });
  });

  group('formatOf (fix 18)', () {
    test('declared format wins over URL suffix', () {
      expect(
        formatOf(url: 'https://cdn.example.com/stream.mp4', declaredFormat: 'flv'),
        StreamFormat.flv,
      );
      expect(
        formatOf(url: 'https://cdn.example.com/stream', declaredFormat: 'hls'),
        StreamFormat.hls,
      );
    });
    test('URL suffix fallback', () {
      expect(formatOf(url: 'https://x/y.flv?token=1'), StreamFormat.flv);
      expect(formatOf(url: 'https://x/y.m3u8'), StreamFormat.hls);
      expect(formatOf(url: 'https://x/y.mp4'), StreamFormat.mp4);
    });
    test('unknown excludes nothing', () {
      expect(formatOf(url: 'https://x/stream'), StreamFormat.unknown);
      expect(engineCanPlay(PlayerEngine.exo, StreamFormat.unknown), isTrue);
    });
  });

  group('candidatesFor (fix 18)', () {
    test('FLV never goes to AVPlayer, even when preferred', () {
      final c = candidatesFor(
        url: 'https://x/live.flv',
        isLive: true,
        preferred: PlayerEngine.exo,
      );
      expect(c, contains(PlayerEngine.mediaKit));
      expect(c, contains(PlayerEngine.fijk));
      expect(c, isNot(contains(PlayerEngine.exo)));
      expect(c.first, PlayerEngine.mediaKit);
    });
    test('HLS: preferred engine first among capable', () {
      final c = candidatesFor(
        url: 'https://x/live.m3u8',
        isLive: true,
        preferred: PlayerEngine.exo,
      );
      expect(c.first, PlayerEngine.exo);
      expect(c, contains(PlayerEngine.mediaKit));
    });
    test('default preferred is MPV', () {
      final c = candidatesFor(url: 'https://x/live.flv', isLive: true);
      expect(c.first, PlayerEngine.mediaKit);
    });
  });
}
