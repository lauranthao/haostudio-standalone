// Douyu duplicate `expire` parsing.
//
// A Douyu play URL can carry `expire` twice: the server-issued value
// first (`expire=300` on ws lines) and the `&expire=0` appended by
// _resolvePlayUrl after it. Dart's Uri.queryParameters keeps the LAST
// value, so the lease parsed as null for every ws line and no
// refreshAt/invalidAt was ever computed. Parsing now takes the FIRST
// occurrence — the value the server signed/issued.
//
// Pure-Dart unit tests, no network. Huya's lease parsing is untouched
// by the fix; its signature bound is pinned below as the brother case.

import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/shared/platforms/douyu/douyu_site.dart';
import 'package:standalone/shared/platforms/huya/huya_anti_code.dart';

void main() {
  group('DouyuSite duplicate expire (lease)', () {
    final issuedAt = DateTime.utc(2026, 11, 16, 12, 0, 0);

    test('duplicate expire: first (server-issued) value wins', () {
      const url =
          'https://ws.play.douyucdn.cn/live/1.flv?wsSecret=x&wsTime=y'
          '&expire=300&fcdn=ws&expire=0';
      expect(DouyuSite.douyuUrlExpireSeconds(url), 300);
      expect(
        DouyuSite.douyuPlayUrlInvalidAt(url, issuedAt),
        issuedAt.add(const Duration(seconds: 300)),
      );
      expect(
        DouyuSite.douyuPlayUrlRefreshAt(url, issuedAt),
        issuedAt.add(const Duration(seconds: 255)),
      );
    });

    test('duplicate expire later in the query still reads the first', () {
      const url =
          'https://ws.play.douyucdn.cn/live/1.flv?wsSecret=x'
          '&expire=300&foo=1&expire=0';
      expect(DouyuSite.douyuUrlExpireSeconds(url), 300);
    });

    test('single expire=300 unchanged', () {
      const url = 'https://ws.play.douyucdn.cn/live/1.flv?expire=300';
      expect(DouyuSite.douyuUrlExpireSeconds(url), 300);
      expect(
        DouyuSite.douyuPlayUrlInvalidAt(url, issuedAt),
        issuedAt.add(const Duration(seconds: 300)),
      );
    });

    test('single expire=0 is still no lease', () {
      const url = 'https://ws.play.douyucdn.cn/live/1.flv?expire=0';
      expect(DouyuSite.douyuUrlExpireSeconds(url), isNull);
      expect(DouyuSite.douyuPlayUrlInvalidAt(url, issuedAt), isNull);
      expect(DouyuSite.douyuPlayUrlRefreshAt(url, issuedAt), isNull);
    });

    test('first expire=0 wins over a later expire=300', () {
      const url =
          'https://ws.play.douyucdn.cn/live/1.flv?expire=0&expire=300';
      expect(DouyuSite.douyuUrlExpireSeconds(url), isNull);
    });

    test('no expire has no lease', () {
      const url = 'https://ws.play.douyucdn.cn/live/1.flv?wsSecret=x';
      expect(DouyuSite.douyuUrlExpireSeconds(url), isNull);
      expect(DouyuSite.douyuPlayUrlInvalidAt(url, issuedAt), isNull);
    });
  });

  group('Huya lease parsing unchanged (brother case)', () {
    test('wsTime + 5 min is still the signature bound', () {
      final issuedAt = DateTime.utc(2026, 11, 16, 12, 0, 0);
      final issuedSeconds = issuedAt.millisecondsSinceEpoch ~/ 1000;
      final wsTimeHex = (issuedSeconds + 120).toRadixString(16);
      final url =
          'https://al.flv.huya.com/src/teststream.flv'
          '?wsSecret=abc&wsTime=$wsTimeHex&seqid=1'
          '&ctype=huya_webh5&ver=1&fs=bgct&t=100';
      expect(
        huyaSignedUrlInvalidAt(url),
        issuedAt.add(const Duration(seconds: 420)),
      );
    });
  });
}
