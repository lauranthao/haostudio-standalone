// Huya transport policy — port of Pure Live 3.x
// lib/shared/platforms/huya/huya_transport_policy.dart.
//
// Line identity rule (HUYA_LINE_IDENTITY_AUDIT_2026_09_05): lines are
// identified by URL (CDN + port + media path + credential family), NEVER
// by index after a refresh — a refresh can reorder/filter the line list
// and a stale index silently switches the viewer to another CDN/format.

/// Shared classification of Huya credential and transport refresh policies.
abstract final class HuyaTransportPolicy {
  /// Picks the line index in the refreshed [urls] list that corresponds to
  /// the previously playing [currentUrl].
  ///
  /// Match order: same CDN + port + media path, preferring the same format
  /// (FLV stays FLV) and the same credential family (native FLV token
  /// stays native); when the broadcaster restarted and the stream name
  /// rotated, fall back to same CDN + format, then same format, then the
  /// first line. When [advanceLine] is true (current line failed), the
  /// NEXT line in the matched pool is returned instead of the match itself.
  static int selectRefreshedLine({
    required List<String> urls,
    required String? currentUrl,
    required int currentLineIndex,
    required bool advanceLine,
  }) {
    if (urls.isEmpty) return 0;
    final legacyIndex = currentLineIndex.clamp(0, urls.length - 1);
    final fallback =
        advanceLine ? (legacyIndex + 1) % urls.length : legacyIndex;
    final current = _mediaUri(currentUrl ?? '');
    if (current == null) return fallback;

    final candidates = urls.map(_mediaUri).toList(growable: false);
    final all = [
      for (var i = 0; i < candidates.length; i++)
        if (candidates[i] != null) i,
    ];
    final isFlv = current.path.toLowerCase().endsWith('.flv');
    final sameFormat = [
      for (final i in all)
        if (candidates[i]!.path.toLowerCase().endsWith('.flv') == isFlv) i,
    ];
    final wasNative = hasNativeFlvCredential(currentUrl!);
    final native = [
      for (final i in sameFormat)
        if (hasNativeFlvCredential(urls[i])) i,
    ];

    for (final pool in [if (wasNative) native, sameFormat, all]) {
      if (pool.isEmpty) continue;
      bool sameCdn(int i) =>
          candidates[i]!.host == current.host &&
          candidates[i]!.port == current.port &&
          hasNativeFlvCredential(urls[i]) == wasNative;
      var position = pool.indexWhere(
          (i) => sameCdn(i) && candidates[i]!.path == current.path);
      // Stream names can rotate when the broadcaster restarts. The CDN and
      // format still identify the viewer's line in the refreshed snapshot.
      if (position < 0) position = pool.indexWhere(sameCdn);
      if (position < 0) return pool.first;
      if (!advanceLine) return pool[position];
      if (pool.length > 1) return pool[(position + 1) % pool.length];
      // The only native line failed: broaden to web FLV, then HLS rather
      // than retrying that same endpoint forever or deleting the fallback
      // choices.
    }
    return fallback;
  }

  static Uri? _mediaUri(String url) {
    final uri = Uri.tryParse(url);
    if (uri == null || (uri.scheme != 'https' && uri.scheme != 'http')) {
      return null;
    }
    if (uri.host != 'huya.com' && !uri.host.endsWith('.huya.com')) {
      return null;
    }
    final path = uri.path.toLowerCase();
    return path.endsWith('.flv') || path.endsWith('.m3u8') ? uri : null;
  }

  /// Whether this URL is on the short (~100 s / 125 s) transport lease.
  /// Native WUP FLV tokens outlive their credential in long probes, so
  /// they are excluded; every web-template-signed URL has the short lease.
  static bool hasShortTransportLease(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    final path = uri?.path.toLowerCase() ?? '';
    final isHuya = host == 'huya.com' || host.endsWith('.huya.com');
    if (!isHuya || (!path.endsWith('.flv') && !path.endsWith('.m3u8'))) {
      return false;
    }
    return !hasNativeFlvCredential(url);
  }

  /// Native WUP FLV credential marker: FLV + ctype=huya_pc_exe + t=100.
  /// Web-template-signed URLs carry ctype=huya_webh5 and never match.
  static bool hasNativeFlvCredential(String url) {
    final uri = Uri.tryParse(url);
    final host = uri?.host.toLowerCase() ?? '';
    if (host != 'huya.com' && !host.endsWith('.huya.com')) return false;
    return (uri?.path.toLowerCase().endsWith('.flv') ?? false) &&
        uri!.queryParameters['ctype'] == 'huya_pc_exe' &&
        uri.queryParameters['t'] == '100';
  }
}
