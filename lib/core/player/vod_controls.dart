// VOD playback controls (1.1.6) — pure logic + Hive reads.
//
// One module for the three VOD-only, MPV-only enhancement switches
// and the skip-intro/outro model, so unit tests can pin them without
// a player:
//
// - Skip intro/outro: mode (off/manual/auto3s/autoNow) + Emby
//   Chapters markers (IntroStart/IntroEnd/CreditsStart) + per-episode
//   custom CMS durations. No IntroDB/TheIntroDB — Emby markers +
//   per-episode custom seconds are the only automatic sources.
// - Subtitle time offset: mpv `sub-delay`, ±10 s, 0.1 s steps.
// - Frame interpolation + SDR→HDR: mutually exclusive with each
//   other and with Anime4K super-resolution — the gate layer runs
//   only the first passing branch (super-res → interpolation →
//   SDR→HDR), so a phone GPU never runs two of them at once.
//
// Real-device effect is UNVERIFIED for interpolation (vo=libmpv may
// silently disable it without display-sync) and for SDR→HDR
// (inverse-tone-mapping is marked vo=gpu-next only, and the Flutter
// texture → Metal chain may not carry a real HDR signal). Both
// switches default off; if chen's phone shows no effect, the switch
// is dropped — the gates below only decide whether the properties
// are SET, never whether they worked.

import '../../features/video/video_title_helpers.dart';
import '../storage/hive_store.dart';
import 'kernel/player_engine.dart';

// -- Skip intro/outro mode ----------------------------------------------

/// VOD skip-intro/outro mode (HiveKeys.vodSkipIntroMode, default
/// 'off'): 'off' | 'manual' (button in the intro window) | 'auto3s'
/// (button + auto-skip after 3 s) | 'autoNow' (skip on entering the
/// window). The stored strings are the Hive contract — never rename
/// them without a migration.
enum VodSkipIntroMode { off, manual, auto3s, autoNow }

/// Parse the stored mode string; anything unknown reads as off, so a
/// corrupt or future value can never turn auto-skip on by itself.
VodSkipIntroMode parseVodSkipIntroMode(String? raw) {
  switch (raw) {
    case 'manual':
      return VodSkipIntroMode.manual;
    case 'auto3s':
      return VodSkipIntroMode.auto3s;
    case 'autoNow':
      return VodSkipIntroMode.autoNow;
    case 'off':
    default:
      return VodSkipIntroMode.off;
  }
}

/// The persisted mode (default off). Any storage failure reads as
/// off — auto-skip must never turn itself on because Hive is
/// uninitialised or corrupt.
VodSkipIntroMode vodSkipIntroMode() {
  try {
    return parseVodSkipIntroMode(
      HiveStore.getString(HiveKeys.vodSkipIntroMode, 'off'),
    );
  } catch (_) {
    return VodSkipIntroMode.off;
  }
}

// -- Skip markers ---------------------------------------------------------

/// Intro/outro time markers for one episode, in seconds.
///
/// Sources, in priority order: Emby Chapters markers (IntroStart /
/// IntroEnd / CreditsStart, from `Fields=Chapters`) > the per-episode
/// custom intro seconds (CMS has no markers at all). A null field
/// means "no marker": never invent one.
class SkipMarkers {
  const SkipMarkers({this.introStart, this.introEnd, this.creditsStart});

  /// Parse Emby `Chapters` (`ChapterInfo[]`): `StartPositionTicks`
  /// is 100 ns units, seconds = ticks / 10_000_000; `MarkerType` is
  /// `Chapter` / `IntroStart` / `IntroEnd` / `CreditsStart`. Unknown
  /// / malformed chapters yield empty markers, never a throw — a
  /// server without the IntroSkip plugin (or an old server) returns
  /// an empty array or no field at all.
  ///
  /// Whether chen's server actually returns `MarkerType` is
  /// 待真服验证: this parser only defines the mapping.
  factory SkipMarkers.fromEmbyChapters(dynamic chapters) {
    if (chapters is! List) return const SkipMarkers();
    double? introStart;
    double? introEnd;
    double? creditsStart;
    for (final c in chapters) {
      if (c is! Map<String, dynamic>) continue;
      final markerRaw = c['MarkerType'];
      final ticksRaw = c['StartPositionTicks'];
      // `as` casts throw on a wrong type — a server (or a stale
      // cache) can hand us a String tick count, so check with `is`
      // and skip instead of crashing the detail load.
      if (markerRaw is! String || ticksRaw is! num) continue;
      final ticks = ticksRaw.toDouble();
      if (ticks < 0) continue;
      final seconds = ticks / 10000000.0;
      switch (markerRaw) {
        case 'IntroStart':
          introStart ??= seconds;
        case 'IntroEnd':
          introEnd ??= seconds;
        case 'CreditsStart':
          creditsStart ??= seconds;
      }
    }
    return SkipMarkers(
      introStart: introStart,
      introEnd: introEnd,
      creditsStart: creditsStart,
    );
  }

  /// Start of the intro window (seconds from 0). Null = unknown.
  final double? introStart;

  /// End of the intro window — the seek target. Null = unknown, and
  /// an intro with a start but no end can never auto-skip (there is
  /// no known end to jump to).
  final double? introEnd;

  /// Start of the credits — the next-episode trigger. Null = unknown.
  final double? creditsStart;

  bool get isEmpty =>
      introStart == null && introEnd == null && creditsStart == null;
}

/// The intro window for one episode: (start, end) in seconds, or null
/// when there is nothing to skip to.
///
/// Effective end = the Emby `introEnd` marker when present, else the
/// per-episode custom seconds when > 0. Effective start = the marker's
/// `introStart` when present, else 0. A marker end of 0 or a custom
/// value of 0 means "no skip" — never seek to 0.
({double start, double end})? resolveIntroWindow({
  required SkipMarkers? markers,
  required int customSeconds,
}) {
  final end = markers?.introEnd ?? (customSeconds > 0 ? customSeconds.toDouble() : null);
  if (end == null || end <= 0) return null;
  final start = markers?.introStart ?? 0.0;
  if (start >= end) return null;
  return (start: start, end: end);
}

// -- Per-episode custom intro seconds (CMS) ------------------------------

/// Hive map key for one episode's custom intro seconds: the
/// normalised series title + the episode name. Titles are normalised
/// with [videoNormTitle] (same function the search ranker uses), so
/// "狂飙 (2023)" and "狂飙" share one entry instead of forking per
/// source spelling.
String skipIntroDurationKey({
  required String title,
  required String episodeName,
}) =>
    '${videoNormTitle(title)}|$episodeName';

/// Read the whole custom-durations map defensively: a missing key, a
/// corrupt value or an uninitialised Hive reads as empty, never a
/// throw. Values are clamped to 0–300 on read (the write path clamps
/// too — this is the belt to its braces).
Map<String, int> readSkipIntroDurations() {
  try {
    final raw = HiveStore.box.get(HiveKeys.vodSkipIntroDurations);
    if (raw is! Map) return const {};
    final out = <String, int>{};
    for (final e in raw.entries) {
      final k = e.key;
      final v = e.value;
      if (k is String && v is num) {
        out[k] = v.toInt().clamp(0, 300);
      }
    }
    return out;
  } catch (_) {
    return const {};
  }
}

/// Custom intro seconds for one episode (0 = none set).
int readSkipIntroDuration({
  required String title,
  required String episodeName,
}) =>
    readSkipIntroDurations()[skipIntroDurationKey(
          title: title,
          episodeName: episodeName,
        )] ??
        0;

/// Persist one episode's custom intro seconds (0–300; 0 removes the
/// entry, i.e. "no custom skip"). The write is defensive: a Hive
/// failure is swallowed — a settings write must never break playback
/// or the detail page.
Future<void> saveSkipIntroDuration({
  required String title,
  required String episodeName,
  required int seconds,
}) async {
  try {
    final clamped = seconds.clamp(0, 300);
    final map = Map<String, int>.of(readSkipIntroDurations());
    final key = skipIntroDurationKey(title: title, episodeName: episodeName);
    if (clamped == 0) {
      map.remove(key);
    } else {
      map[key] = clamped;
    }
    await HiveStore.put(HiveKeys.vodSkipIntroDurations, map);
  } catch (_) {}
}

// -- Subtitle time offset -------------------------------------------------

/// Clamp a subtitle offset to the ±10 s range (mpv `sub-delay`).
/// Values inside the range pass through untouched — the 0.1 s step
/// is a UI concern, not a clamp concern.
double clampSubtitleDelay(double seconds) => seconds.clamp(-10.0, 10.0);

/// The persisted subtitle offset (HiveKeys.vodSubtitleDelay, default
/// 0.0), clamped to ±10 s. Any storage failure reads as 0.0.
double vodSubtitleDelaySeconds() {
  try {
    return clampSubtitleDelay(
      HiveStore.getDouble(HiveKeys.vodSubtitleDelay, 0.0),
    );
  } catch (_) {
    return 0.0;
  }
}

// -- Subtitle appearance --------------------------------------------------
//
// Three tiers each, stored as tier keys (see HiveKeys). Defaults are
// the mpv defaults: sub-font-size 55, sub-color white (#FFFFFF,
// 6-digit — mpv's own examples use the 6-digit form, no alpha byte),
// sub-pos 100 (bottom; 0 = top). An unknown stored tier reads as the
// default, never a crash, never a guessed value.

/// Tier key -> mpv `sub-font-size`.
const Map<String, int> vodSubtitleFontSizeValues = {
  'small': 42,
  'medium': 55,
  'large': 70,
};

/// Tier key -> mpv `sub-color` (6-digit #RRGGBB).
const Map<String, String> vodSubtitleColorValues = {
  'white': '#FFFFFF',
  'yellow': '#FFFF00',
  'cyan': '#00FFFF',
};

/// Tier key -> mpv `sub-pos` (0 = top, 100 = bottom; 8 keeps the top
/// row off the very edge of the frame).
const Map<String, double> vodSubtitlePositionValues = {
  'bottom': 100.0,
  'middle': 50.0,
  'top': 8.0,
};

/// The persisted subtitle font size (mpv `sub-font-size`).
int vodSubtitleFontSize() {
  try {
    return vodSubtitleFontSizeValues[
            HiveStore.getString(HiveKeys.vodSubtitleFontSize, 'medium')] ??
        55;
  } catch (_) {
    return 55;
  }
}

/// The persisted subtitle colour (mpv `sub-color`).
String vodSubtitleColor() {
  try {
    return vodSubtitleColorValues[
            HiveStore.getString(HiveKeys.vodSubtitleColor, 'white')] ??
        '#FFFFFF';
  } catch (_) {
    return '#FFFFFF';
  }
}

/// The persisted subtitle position (mpv `sub-pos`).
double vodSubtitlePosition() {
  try {
    return vodSubtitlePositionValues[
            HiveStore.getString(HiveKeys.vodSubtitlePosition, 'bottom')] ??
        100.0;
  } catch (_) {
    return 100.0;
  }
}

// -- Frame interpolation / SDR→HDR (mutually exclusive trio) -------------

/// The persisted interpolation switch (default off). Storage failure
/// reads as off.
bool vodInterpolationSwitchOn() {
  try {
    return HiveStore.getBool(HiveKeys.vodInterpolation, false);
  } catch (_) {
    return false;
  }
}

/// The persisted SDR→HDR switch (default off). Storage failure reads
/// as off.
bool vodSdrToHdrSwitchOn() {
  try {
    return HiveStore.getBool(HiveKeys.vodSdrToHdr, false);
  } catch (_) {
    return false;
  }
}

/// Frame interpolation gate: VOD only, MPV only, switch on, and
/// neither of the other two trio switches on. The caller applies the
/// branches in super-res → interpolation → SDR→HDR order and runs
/// only the first passing one.
bool shouldApplyFrameInterpolation({
  required bool isLive,
  required PlayerEngine engine,
  required bool switchOn,
  required bool superResolutionOn,
  required bool sdrToHdrOn,
}) =>
    !isLive &&
    switchOn &&
    engine == PlayerEngine.mediaKit &&
    !superResolutionOn &&
    !sdrToHdrOn;

/// SDR→HDR gate: same shape as the interpolation gate, last in the
/// trio order.
bool shouldApplySdrToHdr({
  required bool isLive,
  required PlayerEngine engine,
  required bool switchOn,
  required bool superResolutionOn,
  required bool interpolationOn,
}) =>
    !isLive &&
    switchOn &&
    engine == PlayerEngine.mediaKit &&
    !superResolutionOn &&
    !interpolationOn;

/// mpv properties for frame interpolation. `interpolation` requires
/// a `display-*` video-sync or mpv silently disables it, so the
/// three go together; `tscale=oversample` is the interpolation
/// filter. Set at open() only, never mid-playback (runtime enabling
/// may also need `hwdec-extra-frames`).
const Map<String, String> kVodInterpolationProperties = {
  'video-sync': 'display-resample',
  'interpolation': 'yes',
  'tscale': 'oversample',
};

/// mpv properties for SDR→HDR. NOTE the direction: `tone-mapping`
/// itself is HDR→SDR — SDR→HDR is `--inverse-tone-mapping`
/// ("expanding dynamic range… for upscaling SDR content to HDR").
/// `tone-mapping=spline` is only the curve used with it, and
/// `target-trc=pq` + `target-peak=1000` tell mpv to treat the display
/// as an HDR display. `hdr-compute-peak` is deliberately NOT set
/// (it is per-frame peak detection for HDR sources, unrelated to SDR).
const Map<String, String> kVodSdrToHdrProperties = {
  'inverse-tone-mapping': 'yes',
  'tone-mapping': 'spline',
  'target-trc': 'pq',
  'target-peak': '1000',
};
