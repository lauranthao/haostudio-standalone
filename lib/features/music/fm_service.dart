import 'dart:async';
import 'dart:math';

import 'package:flutter/foundation.dart';
import 'package:get/get.dart';

import '../../core/storage/hive_store.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import 'music_player_controller.dart';

/// Local-only personal FM (私人漫游) + heartbeat mode (心动模式).
///
/// Kumone behaviour, local data only — no login anywhere. Kumone's
/// personalFM and intelligenceList both need a NetEase login, so they
/// are NOT used: seeds come from the local favourites (Hive) and
/// recent plays, and similar songs come from the public
/// single-platform search ([MusicApi.searchOne] — proven by curl:
/// NetEase cloudsearch/pc and QQ search_for_qq_cp both return real
/// songs with no login).
///
/// - 私人漫游： an endless queue. [startFM] builds an initial queue of
///   songs similar to a local seed and plays it through the existing
///   player queue ([MusicPlayerController.playQueue] — no second
///   player). A worker on the player's currentIndex refills the queue
///   whenever 3 or fewer songs remain, so playback never reaches the
///   end. [dislike] removes a song from the queue (skipping it when
///   it is the current one), records its identityKey in Hive, and
///   never recommends it again.
/// - 心动模式： one random liked song as the seed; the queue is
///   [seed, ...similar]. Finite — no refill, no dislike.
/// Playback resolution is unchanged: the queued songs resolve through
/// the normal per-song path (serial source asking, first playable
/// plays immediately).
class FmService {
  FmService({MusicApi? api, MusicPlayerController? player})
      : _api = api ?? MusicApi(),
        _player = player ?? MusicPlayerController.ensure() {
    _disliked = _readDisliked();
    // Index worker: refill when the queue runs short (see below).
    _indexWorker = ever(
      _player.currentIndex,
      (_) => unawaited(_onIndexChanged()),
    );
    // Queue worker: end FM the moment the queue is replaced by a
    // foreign list. Needed because playQueue can keep currentIndex
    // at the same value (first song of another list while FM is on
    // its first song), in which case the index worker never fires.
    // The service's own appends/removals never trip it: the current
    // song stays an FM song (or null mid-surgery, which is ignored).
    _queueWorker = ever(
      _player.queue,
      (_) => _checkForeign(),
    );
  }

  static FmService? _instance;

  /// App-wide singleton (same pattern as [EqualizerStore.ensure]).
  static FmService ensure() => _instance ??= FmService();

  /// Test-only: install [service] as the singleton, so widget tests
  /// can inject a fake [MusicApi]. Real HTTP never completes inside a
  /// widget test's fake-async zone (a real searchOne hangs there even
  /// though it fails fast in a plain test), so the card-tap path must
  /// be tested with a fake API — same idea as [HiveStore.setTestBox].
  @visibleForTesting
  static void setTestInstance(FmService service) {
    _instance?.dispose();
    _instance = service;
  }

  /// Test-only: drop the singleton (and its index worker) so a fresh
  /// instance re-reads Hive and re-subscribes to a fresh controller.
  @visibleForTesting
  static void resetForTest() {
    _instance?.dispose();
    _instance = null;
  }

  final MusicApi _api;
  final MusicPlayerController _player;

  /// True while a personal-FM queue is playing. Cleared when the user
  /// starts any other queue (the index worker sees a current song the
  /// FM pool did not provide) or when the queue is emptied.
  final RxBool isFM = false.obs;

  /// Refill when this many songs (including the current one) remain.
  static const int refillThreshold = 3;

  /// Songs wanted per similar-songs fetch.
  static const int initialWant = 10;

  /// Songs wanted for a heartbeat queue (seed + similar).
  static const int heartbeatWant = 20;

  Set<String> _disliked = {};

  /// IdentityKeys of every song this service put in the queue. The
  /// workers use it to tell "still FM" from "the user started
  /// something else".
  Set<String> _fmIds = {};

  Worker? _indexWorker;
  Worker? _queueWorker;
  var _refilling = false;

  /// Disliked identityKeys (read-only view, for tests).
  @visibleForTesting
  Set<String> get dislikedIds => Set.unmodifiable(_disliked);

  /// FM pool identityKeys (read-only view, for tests).
  @visibleForTesting
  Set<String> get fmIds => Set.unmodifiable(_fmIds);

  /// Test-only: put [songs] in the player queue as an FM queue
  /// (sets [_fmIds] and [isFM]) without resolving any URL, so refill
  /// / dislike tests do not wait on the network.
  @visibleForTesting
  void seedForTest(List<Song> songs, {int index = 0}) {
    _fmIds = songs.map((s) => s.identityKey).toSet();
    isFM.value = true;
    _player.queue.assignAll(songs);
    _player.currentIndex.value = index;
  }

  void dispose() {
    _indexWorker?.dispose();
    _indexWorker = null;
    _queueWorker?.dispose();
    _queueWorker = null;
  }

  static Set<String> _readDisliked() {
    final raw = HiveStore.box.get(HiveKeys.fmDislikedIds) as List?;
    if (raw == null) return {};
    return raw
        .map((e) => e.toString())
        .where((s) => s.isNotEmpty)
        .toSet();
  }

  /// Songs similar to [seed], most similar first: same artist on the
  /// seed's platform, then same album, then the same artist on the
  /// other main platform (wy <-> tx). The seed itself, duplicates and
  /// disliked songs are dropped. A failed leg contributes nothing and
  /// never blocks the others.
  Future<List<Song>> similarSongs(Song seed, {int want = 10}) async {
    final out = <Song>[];
    final seen = <String>{seed.identityKey};
    void addAll(List<Song> songs) {
      for (final s in songs) {
        if (out.length >= want) break;
        if (s.title.isEmpty || s.songId.isEmpty) continue;
        final key = s.identityKey;
        if (!seen.add(key)) continue;
        if (_disliked.contains(key)) continue;
        out.add(s);
      }
    }

    final artist = firstArtist(seed.artist);
    if (artist.isNotEmpty) {
      addAll(await _safeSearch(seed.platform, artist));
    }
    if (out.length < want && seed.album.isNotEmpty) {
      addAll(await _safeSearch(seed.platform, seed.album));
    }
    if (out.length < want && artist.isNotEmpty) {
      final other = seed.platform == MusicPlatform.wy
          ? MusicPlatform.tx
          : MusicPlatform.wy;
      addAll(await _safeSearch(other, artist));
    }
    return out;
  }

  Future<List<Song>> _safeSearch(MusicPlatform pf, String q) async {
    try {
      return await _api.searchOne(pf, q);
    } catch (_) {
      return [];
    }
  }

  /// Local seeds, shuffled: favourites first, then recent plays,
  /// deduplicated, disliked dropped.
  List<Song> _localSeeds() {
    final seen = <String>{};
    final seeds = <Song>[];
    for (final s in [...MusicStore.getFavSongs(), ...MusicStore.getRecent()]) {
      if (_disliked.contains(s.identityKey)) continue;
      if (!seen.add(s.identityKey)) continue;
      seeds.add(s);
    }
    seeds.shuffle();
    return seeds;
  }

  /// Start personal FM. Returns false when there are no local seeds
  /// at all (no favourites and no recent plays) — the caller shows
  /// the "collect some songs first" prompt instead of failing
  /// silently. Otherwise the FM queue is playing when this returns.
  Future<bool> startFM() async {
    final seeds = _localSeeds();
    if (seeds.isEmpty) return false;
    // Try the first few seeds until one yields similar songs; the
    // fetch is serial (one artist search at a time).
    var similar = <Song>[];
    for (final seed in seeds.take(3)) {
      similar = await similarSongs(seed, want: initialWant);
      if (similar.isNotEmpty) break;
    }
    // Offline or no similar songs anywhere: play the seeds
    // themselves, so FM still starts when seeds exist.
    final queue = similar.isNotEmpty ? similar : seeds;
    _fmIds = queue.map((s) => s.identityKey).toSet();
    isFM.value = true;
    await _player.playQueue(queue, 0, label: '私人漫游');
    return true;
  }

  /// Start heartbeat mode. Returns false when there are no liked
  /// songs — the caller shows the "collect some songs first" prompt.
  /// The queue is [seed, ...similar]; finite, no refill, no dislike.
  Future<bool> startHeartbeat() async {
    final favs = MusicStore.getFavSongs()
        .where((s) => !_disliked.contains(s.identityKey))
        .toList();
    if (favs.isEmpty) return false;
    final seed = favs[Random().nextInt(favs.length)];
    final similar = await similarSongs(seed, want: heartbeatWant);
    isFM.value = false;
    _fmIds.clear();
    await _player.playQueue([seed, ...similar], 0, label: '心动模式');
    return true;
  }

  /// "不喜欢": never recommend [song] again, and take it out of the
  /// queue. When it is the current song playback skips to the next
  /// one (or, when it was the last one, refills first and plays the
  /// first fresh song). Safe to call for a song that is not queued
  /// (only the Hive record is added).
  Future<void> dislike(Song song) async {
    final key = song.identityKey;
    if (_disliked.add(key)) {
      await HiveStore.put(HiveKeys.fmDislikedIds, _disliked.toList());
    }
    _fmIds.remove(key);
    final queue = _player.queue;
    final idx = queue.indexWhere((s) => s.identityKey == key);
    if (idx < 0) return;
    final current = _player.currentIndex.value;
    final wasCurrent = idx == current;
    queue.removeAt(idx);
    if (queue.isEmpty) {
      isFM.value = false;
      await _player.pause();
      return;
    }
    if (wasCurrent) {
      if (idx >= queue.length) {
        // It was the last song: pause, refill, then play the first
        // fresh song (it lands at the removed song's index).
        final before = queue.length;
        await _player.pause();
        await _refill(anchor: song);
        if (_player.queue.length > before) {
          await _player.playIndex(before);
        } else {
          isFM.value = false;
        }
      } else {
        // The next song slid into the removed song's slot.
        await _player.playIndex(idx);
      }
    } else if (idx < current) {
      // The queue shifted before the current song: keep the index
      // pointing at the same song.
      _player.currentIndex.value = current - 1;
    }
  }

  /// End FM when the current song is not one this service queued
  /// (the user started a different list). A null current song is
  /// ignored: it happens mid-surgery (dislike removing the last song
  /// leaves the index briefly past the end before the refill lands).
  void _checkForeign() {
    if (!isFM.value) return;
    final song = _player.currentSong;
    if (song == null) return;
    if (!_fmIds.contains(song.identityKey)) {
      isFM.value = false;
    }
  }

  Future<void> _onIndexChanged() async {
    if (!isFM.value) return;
    final song = _player.currentSong;
    if (song == null) {
      isFM.value = false;
      return;
    }
    if (!_fmIds.contains(song.identityKey)) {
      // The user started a different queue: FM is over.
      isFM.value = false;
      return;
    }
    final remaining = _player.queue.length - _player.currentIndex.value;
    if (remaining > refillThreshold) return;
    await _refill(anchor: song);
  }

  /// Append fresh similar songs to the FM queue. Anchors on the
  /// current song first, then the last queued song, then a random
  /// local seed, until one of them yields songs not already queued.
  Future<void> _refill({required Song anchor}) async {
    if (_refilling || !isFM.value) return;
    _refilling = true;
    try {
      final queued =
          _player.queue.map((s) => s.identityKey).toSet();
      final candidates = <Song>[anchor];
      if (_player.queue.isNotEmpty &&
          _player.queue.last.identityKey != anchor.identityKey) {
        candidates.add(_player.queue.last);
      }
      final seeds = _localSeeds();
      if (seeds.isNotEmpty) candidates.add(seeds.first);
      for (final candidate in candidates) {
        if (!isFM.value) return;
        final more = await similarSongs(candidate, want: initialWant);
        final fresh = more
            .where((s) => !queued.contains(s.identityKey))
            .toList();
        if (fresh.isEmpty) continue;
        _fmIds.addAll(fresh.map((s) => s.identityKey));
        _player.queue.addAll(fresh);
        return;
      }
    } finally {
      _refilling = false;
    }
  }
}
