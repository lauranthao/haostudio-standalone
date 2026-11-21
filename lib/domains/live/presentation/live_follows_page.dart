// Follow page (L03) — independent page, NOT nested in the live tab.
//
// Top tabs: 已开播 (n) / 未开播 (n) with counts. There is deliberately
// NO 录播 tab: no replay data exists yet (L14 has not landed) and a
// tab with faked counts would be fake data. Below the tabs, a platform
// chips row (全部 + each platform that has follows). Pull-to-refresh
// refreshes follow statuses; tapping a tab re-refreshes. Per-group
// empty states carry a "去逛逛" action back to the live tab. Cards
// reuse the live tab's room-card style (cover + LIVE badge + title +
// anchor) with an unfollow button; tapping a card opens the room.
//
// Follow data: [LiveFollowStore] (Hive `hao_live_follows`) — the
// Flutter app had no follow store before L03. Statuses come from
// [refreshRoomStatuses]: a room is only 已开播 when the adapter's fresh
// detail says so; a failed check is 状态未知 (shown in the 未开播
// group with an unknown badge, never counted as live).
//
// Pure Live reference: features/favorite/favorite_page.dart,
// favorite_rules.dart (`roomsOf`, `groupOf`).

import '../../../core/theme/hao_radius.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/haptics.dart';
import '../../../core/theme/glass.dart';
import '../../../features/video/widgets/referer_image.dart';
import '../../../shared/platforms/live_site.dart';
import '../live_follow_store.dart';
import '../live_status.dart';
import 'live_status_badge.dart';
import 'playback/live_room_page.dart';

enum _FollowTab { live, notLive }

class LiveFollowsPage extends StatefulWidget {
  const LiveFollowsPage({super.key, this.siteOf, this.onOpenRoom, this.onBrowse});

  /// Injected for tests; defaults to the real platform adapters.
  final LiveSite Function(String platformId)? siteOf;

  /// Injected for tests; defaults to opening [LiveRoomPage].
  final void Function(LiveFollow follow)? onOpenRoom;

  /// Injected for tests; defaults to popping back to the live tab.
  final VoidCallback? onBrowse;

  @override
  State<LiveFollowsPage> createState() => _LiveFollowsPageState();
}

class _LiveFollowsPageState extends State<LiveFollowsPage> {
  _FollowTab _tab = _FollowTab.live;

  /// Null = 全部 platforms; otherwise a platform id.
  String? _platformFilter;
  Map<String, LiveStatus> _statuses = const {};
  bool _refreshing = false;
  bool _hasRefreshed = false;
  int _failedCount = 0;

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  Future<void> _refresh() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    final follows = LiveFollowStore.getAll();
    final statuses = await refreshRoomStatuses(
      follows.map((f) => f.toRoom()).toList(),
      siteOf: widget.siteOf,
    );
    if (!mounted) return;
    setState(() {
      _statuses = statuses;
      _refreshing = false;
      _hasRefreshed = true;
      _failedCount = statuses.values
          .where((s) => s == LiveStatus.unknown)
          .length;
    });
  }

  /// Tapping a tab re-refreshes (Pure Live behaviour).
  Future<void> _selectTab(_FollowTab tab) async {
    setState(() => _tab = tab);
    await _refresh();
  }

  LiveStatus _statusOf(LiveFollow follow) =>
      _statuses[follow.identityKey] ?? LiveStatus.unknown;

  List<LiveFollow> get _allFollows => LiveFollowStore.getAll();

  List<LiveFollow> get _liveFollows => _allFollows
      .where((f) => _statusOf(f) == LiveStatus.live)
      .toList();

  List<LiveFollow> get _notLiveFollows => _allFollows
      .where((f) => _statusOf(f) != LiveStatus.live)
      .toList();

  List<LiveFollow> get _visible {
    final base = _tab == _FollowTab.live ? _liveFollows : _notLiveFollows;
    final filter = _platformFilter;
    if (filter == null) return base;
    return base.where((f) => f.platform == filter).toList();
  }

  void _openFollow(LiveFollow follow) {
    if (widget.onOpenRoom != null) {
      widget.onOpenRoom!(follow);
      return;
    }
    Get.to(() => LiveRoomPage(room: follow.toRoom()));
  }

  void _goBrowse() {
    if (widget.onBrowse != null) {
      widget.onBrowse!();
      return;
    }
    Navigator.of(context).pop();
  }

  Future<void> _unfollow(LiveFollow follow) async {
    await LiveFollowStore.remove(follow.platform, follow.roomId);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final follows = _allFollows;
    final liveCount = _liveFollows.length;
    final notLiveCount = _notLiveFollows.length;
    final visible = _visible;
    final platforms = LiveFollowStore.followedPlatforms();
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(
        title: const Text('我的关注'),
        backgroundColor: theme.surface,
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 0),
            child: Row(
              children: [
                _TabButton(
                  label: '已开播',
                  count: liveCount,
                  selected: _tab == _FollowTab.live,
                  onTap: () => _selectTab(_FollowTab.live),
                ),
                const SizedBox(width: 8),
                _TabButton(
                  label: '未开播',
                  count: notLiveCount,
                  selected: _tab == _FollowTab.notLive,
                  onTap: () => _selectTab(_FollowTab.notLive),
                ),
                const Spacer(),
                if (_refreshing)
                  SizedBox(
                    width: 18,
                    height: 18,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: theme.accent,
                    ),
                  ),
              ],
            ),
          ),
          if (platforms.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  _PlatformChip(
                    label: '全部',
                    selected: _platformFilter == null,
                    onTap: () => setState(() => _platformFilter = null),
                  ),
                  for (final platform in platforms)
                    _PlatformChip(
                      label:
                          '${platformName(platform)} (${follows.where((f) => f.platform == platform).length})',
                      selected: _platformFilter == platform,
                      onTap: () =>
                          setState(() => _platformFilter = platform),
                    ),
                ],
              ),
            ),
          if (_failedCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(
                    Icons.warning_amber_outlined,
                    size: 14,
                    color: theme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$_failedCount 个状态获取失败',
                    style: TextStyle(
                      color: theme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: !_hasRefreshed
                ? const Center(child: CircularProgressIndicator())
                : follows.isEmpty
                    ? _EmptyState(
                        title: '还没有关注的主播',
                        subtitle: '关注主播后，在这里查看他们的开播状态',
                        onBrowse: _goBrowse,
                      )
                    : visible.isEmpty
                        ? _EmptyState(
                            title: _tab == _FollowTab.live
                                ? '没有正在开播的关注'
                                : '没有未开播的关注',
                            subtitle: _tab == _FollowTab.live
                                ? '关注的主播开播后会显示在这里'
                                : '关注的主播都在开播',
                            onBrowse: _goBrowse,
                          )
                        : RefreshIndicator(
                            onRefresh: _refresh,
                            child: GridView.builder(
                              padding: const EdgeInsets.all(12),
                              gridDelegate:
                                  const SliverGridDelegateWithFixedCrossAxisCount(
                                    crossAxisCount: 2,
                                    crossAxisSpacing: 12,
                                    mainAxisSpacing: 12,
                                    childAspectRatio: 16 / 10,
                                  ),
                              itemCount: visible.length,
                              itemBuilder: (context, i) {
                                final follow = visible[i];
                                return _FollowCard(
                                  follow: follow,
                                  status: _statusOf(follow),
                                  onTap: () => _openFollow(follow),
                                  onUnfollow: () => _unfollow(follow),
                                );
                              },
                            ),
                          ),
          ),
        ],
      ),
    );
  }
}

class _TabButton extends StatelessWidget {
  const _TabButton({
    required this.label,
    required this.count,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final int count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    // Glass capsule: selection is carried by the accent border +
    // accent bold text (the old accentSoft fill is the glass fill now
    // — a second fill under the glass would hide the blur).
    return GlassCard(
      radius: 999,
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 10),
      shadow: GlassShadow.none,
      borderColor: selected ? theme.accent : null,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: () {
            HaoHaptics.tap();
            onTap();
          },
          borderRadius: BorderRadius.circular(999),
          child: Text(
            '$label ($count)',
            style: TextStyle(
              color: selected ? theme.accent : theme.textSecondary,
              fontSize: 14,
              fontWeight: selected ? FontWeight.w700 : FontWeight.w500,
            ),
          ),
        ),
      ),
    );
  }
}

class _PlatformChip extends StatelessWidget {
  const _PlatformChip({
    required this.label,
    required this.selected,
    required this.onTap,
  });

  final String label;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: ChoiceChip(
        label: Text(label),
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
        onSelected: (_) => onTap(),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.title,
    required this.subtitle,
    required this.onBrowse,
  });

  final String title;
  final String subtitle;
  final VoidCallback onBrowse;

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
              child: Icon(
                Icons.favorite_border,
                size: 40,
                color: theme.accent,
              ),
            ),
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
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                color: theme.textSecondary,
                fontSize: 14,
                height: 1.5,
              ),
            ),
            const SizedBox(height: 20),
            FilledButton(
              onPressed: onBrowse,
              style: FilledButton.styleFrom(
                backgroundColor: theme.accent,
                foregroundColor:
                    Theme.of(context).colorScheme.onPrimary,
                padding: const EdgeInsets.symmetric(
                  horizontal: 24,
                  vertical: 12,
                ),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(999),
                ),
              ),
              child: const Text('去逛逛'),
            ),
          ],
        ),
      ),
    );
  }
}

/// One follow card — the live tab's room-card style (full-bleed cover,
/// LIVE badge top-left, title + anchor over a bottom scrim) with an
/// unfollow heart top-right. Tapping the card opens the room; tapping
/// the heart unfollows without opening it.
class _FollowCard extends StatelessWidget {
  const _FollowCard({
    required this.follow,
    required this.status,
    required this.onTap,
    required this.onUnfollow,
  });

  final LiveFollow follow;
  final LiveStatus status;
  final VoidCallback onTap;
  final VoidCallback onUnfollow;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Stack(
      fit: StackFit.expand,
      children: [
        InkWell(
          onTap: onTap,
          borderRadius: BorderRadius.circular(HaoRadius.panel),
          child: Container(
            decoration: BoxDecoration(
              // Theme surface so the tile adapts to all 8 combos
              // (was hard-coded 0xFF1C1C1E).
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
                if (follow.cover.isNotEmpty)
                  // Dio loader, not Image.network (v1.0.5 phone bug:
                  // plain NetworkImage shows blank).
                  RefererImage(
                    url: follow.cover,
                    fit: BoxFit.cover,
                    fallback: ColoredBox(
                      color: theme.surfaceSolid,
                    ),
                  )
                else
                  Center(
                    child: Icon(
                      Icons.live_tv_outlined,
                      color: theme.textMuted,
                      size: 32,
                    ),
                  ),
                // Over-cover scrim: black-alpha is deliberate so the
                // title stays readable over any cover in all 8 combos.
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
                Positioned(
                  top: 8,
                  left: 8,
                  child: LiveStatusBadge(status: status),
                ),
                Positioned(
                  left: 12,
                  right: 12,
                  bottom: 10,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        follow.title.isEmpty ? follow.nick : follow.title,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        '${follow.nick} · ${platformName(follow.platform)}',
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: Colors.white.withValues(alpha: 0.85),
                          fontSize: 12,
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
          top: 6,
          right: 6,
          // Frosted dark dot behind the heart so it stays legible
          // over bright covers in every theme/mode.
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
                icon: const Icon(
                  Icons.favorite,
                  color: Colors.white,
                  size: 20,
                ),
                tooltip: '取消关注',
                onPressed: onUnfollow,
              ),
            ),
          ),
        ),
      ],
    );
  }
}
