// HAo Studio standalone — app constants (v1.0.4).
//
// Version rules (fixes spec fix 8): version constant is '1.0.4', build 5,
// pubspec 1.0.4+5. Update check fetches version.json from the shop server
// FIRST (reachable from mainland China — GitHub raw is blocked/slow there)
// and falls back to the GitHub raw URL. Semver comparison is NUMERIC,
// part by part — never lexicographic, never against a changelog date tag
// or a cache-buster.

/// Current app version (CFBundleShortVersionString).
const String kAppVersion = '1.0.5';

/// Current build number (CFBundleVersion).
const int kAppBuild = 6;

/// Online-update manifest (primary). Served from the shop server, which
/// is reachable from mainland China. The published version.json in the
/// shop's public/ must be bumped to version 1.0.4 / build 5 with the new
/// IPA URL at release time.
const String kVersionUrl =
    'https://chen-hao-shop-production.up.railway.app/version.json';

/// Online-update manifest (fallback). GitHub raw is slow/blocked in
/// mainland China and its CDN cache lags hours behind a push, so it is
/// only tried when the shop server fails.
const String kVersionUrlFallback =
    'https://raw.githubusercontent.com/lauranthao/haostudio-standalone/master/version.json';

/// Compare two dotted semver strings numerically, part by part.
/// Missing parts count as 0; the first differing part decides; equal means
/// not newer. Non-numeric input falls back to plain string comparison and
/// never throws.
///
/// Returns < 0 if [a] < [b], 0 if equal, > 0 if [a] > [b].
int compareSemver(String a, String b) {
  final aParts = a.trim().split('.');
  final bParts = b.trim().split('.');
  final len = aParts.length > bParts.length ? aParts.length : bParts.length;
  for (var i = 0; i < len; i++) {
    final aPart = i < aParts.length ? aParts[i] : '0';
    final bPart = i < bParts.length ? bParts[i] : '0';
    final aNum = int.tryParse(aPart);
    final bNum = int.tryParse(bPart);
    if (aNum != null && bNum != null) {
      if (aNum != bNum) return aNum.compareTo(bNum);
    } else {
      final cmp = aPart.compareTo(bPart);
      if (cmp != 0) return cmp;
    }
  }
  return 0;
}

/// True when [candidate] is a newer version than [current].
bool isNewerVersion(String candidate, String current) =>
    compareSemver(candidate, current) > 0;
