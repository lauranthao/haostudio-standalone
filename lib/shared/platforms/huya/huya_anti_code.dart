// Huya anti-code signing + URL lease math — port of the pure functions in
// Pure Live 3.x lib/shared/platforms/huya/huya_site.dart
// (buildAntiCode L969-1044, rotateViewerUid32 / unrotateViewerUid32,
// replaceQueryParameter, secureHuyaCdnBase, getSignedSequenceIssuedAt,
// _signedUrlInvalidAtFromQuery) and the lease constants (refresh ~100 s,
// invalid ~125 s after issue).
//
// All functions here are pure and unit-tested (test/huya_site_test.dart).
// The stateful parts (monotonic seqid millis, remembered transport
// issue times) live in HuyaSite and delegate here.

import 'dart:convert';
import 'dart:math';

import 'package:crypto/crypto.dart';

/// Proactive refresh: transport lease age after which a fresh URL should be
/// prefetched (before the transport dies — do not wait for EOF).
const Duration huyaTransportRefreshAge = Duration(seconds: 100);

/// Hard transport expiry: CDN transport lifetime after issue.
const Duration huyaTransportInvalidAge = Duration(seconds: 125);

/// Signature validity after wsTime: wsTime (hex seconds) + 5 min.
const Duration huyaSignatureValidity = Duration(minutes: 5);

/// Refresh a signature 30 s before its wsTime+5min expiry.
const Duration huyaSignatureRefreshLead = Duration(seconds: 30);

/// Builds the per-open AntiCode for one stream line.
///
/// Decodes the base64 `fm` template, substitutes
/// `$0=rotatedUid, $1=stream, $2=md5("$seqid|$ctype|$platformId"),
/// $3=wsTime`, computes `wsSecret=md5(template)`, and emits
/// `wsSecret/wsTime/seqid(=uid+millis)/ctype/ver/fs/t/u|uid/uuid`
/// (the `fm` template itself is consumed locally and omitted from the URL,
/// as the official web player does).
///
/// * `antiCode` with no `fm` param is returned unchanged (legacy static
///   token — nothing to sign).
/// * Throws [FormatException] when `wsTime` is missing/invalid or the `fm`
///   template lacks any of `$0..$3`; throws [StateError] when
///   `now > wsTime + 5 min` (refuse — never extend wsTime locally).
/// * Pass [now] only in tests; production callers pass the wall clock (or
///   a monotonic-adjusted instant — see HuyaSite).
String buildHuyaAntiCode(
  String stream,
  int viewerUid,
  String antiCode, {
  DateTime? now,
  int fallbackViewerUid = 0,
}) {
  final original = Uri(query: antiCode).queryParameters;
  final encodedFm = original['fm']?.trim() ?? '';
  if (encodedFm.isEmpty) {
    return antiCode;
  }

  final ctype = original['ctype']?.trim().isNotEmpty == true
      ? original['ctype']!.trim()
      : 'huya_webh5';
  final platformId = original['t']?.trim().isNotEmpty == true
      ? original['t']!.trim()
      : '100';
  final isWap = platformId == '103';
  final timestamp = now ?? DateTime.now();
  final currentMillis = timestamp.millisecondsSinceEpoch;
  final currentSeconds = currentMillis ~/ 1000;
  final uid = viewerUid > 0 ? viewerUid : fallbackViewerUid;

  final wsTimeRaw = original['wsTime']?.trim() ?? '';
  final wsTimeSeconds = int.tryParse(wsTimeRaw, radix: 16);
  if (wsTimeSeconds == null) {
    throw const FormatException('Huya AntiCode has no valid wsTime');
  }
  if (currentSeconds > wsTimeSeconds + huyaSignatureValidity.inSeconds) {
    throw StateError('Huya AntiCode lease expired');
  }
  final wsTime = wsTimeRaw.toLowerCase();
  final seqId = uid + currentMillis;
  final secretHash =
      md5.convert(utf8.encode('$seqId|$ctype|$platformId')).toString();

  final convertUid = rotateViewerUid32(uid);
  final calcUid = isWap ? uid : convertUid;
  // Preserve the complete decoded template in place: splitting on `_` and
  // rebuilding a presumed `prefix_$0_$1_$2_$3` layout would silently sign
  // the wrong string if Huya adds a field or moves a placeholder.
  final secretTemplate = utf8.decode(base64.decode(base64.normalize(encodedFm)));
  if (!const <String>[r'$0', r'$1', r'$2', r'$3']
      .every(secretTemplate.contains)) {
    throw const FormatException('Huya AntiCode fm template is incomplete');
  }
  final secretStr = secretTemplate
      .replaceFirst(r'$0', calcUid.toString())
      .replaceFirst(r'$1', stream)
      .replaceFirst(r'$2', secretHash)
      .replaceFirst(r'$3', wsTime);
  final wsSecret = md5.convert(utf8.encode(secretStr)).toString();

  final rnd = Random();
  final ct = ((wsTimeSeconds + rnd.nextDouble()) * 1000).toInt();
  final uuid =
      (((ct % 1e10) + rnd.nextDouble()) * 1e3 % 0xffffffff).toInt().toString();
  final antiCodeRes = <String, String>{...original}
    ..remove('wsSecret')
    ..remove('seqid')
    ..remove('u')
    ..remove('uid')
    ..remove('uuid')
    // `fm` is signing material, not a media query field.
    ..remove('fm')
    ..addAll(<String, String>{
      'wsSecret': wsSecret,
      'wsTime': wsTime,
      'seqid': seqId.toString(),
      'ctype': ctype,
      'ver': '1',
      'fs': original['fs'] ?? 'bgct',
      't': platformId,
    });
  if (isWap) {
    antiCodeRes.addAll({'uid': uid.toString(), 'uuid': uuid});
  } else {
    antiCodeRes['u'] = convertUid.toString();
  }

  return Uri(queryParameters: antiCodeRes).query;
}

/// Huya's web player names this `rotl64`: only the low 32-bit lane is
/// rotated, the upper 32-bit lane of the 64-bit viewer UID is preserved.
/// Returning only the rotated low lane truncates real anonymous UIDs
/// (normally > 2^32) and the CDN rejects the URL with HTTP 403.
int rotateViewerUid32(int value) {
  final low = value & 0xffffffff;
  final high = value - low;
  final rotatedLow = ((low << 8) | (low >> 24)) & 0xffffffff;
  return high | rotatedLow;
}

int unrotateViewerUid32(int value) {
  final low = value & 0xffffffff;
  final high = value - low;
  final originalLow = ((low >> 8) | (low << 24)) & 0xffffffff;
  return high | originalLow;
}

/// Replaces (or removes, when [value] is null) one query parameter in a
/// `a=b&c=d` string, preserving order and de-duplicating the key.
String replaceQueryParameter(String query, String key, String? value) {
  final output = <String>[];
  var replaced = false;
  for (final segment in query.split('&')) {
    if (segment.isEmpty) continue;
    final separator = segment.indexOf('=');
    final segmentKey = separator < 0 ? segment : segment.substring(0, separator);
    if (segmentKey != key) {
      output.add(segment);
      continue;
    }
    if (!replaced && value != null) output.add('$key=$value');
    replaced = true;
  }
  if (!replaced && value != null) output.add('$key=$value');
  return output.join('&');
}

/// Upgrades an http:// Huya CDN base to https://; anything else is returned
/// unchanged.
String secureHuyaCdnBase(String base) {
  final uri = Uri.tryParse(base);
  if (uri == null ||
      uri.scheme != 'http' ||
      !(uri.host == 'huya.com' || uri.host.endsWith('.huya.com'))) {
    return base;
  }
  return uri.replace(scheme: 'https').toString();
}

/// Hard signature expiry of a signed URL: wsTime (hex) + 5 min.
/// Null when the URL carries no parseable wsTime.
DateTime? huyaSignedUrlInvalidAt(String url) {
  final query = Uri.tryParse(url)?.queryParameters;
  if (query == null) return null;
  final wsTime = int.tryParse(query['wsTime'] ?? '', radix: 16);
  if (wsTime == null) return null;
  return DateTime.fromMillisecondsSinceEpoch(wsTime * 1000, isUtc: true)
      .add(huyaSignatureValidity);
}

/// Recovers the issue time encoded by the official web player's
/// `seqid = viewerUid + Date.now()` contract. The CDN can close a signed
/// transport roughly two minutes after this point while `wsTime` is still
/// valid, so the issue time is the stable transport-age anchor. It must
/// not be recomputed from the time this method happens to be called.
DateTime? huyaSignedSequenceIssuedAt(String url) {
  final query = Uri.tryParse(url)?.queryParameters;
  if (query == null) return null;
  final seqId = int.tryParse(query['seqid'] ?? '');
  final isWap = query['t'] == '103';
  final encodedUid = int.tryParse(query[isWap ? 'uid' : 'u'] ?? '');
  if (seqId == null || encodedUid == null) return null;
  final viewerUid = isWap ? encodedUid : unrotateViewerUid32(encodedUid);
  final issuedMillis = seqId - viewerUid;
  if (issuedMillis <= 0) return null;

  final issuedAt =
      DateTime.fromMillisecondsSinceEpoch(issuedMillis, isUtc: true);
  if (issuedAt.isBefore(DateTime.utc(2020)) ||
      issuedAt.isAfter(DateTime.utc(2100))) {
    return null;
  }
  final signedInvalidAt = huyaSignedUrlInvalidAt(url);
  if (signedInvalidAt != null && issuedAt.isAfter(signedInvalidAt)) {
    return null;
  }
  return issuedAt;
}

/// Proactive refresh deadline for one signed URL: the earliest of
/// (wsTime expiry − 30 s) and (transport issue + 100 s).
/// Returns null when no expiry can be derived from the URL at all.
/// [transportIssuedAt] overrides the seqid-derived issue time (used for
/// legacy/static-token lines whose seqid carries no issue instant).
DateTime? huyaPlayUrlRefreshAt(
  String url, {
  DateTime? now,
  DateTime? transportIssuedAt,
}) {
  final current = (now ?? DateTime.now()).toUtc();
  final signedInvalidAt = huyaSignedUrlInvalidAt(url);
  final issuedAt = transportIssuedAt ?? huyaSignedSequenceIssuedAt(url);
  DateTime? refreshAt;
  if (signedInvalidAt != null) {
    refreshAt = signedInvalidAt.subtract(huyaSignatureRefreshLead);
  }
  if (issuedAt != null) {
    final transportRefreshAt = issuedAt.add(huyaTransportRefreshAge);
    refreshAt = refreshAt == null || transportRefreshAt.isBefore(refreshAt)
        ? transportRefreshAt
        : refreshAt;
  }
  if (refreshAt == null) return null;
  return refreshAt.isAfter(current) ? refreshAt : current;
}

/// Hard expiry for one signed URL: the earliest of (wsTime + 5 min) and
/// (transport issue + 125 s). Null when no expiry can be derived.
/// [transportIssuedAt] overrides the seqid-derived issue time.
DateTime? huyaPlayUrlInvalidAt(String url, {DateTime? transportIssuedAt}) {
  final signedInvalidAt = huyaSignedUrlInvalidAt(url);
  final issuedAt = transportIssuedAt ?? huyaSignedSequenceIssuedAt(url);
  DateTime? invalidAt = signedInvalidAt;
  if (issuedAt != null) {
    final transportInvalidAt = issuedAt.add(huyaTransportInvalidAge);
    invalidAt = invalidAt == null || transportInvalidAt.isBefore(invalidAt)
        ? transportInvalidAt
        : invalidAt;
  }
  return invalidAt;
}

/// SHA-256 key for per-URL lease bookkeeping (issue times / token leases
/// are keyed by the full signed URL, never by line index).
String huyaUrlLeaseKey(String url) =>
    sha256.convert(utf8.encode(url)).toString();
