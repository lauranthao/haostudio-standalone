// Bilibili WBI signing — port of Pure Live 3.x
// lib/shared/platforms/bilibili/bilibili_site.dart (getWbiKeys /
// getWbiSign / getMixinKey / mixinKeyEncTab).
//
// How it works: GET api.bilibili.com/x/web-interface/nav returns
// `wbi_img.img_url` / `sub_url`; the 32-char file stems are the img/sub
// keys. The mixin key reorders (imgKey + subKey) through the fixed
// 64-entry table and takes the first 32 chars. A request is signed by
// sorting its query params, stripping `!'()*` from values, adding `wts`
// (unix seconds), and appending `w_rid = md5(query + mixinKey)`.
//
// Why it is needed: the unsigned calls to getInfoByRoom, getDanmuInfo
// and second/getList return code -352 on this VM; WBI-signed calls
// return code 0 (verified live 2026-11-16 for rooms 6 / 7734200).
// Keys are cached 6 h and the in-flight nav fetch is shared, as in
// Pure Live.

import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../../core/network/http_client.dart';

class BilibiliWbiSigner {
  BilibiliWbiSigner({Dio? dio}) : _dio = dio ?? sharedDio();

  final Dio _dio;

  static const List<int> mixinKeyEncTab = [
    46,
    47,
    18,
    2,
    53,
    8,
    23,
    32,
    15,
    50,
    10,
    31,
    58,
    3,
    45,
    35,
    27,
    43,
    5,
    49,
    33,
    9,
    42,
    19,
    29,
    28,
    14,
    39,
    12,
    38,
    41,
    13,
    37,
    48,
    7,
    16,
    24,
    55,
    40,
    61,
    26,
    17,
    0,
    1,
    60,
    51,
    30,
    4,
    22,
    25,
    54,
    21,
    56,
    59,
    6,
    63,
    57,
    62,
    11,
    36,
    20,
    34,
    44,
    52,
  ];

  String _imgKey = '';
  String _subKey = '';
  DateTime? _keysUpdatedAt;
  Future<(String, String)>? _keysRequest;

  /// Mixin key: reorder [origin] (imgKey + subKey, 64 chars) through
  /// the table and take the first 32 chars.
  static String getMixinKey(String origin) {
    return mixinKeyEncTab.fold('', (s, i) => s + origin[i]).substring(0, 32);
  }

  /// Pure signing step: sort params, strip `!'()*` from values, add
  /// `wts`, then `w_rid = md5(query + mixinKey)`. [wtsSeconds] is
  /// injectable so the signature is deterministic in tests.
  static Map<String, String> signParams(
    Map<String, String> params,
    String mixinKey, {
    int? wtsSeconds,
  }) {
    final queryParams = Map<String, String>.from(params);
    queryParams['wts'] =
        (wtsSeconds ?? DateTime.now().millisecondsSinceEpoch ~/ 1000)
            .toString();

    final cleaned = <String, String>{};
    final sortedKeys = queryParams.keys.toList()..sort();
    for (final key in sortedKeys) {
      cleaned[key] = queryParams[key]!
          .split('')
          .where((c) => !"!'()*".contains(c))
          .join('');
    }

    final query = cleaned.keys
        .map((key) => '$key=${Uri.encodeQueryComponent(cleaned[key]!)}')
        .join('&');
    queryParams['w_rid'] =
        md5.convert(utf8.encode('$query$mixinKey')).toString();
    return queryParams;
  }

  /// (imgKey, subKey), cached 6 h; concurrent callers share the
  /// in-flight nav fetch.
  Future<(String, String)> getWbiKeys({
    bool forceRefresh = false,
    Map<String, String>? headers,
  }) async {
    final cacheAge =
        _keysUpdatedAt == null
            ? null
            : DateTime.now().difference(_keysUpdatedAt!);
    if (!forceRefresh &&
        _imgKey.isNotEmpty &&
        _subKey.isNotEmpty &&
        cacheAge != null &&
        cacheAge < const Duration(hours: 6)) {
      return (_imgKey, _subKey);
    }

    final pending = _keysRequest;
    if (pending != null) return pending;

    late final Future<(String, String)> operation;
    operation = _fetchWbiKeys(headers: headers).whenComplete(() {
      if (identical(_keysRequest, operation)) _keysRequest = null;
    });
    _keysRequest = operation;
    return operation;
  }

  Future<(String, String)> _fetchWbiKeys({
    Map<String, String>? headers,
  }) async {
    final response = await _dio.get<dynamic>(
      'https://api.bilibili.com/x/web-interface/nav',
      options: Options(headers: headers),
    );
    final body = response.data;
    final data = body is Map ? body['data'] : null;
    final wbiImg = data is Map ? data['wbi_img'] : null;
    final imgUrl = wbiImg is Map ? wbiImg['img_url']?.toString() ?? '' : '';
    final subUrl = wbiImg is Map ? wbiImg['sub_url']?.toString() ?? '' : '';
    if (imgUrl.isEmpty || subUrl.isEmpty) {
      throw const FormatException(
        'Bilibili WBI keys missing from nav response',
      );
    }
    final imgKey = imgUrl.substring(imgUrl.lastIndexOf('/') + 1).split('.').first;
    final subKey = subUrl.substring(subUrl.lastIndexOf('/') + 1).split('.').first;

    _imgKey = imgKey;
    _subKey = subKey;
    _keysUpdatedAt = DateTime.now();

    return (imgKey, subKey);
  }

  /// Sign a full URL: its query params + `wts` + `w_rid`. Returns the
  /// signed param map — pass it as Dio `queryParameters` against the
  /// bare base URL (no query string) so Dio encodes it once.
  Future<Map<String, String>> signUrl(
    String url, {
    bool forceRefresh = false,
    Map<String, String>? headers,
  }) async {
    final (imgKey, subKey) = await getWbiKeys(
      forceRefresh: forceRefresh,
      headers: headers,
    );
    final mixinKey = getMixinKey(imgKey + subKey);
    final params = Map<String, String>.from(Uri.parse(url).queryParameters);
    return signParams(params, mixinKey);
  }
}
