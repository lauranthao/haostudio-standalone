// Streaming song search tests (v1.0.9: 秒出).
//
// The old search waited for the slowest leg (Future.wait, 5 s cap)
// before showing anything. Now each leg emits the moment it returns,
// so the first result appears as soon as the fastest leg returns
// (~1 s), and slower legs append after it.
//
// fakeAsync drives the fake legs' timers; it fakes Timer but NOT
// DateTime.now() — the search path uses no wall-clock reads, only
// per-leg timeouts, so fake time is exact here.

import 'package:fake_async/fake_async.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:standalone/services/music/lx_script_engine.dart';
import 'package:standalone/services/music/music_api.dart';
import 'package:standalone/services/music/music_models.dart';
import 'package:standalone/services/music/song_search_service.dart';

Song _song(String id, String title, MusicPlatform pf, {String artist = 'A'}) =>
    Song(songId: id, title: title, artist: artist, platform: pf);

/// Fake platform search: each platform answers after its own delay
/// (or throws, for [throwFor]).
class _FakeApi extends MusicApi {
  _FakeApi({required this.delays, required this.results, this.throwFor = const {}});

  final Map<MusicPlatform, Duration> delays;
  final Map<MusicPlatform, List<Song>> results;
  final Set<MusicPlatform> throwFor;

  @override
  Future<List<Song>> searchOne(MusicPlatform pf, String q) async {
    await Future<void>.delayed(delays[pf] ?? Duration.zero);
    if (throwFor.contains(pf)) throw StateError('leg failed');
    return List.of(results[pf] ?? const []);
  }
}

/// Fake LX engine: no real JS runtime, no asset loading. Script legs
/// are declared explicitly; `search` answers after [scriptDelay].
class _FakeEngine extends LxScriptEngine {
  _FakeEngine({
    this.legs = const [],
    this.scriptResults = const {},
    this.scriptDelay = Duration.zero,
  });

  final List<({MusicPlatform pf, String scriptId})> legs;
  final Map<String, List<Map<String, dynamic>>> scriptResults;
  final Duration scriptDelay;

  @override
  Future<void> ensureInitialized() async {}

  @override
  List<({String scriptId, String scriptName})> searchLegsFor(
    MusicPlatform platform,
  ) => [
    for (final l in legs)
      if (l.pf == platform) (scriptId: l.scriptId, scriptName: l.scriptId),
  ];

  @override
  Future<List<Map<String, dynamic>>> search({
    required String scriptId,
    required String platform,
    required String keyword,
    int page = 1,
    int limit = 20,
  }) async {
    await Future<void>.delayed(scriptDelay);
    return scriptResults[scriptId] ?? const [];
  }
}

void main() {
  test('fast leg shows at ~1s, slow legs append at ~5s', () {
    fakeAsync((async) {
      final api = _FakeApi(
        delays: const {
          MusicPlatform.wy: Duration(seconds: 1),
          MusicPlatform.tx: Duration(seconds: 5),
          MusicPlatform.kg: Duration(seconds: 5),
          MusicPlatform.kw: Duration(seconds: 5),
        },
        results: {
          MusicPlatform.wy: [_song('1', 'A', MusicPlatform.wy)],
          MusicPlatform.tx: [_song('2', 'B', MusicPlatform.tx)],
          MusicPlatform.kg: [_song('3', 'C', MusicPlatform.kg)],
          MusicPlatform.kw: [_song('4', 'D', MusicPlatform.kw)],
        },
      );
      final service = SongSearchService(api: api, scriptEngine: _FakeEngine());
      final updates = <SearchStreamUpdate>[];
      var done = false;
      service.searchAllStream('test').listen(updates.add, onDone: () => done = true);
      async.elapse(const Duration(milliseconds: 500));
      async.flushMicrotasks();
      expect(updates, isEmpty, reason: 'nothing before the fastest leg');
      async.elapse(const Duration(milliseconds: 500));
      async.flushMicrotasks();
      // t = 1 s: only wy has returned — its result is already shown,
      // the other legs are still pending.
      expect(updates.length, 1);
      expect(updates.last.songs.map((s) => s.title).toList(), ['A']);
      expect(
        updates.last.pending,
        {MusicPlatform.tx, MusicPlatform.kg, MusicPlatform.kw},
      );
      expect(done, isFalse);
      async.elapse(const Duration(seconds: 4));
      async.flushMicrotasks();
      // t = 5 s: every leg settled; the slow legs appended after wy.
      expect(done, isTrue);
      expect(
        updates.last.songs.map((s) => s.title).toList(),
        ['A', 'B', 'C', 'D'],
      );
      expect(updates.last.pending, isEmpty);
    });
  });

  test('new query cancels the old search: late old legs never appear', () {
    fakeAsync((async) {
      final api = _FakeApi(
        delays: const {
          MusicPlatform.wy: Duration(seconds: 3),
          MusicPlatform.tx: Duration(milliseconds: 100),
          MusicPlatform.kg: Duration(milliseconds: 100),
          MusicPlatform.kw: Duration(milliseconds: 100),
        },
        results: {
          MusicPlatform.wy: [_song('1', 'OLD', MusicPlatform.wy)],
          MusicPlatform.tx: [_song('2', 'B', MusicPlatform.tx)],
          MusicPlatform.kg: [_song('3', 'C', MusicPlatform.kg)],
          MusicPlatform.kw: [_song('4', 'D', MusicPlatform.kw)],
        },
      );
      final service = SongSearchService(api: api, scriptEngine: _FakeEngine());
      final oldUpdates = <SearchStreamUpdate>[];
      var oldDone = false;
      service
          .searchAllStream('old')
          .listen(oldUpdates.add, onDone: () => oldDone = true);
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();
      // Fast legs settled; wy (3 s) still pending.
      expect(
        oldUpdates.last.songs.map((s) => s.title).toList(),
        ['B', 'C', 'D'],
      );
      expect(oldDone, isFalse);
      // A new query supersedes the old search.
      final newUpdates = <SearchStreamUpdate>[];
      var newDone = false;
      service
          .searchAllStream('new')
          .listen(newUpdates.add, onDone: () => newDone = true);
      async.elapse(const Duration(seconds: 3));
      async.flushMicrotasks();
      // The old wy leg completed at t = 3 s but must not emit: the old
      // stream was closed by the supersede, and its late results are
      // dropped by the generation guard.
      expect(
        oldUpdates.last.songs.map((s) => s.title).toList(),
        ['B', 'C', 'D'],
      );
      expect(oldDone, isTrue);
      // The new search ran the same legs and got all four.
      // wy's OLD song (3 s) settles last but sorts to the front
      // group — behind tx's B, which arrived first inside the
      // wy/tx group (arrival order within the group), ahead of
      // kg/kw (2026-11-17 platform-priority rule).
      expect(newDone, isTrue);
      expect(
        newUpdates.last.songs.map((s) => s.title).toList(),
        ['B', 'OLD', 'C', 'D'],
      );
    });
  });

  test('a failing leg contributes nothing and never blocks the others', () {
    fakeAsync((async) {
      final api = _FakeApi(
        delays: const {
          MusicPlatform.wy: Duration(seconds: 1),
          MusicPlatform.tx: Duration(seconds: 1),
          MusicPlatform.kg: Duration(seconds: 1),
          MusicPlatform.kw: Duration(seconds: 1),
        },
        results: {
          MusicPlatform.wy: [_song('1', 'A', MusicPlatform.wy)],
          MusicPlatform.tx: [_song('2', 'B', MusicPlatform.tx)],
          MusicPlatform.kw: [_song('4', 'D', MusicPlatform.kw)],
        },
        throwFor: {MusicPlatform.kg},
      );
      final service = SongSearchService(api: api, scriptEngine: _FakeEngine());
      final updates = <SearchStreamUpdate>[];
      var done = false;
      service.searchAllStream('test').listen(updates.add, onDone: () => done = true);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(
        updates.last.songs.map((s) => s.title).toList(),
        ['A', 'B', 'D'],
      );
      expect(updates.last.pending, isEmpty);
    });
  });

  test('all legs empty: stream closes with no songs', () {
    fakeAsync((async) {
      final api = _FakeApi(
        delays: const {
          MusicPlatform.wy: Duration(milliseconds: 100),
          MusicPlatform.tx: Duration(milliseconds: 100),
          MusicPlatform.kg: Duration(milliseconds: 100),
          MusicPlatform.kw: Duration(milliseconds: 100),
        },
        results: const {},
      );
      final service = SongSearchService(api: api, scriptEngine: _FakeEngine());
      final updates = <SearchStreamUpdate>[];
      var done = false;
      service.searchAllStream('zzz').listen(updates.add, onDone: () => done = true);
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();
      expect(done, isTrue);
      expect(updates.last.songs, isEmpty);
      expect(updates.last.pending, isEmpty);
    });
  });

  test('dedupe: same song on two platforms both show, same-platform dupe dropped', () {
    fakeAsync((async) {
      final api = _FakeApi(
        delays: const {
          MusicPlatform.wy: Duration(milliseconds: 100),
          MusicPlatform.tx: Duration(milliseconds: 200),
          MusicPlatform.kg: Duration(milliseconds: 50),
          MusicPlatform.kw: Duration(milliseconds: 50),
        },
        results: {
          MusicPlatform.wy: [
            _song('1', 'A', MusicPlatform.wy),
            _song('1', 'A', MusicPlatform.wy),
          ],
          MusicPlatform.tx: [_song('1', 'A', MusicPlatform.tx)],
        },
      );
      final service = SongSearchService(api: api, scriptEngine: _FakeEngine());
      final updates = <SearchStreamUpdate>[];
      var done = false;
      service.searchAllStream('test').listen(updates.add, onDone: () => done = true);
      async.elapse(const Duration(milliseconds: 200));
      async.flushMicrotasks();
      expect(done, isTrue);
      final songs = updates.last.songs;
      expect(songs.length, 2);
      expect(songs[0].platform, MusicPlatform.wy);
      expect(songs[1].platform, MusicPlatform.tx);
    });
  });

  test('script leg emits after its platform leg and dedupes against it', () {
    fakeAsync((async) {
      final api = _FakeApi(
        delays: const {
          MusicPlatform.wy: Duration(milliseconds: 100),
          MusicPlatform.tx: Duration(milliseconds: 100),
          MusicPlatform.kg: Duration(milliseconds: 100),
          MusicPlatform.kw: Duration(seconds: 2),
        },
        results: {
          MusicPlatform.kw: [
            _song('k1', 'Same Song', MusicPlatform.kw, artist: 'X'),
          ],
        },
      );
      final engine = _FakeEngine(
        legs: [(pf: MusicPlatform.kw, scriptId: 'suyin')],
        scriptResults: {
          'suyin': [
            {
              'id': 'kw-s1',
              'name': 'Same Song',
              'singer': 'X',
              'interval': '3:00',
            },
            {
              'id': 'kw-s2',
              'name': 'Script Only',
              'singer': 'Y',
              'interval': '2:30',
            },
          ],
        },
        scriptDelay: const Duration(seconds: 1),
      );
      final service = SongSearchService(api: api, scriptEngine: engine);
      final updates = <SearchStreamUpdate>[];
      var done = false;
      service.searchAllStream('test').listen(updates.add, onDone: () => done = true);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      // t = 1 s: the script search already returned, but the kw
      // platform leg (2 s) has not settled, so the script songs must
      // NOT be shown yet — the platform list is authoritative.
      expect(
        updates.expand((u) => u.songs).where((s) => s.title == 'Script Only'),
        isEmpty,
      );
      expect(done, isFalse);
      async.elapse(const Duration(seconds: 1));
      async.flushMicrotasks();
      // t = 2 s: kw platform leg settled, then the script leg emitted.
      expect(done, isTrue);
      final titles = updates.last.songs.map((s) => s.title).toList();
      expect(titles.where((t) => t == 'Same Song').length, 1,
          reason: 'script dupe of the platform song is dropped');
      expect(titles, contains('Script Only'));
    });
  });

  test('sortSongsByPlatformPriority: wy+tx first, arrival order within groups', () {
    final songs = [
      _song('k1', 'K1', MusicPlatform.kw),
      _song('w1', 'W1', MusicPlatform.wy),
      _song('g1', 'G1', MusicPlatform.kg),
      _song('t1', 'T1', MusicPlatform.tx),
      _song('w2', 'W2', MusicPlatform.wy),
      _song('k2', 'K2', MusicPlatform.kw),
    ];
    final sorted = sortSongsByPlatformPriority(songs);
    // wy + tx first (arrival order between them: W1, then T1, then
    // W2), others after (arrival order: K1, G1, K2). Same-platform
    // order never changes (W1 before W2, K1 before K2).
    expect(
      sorted.map((s) => s.title).toList(),
      ['W1', 'T1', 'W2', 'K1', 'G1', 'K2'],
    );
    // Input untouched.
    expect(
      songs.map((s) => s.title).toList(),
      ['K1', 'W1', 'G1', 'T1', 'W2', 'K2'],
    );
    // Empty / single-song are no-ops.
    expect(sortSongsByPlatformPriority(const []), isEmpty);
    expect(
      sortSongsByPlatformPriority([songs.first]).map((s) => s.title),
      ['K1'],
    );
  });

  test('kw fast leg shows first, wy/tx jump to front when they settle', () {
    fakeAsync((async) {
      final api = _FakeApi(
        delays: const {
          MusicPlatform.wy: Duration(seconds: 2),
          MusicPlatform.tx: Duration(seconds: 3),
          MusicPlatform.kg: Duration(seconds: 5),
          MusicPlatform.kw: Duration(milliseconds: 100),
        },
        results: {
          MusicPlatform.wy: [
            _song('w1', 'WY1', MusicPlatform.wy),
            _song('w2', 'WY2', MusicPlatform.wy),
          ],
          MusicPlatform.tx: [_song('t', 'TX', MusicPlatform.tx)],
          MusicPlatform.kg: [_song('g', 'KG', MusicPlatform.kg)],
          MusicPlatform.kw: [
            _song('k1', 'KW1', MusicPlatform.kw),
            _song('k2', 'KW2', MusicPlatform.kw),
          ],
        },
      );
      final service = SongSearchService(api: api, scriptEngine: _FakeEngine());
      final updates = <SearchStreamUpdate>[];
      var done = false;
      service.searchAllStream('test').listen(updates.add, onDone: () => done = true);
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();
      // t = 100 ms: only the fastest leg (kw) has returned — its
      // songs show immediately (秒出 kept, no waiting for wy/tx).
      expect(updates.length, 1);
      expect(
        updates.last.songs.map((s) => s.title).toList(),
        ['KW1', 'KW2'],
      );
      expect(done, isFalse);
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      // t = 5 s: every leg settled. wy + tx moved to the front
      // (arrival order between them: WY1/WY2 at 2 s, TX at 3 s),
      // kw/kg after (arrival order), same-platform order kept.
      expect(done, isTrue);
      expect(
        updates.last.songs.map((s) => s.title).toList(),
        ['WY1', 'WY2', 'TX', 'KW1', 'KW2', 'KG'],
      );
      expect(updates.last.pending, isEmpty);
    });
  });

  test('tx arriving before wy stays ahead of it inside the priority group', () {
    fakeAsync((async) {
      final api = _FakeApi(
        delays: const {
          MusicPlatform.wy: Duration(seconds: 2),
          MusicPlatform.tx: Duration(milliseconds: 100),
          MusicPlatform.kg: Duration(seconds: 5),
          MusicPlatform.kw: Duration(seconds: 5),
        },
        results: {
          MusicPlatform.wy: [_song('w', 'WY', MusicPlatform.wy)],
          MusicPlatform.tx: [_song('t', 'TX', MusicPlatform.tx)],
          MusicPlatform.kg: [_song('g', 'KG', MusicPlatform.kg)],
          MusicPlatform.kw: [_song('k', 'KW', MusicPlatform.kw)],
        },
      );
      final service = SongSearchService(api: api, scriptEngine: _FakeEngine());
      final updates = <SearchStreamUpdate>[];
      var done = false;
      service.searchAllStream('test').listen(updates.add, onDone: () => done = true);
      async.elapse(const Duration(milliseconds: 100));
      async.flushMicrotasks();
      // t = 100 ms: only tx has returned.
      expect(
        updates.last.songs.map((s) => s.title).toList(),
        ['TX'],
      );
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      // wy settles at 2 s but does NOT jump ahead of tx: inside the
      // wy/tx group the original arrival order rules.
      expect(done, isTrue);
      expect(
        updates.last.songs.map((s) => s.title).toList(),
        ['TX', 'WY', 'KG', 'KW'],
      );
    });
  });

  test('script-leg songs sort by their own platform, not by leg', () {
    fakeAsync((async) {
      final api = _FakeApi(
        delays: const {
          MusicPlatform.wy: Duration(seconds: 2),
          MusicPlatform.tx: Duration(seconds: 5),
          MusicPlatform.kg: Duration(seconds: 5),
          MusicPlatform.kw: Duration(milliseconds: 100),
        },
        results: {
          MusicPlatform.wy: [_song('w', 'W1', MusicPlatform.wy)],
          MusicPlatform.kw: [_song('k1', 'K1', MusicPlatform.kw)],
        },
      );
      final engine = _FakeEngine(
        legs: [(pf: MusicPlatform.kw, scriptId: 'suyin')],
        scriptResults: {
          'suyin': [
            {
              'id': 'kw-s2',
              'name': 'K2',
              'singer': 'Y',
              'interval': '2:30',
            },
          ],
        },
        scriptDelay: const Duration(milliseconds: 200),
      );
      final service = SongSearchService(api: api, scriptEngine: engine);
      final updates = <SearchStreamUpdate>[];
      var done = false;
      service.searchAllStream('test').listen(updates.add, onDone: () => done = true);
      async.elapse(const Duration(milliseconds: 200));
      async.flushMicrotasks();
      // t = 200 ms: kw platform song + kw script song, both rank 1.
      expect(
        updates.last.songs.map((s) => s.title).toList(),
        ['K1', 'K2'],
      );
      async.elapse(const Duration(seconds: 5));
      async.flushMicrotasks();
      // t = 5 s: the late wy song sorts to the front even though
      // the kw songs (platform + script) arrived first.
      expect(done, isTrue);
      expect(
        updates.last.songs.map((s) => s.title).toList(),
        ['W1', 'K1', 'K2'],
      );
    });
  });
}
