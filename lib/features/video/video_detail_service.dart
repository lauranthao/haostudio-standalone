// Video detail service — fast open (fix 4).
//
// Port of the web detail race (app.js `renderVideoDetail` + `vodDetGet`
// + `detDirectP`, fix 4):
// - Result cache 300 s + pending-promise cache (30 s): a pointer-down
//   prefetch and the detail render share one request instead of
//   fetching twice.
// - Prefetch: at most 3 inflight.
// - Fast open (2026-11-17, chen: 每次解析都用最快的，换源直到能播):
//   the tapped source AND the fastest-first alt sweep start IN
//   PARALLEL the moment the page opens — before, the alt race only
//   started after a 3.5 s first window, so a slow tapped source
//   delayed the fast sources (金鹰/非凡） by 3.5 s for nothing. The
//   first usable detail wins: the tapped source when it is fast
//   (exact title/vodId by construction), otherwise the fastest alt
//   carrying the same title. The sweep keeps switching sources until
//   one yields a usable detail (up to 5 alts) or nothing is left to
//   try; the race ends at the 7 s deadline at the latest, and
//   immediately when every candidate has failed. The error card shows
//   as soon as the race resolves empty, never later.
// - Direct detail fetch: one retry on fast (non-timeout) failures
//   only — a timeout means the CMS host is slow; a blind second
//   attempt just doubles the wait.
// - The winning alt result is cached under its own source+id, and the
//   caller is told the detail switched sources (page shows a
//   "正在换源播放…" toast and opens the winning source+id).
//
// The fetch functions are injectable so the race/timeout behaviour is
// unit-testable without the network; production wires [CmsClient].

import 'dart:async';

import 'package:dio/dio.dart';

import '../../services/video/cms_client.dart';
import 'video_models.dart';

/// Outcome of [VideoDetailService.loadWithRace].
class DetailRaceResult {
  const DetailRaceResult({
    required this.detail,
    required this.sourceId,
    required this.vodId,
    required this.switchedSource,
  });

  /// The usable detail (has lines with episodes).
  final VideoDetail detail;

  /// Source/id the detail actually came from (may differ from the
  /// requested ones when the alt-source race won).
  final dynamic sourceId;
  final String vodId;

  /// True when the alt-source race won (caller shows the switch toast
  /// and re-opens under the winning source+id).
  final bool switchedSource;
}

typedef DetailFetcher = Future<VideoDetail> Function(
  dynamic sourceId,
  String vodId, {
  CancelToken? cancelToken,
});

/// Alt sources carrying the same title, streamed fastest-first: each
/// match is yielded the moment its source answers, instead of waiting
/// for the whole scan (see [CmsClient.altSourcesStream]).
typedef AltSourcesStreamer = Stream<AltVideoSource> Function(
  String title,
  String year,
  dynamic excludeSourceId, {
  CancelToken? cancelToken,
});

class _CachedDetail {
  _CachedDetail({required this.at, this.result, this.pending});

  final DateTime at;
  final VideoDetail? result;
  final Future<VideoDetail>? pending;
}

class VideoDetailService {
  VideoDetailService({
    DetailFetcher? fetchDetail,
    AltSourcesStreamer? findAlts,
    CmsClient? cms,
  })  : _fetchDetail = fetchDetail ??
            ((sourceId, vodId, {cancelToken}) =>
                (cms ?? CmsClient()).detail(
                  sourceId,
                  vodId,
                  cancelToken: cancelToken,
                )),
        _findAlts = findAlts ??
            ((title, year, exclude, {cancelToken}) =>
                (cms ?? CmsClient()).altSourcesStream(
                  title,
                  year,
                  exclude,
                  cancelToken: cancelToken,
                ));

  final DetailFetcher _fetchDetail;
  final AltSourcesStreamer _findAlts;

  /// Alt sources for [title]/[year] excluding [excludeSourceId],
  /// fastest first (shared by the detail race and the player's
  /// play-time source switch).
  Stream<AltVideoSource> findAlts(
    String title,
    String year,
    dynamic excludeSourceId, {
    CancelToken? cancelToken,
  }) =>
      _findAlts(title, year, excludeSourceId, cancelToken: cancelToken);

  final Map<String, _CachedDetail> _cache = {};

  static const Duration resultTtl = Duration(seconds: 300);
  static const Duration pendingTtl = Duration(seconds: 30);
  static const int maxPrefetchInflight = 3;

  /// First fetch: 3.5 s timer. Alt race: a further 3.5 s.
  static const Duration firstRace = Duration(milliseconds: 3500);
  static const Duration altRace = Duration(milliseconds: 3500);

  String _key(dynamic sourceId, String vodId) => '$sourceId|$vodId';

  /// One direct detail fetch with the web's retry rule: one retry on
  /// fast (non-timeout) failures only. A caller cancellation is not a
  /// failure and is never retried (V-P1-4).
  Future<VideoDetail> _directFetch(
    dynamic sourceId,
    String vodId, {
    CancelToken? cancelToken,
  }) async {
    try {
      final r = await _fetchDetail(
        sourceId,
        vodId,
        cancelToken: cancelToken,
      );
      if (!r.usable) throw StateError('direct detail fail');
      return r;
    } on CmsTimeoutException {
      rethrow;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) rethrow;
      // Fast failure — one retry, then give up.
      final r = await _fetchDetail(
        sourceId,
        vodId,
        cancelToken: cancelToken,
      );
      if (!r.usable) throw StateError('direct detail fail');
      return r;
    } catch (_) {
      // Fast failure — one retry, then give up.
      final r = await _fetchDetail(
        sourceId,
        vodId,
        cancelToken: cancelToken,
      );
      if (!r.usable) throw StateError('direct detail fail');
      return r;
    }
  }

  /// `vodDetGet(sid, vid)`: resolved results live 5 min; in-flight
  /// futures are shared (30 s window).
  Future<VideoDetail> get(
    dynamic sourceId,
    String vodId, {
    CancelToken? cancelToken,
  }) {
    final k = _key(sourceId, vodId);
    final now = DateTime.now();
    final c = _cache[k];
    if (c != null) {
      if (c.result != null && now.difference(c.at) < resultTtl) {
        return Future.value(c.result);
      }
      if (c.result == null &&
          c.pending != null &&
          now.difference(c.at) < pendingTtl) {
        return c.pending!;
      }
    }
    late final Future<VideoDetail> p;
    p = _directFetch(
      sourceId,
      vodId,
      cancelToken: cancelToken,
    ).then((r) {
      if (_cache[k]?.pending == p) {
        _cache[k] = _CachedDetail(at: DateTime.now(), result: r, pending: p);
      }
      return r;
    }, onError: (Object e) {
      if (_cache[k]?.pending == p) _cache.remove(k);
      throw e;
    });
    _cache[k] = _CachedDetail(at: now, pending: p);
    return p;
  }

  /// Cache a winning alt-source detail under its own source+id.
  void cacheResult(dynamic sourceId, String vodId, VideoDetail detail) {
    final k = _key(sourceId, vodId);
    _cache[k] = _CachedDetail(
      at: DateTime.now(),
      result: detail,
      pending: Future.value(detail),
    );
  }

  /// `vodDetPrefetch(sid, vid)`: head start on pointer-down of a poster
  /// card; at most 3 inflight prefetches.
  void prefetch(dynamic sourceId, String vodId) {
    if (sourceId == null || vodId.isEmpty) return;
    var inflight = 0;
    for (final c in _cache.values) {
      if (c.result == null && c.pending != null) inflight++;
    }
    if (inflight >= maxPrefetchInflight) return;
    unawaited(get(sourceId, vodId).then((_) {}, onError: (_) {}));
  }

  /// Fast-open race (fix 4, reworked 2026-11-17). Returns null when
  /// nothing usable arrives within the race windows — the caller shows
  /// the error card with retry (retry re-runs the whole race).
  ///
  /// The tapped source and the fastest-first alt sweep start IN
  /// PARALLEL at t=0; the first usable detail wins. The sweep keeps
  /// switching sources until one yields a usable detail, or every
  /// candidate has failed (then null returns immediately — no staring
  /// at the skeleton for the full 7 s), or the 7 s deadline fires.
  ///
  /// [preload] is the list item the user tapped (cover + title on
  /// screen instantly; its title/year drive the alt-source sweep).
  /// [cancelToken] (V-P1-4): the detail page cancels it on dispose;
  /// the tapped fetch and the alt sweep both honour it, and a
  /// cancellation is never retried as a failure.
  Future<DetailRaceResult?> loadWithRace(
    dynamic sourceId,
    String vodId, {
    VideoItem? preload,
    CancelToken? cancelToken,
  }) async {
    final completer = Completer<DetailRaceResult?>();
    var settled = false;
    StreamSubscription<AltVideoSource>? altSub;
    Timer? deadline;

    void settle(DetailRaceResult? r) {
      if (settled) return;
      settled = true;
      deadline?.cancel();
      unawaited(altSub?.cancel());
      completer.complete(r);
    }

    // Overall budget: firstRace + altRace (7 s), same as before.
    deadline = Timer(firstRace + altRace, () => settle(null));

    // Early exit when nothing is left to try: the tapped fetch has
    // failed AND the sweep is done AND no alt detail is in flight.
    var firstFailed = false;
    var altsDone = false;
    var altInflight = 0;
    void maybeSettleNull() {
      if (firstFailed && altsDone && altInflight == 0) settle(null);
    }

    // 1. Tapped source — exact title/vodId. Raced, not awaited first:
    // when it is fast it wins (correct by construction); when slow,
    // the fastest alt below wins instead of making the user wait.
    unawaited(get(
      sourceId,
      vodId,
      cancelToken: cancelToken,
    ).then((d) {
      settle(DetailRaceResult(
        detail: d,
        sourceId: sourceId,
        vodId: vodId,
        switchedSource: false,
      ));
    }, onError: (_) {
      firstFailed = true;
      maybeSettleNull();
    }));

    final title = preload?.name ?? '';
    final year = preload?.year ?? '';
    if (title.isNotEmpty) {
      // 2. Fastest-first sweep, starting NOW (not after the 3.5 s
      // first window): sources are scanned in priority order, each
      // match's detail is fetched the moment it is found (3 s each),
      // and the first usable detail wins.
      altSub = _findAlts(
        title,
        year,
        sourceId,
        cancelToken: cancelToken,
      ).listen((alt) {
        if (settled) return;
        altInflight++;
        unawaited(_fetchDetail(
          alt.source,
          alt.vodId,
          cancelToken: cancelToken,
        )
            .timeout(
              const Duration(seconds: 3),
              onTimeout: () => throw TimeoutException('alt detail timeout'),
            )
            .then((d) {
          altInflight--;
          if (d.usable && !settled) {
            cacheResult(alt.source, alt.vodId, d);
            settle(DetailRaceResult(
              detail: d,
              sourceId: alt.source,
              vodId: alt.vodId,
              switchedSource: true,
            ));
          } else {
            maybeSettleNull();
          }
        }, onError: (_) {
          altInflight--;
          maybeSettleNull();
        }));
      }, onDone: () {
        altsDone = true;
        maybeSettleNull();
      }, onError: (_) {
        altsDone = true;
        maybeSettleNull();
      });
    } else {
      // No title to sweep with — the tapped fetch gets the whole
      // window (the deadline is the backstop if it hangs); a fast
      // failure settles null at once via maybeSettleNull.
      altsDone = true;
    }

    return completer.future;
  }
}
