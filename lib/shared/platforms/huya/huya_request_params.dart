// Huya request params — port of Pure Live 3.x
// lib/shared/platforms/huya/huya_request_params.dart.
//
// The random SDK UA generator (`requestHuyaUA`) feeds the native WUP
// `getCdnTokenInfoEx` calls (see huya_wup.dart).

import 'dart:math';

mixin HuyaRequestParams {
  static const String baseUrl = 'https://www.huya.com';

  static const String kUserAgent =
      'Mozilla/5.0 (Linux; Android 11; Pixel 5) AppleWebKit/537.36 '
      '(KHTML, like Gecko) Chrome/90.0.4430.91 Mobile Safari/537.36 '
      'Edg/117.0.0.0';

  /// Regexes for the room-page HTML scrape (room detail is HTML, not JSON).
  static const String roomDataRegex = r'var\s+TT_ROOM_DATA\s*=\s*(\{[\s\S]*?\})';

  static const String streamRegex = r'stream:\s*(\{[\s\S]*?\n\s*\})';

  static const String hysdkUa =
      'HYSDK(Windows,30000002)_APP(pc_exe&7100004&official)_SDK(trans&2.40.0.6448)';

  /// Randomly generates a Huya SDK UA, e.g. `adr&13.1.0.3456&official&31`.
  ///
  /// Ported from Pure Live (synced from dart_simple_live's
  /// getCdnTokenInfoEx): WUP token requests previously used a fixed
  /// `pc_exe&7060000&official`; a fixed UA is easier for risk control to
  /// recognise, so a random platform / sub-version / API level
  /// combination lowers the chance a signing request is refused.
  static String get requestHuyaUA {
    const platforms = [
      (name: 'adr', version: '13.1.0', hasApiLevel: true),
      (name: 'ios', version: '13.1.0', hasApiLevel: false),
      (name: 'huya_nftv', version: '2.6.10', hasApiLevel: true),
      (name: 'pc_exe', version: '7000000', hasApiLevel: false),
    ];

    final platform = platforms[Random().nextInt(platforms.length)];
    var version = platform.version;

    // Platforms with sub-versions get a random sub-version appended.
    if (platform.name == 'adr' || platform.name == 'huya_nftv') {
      version = '$version.${Random().nextInt(2000) + 3000}';
    }

    var ua = '${platform.name}&$version&official';

    // Append an Android API level (28-36).
    if (platform.hasApiLevel) {
      ua = '$ua&${Random().nextInt(9) + 28}';
    }

    return ua;
  }

  static Map<String, String> get requestHeaders {
    return {'Origin': baseUrl, 'Referer': baseUrl, 'User-Agent': hysdkUa};
  }
}
