// PlaybackHeaderResolver unit tests — Pure Live
// lib/domains/live/data/playback_header_resolver.dart.
//
// Locks the exact header sets PL sends for Huya/Douyu playback.
// The room-level tests (live_quality_line_test.dart) prove the room
// passes these headers to every session open; this file proves the
// mapping itself, including the Douyu cookie the widget tests cannot
// cover (their fake site is not a real DouyuSite).
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/domains/live/data/playback_header_resolver.dart';
import 'package:standalone/shared/platforms/douyu/douyu_utils.dart';
import 'package:standalone/shared/platforms/huya/huya_request_params.dart';

void main() {
  group('PlaybackHeaderResolver', () {
    test('huya: HYSDK UA + origin + room referer', () {
      final headers = PlaybackHeaderResolver.resolve(
        platform: 'huya',
        roomId: '660000',
      );
      expect(headers['user-agent'], HuyaRequestParams.hysdkUa);
      expect(headers['origin'], 'https://www.huya.com');
      expect(headers['referer'], 'https://www.huya.com/660000');
    });

    test('huya: empty room id falls back to the site referer', () {
      final headers = PlaybackHeaderResolver.resolve(platform: 'huya');
      expect(headers['referer'], 'https://www.huya.com/');
    });

    test('douyu: origin + room referer + UA + cookie', () {
      const cookie = 'dy_did=123; acf_did=123';
      final headers = PlaybackHeaderResolver.resolve(
        platform: 'douyu',
        roomId: '226037',
        douyuCookie: cookie,
      );
      expect(headers['origin'], 'https://www.douyu.com');
      expect(headers['referer'], 'https://www.douyu.com/226037');
      expect(headers['user-agent'], DouyuUtils.userAgent);
      expect(headers['cookie'], cookie);
    });

    test('douyu: no cookie passed means no cookie header', () {
      final headers = PlaybackHeaderResolver.resolve(
        platform: 'douyu',
        roomId: '226037',
      );
      expect(headers.containsKey('cookie'), isFalse);
      expect(headers['origin'], 'https://www.douyu.com');
    });

    test('unknown platform: no headers, same as PL default branch', () {
      expect(
        PlaybackHeaderResolver.resolve(
          platform: 'bilibili',
          roomId: '1',
        ),
        isEmpty,
      );
    });

    test('platform matching is case-insensitive and trims', () {
      final headers = PlaybackHeaderResolver.resolve(
        platform: ' Huya ',
        roomId: '660000',
      );
      expect(headers['origin'], 'https://www.huya.com');
    });
  });
}
