// Kernel selection — capability table + format resolution + scoring.
//
// Pure Live 3.x, study §1.2. There is NO boolean `supports(url)` gate:
// 1. The user's preferred engine wins UNCONDITIONALLY — but only among
//    engines that CAN play this format (preference first, capability as a
//    gate, not a suggestion).
// 2. Scoring (priority 100/90/80 + protocol +40 + format +30 + live +10)
//    only matters when the preferred backend is unregistered/disabled.
// 3. Format facts come from the adapter's declaration first; the URL
//    suffix is only a fallback. Unknown/empty format excludes NOTHING.
// 4. AVPlayer (BetterPlayer on iOS) has NO FLV demuxer — Pure Live never
//    sends FLV to AVPlayer, it switches engines. Our old app showed
//    "播放失败" here; the fix is automatic fallback, never a dead-end error.

import 'player_engine.dart';

/// Stream format as declared by the platform adapter
/// (LivePlayStreamFacts: format flv | hls | other).
enum StreamFormat { flv, hls, mp4, other, unknown }

/// Capability table (media_core media_format_constants.dart).
///
/// MPV (media_kit): flv, hls/m3u8, mp4, ts, mov, mkv, webm, avi.
/// IJK (fijk): same set.
/// AVPlayer (BetterPlayer): hls/m3u8, mp4, ts, mov, mkv, webm, avi — NO flv.
const Map<PlayerEngine, Set<StreamFormat>> kSupportedFormats = {
  PlayerEngine.mediaKit: {
    StreamFormat.flv,
    StreamFormat.hls,
    StreamFormat.mp4,
    StreamFormat.other,
  },
  PlayerEngine.fijk: {
    StreamFormat.flv,
    StreamFormat.hls,
    StreamFormat.mp4,
    StreamFormat.other,
  },
  PlayerEngine.exo: {
    StreamFormat.hls,
    StreamFormat.mp4,
    StreamFormat.other,
  },
};

bool engineCanPlay(PlayerEngine engine, StreamFormat format) {
  if (format == StreamFormat.unknown) return true;
  return kSupportedFormats[engine]?.contains(format) ?? false;
}

/// Resolve the stream format. The DECLARED format wins over the URL
/// suffix (Pure Live: "the enum can be present while the URI has no
/// extension"). Resolution order: declared flv -> flv; declared hls/m3u8
/// -> hls; declared mp4/mov -> mp4; otherwise URL extension (.flv -> flv,
/// .m3u8 -> hls, .mp4/.mov -> mp4); unknown/empty excludes nothing.
StreamFormat formatOf({required String url, String? declaredFormat}) {
  final declared = declaredFormat?.trim().toLowerCase();
  if (declared != null && declared.isNotEmpty) {
    switch (declared) {
      case 'flv':
        return StreamFormat.flv;
      case 'hls':
      case 'm3u8':
        return StreamFormat.hls;
      case 'mp4':
      case 'mov':
        return StreamFormat.mp4;
      case 'other':
        return StreamFormat.other;
    }
  }
  final lower = url.toLowerCase().split('?').first;
  if (lower.endsWith('.flv')) return StreamFormat.flv;
  if (lower.endsWith('.m3u8') || lower.endsWith('.m3u')) {
    return StreamFormat.hls;
  }
  if (lower.endsWith('.mp4') || lower.endsWith('.mov')) {
    return StreamFormat.mp4;
  }
  // Real-world URLs often carry the format in the host or a path
  // fragment instead of the suffix: Huya FLV
  // `http://al-game.flv.huya.com/src`, Douyin pull hosts
  // `pull-flv-…`, Kuaishou `…_GameAvcHdL0.flv` is covered above but
  // `/flv/` path segments are not. Scan the whole URL (host + path,
  // query stripped) before giving up — unknown excludes nothing, but a
  // wrong unknown lets AVPlayer waste one attempt on an FLV stream.
  final whole = url.toLowerCase();
  if (whole.contains('.flv.') ||
      whole.contains('/flv/') ||
      whole.contains('flv_pull') ||
      whole.contains('pull-flv')) {
    return StreamFormat.flv;
  }
  if (whole.contains('.m3u8')) return StreamFormat.hls;
  // HLS playlists often have no extension; a URL containing a playlist
  // marker is still not proof — unknown excludes nothing.
  return StreamFormat.unknown;
}

/// Score one engine for one source (media_core player_adapter_selector).
/// Baseline = registration priority; protocol match +40; format match +30;
/// live source +10.
int scoreEngine({
  required PlayerEngine engine,
  required StreamFormat format,
  required String url,
  required bool isLive,
}) {
  var score = engine.priority;
  final scheme = url.split(':').first.toLowerCase();
  const playableProtocols = {
    'http',
    'https',
    'hls',
    'rtmp',
    'rtmps',
    'rtsp',
    'srt',
    'udp',
    'rtp',
    'tcp',
    'file',
  };
  if (playableProtocols.contains(scheme)) score += 40;
  if (format != StreamFormat.unknown &&
      engineCanPlay(engine, format)) {
    score += 30;
  }
  if (isLive) score += 10;
  return score;
}

/// Candidate engines for a source, in try order.
///
/// Preferred capable engine first, then remaining capable engines in
/// registration priority order. An incapable engine never appears in the
/// list, so it can never be selected or retried for that stream.
List<PlayerEngine> candidatesFor({
  required String url,
  String? declaredFormat,
  required bool isLive,
  PlayerEngine preferred = PlayerEngine.mediaKit,
}) {
  final format = formatOf(url: url, declaredFormat: declaredFormat);
  final capable = PlayerEngine.values
      .where((e) => e.isAvailableOnPlatform && engineCanPlay(e, format))
      .toList()
    ..sort((a, b) {
      // Preferred first; ties broken by score, then priority.
      if (a == preferred && b != preferred) return -1;
      if (b == preferred && a != preferred) return 1;
      final sa = scoreEngine(engine: a, format: format, url: url, isLive: isLive);
      final sb = scoreEngine(engine: b, format: format, url: url, isLive: isLive);
      return sb.compareTo(sa);
    });
  return capable;
}
