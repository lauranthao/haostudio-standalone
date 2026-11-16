// Live recovery (fix 3 + study §2.9 / §B).
//
// Live play URLs expire. Huya's anti-code is shared across ALL lines of a
// room and expires ~100-130 s after issue — so NEVER retry the same URL.
// Fixed order on failure:
//   (1) try the NEXT CDN line of the current quality (same URL family,
//       different host — no network request, just open the next URL);
//   (2) only after every line fails, re-parse a FRESH URL from the
//       platform (resolve again, do not reuse the old response);
//   (3) throttle the fresh-URL fetch to at most once per 60 s so a dead
//       room cannot loop forever; if the fresh fetch also fails or is
//       throttled, show the failure card.
// Manual retry follows the same order — it must fetch fresh, never replay
// the dead URL. While a fresh fetch is in flight show loading and hide the
// failure buttons; if no new stream arrives within 10 s, restore the
// failure UI. Clear any "already posted this URL" dedupe before a retry,
// so a retry tapped within 2 s of the last post is not silently swallowed.
//
// Proactive refresh (Huya): prefetch a new URL ~100 s after issue, hard
// expiry ~125 s. Lines are identified by URL (CDN + path + credential
// family), NOT by index — a refresh can turn a TX FLV line into TX HLS.

import 'dart:async';

import '../../core/models/live_models.dart';
import '../../shared/platforms/live_site.dart';

class LiveRecovery {
  LiveRecovery({
    required this.site,
    required this.room,
    this.quality,
  });

  final LiveSite site;
  final LiveRoom room;
  final LivePlayQuality? quality;

  /// Current resolved lines, in platform order. Index = line.
  List<String> lines = [];

  /// Per-URL stream facts, same order as [lines] (declared format wins
  /// over URL detection — a refresh can turn a TX FLV line into TX HLS,
  /// and the session must be told the new fact, not guess from the URL).
  List<LiveStreamFacts> facts = [];

  /// Declared format for one line index (falls back to unknown facts).
  LiveStreamFacts factsFor(int index) {
    if (index >= 0 && index < facts.length) return facts[index];
    return const LiveStreamFacts(format: 'other');
  }

  /// Index of the line currently playing.
  int currentLineIndex = 0;

  /// When the current resolution was issued (for 100 s / 125 s math).
  DateTime? issuedAt;

  DateTime? _lastFreshFetchAt;
  Timer? _prefetchTimer;
  bool _disposed = false;

  static const Duration freshFetchThrottle = Duration(seconds: 60);
  static const Duration freshFetchTimeout = Duration(seconds: 10);
  static const Duration prefetchAfterIssue = Duration(seconds: 100);
  static const Duration hardExpiryAfterIssue = Duration(seconds: 125);

  String? get currentUrl =>
      lines.isEmpty ? null : lines[currentLineIndex % lines.length];

  /// The next line, wrapping around: (currentLineIndex + 1) % lineCount.
  String? get nextLineUrl {
    if (lines.length < 2) return null;
    return lines[(currentLineIndex + 1) % lines.length];
  }

  /// Advance to the next line WITHOUT a network request. Returns the URL
  /// to open, or null when there is no other line.
  String? advanceLine() {
    final next = nextLineUrl;
    if (next == null) return null;
    currentLineIndex = (currentLineIndex + 1) % lines.length;
    return next;
  }

  /// Re-parse a FRESH resolution from the platform. Never returns the old
  /// URLs: recovery must RE-PARSE, never retry the same URL. Returns null
  /// when throttled, timed out, or the room is offline / parse failed.
  /// A null result means: show the failure card, do not loop.
  Future<LivePlayUrlResolution?> fetchFresh() async {
    final now = DateTime.now();
    if (_lastFreshFetchAt != null &&
        now.difference(_lastFreshFetchAt!) < freshFetchThrottle) {
      return null;
    }
    _lastFreshFetchAt = now;
    try {
      final resolution = await site
          .resolvePlayUrlsForRecovery(liveRoom: room, quality: quality)
          .timeout(freshFetchTimeout);
      if (resolution.urls.isEmpty) return null;
      // Capture the previously playing URL BEFORE replacing the list:
      // currentUrl reads from [lines], so evaluating it after the
      // assignment would return a new-list URL at the old index — the
      // exact index-identity bug the Huya audit forbids.
      final previousUrl = currentUrl;
      lines = resolution.urls;
      facts = resolution.streamFacts;
      issuedAt = resolution.issuedAt ?? now;
      // Keep the user's format/line family: match the new list to the
      // previously playing URL by CDN + path, not by index.
      currentLineIndex = _matchLineIndex(resolution.urls, previousUrl);
      schedulePrefetch();
      return resolution;
    } on TimeoutException {
      return null;
    } catch (_) {
      return null;
    }
  }

  /// Match a previously playing URL in a refreshed list by CDN + media
  /// path, ignoring signature query changes. Falls back to line 0.
  ///
  /// Two passes: exact host + path first; then CDN token + media id.
  /// The second pass matters when a refresh changes a line's FORMAT
  /// (TX FLV -> TX HLS): the host changes (tx.flv… -> tx.hls…) and the
  /// path suffix changes (.flv -> .m3u8), so exact matching misses the
  /// same line. The CDN token (first host label) + media id (last path
  /// segment minus its format extension) still identify it.
  int _matchLineIndex(List<String> urls, String? previousUrl) {
    if (previousUrl == null || urls.isEmpty) return 0;
    final prev = Uri.tryParse(previousUrl);
    if (prev == null) return 0;
    for (var i = 0; i < urls.length; i++) {
      final candidate = Uri.tryParse(urls[i]);
      if (candidate == null) continue;
      if (candidate.host == prev.host && candidate.path == prev.path) {
        return i;
      }
    }
    for (var i = 0; i < urls.length; i++) {
      final candidate = Uri.tryParse(urls[i]);
      if (candidate == null) continue;
      if (_cdnToken(candidate.host) == _cdnToken(prev.host) &&
          _mediaId(candidate.path) == _mediaId(prev.path)) {
        return i;
      }
    }
    return 0;
  }

  /// First host label: the CDN token (tx / al / hs …).
  static String _cdnToken(String host) => host.split('.').first;

  /// Last path segment minus its format extension (1.flv / 1.m3u8 -> 1).
  static String _mediaId(String path) {
    final last = path.split('/').last;
    final dot = last.lastIndexOf('.');
    return dot > 0 ? last.substring(0, dot) : last;
  }

  /// Schedule the proactive prefetch ~100 s after issue. The caller passes
  /// the prefetch callback (open the prefetched URL only after its first
  /// frame is verified — never swap in an unverified candidate).
  ///
  /// Public so the room page can arm it after the INITIAL resolve too:
  /// fetchFresh arms it on the recovery path, but the happy path never
  /// calls fetchFresh — without this the 100 s prefetch never fires and
  /// the URL dies at its ~125 s hard expiry with no prefetch.
  void schedulePrefetch() {
    _prefetchTimer?.cancel();
    if (issuedAt == null) return;
    final delay = issuedAt!.add(prefetchAfterIssue).difference(DateTime.now());
    if (delay.isNegative) return;
    _prefetchTimer = Timer(delay, () {
      if (_disposed) return;
      // The room page observes [prefetchDue] via this timer's callback.
      onPrefetchDue?.call();
    });
  }

  /// Called when the ~100 s prefetch point is reached.
  void Function()? onPrefetchDue;

  /// True when the current URL is past its hard expiry (~125 s).
  bool get isExpired {
    if (issuedAt == null) return false;
    return DateTime.now().isAfter(issuedAt!.add(hardExpiryAfterIssue));
  }

  void dispose() {
    _disposed = true;
    _prefetchTimer?.cancel();
  }
}
