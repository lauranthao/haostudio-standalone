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

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../core/theme/glass.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassCard, GlassShadow;
import '../../services/video/cms_client.dart';
import 'video_detail_page.dart';
import 'video_detail_service.dart';
import 'video_history_store.dart';
import 'video_models.dart';
import 'video_poster_card.dart';
import 'video_title_helpers.dart';

class VideoSearchPage extends StatefulWidget {
  const VideoSearchPage({super.key});

  @override
  State<VideoSearchPage> createState() => _VideoSearchPageState();
}

class _VideoSearchPageState extends State<VideoSearchPage> {
  final _cms = CmsClient();
  final _detailService = VideoDetailService();
  final _controller = TextEditingController();
  final _scrollController = ScrollController();

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
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
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
        _hotNames = daily.map((e) => e.name).where((n) => n.isNotEmpty).take(8).toList();
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
      pageItems = await _cms.search(q, page: 1).timeout(
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
      pageItems = await _cms.search(_query, page: _page + 1);
    } catch (_) {
      if (mounted) setState(() => _loadingMore = false);
      return;
    }
    if (seq != _searchSeq || !mounted) return;
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
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => VideoDetailPage(
          sourceId: item.source,
          vodId: item.vodId,
          preload: item,
        ),
      ),
    );
  }

  @override
  void dispose() {
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
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(
        title: const Text('搜索影片'),
        backgroundColor: theme.surface,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            // Library glass search bar (SKILL.md: inputs are a control
            // surface; the bar is a standalone top-of-page control, not
            // a row inside a scrolling list, so `glass` is correct
            // here, not `solid`). The built-in clear button replaces
            // our suffixIcon clear; textInputAction.search is the
            // library search variant's default; the cursor follows
            // DefaultSelectionStyle -> colorScheme.primary = accent.
            child: GlassSearchBar(
              controller: _controller,
              autofocus: true,
              placeholder: '搜索影片、剧集…',
              placeholderStyle: TextStyle(color: theme.textMuted),
              textStyle: TextStyle(
                color: theme.textPrimary,
                fontSize: 16,
              ),
              searchIconColor: theme.textMuted,
              clearIconColor: theme.textMuted,
              onSubmitted: _search,
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
                ? const Center(child: CircularProgressIndicator())
                : _failed
                    ? _SearchError(
                        query: _query,
                        onRetry: () => _search(_query),
                      )
                    : _searched && _results.isEmpty
                        ? _EmptyResults(query: _query)
                        : _searched
                            ? CustomScrollView(
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
                                        items: _results,
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
                                            ? const CircularProgressIndicator()
                                            : _exhausted
                                                ? Text(
                                                    '已加载全部',
                                                    style: TextStyle(
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
            style: TextStyle(
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
                .take(8)
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
                        child: InkWell(
                          onTap: () {
                            HaoHaptics.tap();
                            onTap(c);
                          },
                          borderRadius: BorderRadius.circular(999),
                          child: Text(
                            c,
                            style: TextStyle(
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
            Icon(Icons.cloud_off, size: 48, color: theme.textMuted),
            const SizedBox(height: 16),
            Text(
              '视频源暂时无法访问',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
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
            const Text('🔍', style: TextStyle(fontSize: 40)),
            const SizedBox(height: 12),
            Text(
              '没有找到相关影片：$query',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '· 换个关键词试试\n· 检查片名有没有错字\n· 换个源可能有更多结果',
              textAlign: TextAlign.center,
              style: TextStyle(
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
