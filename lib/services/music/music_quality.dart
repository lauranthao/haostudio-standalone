// Audio quality — ported from resolvers.js / app.js.
//
// MASTER FINDING (investigated 2026-11-16): there is NO Master tier in the
// old code. Evidence:
//  - `QUALITY_CHAIN = ['hires', 'lossless', '320k', '128k']`
//    (resolvers.js:26); `QRANK = {hires:4, lossless:3, '320k':2, '128k':1}`.
//  - The quality sheet in web/index.html has exactly FOUR buttons
//    (hires / lossless / 320k / 128k); i18n has only qHires / qLossless /
//    qHigh / qStd — no qMaster key in any locale.
//  - `grep -i master` over resolvers.js / app.js / sources.js finds only
//    the GitHub `master` branch name in the version.json URL.
//  - The QQ `tang` resolver reads a `song_play_url_pq` field for the hires
//    tier, but the old code folds that field INTO the hires tier (it is the
//    hires-tier URL source), never a separate selectable tier — and no
//    other platform exposes an equivalent distinct tier, so there is no
//    parameter that could request "Master" above hires from any resolver.
// The 5-option sheet in the product notes is aspirational; inventing a
// Master tier would label ordinary hires streams as Master. This port
// therefore ships the 4 real tiers. If chen wants a Master row, it needs a
// resolver that can actually return a distinct Master stream first.

/// The four real quality tiers, best first.
enum AudioQuality { hires, lossless, q320k, q128k }

extension AudioQualityX on AudioQuality {
  String get code {
    switch (this) {
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
  /// 320k→高品质 320k, 128k→标准 128k.
  String get label {
    switch (this) {
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
String srcQuality(AudioQuality q) =>
    (q == AudioQuality.hires || q == AudioQuality.lossless) ? 'flac' : q.code;

String songLevel(AudioQuality q) {
  if (q == AudioQuality.hires || q == AudioQuality.lossless) return 'lossless';
  if (q == AudioQuality.q320k) return 'exhigh';
  return 'standard';
}

int gdBr(AudioQuality q) {
  if (q == AudioQuality.hires || q == AudioQuality.lossless) return 999;
  if (q == AudioQuality.q320k) return 320;
  return 128;
}

int kwBr(AudioQuality q) {
  if (q == AudioQuality.hires || q == AudioQuality.lossless) return 1;
  if (q == AudioQuality.q320k) return 2;
  return 3;
}

String lxQuality(AudioQuality q) {
  if (q == AudioQuality.hires) return 'hires';
  if (q == AudioQuality.lossless) return 'flac';
  return q.code;
}

String wwwwebQuality(AudioQuality q, String platformCode) {
  if (platformCode == 'kw') {
    return (q == AudioQuality.hires || q == AudioQuality.lossless)
        ? '320k'
        : q.code;
  }
  return (q == AudioQuality.hires || q == AudioQuality.lossless)
      ? 'flac'
      : q.code;
}

/// extraQuality: what a resolver ACTUALLY returns at the requested tier
/// (resolvers.js:82-96). Used for candidate sorting and the quality badge.
/// Undeclared resolvers count as 320k.
AudioQuality extraQuality(String key, AudioQuality q, String platformCode) {
  switch (key) {
    case 'gd':
    case 'yutang':
    case 'kangqi':
    case 'qjqq':
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
