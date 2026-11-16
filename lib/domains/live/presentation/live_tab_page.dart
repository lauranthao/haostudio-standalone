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

import 'dart:async';
import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/models/live_models.dart';
import '../../../core/theme/hao_themes.dart';
import '../../../features/settings/source_stores.dart';
import '../../../shared/platforms/sites.dart';
import '../live_follow_store.dart';
import '../live_history_store.dart';
import 'live_follows_page.dart';
import 'live_history_page.dart';
import 'live_tab_controller.dart';
import 'playback/live_room_page.dart';

class LiveTabPage extends StatefulWidget {
  const LiveTabPage({super.key, this.controller});

  /// Injected for tests; the page creates (and owns) one when omitted.
  final LiveTabController? controller;

  @override
  State<LiveTabPage> createState() => _LiveTabPageState();
}

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
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(
        title: const Text('直播'),
        actions: [
          IconButton(
            icon: const Icon(Icons.history),
            tooltip: '直播历史',
            onPressed: () => Get.to(() => const LiveHistoryPage()),
          ),
          IconButton(
            icon: const Icon(Icons.favorite_border),
            tooltip: '我的关注',
            onPressed: () => Get.to(() => const LiveFollowsPage()),
          ),
        ],
      ),
      body: ListenableBuilder(
        listenable: _controller,
        builder: (context, _) {
          return Column(
            children: [
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
          subtitle: '该平台暂时没有返回推荐内容，换个平台试试，或稍后重试',
          actionLabel: '重新加载',
          onAction: _controller.retry,
        );
      case LiveTabStatus.ready:
        return RefreshIndicator(
          onRefresh: _controller.refresh,
          child: GridView.builder(
            controller: _scrollController,
            padding: const EdgeInsets.all(12),
            gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
              crossAxisCount: 2,
              crossAxisSpacing: 12,
              mainAxisSpacing: 12,
              childAspectRatio: 16 / 10,
            ),
            itemCount: _controller.rooms.length + _footerItemCount,
            itemBuilder: (context, i) {
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
          ),
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
            style: TextStyle(color: theme.accent, fontSize: 12),
          ),
        ),
      );
    }
    return Center(
      child: SizedBox(
        width: 20,
        height: 20,
        child: CircularProgressIndicator(
          strokeWidth: 2,
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
              label: Text(site.name),
              selected: selected,
              selectedColor: theme.accentSoft,
              labelStyle: TextStyle(
                color: selected ? theme.accent : theme.textSecondary,
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
          _categoryChip(theme, '全部', selected == null, () => onSelect(null)),
          for (final area in categories)
            _categoryChip(
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
    HaoTheme theme,
    String label,
    bool isSelected,
    VoidCallback onTap,
  ) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label),
        selected: isSelected,
        selectedColor: theme.accentSoft,
        labelStyle: TextStyle(
          color: isSelected ? theme.accent : theme.textSecondary,
          fontSize: 13,
        ),
        onSelected: (_) => onTap(),
      ),
    );
  }
}

/// One room: full-bleed cover, LIVE badge top-left (the only red in the
/// app), watching pill bottom-right, title + nick over a bottom scrim.
/// The follow heart top-right is a Stack sibling of the card's InkWell,
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
        InkWell(
          onTap: widget.onTap,
          borderRadius: BorderRadius.circular(16),
          child: Container(
            decoration: BoxDecoration(
              // Dark tile under the artwork (same over-image treatment as
              // the video poster card: artwork area is always dark).
              color: const Color(0xFF1C1C1E),
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: theme.hairline),
            ),
            clipBehavior: Clip.antiAlias,
            child: Stack(
              fit: StackFit.expand,
              children: [
                if (room.cover.isNotEmpty)
                  Image.network(
                    room.cover,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => const _MissingCover(),
                  )
                else
                  const _MissingCover(),
                // Bottom scrim so title / nick stay readable over any cover.
                Positioned.fill(
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      gradient: LinearGradient(
                        begin: Alignment.topCenter,
                        end: Alignment.bottomCenter,
                        colors: [
                          Colors.transparent,
                          Colors.black.withValues(alpha: 0.55),
                        ],
                        stops: const [0.55, 1.0],
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
                        horizontal: 7,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        // Red is reserved for the LIVE badge — see hao_themes.
                        color: theme.liveRed,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'LIVE',
                        style: TextStyle(
                          color: Colors.white,
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
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
                        color: const Color(0xA6000000),
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: [
                          const Icon(
                            Icons.visibility_outlined,
                            color: Colors.white,
                            size: 12,
                          ),
                          const SizedBox(width: 3),
                          Text(
                            formatWatching(room.watching),
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
                  left: 10,
                  right: 10,
                  bottom: 8,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        room.title.isEmpty ? room.nick : room.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 13,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        room.nick,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 11,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
        Positioned(
          top: 2,
          right: 2,
          child: Material(
            color: Colors.transparent,
            child: IconButton(
              icon: Icon(
                followed ? Icons.favorite : Icons.favorite_border,
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
      ],
    );
  }
}

class _MissingCover extends StatelessWidget {
  const _MissingCover();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF1C1C1E),
      child: Center(
        child: Icon(Icons.live_tv_outlined, color: Color(0xFF8E8E93), size: 32),
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
      padding: const EdgeInsets.all(12),
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 2,
        crossAxisSpacing: 12,
        mainAxisSpacing: 12,
        childAspectRatio: 16 / 10,
      ),
      itemCount: 6,
      itemBuilder: (context, i) {
        return Container(
          decoration: BoxDecoration(
            color: theme.surface,
            borderRadius: BorderRadius.circular(16),
            border: Border.all(color: theme.hairline),
          ),
          child: ClipRRect(
            borderRadius: BorderRadius.circular(16),
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

/// Centred honest state (empty / error): icon, title, subtitle, retry.
/// The retry button uses the theme accent — never red.
class _StateView extends StatelessWidget {
  const _StateView({
    required this.icon,
    required this.title,
    required this.subtitle,
    required this.actionLabel,
    required this.onAction,
  });

  final IconData icon;
  final String title;
  final String subtitle;
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
            Icon(icon, size: 48, color: theme.textMuted),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onAction,
              style: FilledButton.styleFrom(backgroundColor: theme.accent),
              child: Text(actionLabel),
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
