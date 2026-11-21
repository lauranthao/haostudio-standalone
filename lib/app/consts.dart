// HAo Studio standalone — app constants (v1.0.4).
//
// Version rules (fixes spec fix 8): version constant is '1.0.4', build 5,
// pubspec 1.0.4+5. Update check fetches version.json from the shop server
// FIRST (reachable from mainland China — GitHub raw is blocked/slow there)
// and falls back to the GitHub raw URL. Semver comparison is NUMERIC,
// part by part — never lexicographic, never against a changelog date tag
// or a cache-buster.

/// Current app version (CFBundleShortVersionString).
const String kAppVersion = '1.1.6';

/// Current build number (CFBundleVersion).
const int kAppBuild = 28;

/// Online-update manifest (primary). Gitee raw, hosted in mainland China,
/// so the check works from chen's phone — the shop server (Railway US)
/// is slow from China and its free tier returns 502 while deploying,
/// which is what broke the check. Gitee raw redirects (302) to its file
/// CDN; Dio follows redirects. The repo is public, the manifest holds
/// only public release info (version/build/size/IPA URL/changelog).
const String kVersionUrl =
    'https://gitee.com/chenhao030610/chen-hao-shop/raw/master/version.json';

/// Online-update manifest (fallback). The shop server, kept as the
/// second source when Gitee is unreachable. Its version.json is updated
/// at release time alongside the Gitee copy — both must agree.
const String kVersionUrlFallback =
    'https://chen-hao-shop-production.up.railway.app/version.json';

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
