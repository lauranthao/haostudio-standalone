// Smart Rules (build 29, music) — 按规则自动生成队列/歌单.
//
// Pure local rules over data the app already has: favourites,
// 最近播放, the listen log. No network, no login, no server. The
// page (smart_rules_page.dart) shows each rule with its live count;
// tapping one builds the queue and plays it.

import 'music_models.dart';

enum SmartRule {
  recentFavourites,
  unplayedFavourites,
  sameArtistDeepDive,
  longUnplayed,
  dailyMix,
}

extension SmartRuleX on SmartRule {
  String get id => name;

  static SmartRule fromId(String? id) => switch (id) {
        'unplayedFavourites' => SmartRule.unplayedFavourites,
        'sameArtistDeepDive' => SmartRule.sameArtistDeepDive,
        'longUnplayed' => SmartRule.longUnplayed,
        'dailyMix' => SmartRule.dailyMix,
        _ => SmartRule.recentFavourites,
      };

  String get title => switch (this) {
        SmartRule.recentFavourites => '最近常听的收藏',
        SmartRule.unplayedFavourites => '收藏里好久没听',
        SmartRule.sameArtistDeepDive => '同艺人深挖',
        SmartRule.longUnplayed => '好久没听的老歌',
        SmartRule.dailyMix => '今日混搭',
      };

  String get subtitle => switch (this) {
        SmartRule.recentFavourites => '按播放次数排的收藏',
        SmartRule.unplayedFavourites => '收藏了却很少放的歌',
        SmartRule.sameArtistDeepDive => '你听得最多的歌手的收藏与最近播放',
        SmartRule.longUnplayed => '30 天以上没听过的歌，按最久没听排',
        SmartRule.dailyMix => '收藏 + 最近播放，每天换一种顺序',
      };
}

class SmartRules {
  SmartRules._();

  /// Max songs per generated queue.
  static const int maxQueue = 20;

  /// "好久没听" threshold.
  static const Duration unplayedAfter = Duration(days: 30);

  /// Build the queue for [rule] from local data only.
  /// [favourites] and [recent] are Songs; [listenLog] carries the
  /// real play counts / last-heard times. [now] and [dayKey] are
  /// injectable so tests are deterministic.
  static List<Song> build(
    SmartRule rule, {
    required List<Song> favourites,
    required List<Song> recent,
    required List<ListenEvent> listenLog,
    DateTime? now,
    String? dayKey,
  }) {
    final ref = now ?? DateTime.now();
    final counts = <String, int>{};
    final lastHeard = <String, int>{};
    for (final e in listenLog) {
      final k = '${e.platform.code}|${e.songId}';
      counts[k] = (counts[k] ?? 0) + 1;
      final at = e.at;
      if (lastHeard[k] == null || at > lastHeard[k]!) lastHeard[k] = at;
    }

    List<Song> dedupe(List<Song> songs) {
      final seen = <String>{};
      return songs.where((s) => seen.add(s.identityKey)).toList();
    }

    switch (rule) {
      case SmartRule.recentFavourites:
        final heard = favourites
            .where((s) => (counts[s.identityKey] ?? 0) > 0)
            .toList()
          ..sort(
            (a, b) => (counts[b.identityKey] ?? 0)
                .compareTo(counts[a.identityKey] ?? 0),
          );
        final out = heard.isNotEmpty ? heard : List<Song>.of(favourites);
        return dedupe(out).take(maxQueue).toList();

      case SmartRule.unplayedFavourites:
        final cutoff = ref.subtract(unplayedAfter).millisecondsSinceEpoch;
        final out = favourites.where((s) {
          final last = lastHeard[s.identityKey];
          return last == null || last < cutoff;
        }).toList();
        // Deterministic daily order (same shuffle all day, new
        // order tomorrow) instead of a fixed list order.
        final rng = SeededRandom(dayKey ?? dayKeyOf(ref));
        return dedupe(rng.shuffle(out)).take(maxQueue).toList();

      case SmartRule.sameArtistDeepDive:
        final artistPlays = <String, int>{};
        for (final e in listenLog) {
          final a = firstArtist(e.artist);
          if (a.isEmpty) continue;
          artistPlays[a] = (artistPlays[a] ?? 0) + 1;
        }
        if (artistPlays.isEmpty) {
          return build(
            SmartRule.recentFavourites,
            favourites: favourites,
            recent: recent,
            listenLog: listenLog,
            now: ref,
            dayKey: dayKey,
          );
        }
        final top = artistPlays.entries.toList()
          ..sort((a, b) => b.value.compareTo(a.value));
        final topArtist = top.first.key;
        final pool = dedupe([
          ...favourites,
          ...recent,
        ]).where((s) => firstArtist(s.artist) == topArtist).toList();
        if (pool.length < 3) {
          // Too thin to be a deep dive — fall back to the
          // most-played favourites instead of an empty queue.
          return build(
            SmartRule.recentFavourites,
            favourites: favourites,
            recent: recent,
            listenLog: listenLog,
            now: ref,
            dayKey: dayKey,
          );
        }
        return pool.take(maxQueue).toList();

      case SmartRule.longUnplayed:
        final byKey = <String, ({Song song, int last})>{};
        for (final e in listenLog) {
          final k = '${e.platform.code}|${e.songId}';
          final prev = byKey[k];
          if (prev == null || e.at > prev.last) {
            byKey[k] = (
              song: Song(
                songId: e.songId,
                title: e.title,
                artist: e.artist,
                platform: e.platform,
                cover: e.cover,
                dur: e.totalDur,
              ),
              last: e.at,
            );
          }
        }
        final cutoff = ref.subtract(unplayedAfter).millisecondsSinceEpoch;
        final out = byKey.values
            .where((v) => v.last < cutoff)
            .toList()
          ..sort((a, b) => a.last.compareTo(b.last));
        return out.map((v) => v.song).take(maxQueue).toList();

      case SmartRule.dailyMix:
        final rng = SeededRandom(dayKey ?? dayKeyOf(ref));
        return dedupe(rng.shuffle([...favourites, ...recent]))
            .take(maxQueue)
            .toList();
    }
  }
}
