// Audio quality — ported from resolvers.js / app.js.
//
// MASTER FINDING (verified live 2026-11-16, supersedes the old "no
// Master" note): Master IS a real, distinct tier — not a relabelled
// hires stream. Evidence:
//  - ikun script (research/kmusic/ikun音源.js:13): wy quality list
//    ["128k","320k","flac","flac24bit","hires","atmos","master"].
//  - zddyr API, called live from this VM:
//    GET https://yy.zddyr.top/lx/api/?source=wy&songmid=1851244158
//    &quality=master → code 200, real .flac URL,
//    "quality":"master", "quality_requested":"master",
//    "quality_fallback":false, br 4.27M (vs hires control br 694782,
//    quality "flac"). Same result via the xinghai (token) path.
//  - ikun's own API (api.ikunshare.com) is DEAD — re-verified
//    2026-11-23 (curl 000, both songs) — and the ikun script +
//    resolver were DELETED the same day, so the master tier does
//    NOT depend on it: zddyr/xinghai already serve master.
//  - huibq (lxmusicapi.onrender.com) returns 503 "Service Suspended"
//    as of 2026-11-16 — the order-1 resolver is down (pre-existing,
//    not caused by this change; the loop falls through to others).
// Honesty rule: only resolvers with a real Master path may claim
// Master (see [extraQuality]). A below-target URL plays immediately
// at its REAL tier (first-playable-wins, chen 2026-11-17): the loop
// never drops a playable candidate to hunt for Master, and
// [extraQuality] caps every non-master resolver's label at hires,
// so the badge shows the tier actually played, never a Master label
// on a hires stream.
// i18n note: this app has NO locale system (no .arb /
// AppLocalizations; labels are hardcoded here, as for the other
// tiers), so there is no qMaster locale key to add — Master reuses
// the same hardcoded-label pattern ("Master").

/// The five real quality tiers, best first.
enum AudioQuality { master, hires, lossless, q320k, q128k }

extension AudioQualityX on AudioQuality {
  String get code {
    switch (this) {
      case AudioQuality.master:
        return 'master';
      case AudioQuality.hires:
        return 'hires';
      case AudioQuality.lossless:
        return 'lossless';
      case AudioQuality.q320k:
        return '320k';
      case AudioQuality.q128k:
        return '128k';
    }
  }

  static AudioQuality fromCode(String? code) {
    switch (code) {
      case 'master':
        return AudioQuality.master;
      case 'lossless':
        return AudioQuality.lossless;
      case '320k':
        return AudioQuality.q320k;
      case '128k':
        return AudioQuality.q128k;
      case 'hires':
      default:
        return AudioQuality.hires;
    }
  }

  /// qLabel (app.js:2149): hires→Hi-Res 24bit, lossless→无损 FLAC,
  /// 320k→高品质 320k, 128k→标准 128k. Master is the tier above Hi-Res.
  String get label {
    switch (this) {
      case AudioQuality.master:
        return 'Master';
      case AudioQuality.hires:
        return 'Hi-Res 24bit';
      case AudioQuality.lossless:
        return '无损 FLAC';
      case AudioQuality.q320k:
        return '高品质 320k';
      case AudioQuality.q128k:
        return '标准 128k';
    }
  }

  /// Short badge label shown below the player cover.
  String get badgeLabel {
    switch (this) {
      case AudioQuality.master:
        return 'Master';
      case AudioQuality.hires:
        return 'Hi-Res';
      case AudioQuality.lossless:
        return '无损 FLAC';
      case AudioQuality.q320k:
        return '320k';
      case AudioQuality.q128k:
        return '128k';
    }
  }

  int get rank {
    switch (this) {
      case AudioQuality.master:
        return 5;
      case AudioQuality.hires:
        return 4;
      case AudioQuality.lossless:
        return 3;
      case AudioQuality.q320k:
        return 2;
      case AudioQuality.q128k:
        return 1;
    }
  }
}

/// Downgrade chain from the requested tier (resolvers.js:383-385).
const List<AudioQuality> kQualityChain = [
  AudioQuality.master,
  AudioQuality.hires,
  AudioQuality.lossless,
  AudioQuality.q320k,
  AudioQuality.q128k,
];

List<AudioQuality> qualityChainFrom(AudioQuality requested) {
  final idx = kQualityChain.indexOf(requested);
  if (idx < 0) return List.of(kQualityChain);
  return kQualityChain.sublist(idx);
}

/// Quality parameter mappings (resolvers.js:65-78).
///
/// Master maps to each API's BEST KNOWN parameter — never to a
/// parameter the API does not understand, and never to a low tier:
/// huibq/wwwweb get 'flac' (they have no master value), NCM-level
/// APIs get 'lossless', bitrate APIs get their top value. Only
/// [lxQuality] passes 'master' through, because the zddyr/xinghai
/// LX APIs genuinely accept it (verified live, see header).
String srcQuality(AudioQuality q) {
  if (q == AudioQuality.master) return 'flac';
  return (q == AudioQuality.hires || q == AudioQuality.lossless)
      ? 'flac'
      : q.code;
}

String songLevel(AudioQuality q) {
  if (q == AudioQuality.master) return 'lossless';
  if (q == AudioQuality.hires || q == AudioQuality.lossless) return 'lossless';
  if (q == AudioQuality.q320k) return 'exhigh';
  return 'standard';
}

int gdBr(AudioQuality q) {
  if (q == AudioQuality.master) return 999;
  if (q == AudioQuality.hires || q == AudioQuality.lossless) return 999;
  if (q == AudioQuality.q320k) return 320;
  return 128;
}

int kwBr(AudioQuality q) {
  if (q == AudioQuality.master) return 1;
  if (q == AudioQuality.hires || q == AudioQuality.lossless) return 1;
  if (q == AudioQuality.q320k) return 2;
  return 3;
}

String lxQuality(AudioQuality q) {
  if (q == AudioQuality.master) return 'master';
  if (q == AudioQuality.hires) return 'hires';
  if (q == AudioQuality.lossless) return 'flac';
  return q.code;
}

String wwwwebQuality(AudioQuality q, String platformCode) {
  if (q == AudioQuality.master) return 'flac';
  if (platformCode == 'kw') {
    return (q == AudioQuality.hires || q == AudioQuality.lossless)
        ? '320k'
        : q.code;
  }
  return (q == AudioQuality.hires || q == AudioQuality.lossless)
      ? 'flac'
      : q.code;
}

/// Pick the quality string to ask an LX script for, given the
/// qualities that script declares for the platform. Returns null
/// when the script cannot serve the requested tier at all (the
/// caller then skips the script; the resolver chain downgrades).
/// - master: only a literal 'master' counts — never substitute hires.
/// - hires: 'hires', else 'flac24bit', else 'flac'.
/// - lossless: 'flac', else 'flac24bit'.
String? lxQualityForScript(AudioQuality q, List<String> available) {
  switch (q) {
    case AudioQuality.master:
      return available.contains('master') ? 'master' : null;
    case AudioQuality.hires:
      if (available.contains('hires')) return 'hires';
      if (available.contains('flac24bit')) return 'flac24bit';
      if (available.contains('flac')) return 'flac';
      return null;
    case AudioQuality.lossless:
      if (available.contains('flac')) return 'flac';
      if (available.contains('flac24bit')) return 'flac24bit';
      return null;
    case AudioQuality.q320k:
      return available.contains('320k') ? '320k' : null;
    case AudioQuality.q128k:
      return available.contains('128k') ? '128k' : null;
  }
}

/// extraQuality: what a resolver ACTUALLY returns at the requested tier
/// (resolvers.js:82-96). Used for candidate sorting and the quality badge.
/// Undeclared resolvers count as 320k.
///
/// Master gate: only resolvers with a verified real Master path may
/// claim Master — 'zddyr' and 'xinghai' (LX APIs). Every other
/// resolver caps at hires: its best output at the master tier is a
/// hires-level stream, and the resolver loop drops non-master
/// candidates at that tier, so these never surface as Master.
/// (2026-11-23: 'ikun' removed — direct ikun API dead, resolver
/// deleted.)
///
/// LX scripts ('lx:*') are capped at hires here too (M-P0-1): a
/// script that returns a bare URL string carries NO tier signal, so
/// its declared label must not claim Master — the script only gets
/// a master job because it lists 'master' for the platform, which
/// is a claim, not a verification. A script keeps Master ONLY when
/// it returns a `{url, quality: 'master'}` map: that report travels
/// as [actualQuality] ([LxScriptEngine.getMusicUrlWithTier] /
/// `reportedTierFor`) and the resolver loop labels the result with
/// it instead of this declared label.
///
/// This is the DECLARED label only (used when a resolver reports no
/// tier). The actual label is verified per response (P1-L1):
/// zddyr/xinghai must answer `quality == 'master'` with no
/// `quality_fallback` or the result is labelled hires
/// ([MusicResolvers._lxApiServedTier]); a script that returns a
/// `{url, quality}` map is held to the tier it reports
/// ([LxScriptEngine.getMusicUrlWithTier]).
AudioQuality extraQuality(String key, AudioQuality q, String platformCode) {
  if (q == AudioQuality.master) {
    switch (key) {
      case 'zddyr':
      case 'xinghai':
        return AudioQuality.master;
      default:
        // M-P0-1: 'lx:*' included — a bare-string script URL has no
        // tier signal, so it caps at hires; only a map-reported
        // quality: 'master' (via actualQuality) keeps Master.
        return AudioQuality.hires;
    }
  }
  // LX script jobs only exist when the script declares the requested
  // tier (scriptJobsFor filters by lxQualityForScript), so a script
  // URL IS the requested tier — not 320k. Labelling it 320k made the
  // resolver loop hunt for a better URL it already had, and mis-set
  // the quality badge (a hires script result showed as 320k).
  if (key.startsWith('lx:')) return q;
  switch (key) {
    case 'gd':
    case 'zddyr':
    case 'oiapi_kw':
    case 'tang':
    case 'zddyr_kw':
      return q;
    case 'xinghai':
      return platformCode == 'kw' ? AudioQuality.q128k : q;
    case 'wwwweb':
      if (q == AudioQuality.hires) return AudioQuality.lossless;
      if (platformCode == 'kw' &&
          (q == AudioQuality.hires || q == AudioQuality.lossless)) {
        return AudioQuality.q320k;
      }
      return q;
    case 'huibq':
      return (q == AudioQuality.hires || q == AudioQuality.lossless)
          ? AudioQuality.q320k
          : q;
    default:
      return AudioQuality.q320k;
  }
}
