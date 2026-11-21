// 1.1.6 换源链路 — CmsClient.altDetailsStream (mock fetcher).
//
// Pins: the detail race keeps only the FIRST usable detail, but
// the multi-source episode union needs the OTHER sources' episode
// lists too. altDetailsStream retains them — each alt's parsed
// detail yielded the moment it is fetched, a dead alt skipped
// silently instead of failing the stream.

import 'package:dio/dio.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/features/video/video_models.dart';
import 'package:standalone/services/video/cms_client.dart';

VideoSource source(int id, String host) => VideoSource(
      id: id,
      name: '源$id',
      apiUrl: 'http://$host/api.php/provide/vod',
      kind: 'play',
      sort: id,
    );

Map<String, dynamic> searchDoc(List<Map<String, dynamic>> list) =>
    {'list': list};

Map<String, dynamic> detailDoc({
  required String name,
  required String year,
  required String playFrom,
  required String playUrl,
}) =>
    {
      'list': [
        {
          'vod_id': 'v',
          'vod_name': name,
          'vod_year': year,
          'vod_play_from': playFrom,
          'vod_play_url': playUrl,
          'vod_pic': '',
          'vod_content': '',
        },
      ],
    };

void main() {
  group('altDetailsStream', () {
    test('yields each alt detail; dead alt skipped', () async {
      Future<Map<String, dynamic>> fetcher(
        String url, {
        Duration timeout = const Duration(seconds: 8),
        CancelToken? cancelToken,
      }) async {
        if (url.contains('ac=videolist&wd=')) {
          // Search: every source carries the same title.
          return searchDoc([
            {'vod_id': 'v1', 'vod_name': '狂飙', 'vod_year': '2023'},
          ]);
        }
        if (url.contains('ids=v1')) {
          // Detail per source host: different episode counts.
          if (url.contains('s12.example.com')) {
            return detailDoc(
              name: '狂飙',
              year: '2023',
              playFrom: '线路1',
              playUrl: '第1集\$http://cdn/a1.mp4#第2集\$http://cdn/a2.mp4',
            );
          }
          if (url.contains('s13.example.com')) {
            return detailDoc(
              name: '狂飙',
              year: '2023',
              playFrom: '线路1',
              playUrl:
                  '01\$http://cdn/b1.mp4#02\$http://cdn/b2.mp4#03\$http://cdn/b3.mp4',
            );
          }
          // s14: detail fetch fails (dead alt).
          throw CmsException('boom');
        }
        return {'list': []};
      }

      final client = CmsClient(
        sources: [source(12, 's12.example.com'), source(13, 's13.example.com'), source(14, 's14.example.com')],
        fetcher: fetcher,
      );
      final details = await client
          .altDetailsStream('狂飙', '2023', 99)
          .toList();
      expect(details.length, 2);
      expect(details[0].lines.first.episodes.length, 2);
      expect(details[1].lines.first.episodes.length, 3);
      // The union built from these is what the episode list needs:
      // base (12) has 1–2, alt (13) adds 3.
      final union = buildEpisodeUnion(base: details[0], alts: [details[1]]);
      expect(missingEpisodeNumbers(union), [3]);
    });

    test('no alt matches => empty stream', () async {
      Future<Map<String, dynamic>> fetcher(
        String url, {
        Duration timeout = const Duration(seconds: 8),
        CancelToken? cancelToken,
      }) async =>
          {'list': []};
      final client = CmsClient(
        sources: [source(12, 's12.example.com')],
        fetcher: fetcher,
      );
      final details = await client
          .altDetailsStream('不存在的片', '2023', 99)
          .toList();
      expect(details, isEmpty);
    });
  });
}
