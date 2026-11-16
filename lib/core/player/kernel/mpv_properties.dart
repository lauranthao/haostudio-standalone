// mpv tuning table — Pure Live 3.x
// `lib/core/player/kernel/media_kit_live_properties.dart`
// (`MediaKitLiveProperties.build()` + `sourceProperties()`), copied
// verbatim. Only the class wrapper changed (top-level functions instead
// of statics) and the proxy/private-input inputs are fixed: our live
// URLs are always remote http(s) and playback is direct (no proxy).
// The Settings/preset/super-resolution methods of that class are NOT
// copied — they belong to Pure Live's settings system, not to this table.
//
// Why this table and not the 5.6.5 "first-frame" numbers: the 5.6.5
// numbers (cache 6 s / 32 MB / readahead 2 s, probe 1 MB / 1 s) starve
// the demuxer on jittery Douyu/Huya FLV lines — the buffer drains,
// playback stalls, and the small probe can fail to identify a
// high-bitrate FLV at all ("一直加载中"). Pure Live 3.x chose 30 s /
// 96 MB / 8 s deliberately ("Network cache-secs takes precedence over
// the smaller base readahead").

import 'dart:io';

/// Base mpv properties applied to every media_kit player.
/// Pure Live `MediaKitLiveProperties.build()`, verbatim.
Map<String, String> mpvBaseProperties() {
  final properties = <String, String>{
    'protocol_whitelist':
        'httpproxy,udp,rtp,tcp,tls,data,file,http,https,crypto,rtmp,rtmps,rtsp,srt',
    'demuxer-lavf-probesize': '2097152',
    'demuxer-lavf-analyzeduration': '2',
    'network-timeout': '15',
    // Drop a failing hw decoder after one bad frame.
    'hwdec-software-fallback': '1',
    // Network cache-secs takes precedence over the smaller base readahead.
    'cache': 'yes',
    'cache-on-disk': 'no',
    'cache-secs': _cacheSeconds.toString(),
    'demuxer-max-bytes':
        (_lowEnd ? _lowEndForwardBytes : _forwardBytes).toString(),
    'demuxer-max-back-bytes':
        (_lowEnd ? _lowEndBackBytes : _backBytes).toString(),
    // Past media must not borrow the unused forward reserve.
    'demuxer-donate-buffer': 'no',
    'demuxer-readahead-secs': _readaheadSeconds.toString(),
    // Refill-then-resume: wait for a healthy buffer after a stall. Whether it
    // is enabled at all is a per-source decision (see [mpvLiveSourceProperties]).
    'cache-pause-wait': _cachePauseWaitSeconds.toString(),
    'demuxer-thread': 'yes',
    // Drop late frames instead of stacking lag.
    'framedrop': 'decoder+vo',
  };

  if (_lowEnd) {
    properties['audio-buffer'] = '0.4';
    properties['stream-lavf-o'] =
        'reconnect=1,reconnect_streamed=1,reconnect_on_network_error=1,reconnect_delay_max=2';
  }

  if (Platform.isAndroid) {
    properties['mediacodec-surface-iostream'] = 'yes';
    properties['mediacodec-embed-surface-landscape'] = 'yes';
  }

  if (Platform.isMacOS) {
    // The bundled libmpv's VideoToolbox path is unstable with the Flutter
    // texture surface on this app's macOS builds.
    properties['hwdec'] = 'no';
  }

  // Decode-cost policy: a software decoder's thread pool is what actually
  // costs CPU on a weak box, so cap it there and let lowres absorb the rest.
  if (_lowEnd) {
    properties['vd-lavc-threads'] = '2';
    properties['vd-lavc-o'] = 'lowres=1';
    properties['vd-lavc-skiploopfilter'] = 'nonref';
  } else {
    properties['vd-lavc-o'] = 'lowres=0';
    properties['vd-lavc-skiploopfilter'] = 'default';
  }

  return properties;
}

const int _forwardBytes = 96 * 1024 * 1024;
const int _backBytes = 8 * 1024 * 1024;
const int _lowEndForwardBytes = 40 * 1024 * 1024;
const int _lowEndBackBytes = 5 * 1024 * 1024;
const int _readaheadSeconds = 8;
const int _cacheSeconds = 30;
const int _cachePauseWaitSeconds = 4;

bool get _lowEnd => _cpuCores <= 4;

int get _cpuCores {
  try {
    return Platform.numberOfProcessors;
  } catch (_) {
    return 4;
  }
}

/// Per-source properties for LIVE streams only.
/// Pure Live `MediaKitLiveProperties.sourceProperties()`, with
/// `privateInput` fixed to false (our live URLs are always remote
/// http(s)) and `proxy` fixed to `''` (direct playback, no proxy):
/// playlist = isHls, liveProgressive = !isHls, so force-seekable and
/// cache-pause are always 'no' for live.
///
/// 远端渐进式流（FLV 等）一律按直播对待：直播数据没有“缓存目标凑齐”的
/// 那一刻，cache-pause 只会播两秒后停进缓冲再续播——观察到的
/// “先播后暂停再加载”就是它。(Pure Live comment, kept.)
Map<String, String> mpvLiveSourceProperties({required bool isHls}) {
  return <String, String>{
    'http-proxy': '',
    'demuxer-lavf-format': isHls ? 'hls' : '',
    'force-seekable': 'no',
    'cache-pause': 'no',
  };
}

/// Per-source properties for VOD (unchanged — VOD is out of the live
/// audit's scope; Pure Live's live table above is never applied to VOD
/// in Pure Live either).
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
