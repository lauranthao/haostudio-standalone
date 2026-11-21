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

import '../../storage/hive_store.dart';
import 'player_engine.dart';

/// Stream format as declared by the platform adapter
/// (LivePlayStreamFacts: format flv | hls | other).
///
/// `mkv` is a real container, not a flavour of `other`: AVPlayer
/// (BetterPlayer) has no MKV demuxer, while the ffmpeg kernels do —
/// so MKV must exclude AVPlayer at selection time instead of letting
/// it waste one open attempt and fall back.
enum StreamFormat { flv, hls, mp4, mkv, other, unknown }

/// Capability table (media_core media_format_constants.dart).
///
/// MPV (media_kit): flv, hls/m3u8, mp4, ts, mov, mkv, webm, avi.
/// IJK (fijk): same set.
/// AVPlayer (BetterPlayer): hls/m3u8, mp4, ts, mov — NO flv, NO mkv
/// (AVFoundation has neither demuxer; the old comment listing mkv
/// for AVPlayer was the claim, not the behaviour — see audit).
const Map<PlayerEngine, Set<StreamFormat>> kSupportedFormats = {
  PlayerEngine.mediaKit: {
    StreamFormat.flv,
    StreamFormat.hls,
    StreamFormat.mp4,
    StreamFormat.mkv,
    StreamFormat.other,
  },
  PlayerEngine.fijk: {
    StreamFormat.flv,
    StreamFormat.hls,
    StreamFormat.mp4,
    StreamFormat.mkv,
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
      case 'mkv':
        return StreamFormat.mkv;
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
  if (lower.endsWith('.mkv')) return StreamFormat.mkv;
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
  // Container facts carried in the URL query (Emby direct streams —
  // the path has no suffix, so the container rides `hao_container`).
  // A known MKV/MP4 container resolves here; any other container
  // falls through to unknown and is gated by [streamFactsOf] in
  // [candidatesFor] instead.
  final factsContainer = streamFactsOf(url)?.container;
  if (factsContainer == 'mkv') return StreamFormat.mkv;
  if (factsContainer == 'mp4' ||
      factsContainer == 'mov' ||
      factsContainer == 'm4v') {
    return StreamFormat.mp4;
  }
  // HLS playlists often have no extension; a URL containing a playlist
  // marker is still not proof — unknown excludes nothing.
  return StreamFormat.unknown;
}

/// Container / codec facts for one stream, carried in the URL query
/// as `hao_container` / `hao_vcodec` / `hao_acodec` / `hao_dv` /
/// `hao_dvprofile` / `hao_width` / `hao_height` / `hao_bitrate` /
/// `hao_size`.
///
/// Why in the URL: the player page derives `declaredFormat` from the
/// URL suffix only, and an Emby direct-stream URL
/// (`/Videos/{id}/stream?...`) has no suffix — so the facts Emby
/// reports (MediaSources: container, codecs, Dolby Vision) ride the
/// query instead. Emby ignores unknown query params; the markers
/// survive line switches and engine re-opens because they are part
/// of the URL itself. Only Emby stream URLs carry them — every other
/// caller sees null and keeps the old behaviour.
class StreamFacts {
  const StreamFacts({
    this.container,
    this.videoCodec,
    this.audioCodec,
    this.dolbyVision = false,
    this.dvProfile,
    this.width,
    this.height,
    this.bitRate,
    this.size,
  });

  /// Lowercase container: 'mkv' | 'mp4' | 'mov' | 'avi' | ...
  final String? container;

  /// Lowercase video codec: 'hevc' | 'h264' | 'av1' | ...
  final String? videoCodec;

  /// Lowercase codec of the DEFAULT audio track: 'aac' | 'truehd' |
  /// 'dts' | ... (only the default track matters for the gate — an
  /// optional TrueHD track next to an AAC default still plays).
  final String? audioCodec;

  /// Dolby Vision video range (any profile). P5 / P7 / unknown
  /// profile route to the ffmpeg kernels; P8 in an Apple container
  /// is admitted to AVPlayer when the downgrade switch is on (see
  /// [engineCanPlayFacts]) — its base layer is HDR10 (8.1) or HLG
  /// (8.4) compatible, so AVPlayer plays it natively.
  final bool dolbyVision;

  /// Dolby Vision bitstream profile (5 / 7 / 8 / ...), from
  /// `hao_dvprofile`. Null when the server did not report a profile
  /// — the gate then treats the stream as DV of unknown profile
  /// (ffmpeg kernels only).
  final int? dvProfile;

  /// Frame size in pixels, from `hao_width` / `hao_height`. Feeds
  /// the detail-page 4K badge only — never the kernel gate (there
  /// is no resolution cap anywhere in the kernel).
  final int? width;
  final int? height;

  /// Bitrate in bits/sec, from `hao_bitrate` (Emby `BitRate`).
  /// Display only — never the kernel gate.
  final int? bitRate;

  /// File size in bytes, from `hao_size` (Emby `MediaSources[].Size`).
  /// Display only.
  final int? size;

  /// 4K by frame size: 3840 wide or 2160 tall (covers 3840x2160 and
  /// wider DCI 4K / scope crops whose height is under 2160).
  bool get is4K =>
      (width != null && width! >= 3840) ||
      (height != null && height! >= 2160);

  bool get isEmpty =>
      container == null &&
      videoCodec == null &&
      audioCodec == null &&
      !dolbyVision &&
      dvProfile == null &&
      width == null &&
      height == null &&
      bitRate == null &&
      size == null;
}

/// Parse [StreamFacts] from a URL's `hao_*` query params. Null when
/// the URL carries no markers (all non-Emby URLs).
StreamFacts? streamFactsOf(String url) {
  final query = Uri.tryParse(url)?.queryParameters;
  if (query == null) return null;
  final container = query['hao_container']?.toLowerCase();
  final videoCodec = query['hao_vcodec']?.toLowerCase();
  final audioCodec = query['hao_acodec']?.toLowerCase();
  final dolbyVision = query['hao_dv'] == '1';
  final dvProfile = int.tryParse(
    (query['hao_dvprofile'] ?? '').split('.').first,
  );
  final width = int.tryParse(query['hao_width'] ?? '');
  final height = int.tryParse(query['hao_height'] ?? '');
  final bitRate = int.tryParse(query['hao_bitrate'] ?? '');
  final size = int.tryParse(query['hao_size'] ?? '');
  if (container == null &&
      videoCodec == null &&
      audioCodec == null &&
      !dolbyVision &&
      dvProfile == null &&
      width == null &&
      height == null &&
      bitRate == null &&
      size == null) {
    return null;
  }
  return StreamFacts(
    container: container,
    videoCodec: videoCodec,
    audioCodec: audioCodec,
    dolbyVision: dolbyVision,
    dvProfile: dvProfile,
    width: width,
    height: height,
    bitRate: bitRate,
    size: size,
  );
}

/// The persisted switch ([HiveKeys.vodDvP8Downgrade],
/// 'hao_vod_dv_p8_downgrade', default ON, decided 2026-11-22): P8's
/// base layer is HDR10 (8.1) / HLG (8.4) compatible by Dolby's
/// spec, so "downgrading" loses no information and never transcodes
/// — the only thing default-off would buy is a visible error when
/// DV fails, which contradicts chen's "play the next thing, never
/// show an error" rule. The switch ROW lives in
/// settings_tab_page.dart (settings group); this file only owns
/// the read + the routing. Any storage failure reads as ON (the
/// default), never as off — the mirror of superResolutionSwitchOn,
/// whose default is off.
///
/// Binding to real-device verification: if MPV plays P8 with wrong
/// colours while AVPlayer is correct, default-on still holds (the
/// gate sends MP4 P8 to AVPlayer); if BOTH are wrong / unplayable,
/// the default must go back to off and the item returns to the
/// coordinator — do not change the default here on your own.
bool dvDowngradeToHdrSwitchOn() {
  try {
    return HiveStore.getBool(HiveKeys.vodDvP8Downgrade, true);
  } catch (_) {
    return true;
  }
}

/// Capability gate for [StreamFacts]. The ffmpeg kernels (MPV/IJK)
/// play everything; AVPlayer is excluded when the file needs a
/// demuxer or decoder AVFoundation does not have:
///
/// - container outside {mp4, mov, m4v} (mkv/avi/webm/ts/...),
/// - AV1 video (no AVFoundation decoder on most devices),
/// - Dolby Vision, EXCEPT profile 8 in an Apple container when the
///   downgrade switch is on (see below),
/// - TrueHD / DTS audio (AVFoundation cannot decode them).
///
/// HEVC in MP4/MOV stays allowed on AVPlayer (hardware-decoded
/// since iOS 11), as does HDR10/HLG in MP4 — the gate is about the
/// container/codec combination, never the resolution: there is no
/// resolution cap anywhere in the kernel (see audit).
///
/// What "P8 downgrade" means here (and what it does NOT mean):
/// routing only. There is no tone-mapping knob on the iOS MPV path
/// (vo=libmpv, HB-1) — MPV already decodes the HDR10-compatible
/// base layer and never applies the RPU, so the switch changes no
/// MPV decode parameter. Its effect is admitting AVPlayer for P8 in
/// MP4 (native DV) and keeping the silent ladder fallback on
/// failure — never "MPV 降级渲染", never an error dialog. P7 stays
/// on the ffmpeg kernels in both switch states: its enhancement
/// layer is discarded by ffmpeg (base-layer HDR10 playback) and
/// AVFoundation cannot play dual-layer DV at all (HB-2).
bool engineCanPlayFacts(
  PlayerEngine engine,
  StreamFacts facts, {
  bool dvDowngradeToHdr = true,
}) {
  if (engine != PlayerEngine.exo) return true;
  const appleContainers = {'mp4', 'mov', 'm4v'};
  if (facts.container != null &&
      !appleContainers.contains(facts.container)) {
    return false;
  }
  if (facts.videoCodec == 'av1') return false;
  if (facts.dolbyVision) {
    // P8 + switch on + Apple container (checked above): AVPlayer
    // plays it natively — fall through to the audio gate. Anything
    // else (switch off, P5 / P7 / unknown profile) keeps the old
    // behaviour: DV goes to the ffmpeg kernels only.
    if (!dvDowngradeToHdr || facts.dvProfile != 8) return false;
  }
  const ffmpegOnlyAudio = {'truehd', 'dts', 'dtshd', 'dts-hd', 'dca'};
  if (facts.audioCodec != null &&
      ffmpegOnlyAudio.contains(facts.audioCodec)) {
    return false;
  }
  return true;
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
///
/// [dvDowngradeToHdr] overrides the persisted P8 switch (tests pass
/// it explicitly); null reads the switch via
/// [dvDowngradeToHdrSwitchOn] (default on).
List<PlayerEngine> candidatesFor({
  required String url,
  String? declaredFormat,
  required bool isLive,
  PlayerEngine preferred = PlayerEngine.mediaKit,
  bool? dvDowngradeToHdr,
}) {
  final format = formatOf(url: url, declaredFormat: declaredFormat);
  final facts = streamFactsOf(url);
  final downgrade = dvDowngradeToHdr ?? dvDowngradeToHdrSwitchOn();
  final capable = PlayerEngine.values
      .where(
        (e) =>
            engineCanPlay(e, format) &&
            (facts == null ||
                engineCanPlayFacts(e, facts,
                    dvDowngradeToHdr: downgrade)),
      )
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
