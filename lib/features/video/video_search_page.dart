// Video search page — per-source race, infinite scroll.
//
// - Every search fans out to all enabled CMS sources (3 workers,
//   5 s per source, 6 s cap, sequential fallback — see CmsClient).
// - Infinite scroll: first 20 shown, 20 more appended when the user
//   scrolls to the sentinel at the bottom; when exhausted show
//   "已加载全部". There is no next-page button. The accumulated list
//   comes from CMS pages (pg=1, 2, … up to 5), deduped + ranked per
//   page, so later pages never repeat earlier items.
// - A new query cancels the previous search (generation guard) so
//   stale results cannot overwrite the new query.
// - Search history chips + hot chips (daily names, with a static
//   fallback list when daily is unavailable).

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import '../../widgets/hao_pressable.dart';
import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../core/theme/glass.dart';
import '../../services/video/cms_client.dart';
import '../../services/video/poster_patch_service.dart';
import 'video_detail_service.dart';
import 'video_history_store.dart';
import 'video_models.dart';
import 'video_poster_card.dart';
import 'video_smart_groups.dart';
import 'video_title_helpers.dart';
import '../../widgets/hao_search_field.dart';
import 'video_version_sheet.dart';
import '../../widgets/hao_nav_bar.dart';

class VideoSearchPage extends StatefulWidget {
  const VideoSearchPage({super.key});

  @override
  State<VideoSearchPage> createState() => _VideoSearchPageState();
}

/// Max chips shown in one chip section (history / hot) — was a bare
/// `.take(8)` in two places (G-P2-1).
const int kMaxSearchChips = 8;

class _VideoSearchPageState extends State<VideoSearchPage> {
  final _cms = CmsClient();
  final _detailService = VideoDetailService();
  final _posterPatch = PosterPatchService();
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

  /// The in-flight search's token (V-P1-4): a new query — or leaving
  /// the page — cancels the previous search instead of letting it
  /// run to its 55 s timeout. A cancellation is never a source
  /// failure; the generation guard already drops stale results.
  CancelToken? _searchToken;

  List<VideoItem> _results = [];
  final Set<String> _seenKeys = {};
  bool _searching = false;
  bool _searched = false;
  bool _failed = false;
  bool _loadingMore = false;
  bool _exhausted = false;
  int _page = 1;
  int _searchSeq = 0;
  String _query = '';
  List<String> _hotNames = const [];

  static const int _maxPages = 5;
  static const List<String> _fallbackHot = [
    '繁花',
    '庆余年',
    '哪吒',
    '流浪地球',
    '甄嬛传',
    '狂飙',
    '长津湖',
    '三体',
  ];

  @override
  void initState() {
    super.initState();
    // G-P2-1: the search box used to setState() the WHOLE page on
    // every keystroke. The input area below is wrapped in a
    // ValueListenableBuilder on the controller instead, so only the
    // input rebuilds while typing; the results/chips below it do not.
    _scrollController.addListener(_onScroll);
    unawaited(_loadHot());
  }

  Future<void> _loadHot() async {
    try {
      final daily = await _cms.daily().timeout(
        const Duration(seconds: 10),
        onTimeout: () => <VideoItem>[],
      );
      if (!mounted) return;
      setState(() {
        _hotNames = daily
            .map((e) => e.name)
            .where((n) => n.isNotEmpty)
            .take(kMaxSearchChips)
            .toList();
      });
    } catch (_) {}
  }

  void _onScroll() {
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 400) {
      unawaited(_loadMore());
    }
  }

  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final seq = ++_searchSeq;
    // A new query cancels the previous search's requests (V-P1-4).
    _searchToken?.cancel();
    final token = _searchToken = CancelToken();
    setState(() {
      _query = q;
      _searching = true;
      _searched = true;
      _failed = false;
      _results = [];
      _seenKeys.clear();
      _page = 1;
      _exhausted = false;
    });
    await VideoHistoryStore.saveSearchQuery(q);
    List<VideoItem> pageItems;
    try {
      pageItems = await _cms
          .search(q, page: 1, cancelToken: token)
          .timeout(
            const Duration(seconds: 55),
            onTimeout: () => throw TimeoutException('search timeout'),
          );
    } catch (_) {
      if (seq != _searchSeq || !mounted) return;
      setState(() {
        _searching = false;
        _failed = true;
      });
      return;
    }
    if (seq != _searchSeq || !mounted) return;
    setState(() {
      _searching = false;
      _results = pageItems;
      for (final item in pageItems) {
        // Same normalised key as CmsClient.dedupeAndRankSearch —
        // a raw name|year key lets the same title reappear on a later
        // page with a different suffix / spacing (e.g. "庆余年(高清)").
        _seenKeys.add('${videoNormTitle(item.name)}|${item.year}');
      }
      if (pageItems.isEmpty) _exhausted = true;
    });
  }

  Future<void> _loadMore() async {
    if (_loadingMore || _exhausted || !_searched || _searching) return;
    if (_page >= _maxPages) {
      setState(() => _exhausted = true);
      return;
    }
    final seq = _searchSeq;
    setState(() => _loadingMore = true);
    List<VideoItem> pageItems;
    try {
      // G-P2-1: the first search has an explicit 55 s timeout; the
      // pager had none (a hung page left _loadingMore true forever
      // and dead-locked pagination). Same timeout, same failure
      // reset as the first search.
      pageItems = await _cms
          .search(_query, page: _page + 1, cancelToken: _searchToken)
          .timeout(
            const Duration(seconds: 55),
            onTimeout: () => throw TimeoutException('search timeout'),
          );
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
      return;
    }
    if (!mounted) return;
    if (seq != _searchSeq) {
      // A new query superseded this page: reset the flag, or the
      // abandoned load leaves _loadingMore true forever and
      // dead-locks pagination (same reset as the failure path).
      setState(() => _loadingMore = false);
      return;
    }
    final fresh = pageItems
        .where(
          (item) => _seenKeys.add(
            '${videoNormTitle(item.name)}|${item.year}',
          ),
        )
        .toList();
    setState(() {
      _loadingMore = false;
      _page++;
      _results = [..._results, ...fresh];
      if (fresh.isEmpty) _exhausted = true;
    });
  }

  void _openDetail(VideoItem item) {
    // 1.1.6 Smart Groups: the service already dedupes search results
    // by film, so groups here are usually singletons (tap = detail
    // directly); a suffix variant slipping through on one page still
    // opens the version sheet instead of a second card.
    GroupedVideoItem? group;
    for (final g in groupVideoItems(_results)) {
      if (g.representative.identityKey == item.identityKey) {
        group = g;
        break;
      }
    }
    unawaited(
      openGroupedVideo(
        context,
        group ??
            GroupedVideoItem(
              key: '',
              representative: item,
              versions: [item],
            ),
        detailService: _detailService,
      ),
    );
  }

  @override
  void dispose() {
    _searchToken?.cancel();
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final history = VideoHistoryStore.getSearchHistory();
    final hot = _hotNames.isEmpty ? _fallbackHot : _hotNames;
    return Scaffold(
      appBar: HaoNavBar(
        title: '搜索影片',
        scrollController: _scrollController,
      ),
      body: Column(
        children: [
          // G-P2-1: only the input area rebuilds per keystroke
          // (ValueListenableBuilder on the controller) — the chips
          // and results below do not.
          ValueListenableBuilder<TextEditingValue>(
            valueListenable: _controller,
            builder: (context, _, _) => Padding(
              padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
              // Library glass search bar (SKILL.md: inputs are a control
              // surface; the bar is a standalone top-of-page control, not
              // a row inside a scrolling list, so `glass` is correct
              // here, not `solid`). The built-in clear button replaces
              // our suffixIcon clear; textInputAction.search is the
              // library search variant's default; the cursor follows
              // DefaultSelectionStyle -> colorScheme.primary = accent.
              child: HaoSearchField(
                controller: _controller,
                autofocus: true,
                hintText: '搜索影片、剧集…',
                onSubmitted: _search,
                onCancel: () {
                  setState(() {
                    _searched = false;
                    _results = [];
                  });
                },
              ),
            ),
          ),
          if (!_searched) ...[
            if (history.isNotEmpty)
              _ChipSection(
                title: '搜索历史',
                chips: history,
                onTap: (q) {
                  _controller.text = q;
                  unawaited(_search(q));
                },
              ),
            _ChipSection(
              title: '热门搜索',
              chips: hot,
              onTap: (q) {
                _controller.text = q;
                unawaited(_search(q));
              },
            ),
          ],
          Expanded(
            child: _searching
                ? const Center(child: CupertinoActivityIndicator())
                : _failed
                    ? _SearchError(
                        query: _query,
                        onRetry: () => _search(_query),
                      )
                    : _searched && _results.isEmpty
                        ? _EmptyResults(query: _query)
                        : _searched
                            ? CustomScrollView(
                                keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
                                controller: _scrollController,
                                slivers: [
                                  SliverPadding(
                                    padding: const EdgeInsets.fromLTRB(
                                      14,
                                      12,
                                      14,
                                      8,
                                    ),
                                    sliver: SliverToBoxAdapter(
                                      child: VideoPosterGrid(
                                        items: groupVideoItems(
                                          _posterPatch.withCachedPatches(
                                            _results,
                                          ),
                                        )
                                            .map(
                                              (g) => g.representative,
                                            )
                                            .toList(),
                                        onTapItem: _openDetail,
                                        onPointerDownItem: (item) =>
                                            _detailService.prefetch(
                                          item.source,
                                          item.vodId,
                                        ),
                                      ),
                                    ),
                                  ),
                                  SliverToBoxAdapter(
                                    child: Padding(
                                      padding: const EdgeInsets.symmetric(
                                        vertical: 16,
                                      ),
                                      child: Center(
                                        child: _loadingMore
                                            ? const CupertinoActivityIndicator()
                                            : _exhausted
                                                ? Text(
                                                    '已加载全部',
                                                    style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                                                      color: theme.textMuted,
                                                    ),
                                                  )
                                                : const SizedBox.shrink(),
                                      ),
                                    ),
                                  ),
                                ],
                              )
                            : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

class _ChipSection extends StatelessWidget {
  const _ChipSection({
    required this.title,
    required this.chips,
    required this.onTap,
  });

  final String title;
  final List<String> chips;
  final void Function(String query) onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            title,
            style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
              color: theme.textPrimary,
              fontSize: 17,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.01,
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: chips
                .take(kMaxSearchChips)
                .map(
                  (c) => GlassPressScale(
                    pressedScale: 0.97,
                    child: GlassCard(
                      radius: 999,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 7,
                      ),
                      shadow: GlassShadow.none,
                      child: Material(
                        color: Colors.transparent,
                        child: HaoPressable(
                          onTap: () {
                            HaoHaptics.tap();
                            onTap(c);
                          },
                          borderRadius: BorderRadius.circular(999),
                          child: Text(
                            c,
                            style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                              color: theme.textSecondary,
                              fontSize: 14,
                              fontWeight: FontWeight.w500,
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

class _SearchError extends StatelessWidget {
  const _SearchError({required this.query, required this.onRetry});

  final String query;
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
            Icon(shadows: HaoTheme.legibilityShadows(context), Icons.cloud_off, size: 48, color: theme.textMuted),
            const SizedBox(height: 16),
            Text(
              '视频源暂时无法访问',
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.refresh),
              label: Text('重试', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
              style: FilledButton.styleFrom(
                backgroundColor: theme.accent,
                // Theme-defined onPrimary per mode, not hardcoded
                // white (unreadable on the dark-mode light accents).
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

class _EmptyResults extends StatelessWidget {
  const _EmptyResults({required this.query});

  final String query;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            // B-P2-5: the empty state was an emoji 🔍; every other
            // empty state in the app is a theme-coloured icon.
            Icon(shadows: HaoTheme.legibilityShadows(context), Icons.search, size: 40, color: theme.textMuted),
            const SizedBox(height: 12),
            Text(
              '没有找到相关影片：$query',
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '· 换个关键词试试\n· 检查片名有没有错字\n· 换个源可能有更多结果',
              textAlign: TextAlign.center,
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textMuted,
                fontSize: 14,
                height: 1.7,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
