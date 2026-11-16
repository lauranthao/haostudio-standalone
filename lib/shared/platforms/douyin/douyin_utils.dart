// Douyin request signing helpers — port of Pure Live 3.x
// lib/shared/platforms/douyin/douyin_utils.dart (buildRequestUrl +
// getMSToken only).
//
// `getTtwidWebid` is NOT ported: it needs Pure Live's HttpClient and the
// RENDER_DATA user id, neither of which this adapter uses — the cookie
// warm-up lives in DouyinSite.getRequestHeaders / DouyinDanmaku instead.

import 'dart:math';

import 'abogus.dart';
import 'douyin_request_params.dart';

class DouyinUtils {
  DouyinUtils._();

  /// Random msToken (184 chars, upstream default).
  static String getMSToken({int randomLength = 184}) {
    if (randomLength < 0) {
      throw ArgumentError.value(randomLength, 'randomLength');
    }
    const baseStr =
        'ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789=';
    final random = Random.secure();
    final sb = StringBuffer();
    for (var i = 0; i < randomLength; i++) {
      sb.write(baseStr[random.nextInt(baseStr.length)]);
    }
    return sb.toString();
  }

  /// Signs [baseUrl]+[params] with A-Bogus and returns the full request
  /// URL. Adds aid/compress/device_platform/browser_* and a fresh msToken
  /// when the caller did not supply one, exactly as upstream.
  static String buildRequestUrl(String baseUrl, Map<String, dynamic> params) {
    final abogus = ABogus(userAgent: DouyinRequestParams.kDefaultUserAgent);
    final parsedUrl = Uri.parse(baseUrl);
    final exParams = <String, dynamic>{
      ...parsedUrl.queryParameters,
      ...params,
    };
    exParams['aid'] = DouyinRequestParams.aidValue;
    exParams['compress'] = 'gzip';
    exParams['device_platform'] = 'web';
    exParams['browser_language'] = 'zh-CN';
    exParams['browser_platform'] = 'Win32';
    exParams['browser_name'] = 'Edge';
    exParams['browser_version'] = '125.0.0.0';
    if (!exParams.containsKey('msToken')) {
      exParams['msToken'] = getMSToken();
    }
    final newQueryStr = Uri(queryParameters: exParams).query;
    final signedQueryStr = abogus.generateAbogus(newQueryStr).first;
    final newUrl = parsedUrl.replace(query: signedQueryStr);
    return newUrl.toString();
  }
}
