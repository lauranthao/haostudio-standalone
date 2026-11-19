// Streaming playlist / artist search tests (v1.1.3).
//
// Song search already streams per leg (searchAllStream, 秒出), but
// playlist / artist search awaited its single platform call and showed
// nothing until it returned. Both now stream with the same convention
// (one emission per settled leg, pending set, 5 s leg cap, generation
// supersede): the fastest leg shows first, a slow leg never holds up
// the rest.
//
// Legs: playlist = wy + kw (QQ's playlist API rejects the call,
// Kugou has none); artist = wy + tx + kw (Kugou has none).
// fakeAsync drives the fake legs' timers, like
// music_search_stream_test.dart.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/song_search_service.dart';

PlaylistSummary _playlist(String id, String name, MusicPlatform pf) =>
    PlaylistSummary(id: id, name: name, platform: pf);

ArtistSummary _artist(String id, String name, MusicPlatform pf) =>
    ArtistSummary(id: id, name: name, platform: pf);

/// Fake platform search: each platform answers after its own delay
/// (or throws, for [throwFor]).
class _FakeApi extends MusicApi {
  _FakeApi({
    required this.delays,
    this.playlists = const {},
    this.artists = const {},
    this.throwFor = const {},
  });

  final Map<MusicPlatform, Duration> delays;
  final Map<MusicPlatform, List<PlaylistSummary>> playlists;
  final Map<MusicPlatform, List<ArtistSummary>> artists;
  final Set<MusicPlatform> throwFor;

  Future<void> _wait(MusicPlatform pf) async {
    await Future<void>.delayed(delays[pf] ?? Duration.zero);
    if (throwFor.contains(pf)) throw StateError('leg failed');
  }

  @override
  Future<({List<PlaylistSummary> items, int total})> searchWyPlaylists(
    String q,
    int page,
  ) async {
    await _wait(MusicPlatform.wy);
    return (
      items: List.of(
        playlists[MusicPlatform.wy] ?? const <PlaylistSummary>[],
      ),
      total: 0,
    );
  }

  @override
  Future<({List<PlaylistSummary> items, int total})> searchKwPlaylists(
    String q,
    int page,
  ) async {
    await _wait(MusicPlatform.kw);
    return (
      items: List.of(
        playlists[MusicPlatform.kw] ?? const <PlaylistSummary>[],
      ),
      total: 0,
    );
  }

  @override
  Future<List<ArtistSummary>> searchWyArtists(String q) async {
    await _wait(MusicPlatform.wy);
    return List.of(artists[MusicPlatform.wy] ?? const []);
  }

  @override
  Future<List<ArtistSummary>> searchTxArtists(String q, int page) async {
    await _wait(MusicPlatform.tx);
    return List.of(artists[MusicPlatform.tx] ?? const []);
  }

  @override
  Future<List<ArtistSummary>> searchKwArtists(String q) async {
    await _wait(MusicPlatform.kw);
    return List.of(artists[MusicPlatform.kw] ?? const []);
  }
}

void main() {
  group('playlist search streams per leg', () {
    test('fast wy leg shows first, slow kw leg appends', () {
      fakeAsync((async) {
        final api = _FakeApi(
          delays: const {
            MusicPlatform.wy: Duration(milliseconds: 100),
            MusicPlatform.kw: Duration(seconds: 3),
          },
          playlists: {
            MusicPlatform.wy: [_playlist('w1', 'WY歌单', MusicPlatform.wy)],
            MusicPlatform.kw: [_playlist('k1', 'KW歌单', MusicPlatform.kw)],
          },
        );
        final service = SongSearchService(api: api);
        final updates = <PlaylistSearchUpdate>[];
        var done = false;
        service.searchPlaylistsStream('test').listen(
          updates.add,
          onDone: () => done = true,
        );
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
        // t = 100 ms: only wy has returned — its result is already
        // shown, kw still pending.
        expect(updates.length, 1);
        expect(
          updates.last.items.map((p) => p.name).toList(),
          ['WY歌单'],
        );
        expect(updates.last.pending, {MusicPlatform.kw});
        expect(done, isFalse);
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        // t = 3 s: every leg settled; the slow leg appended after wy.
        expect(done, isTrue);
        expect(
          updates.last.items.map((p) => p.name).toList(),
          ['WY歌单', 'KW歌单'],
        );
        expect(updates.last.pending, isEmpty);
      });
    });

    test('a failing leg contributes nothing and never blocks the others',
        () {
      fakeAsync((async) {
        final api = _FakeApi(
          delays: const {
            MusicPlatform.wy: Duration(milliseconds: 100),
            MusicPlatform.kw: Duration(milliseconds: 100),
          },
          playlists: {
            MusicPlatform.wy: [_playlist('w1', 'WY歌单', MusicPlatform.wy)],
            MusicPlatform.kw: [_playlist('k1', 'KW歌单', MusicPlatform.kw)],
          },
          throwFor: {MusicPlatform.kw},
        );
        final service = SongSearchService(api: api);
        final updates = <PlaylistSearchUpdate>[];
        var done = false;
        service.searchPlaylistsStream('test').listen(
          updates.add,
          onDone: () => done = true,
        );
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
        expect(done, isTrue);
        expect(
          updates.last.items.map((p) => p.name).toList(),
          ['WY歌单'],
        );
        expect(updates.last.pending, isEmpty);
      });
    });

    test('slow leg past the 5 s cap contributes nothing', () {
      fakeAsync((async) {
        final api = _FakeApi(
          delays: const {
            MusicPlatform.wy: Duration(milliseconds: 100),
            MusicPlatform.kw: Duration(seconds: 10),
          },
          playlists: {
            MusicPlatform.wy: [_playlist('w1', 'WY歌单', MusicPlatform.wy)],
            MusicPlatform.kw: [_playlist('k1', 'KW歌单', MusicPlatform.kw)],
          },
        );
        final service = SongSearchService(api: api);
        final updates = <PlaylistSearchUpdate>[];
        var done = false;
        service.searchPlaylistsStream('test').listen(
          updates.add,
          onDone: () => done = true,
        );
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
        expect(updates.length, 1);
        expect(done, isFalse);
        async.elapse(const Duration(seconds: 5));
        async.flushMicrotasks();
        // t = 5 s: the kw leg hit the cap and contributed nothing;
        // the stream closed instead of waiting out the 10 s leg.
        expect(done, isTrue);
        expect(
          updates.last.items.map((p) => p.name).toList(),
          ['WY歌单'],
        );
        expect(updates.last.pending, isEmpty);
      });
    });

    test('onlyPlatform scopes the legs; a platform with no endpoint closes empty',
        () {
      fakeAsync((async) {
        final api = _FakeApi(
          delays: const {
            MusicPlatform.wy: Duration(milliseconds: 100),
            MusicPlatform.kw: Duration(milliseconds: 100),
          },
          playlists: {
            MusicPlatform.wy: [_playlist('w1', 'WY歌单', MusicPlatform.wy)],
            MusicPlatform.kw: [_playlist('k1', 'KW歌单', MusicPlatform.kw)],
          },
        );
        final service = SongSearchService(api: api);
        // Only kw: wy never runs.
        final kwUpdates = <PlaylistSearchUpdate>[];
        var kwDone = false;
        service
            .searchPlaylistsStream('test', onlyPlatform: MusicPlatform.kw)
            .listen(kwUpdates.add, onDone: () => kwDone = true);
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
        expect(kwDone, isTrue);
        expect(
          kwUpdates.last.items.map((p) => p.name).toList(),
          ['KW歌单'],
        );
        // tx has no playlist endpoint: no leg runs, the stream
        // closes at once with no emission.
        final txUpdates = <PlaylistSearchUpdate>[];
        var txDone = false;
        service
            .searchPlaylistsStream('test', onlyPlatform: MusicPlatform.tx)
            .listen(txUpdates.add, onDone: () => txDone = true);
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
        expect(txDone, isTrue);
        expect(txUpdates, isEmpty);
      });
    });

    test('new query cancels the old search: late old legs never appear',
        () {
      fakeAsync((async) {
        final api = _FakeApi(
          delays: const {
            MusicPlatform.wy: Duration(seconds: 3),
            MusicPlatform.kw: Duration(milliseconds: 100),
          },
          playlists: {
            MusicPlatform.wy: [_playlist('w1', 'OLD', MusicPlatform.wy)],
            MusicPlatform.kw: [_playlist('k1', 'KW歌单', MusicPlatform.kw)],
          },
        );
        final service = SongSearchService(api: api);
        final oldUpdates = <PlaylistSearchUpdate>[];
        var oldDone = false;
        service.searchPlaylistsStream('old').listen(
          oldUpdates.add,
          onDone: () => oldDone = true,
        );
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
        expect(
          oldUpdates.last.items.map((p) => p.name).toList(),
          ['KW歌单'],
        );
        expect(oldDone, isFalse);
        // A new query supersedes the old search.
        final newUpdates = <PlaylistSearchUpdate>[];
        var newDone = false;
        service.searchPlaylistsStream('new').listen(
          newUpdates.add,
          onDone: () => newDone = true,
        );
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        // The old wy leg completed at t = 3 s but must not emit.
        expect(
          oldUpdates.last.items.map((p) => p.name).toList(),
          ['KW歌单'],
        );
        expect(oldDone, isTrue);
        expect(newDone, isTrue);
        expect(
          newUpdates.last.items.map((p) => p.name).toList(),
          ['KW歌单', 'OLD'],
        );
      });
    });
  });

  group('artist search streams per leg', () {
    test('fast wy leg shows first, tx/kw append', () {
      fakeAsync((async) {
        final api = _FakeApi(
          delays: const {
            MusicPlatform.wy: Duration(milliseconds: 100),
            MusicPlatform.tx: Duration(seconds: 2),
            MusicPlatform.kw: Duration(seconds: 3),
          },
          artists: {
            MusicPlatform.wy: [_artist('w1', '歌手A', MusicPlatform.wy)],
            MusicPlatform.tx: [_artist('t1', '歌手B', MusicPlatform.tx)],
            MusicPlatform.kw: [_artist('k1', '歌手C', MusicPlatform.kw)],
          },
        );
        final service = SongSearchService(api: api);
        final updates = <ArtistSearchUpdate>[];
        var done = false;
        service.searchArtistsStream('test').listen(
          updates.add,
          onDone: () => done = true,
        );
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
        // t = 100 ms: only wy has returned.
        expect(updates.length, 1);
        expect(updates.last.items.map((a) => a.name).toList(), ['歌手A']);
        expect(
          updates.last.pending,
          {MusicPlatform.tx, MusicPlatform.kw},
        );
        expect(done, isFalse);
        async.elapse(const Duration(seconds: 3));
        async.flushMicrotasks();
        // t = 3 s: every leg settled, in arrival order.
        expect(done, isTrue);
        expect(
          updates.last.items.map((a) => a.name).toList(),
          ['歌手A', '歌手B', '歌手C'],
        );
        expect(updates.last.pending, isEmpty);
      });
    });

    test('onlyPlatform scopes the legs (kg has no artist endpoint)', () {
      fakeAsync((async) {
        final api = _FakeApi(
          delays: const {
            MusicPlatform.wy: Duration(milliseconds: 100),
            MusicPlatform.tx: Duration(milliseconds: 100),
            MusicPlatform.kw: Duration(milliseconds: 100),
          },
          artists: {
            MusicPlatform.tx: [_artist('t1', '歌手B', MusicPlatform.tx)],
          },
        );
        final service = SongSearchService(api: api);
        final txUpdates = <ArtistSearchUpdate>[];
        var txDone = false;
        service
            .searchArtistsStream('test', onlyPlatform: MusicPlatform.tx)
            .listen(txUpdates.add, onDone: () => txDone = true);
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
        expect(txDone, isTrue);
        expect(
          txUpdates.last.items.map((a) => a.name).toList(),
          ['歌手B'],
        );
        // Kugou has no artist endpoint: closes at once, no emission.
        final kgUpdates = <ArtistSearchUpdate>[];
        var kgDone = false;
        service
            .searchArtistsStream('test', onlyPlatform: MusicPlatform.kg)
            .listen(kgUpdates.add, onDone: () => kgDone = true);
        async.elapse(const Duration(milliseconds: 100));
        async.flushMicrotasks();
        expect(kgDone, isTrue);
        expect(kgUpdates, isEmpty);
      });
    });
  });
}
