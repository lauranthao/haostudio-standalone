// Live tab — per-platform room grid fed by real adapter data.
//
// Data comes from [LiveTabController], which calls the platform adapter
// (LiveSite.getRecommendRooms / getCategoryRooms) through Sites.of.
// No fake rooms are ever shown: while loading the grid is a skeleton,
// an adapter that returns nothing is an honest empty state, and a
// failed load is an honest error state with a retry.
//
// Room entry is unchanged: tap opens LiveRoomPage in portrait with an
// inline 16:9 video; only the [ ] button in the room goes landscape.

import '../../../core/theme/hao_radius.dart';
import 'dart:async';
import 'dart:ui';

import 'package:flutter/cupertino.dart';
import '../../../widgets/hao_pressable.dart';
import '../../../widgets/hao_scroll_to_top.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/models/live_models.dart';
import '../../../core/theme/hao_themes.dart';
import '../../../features/settings/source_stores.dart';
import '../../../features/video/widgets/referer_image.dart';
import '../../../shared/platforms/sites.dart';
import '../live_follow_store.dart';
import '../live_history_store.dart';
import '../live_metrics.dart';
import 'live_follows_page.dart';
import 'live_history_page.dart';
import 'live_link_sheet.dart';
import 'live_search_page.dart';
import 'live_tab_controller.dart';
import 'playback/live_multiview_page.dart';
import 'playback/live_recording_center_page.dart';
import 'playback/live_room_page.dart';

class LiveTabPage extends StatefulWidget {
  const LiveTabPage({super.key, this.controller});

  /// Injected for tests; the page creates (and owns) one when omitted.
  final LiveTabController? controller;

  @override
  State<LiveTabPage> createState() => _LiveTabPageState();
}

/// No KeepAlive (P1-P3): the bottom tab is a PageView, so a tab
/// switch disposes this State and it rebuilds on return (room list
/// reloads from the controller). Only the music tab keeps KeepAlive,
/// so the four tabs no longer all sit resident in memory. The scroll
/// listener only fires on scroll; there are no timers, streams or
/// polling in this State that would keep running while hidden.
class _LiveTabPageState extends State<LiveTabPage> {
  late final LiveTabController _controller;
  late final bool _ownsController;
  final _scrollController = ScrollController();

  @override
  void initState() {
    super.initState();
    _ownsController = widget.controller == null;
    _controller = widget.controller ?? LiveTabController();
    _scrollController.addListener(_onScroll);
    HaoScrollToTop.register(HaoScrollToTop.liveTab, _scrollController);
    // If the controller's platform was disabled in settings → 直播源管理,
    // start on the first enabled platform instead.
    final enabled = LiveSourcesStore.enabledIds();
    if (enabled.contains(_controller.platform)) {
      _controller.loadInitial();
    } else {
      _controller.selectPlatform(enabled.first);
    }
  }

  @override
  void dispose() {
    HaoScrollToTop.unregister(HaoScrollToTop.liveTab, _scrollController);
    _scrollController.dispose();
    if (_ownsController) _controller.dispose();
    super.dispose();
  }

  void _onScroll() {
    // Start the next page before the user hits the absolute bottom.
    if (_scrollController.position.extentAfter < 500) {
      _controller.loadMore();
    }
  }

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
      // No AppBar (chen 2026-11-21, screenshot): the title is a big
      // bold header at the top-left of the page body (26 w800), with
      // the actions on the same row — like his 我的片库 screenshot.
      // The header carries the status-bar inset itself (MediaQuery),
      // so the page needs no AppBar and no SafeArea.
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          return Column(
            children: [
              Padding(
                padding: EdgeInsets.fromLTRB(
                  16,
                  MediaQuery.of(context).padding.top + 8,
                  4,
                  4,
                ),
                child: Row(
                  children: [
                    Text(
                      '直播',
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textPrimary,
                        fontSize: 26,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    IconButton(
                      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.search),
                      tooltip: '搜索直播间',
                      onPressed: () => Get.to(
                        () => LiveSearchPage(
                          initialPlatform: _controller.platform,
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.link),
                      tooltip: '粘贴链接进房',
                      onPressed: () => showLiveLinkSheet(
                        context: context,
                        onOpenRoom: (room) => Get.to(
                          () => LiveRoomPage(
                            room: room,
                            playlist: _controller.rooms,
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.grid_view),
                      tooltip: '多画面同看',
                      onPressed: () => Get.to(
                        () => LiveMultiViewPage(
                          rooms: _controller.rooms,
                          onOpenSingle: (room) => Get.to(
                            () => LiveRoomPage(
                              room: room,
                              playlist: _controller.rooms,
                            ),
                          ),
                        ),
                      ),
                    ),
                    IconButton(
                      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.video_library_outlined),
                      tooltip: '录制中心',
                      onPressed: () => Get.to(
                        () => const LiveRecordingCenterPage(),
                      ),
                    ),
                    IconButton(
                      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.history),
                      tooltip: '直播历史',
                      onPressed: () => Get.to(() => const LiveHistoryPage()),
                    ),
                    IconButton(
                      icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.favorite_border),
                      tooltip: '我的关注',
                      onPressed: () => Get.to(() => const LiveFollowsPage()),
                    ),
                  ],
                ),
              ),
              _PlatformRow(
                platform: _controller.platform,
                onSelect: _controller.selectPlatform,
              ),
              if (_controller.categories.isNotEmpty)
                _CategoryRow(
                  categories: _controller.categories,
                  selected: _controller.selectedArea,
                  onSelect: _controller.selectCategory,
                ),
              Expanded(child: _buildBody(theme)),
            ],
          );
        },
      ),
    );
  }

  Widget _buildBody(HaoTheme theme) {
    switch (_controller.status) {
      case LiveTabStatus.loading:
        return const _SkeletonGrid();
      case LiveTabStatus.error:
        return _StateView(
          icon: Icons.cloud_off_outlined,
          title: '加载失败',
          subtitle: '请检查网络后重试',
          actionLabel: '重试',
          onAction: _controller.retry,
        );
      case LiveTabStatus.empty:
        return _StateView(
          icon: Icons.live_tv_outlined,
          title: '暂无直播间',
          actionLabel: '重新加载',
          onAction: _controller.retry,
        );
      case LiveTabStatus.ready:
        return CustomScrollView(
          controller: _scrollController,
          slivers: [
            CupertinoSliverRefreshControl(
              onRefresh: _controller.refresh,
            ),
            SliverPadding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              sliver: SliverGrid(
                gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
                  crossAxisCount: 2,
                  crossAxisSpacing: 12,
                  mainAxisSpacing: 14,
                  childAspectRatio: 16 / 10,
                ),
                delegate: SliverChildBuilderDelegate(
                  (context, i) {
              if (i >= _controller.rooms.length) return _buildFooter(theme);
              final room = _controller.rooms[i];
              return _RoomCard(
                room: room,
                onTap: () {
                  // L01: entering a room records a history entry.
                  unawaited(LiveHistoryStore.record(room));
                  // L04: the room's source list feeds the switch-room
                  // panel's "当前列表" group.
                  Get.to(
                    () => LiveRoomPage(
                      room: room,
                      playlist: _controller.rooms,
                    ),
                  );
                },
              );
                  },
                  childCount: _controller.rooms.length + _footerItemCount,
                ),
              ),
            ),
          ],
        );
    }
  }

  /// One trailing footer cell while another page may exist (spinner,
  /// or a retry when the last page-load failed).
  int get _footerItemCount {
    if (_controller.loadingMore) return 1;
    if (_controller.loadMoreFailed) return 1;
    if (_controller.hasMore) return 1;
    return 0;
  }

  Widget _buildFooter(HaoTheme theme) {
    if (_controller.loadMoreFailed) {
      return Center(
        child: TextButton(
          onPressed: _controller.loadMore,
          child: Text(
            '加载失败，点击重试',
            style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.accent, fontSize: 13),
          ),
        ),
      );
    }
    return Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CupertinoActivityIndicator(
          color: theme.accent,
        ),
      ),
    );
  }
}

/// Horizontal platform switcher (Big-5 only, minus platforms disabled
/// in settings → 直播源管理). Switching re-fetches.
class _PlatformRow extends StatelessWidget {
  const _PlatformRow({required this.platform, required this.onSelect});

  final String platform;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return SizedBox(
      height: 48,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: LiveSourcesStore.enabledIds().map((id) {
          final site = Sites.of(id);
          final selected = id == platform;
          return Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: ChoiceChip(
              label: Text(site.name, style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
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
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.w500,
              ),
              onSelected: (_) => onSelect(id),
            ),
          );
        }).toList(),
      ),
    );
  }
}

/// Horizontal category switcher — shown only when the current platform
/// actually returns categories. "全部" = the recommend list.
class _CategoryRow extends StatelessWidget {
  const _CategoryRow({
    required this.categories,
    required this.selected,
    required this.onSelect,
  });

  final List<LiveArea> categories;
  final LiveArea? selected;
  final ValueChanged<LiveArea?> onSelect;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return SizedBox(
      height: 40,
      child: ListView(
        scrollDirection: Axis.horizontal,
        padding: const EdgeInsets.symmetric(horizontal: 12),
        children: [
          _categoryChip(context, theme, '全部', selected == null, () => onSelect(null)),
          for (final area in categories)
            _categoryChip(
              context,
              theme,
              area.areaName,
              selected?.areaId == area.areaId,
              () => onSelect(area),
            ),
        ],
      ),
    );
  }

  Widget _categoryChip(
    BuildContext context,
    HaoTheme theme,
    String label,
    bool isSelected,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label, style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
        selected: isSelected,
        selectedColor: theme.accentSoft,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(HaoRadius.panel),
        ),
        side: BorderSide(
          color: isSelected ? theme.accent : theme.hairline,
        ),
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 2),
        labelStyle: TextStyle(shadows: HaoTheme.legibilityShadows(context),
          color: isSelected ? theme.accent : theme.textSecondary,
          fontSize: 13,
          fontWeight: isSelected ? FontWeight.w600 : FontWeight.w500,
        ),
        onSelected: (_) => onTap(),
      ),
    );
  }
}

/// One room: full-bleed cover, LIVE badge top-left (the only red in the
/// app), watching pill bottom-right, title + nick over a bottom scrim.
/// The follow heart top-right is a Stack sibling of the card's HaoPressable,
/// so tapping it never opens the room.
class _RoomCard extends StatefulWidget {
  const _RoomCard({required this.room, required this.onTap});

  final LiveRoom room;
  final VoidCallback onTap;

  @override
  State<_RoomCard> createState() => _RoomCardState();
}

class _RoomCardState extends State<_RoomCard> {
  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final room = widget.room;
    final followed = LiveFollowStore.isFollowed(room.platform, room.roomId);
    return Stack(
      fit: StackFit.expand,
      children: [
        HaoPressable(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(HaoRadius.panel),
          child: Container(
            decoration: BoxDecoration(
              // Tile under the artwork: theme surface so it adapts to
              // all 4 themes x light/dark (was hard-coded 0xFF1C1C1E).
              color: theme.surfaceSolid,
              borderRadius: BorderRadius.circular(HaoRadius.panel),
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
                if (room.cover.isNotEmpty)
                  // Dio loader, not Image.network: plain NetworkImage
                  // shows blank on chen's phone (v1.0.5 bug — same
                  // reason music/video posters use Dio loaders).
                  RefererImage(
                    url: room.cover,
                    fit: BoxFit.cover,
                    fallback: const _MissingCover(),
                  )
                else
                  const _MissingCover(),
                // Bottom scrim so title / nick stay readable over any
                // cover in every theme/mode. Black-alpha is deliberate
                // here: a theme surface would be white in light mode
                // and unreadable over artwork.
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.18),
                          Colors.black.withValues(alpha: 0.62),
                        ],
                        stops: const [0.45, 0.78, 1.0],
                      ),
                    ),
                  ),
                ),
                if (room.liveStatus)
                  Positioned(
                    top: 8,
                    left: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 3,
                      ),
                      decoration: BoxDecoration(
                        // Red is reserved for the LIVE badge — see hao_themes.
                        color: theme.liveRed,
                        borderRadius: BorderRadius.circular(HaoRadius.small),
                        boxShadow: [
                          BoxShadow(
                            color: Colors.black.withValues(alpha: 0.30),
                            blurRadius: 4,
                            offset: const Offset(0, 1),
                          ),
                        ],
                      ),
                      child: const Text(
                        'LIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          letterSpacing: 0.6,
                        ),
                      ),
                    ),
                  ),
                if (room.watching > 0)
                  Positioned(
                    right: 8,
                    bottom: 8,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        // Over-cover pill: black-alpha stays readable
                        // over any cover in all 8 combos.
                        color: const Color(0xA6000000),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          Icon(
                            Icons.visibility_outlined, shadows: HaoTheme.legibilityShadows(context), 
                            color: Colors.white,
                            size: 12,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            // Build-29 item 6: labelled by metric
                            // kind (在线 / 热度 / 观看), never a bare
                            // number pretending to be 在线人数.
                            metricLabelFor(room.platform, room.watching),
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ],
                      ),
                    ),
                  ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      // Empty title used to fall back to nick here, so
                      // the same name showed twice. Now an empty title
                      // renders one nick line only (14 bold, same
                      // style as the title line); the second line is
                      // skipped. Card height is fixed by the grid
                      // aspect ratio, so it does not change.
                      Text(
                        room.title.isEmpty ? room.nick : room.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      if (room.title.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          room.nick,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 6,
          right: 6,
          // Frosted dark dot behind the heart so it stays tappable
          // and legible over bright covers in every theme/mode.
          child: Container(
            decoration: BoxDecoration(
              color: Colors.black.withValues(alpha: 0.30),
              shape: BoxShape.circle,
            ),
            child: Material(
              color: Colors.transparent,
              child: IconButton(
                padding: const EdgeInsets.all(6),
                constraints: const BoxConstraints(
                  minWidth: 32,
                  minHeight: 32,
                ),
                icon: Icon(
                  followed ? Icons.favorite : Icons.favorite_border, shadows: HaoTheme.legibilityShadows(context), 
                  color: followed ? theme.accent : Colors.white,
                  size: 20,
                ),
                tooltip: followed ? '取消关注' : '关注',
                onPressed: () async {
                  await LiveFollowStore.toggle(room);
                  if (mounted) setState(() {});
                },
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _MissingCover extends StatelessWidget {
  const _MissingCover();

  @override
  Widget build(BuildContext context) {
    // Theme surface + muted icon: was hard-coded dark tile + grey,
    // which read as a black hole on light themes.
    final theme = HaoTheme.of(context);
    return ColoredBox(
      color: theme.surfaceSolid,
      child: Center(
        child: Icon(
          Icons.live_tv_outlined, shadows: HaoTheme.legibilityShadows(context), 
          color: theme.textMuted,
          size: 32,
        ),
      ),
    );
  }
}

/// Skeleton grid shown while the first page loads — same 2-column 16:10
/// grid as the real rooms, so the layout does not jump when data lands.
class _SkeletonGrid extends StatelessWidget {
  const _SkeletonGrid();

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GridView.builder(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 14,
        childAspectRatio: 16 / 10,
      ),
      itemCount: 6,
      itemBuilder: (context, i) {
        return Container(
          decoration: BoxDecoration(
            color: theme.surface,
            borderRadius: BorderRadius.circular(HaoRadius.large),
            border: Border.all(color: theme.hairline),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(HaoRadius.large),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: theme.glassBlurSigma,
                sigmaY: theme.glassBlurSigma,
              ),
              child: const SizedBox.expand(),
            ),
          ),
        );
      },
    );
  }
}

/// Centred honest state (empty / error): icon, title, optional
/// subtitle, retry. The empty state has no subtitle (removed
/// 2026-11-19 clean pass); the error state keeps its '请检查网络后重试'.
/// The retry button uses the theme accent — never red.
class _StateView extends StatelessWidget {
  const _StateView({
    required this.icon,
    required this.title,
    this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String? subtitle;
  final String actionLabel;
  final VoidCallback onAction;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Container(
              padding: const EdgeInsets.all(20),
              decoration: BoxDecoration(
                color: theme.accentSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(shadows: HaoTheme.legibilityShadows(context), icon, size: 40, color: theme.accent),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            if (subtitle != null) ...[
              const SizedBox(height: 8),
              Text(
                subtitle!,
                textAlign: TextAlign.center,
                style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                  color: theme.textSecondary,
                  fontSize: 14,
                  height: 1.5,
                ),
              ),
            ],
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onAction,
              child: Text(actionLabel, style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
            ),
          ],
        ),
      ),
    );
  }
}

/// Watching count: 12345 -> "1.2万", smaller counts as-is.
String formatWatching(int watching) {
  if (watching >= 10000) {
    return '${(watching / 10000).toStringAsFixed(1)}万';
  }
  return '$watching';
}
