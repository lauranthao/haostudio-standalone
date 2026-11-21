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
import 'package:flutter/material.dart';

import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import 'video_detail_page.dart';
import 'video_detail_service.dart';
import 'video_favs_page.dart';
import 'video_history_page.dart';
import 'video_history_store.dart';
import 'video_home_service.dart';
import 'video_models.dart';
import 'video_poster_card.dart';
import 'video_search_page.dart';
import 'video_type_page.dart';
import 'widgets/referer_image.dart';

class VideoTabPage extends StatefulWidget {
  const VideoTabPage({super.key});

  @override
  State<VideoTabPage> createState() => _VideoTabPageState();
}

/// No KeepAlive (P1-P3): initState renders from the Hive cache +
/// refreshes once in the background; no timers, streams or polling
/// that would keep running while hidden. The page rebuilds from the
/// Hive cache on every tab switch, so it never sits resident in
/// memory; scroll position is lost on switch, data is not.
class _VideoTabPageState extends State<VideoTabPage> {
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

  @override
  void initState() {
    super.initState();
    // (1) Immediate render from cache + local history — never a bare
    // spinner while data exists.
    _home = _homeService.loadCached();
    _history = VideoHistoryStore.getAll();
    _loading = _home == null && _history.isEmpty;
    // (2) Fresh data in the background.
    unawaited(_refreshHome());
    unawaited(_refreshDaily());
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
        _home = fresh;
        _loading = false;
        _failed = false;
        _stale = false;
      });
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
      _daily = daily;
      _dailyFailed = daily.isEmpty;
    });
  }

  void _openDetail(VideoItem item, {bool autoResume = false}) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailPage(
          sourceId: item.source,
          vodId: item.vodId,
          preload: item,
          autoResume: autoResume,
        ),
      ),
    );
  }

  void _openType(String name) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoTypePage(typeName: name),
      ),
    );
  }

  void _openSearch() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const VideoSearchPage(),
      ),
    );
  }

  void _openFavs() {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => const VideoFavsPage(),
      ),
    );
  }

  void _openHistory() {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => const VideoHistoryPage(),
          ),
        )
        .then((_) {
          // History may have been cleared or advanced while away.
          if (mounted) {
            setState(() => _history = VideoHistoryStore.getAll());
          }
        });
  }

  Set<String> get _watchedKeys => _history
      .where((e) => e.isFinished)
      .map((e) => e.identityKey)
      .toSet();

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
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
        child: _loading
            ? const Center(child: CircularProgressIndicator())
            : _failed
                ? _HomeError(onRetry: () {
                    setState(() => _loading = true);
                    unawaited(_refreshHome(force: true));
                  })
                : RefreshIndicator(
                    onRefresh: () async {
                      await Future.wait([
                        _refreshHome(force: true),
                        _refreshDaily(),
                      ]);
                    },
                    child: CustomScrollView(
                      slivers: [
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
                                                color: theme.textMuted,
                                                size: 20,
                                              ),
                                              const SizedBox(width: 8),
                                              Text(
                                                '搜索影片、剧集…',
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
                                    const SizedBox(width: 10),
                                    GlassCard(
                                      radius: 999,
                                      padding: EdgeInsets.zero,
                                      shadow: GlassShadow.card,
                                      quality: GlassCardQuality.standard,
                                      child: IconButton(
                                        icon: Icon(
                                          Icons.history,
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
                                  items: _daily,
                                  watchedKeys: _watchedKeys,
                                  onTapItem: _openDetail,
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
                                    style:
                                        TextStyle(color: theme.textMuted),
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
                                    items: row.items,
                                    watchedKeys: _watchedKeys,
                                    onTapItem: _openDetail,
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
                    ),
                  ),
      ),
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

/// Horizontal poster row (posters 2:3, ~112px wide).
class _PosterRow extends StatelessWidget {
  const _PosterRow({
    required this.items,
    required this.onTapItem,
    required this.onPrefetch,
    this.watchedKeys = const {},
  });

  final List<VideoItem> items;
  final void Function(VideoItem item) onTapItem;
  final void Function(VideoItem item) onPrefetch;
  final Set<String> watchedKeys;

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
              child: VideoPosterCard(
                item: item,
                isWatched: watchedKeys.contains(item.identityKey),
                onTap: () => onTapItem(item),
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
                color: theme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            Text(
              '${row.count} 部',
              style: TextStyle(color: theme.textMuted, fontSize: 12),
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
            Icon(Icons.cloud_off, size: 48, color: theme.textMuted),
            const SizedBox(height: 16),
            Text(
              '影视首页加载失败',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '视频源暂时无法访问，请检查网络后重试',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textMuted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
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
