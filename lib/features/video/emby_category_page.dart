// Emby category full list (build 30 audit §18).
//
// The tab page's 电影 / 剧集 rails are only a preview (one row +
// "加载更多"); the whole category lives here — Infuse grid, paginated
// from the server, total shown, pull-to-refresh, tap a poster for
// the detail page. Same card and grid geometry as the tab page's
// search grid (3 columns, EmbyPosterCard with auth headers); no new
// visual language invented.

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/video/emby_client.dart';
import '../../widgets/hao_nav_bar.dart';
import 'emby_detail_page.dart';
import 'video_models.dart';
import 'video_poster_card.dart';

enum EmbyCategoryKind { movies, series, favorites, genre }

extension EmbyCategoryKindLabel on EmbyCategoryKind {
  String get title => switch (this) {
        EmbyCategoryKind.movies => '电影',
        EmbyCategoryKind.series => '剧集',
        EmbyCategoryKind.favorites => '收藏',
        EmbyCategoryKind.genre => '类型',
      };
}

class EmbyCategoryPage extends StatefulWidget {
  const EmbyCategoryPage({
    super.key,
    required this.client,
    required this.kind,
    this.genre,
    this.libraryId,
    this.initialItems = const [],
    this.total = 0,
    this.watchedKeys = const {},
  });

  /// Client that already passed the tab page's loads.
  final EmbyClient client;

  final EmbyCategoryKind kind;

  /// Genre name when [kind] is [EmbyCategoryKind.genre].
  final String? genre;

  /// Pinned library id (null = whole server, same as the rail).
  final String? libraryId;

  /// First page, already loaded by the tab page — paints instantly.
  final List<VideoItem> initialItems;

  /// Server total at open time (0 = unknown, loads the first page).
  final int total;

  final Set<String> watchedKeys;

  @override
  State<EmbyCategoryPage> createState() => _EmbyCategoryPageState();
}

class _EmbyCategoryPageState extends State<EmbyCategoryPage> {
  static const int _pageSize = 60;

  final _scrollController = ScrollController();
  CancelToken? _pageToken;

  late List<VideoItem> _items;
  late int _total;
  bool _loadingMore = false;
  bool _loadMoreFailed = false;
  bool _firstLoadFailed = false;

  bool get _hasMore => _items.length < _total;

  @override
  void initState() {
    super.initState();
    _items = List.of(widget.initialItems);
    _total = widget.total;
    _scrollController.addListener(_maybeLoadMore);
    if (_items.isEmpty) {
      _loadMore();
    }
  }

  @override
  void dispose() {
    _pageToken?.cancel();
    _scrollController.dispose();
    super.dispose();
  }

  void _maybeLoadMore() {
    if (!_scrollController.hasClients) return;
    if (_scrollController.position.extentAfter < 800) {
      _loadMore();
    }
  }

  Future<EmbyItemsPage> _fetchPage(int startIndex, int limit) {
    return switch (widget.kind) {
      EmbyCategoryKind.movies => widget.client.movies(
          libraryId: widget.libraryId,
          startIndex: startIndex,
          limit: limit,
          cancelToken: _pageToken,
        ),
      EmbyCategoryKind.series => widget.client.series(
          libraryId: widget.libraryId,
          startIndex: startIndex,
          limit: limit,
          cancelToken: _pageToken,
        ),
      EmbyCategoryKind.favorites => widget.client.favorites(
          startIndex: startIndex,
          limit: limit,
          cancelToken: _pageToken,
        ),
      EmbyCategoryKind.genre => widget.client.byGenre(
          widget.genre ?? '',
          startIndex: startIndex,
          limit: limit,
          cancelToken: _pageToken,
        ),
    };
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore && _items.isNotEmpty) return;
    setState(() {
      _loadingMore = true;
      _loadMoreFailed = false;
    });
    _pageToken?.cancel();
    _pageToken = CancelToken();
    try {
      final page = await _fetchPage(_items.length, _pageSize);
      if (!mounted) return;
      setState(() {
        _items = [..._items, ...page.items];
        _total = page.totalCount;
        _firstLoadFailed = false;
      });
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      if (!mounted) return;
      setState(() {
        if (_items.isEmpty) _firstLoadFailed = true;
        _loadMoreFailed = true;
      });
    } on EmbyException {
      if (!mounted) return;
      setState(() {
        if (_items.isEmpty) _firstLoadFailed = true;
        _loadMoreFailed = true;
      });
    } finally {
      if (mounted) setState(() => _loadingMore = false);
    }
  }

  Future<void> _refresh() async {
    _pageToken?.cancel();
    _pageToken = CancelToken();
    try {
      final page = await _fetchPage(0, _pageSize);
      if (!mounted) return;
      setState(() {
        _items = page.items;
        _total = page.totalCount;
        _firstLoadFailed = false;
        _loadMoreFailed = false;
      });
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
    } on EmbyException {
      // Pull-to-refresh failing keeps the old list (the stale
      // banner on the tab page is the failure signal there); a
      // first-load failure is shown by the empty state below.
      if (!mounted) return;
      if (_items.isEmpty) setState(() => _firstLoadFailed = true);
    }
  }

  void _openDetail(VideoItem item) {
    Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => EmbyDetailPage(
          itemId: item.vodId,
          preload: item,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    // Same cell ratio derivation as VideoPosterGrid: column width /
    // (2:3 poster + the card's fixed text block).
    final gridWidth = MediaQuery.sizeOf(context).width - 32;
    final colW = (gridWidth - 2 * 12) / 3;
    final ratio = colW / (colW * 3 / 2 + kVideoPosterCardTextHeight);
    return Scaffold(
      appBar: HaoNavBar(
        title: widget.kind == EmbyCategoryKind.genre
            ? (widget.genre ?? '类型')
            : widget.kind.title,
        scrollController: _scrollController,
      ),
      body: CustomScrollView(
        controller: _scrollController,
        physics: const BouncingScrollPhysics(
          parent: AlwaysScrollableScrollPhysics(),
        ),
        slivers: [
          CupertinoSliverRefreshControl(onRefresh: _refresh),
          if (_total > 0)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                child: Text(
                  '共 $_total 部',
                  style: TextStyle(
                    color: theme.textSecondary,
                    fontSize: 13,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ),
            ),
          if (_items.isNotEmpty)
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              sliver: SliverGrid(
                gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 3,
                  mainAxisSpacing: 16,
                  crossAxisSpacing: 12,
                  childAspectRatio: ratio,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
                    final item = _items[i];
                    return EmbyPosterCard(
                      item: item,
                      imageHeaders: widget.client.imageHeaders,
                      isWatched: widget.watchedKeys.contains(item.identityKey),
                      onTap: () => _openDetail(item),
                    );
                  },
                  childCount: _items.length,
                ),
              ),
            ),
          if (_firstLoadFailed)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '加载失败，下拉重试',
                      style: TextStyle(color: theme.textSecondary),
                    ),
                    const SizedBox(height: 12),
                    CupertinoButton(
                      onPressed: _loadMore,
                      child: const Text('重试'),
                    ),
                  ],
                ),
              ),
            )
          else if (_items.isEmpty && !_loadingMore)
            SliverFillRemaining(
              hasScrollBody: false,
              child: Center(
                child: Text(
                  '这里还没有内容',
                  style: TextStyle(color: theme.textMuted),
                ),
              ),
            )
          else if (_loadMoreFailed)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                child: Center(
                  child: CupertinoButton(
                    onPressed: _loadMore,
                    child: Text(
                      '加载失败，点按重试（已显示 ${_items.length} / 共 $_total 部）',
                      style: const TextStyle(fontSize: 14),
                    ),
                  ),
                ),
              ),
            )
          else if (_loadingMore)
            const SliverToBoxAdapter(
              child: Padding(
                padding: EdgeInsets.fromLTRB(16, 4, 16, 24),
                child: Center(child: CupertinoActivityIndicator()),
              ),
            )
          else if (_items.isNotEmpty && !_hasMore)
            SliverToBoxAdapter(
              child: Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 24),
                child: Center(
                  child: Text(
                    '已显示全部 $_total 部',
                    style: TextStyle(
                      color: theme.textMuted,
                      fontSize: 13,
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
