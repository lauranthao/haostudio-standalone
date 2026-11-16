// Douyu signing utilities — anonymous-only port of Pure Live 3.x
// lib/core/network/douyu_utils.dart (651 lines).
//
// What is ported:
// - The MD5 play-URL signer (buildSignedData / sign): the encryption
//   descriptor comes from GET .../websec/getEncryption?did=<did>, is
//   cached for 5 minutes, and the signed form body is built from it
//   (auth = md5 chain over rand_str/key, salted with roomId+timestamp).
// - requestHeaders / cookieHeader: a process-local random DID sent as
//   `dy_did` + `acf_did`. The same DID must appear in the cookie, the
//   signed query and the descriptor fetch — Douyu rejects a signature
//   presented by another device.
//
// What is NOT ported (no account store exists in this project):
// - The account-cookie / session / renewal machinery (dy_auth,
//   acf_jwt_token, LTP0, passport safeAuth, DouyuSessionState). This
//   adapter is anonymous-only; anonymous H5 play is downgraded by the
//   server when it must be, and resolvePlayUrls reports the confirmed
//   rate instead of the requested one.
//
// Test seams: the Dio is injectable; buildSignedData and
// isEncryptionKeyUsable are pure statics with deterministic vectors
// (see test/douyu_test.dart).

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';
import 'package:dio/dio.dart';

import '../../../core/network/http_client.dart';

class DouyuUtils {
  DouyuUtils({Dio? dio, String? deviceId})
    : _dio = dio ?? sharedDio(),
      _deviceId = deviceId ?? generateDeviceId();

  static const String defaultDeviceId = '10000000000000000000000000001501';

  static const String userAgent =
      'Mozilla/5.0 (Windows NT 10.0; Win64; x64) '
      'AppleWebKit/537.36 (KHTML, like Gecko) '
      'Chrome/128.0.0.0 Safari/537.36';

  static const String _apiDouyuEnc =
      'https://www.douyu.com/wgapi/livenc/liveweb/websec/getEncryption';
  static const int _expirySafetySeconds = 30;
  static const int _maximumCacheAgeSeconds = 5 * 60;

  final Dio _dio;
  final String _deviceId;

  String get deviceId => _deviceId;

  Map<String, dynamic> _encKey = <String, dynamic>{};
  Future<void>? _encKeyRefresh;
  int? _encKeyFetchedAtSeconds;
  String? _encKeyDeviceId;

  static int _nowSeconds() => DateTime.now().millisecondsSinceEpoch ~/ 1000;

  /// Creates the browser DID used by a single app process (32 hex chars).
  static String generateDeviceId({Random? random}) {
    final source = random ?? Random.secure();
    return List<String>.generate(
      32,
      (_) => source.nextInt(16).toRadixString(16),
    ).join();
  }

  /// Validates the server encryption descriptor using second-based Unix time.
  static bool isEncryptionKeyUsable(
    Map<String, dynamic> value, {
    required int nowSeconds,
    int safetySeconds = _expirySafetySeconds,
  }) {
    final expiresAt = _asInt(value['expire_at']);
    final encTime = _asInt(value['enc_time']);
    return expiresAt != null &&
        expiresAt > nowSeconds + safetySeconds &&
        encTime != null &&
        encTime > 0 &&
        encTime <= 16 &&
        _nonEmpty(value['key']) &&
        _nonEmpty(value['rand_str']) &&
        _nonEmpty(value['enc_data']);
  }

  bool _isCachedEncryptionKeyUsable(int nowSeconds) {
    final fetchedAt = _encKeyFetchedAtSeconds;
    return fetchedAt != null &&
        _encKeyDeviceId == _deviceId &&
        nowSeconds - fetchedAt < _maximumCacheAgeSeconds &&
        isEncryptionKeyUsable(_encKey, nowSeconds: nowSeconds);
  }

  Future<void> _encKeyUpdate({bool forceRefresh = false}) async {
    final nowSeconds = _nowSeconds();
    if (!forceRefresh && _isCachedEncryptionKeyUsable(nowSeconds)) return;

    final activeRefresh = _encKeyRefresh;
    if (activeRefresh != null) {
      await activeRefresh;
      if (_isCachedEncryptionKeyUsable(_nowSeconds())) return;
    }

    final refresh = _fetchEncryptionKey();
    _encKeyRefresh = refresh;
    try {
      await refresh;
    } finally {
      if (identical(_encKeyRefresh, refresh)) _encKeyRefresh = null;
    }
  }

  Future<void> _fetchEncryptionKey() async {
    // The same DID has to be used here, in the signed query and in the
    // request Cookie: Douyu issues the descriptor to a device and rejects
    // a signature presented by another one (a plain 403 from its edge,
    // with no API error).
    final response = await _dio.get<dynamic>(
      _apiDouyuEnc,
      queryParameters: <String, dynamic>{'did': _deviceId},
      options: Options(headers: requestHeaders()),
    );
    final decoded = _decodeJson(response.data);
    final rawData = decoded is Map ? decoded['data'] : null;
    if (rawData is! Map) {
      throw const FormatException('Douyu encryption response is missing data');
    }
    final data = Map<String, dynamic>.from(rawData);
    if (!isEncryptionKeyUsable(data, nowSeconds: _nowSeconds())) {
      throw const FormatException(
        'Douyu encryption descriptor is incomplete or expired',
      );
    }
    _encKey = data;
    _encKeyFetchedAtSeconds = _nowSeconds();
    _encKeyDeviceId = _deviceId;
  }

  Map<String, String> requestHeaders([String roomId = '']) {
    final referer = roomId.isEmpty
        ? 'https://www.douyu.com/'
        : 'https://www.douyu.com/$roomId';
    return <String, String>{
      'accept': 'application/json, text/plain, */*',
      'accept-language': 'zh-CN,zh;q=0.9,en;q=0.7',
      'origin': 'https://www.douyu.com',
      'referer': referer,
      'user-agent': userAgent,
      'cookie': cookieHeader(),
    };
  }

  /// Anonymous-only cookie: just the device id, twice. No account fields
  /// (dy_auth / acf_jwt_token / LTP0) exist in this project.
  String cookieHeader() => 'dy_did=$_deviceId; acf_did=$_deviceId';

  /// Builds the form body from an already validated encryption descriptor.
  /// Deterministic unit-test seam for the platform signing path.
  static String buildSignedData({
    required Map<String, dynamic> encryptionKey,
    required String roomId,
    required int timestampSeconds,
    int rate = -1,
    String cdn = '',
    String deviceId = defaultDeviceId,
  }) {
    if (!isEncryptionKeyUsable(
      encryptionKey,
      nowSeconds: timestampSeconds,
      safetySeconds: 0,
    )) {
      throw const FormatException(
        'Douyu encryption descriptor is incomplete or expired',
      );
    }
    final key = encryptionKey['key'].toString();
    final randStr = encryptionKey['rand_str'].toString();
    final encTime = _asInt(encryptionKey['enc_time'])!;
    final salt = _asInt(encryptionKey['is_special']) == 1
        ? ''
        : '$roomId$timestampSeconds';

    var secret = randStr;
    for (var index = 0; index < encTime; index++) {
      secret = md5.convert(utf8.encode('$secret$key')).toString();
    }
    final auth = md5.convert(utf8.encode('$secret$key$salt')).toString();
    return Uri(
      queryParameters: <String, String>{
        'enc_data': encryptionKey['enc_data'].toString(),
        'tt': timestampSeconds.toString(),
        'did': deviceId,
        'auth': auth,
        'cdn': cdn,
        'rate': rate.toString(),
        'hevc': '0',
        'fa': '0',
        'ive': '0',
        'ver': 'Douyu_new',
        'iar': '0',
      },
    ).query;
  }

  /// Signs a play request: refreshes the cached encryption descriptor
  /// when needed, then builds the form body for [roomId]/[rate]/[cdn].
  Future<String> sign(
    String roomId, {
    int rate = -1,
    String cdn = '',
    bool forceRefresh = false,
  }) async {
    await _encKeyUpdate(forceRefresh: forceRefresh);
    return buildSignedData(
      encryptionKey: _encKey,
      roomId: roomId,
      timestampSeconds: _nowSeconds(),
      rate: rate,
      cdn: cdn,
      deviceId: _deviceId,
    );
  }

  static dynamic _decodeJson(dynamic data) {
    if (data is String) {
      try {
        return json.decode(data);
      } on FormatException {
        return null;
      }
    }
    return data;
  }

  static int? _asInt(dynamic value) {
    if (value is num) return value.toInt();
    return int.tryParse(value?.toString() ?? '');
  }

  static bool _nonEmpty(dynamic value) =>
      value?.toString().trim().isNotEmpty == true;
}
