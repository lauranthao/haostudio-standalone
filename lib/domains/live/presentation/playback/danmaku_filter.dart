// Danmaku content filtering (S3) — similarity / pure-emoji /
// overlong / Douyu suspected-automated, on top of the keyword +
// username block list (DanmakuBlockStore).
//
// Ports of Pure Live's `live_danmaku` package filters
// (`packages/live_danmaku/lib/src/filters/`):
// - [partialRatio] / [DanmakuSimilarityFilter]: the fuzzywuzzy-style
//   partial ratio (0–100) and the cache of recently shown texts.
//   Texts compare as-is (case, emoji and punctuation count); a
//   punctuation/number variant ("666!!!" vs "666") scores high and
//   is hidden at the default threshold 85.
// - Pure-emoji / overlong: Pure Live's `danmakuMessageShape`
//   (`text_shape.dart`) — a message that is nothing but emoticons
//   (Unicode emoji, with spaces at most) or longer than the limit.
//   Our adapters attach no platform emote codes, so bracketed
//   platform emotes (`[笑哭]`) are stripped as emote tokens first —
//   the app-level equivalent of Pure Live's bundled emote lists.
// - Douyu suspected-automated: Pure Live's protocol rule
//   (`sites/douyu.dart`: a `chatmsg` with no `dms` field and `if` !=
//   '1'); the Douyu transport tags it on [LiveMessage.suspectedAutomated].
//
// Order matches Pure Live's `DanmakuMessageFilter.judge`: block list
// first, then emote-only / overlong, then similarity. Super chats
// (gifts) go through the block list only — a gift repeats on purpose,
// so collapsing/similarity must not hide it.

import 'dart:collection';
import 'dart:typed_data';

import '../../../../core/models/live_models.dart';
import '../../../../features/settings/source_stores.dart';
import 'danmaku_block_store.dart';

/// Snapshot of the S3 settings one room applies. Read once per room
/// (and re-read when the settings change); [DanmakuContentFilter]
/// keeps the similarity cache across re-reads.
class DanmakuFilterConfig {
  const DanmakuFilterConfig({
    this.similarityEnabled = true,
    this.similarityThreshold = DanmakuSettings.defaultSimilarityThreshold,
    this.blockEmoteOnly = false,
    this.blockLong = false,
    this.blockLongLength = DanmakuSettings.defaultBlockLongLength,
    this.filterDouyuSuspectedAutomated = false,
    this.blockedKeywords = const [],
    this.blockedUsers = const [],
  });

  factory DanmakuFilterConfig.fromSettings() => DanmakuFilterConfig(
    similarityEnabled: DanmakuSettings.similarityEnabled(),
    similarityThreshold: DanmakuSettings.similarityThreshold(),
    blockEmoteOnly: DanmakuSettings.blockEmoteOnly(),
    blockLong: DanmakuSettings.blockLong(),
    blockLongLength: DanmakuSettings.blockLongLength(),
    filterDouyuSuspectedAutomated: DanmakuSettings.douyuBotFilter(),
    blockedKeywords: DanmakuBlockStore.keywords(),
    blockedUsers: DanmakuBlockStore.usernames(),
  );

  final bool similarityEnabled;

  /// Partial-ratio score (0–100) that hides a text.
  final int similarityThreshold;

  final bool blockEmoteOnly;
  final bool blockLong;

  /// Most characters [blockLong] lets through.
  final int blockLongLength;

  /// Hide Douyu protocol-tagged suspected automated chat.
  final bool filterDouyuSuspectedAutomated;

  final List<String> blockedKeywords;
  final List<String> blockedUsers;
}

/// What the filter did with a message.
enum DanmakuVerdict {
  /// Shown.
  shown,

  /// Hidden by the keyword / username block list, pure-emoji or
  /// overlong block, or the Douyu suspected-automated filter.
  blocked,

  /// Hidden as similar to a text just shown.
  similar,
}

/// Decides which chat messages of one room reach the list.
class DanmakuContentFilter {
  DanmakuContentFilter({
    DanmakuFilterConfig config = const DanmakuFilterConfig(),
    DateTime Function()? clock,
  }) : _similarity = DanmakuSimilarityFilter(clock: clock) {
    this.config = config;
  }

  /// The similarity cache (recently shown texts).
  final DanmakuSimilarityFilter _similarity;

  late DanmakuFilterConfig _config;

  DanmakuFilterConfig get config => _config;

  /// Applies new settings to the following messages, without
  /// reconnecting: the similarity filter takes the new threshold, or
  /// forgets its texts when it is off.
  set config(DanmakuFilterConfig value) {
    _config = value;
    if (!value.similarityEnabled) {
      _similarity.clear();
      return;
    }
    _similarity.updateConfig(
      similarityThreshold: value.similarityThreshold,
    );
  }

  /// Whether [message] should be shown.
  bool shouldShow(LiveMessage message, {required String platform}) =>
      judge(message, platform: platform) == DanmakuVerdict.shown;

  /// Whether an ALREADY-SHOWN message is now blocked by the current
  /// block list / shape / Douyu-bot settings. Used to prune the
  /// displayed list when the settings change mid-room. Similarity is
  /// deliberately NOT re-applied here: re-judging shown texts against
  /// the similarity cache would hide near-duplicates that were
  /// legitimately shown, and mutating the cache on prune would be
  /// wrong.
  bool blocksExisting(LiveMessage message, {required String platform}) {
    if (message.type != LiveMessageType.chat) {
      return _blockedByList(message);
    }
    return _blockedByList(message) ||
        _blockedByShape(message) ||
        _blockedAsDouyuBot(message, platform);
  }

  DanmakuVerdict judge(LiveMessage message, {required String platform}) {
    // Gifts / super chats: block list only (Pure Live D07.1).
    if (message.type != LiveMessageType.chat) {
      return _blockedByList(message)
          ? DanmakuVerdict.blocked
          : DanmakuVerdict.shown;
    }
    if (_blockedByList(message)) return DanmakuVerdict.blocked;
    if (_blockedByShape(message)) return DanmakuVerdict.blocked;
    if (_blockedAsDouyuBot(message, platform)) {
      return DanmakuVerdict.blocked;
    }
    if (!_config.similarityEnabled) return DanmakuVerdict.shown;
    return _similarity.shouldDisplay(message.message)
        ? DanmakuVerdict.shown
        : DanmakuVerdict.similar;
  }

  bool _blockedByList(LiveMessage message) {
    for (final word in _config.blockedKeywords) {
      if (message.message.isNotEmpty &&
          message.message.contains(word)) {
        return true;
      }
    }
    for (final user in _config.blockedUsers) {
      if (message.userName.isNotEmpty &&
          message.userName.contains(user)) {
        return true;
      }
    }
    return false;
  }

  bool _blockedByShape(LiveMessage message) {
    if (!_config.blockEmoteOnly && !_config.blockLong) return false;
    final shape = danmakuTextShape(message.message);
    if (_config.blockEmoteOnly && shape.emoteOnly) return true;
    if (_config.blockLong && shape.length > _config.blockLongLength) {
      return true;
    }
    return false;
  }

  bool _blockedAsDouyuBot(LiveMessage message, String platform) {
    return _config.filterDouyuSuspectedAutomated &&
        platform == 'douyu' &&
        message.suspectedAutomated;
  }

  /// Forgets everything seen (another room).
  void clear() => _similarity.clear();
}

/// The shape of a message for the emote-only / overlong blocks: its
/// length in characters (code points) and whether it is nothing but
/// emoticons. Mirrors Pure Live's `danmakuTextShape`.
///
/// Dart's RegExp does not accept `\p{Extended_Pictographic}`, so the
/// pictograph test is a rune-range check over the
/// Extended_Pictographic set (broad emoji blocks plus the BMP
/// singletons), with joiners (ZWJ / variation selectors / keycap /
/// tags / skin tones) handled separately.
({int length, bool emoteOnly}) danmakuTextShape(String text) {
  // Platform emote tokens (`[笑哭]`) count as emoticons, not text.
  final withoutTokens = text.replaceAll(_bracketedEmote, '');
  final rest = withoutTokens.trim();
  final hasTokens = withoutTokens.length != text.length;
  var hasPictograph = false;
  var allEmoji = rest.isNotEmpty;
  for (final rune in rest.runes) {
    if (_isPictographic(rune)) {
      hasPictograph = true;
    } else if (_isEmojiJoiner(rune) || rune == 0x20) {
      // Joiners and spaces may sit between emoji; they are not
      // pictures themselves.
      continue;
    } else {
      allEmoji = false;
      break;
    }
  }
  return (
    length: rest.runes.length,
    emoteOnly: rest.isEmpty ? hasTokens : allEmoji && hasPictograph,
  );
}

/// True when [text] is nothing but emoji (and whitespace / bracketed
/// platform emote tokens).
bool isPureEmoji(String text) => danmakuTextShape(text).emoteOnly;

/// `[xxx]` platform emote tokens (Bilibili / Douyu / Kuaishou style).
final _bracketedEmote = RegExp(r'\[[^\[\]\s]{1,12}\]');

/// A rune that is an emoji picture (Extended_Pictographic): the broad
/// emoji blocks plus the BMP singletons outside them.
bool _isPictographic(int rune) {
  if (rune >= 0x1F000 && rune <= 0x1FAFF) return true;
  if (rune >= 0x2600 && rune <= 0x27BF) return true;
  if (rune >= 0x2B00 && rune <= 0x2BFF) return true;
  if (rune == 0x00A9 || rune == 0x00AE) return true; // © ®
  if (rune == 0x203C || rune == 0x2049) return true; // ‼ ⁉
  if (rune == 0x2122 || rune == 0x2139) return true; // ™ ℹ
  if (rune >= 0x2194 && rune <= 0x2199) return true;
  if (rune >= 0x21A9 && rune <= 0x21AA) return true;
  if (rune == 0x231A || rune == 0x231B || rune == 0x2328) return true;
  if (rune == 0x23CF) return true;
  if (rune >= 0x23E9 && rune <= 0x23F3) return true;
  if (rune >= 0x23F8 && rune <= 0x23FA) return true;
  if (rune == 0x24C2) return true;
  if (rune >= 0x25AA && rune <= 0x25AB) return true;
  if (rune == 0x25B6 || rune == 0x25C0) return true;
  if (rune >= 0x25FB && rune <= 0x25FE) return true;
  if (rune >= 0x2934 && rune <= 0x2935) return true;
  if (rune == 0x3030 || rune == 0x303D) return true;
  if (rune == 0x3297 || rune == 0x3299) return true;
  return false;
}

/// A rune that joins or changes emoji (skin tones, flags, keycaps,
/// tags) but is not a picture itself.
bool _isEmojiJoiner(int rune) {
  if (rune == 0x200D) return true; // ZWJ
  if (rune >= 0xFE00 && rune <= 0xFE0F) return true; // variation selectors
  if (rune == 0x20E3) return true; // combining enclosing keycap
  if (rune >= 0xE0020 && rune <= 0xE007F) return true; // tags
  if (rune >= 0x1F3FB && rune <= 0x1F3FF) return true; // skin tones
  return false;
}

/// Hides a text that is too similar to one shown in the last few
/// seconds. Port of Pure Live's `DanmakuSimilarityFilter`
/// (`packages/live_danmaku/lib/src/filters/similarity_filter.dart`):
///
/// - Texts are trimmed and otherwise compared as they are: case,
///   emoji and punctuation count.
/// - An empty text is never shown.
/// - A text equal to a cached one, or whose [partialRatio] with one
///   of the newest [maxComparisons] cached texts reaches
///   [similarityThreshold], is hidden and refreshes that entry
///   (moves it to the newest and restarts its time).
/// - Entries older than [cacheDuration] are dropped; at most
///   [maxCacheSize] are kept.
final class DanmakuSimilarityFilter {
  DanmakuSimilarityFilter({
    int similarityThreshold = DanmakuSettings.defaultSimilarityThreshold,
    this.cacheDuration = const Duration(seconds: 3),
    int maxCacheSize = 100,
    int maxComparisons = 96,
    DateTime Function()? clock,
  }) : _similarityThreshold = similarityThreshold.clamp(0, 100),
       _maxCacheSize = maxCacheSize.clamp(1, 1000),
       maxComparisons = maxComparisons.clamp(1, 256),
       _clock = clock ?? DateTime.now;

  int _similarityThreshold;
  Duration cacheDuration;
  int _maxCacheSize;
  final DateTime Function() _clock;
  final LinkedHashMap<String, _Cached> _cache = LinkedHashMap();

  /// Lowest score that counts as similar.
  int get similarityThreshold => _similarityThreshold;

  /// Most texts kept.
  int get maxCacheSize => _maxCacheSize;

  /// Most cached texts one incoming text is compared with (the newest
  /// ones): bounds the work per message while the cache keeps its
  /// full history.
  final int maxComparisons;

  /// Texts cached now.
  int get cacheSize => _cache.length;

  /// Changes the settings; omitted ones stay. A smaller [maxCacheSize]
  /// drops the oldest entries at once.
  void updateConfig({int? similarityThreshold, Duration? cacheDuration, int? maxCacheSize}) {
    if (similarityThreshold != null) {
      _similarityThreshold = similarityThreshold.clamp(0, 100);
    }
    if (cacheDuration != null) this.cacheDuration = cacheDuration;
    if (maxCacheSize != null) {
      _maxCacheSize = maxCacheSize.clamp(1, 1000);
      _trim();
    }
  }

  /// Whether [text] should be shown; a shown text becomes a reference.
  bool shouldDisplay(String text) {
    final normalized = text.trim();
    if (normalized.isEmpty) return false;
    final now = _clock();
    _cache.removeWhere(
      (_, cached) => now.difference(cached.lastSeenAt) > cacheDuration,
    );

    final exact = _cache[normalized];
    if (exact != null) {
      _refresh(normalized, exact, now);
      return false;
    }
    var skipped = (_cache.length - maxComparisons).clamp(0, _cache.length);
    for (final MapEntry(:key, :value) in _cache.entries) {
      if (skipped > 0) {
        skipped--;
        continue;
      }
      if (partialRatio(value.text, normalized) >= _similarityThreshold) {
        _refresh(key, value, now);
        return false;
      }
    }
    _cache[normalized] = _Cached(normalized, now);
    _trim();
    return true;
  }

  /// Forgets every reference.
  void clear() => _cache.clear();

  void _refresh(String key, _Cached cached, DateTime now) {
    cached.lastSeenAt = now;
    _cache
      ..remove(key)
      ..[key] = cached;
  }

  void _trim() {
    while (_cache.length > _maxCacheSize) {
      _cache.remove(_cache.keys.first);
    }
  }
}

final class _Cached {
  _Cached(this.text, this.lastSeenAt);

  final String text;
  DateTime lastSeenAt;
}

/// How similar the shorter of two texts is to the best-aligned part
/// of the longer one, 0–100: the "partial ratio" Pure Live's
/// similarity filter took from the `fuzzywuzzy` package (1.2.0).
/// Port of `packages/live_danmaku/lib/src/filters/partial_ratio.dart`
/// (itself an independent implementation of the same published
/// algorithm, written to give the same scores):
///
/// 1. Texts are compared as UTF-16 code units, case-sensitively.
///    The shorter text is `s1` when it is strictly shorter, otherwise
///    `s2`.
/// 2. The candidate alignments come from one Levenshtein edit script
///    from the shorter to the longer text. Every run of equal
///    characters on that path (and the common prefix) is an alignment
///    at offset `longer index − shorter index`; the end of both texts
///    is one more.
/// 3. Each alignment picks the window of the longer text that starts
///    at the offset (at least 0) and is as long as the shorter text
///    (cut at the end). It scores `2 × LCS / (length of both)`, the
///    indel similarity.
/// 4. A score above 0.995 answers 100 at once; otherwise the best
///    score times 100, rounded. Two empty texts score 0.
int partialRatio(String s1, String s2) {
  final (shorter, longer) = s1.length < s2.length ? (s1, s2) : (s2, s1);
  final a = shorter.codeUnits;
  final b = longer.codeUnits;
  var best = -1.0;
  for (final offset in _alignments(a, b)) {
    final start = offset > 0 ? offset : 0;
    final end = start + a.length < b.length ? start + a.length : b.length;
    final total = a.length + end - start;
    if (total == 0) continue;
    final ratio = (2 * _lcs(a, b, start, end)) / total;
    if (ratio > 0.995) return 100;
    if (ratio > best) best = ratio;
  }
  return best < 0 ? 0 : (100 * best).round();
}

/// Offsets (`longer index − shorter index`) of the runs of equal
/// characters on the edit path from [a] to [b], plus the end of both
/// texts.
Set<int> _alignments(List<int> a, List<int> b) {
  final offsets = {b.length - a.length};
  var prefix = 0;
  while (prefix < a.length && prefix < b.length && a[prefix] == b[prefix]) {
    prefix++;
  }
  if (prefix > 0) offsets.add(0);
  var suffix = 0;
  while (suffix < a.length - prefix &&
      suffix < b.length - prefix &&
      a[a.length - 1 - suffix] == b[b.length - 1 - suffix]) {
    suffix++;
  }
  final rows = a.length - prefix - suffix;
  final columns = b.length - prefix - suffix;
  if (rows == 0 && columns == 0) return offsets;

  // Unit-cost edit distances between the middle parts, row-major.
  final width = columns + 1;
  final cost = Uint32List((rows + 1) * width);
  for (var j = 0; j <= columns; j++) {
    cost[j] = j;
  }
  for (var i = 1; i <= rows; i++) {
    final row = i * width;
    final above = row - width;
    final char = a[prefix + i - 1];
    cost[row] = i;
    for (var j = 1; j <= columns; j++) {
      final diagonal =
          cost[above + j - 1] + (char == b[prefix + j - 1] ? 0 : 1);
      final left = cost[row + j - 1] + 1;
      final up = cost[above + j] + 1;
      var value = diagonal < left ? diagonal : left;
      if (up < value) value = up;
      cost[row + j] = value;
    }
  }

  // Walk back from the end; `run` is -1 inside an insert run, 1 inside
  // a delete run, 0 otherwise.
  var i = rows;
  var j = columns;
  var run = 0;
  while (i > 0 || j > 0) {
    final here = cost[i * width + j];
    if (i > 0 &&
        j > 0 &&
        here == cost[(i - 1) * width + j - 1] &&
        a[prefix + i - 1] == b[prefix + j - 1]) {
      offsets.add(j - i);
      i--;
      j--;
      run = 0;
    } else if (run < 0 && j > 0 && here == cost[i * width + j - 1] + 1) {
      j--;
    } else if (run > 0 && i > 0 && here == cost[(i - 1) * width + j] + 1) {
      i--;
    } else if (i > 0 &&
        j > 0 &&
        here == cost[(i - 1) * width + j - 1] + 1) {
      i--;
      j--;
      run = 0;
    } else if (run == 0 && j > 0 && here == cost[i * width + j - 1] + 1) {
      j--;
      run = -1;
    } else if (run == 0 && i > 0 && here == cost[(i - 1) * width + j] + 1) {
      i--;
      run = 1;
    } else if (run != 0) {
      // Not reachable in an edit matrix; ending the run keeps the
      // walk finite.
      run = 0;
    } else {
      break;
    }
  }
  return offsets;
}

/// Length of the longest common subsequence of [a] and `b[start, end)`.
int _lcs(List<int> a, List<int> b, int start, int end) {
  final length = end - start;
  if (a.isEmpty || length <= 0) return 0;
  var previous = Uint32List(length + 1);
  var current = Uint32List(length + 1);
  for (final char in a) {
    for (var k = 1; k <= length; k++) {
      if (char == b[start + k - 1]) {
        current[k] = previous[k - 1] + 1;
      } else {
        current[k] = previous[k] > current[k - 1]
            ? previous[k]
            : current[k - 1];
      }
    }
    final swap = previous;
    previous = current;
    current = swap;
  }
  return previous[length];
}
