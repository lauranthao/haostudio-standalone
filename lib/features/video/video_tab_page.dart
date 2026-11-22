// Video home (fix 13 + Infuse home H1–H9).
//
// - Never a bare spinner while data exists: on entry, paint the shell
//   + cached home + Continue Watching history IMMEDIATELY, then fetch
//   fresh data in the background and re-render when it lands.
// - Per-source discipline: up to 12 categories in parallel, each raced
//   against its own 8 s timeout (a slow category yields nothing, it
//   does not block the others); overall 12 s first-result window +
//   5 s grace for a late result.
// - If the fresh fetch fails/times out and cached data was shown, keep
//   the cached data and mark it stale ("内容可能不是最新"); if nothing
//   was cached, show the error/empty state.
// - Continue Watching history is read locally and never delays the
//   render. Daily recommendations load independently in the background.
// - NO Douban enrichment before first paint. No totals strip (Infuse
//   H7 — library size is not home-screen content). No "在线影视" page
//   title (Infuse H2): a search pill + favourites button instead.
// - Row order: My Media collections (poster-style, first) →
//   Continue Watching → Daily Picks → category rows. No TMDB
//   Trending — TMDB is OUT of the standalone.
// - Poster cards prefetch the detail on pointer-down (max 3 inflight).

import '../../core/theme/hao_radius.dart';
import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/player/vod_features.dart';
import '../../core/storage/hive_store.dart';
import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../services/video/emby_client.dart';
import '../../services/video/emby_models.dart';
import '../../services/video/poster_patch_service.dart';
import 'emby_tab_page.dart';
import 'video_detail_router.dart';
import '../../widgets/hao_segmented_control.dart';
import 'video_detail_service.dart';
import 'video_favs_page.dart';
import 'video_history_page.dart';
import 'video_history_store.dart';
import 'video_home_service.dart';
import 'video_models.dart';
import 'video_poster_card.dart';
import 'video_search_page.dart';
import 'video_smart_groups.dart';
import 'video_type_page.dart';
import 'video_version_sheet.dart';
import 'widgets/referer_image.dart';

/// Split an aggregated history list into the two bars (pure, tested).
/// "在看" = unfinished rows; "下一集" = rows whose current episode is
/// FINISHED and whose next episode is KNOWN. The two bars never show
/// the same work twice: while an episode is still unfinished the row
/// stays in "在看" only — b29 (chen: the same film in both bars at
/// once, e.g. 《空枪》 in 继续观看 and 下一集, reads as a duplicate).
/// A finished movie / last-episode row never enters "下一集" (old
/// rows without `nextEpName` stay out until re-recorded; a stale
/// next-episode name that is only a dub/version tag stays out too).
/// One work = one bar: a finished row of a film already in "在看"
/// (same title + year, or same source + vodId when untitled) stays
/// out of "下一集" — different languages / lines of one film are the
/// same work.
({List<WatchHistoryEntry> watching, List<WatchHistoryEntry> nextUp})
    splitContinueWatching(List<WatchHistoryEntry> all) {
  final watching = all.where((e) => !e.isFinished).toList();
  final watchingWorks = <String>{for (final e in watching) _splitWorkKey(e)};
  return (
    watching: watching,
    nextUp: all
        .where((e) =>
            e.hasNextEpisode &&
            e.isFinished &&
            !isVersionEpisodeName(e.nextEpName) &&
            !watchingWorks.contains(_splitWorkKey(e)))
        .toList(),
  );
}

/// Work identity for the two-bar split: the film key when the row
/// has one, else the exact source + vodId (same rule as the store's
/// film dedup, minus the legacy year-less merge).
String _splitWorkKey(WatchHistoryEntry e) {
  final film = VideoHistoryStore.filmKey(e);
  return film.isEmpty ? e.identityKey : film;
}

/// Bumps whenever any video detail/history navigation returns, so the
/// aggregated bar above the segments re-reads the store. Same-file
/// only (the bar and the CMS home live in this file).
final _continueRefresh = ValueNotifier<int>(0);

void _bumpContinueRefresh() => _continueRefresh.value++;

class VideoTabPage extends StatefulWidget {
  const VideoTabPage({super.key});

  @override
  State<VideoTabPage> createState() => _VideoTabPageState();
}

/// Mode holder only: the HaoSegmentedControl (影视源 / Emby) + the
/// persisted selection. Each branch is its own page with its own
/// State / Client / CancelToken; switching unmounts the other page
/// (no IndexedStack), so the switch cancels the outgoing page's
/// in-flight requests via its dispose(). The switch control lives
/// only on this tab root page — never on pushed detail/search pages.
class _VideoTabPageState extends State<VideoTabPage> {
  VideoTabMode _mode = VideoTabMode.cms;

  @override
  void initState() {
    super.initState();
    // Dirty / missing value reads back as 'cms'
    // (VideoTabMode.fromString); an uninitialised Hive box throws
    // and is caught too.
    try {
      _mode = VideoTabMode.fromString(
        HiveStore.getString(HiveKeys.videoTabMode, 'cms'),
      );
    } catch (_) {
      _mode = VideoTabMode.cms;
    }
  }

  void _onModeChanged(VideoTabMode mode) {
    if (mode == _mode) return;
    setState(() => _mode = mode);
    // Fire-and-forget, never blocks the switch or errors into UI.
    try {
      unawaited(HiveStore.put(HiveKeys.videoTabMode, mode.code));
    } catch (_) {}
  }

  @override
  Widget build(BuildContext context) {
    // G-P2-5: no explicit backgroundColor — the Scaffold falls back
    // to ThemeData.scaffoldBackgroundColor (transparent while the
    // wallpaper is on), so the two background mechanisms cannot drift.
    // No Obx either: the deleted backgroundColor line was this
    // builder's ONLY GetX observable read (tabScaffoldBackground
    // reads AppearanceController.backgroundActive); without it GetX
    // throws "improper use of GetX" and the page never renders.
    // The body already rebuilds via ListenableBuilder / setState /
    // InheritedWidget, so nothing here needs an Obx.
    return Scaffold(
      // Full-bleed, no card wrapper (Infuse H1): the artwork IS the UI.
      body: SafeArea(
        child: Column(
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              child: HaoSegmentedControl<VideoTabMode>(
                segments: const [
                  HaoSegment(value: VideoTabMode.cms, label: '影视源'),
                  HaoSegment(value: VideoTabMode.emby, label: 'Emby'),
                ],
                value: _mode,
                onChanged: _onModeChanged,
              ),
            ),
            // Aggregated continue-watching (1.1.6, browse A3 §4): one
            // cross-source bar above the CMS/Emby segments. It reads
            // the shared store unfiltered — the per-source bars inside
            // each page stay as they are.
            const AggregatedContinueBar(),
            Expanded(
              child: _mode == VideoTabMode.cms
                  ? const _CmsHomePage()
                  : const EmbyTabPage(),
            ),
          ],
        ),
      ),
    );
  }
}

/// The existing CMS home, moved down unchanged (a move, not a
/// rewrite) — same service, tokens, cache, error states. One
/// deliberate change: Continue Watching shows CMS rows only; Emby
/// rows live on the Emby page (shared store, per-source filter).
class _CmsHomePage extends StatefulWidget {
  const _CmsHomePage();

  @override
  State<_CmsHomePage> createState() => _CmsHomePageState();
}

/// No KeepAlive (P1-P3): initState renders from the Hive cache +
/// refreshes once in the background; no timers, streams or polling
/// that would keep running while hidden. The page rebuilds from the
/// Hive cache on every tab switch, so it never sits resident in
/// memory; scroll position is lost on switch, data is not.
class _CmsHomePageState extends State<_CmsHomePage> {
  final _homeService = VideoHomeService();
  final _detailService = VideoDetailService();

  VideoHomeData? _home;
  List<VideoItem> _daily = [];
  List<WatchHistoryEntry> _history = [];
  bool _loading = true;
  bool _failed = false;
  bool _stale = false;
  bool _dailyFailed = false;

  /// Cancels the in-flight home/daily fetches when the tab is left
  /// or a refresh supersedes them (V-P1-4). Separate tokens: a home
  /// refresh must never cancel an in-flight daily load, or vice versa.
  CancelToken? _homeToken;
  CancelToken? _dailyToken;

  /// Poster patch (1.1.6, browse A3 §2): cached URLs are applied to
  /// fetched rows at render; poster-less cards are looked up lazily,
  /// once per title (see [_patchAttempted]).
  final _posterPatch = PosterPatchService();
  final _patchAttempted = <String>{};

  /// Apply cached poster patches to a cached/fresh home payload.
  /// I-影视 item 10: the user's category prefs (hide/reorder) are
  /// applied here, so every render — cached or fresh — honours
  /// them, and "我的媒体" (rows.take(5)) follows the same order.
  VideoHomeData _patchedHome(VideoHomeData data) => VideoHomeData(
        rows: applyCategoryPrefs(
          data.rows
              .map(
                (row) => VideoHomeRow(
                  name: row.name,
                  count: row.count,
                  items: _posterPatch.withCachedPatches(row.items),
                ),
              )
              .toList(),
          readCategoryPrefs(),
        ),
        fetchedAt: data.fetchedAt,
      );

  /// Lazy lookup for poster-less wall cards (1.1.6): one attempt per
  /// title, in the background, never on first paint. A success only
  /// triggers a rebuild — the render path re-applies the cached URL.
  void _patchMissing() {
    final items = <VideoItem>[
      ..._daily,
      for (final row in _home?.rows ?? const <VideoHomeRow>[])
        ...row.items,
    ];
    for (final item in items) {
      if (item.pic.isNotEmpty) continue;
      final key = PosterPatchService.patchKey(item.name, item.year);
      if (key.isEmpty || !_patchAttempted.add(key)) continue;
      unawaited(_posterPatch.patchFor(item.name, item.year).then((url) {
        if (url != null && mounted) setState(() {});
      }));
    }
  }

  @override
  void initState() {
    super.initState();
    // (1) Immediate render from cache + local history — never a bare
    // spinner while data exists. CMS rows only: Emby rows are shown
    // on the Emby page (shared store, per-source filter).
    final cachedHome = _homeService.loadCached();
    _home = cachedHome == null ? null : _patchedHome(cachedHome);
    _history = VideoHistoryStore.getAll()
        .where((e) => e.sourceKey != EmbyClient.sourceId)
        .toList();
    _loading = _home == null && _history.isEmpty;
    // (2) Fresh data in the background.
    unawaited(_refreshHome());
    unawaited(_refreshDaily());
    _patchMissing();
  }

  @override
  void dispose() {
    _homeToken?.cancel();
    _dailyToken?.cancel();
    super.dispose();
  }

  Future<void> _refreshHome({bool force = false}) async {
    // G-P1-1: a fresh Hive cache means this tab was just rebuilt
    // after a switch — fetchFresh serves it with no network. A
    // forced refresh (pull-to-refresh / error retry) bypasses it.
    _homeToken?.cancel();
    final token = _homeToken = CancelToken();
    final fresh = await _homeService.fetchFresh(
      force: force,
      cancelToken: token,
    );
    if (!mounted) return;
    if (fresh != null) {
      setState(() {
        _home = _patchedHome(fresh);
        _loading = false;
        _failed = false;
        _stale = false;
      });
      _patchMissing();
    } else {
      // Fresh fetch failed/timed out: keep cached data + stale flag,
      // or the error state when nothing was cached.
      setState(() {
        _loading = false;
        if (_home != null) {
          _stale = true;
        } else {
          _failed = true;
        }
      });
    }
  }

  Future<void> _refreshDaily() async {
    _dailyToken?.cancel();
    final token = _dailyToken = CancelToken();
    final daily = await _homeService.fetchDaily(
      cancelToken: token,
    );
    if (!mounted) return;
    setState(() {
      _daily = _posterPatch.withCachedPatches(daily);
      _dailyFailed = daily.isEmpty;
    });
    _patchMissing();
  }

  void _openDetail(VideoItem item, {bool autoResume = false}) {
    // 1.1.6: shared routing (audit P0) — the third call site
    // (history page + favourites page are the other two). Emby rows
    // can reach this page through the aggregated bar's cards.
    openVideoDetail<void>(
      context,
      source: item.source,
      vodId: item.vodId,
      preload: item,
      autoResume: autoResume,
    ).then((_) {
      if (mounted) {
        setState(() => _history = VideoHistoryStore.getAll()
            .where((e) => e.sourceKey != EmbyClient.sourceId)
            .toList());
      }
      _bumpContinueRefresh();
    });
  }

  void _openType(String name) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => VideoTypePage(typeName: name),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => const VideoSearchPage(),
      ),
    );
  }

  void _openFavs() {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => const VideoFavsPage(),
      ),
    );
  }

  void _openHistory() {
    Navigator.of(context)
        .push(
          CupertinoPageRoute<void>(
            builder: (_) => const VideoHistoryPage(),
          ),
        )
        .then((_) {
          // History may have been cleared or advanced while away.
          // CMS rows only (see initState).
          if (mounted) {
            setState(() => _history = VideoHistoryStore.getAll()
                .where((e) => e.sourceKey != EmbyClient.sourceId)
                .toList());
          }
          _bumpContinueRefresh();
        });
  }

  Set<String> get _watchedKeys => _history
      .where((e) => e.isFinished)
      .map((e) => e.identityKey)
      .toSet();

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    // No Scaffold/SafeArea here — VideoTabPage owns both (the
    // G-P2-5 note lives on its build now). Full-bleed, no card
    // wrapper (Infuse H1): the artwork IS the UI.
    return _loading
            ? const Center(child: CupertinoActivityIndicator())
            : _failed
                ? _HomeError(onRetry: () {
                    setState(() => _loading = true);
                    unawaited(_refreshHome(force: true));
                  })
                : CustomScrollView(
                    slivers: [
                      CupertinoSliverRefreshControl(
                        onRefresh: () async {
                          await Future.wait([
                            _refreshHome(force: true),
                            _refreshDaily(),
                          ]);
                        },
                      ),
                        SliverToBoxAdapter(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              // Search pill + favourites (Infuse H2).
                              Padding(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  12,
                                  14,
                                  4,
                                ),
                                child: Row(
                                  children: [
                                    Expanded(
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
                                                Icons.search,
                                                shadows: HaoTheme.legibilityShadows(context),
                                                color: theme.textMuted,
                                                size: 20,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                '搜索影片、剧集…',
                                                style: TextStyle(
                                                  shadows: HaoTheme.legibilityShadows(context),
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
                                    const SizedBox(width: 10),
                                    GlassCard(
                                      radius: 999,
                                      padding: EdgeInsets.zero,
                                      shadow: GlassShadow.card,
                                      quality: GlassCardQuality.standard,
                                      child: IconButton(
                                        icon: Icon(
                                          Icons.history,
                                          shadows: HaoTheme.legibilityShadows(context),
                                          color: theme.textPrimary,
                                        ),
                                        tooltip: '历史记录',
                                        onPressed: () {
                                          HaoHaptics.tap();
                                          _openHistory();
                                        },
                                      ),
                                    ),
                                    const SizedBox(width: 10),
                                    GlassCard(
                                      radius: 999,
                                      padding: EdgeInsets.zero,
                                      shadow: GlassShadow.card,
                                      quality: GlassCardQuality.standard,
                                      child: IconButton(
                                        icon: Icon(
                                          Icons.favorite_border,
                                          shadows: HaoTheme.legibilityShadows(context),
                                          color: theme.textPrimary,
                                        ),
                                        tooltip: '我的收藏',
                                        onPressed: () {
                                          HaoHaptics.tap();
                                          _openFavs();
                                        },
                                      ),
                                    ),
                                  ],
                                ),
                              ),
                              if (_stale)
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    0,
                                  ),
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
                                          Icons.info_outline,
                                          shadows: HaoTheme.legibilityShadows(context),
                                          color: theme.accent,
                                          size: 16,
                                        ),
                                        const SizedBox(width: 8),
                                        Text(
                                          '内容可能不是最新',
                                          style: TextStyle(
                                            shadows: HaoTheme.legibilityShadows(context),
                                            color: theme.textSecondary,
                                            fontSize: 13,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ],
                                    ),
                                  ),
                                ),
                              // My Media first (user request), poster-style (H6/H8).
                              if (_home != null &&
                                  _home!.collections.isNotEmpty) ...[
                                _SectionHead(
                                  title: '我的媒体',
                                  onMore: null,
                                ),
                                SizedBox(
                                  height: 212,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    itemCount: _home!.collections.length,
                                    itemBuilder: (context, i) {
                                      final row =
                                          _home!.collections[i];
                                      return Padding(
                                        padding:
                                            const EdgeInsets.only(right: 12),
                                        child: _CollectionCard(
                                          row: row,
                                          onTap: () =>
                                              _openType(row.name),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                              // Continue Watching first (Infuse H5).
                              if (_history.isNotEmpty) ...[
                                _SectionHead(
                                  title: '继续观看',
                                  onMore: _openHistory,
                                ),
                                // 2026-11-17 (v1.0.6 phone bug: 第21集被切掉一半):
                                // card content is 16:9 poster 139.5 +
                                // 6 gap + title ~19 + subtitle ~17 =
                                // ~182 — the old 172 container clipped
                                // the subtitle's bottom half. Same bug
                                // class as the v1.0.5 _CollectionCard
                                // fix (196 -> 212).
                                SizedBox(
                                  height: 186,
                                  child: ListView.builder(
                                    scrollDirection: Axis.horizontal,
                                    padding: const EdgeInsets.symmetric(
                                      horizontal: 16,
                                    ),
                                    itemCount: _history.length,
                                    itemBuilder: (context, i) {
                                      final h = _history[i];
                                      return Padding(
                                        padding:
                                            const EdgeInsets.only(right: 12),
                                        child: _ContinueCard(
                                          entry: h,
                                          onTap: () => _openDetail(
                                            VideoItem(
                                              source: h.source,
                                              sourceName: '',
                                              vodId: h.vodId,
                                              name: h.title,
                                              pic: h.pic,
                                              picAlt: h.picAlt,
                                            ),
                                            // Same "continue watching"
                                            // action as the history
                                            // page: resume at the saved
                                            // position, no extra tap.
                                            autoResume: true,
                                          ),
                                        ),
                                      );
                                    },
                                  ),
                                ),
                              ],
                              // Daily Picks (background load).
                              if (_daily.isNotEmpty) ...[
                                _SectionHead(
                                  title: '每日推荐',
                                  onMore: null,
                                ),
                                _PosterRow(
                                  groups: groupVideoItems(
                                    _posterPatch.withCachedPatches(_daily),
                                  ),
                                  watchedKeys: _watchedKeys,
                                  onTapGroup: (group) => unawaited(
                                    openGroupedVideo(
                                      context,
                                      group,
                                      detailService: _detailService,
                                    ),
                                  ),
                                  onPrefetch: (item) =>
                                      _detailService.prefetch(
                                    item.source,
                                    item.vodId,
                                  ),
                                ),
                              ] else if (_dailyFailed) ...[
                                _SectionHead(
                                  title: '每日推荐',
                                  onMore: null,
                                ),
                                Padding(
                                  padding: const EdgeInsets.fromLTRB(
                                    16,
                                    8,
                                    16,
                                    0,
                                  ),
                                  child: Text(
                                    '每日推荐暂不可用',
                                    style: TextStyle(
                                      shadows: HaoTheme.legibilityShadows(context),
                                      color: theme.textMuted,
                                    ),
                                  ),
                                ),
                              ],
                              // Category rows.
                              if (_home != null)
                                for (final row in _home!.rows) ...[
                                  _SectionHead(
                                    title: row.name,
                                    count: row.count,
                                    onMore: () => _openType(row.name),
                                  ),
                                  _PosterRow(
                                    groups: groupVideoItems(
                                      _posterPatch.withCachedPatches(
                                        row.items,
                                      ),
                                    ),
                                    watchedKeys: _watchedKeys,
                                    onTapGroup: (group) => unawaited(
                                      openGroupedVideo(
                                        context,
                                        group,
                                        detailService: _detailService,
                                      ),
                                    ),
                                    onPrefetch: (item) =>
                                        _detailService.prefetch(
                                      item.source,
                                      item.vodId,
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
}

/// Section header: 20px/800 + "count ›" See All (Infuse H3).
class _SectionHead extends StatelessWidget {
  const _SectionHead({
    required this.title,
    this.count,
    this.onMore,
  });

  final String title;
  final int? count;
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
              shadows: HaoTheme.legibilityShadows(context),
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
                count != null ? '$count ›' : '查看全部 ›',
                style: TextStyle(
                  shadows: HaoTheme.legibilityShadows(context),
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

/// Horizontal poster row (posters 2:3, ~112px wide). Grouped: one
/// card per film (Smart Groups); the representative is shown and the
/// tap opens the group (sheet when multi-version, detail when single).
class _PosterRow extends StatelessWidget {
  const _PosterRow({
    required this.groups,
    required this.onTapGroup,
    required this.onPrefetch,
    this.watchedKeys = const {},
  });

  final List<GroupedVideoItem> groups;
  final void Function(GroupedVideoItem group) onTapGroup;
  final void Function(VideoItem item) onPrefetch;
  final Set<String> watchedKeys;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: 216,
      child: ListView.builder(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 16),
        itemCount: groups.length,
        itemBuilder: (context, i) {
          final group = groups[i];
          final item = group.representative;
          return Padding(
            padding: const EdgeInsets.only(right: 12),
            child: SizedBox(
              width: 112,
              child: VideoPosterCard(
                item: item,
                // Watched when ANY version was watched: the group is
                // one film, the watched source may not be the
                // representative.
                isWatched: group.versions.any(
                  (v) => watchedKeys.contains(v.identityKey),
                ),
                onTap: () => onTapGroup(group),
                onPointerDown: () => onPrefetch(item),
              ),
            ),
          );
        },
      ),
    );
  }
}

/// Continue Watching card: 16:9 fanart + 6px progress overlay +
/// "还剩 X 分钟" meta (Infuse H5).
class _ContinueCard extends StatelessWidget {
  const _ContinueCard({required this.entry, required this.onTap});

  final WatchHistoryEntry entry;
  final VoidCallback onTap;

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
                  // Missing-artwork tile: theme glass (the old
                  // hardcoded 0xFF1C1C1E was a black hole in light
                  // modes). The progress scrim below stays black —
                  // it sits ON the artwork.
                  color: theme.surfaceStrong,
                  borderRadius: BorderRadius.circular(HaoRadius.large),
                  border: Border.all(color: theme.hairline),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (entry.pic.isNotEmpty)
                      RefererImage(
                        url: entry.pic,
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
                shadows: HaoTheme.legibilityShadows(context),
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
                shadows: HaoTheme.legibilityShadows(context),
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

/// Collection card (Infuse H6): fanned stack of 3 mini posters +
/// collection name + count, same geometry as a poster card.
class _CollectionCard extends StatelessWidget {
  const _CollectionCard({required this.row, required this.onTap});

  final VideoHomeRow row;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final pics = row.items.take(3).map((e) => e.pic).toList();
    return GestureDetector(
      onTap: onTap,
      child: SizedBox(
        width: 112,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              height: 168,
              child: Stack(
                children: [
                  for (var i = 0; i < pics.length; i++)
                    Positioned(
                      left: i * 14.0,
                      top: i * 4.0,
                      child: Transform.rotate(
                        angle: (i - 1) * 0.07,
                        child: Container(
                          width: 84,
                          height: 126,
                          decoration: BoxDecoration(
                            // Theme glass, not a hardcoded dark tile
                            // (black hole in light modes).
                            color: theme.surfaceStrong,
                            borderRadius: BorderRadius.circular(HaoRadius.standard),
                            border: Border.all(
                              color: theme.hairline,
                            ),
                          ),
                          clipBehavior: Clip.antiAlias,
                          child: pics[i].isNotEmpty
                              ? RefererImage(
                                  url: pics[i],
                                  fit: BoxFit.cover,
                                  fallback: const SizedBox.shrink(),
                                )
                              : const SizedBox.shrink(),
                        ),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 6),
            Text(
              row.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${row.count} 部',
              style: TextStyle(
                shadows: HaoTheme.legibilityShadows(context),
                color: theme.textMuted,
                fontSize: 12,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Aggregated continue-watching (1.1.6, browse A3 §4): ONE bar across
/// CMS + Emby, above the source segments (it is cross-source, so it
/// belongs above the segment switch, not inside either page). The
/// per-source bars inside the CMS/Emby pages stay as they are.
///
/// Two separate rows, never one mixed row: "在看" (unfinished, tap =
/// resume this episode) and "下一集" (current episode FINISHED and
/// next episode known, tap = open the detail page at the next
/// episode from 0 — the current episode's position is never carried
/// over). One work appears in at most one row (b29): while an
/// episode is unfinished its row stays in "在看" only, so the same
/// poster never shows in both rows at once. A finished row never
/// enters "在看"; a movie / last-episode row never enters "下一集"
/// (old rows without `nextEpName` stay out until re-recorded).
/// Reads the store on every build + on [_continueRefresh], so a
/// return from any detail/history navigation re-reads it.
class AggregatedContinueBar extends StatefulWidget {
  const AggregatedContinueBar({super.key, this.onOpen});

  /// Test seam: replaces navigation when provided (the real path
  /// routes through `openHistoryDetail`).
  final Future<void> Function(
    WatchHistoryEntry entry, {
    String? startEpName,
  })? onOpen;

  @override
  State<AggregatedContinueBar> createState() =>
      _AggregatedContinueBarState();
}

class _AggregatedContinueBarState extends State<AggregatedContinueBar> {
  Future<void> _open(WatchHistoryEntry entry, {String? startEpName}) async {
    final open = widget.onOpen;
    if (open != null) {
      await open(entry, startEpName: startEpName);
    } else if (startEpName != null) {
      await openHistoryDetail<void>(
        context,
        entry,
        autoResume: false,
        startEpName: startEpName,
      );
    } else {
      await openHistoryDetail<void>(context, entry);
    }
    if (mounted) setState(() {});
    _bumpContinueRefresh();
  }

  void _openHistoryPage() {
    Navigator.of(context)
        .push(
          CupertinoPageRoute<void>(
            builder: (_) => const VideoHistoryPage(),
          ),
        )
        .then((_) => _bumpContinueRefresh());
  }

  @override
  Widget build(BuildContext context) {
    return ValueListenableBuilder<int>(
      valueListenable: _continueRefresh,
      builder: (context, _, _) {
        final split = splitContinueWatching(VideoHistoryStore.getAll());
        if (split.watching.isEmpty && split.nextUp.isEmpty) {
          return const SizedBox.shrink();
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            if (split.watching.isNotEmpty) ...[
              _SectionHead(
                title: '继续观看',
                onMore: _openHistoryPage,
              ),
              SizedBox(
                height: 186,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: split.watching.length,
                  itemBuilder: (context, i) {
                    final h = split.watching[i];
                    return Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _ContinueCard(
                        entry: h,
                        onTap: () => _open(h),
                      ),
                    );
                  },
                ),
              ),
            ],
            if (split.nextUp.isNotEmpty) ...[
              _SectionHead(
                title: '下一集',
                onMore: null,
              ),
              SizedBox(
                height: 186,
                child: ListView.builder(
                  scrollDirection: Axis.horizontal,
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  itemCount: split.nextUp.length,
                  itemBuilder: (context, i) {
                    final h = split.nextUp[i];
                    return Padding(
                      padding: const EdgeInsets.only(right: 12),
                      child: _NextCard(
                        entry: h,
                        onTap: () => _open(h, startEpName: h.nextEpName),
                      ),
                    );
                  },
                ),
              ),
            ],
          ],
        );
      },
    );
  }
}

/// Next-episode card: same 16:9 geometry as [_ContinueCard], but the
/// subtitle names the NEXT episode ("下一集 · 第 8 集") instead of the
/// remaining time of the current one.
class _NextCard extends StatelessWidget {
  const _NextCard({required this.entry, required this.onTap});

  final WatchHistoryEntry entry;
  final VoidCallback onTap;

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
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (entry.pic.isNotEmpty)
                      RefererImage(
                        url: entry.pic,
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
                shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 15,
                fontWeight: FontWeight.w700,
                height: 1.25,
              ),
            ),
            Text(
              '下一集 · ${entry.nextEpName}',
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                shadows: HaoTheme.legibilityShadows(context),
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

class _HomeError extends StatelessWidget {
  const _HomeError({required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(
              Icons.cloud_off,
              shadows: HaoTheme.legibilityShadows(context),
              size: 48,
              color: theme.textMuted,
            ),
            const SizedBox(height: 16),
            Text(
              '影视首页加载失败',
              style: TextStyle(
                shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '视频源暂时无法访问，请检查网络后重试',
              textAlign: TextAlign.center,
              style: TextStyle(
                shadows: HaoTheme.legibilityShadows(context),
                color: theme.textMuted,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh, shadows: HaoTheme.legibilityShadows(context),),
              label: const Text('重试'),
              style: FilledButton.styleFrom(
                backgroundColor: theme.accent,
                // onPrimary (theme-defined per mode), NOT hardcoded
                // white: white on the light-gold / light-teal /
                // light-blue dark-mode accents is unreadable.
                foregroundColor:
                    Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
