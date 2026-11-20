// MpvMusicPlayer unit tests — pure logic only (no native audio):
// the mpv `af` filter chain built from the EQ settings, and the
// platform gate. Native playback itself is verified on the Windows
// CI build / real machine, not here.
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/music/mpv_music_player.dart';

void main() {
  group('MpvMusicPlayer.equalizerAf', () {
    test('disabled returns empty chain', () {
      expect(
        MpvMusicPlayer.equalizerAf(
          enabled: false,
          gains: List.filled(10, 6),
          preamp: 3,
        ),
        '',
      );
    });

    test('enabled but flat returns empty chain', () {
      expect(
        MpvMusicPlayer.equalizerAf(
          enabled: true,
          gains: List.filled(10, 0),
          preamp: 0,
        ),
        '',
      );
    });

    test('non-flat bands become equalizer filters at the right frequencies', () {
      final af = MpvMusicPlayer.equalizerAf(
        enabled: true,
        gains: [6, 0, 0, 0, 0, 0, 0, 0, 0, 0],
        preamp: 0,
      );
      expect(af, 'equalizer=f=31:width_type=o:width=1:g=6');
    });

    test('multiple bands chain with commas, halves keep one decimal', () {
      final af = MpvMusicPlayer.equalizerAf(
        enabled: true,
        gains: [2.5, -1, 0, 0, 0, 0, 0, 0, 0, 4],
        preamp: 0,
      );
      expect(
        af,
        'equalizer=f=31:width_type=o:width=1:g=2.5,'
        'equalizer=f=62:width_type=o:width=1:g=-1,'
        'equalizer=f=16000:width_type=o:width=1:g=4',
      );
    });

    test('preamp becomes a linear volume filter (dB -> 10^(dB/20))', () {
      // +6 dB preamp ≈ 2x linear.
      final af = MpvMusicPlayer.equalizerAf(
        enabled: true,
        gains: List.filled(10, 0),
        preamp: 6,
      );
      expect(af, 'volume=2');
      // -6 dB ≈ 0.5x.
      final af2 = MpvMusicPlayer.equalizerAf(
        enabled: true,
        gains: List.filled(10, 0),
        preamp: -6,
      );
      expect(af2, 'volume=0.5');
    });

    test('bands and preamp combine in one chain', () {
      final af = MpvMusicPlayer.equalizerAf(
        enabled: true,
        gains: [0, 0, 0, 0, 0, 0, 0, 0, 0, 3],
        preamp: 6,
      );
      expect(
        af,
        'equalizer=f=16000:width_type=o:width=1:g=3,volume=2',
      );
    });
  });

  group('MpvMusicPlayer.isSupported', () {
    test('false off Windows (this host is Linux)', () {
      expect(MpvMusicPlayer.isSupported, isFalse);
    });
  });
}
