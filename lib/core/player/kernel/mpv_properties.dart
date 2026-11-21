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

import '../../storage/hive_store.dart';

/// Low-memory mode — Kazumi `LowMemoryMode`
/// (`lib/services/player/low_memory_mode.dart`, GPL-3.0: idea + mode
/// set only, no code copied) adapted to our table.
///
/// Kazumi: auto / always / never, stored as 'auto' | 'always' |
/// 'never' (legacy bool key migrates to always/auto); auto means
/// "metered network" (mobile data on, WLAN off) and the effect is
/// `cache-secs 0` + `demuxer-readahead-secs 0` while suspended
/// (`player_playback_controller.dart:255`).
///
/// Our adaptation (own structure, same three modes):
/// - auto (default): keeps the behaviour this table already had —
///   low-end when the device has <= 4 CPU cores (`_lowEnd`). We have
///   no metered-network service, so Kazumi's network trigger is NOT
///   copied; the doc says so instead of faking it.
/// - always: force the low-end property set on any device.
/// - never: force the full property set on any device.
/// The low-end set itself is unchanged (40 MB forward / 5 MB back,
/// audio-buffer 0.4, reconnect triple, vd-lavc-threads 2, lowres=1,
/// skiploopfilter nonref); the mode only decides WHEN it applies.
/// Applied at open() (mpv_backend reads the mode then), so a change
/// takes effect on the NEXT open — live and VOD share the base table,
/// so the mode covers both.
enum LowMemoryMode {
  auto('auto', '自动'),
  always('always', '始终开启'),
  never('never', '始终关闭');

  const LowMemoryMode(this.storageValue, this.label);

  final String storageValue;
  final String label;

  static LowMemoryMode fromStorageValue(Object? value) {
    if (value is String) {
      for (final mode in LowMemoryMode.values) {
        if (mode.storageValue == value) return mode;
      }
    }
    return LowMemoryMode.auto;
  }

  /// Cycle order for the settings row: 自动 -> 始终开启 -> 始终关闭.
  LowMemoryMode get next {
    final i = LowMemoryMode.values.indexOf(this);
    return LowMemoryMode.values[(i + 1) % LowMemoryMode.values.length];
  }

  /// Persisted mode; uninitialised/corrupt Hive falls back to [auto].
  static LowMemoryMode get current {
    try {
      return fromStorageValue(
        HiveStore.getString(HiveKeys.lowMemoryMode, 'auto'),
      );
    } catch (_) {
      return LowMemoryMode.auto;
    }
  }

  static Future<void> save(LowMemoryMode mode) =>
      HiveStore.put(HiveKeys.lowMemoryMode, mode.storageValue);

  /// Whether the low-end property set applies. [cpuCores] is a test
  /// seam (production passes nothing and reads the device).
  bool isEffective({int? cpuCores}) {
    switch (this) {
      case LowMemoryMode.always:
        return true;
      case LowMemoryMode.never:
        return false;
      case LowMemoryMode.auto:
        return (cpuCores ?? _cpuCores) <= 4;
    }
  }

  /// Description shown in Settings (Kazumi's words where they still
  /// apply; the auto line is ours — Kazumi's metered-network trigger
  /// does not exist here, see the enum doc above).
  String get description => switch (this) {
    LowMemoryMode.auto => '按设备性能自动决定，低配设备自动开启',
    LowMemoryMode.always => '所有网络均减少缓存，降低内存占用',
    LowMemoryMode.never => '使用完整缓存',
  };

  String statusDescription({int? cpuCores}) {
    final on = isEffective(cpuCores: cpuCores);
    return switch (this) {
      LowMemoryMode.auto => on
          ? '自动 · 已开启（低配设备，减少缓存）'
          : '自动 · 已关闭（完整缓存）',
      LowMemoryMode.always => '始终开启 · 减少缓存',
      LowMemoryMode.never => '始终关闭 · 完整缓存',
    };
  }
}

/// Base mpv properties applied to every media_kit player.
/// Pure Live `MediaKitLiveProperties.build()`, verbatim.
/// [mode] selects the low-end property set (Kazumi low-memory mode):
/// null = persisted mode ([LowMemoryMode.current]).
Map<String, String> mpvBaseProperties({LowMemoryMode? mode}) {
  // Resolved once: every low-end branch below reads this, never the
  // raw core count, so `always`/`never` override the auto rule.
  final lowEnd = (mode ?? LowMemoryMode.current).isEffective();
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
        (lowEnd ? _lowEndForwardBytes : _forwardBytes).toString(),
    'demuxer-max-back-bytes':
        (lowEnd ? _lowEndBackBytes : _backBytes).toString(),
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

  if (lowEnd) {
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

  properties.addAll(mpvPlatformHwdec(isIOS: Platform.isIOS));

  // Decode-cost policy: a software decoder's thread pool is what actually
  // costs CPU on a weak box, so cap it there and let lowres absorb the rest.
  if (lowEnd) {
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

int get _cpuCores {
  try {
    return Platform.numberOfProcessors;
  } catch (_) {
    return 4;
  }
}

/// Hardware-decode property by platform (pure, tested).
///
/// iOS: `hwdec=videotoolbox`. mpv's built-in default is `no`
/// (software) — nothing in the repo ever set it on iOS, so the
/// mpv_backend.dart header comment claiming "hwdec videotoolbox"
/// was aspirational, not behaviour. Software decode cannot hold
/// 4K HEVC (the Emby direct-file case) smoothly; VideoToolbox
/// decodes H.264/HEVC in hardware. The software fallback
/// (`hwdec-software-fallback=1`, set in the base table) keeps the
/// failure path: a codec VideoToolbox rejects still falls back
/// instead of failing the open. macOS stays `no` (unstable texture
/// path, see the macOS branch above); Android is untouched (its
/// mediacodec path is set elsewhere).
Map<String, String> mpvPlatformHwdec({required bool isIOS}) {
  if (isIOS) return const {'hwdec': 'videotoolbox'};
  return const {};
}

/// Anime4K super-resolution — the mpv list-option name (build 28).
///
/// Only the option name lives here: the efficiency chain itself
/// (Kazumi `mpvAnime4KShadersLite`, via Pure Live
/// `super_resolution.dart` — 7 files, mount order fixed) lives in
/// `lib/core/player/super_resolution.dart` as
/// `kAnime4kEfficiencyShaders`, with the unpack / gate / command
/// helpers. Pure Live's preset system (modes, locale keys, settings
/// wiring) is deliberately NOT ported — one bool switch, one tier,
/// VOD only, MPV only, default off.
///
/// The value is a list option: set it ONLY through the `change-list`
/// command (`glslShadersChangeListCommand`), never through
/// `setProperty` with a joined string (mpv would take the whole
/// joined value as a single shader filename).
const String kMpvGlslShadersOption = 'glsl-shaders';

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
