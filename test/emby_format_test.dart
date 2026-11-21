// Emby high-spec format tests (build 28, task E).
//
// Kernel side: MKV format + container/codec facts gate + candidate
// order + iOS hwdec property. Emby side: MediaSources -> facts ->
// marked stream URL. Hermetic: no network, no native player.
//
// Fixture apiKey is FAKE ('test-key-123'), never a real credential.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/core/player/kernel/mpv_properties.dart';
import 'package:standalone/core/player/kernel/player_engine.dart';
import 'package:standalone/core/player/kernel/player_kernel.dart';
import 'package:standalone/services/video/emby_client.dart';
import 'package:standalone/services/video/emby_models.dart';

const _config = EmbyServerConfig(
  baseUrl: 'http://127.0.0.1:8096',
  apiKey: 'test-key-123',
  userId: 'user-1',
);

/// Emby direct-stream URL with fact markers (as EmbyClient builds
/// it), for a 4K HEVC MKV with TrueHD default audio + Dolby Vision.
const _mkvUrl =
    'http://127.0.0.1:8096/emby/Videos/m1/stream?static=true'
    '&api_key=test-key-123'
    '&hao_container=mkv&hao_vcodec=hevc&hao_acodec=truehd&hao_dv=1';

/// Same shape, but an MP4 with HEVC video + AAC audio (plays
/// everywhere, AVPlayer included).
const _mp4HevcUrl =
    'http://127.0.0.1:8096/emby/Videos/m2/stream?static=true'
    '&api_key=test-key-123'
    '&hao_container=mp4&hao_vcodec=hevc&hao_acodec=aac';

void main() {
  group('StreamFormat.mkv', () {
    test('.mkv suffix and declared mkv resolve to mkv', () {
      expect(formatOf(url: 'https://cdn.example.com/film.mkv'),
          StreamFormat.mkv);
      expect(
        formatOf(url: 'https://cdn.example.com/stream', declaredFormat: 'mkv'),
        StreamFormat.mkv,
      );
      // Unchanged: mp4 / flv / hls keep their old answers.
      expect(formatOf(url: 'https://cdn.example.com/film.mp4'),
          StreamFormat.mp4);
      expect(formatOf(url: 'https://cdn.example.com/live.flv'),
          StreamFormat.flv);
      expect(formatOf(url: 'https://cdn.example.com/live.m3u8'),
          StreamFormat.hls);
    });

    test('capability table: ffmpeg kernels have mkv, AVPlayer does not',
        () {
      expect(kSupportedFormats[PlayerEngine.mediaKit]!.contains(
          StreamFormat.mkv), isTrue);
      expect(
          kSupportedFormats[PlayerEngine.fijk]!.contains(StreamFormat.mkv),
          isTrue);
      expect(
          kSupportedFormats[PlayerEngine.exo]!.contains(StreamFormat.mkv),
          isFalse);
      expect(engineCanPlay(PlayerEngine.exo, StreamFormat.mkv), isFalse);
      expect(engineCanPlay(PlayerEngine.mediaKit, StreamFormat.mkv),
          isTrue);
    });
  });

  group('streamFactsOf / engineCanPlayFacts', () {
    test('parses hao_* markers, null when absent', () {
      final facts = streamFactsOf(_mkvUrl);
      expect(facts, isNotNull);
      expect(facts!.container, 'mkv');
      expect(facts.videoCodec, 'hevc');
      expect(facts.audioCodec, 'truehd');
      expect(facts.dolbyVision, isTrue);
      expect(streamFactsOf('https://cdn.example.com/film.mp4'), isNull);
      expect(streamFactsOf(_mp4HevcUrl)?.dolbyVision, isFalse);
    });

    test('AVPlayer is excluded for mkv / TrueHD / DTS / DV / AV1', () {
      const ffmpegOnly = [
        StreamFacts(container: 'mkv'),
        StreamFacts(container: 'mp4', audioCodec: 'truehd'),
        StreamFacts(container: 'mp4', audioCodec: 'dts'),
        StreamFacts(container: 'mp4', audioCodec: 'dtshd'),
        StreamFacts(container: 'mp4', dolbyVision: true),
        StreamFacts(container: 'mp4', videoCodec: 'av1'),
        StreamFacts(container: 'avi'),
      ];
      for (final facts in ffmpegOnly) {
        expect(engineCanPlayFacts(PlayerEngine.exo, facts), isFalse,
            reason: 'exo must refuse $facts');
        expect(engineCanPlayFacts(PlayerEngine.mediaKit, facts), isTrue);
        expect(engineCanPlayFacts(PlayerEngine.fijk, facts), isTrue);
      }
    });

    test('AVPlayer stays allowed for MP4 HEVC/HDR10 + AAC', () {
      expect(
        engineCanPlayFacts(
          PlayerEngine.exo,
          const StreamFacts(
            container: 'mp4',
            videoCodec: 'hevc',
            audioCodec: 'aac',
          ),
        ),
        isTrue,
      );
      expect(
        engineCanPlayFacts(
          PlayerEngine.exo,
          const StreamFacts(container: 'mov', videoCodec: 'h264'),
        ),
        isTrue,
      );
    });
  });

  group('candidatesFor with facts', () {
    test('MKV URL with preferred AVPlayer goes MPV first, AVPlayer out',
        () {
      final c = candidatesFor(
        url: _mkvUrl,
        isLive: false,
        preferred: PlayerEngine.exo,
      );
      expect(c, [PlayerEngine.mediaKit, PlayerEngine.fijk]);
    });

    test('MP4 HEVC URL with preferred AVPlayer keeps AVPlayer first', () {
      final c = candidatesFor(
        url: _mp4HevcUrl,
        isLive: false,
        preferred: PlayerEngine.exo,
      );
      expect(c.first, PlayerEngine.exo);
      expect(c, contains(PlayerEngine.mediaKit));
    });

    test('unmarked URL keeps the old order (preferred AVPlayer first)',
        () {
      final c = candidatesFor(
        url: 'http://127.0.0.1:8096/emby/Videos/m3/stream?static=true'
            '&api_key=test-key-123',
        isLive: false,
        preferred: PlayerEngine.exo,
      );
      expect(c.first, PlayerEngine.exo);
    });

    test('.mkv suffix URL excludes AVPlayer even without markers', () {
      final c = candidatesFor(
        url: 'https://cdn.example.com/film.mkv',
        isLive: false,
        preferred: PlayerEngine.exo,
      );
      expect(c, isNot(contains(PlayerEngine.exo)));
      expect(c.first, PlayerEngine.mediaKit);
    });

    test('fallback chain is preserved: MPV then IJK', () {
      final c = candidatesFor(
        url: _mkvUrl,
        isLive: false,
        preferred: PlayerEngine.mediaKit,
      );
      expect(c, [PlayerEngine.mediaKit, PlayerEngine.fijk]);
    });
  });

  group('mpvPlatformHwdec', () {
    test('iOS gets videotoolbox, other platforms get nothing', () {
      expect(
        mpvPlatformHwdec(isIOS: true),
        {'hwdec': 'videotoolbox'},
      );
      expect(mpvPlatformHwdec(isIOS: false), isEmpty);
    });
  });

  group('EmbyStreamFacts.fromMediaSources', () {
    test('mkv + hevc + TrueHD default + Dolby Vision', () {
      final facts = EmbyStreamFacts.fromMediaSources([
        {
          'Container': 'mkv',
          'MediaStreams': [
            {
              'Type': 'Video',
              'Codec': 'hevc',
              'VideoRangeType': 'DOLBYVISION',
            },
            {'Type': 'Audio', 'Codec': 'truehd', 'IsDefault': true},
            {'Type': 'Audio', 'Codec': 'aac'},
            {'Type': 'Subtitle', 'Codec': 'ass', 'Language': 'chi'},
          ],
        },
      ]);
      expect(facts.container, 'mkv');
      expect(facts.videoCodec, 'hevc');
      expect(facts.audioCodec, 'truehd');
      expect(facts.dolbyVision, isTrue);
      expect(
        facts.toQueryParams(),
        {
          'hao_container': 'mkv',
          'hao_vcodec': 'hevc',
          'hao_acodec': 'truehd',
          'hao_dv': '1',
        },
      );
    });

    test('default audio wins over a non-default TrueHD track', () {
      final facts = EmbyStreamFacts.fromMediaSources([
        {
          'Container': 'mp4',
          'MediaStreams': [
            {'Type': 'Video', 'Codec': 'h264'},
            {'Type': 'Audio', 'Codec': 'truehd'},
            {'Type': 'Audio', 'Codec': 'aac', 'IsDefault': true},
          ],
        },
      ]);
      expect(facts.audioCodec, 'aac');
      expect(facts.dolbyVision, isFalse);
    });

    test('missing MediaSources => empty facts, no markers', () {
      expect(EmbyStreamFacts.fromMediaSources(null).isEmpty, isTrue);
      expect(EmbyStreamFacts.fromMediaSources([]).isEmpty, isTrue);
      expect(
        const EmbyStreamFacts().toQueryParams(),
        isEmpty,
      );
    });
  });

  group('EmbyClient streamUrl with facts', () {
    test('detail() tags the movie stream URL; no facts => unmarked', () async {
      Future<EmbyResponse> fetcher(
        String url, {
        Map<String, String>? headers,
        Duration timeout = const Duration(seconds: 8),
        CancelToken? cancelToken,
      }) async {
        if (url.contains('/Items/movie-1')) {
          return EmbyResponse(statusCode: 200, json: {
            'Id': 'movie-1',
            'Name': 'Film',
            'Type': 'Movie',
            'MediaSources': [
              {
                'Container': 'mkv',
                'MediaStreams': [
                  {
                    'Type': 'Video',
                    'Codec': 'hevc',
                    'VideoRangeType': 'DOLBYVISION',
                  },
                  {'Type': 'Audio', 'Codec': 'truehd', 'IsDefault': true},
                ],
              },
            ],
          });
        }
        if (url.contains('/Items/movie-2')) {
          return const EmbyResponse(statusCode: 200, json: {
            'Id': 'movie-2',
            'Name': 'Plain',
            'Type': 'Movie',
          });
        }
        return const EmbyResponse(statusCode: 404, json: {});
      }

      // Dio CancelToken: the fetcher signature must match EmbyFetcher.
      final client = EmbyClient(config: _config, fetcher: fetcher);
      final tagged = await client.detail('movie-1');
      final taggedUrl = tagged.lines.first.episodes.first.url;
      expect(taggedUrl, contains('hao_container=mkv'));
      expect(taggedUrl, contains('hao_vcodec=hevc'));
      expect(taggedUrl, contains('hao_acodec=truehd'));
      expect(taggedUrl, contains('hao_dv=1'));
      // And the kernel reads the tag back: AVPlayer is out.
      expect(
        candidatesFor(url: taggedUrl, isLive: false,
            preferred: PlayerEngine.exo),
        [PlayerEngine.mediaKit, PlayerEngine.fijk],
      );

      final plain = await client.detail('movie-2');
      final plainUrl = plain.lines.first.episodes.first.url;
      expect(plainUrl, isNot(contains('hao_')));
      expect(plainUrl, contains('static=true'));
    });
  });
}
