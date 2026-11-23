// Emby page inside the video tab (build 28).
//
// Own State / Client / CancelToken / cache — never shared with the
// CMS home page. The parent (VideoTabPage) unmounts this page on
// switch (no IndexedStack), so dispose() cancels in-flight requests
// and nothing keeps running while hidden.
//
// What it shows: search pill (Emby-only search, inline) → Continue
// Watching (Emby history rows only, source == 'emby') → 电影 → 剧集.
// History/favourites stores are SHARED with CMS, but each page only
// ever shows its own source's rows, and opening a row always routes
// by source (here: EmbyDetailPage). There is deliberately NO
// history/favourites button on this page: the shared History/Favs
// pages still route everything through the CMS detail page (not
// this group's files), so sending users there with Emby rows would
// open the wrong detail — that routing is an open item for the
// coordinator, tracked in the build-28 report.
//
// Posters go through RefererImage with the X-Emby-Token header; the
// image URL itself never carries api_key. The poster card below
// copies VideoPosterCard's values (2:3, radius standard, title
// 13/600, meta 12, count badge, watched ✓) because that widget has
// no headers parameter and lives outside this group's files.

import 'dart:async';
import 'dart:convert';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/storage/hive_store.dart';
import '../../core/theme/glass.dart';
import '../../core/theme/hao_radius.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../widgets/hao_search_field.dart';
import '../../services/video/emby_client.dart';
import '../../services/video/emby_models.dart';
import '../settings/video_sources_page.dart';
import 'emby_category_page.dart';
import 'emby_detail_page.dart';
import 'video_history_page.dart';
import 'video_history_store.dart';
import 'video_models.dart';
import 'video_poster_card.dart';
import 'widgets/referer_image.dart';

/// Series ids that may feed a NextUp lookup from LOCAL history
/// (b29): only rows with a KNOWN next episode. A local row's vodId
/// is the series id for a series detail — but for a movie it is the
/// movie id, and passing a movie id as `seriesId` to /Shows/NextUp
/// is how a film could leak into 下一集. Movies never carry
/// `nextEpName` (see `historyNextEpisode`), so this filter keeps
/// them out. Rows recorded from a single-episode detail carry an
/// episode id, not a series id — the server answers those with an
/// empty list, never a wrong episode.
List<String> embyFallbackNextUpSeriesIds(List<WatchHistoryEntry> history) {
  final ids = <String>[];
  for (final h in history) {
    if (h.hasNextEpisode && h.vodId.isNotEmpty && !ids.contains(h.vodId)) {
      ids.add(h.vodId);
    }
  }
  return ids;
}

/// Drop NextUp items whose series is already in the resume rail
/// (b29): while an episode is still in progress the series poster
/// is already in 继续观看 — showing its next episode in 下一集 as
/// well is the same duplicate chen reported on the CMS bar. A series
/// enters 下一集 only once its current episode leaves 继续观看
/// (finished). Items with no series id cannot be matched, so they
/// are kept. Repeated episodes of one series keep the first only.
List<VideoItem> filterEmbyNextUp(
  List<VideoItem> nextUp,
  Set<String> resumeSeriesIds,
) {
  final seen = <String>{};
  final out = <VideoItem>[];
  for (final item in nextUp) {
    final sid = item.seriesId;
    if (sid.isEmpty) {
      out.add(item);
      continue;
    }
    if (resumeSeriesIds.contains(sid)) continue;
    if (!seen.add(sid)) continue;
    out.add(item);
  }
  return out;
}

class EmbyTabPage extends StatefulWidget {
  const EmbyTabPage({super.key, this.client});

  /// Test seam: production passes null and the page loads the stored
  /// config itself.
  final EmbyClient? client;

  @override
  State<EmbyTabPage> createState() => _EmbyTabPageState();
}

enum _EmbyPhase { unconfigured, disabled, needsUser, loading, error, ready }

class _EmbyTabPageState extends State<EmbyTabPage> {
  EmbyClient? _client;
  _EmbyPhase _phase = _EmbyPhase.loading;
  String _errorMessage = '';

  List<VideoItem> _movies = [];
  List<VideoItem> _series = [];
  List<WatchHistoryEntry> _history = [];
  bool _stale = false;

  /// Library totals for pagination (1.1.6): the server reports
  /// TotalRecordCount; the rows load 60 at a time and offer
  /// "load more" until everything is shown (before: 60+ items
  /// were silently cut off).
  int _moviesTotal = 0;
  int _seriesTotal = 0;
  bool _moviesLoadingMore = false;
  bool _seriesLoadingMore = false;
  String? _movieLibId;
  String? _tvLibId;

  /// Libraries the server reported + per-library item counts, for
  /// the inventory line under the search box (build 30 audit §17):
  /// chen matches what the app found against his server.
  List<EmbyLibrary> _libraries = [];
  Map<String, int> _libraryCounts = {};

  /// Server-side resume (GET /Items/Resume) + per-series next-up
  /// (GET /Shows/NextUp), 1.1.6. [_resumeFromServer] is true only
  /// when the server actually answered; otherwise the page falls
  /// back to local history and [_serverResume] stays empty.
  List<VideoItem> _serverResume = [];
  List<VideoItem> _nextUp = [];
  bool _resumeFromServer = false;

  CancelToken? _loadToken;
  CancelToken? _searchToken;
  final _searchController = TextEditingController();

  bool _searchMode = false;
  bool _searching = false;
  String _searchQuery = '';
  List<VideoItem> _searchResults = [];
  String _searchError = '';

  /// Search pagination: server total + in-flight flag for the
  /// load-more footer under the search grid.
  int _searchTotal = 0;
  bool _searchLoadingMore = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  @override
  void dispose() {
    _loadToken?.cancel();
    _searchToken?.cancel();
    _searchController.dispose();
    super.dispose();
  }

  // -- Cache (hao_emby_home, same shape as the CMS home cache) --------

  VideoHomeData? _loadCached() {
    String? raw;
    try {
      raw = HiveStore.box.get(HiveKeys.embyHomeCache) as String?;
    } catch (_) {
      return null;
    }
    if (raw == null || raw.isEmpty) return null;
    try {
      final decoded = jsonDecode(raw);
      if (decoded is Map<String, dynamic>) {
        return VideoHomeData.fromJson(decoded);
      }
    } catch (_) {}
    return null;
  }

  Future<void> _saveCache() async {
    final rows = <VideoHomeRow>[
      if (_movies.isNotEmpty)
        VideoHomeRow(name: '电影', count: _movies.length, items: _movies),
      if (_series.isNotEmpty)
        VideoHomeRow(name: '剧集', count: _series.length, items: _series),
    ];
    if (rows.isEmpty) return;
    try {
      await HiveStore.put(
        HiveKeys.embyHomeCache,
        jsonEncode(
          VideoHomeData(rows: rows, fetchedAt: DateTime.now()).toJson(),
        ),
      );
    } catch (_) {}
  }

  // -- Load --------------------------------------------------------------

  Future<void> _load({bool force = false}) async {
    final config = widget.client?.config ?? EmbyConfigStore.load();
    if (config == null || !config.isConfigured) {
      if (mounted) setState(() => _phase = _EmbyPhase.unconfigured);
      return;
    }
    if (!config.enabled) {
      if (mounted) setState(() => _phase = _EmbyPhase.disabled);
      return;
    }
    _client = widget.client ?? EmbyClient(config: config);

    if (!force) {
      final cached = _loadCached();
      if (cached != null) {
        _applyRows(cached);
        if (mounted) setState(() => _phase = _EmbyPhase.ready);
      }
    }
    _history = VideoHistoryStore.getAll()
        .where((e) => e.sourceKey == EmbyClient.sourceId)
        .toList();
    if (mounted) setState(() {});

    _loadToken?.cancel();
    final token = _loadToken = CancelToken();
    try {
      await _client!.ensureApiRoot(cancelToken: token);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      if (!mounted) return;
      _fail('连不上 Emby 服务器，检查地址和网络');
      return;
    } on EmbyException catch (e) {
      if (!mounted) return;
      _fail(e.message);
      return;
    }
    if (!mounted) return;

    // userId comes from probe, never typed by the user. Single user:
    // take it silently. Several: stop here — Settings picks one.
    if (config.userId.isEmpty) {
      EmbyProbeResult probe;
      try {
        probe = await _client!.probe(cancelToken: token);
      } on DioException catch (e) {
        if (e.type == DioExceptionType.cancel) return;
        if (!mounted) return;
        _fail('连不上 Emby 服务器，检查地址和网络');
        return;
      }
      if (!mounted) return;
      if (!probe.ok) {
        _fail(probe.errorMessage);
        return;
      }
      if (probe.users.isEmpty) {
        _fail('Emby 没有返回用户，请在设置里重新测连通');
        return;
      }
      if (probe.users.length > 1) {
        setState(() => _phase = _EmbyPhase.needsUser);
        return;
      }
      final updated = config.copyWith(userId: probe.users.first.id);
      await EmbyConfigStore.save(updated);
      _client = EmbyClient(config: updated);
    }

    final client = _client!;
    List<EmbyLibrary> libraries = const [];
    try {
      libraries = await client.libraries(cancelToken: token);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
    } on EmbyException catch (e) {
      if (!mounted) return;
      _fail(e.message);
      return;
    }
    if (!mounted) return;
    // Pinned library only (config.movieLibraryId / tvLibraryId):
    // when unpinned the query carries NO parentId, so every library
    // of that type is read. The old code passed the FIRST library's
    // id and silently hid the other libraries' content — the
    // model comment ("null = all libraries of that type") already
    // promised this behaviour.
    final movieLibId = config.movieLibraryId?.isNotEmpty == true
        ? _pickLibrary(
            libraries,
            config.movieLibraryId,
            (l) => l.isMovieLibrary,
          )?.id
        : null;
    final tvLibId = config.tvLibraryId?.isNotEmpty == true
        ? _pickLibrary(
            libraries,
            config.tvLibraryId,
            (l) => l.isTvLibrary,
          )?.id
        : null;

    // Movie and series loads are independent: one failing must not
    // kill the other row. A failed rail keeps its old rows but marks
    // the page stale (build 30 audit §17) — before, a failure was
    // silent and the page looked complete with half the content.
    // Depth is preserved too: a refresh re-fetches as many rows as
    // the user had already loaded via "加载更多", instead of
    // shrinking the list back to the first 60.
    List<VideoItem> movies = _movies;
    List<VideoItem> series = _series;
    var moviesTotal = _moviesTotal;
    var seriesTotal = _seriesTotal;
    var moviesFailed = false;
    var seriesFailed = false;
    try {
      final page = await client.movies(
        libraryId: movieLibId,
        limit: _movies.length > 60 ? _movies.length : 60,
        cancelToken: token,
      );
      movies = page.items;
      moviesTotal = page.totalCount;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      moviesFailed = true;
    } on EmbyException catch (_) {
      moviesFailed = true;
    }
    try {
      final page = await client.series(
        libraryId: tvLibId,
        limit: _series.length > 60 ? _series.length : 60,
        cancelToken: token,
      );
      series = page.items;
      seriesTotal = page.totalCount;
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      seriesFailed = true;
    } on EmbyException catch (_) {
      seriesFailed = true;
    }
    if (!mounted) return;
    // Both rails failed and there is nothing to show: say so, with
    // a retry, instead of the misleading 'Emby 片库是空的'.
    if (moviesFailed && seriesFailed && movies.isEmpty && series.isEmpty) {
      _fail('Emby 影片加载失败，下拉重试');
      return;
    }
    setState(() {
      _movies = movies;
      _series = series;
      _moviesTotal = moviesTotal;
      _seriesTotal = seriesTotal;
      _movieLibId = movieLibId;
      _tvLibId = tvLibId;
      _libraries = libraries;
      _history = VideoHistoryStore.getAll()
          .where((e) => e.sourceKey == EmbyClient.sourceId)
          .toList();
      _phase = _EmbyPhase.ready;
      _stale = moviesFailed || seriesFailed;
    });
    unawaited(_saveCache());
    unawaited(_loadServerResume(client, token));
    unawaited(_loadLibraryCounts(client, libraries, token));
  }

  /// Per-library counts for the inventory line (best-effort): one
  /// Limit-1 query per library; a failure leaves that library's
  /// count out instead of failing the page.
  Future<void> _loadLibraryCounts(
    EmbyClient client,
    List<EmbyLibrary> libraries,
    CancelToken token,
  ) async {
    final counts = <String, int>{};
    for (final lib in libraries) {
      if (token.isCancelled || !mounted) return;
      try {
        counts[lib.id] = await client.libraryItemCount(
          lib.id,
          includeItemTypes: _countTypesFor(lib),
          cancelToken: token,
        );
      } catch (_) {
        // Best-effort: the library still shows, without a count.
      }
    }
    if (mounted) setState(() => _libraryCounts = counts);
  }

  /// What a library's inventory count counts: films (+ loose videos)
  /// for a movies library, series for a tv library, both for mixed;
  /// everything for any other kind (music/photos/…).
  static String? _countTypesFor(EmbyLibrary lib) {
    switch (lib.collectionType) {
      case 'movies':
        return 'Movie,Video';
      case 'tvshows':
        return 'Series';
      case 'mixed':
        return 'Movie,Video,Series';
      default:
        return null;
    }
  }

  /// Server resume + next-up rails (1.1.6, best-effort): a server
  /// failure here never fails the page — the local-history
  /// "继续观看" row stays as the fallback, and the "下一集" rail
  /// simply stays empty.
  Future<void> _loadServerResume(EmbyClient client, CancelToken token) async {
    List<VideoItem> resume;
    try {
      resume = await client.resumeItems(cancelToken: token);
    } catch (_) {
      return;
    }
    if (!mounted || token.isCancelled) return;
    // Next-up series: from the resume episodes' SeriesId first
    // (server data), else from local history rows (their vodId IS
    // the series id for Emby series playback). At most 5 series,
    // one NextUp call each — never a per-item sweep.
    final seriesIds = <String>[];
    void addSeries(String id) {
      if (id.isNotEmpty && !seriesIds.contains(id)) seriesIds.add(id);
    }

    for (final item in resume) {
      if (item.seriesId.isNotEmpty) {
        addSeries(item.seriesId);
      } else if (item.mediaType == 'Series') {
        addSeries(item.vodId);
      }
    }
    if (seriesIds.isEmpty) {
      // Local-history fallback: series rows only (b29). Every local
      // row's vodId was passed here before — including movie rows,
      // whose vodId is a movie id, not a series id.
      for (final sid in embyFallbackNextUpSeriesIds(_history)) {
        addSeries(sid);
      }
    }
    final next = <VideoItem>[];
    for (final sid in seriesIds.take(5)) {
      if (!mounted || token.isCancelled) return;
      try {
        next.addAll(await client.nextUp(seriesId: sid, cancelToken: token));
      } catch (_) {
        // One series without a next episode must not kill the rail.
      }
    }
    // One work, one rail (b29): a series already in 继续观看 — the
    // server resume items, or the local-history rows shown when the
    // server has nothing in progress — stays out of 下一集.
    final resumeSeries = <String>{
      for (final item in resume)
        if (item.seriesId.isNotEmpty)
          item.seriesId
        else if (item.mediaType == 'Series')
          item.vodId,
      for (final h in _history)
        if (h.hasNextEpisode) h.vodId,
    };
    if (!mounted) return;
    setState(() {
      _serverResume = resume;
      _nextUp = filterEmbyNextUp(next, resumeSeries);
      _resumeFromServer = true;
    });
  }

  Future<void> _loadMoreMovies() async {
    final client = _client;
    if (client == null || _moviesLoadingMore) return;
    if (_moviesTotal > 0 && _movies.length >= _moviesTotal) return;
    setState(() => _moviesLoadingMore = true);
    try {
      final page = await client.movies(
        libraryId: _movieLibId,
        startIndex: _movies.length,
        limit: 60,
      );
      if (!mounted) return;
      setState(() {
        _movies = [..._movies, ...page.items];
        _moviesTotal = page.totalCount;
        _moviesLoadingMore = false;
      });
      unawaited(_saveCache());
    } catch (_) {
      if (mounted) setState(() => _moviesLoadingMore = false);
    }
  }

  Future<void> _loadMoreSeries() async {
    final client = _client;
    if (client == null || _seriesLoadingMore) return;
    if (_seriesTotal > 0 && _series.length >= _seriesTotal) return;
    setState(() => _seriesLoadingMore = true);
    try {
      final page = await client.series(
        libraryId: _tvLibId,
        startIndex: _series.length,
        limit: 60,
      );
      if (!mounted) return;
      setState(() {
        _series = [..._series, ...page.items];
        _seriesTotal = page.totalCount;
        _seriesLoadingMore = false;
      });
      unawaited(_saveCache());
    } catch (_) {
      if (mounted) setState(() => _seriesLoadingMore = false);
    }
  }

  EmbyLibrary? _pickLibrary(
    List<EmbyLibrary> libraries,
    String? pinnedId,
    bool Function(EmbyLibrary) matches,
  ) {
    if (pinnedId != null && pinnedId.isNotEmpty) {
      for (final l in libraries) {
        if (l.id == pinnedId) return l;
      }
    }
    for (final l in libraries) {
      if (matches(l)) return l;
    }
    return null;
  }

  void _applyRows(VideoHomeData cached) {
    for (final row in cached.rows) {
      if (row.name == '电影') {
        _movies = row.items;
        _moviesTotal = row.items.length;
      }
      if (row.name == '剧集') {
        _series = row.items;
        _seriesTotal = row.items.length;
      }
    }
  }

  void _fail(String message) {
    setState(() {
      _errorMessage = message;
      if (_movies.isEmpty && _series.isEmpty) {
        _phase = _EmbyPhase.error;
      } else {
        _phase = _EmbyPhase.ready;
        _stale = true;
      }
    });
  }

  // -- Search (Emby only, inline) ----------------------------------------

  void _openSearch() {
    setState(() {
      _searchMode = true;
      _searchQuery = '';
      _searchResults = [];
      _searchTotal = 0;
      _searchError = '';
    });
  }

  void _closeSearch() {
    _searchToken?.cancel();
    setState(() {
      _searchMode = false;
      _searching = false;
      _searchResults = [];
      _searchTotal = 0;
      _searchController.clear();
    });
  }

  Future<void> _runSearch(String query) async {
    final client = _client;
    final q = query.trim();
    if (client == null || q.isEmpty) return;
    _searchToken?.cancel();
    final token = _searchToken = CancelToken();
    setState(() {
      _searching = true;
      _searchQuery = q;
      _searchError = '';
      _searchTotal = 0;
    });
    try {
      final page = await client.search(q, cancelToken: token);
      if (!mounted) return;
      setState(() {
        _searchResults = page.items;
        _searchTotal = page.totalCount;
        _searching = false;
      });
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = '连不上 Emby 服务器，检查地址和网络';
      });
    } on EmbyException catch (e) {
      if (!mounted) return;
      setState(() {
        _searching = false;
        _searchError = e.message;
      });
    }
  }

  /// Search load-more — same pattern as _loadMoreMovies: append the
  /// next page under the grid. The old search capped at 50 with no
  /// way to see the rest.
  Future<void> _loadMoreSearch() async {
    final client = _client;
    if (client == null || _searchLoadingMore) return;
    if (_searchTotal > 0 && _searchResults.length >= _searchTotal) return;
    setState(() => _searchLoadingMore = true);
    try {
      final page = await client.search(
        _searchQuery,
        startIndex: _searchResults.length,
      );
      if (!mounted) return;
      setState(() {
        _searchResults = [..._searchResults, ...page.items];
        _searchTotal = page.totalCount;
        _searchLoadingMore = false;
      });
    } catch (_) {
      if (mounted) setState(() => _searchLoadingMore = false);
    }
  }

  // -- Navigation ----------------------------------------------------------

  void _openDetail(VideoItem item, {bool autoResume = false}) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => EmbyDetailPage(
          itemId: item.vodId,
          preload: item,
          autoResume: autoResume,
        ),
      ),
    );
  }

  void _openSettings() {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => const VideoSourcesPage(),
      ),
    );
  }

  /// Full category lists (build 30 audit §18): the rails are only a
  /// preview — the whole category lives on its own page (Infuse
  /// grid, paginated, total shown).
  void _openMoviesCategory() {
    final client = _client;
    if (client == null) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => EmbyCategoryPage(
          client: client,
          kind: EmbyCategoryKind.movies,
          libraryId: _movieLibId,
          initialItems: _movies,
          total: _moviesTotal,
          watchedKeys: _watchedKeys,
        ),
      ),
    );
  }

  /// Genres present in the loaded movies + series (`type` is the
  /// server's Genres joined with ' / '). Sorted, deduped; empty
  /// when nothing is loaded yet, so the chips row hides itself.
  List<String> get _genres {
    final out = <String>{};
    for (final item in [..._movies, ..._series]) {
      for (final g in item.type.split(' / ')) {
        final t = g.trim();
        if (t.isNotEmpty) out.add(t);
      }
    }
    return out.toList()..sort();
  }

  void _openFavoritesCategory() {
    final client = _client;
    if (client == null) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => EmbyCategoryPage(
          client: client,
          kind: EmbyCategoryKind.favorites,
          watchedKeys: _watchedKeys,
        ),
      ),
    );
  }

  void _openGenreCategory(String genre) {
    final client = _client;
    if (client == null) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => EmbyCategoryPage(
          client: client,
          kind: EmbyCategoryKind.genre,
          genre: genre,
          watchedKeys: _watchedKeys,
        ),
      ),
    );
  }

  /// 分类 chips: 收藏 + 类型. The tab used to offer only 电影 /
  /// 剧集 rails — no genre browsing, no favorites entry — even
  /// though the server parses both. One horizontal row under the
  /// library line; hidden until the first load lands.
  Widget _buildCategoryChips(HaoTheme theme) {
    final chips = <Widget>[
      _CategoryChip(
        label: '收藏',
        icon: Icons.favorite,
        onTap: _openFavoritesCategory,
      ),
      for (final g in _genres)
        _CategoryChip(label: g, onTap: () => _openGenreCategory(g)),
    ];
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 0, 0),
      child: SingleChildScrollView(
        scrollDirection: Axis.horizontal,
        child: Row(
          children: [
            for (var i = 0; i < chips.length; i++) ...[
              if (i > 0) const SizedBox(width: 8),
              chips[i],
            ],
            const SizedBox(width: 16),
          ],
        ),
      ),
    );
  }

  void _openSeriesCategory() {
    final client = _client;
    if (client == null) return;
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => EmbyCategoryPage(
          client: client,
          kind: EmbyCategoryKind.series,
          libraryId: _tvLibId,
          initialItems: _series,
          total: _seriesTotal,
          watchedKeys: _watchedKeys,
        ),
      ),
    );
  }

  /// "继续观看" full list: the history page, Emby rows only (build
  /// 30 audit §16 — "emby是emby的 影视源是影视源的"). The
  /// server-resume row itself is server data; its full list is the
  /// local Emby history (every playback on this phone writes one).
  void _openResumeHistory() {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) =>
            const VideoHistoryPage(sourceKey: EmbyClient.sourceId),
      ),
    );
  }

  Set<String> get _watchedKeys {
    final keys = _history
        .where((e) => e.isFinished)
        .map((e) => e.identityKey)
        .toSet();
    // Server-side played counts too (UserData.Played): a film
    // finished on another device must show the ✓ here, not only
    // when this phone's local history has it. The lists below
    // are everything the tab has loaded; the category pages get
    // the same set, so their badges agree with the rails.
    for (final list in [
      _movies,
      _series,
      _serverResume,
      _nextUp,
      _searchResults,
    ]) {
      for (final item in list) {
        if (item.played) keys.add(item.identityKey);
      }
    }
    return keys;
  }

  // -- Build ---------------------------------------------------------------

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      body: SafeArea(
        child: _searchMode
            ? _buildSearch(theme)
            : _phase == _EmbyPhase.loading
                ? const Center(child: CupertinoActivityIndicator())
                : _phase == _EmbyPhase.unconfigured ||
                        _phase == _EmbyPhase.disabled ||
                        _phase == _EmbyPhase.needsUser
                    ? _buildEmptyState(theme)
                    : _phase == _EmbyPhase.error
                        ? _buildError(theme)
                        : _buildHome(theme),
      ),
    );
  }

  Widget _buildEmptyState(HaoTheme theme) {
    final title = switch (_phase) {
      _EmbyPhase.unconfigured => '还没有连接 Emby',
      _EmbyPhase.disabled => 'Emby 已停用',
      _EmbyPhase.needsUser => 'Emby 有多个用户',
      _ => '',
    };
    final body = switch (_phase) {
      _EmbyPhase.unconfigured => '在设置里填入服务器地址和密钥即可连接',
      _EmbyPhase.disabled => '在设置里打开 Emby 开关即可继续',
      _EmbyPhase.needsUser => '请在设置里选择一个用户',
      _ => '',
    };
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, shadows: HaoTheme.legibilityShadows(context),  size: 48, color: theme.textMuted),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textMuted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: _openSettings,
              icon: Icon(Icons.settings, shadows: HaoTheme.legibilityShadows(context),),
              label: const Text('去设置连接'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildError(HaoTheme theme) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, shadows: HaoTheme.legibilityShadows(context),  size: 48, color: theme.textMuted),
            const SizedBox(height: 16),
            Text(
              'Emby 加载失败',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              _errorMessage,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textMuted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: () {
                setState(() => _phase = _EmbyPhase.loading);
                unawaited(_load(force: true));
              },
              icon: Icon(Icons.refresh, shadows: HaoTheme.legibilityShadows(context),),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _buildHome(HaoTheme theme) {
    return CustomScrollView(
      slivers: [
        CupertinoSliverRefreshControl(
          onRefresh: () => _load(force: true),
        ),
          SliverToBoxAdapter(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
                  child: GestureDetector(
                    onTap: () {
                      HaoHaptics.tap();
                      _openSearch();
                    },
                    child: GlassCard(
                      radius: 999,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 14,
                        vertical: 11,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.search, shadows: HaoTheme.legibilityShadows(context), 
                            color: theme.textMuted,
                            size: 20,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '搜索 Emby 影片、剧集…',
                            style: TextStyle(
                              color: theme.textMuted,
                              fontSize: 15,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
                // Library inventory (build 30 audit §17): what the
                // app found on the server, so chen can match it
                // against his library at a glance. Counts arrive
                // one query per library, best-effort — a library
                // without a count yet still shows its name.
                if (_libraries.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 10, 16, 0),
                    child: Text(
                      '媒体库：${_libraries.map((l) {
                        final count = _libraryCounts[l.id];
                        return count == null
                            ? l.name
                            : '${l.name}（$count）';
                      }).join(' · ')}',
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 12.5,
                        fontWeight: FontWeight.w500,
                      ),
                    ),
                  ),
                if (_movies.isNotEmpty || _series.isNotEmpty)
                  _buildCategoryChips(theme),
                if (_stale)
                  Padding(
                    padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                    child: GlassCard(
                      radius: 10,
                      quality: GlassCardQuality.standard,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      child: Row(
                        children: [
                          Icon(
                            Icons.info_outline, shadows: HaoTheme.legibilityShadows(context), 
                            color: theme.accent,
                            size: 16,
                          ),
                          const SizedBox(width: 8),
                          Text(
                            '内容可能不是最新',
                            style: TextStyle(
                              color: theme.textSecondary,
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                // "继续观看": server resume first (1.1.6), local
                // history only when the server did not answer or has
                // nothing in progress. The two sources never mix in
                // one row — the server is the source of truth across
                // devices, local is the offline fallback.
                if (_resumeFromServer && _serverResume.isNotEmpty) ...[
                  _SectionHead(title: '继续观看', onMore: _openResumeHistory),
                  SizedBox(
                    height: 186,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _serverResume.length,
                      itemBuilder: (context, i) {
                        final item = _serverResume[i];
                        return Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: _ResumeCard(
                            item: item,
                            imageHeaders: _client?.imageHeaders,
                            onTap: () => _openDetail(item),
                          ),
                        );
                      },
                    ),
                  ),
                ] else if (_history.isNotEmpty) ...[
                  _SectionHead(title: '继续观看', onMore: _openResumeHistory),
                  SizedBox(
                    height: 186,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _history.length,
                      itemBuilder: (context, i) {
                        final h = _history[i];
                        return Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: _ContinueCard(
                            entry: h,
                            imageHeaders: _client?.imageHeaders,
                            onTap: () => _openDetail(
                              VideoItem(
                                source: h.source,
                                sourceName: 'Emby',
                                vodId: h.vodId,
                                name: h.title,
                                pic: h.pic,
                                picAlt: h.picAlt,
                              ),
                              autoResume: true,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                // "下一集": a SEPARATE rail from "继续观看" (1.1.6) —
                // the next unwatched episode of each in-progress
                // series, from the server (GET /Shows/NextUp).
                // One work, one rail (b29): a series already in
                // 继续观看 stays out of this rail (filtered in
                // _loadServerResume), so the same poster never
                // shows in both rails at once.
                // Tapping one opens that episode's detail, which
                // plays it directly.
                if (_nextUp.isNotEmpty) ...[
                  _SectionHead(title: '下一集', onMore: null),
                  SizedBox(
                    height: 216,
                    child: ListView.builder(
                      scrollDirection: Axis.horizontal,
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      itemCount: _nextUp.length,
                      itemBuilder: (context, i) {
                        final item = _nextUp[i];
                        return Padding(
                          padding: const EdgeInsets.only(right: 12),
                          child: SizedBox(
                            width: 112,
                            child: _NextUpCard(
                              item: item,
                              imageHeaders: _client?.imageHeaders,
                              onTap: () => _openDetail(item),
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ],
                if (_movies.isNotEmpty) ...[
                  _SectionHead(title: '电影', onMore: _openMoviesCategory),
                  _PosterRow(
                    items: _movies,
                    watchedKeys: _watchedKeys,
                    imageHeaders: _client?.imageHeaders,
                    onTapItem: _openDetail,
                  ),
                  if (_moviesTotal > _movies.length)
                    _LoadMoreRow(
                      shown: _movies.length,
                      total: _moviesTotal,
                      loading: _moviesLoadingMore,
                      onTap: _loadMoreMovies,
                    ),
                ],
                if (_series.isNotEmpty) ...[
                  _SectionHead(title: '剧集', onMore: _openSeriesCategory),
                  _PosterRow(
                    items: _series,
                    watchedKeys: _watchedKeys,
                    imageHeaders: _client?.imageHeaders,
                    onTapItem: _openDetail,
                  ),
                  if (_seriesTotal > _series.length)
                    _LoadMoreRow(
                      shown: _series.length,
                      total: _seriesTotal,
                      loading: _seriesLoadingMore,
                      onTap: _loadMoreSeries,
                    ),
                ],
                if (_movies.isEmpty && _series.isEmpty) ...[
                  const SizedBox(height: 48),
                  Center(
                    child: Text(
                      'Emby 片库是空的',
                      style: TextStyle(color: theme.textMuted),
                    ),
                  ),
                ],
                const SizedBox(height: 28),
              ],
            ),
          ),
        ],
      );
  }

  Widget _buildSearch(HaoTheme theme) {
    return Column(
      children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(8, 8, 14, 4),
          child: Row(
            children: [
              IconButton(
                icon: Icon(Icons.arrow_back, shadows: HaoTheme.legibilityShadows(context),),
                onPressed: _closeSearch,
              ),
              Expanded(
                child: HaoSearchField(
                  controller: _searchController,
                  autofocus: true,
                  hintText: '搜索 Emby 影片、剧集…',
                  onSubmitted: _runSearch,
                  onClear: () {
                    setState(() {
                      _searchResults = [];
                      _searchTotal = 0;
                      _searchError = '';
                    });
                  },
                  onCancel: () {
                    setState(() {
                      _searchResults = [];
                      _searchTotal = 0;
                      _searchError = '';
                    });
                  },
                ),
              ),
            ],
          ),
        ),
        Expanded(
          child: _searching
              ? const Center(child: CupertinoActivityIndicator())
              : _searchError.isNotEmpty
                  ? Center(
                      child: Padding(
                        padding: const EdgeInsets.all(32),
                        child: Text(
                          _searchError,
                          textAlign: TextAlign.center,
                          style: TextStyle(color: theme.textMuted),
                        ),
                      ),
                    )
                  : _searchQuery.isEmpty
                      ? Center(
                          child: Text(
                            '输入片名搜索',
                            style: TextStyle(color: theme.textMuted),
                          ),
                        )
                      : _searchResults.isEmpty
                          ? Center(
                              child: Text(
                                '在 Emby 里没有找到“$_searchQuery”',
                                style: TextStyle(color: theme.textMuted),
                              ),
                            )
                          : GridView.builder(
                              padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                crossAxisCount: 3,
                                mainAxisSpacing: 16,
                                crossAxisSpacing: 12,
                                childAspectRatio: 0.52,
                              ),
                              itemCount: _searchResults.length,
                              itemBuilder: (context, i) {
                                final item = _searchResults[i];
                                return EmbyPosterCard(
                                  item: item,
                                  imageHeaders: _client?.imageHeaders,
                                  isWatched:
                                      _watchedKeys.contains(item.identityKey),
                                  onTap: () => _openDetail(item),
                                );
                              },
                            ),
        ),
        if (_searchMode &&
            !_searching &&
            _searchError.isEmpty &&
            _searchQuery.isNotEmpty &&
            _searchResults.isNotEmpty &&
            _searchTotal > _searchResults.length)
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
            child: _LoadMoreRow(
              shown: _searchResults.length,
              total: _searchTotal,
              loading: _searchLoadingMore,
              onTap: _loadMoreSearch,
            ),
          ),
      ],
    );
  }
}

/// Section header — same values as the CMS home (_SectionHead in
/// video_tab_page.dart): 20px/800 + "查看全部 ›".
/// One 分类 chip (收藏 / a genre): pill, hairline border, accent
/// heart for 收藏. Taps open the matching category page.
class _CategoryChip extends StatelessWidget {
  const _CategoryChip({required this.label, this.icon, required this.onTap});

  final String label;
  final IconData? icon;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 7),
        decoration: BoxDecoration(
          color: theme.surfaceStrong,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: theme.hairline),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: [
            if (icon != null) ...[
              Icon(icon, size: 13, color: theme.accent),
              const SizedBox(width: 4),
            ],
            Text(
              label,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _SectionHead extends StatelessWidget {
  const _SectionHead({required this.title, this.onMore});

  final String title;
  final VoidCallback? onMore;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 28, 16, 10),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 20,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.02,
              height: 1.2,
            ),
          ),
          const Spacer(),
          if (onMore != null)
            GestureDetector(
              onTap: onMore,
              child: Text(
                '查看全部 ›',
                style: TextStyle(
                  color: theme.textMuted,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
        ],
      ),
    );
  }
}

/// Horizontal poster row — same geometry as the CMS home
/// (_PosterRow): 216 high, 112 wide cards.
class _PosterRow extends StatelessWidget {
  const _PosterRow({
    required this.items,
    required this.onTapItem,
    required this.watchedKeys,
    this.imageHeaders,
  });

  final List<VideoItem> items;
  final void Function(VideoItem item) onTapItem;
  final Set<String> watchedKeys;
  final Map<String, String>? imageHeaders;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 216,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: items.length,
        itemBuilder: (context, i) {
          final item = items[i];
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SizedBox(
              width: 112,
              child: EmbyPosterCard(
                item: item,
                imageHeaders: imageHeaders,
                isWatched: watchedKeys.contains(item.identityKey),
                onTap: () => onTapItem(item),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Poster card — VideoPosterCard's values, copied because that widget
/// takes no image headers and lives outside this group's files:
/// 2:3 poster, radius standard, title 13/600, meta 12, count badge
/// (dark pill, 11/600, top-right), watched ✓ (20px dark circle,
/// top-left), missing artwork = theme tile + ▶ glyph.
/// "Load more" footer under a paginated row (1.1.6): shows how
/// many are displayed out of the server total, so the 60-item
/// first page is never a silent truncation.
class _LoadMoreRow extends StatelessWidget {
  const _LoadMoreRow({
    required this.shown,
    required this.total,
    required this.loading,
    required this.onTap,
  });

  final int shown;
  final int total;
  final bool loading;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Center(
        child: loading
            ? const SizedBox(
                width: 20,
                height: 20,
                child: CupertinoActivityIndicator(),
              )
            : OutlinedButton(
                onPressed: onTap,
                child: Text('加载更多（已显示 $shown / 共 $total 部）'),
              ),
      ),
    );
  }
}

/// Server-resume card — same values as [_ContinueCard] (16:9
/// fanart, 248 wide, 6px progress bar, title 15/700, subtitle 13),
/// driven by a server [VideoItem] (UserData progress) instead of a
/// local history row. Episodes show their series name as the title
/// and the episode label below; movies show the title + watched %.
class _ResumeCard extends StatelessWidget {
  const _ResumeCard({
    required this.item,
    required this.onTap,
    this.imageHeaders,
  });

  final VideoItem item;
  final VoidCallback onTap;
  final Map<String, String>? imageHeaders;

  bool get _isEpisode => item.mediaType == 'Episode';

  String get _title =>
      _isEpisode && item.seriesName.isNotEmpty ? item.seriesName : item.name;

  String get _subtitle {
    final pct = (item.progressFraction * 100).round().clamp(0, 100);
    if (_isEpisode) {
      final ep = item.episodeIndex != null ? '第 ${item.episodeIndex} 集' : item.name;
      final season = item.seasonIndex != null && item.seasonIndex! > 1
          ? '第 ${item.seasonIndex} 季 · '
          : '';
      return '$season$ep · 已看 $pct%';
    }
    if (item.played) return '已看完';
    return '已看 $pct%';
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 248,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                decoration: BoxDecoration(
                  color: theme.surfaceStrong,
                  borderRadius: BorderRadius.circular(HaoRadius.large),
                  border: Border.all(color: theme.hairline),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    // 16:9 card, 16:9 art: the server's Backdrop
                    // when it has one — the 2:3 poster cropped
                    // into this frame looked flat and cut off.
                    if (item.backdrop.isNotEmpty || item.pic.isNotEmpty)
                      RefererImage(
                        url: item.backdrop.isNotEmpty
                            ? item.backdrop
                            : item.pic,
                        headers: imageHeaders,
                        fit: BoxFit.cover,
                        fallback: ColoredBox(
                          color: theme.surfaceStrong,
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        height: 6,
                        color: const Color(0x73000000),
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: item.serverProgressFraction,
                          child: Container(
                            height: 6,
                            color: theme.accent,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              _title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
            Text(
              _subtitle,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.textMuted,
                fontSize: 13,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Next-up episode card — same geometry as [EmbyPosterCard] (112
/// wide, 2:3 tile, title 13/600, meta 12). The tile is the
/// episode's own poster when the server has one, else the same
/// missing-artwork tile; the title is the series name and the meta
/// line is the episode label. No per-episode stills exist on the
/// server — the tile is never a repeated series poster passed off
/// as a still.
class _NextUpCard extends StatelessWidget {
  const _NextUpCard({
    required this.item,
    this.imageHeaders,
    required this.onTap,
  });

  final VideoItem item;
  final Map<String, String>? imageHeaders;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final title = item.seriesName.isNotEmpty ? item.seriesName : item.name;
    final ep = item.episodeIndex != null ? '第 ${item.episodeIndex} 集' : item.name;
    final season = item.seasonIndex != null && item.seasonIndex! > 1
        ? '第 ${item.seasonIndex} 季 · '
        : '';
    return GestureDetector(
      onTap: onTap,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          AspectRatio(
            aspectRatio: 2 / 3,
            child: Container(
              decoration: BoxDecoration(
                color: theme.surfaceStrong,
                borderRadius: BorderRadius.circular(HaoRadius.standard),
                border: Border.all(color: theme.hairline),
                boxShadow: [
                  BoxShadow(
                    color: Colors.black.withValues(alpha: 0.10),
                    blurRadius: 12,
                    offset: const Offset(0, 4),
                  ),
                ],
              ),
              clipBehavior: Clip.antiAlias,
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (item.pic.isNotEmpty)
                    RefererImage(
                      url: item.pic,
                      headers: imageHeaders,
                      fit: BoxFit.cover,
                      fallback: EmbyMissingArtwork(theme: theme),
                    )
                  else
                    EmbyMissingArtwork(theme: theme),
                ],
              ),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            title,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w600,
              height: 1.25,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            '$season$ep',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              color: theme.textMuted,
              fontSize: 12,
              height: 1.25,
            ),
          ),
        ],
      ),
    );
  }
}
/// (_ContinueCard in video_tab_page.dart): 16:9 fanart, 248 wide,
/// 6px progress bar, title 15/700, subtitle 13. Image goes through
/// RefererImage with the Emby header (the CMS card has none).
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({
    required this.entry,
    required this.onTap,
    this.imageHeaders,
  });

  final WatchHistoryEntry entry;
  final VoidCallback onTap;
  final Map<String, String>? imageHeaders;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 248,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 16 / 9,
              child: Container(
                decoration: BoxDecoration(
                  color: theme.surfaceStrong,
                  borderRadius: BorderRadius.circular(HaoRadius.large),
                  border: Border.all(color: theme.hairline),
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (entry.backdrop.isNotEmpty || entry.pic.isNotEmpty)
                      RefererImage(
                        url: entry.backdrop.isNotEmpty
                            ? entry.backdrop
                            : entry.pic,
                        headers: imageHeaders,
                        fit: BoxFit.cover,
                        fallback: ColoredBox(
                          color: theme.surfaceStrong,
                        ),
                      ),
                    Positioned(
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: Container(
                        height: 6,
                        color: const Color(0x73000000),
                        alignment: Alignment.centerLeft,
                        child: FractionallySizedBox(
                          widthFactor: entry.progressFraction,
                          child: Container(
                            height: 6,
                            color: theme.accent,
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              entry.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
            Text(
              [
                if (entry.epName.isNotEmpty) entry.epName,
                if (entry.remainingLabel.isNotEmpty)
                  entry.remainingLabel
                else if (entry.isFinished)
                  '已看完',
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.textMuted,
                fontSize: 13,
                height: 1.25,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
