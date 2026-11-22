// Live search page — progressive multi-platform search (build 29,
// item 2).
//
// One query fans out to every enabled platform concurrently
// (LiveProgressiveSearch): each platform's results appear the moment
// that platform answers, a single platform's 12 s timeout / failure
// never blocks the others, and the error state only shows when ALL
// platforms failed with nothing found. The platform row is a FILTER
// over the merged results (not a re-search), and "包含未开播" toggles
// whether offline rooms are shown (default on — the old behaviour).
//
// The platform adapters all implement searchRooms already (see the
// old header comment for the per-platform notes, kept below):
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
// Rooms only: searchAnchors is NOT offered — Douyin's throws
// ("抖音暂不支持搜索主播") and Kuaishou has no separate room search,
// so a second tab would be broken on two of the five platforms.
// Room search matches title AND anchor nick on the server side,
// which covers "搜直播间/主播名".
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

import 'package:flutter/cupertino.dart';
import '../../../widgets/hao_pressable.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/models/live_models.dart';
import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/glass.dart';
import '../../../core/theme/haptics.dart';
import '../../../features/settings/source_stores.dart';
import '../../../features/video/widgets/referer_image.dart';
import '../../../widgets/hao_search_field.dart';
import '../../../widgets/native_switch.dart';
import '../../../shared/platforms/sites.dart';
import '../live_history_store.dart';
import '../live_metrics.dart';
import '../live_search_progressive.dart';
import '../live_status.dart';
import 'live_link_sheet.dart';
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

  /// Platform FILTER over the merged results (null = 全部). The
  /// search itself always runs on every enabled platform.
  String? _platformFilter;
  List<LiveRoom> _results = [];

  /// Per-platform completion, for the progressive display + the
  /// partial-failure note.
  Set<String> _donePlatforms = {};
  Set<String> _failedPlatforms = {};
  bool _searching = false;
  bool _searched = false;
  int _searchSeq = 0;
  String _query = '';

  /// "包含未开播" — default on (old behaviour showed offline rooms).
  bool _includeOffline = true;

  @override
  void initState() {
    super.initState();
    final enabled = LiveSourcesStore.enabledIds();
    _platformFilter = widget.initialPlatform != null &&
            enabled.contains(widget.initialPlatform)
        ? widget.initialPlatform
        : null;
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

  /// Progressive fan-out: every enabled platform concurrently, each
  /// with its own 12 s timeout; results appear per platform as they
  /// land. The generation guard ([_searchSeq]) drops stale rounds.
  Future<void> _search(String query) async {
    final q = query.trim();
    if (q.isEmpty) return;
    final seq = ++_searchSeq;
    final platforms = LiveSourcesStore.enabledIds();
    setState(() {
      _query = q;
      _searching = true;
      _searched = true;
      _results = [];
      _donePlatforms = {};
      _failedPlatforms = {};
    });
    await LiveHistoryStore.saveSearchQuery(q);
    final search = LiveProgressiveSearch(search: _runSearch);
    await search.run(
      q,
      platforms,
      generation: () => _searchSeq,
      onPlatformDone: (result) {
        if (seq != _searchSeq || !mounted) return;
        setState(() {
          _donePlatforms = {..._donePlatforms, result.platform};
          if (result.failed) {
            _failedPlatforms = {..._failedPlatforms, result.platform};
          }
          // Merge this platform's rooms (dedupe by platform|roomId).
          final seen = _results
              .map((r) => '${r.platform}|${r.roomId}')
              .toSet();
          for (final room in result.rooms) {
            if (seen.add('${room.platform}|${room.roomId}')) {
              _results = [..._results, room];
            }
          }
        });
      },
    );
    if (seq != _searchSeq || !mounted) return;
    setState(() => _searching = false);
  }

  /// The platform row filters the merged results — it never re-runs
  /// the query (the search already covered every platform).
  void _selectPlatform(String? id) {
    if (id == _platformFilter) return;
    setState(() => _platformFilter = id);
  }

  /// Failed only when every platform failed AND nothing was found.
  bool get _failed =>
      _searched &&
      !_searching &&
      _results.isEmpty &&
      _failedPlatforms.isNotEmpty &&
      _donePlatforms.length == _failedPlatforms.length;

  List<LiveRoom> get _visible {
    var list = _results;
    final filter = _platformFilter;
    if (filter != null) {
      list = list.where((r) => r.platform == filter).toList();
    }
    return applyOfflineFilter(list, includeOffline: _includeOffline);
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

  void _openLinkSheet() {
    unawaited(
      showLiveLinkSheet(context: context, onOpenRoom: _openRoom),
    );
  }

  @override
  Widget build(BuildContext context) {
    final history = LiveHistoryStore.getSearchHistory();
    final enabled = LiveSourcesStore.enabledIds();
    final visible = _visible;
    final theme = HaoTheme.of(context);
    return Scaffold(
      appBar: AppBar(
        title: Text('搜索直播间', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
        actions: [
          IconButton(
            icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.link),
            tooltip: '粘贴链接进房',
            onPressed: _openLinkSheet,
          ),
        ],
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
            child: HaoSearchField(
              controller: _controller,
              autofocus: true,
              hintText: '搜索直播间、主播…',
              onSubmitted: _search,
              onCancel: () {
                setState(() {
                  _results = [];
                  _searched = false;
                  _donePlatforms = {};
                  _failedPlatforms = {};
                  _query = '';
                });
              },
            ),
        ),
          _PlatformRow(
            platform: _platformFilter,
            platforms: enabled,
            onSelect: _selectPlatform,
          ),
          // Build-29 item 2: "包含未开播" filter (HaoNativeSwitch).
          // Default on — the old behaviour showed offline rooms.
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 6),
            child: HaoSwitchRow(
              title: '包含未开播',
              subtitle: _includeOffline ? '开播和未开播的都显示' : '只显示正在开播的',
              value: _includeOffline,
              onChanged: (v) => setState(() => _includeOffline = v),
            ),
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
          // Progressive note: which platforms are still searching /
          // failed alone (a single slow platform never blocks the rest).
          if (_searched && _failedPlatforms.isNotEmpty && !_failed)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              child: Row(
                children: [
                  Icon(
                    shadows: HaoTheme.legibilityShadows(context),
                    Icons.warning_amber_outlined,
                    size: 14,
                    color: theme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Expanded(
                    child: Text(
                      '${_failedPlatforms.map(platformName).join('、')}搜索失败，其他平台结果照常显示',
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: _searching && _results.isEmpty
                ? const Center(child: CupertinoActivityIndicator())
                : _failed
                    ? _SearchError(
                        query: _query,
                        onRetry: () => _search(_query),
                      )
                    : _searched && _results.isEmpty
                        ? _EmptyResults(query: _query)
                        : _searched && visible.isEmpty
                            ? _EmptyResults(
                                query: '$_query（当前筛选下没有结果）',
                              )
                            : _searched
                                ? ListView.separated(
                                    padding: const EdgeInsets.fromLTRB(
                                      14,
                                      12,
                                      14,
                                      16,
                                    ),
                                    itemCount: visible.length,
                                    separatorBuilder: (_, _) =>
                                        const SizedBox(height: 12),
                                    itemBuilder: (context, i) {
                                      final room = visible[i];
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

/// Platform filter — same ChoiceChip language as the live tab's
/// platform row (Big-5 only, minus platforms disabled in settings),
/// plus 全部. Filtering never re-runs the query: the search already
/// covered every platform.
class _PlatformRow extends StatelessWidget {
  const _PlatformRow({
    required this.platform,
    required this.platforms,
    required this.onSelect,
  });

  /// Null = 全部.
  final String? platform;
  final List<String> platforms;
  final ValueChanged<String?> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    Widget chip(String label, bool selected, VoidCallback onTap) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 4),
        child: ChoiceChip(
          label: Text(label, style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
          selected: selected,
          selectedColor: theme.accentSoft,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(HaoRadius.panel),
          ),
          side: BorderSide(
            color: selected ? theme.accent : theme.hairline,
          ),
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
          labelStyle: TextStyle(shadows: HaoTheme.legibilityShadows(context),
            color: selected ? theme.accent : theme.textSecondary,
            fontSize: 13,
            fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
          ),
          onSelected: (_) => onTap(),
        ),
      );
    }

    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          chip('全部', platform == null, () => onSelect(null)),
          for (final id in platforms)
            chip(
              Sites.of(id).name,
              id == platform,
              () => onSelect(id),
            ),
        ],
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
                style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
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
                  style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
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
                    label: Text(c, style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
                    labelStyle: TextStyle(shadows: HaoTheme.legibilityShadows(context),
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
        child: HaoPressable(
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
                    style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
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
                    style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
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
                          child: Text(
                            'LIVE',
                            style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
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
                          style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                            color: theme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      if (room.watching > 0) ...[
                        const SizedBox(width: 8),
                        Icon(shadows: HaoTheme.legibilityShadows(context),
                          Icons.visibility_outlined,
                          color: theme.textMuted,
                          size: 13,
                        ),
                        const SizedBox(width: 3),
                        Text(
                          // Build-29 item 6: labelled by metric kind
                          // (在线 / 热度 / 观看), never a bare number.
                          metricLabelFor(room.platform, room.watching),
                          style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
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
            Icon(shadows: HaoTheme.legibilityShadows(context),
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
        child: Icon(shadows: HaoTheme.legibilityShadows(context),
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
            Icon(shadows: HaoTheme.legibilityShadows(context), Icons.cloud_off, size: 48, color: theme.textMuted),
            const SizedBox(height: 16),
            Text(
              '直播源暂时无法访问',
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '换个关键词或平台试试',
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textMuted,
                fontSize: 14,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.refresh),
              label: Text('重试', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
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
            Icon(shadows: HaoTheme.legibilityShadows(context),
              Icons.search_off_outlined,
              size: 48,
              color: theme.textMuted,
            ),
            const SizedBox(height: 12),
            Text(
              '没有找到相关直播间：$query',
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '· 换个关键词试试\n· 该主播可能没开播\n· 换个平台可能有结果',
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

/// Watching counts are formatted + labelled by live_metrics
/// (metricLabelFor) — the old local _formatWatching copy is gone so
/// the label can never drift from the tab / follow cards again.
