// mpv tuning table for media_kit (fixes spec fix 18 §6 + study §1.4).
//
// FIRST-FRAME priority uses the 5.6.5 numbers — do NOT mix in the 3.x
// numbers (cache 30 s / 96 MB). Per-source live-only properties are the
// critical fix: mpv's default `cache-pause=yes` makes a live stream play
// ~2 s then pause to buffer; Pure Live 3.x sets `cache-pause=no` for live.
// iOS has no special tuning: video output libmpv, hardware decode
// videotoolbox, audio output default.

/// Base mpv properties applied to every media_kit player (5.6.5 numbers).
const Map<String, String> kMpvBaseProperties = {
  // First-frame priority: probe 1 MiB / 1 s (Bilibili first frame
  // 1802 ms -> 708 ms in Pure Live's cold-start test).
  'demuxer-lavf-probesize': '1048576',
  'demuxer-lavf-analyzeduration': '1',
  // Small live-friendly cache: 6 s / 32 MB / 4 MB back / 2 s readahead.
  'cache-secs': '6',
  'demuxer-max-bytes': '33554432',
  'demuxer-max-back-bytes': '4194304',
  'demuxer-readahead-secs': '2',
  'network-timeout': '15',
  'hwdec-software-fallback': '1',
  'framedrop': 'decoder+vo',
  'cache': 'yes',
  'cache-on-disk': 'no',
};

/// Per-source properties for LIVE streams only.
///
/// `force-seekable=no` + `cache-pause=no` — live/HLS and live-progressive
/// streams (FLV treated as live). VOD keeps `force-seekable=yes` and the
/// default cache-pause.
Map<String, String> mpvLiveSourceProperties({required bool isHls}) {
  final props = <String, String>{
    'force-seekable': 'no',
    'cache-pause': 'no',
  };
  if (isHls) {
    props['demuxer-lavf-format'] = 'hls';
  }
  return props;
}

/// Per-source properties for VOD.
const Map<String, String> kMpvVodSourceProperties = {
  'force-seekable': 'yes',
};

/// iOS profile (mpv_platform_profile.dart): vo {auto, libmpv};
/// hwdec {auto, auto-safe, auto-copy, no, videotoolbox, videotoolbox-copy};
/// ao default (mpv default). No iOS-specific tuning properties exist.
const List<String> kIosVideoOutputs = ['auto', 'libmpv'];
const List<String> kIosHardwareDecoders = [
  'auto',
  'auto-safe',
  'auto-copy',
  'no',
  'videotoolbox',
  'videotoolbox-copy',
];
