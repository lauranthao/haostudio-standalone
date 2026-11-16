// Daily picks (app.js:3308-3346) — 20 songs, same-day stable.
//
// 1. "Because you listened" (up to 10): top-20 most-played (last 30 days),
//    date-seeded shuffle, take 10.
// 2. Artist discovery (up to 10 more): top-3 distinct first-artists from
//    the ranked list; per artist search WY (12), add TX (12) when < 4
//    results; filter out heard songs / heard title+artist pairs / songs
//    whose artist does not match; round-robin across the 3 artists.
// 3. Hot fill (to reach 20): first playlist of the first platform that
//    returns (wy/tx/kw plaza in parallel), import it, filter unheard.
// 4. Cached per day (hao_daily_YYYY-MM-DD); cold flag when there is no
//    listen history at all ("多听几首歌，明天推荐会更准").

import 'music_api.dart';
import 'music_models.dart';
import 'music_store.dart';

class DailyService {
  DailyService({MusicApi? api}) : _api = api ?? MusicApi();

  final MusicApi _api;

  Future<({List<Song> tracks, bool cold})> buildDaily({DateTime? now}) async {
    final day = now ?? DateTime.now();
    final dayKey = dayKeyOf(day);
    final cached = MusicStore.getDaily(dayKey);
    if (cached != null) {
      return (tracks: cached, cold: MusicStore.getDailyCold(dayKey));
    }
    final nowMs = day.millisecondsSinceEpoch;
    final evs = MusicStore.getListenLog()
        .where((x) => nowMs - x.at <= 30 * 86400000)
        .toList();
    final counts = <String, ({int n, ListenEvent ev})>{};
    for (final x in evs) {
      final k = '${x.platform.code}|${x.songId}';
      final prev = counts[k];
      counts[k] = (n: (prev?.n ?? 0) + 1, ev: x);
    }
    final ranked = counts.values.toList()
      ..sort((a, b) => b.n.compareTo(a.n));
    final rng = SeededRandom(dayKey);
    final heard = <String>{};
    final heardTitles = <String>{};
    for (final c in ranked) {
      heard.add('${c.ev.platform.code}|${c.ev.songId}');
      heardTitles.add(
        '${normalizeName(c.ev.title)}|${normalizeName(firstArtist(c.ev.artist))}',
      );
    }

    Song toDaily(ListenEvent ev, int n) => Song(
          songId: ev.songId,
          title: ev.title,
          artist: ev.artist,
          platform: ev.platform,
          cover: ev.cover,
          dur: ev.dur,
          reasonKey: 'becauseListen',
          reasonArg: ' ×$n',
        );

    var list = rng
        .shuffle(ranked.take(20).toList())
        .take(10)
        .map((c) => toDaily(c.ev, c.n))
        .toList();
    var cold = false;
    if (ranked.isNotEmpty) {
      final artists = <String>[];
      final seenA = <String>{};
      for (final c in ranked) {
        final a = firstArtist(c.ev.artist);
        if (a.isNotEmpty && !seenA.contains(a)) {
          seenA.add(a);
          artists.add(a);
        }
      }
      list = [
        ...list,
        ...await _discover(artists.take(3).toList(), heard, heardTitles, rng),
      ];
      if (list.length < 20) {
        final have = list.map((x) => x.identityKey).toSet();
        list = [
          ...list,
          ...rng
              .shuffle(
                ranked
                    .where((c) => !have.contains(
                          '${c.ev.platform.code}|${c.ev.songId}',
                        ))
                    .toList(),
              )
              .map((c) => toDaily(c.ev, c.n)),
        ];
      }
    }
    if (list.length < 20) {
      final hot = await _hotFill(20 - list.length, heard, list);
      if (ranked.isEmpty && hot.isNotEmpty) cold = true;
      list = [...list, ...hot];
    }
    list = list.take(20).toList();
    await MusicStore.saveDaily(dayKey, list, cold);
    return (tracks: list, cold: cold);
  }

  Future<List<Song>> _discover(
    List<String> artists,
    Set<String> heard,
    Set<String> heardTitles,
    SeededRandom rng,
  ) async {
    final per = <({String name, List<Song> songs})>[];
    final settled = await Future.wait(
      artists.map((name) async {
        var found = await _api.searchWy(name, 12).catchError((_) => <Song>[]);
        if (found.length < 4) {
          final tx = await _api.searchTx(name, 12).catchError((_) => <Song>[]);
          found = [...found, ...tx];
        }
        return (name: name, songs: found);
      }),
    );
    for (final r in settled) {
      final nn = normalizeName(r.name);
      final seen = <String>{};
      final songs = r.songs.where((s) {
        final k = s.identityKey;
        if (s.songId.isEmpty ||
            s.title.isEmpty ||
            heard.contains(k) ||
            seen.contains(k)) {
          return false;
        }
        if (heardTitles.contains(
          '${normalizeName(s.title)}|${normalizeName(firstArtist(s.artist))}',
        )) {
          return false;
        }
        if (!normalizeName(s.artist).contains(nn) &&
            normalizeName(firstArtist(s.artist)) != nn) {
          return false;
        }
        seen.add(k);
        return true;
      }).map((s) {
        return s.copyWith(reasonKey: 'becauseArtist', reasonArg: r.name);
      }).toList();
      per.add((name: r.name, songs: songs));
    }
    final out = <Song>[];
    var idx = 0;
    var guard = 0;
    while (out.length < 10 && guard++ < 40) {
      var added = false;
      for (final p in per) {
        if (idx < p.songs.length) {
          out.add(p.songs[idx]);
          added = true;
        }
      }
      idx++;
      if (!added) break;
    }
    return rng.shuffle(out).take(10).toList();
  }

  Future<List<Song>> _hotFill(
    int n,
    Set<String> heard,
    List<Song> list,
  ) async {
    final have = list.map((x) => x.identityKey).toSet();
    Future<List<List<PlaylistSummary>>> fetchPlaza() => Future.wait(
          [MusicPlatform.wy, MusicPlatform.tx, MusicPlatform.kw]
              .map((pf) => _api.plaza(pf).catchError((_) => <PlaylistSummary>[])),
        );
    var settled = await fetchPlaza();
    // All three plaza fetches failed: almost certainly a transient
    // network blip, not "no playlists" — retry the plaza fetch once.
    // (The old code retried the WHOLE _hotFill with identical args,
    // re-issuing 3 plaza fetches + imports even when the platforms
    // had answered and the songs were just already heard.)
    if (settled.every((l) => l.isEmpty)) {
      settled = await fetchPlaza();
    }
    final cands = <({MusicPlatform pf, List<PlaylistSummary> items})>[];
    final pfs = [MusicPlatform.wy, MusicPlatform.tx, MusicPlatform.kw];
    for (var i = 0; i < settled.length; i++) {
      if (settled[i].isNotEmpty) {
        cands.add((pf: pfs[i], items: settled[i]));
      }
    }
    var tracks = <Song>[];
    for (final c in cands) {
      if (tracks.isNotEmpty) break;
      try {
        final d = await _api.importPlaylist(c.pf, c.items.first.id);
        tracks = d.tracks;
      } catch (_) {}
    }
    return tracks
        .where((s) {
          final k = s.identityKey;
          return s.songId.isNotEmpty &&
              s.title.isNotEmpty &&
              !heard.contains(k) &&
              !have.contains(k);
        })
        .take(n)
        .map(
          (s) => s.copyWith(reasonKey: 'hotPick', reasonArg: ''),
        )
        .toList();
  }
}
