// Lyrics translation parsing (Beans: NetEase tlyric shown under the
// current line only).
//
// parseLrcWithTranslation matches the translation lines to the main
// lyrics by centisecond timestamp, with a nearest-within-0.5s fallback
// for the small offsets the NetEase tlyric feed sometimes has.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/music_api.dart';

void main() {
  group('parseLrcWithTranslation', () {
    test('exact timestamp match attaches the translation', () {
      const lrc = '[00:10.00]第一句\n[00:25.50]第二句\n[00:40.00]第三句\n';
      const tlyric = '[00:10.00]First line\n[00:25.50]Second line\n';
      final lines = MusicApi.parseLrcWithTranslation(lrc, tlyric);
      expect(lines.length, 3);
      expect(lines[0].translation, 'First line');
      expect(lines[1].translation, 'Second line');
      expect(lines[2].translation, isNull);
    });

    test('translation 0.1s off still matches (nearest within 0.5s)', () {
      const lrc = '[00:25.50]第二句\n';
      const tlyric = '[00:25.60]Second line\n';
      final lines = MusicApi.parseLrcWithTranslation(lrc, tlyric);
      expect(lines.single.translation, 'Second line');
    });

    test('translation more than 0.5s off does not match', () {
      const lrc = '[00:25.50]第二句\n';
      const tlyric = '[00:26.10]Second line\n';
      final lines = MusicApi.parseLrcWithTranslation(lrc, tlyric);
      expect(lines.single.translation, isNull);
    });

    test('null / empty translation leaves plain lines', () {
      const lrc = '[00:10.00]第一句\n';
      expect(
        MusicApi.parseLrcWithTranslation(lrc, null).single.translation,
        isNull,
      );
      expect(
        MusicApi.parseLrcWithTranslation(lrc, '').single.translation,
        isNull,
      );
      expect(
        MusicApi.parseLrcWithTranslation(
          lrc,
          '[00:10.00]  \n',
        ).single.translation,
        isNull,
      );
    });

    test('empty main lyrics returns empty', () {
      expect(MusicApi.parseLrcWithTranslation('', '[00:10.00]x\n'), isEmpty);
    });
  });
}
