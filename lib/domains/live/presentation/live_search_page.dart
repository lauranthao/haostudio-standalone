// Live search page — search live rooms on one platform at a time.
//
// chen 2026-11-17: the live tab had NO search entry at all (not a
// broken search — the feature was entirely absent). The platform
// adapters all implement searchRooms already, so this page is UI +
// history only, no new parsing:
//
//   Huya     search.cdn.huya.com — real API, paginated.
//   Douyu    www.douyu.com/japi/search/api/searchShow — real API.
//   Bilibili api.bilibili.com/x/web-interface/search/type
//            (search_type 'live') — real API.
//   Douyin   DouyinSearch three-stage fallback (live API -> general
//            API -> partition search) — real API.
//   Kuaishou author search — the web search page never lists rooms,
//            so results are anchors as rooms (only a `living` flag).
//
// Rooms only, one platform at a time: searchAnchors is NOT offered
// here — Douyin's throws ("抖音暂不支持搜索主播") and Kuaishou has no
// separate room search, so a second tab would be broken on two of the
// five platforms. Room search matches title AND anchor nick on the
// server side, which covers "搜直播间/主播名".
//
// Entry is the same as the room grid: tap records a history entry and
// opens LiveRoomPage, which re-parses play URLs fresh on entry
// (getRoomDetail + resolvePlayUrls), so a search result never plays a
// stale URL — search results carry no play URLs at all.
//
// Structure mirrors VideoSearchPage: autofocus search field, history
// chips before the first search, a generation guard so a new query
// cancels the previous one (stale results cannot overwrite the new
// query), and honest loading / error / empty states — never a blank.

import '../../../core/theme/hao_radius.dart';
import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/models/live_models.dart';
import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/glass.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart'
    hide GlassCard, GlassShadow;
import '../../../core/theme/haptics.dart';
import '../../../features/settings/source_stores.dart';
import '../../../features/video/widgets/referer_image.dart';
import '../../../shared/platforms/sites.dart';
import '../live_history_store.dart';
import 'playback/live_room_page.dart';

/// Search live rooms. [searchFn] is a test seam: production passes
/// null and the page calls `Sites.of(platform).searchRooms(keyword)`.
/// [onOpenRoom] is a test seam for the room entry: production passes
/// null and the page records history + opens LiveRoomPage (same entry
/// as the room grid).
class LiveSearchPage extends StatefulWidget {
  const LiveSearchPage({
    super.key,
    this.initialPlatform,
    this.searchFn,
    this.onOpenRoom,
  });

  /// Platform to start on (the live tab passes its current platform).
  final String? initialPlatform;

  /// Test seam: (platform, keyword) -> rooms. Null = real adapter.
  final Future<List<LiveRoom>> Function(String platform, String keyword)?
      searchFn;

  /// Test seam: room entry. Null = record history + open LiveRoomPage.
  final void Function(LiveRoom room)? onOpenRoom;

  @override
  State<LiveSearchPage> createState() => _LiveSearchPageState();
}

class _LiveSearchPageState extends State<LiveSearchPage> {
  final _controller = TextEditingController();

  late String _platform;
  List<LiveRoom> _results = [];
  bool _searching = false;
  bool _searched = false;
  bool _failed = false;
  int _searchSeq = 0;
  String _query = '';

  @override
  void initState() {
    super.initState();
    final enabled = LiveSourcesStore.enabledIds();
    _platform = widget.initialPlatform != null &&
            enabled.contains(widget.initialPlatform)
        ? widget.initialPlatform!
        : enabled.first;
    _controller.addListener(() {
      if (mounted) setState(() {});
    });
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  Future<List<LiveRoom>> _runSearch(String platform, String keyword) {
    final fn = widget.searchFn;
    if (fn != null) return fn(platform, keyword);
    return Sites.of(platform).searchRooms(keyword);
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
    });
    await LiveHistoryStore.saveSearchQuery(q);
    List<LiveRoom> rooms;
    try {
      rooms = await _runSearch(_platform, q).timeout(
        const Duration(seconds: 20),
        onTimeout: () => throw TimeoutException('live search timeout'),
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
      _results = rooms;
    });
  }

  void _selectPlatform(String id) {
    if (id == _platform) return;
    setState(() => _platform = id);
    // The platform is part of the search context: a searched query
    // re-runs on the new platform instead of showing stale results.
    if (_searched && _query.isNotEmpty) unawaited(_search(_query));
  }

  void _openRoom(LiveRoom room) {
    // Same entry as the room grid: record history, open in portrait.
    unawaited(LiveHistoryStore.record(room));
    final open = widget.onOpenRoom;
    if (open != null) {
      open(room);
      return;
    }
    Get.to(
      () => LiveRoomPage(room: room, playlist: _results),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final history = LiveHistoryStore.getSearchHistory();
    final enabled = LiveSourcesStore.enabledIds();
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(
        title: const Text('搜索直播间'),
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
              placeholder: '搜索直播间、主播…',
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
          _PlatformRow(
            platform: _platform,
            platforms: enabled,
            onSelect: _selectPlatform,
          ),
          if (!_searched && history.isNotEmpty)
            _HistorySection(
              history: history,
              onTap: (q) {
                _controller.text = q;
                unawaited(_search(q));
              },
              onClear: () async {
                await LiveHistoryStore.clearSearchHistory();
                if (mounted) setState(() {});
              },
            ),
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
                            ? ListView.separated(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  12,
                                  14,
                                  16,
                                ),
                                itemCount: _results.length,
                                separatorBuilder: (_, _) =>
                                    const SizedBox(height: 12),
                                itemBuilder: (context, i) {
                                  final room = _results[i];
                                  return _RoomRow(
                                    room: room,
                                    onTap: () => _openRoom(room),
                                  );
                                },
                              )
                            : const SizedBox.shrink(),
          ),
        ],
      ),
    );
  }
}

/// Platform switcher — same ChoiceChip language as the live tab's
/// platform row (Big-5 only, minus platforms disabled in settings).
class _PlatformRow extends StatelessWidget {
  const _PlatformRow({
    required this.platform,
    required this.platforms,
    required this.onSelect,
  });

  final String platform;
  final List<String> platforms;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: platforms.map((id) {
          final site = Sites.of(id);
          final selected = id == platform;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text(site.name),
              selected: selected,
              selectedColor: theme.accentSoft,
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(HaoRadius.panel),
              ),
              side: BorderSide(
                color: selected ? theme.accent : theme.hairline,
              ),
              padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
              labelStyle: TextStyle(
                color: selected ? theme.accent : theme.textSecondary,
                fontSize: 13,
                fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
              ),
              onSelected: (_) => onSelect(id),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Search history — same shape as the music search page's
/// `_SearchHistory`: title + clear on one row, up to 8 recent terms as
/// chips. Only renders when history is non-empty.
class _HistorySection extends StatelessWidget {
  const _HistorySection({
    required this.history,
    required this.onTap,
    required this.onClear,
  });

  final List<String> history;
  final void Function(String query) onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Text(
                '搜索历史',
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -0.01,
                ),
              ),
              const Spacer(),
              GestureDetector(
                onTap: onClear,
                child: Text(
                  '清除',
                  style: TextStyle(
                    color: theme.textMuted,
                    fontSize: 13,
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: history
                .take(8)
                .map(
                  (c) => ActionChip(
                    label: Text(c),
                    labelStyle: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 14,
                      fontWeight: FontWeight.w500,
                    ),
                    backgroundColor: theme.surface,
                    side: BorderSide(color: theme.hairline),
                    onPressed: () => onTap(c),
                  ),
                )
                .toList(),
          ),
        ],
      ),
    );
  }
}

/// One search result: cover thumb, title + nick, LIVE badge when the
/// room is live, watching count. Offline rooms stay tappable (same as
/// follows/history) — the room page resolves fresh on entry and shows
/// its own error state when nothing plays.
class _RoomRow extends StatelessWidget {
  const _RoomRow({required this.room, required this.onTap});

  final LiveRoom room;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GlassCard(
      radius: 16,
      padding: const EdgeInsets.all(10),
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            HaoHaptics.tap();
            onTap();
          },
          borderRadius: BorderRadius.circular(HaoRadius.large),
          child: Row(
          children: [
            ClipRRect(
              borderRadius: BorderRadius.circular(HaoRadius.standard),
              child: SizedBox(
                width: 112,
                height: 63,
                child: room.cover.isNotEmpty
                    // Dio loader, not Image.network (v1.0.5 phone bug:
                    // plain NetworkImage shows blank).
                    ? RefererImage(
                        url: room.cover,
                        fit: BoxFit.cover,
                        fallback: _MissingCover(theme: theme),
                      )
                    : _MissingCover(theme: theme),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    room.title.isEmpty ? room.nick : room.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    room.nick,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Row(
                    children: [
                      if (room.liveStatus)
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.liveRed,
                            borderRadius: BorderRadius.circular(HaoRadius.badge),
                          ),
                          child: const Text(
                            'LIVE',
                            style: TextStyle(
                              color: Colors.white,
                              fontSize: 10,
                              fontWeight: FontWeight.w700,
                              letterSpacing: 0.6,
                            ),
                          ),
                        )
                      else
                        Text(
                          '未开播',
                          style: TextStyle(
                            color: theme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      if (room.watching > 0) ...[
                        const SizedBox(width: 8),
                        Icon(
                          Icons.visibility_outlined,
                          color: theme.textMuted,
                          size: 13,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          _formatWatching(room.watching),
                          style: TextStyle(
                            color: theme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            Icon(
              Icons.chevron_right,
              color: theme.textMuted,
              size: 20,
            ),
          ],
        ),
        ),
      ),
    );
  }
}

class _MissingCover extends StatelessWidget {
  const _MissingCover({required this.theme});

  final HaoTheme theme;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: theme.surfaceSolid,
      child: Center(
        child: Icon(
          Icons.live_tv_outlined,
          color: theme.textMuted,
          size: 28,
        ),
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
              '直播源暂时无法访问',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '换个关键词或平台试试',
              style: TextStyle(
                color: theme.textMuted,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
              style: FilledButton.styleFrom(
                backgroundColor: theme.accent,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
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
            Icon(
              Icons.search_off_outlined,
              size: 48,
              color: theme.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              '没有找到相关直播间：$query',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '· 换个关键词试试\n· 该主播可能没开播\n· 换个平台可能有结果',
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

/// Watching count — same rule as the live tab's formatWatching:
/// 12345 -> "1.2万", smaller counts as-is.
String _formatWatching(int watching) {
  if (watching >= 10000) {
    return '${(watching / 10000).toStringAsFixed(1)}万';
  }
  return '$watching';
}
