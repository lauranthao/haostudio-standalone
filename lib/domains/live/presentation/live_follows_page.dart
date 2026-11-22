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
import 'package:flutter/cupertino.dart';
import '../../../widgets/hao_pressable.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/haptics.dart';
import '../../../core/theme/glass.dart';
import '../../../features/video/widgets/referer_image.dart';
import '../../../widgets/native_switch.dart';
import '../../../shared/platforms/live_site.dart';
import '../live_follow_refresh.dart';
import '../live_follow_store.dart';
import '../live_follow_visibility.dart';
import '../live_metrics.dart';
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

  /// Null = 全部分组; '' = 未分组; otherwise a group name.
  String? _groupFilter;
  Map<String, LiveStatus> _statuses = const {};
  Map<String, int> _watching = const {};

  // Build-29 item 1: the refresh state machine — unknown preview
  // at start, one round at a time, one snapshot per round, failure
  // cooldown (auto triggers dropped, manual pull bypasses it).
  late final LiveFollowRefreshController<({LiveStatus status, int watching})>
  _refreshCtl;

  @override
  void initState() {
    super.initState();
    _refreshCtl =
        LiveFollowRefreshController<({LiveStatus status, int watching})>(
          fetch: () async {
            final follows = LiveFollowStore.getAll();
            final statuses = await refreshRoomStatusesWithWatching(
              follows.map((f) => f.toRoom()).toList(),
              siteOf: widget.siteOf,
            );
            return (
              statuses,
              statuses.values
                  .where((v) => v.status == LiveStatus.unknown)
                  .length,
            );
          },
        );
    _refresh();
  }

  /// Run a refresh round through the state machine. Returns false
  /// when the trigger was dropped (a round already running, or an
  /// automatic trigger inside the failure cooldown). Manual
  /// pull-to-refresh passes [manual] = true and always runs.
  Future<void> _refresh({bool manual = false}) async {
    final future = _refreshCtl.tryStartRound(manual: manual);
    // The controller flips to refreshing synchronously inside
    // tryStartRound — show the spinner even before the fetch lands.
    if (mounted) setState(() {});
    final started = await future;
    if (!started || !mounted) return;
    final snapshot = _refreshCtl.snapshot;
    if (snapshot == null) return;
    setState(() {
      _statuses = snapshot.values.map((k, v) => MapEntry(k, v.status));
      _watching = snapshot.values.map((k, v) => MapEntry(k, v.watching));
    });
  }

  bool get _refreshing => _refreshCtl.isRefreshing;
  bool get _hasRefreshed =>
      _refreshCtl.phase != FollowRefreshPhase.unknown;
  int get _failedCount => _refreshCtl.snapshot?.failedCount ?? 0;

  /// Tapping a tab re-refreshes (Pure Live behaviour) — through the
  /// state machine, so a tap inside the failure cooldown is dropped
  /// instead of hammering the adapters.
  Future<void> _selectTab(_FollowTab tab) async {
    setState(() => _tab = tab);
    await _refresh();
  }

  LiveStatus _statusOf(LiveFollow follow) =>
      _statuses[follow.identityKey] ?? LiveStatus.unknown;

  /// Visible follows: hidden platforms (item 11a) are excluded
  /// without deleting anything.
  List<LiveFollow> get _allFollows => LiveFollowVisibility.visibleFollows(
    LiveFollowStore.getAll(),
    LiveFollowVisibility.hiddenPlatforms(),
    platformOf: (f) => f.platform,
  );

  List<LiveFollow> get _liveFollows => _allFollows
      .where((f) => _statusOf(f) == LiveStatus.live)
      .toList();

  List<LiveFollow> get _notLiveFollows => _allFollows
      .where((f) => _statusOf(f) != LiveStatus.live)
      .toList();

  List<LiveFollow> get _visible {
    final base = _tab == _FollowTab.live ? _liveFollows : _notLiveFollows;
    var list = base;
    final filter = _platformFilter;
    if (filter != null) {
      list = list.where((f) => f.platform == filter).toList();
    }
    final group = _groupFilter;
    if (group != null) {
      list = list.where((f) => f.group == group).toList();
    }
    return list;
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

  /// Build-29 item 7: unfollow removes the row locally ONLY — it
  /// never triggers a full status refresh (no adapter calls, no
  /// spinner, the other cards' statuses are untouched).
  Future<void> _unfollow(LiveFollow follow) async {
    await LiveFollowStore.remove(follow.platform, follow.roomId);
    if (mounted) setState(() {});
  }

  /// Build-29 item 5: assign [follow] to a group (or 未分组). The
  /// sheet lists existing groups + a new-group field; picking one
  /// only rewrites that follow's group, nothing else.
  Future<void> _showGroupSheet(LiveFollow follow) async {
    final groups = LiveFollowStore.groups();
    final controller = TextEditingController();
    final picked = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) {
        final theme = HaoTheme.of(sheetContext);
        return Container(
          decoration: BoxDecoration(
            color: theme.surfaceSolid,
            borderRadius: const BorderRadius.vertical(
              top: Radius.circular(20),
            ),
          ),
          padding: EdgeInsets.only(
            left: 20,
            right: 20,
            top: 8,
            bottom:
                MediaQuery.of(sheetContext).viewInsets.bottom + 24,
          ),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '移到分组',
                style: TextStyle(
                  shadows: HaoTheme.legibilityShadows(sheetContext),
                  color: theme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w800,
                ),
              ),
              const SizedBox(height: 12),
              ListTile(
                title: Text(
                  '未分组',
                  style: TextStyle(color: theme.textPrimary),
                ),
                trailing: follow.group.isEmpty
                    ? Icon(shadows: HaoTheme.legibilityShadows(context), Icons.check, color: theme.accent)
                    : null,
                onTap: () => Navigator.of(sheetContext).pop(''),
              ),
              for (final g in groups)
                ListTile(
                  title: Text(
                    g,
                    style: TextStyle(color: theme.textPrimary),
                  ),
                  trailing: follow.group == g
                      ? Icon(shadows: HaoTheme.legibilityShadows(context), Icons.check, color: theme.accent)
                      : null,
                  onTap: () => Navigator.of(sheetContext).pop(g),
                ),
              const SizedBox(height: 8),
              TextField(
                controller: controller,
                decoration: const InputDecoration(
                  hintText: '新建分组…',
                  border: OutlineInputBorder(),
                  contentPadding: EdgeInsets.symmetric(
                    horizontal: 12,
                    vertical: 10,
                  ),
                ),
                textInputAction: TextInputAction.done,
                onSubmitted: (v) => Navigator.of(sheetContext).pop(v),
              ),
              const SizedBox(height: 12),
              SizedBox(
                width: double.infinity,
                child: FilledButton(
                  onPressed: () =>
                      Navigator.of(sheetContext).pop(controller.text),
                  style: FilledButton.styleFrom(
                    backgroundColor: theme.accent,
                    foregroundColor: Theme.of(
                      sheetContext,
                    ).colorScheme.onPrimary,
                  ),
                  child: const Text('确定'),
                ),
              ),
            ],
          ),
        );
      },
    );
    if (picked == null) return;
    final group = picked.trim();
    if (group == follow.group) return;
    await LiveFollowStore.setGroup(follow.platform, follow.roomId, group);
    if (mounted) setState(() {});
  }

  /// Build-29 item 11a: per-platform show/hide for the follow list.
  /// Hiding never deletes follows and never touches the global
  /// live-source enablement in Settings.
  Future<void> _showVisibilitySheet() async {
    final platforms = LiveFollowStore.followedPlatforms();
    await showModalBottomSheet<void>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      backgroundColor: Colors.transparent,
      builder: (sheetContext) => StatefulBuilder(
        builder: (context, setSheetState) {
          final theme = HaoTheme.of(context);
          final hidden = LiveFollowVisibility.hiddenPlatforms();
          return Container(
            decoration: BoxDecoration(
              color: theme.surfaceSolid,
              borderRadius: const BorderRadius.vertical(
                top: Radius.circular(20),
              ),
            ),
            padding: const EdgeInsets.fromLTRB(8, 8, 8, 24),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    '关注按平台显示',
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: theme.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  child: Text(
                    '隐藏的平台不在关注列表显示，关注本身不会被删除',
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: theme.textMuted,
                      fontSize: 13,
                    ),
                  ),
                ),
                for (final p in platforms)
                  HaoSwitchRow(
                    title: platformName(p),
                    value: !hidden.contains(p),
                    onChanged: (show) async {
                      await LiveFollowVisibility.setHidden(p, !show);
                      setSheetState(() {});
                      if (mounted) setState(() {});
                    },
                  ),
              ],
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final follows = _allFollows;
    final liveCount = _liveFollows.length;
    final notLiveCount = _notLiveFollows.length;
    final visible = _visible;
    final platforms = LiveFollowStore.followedPlatforms();
    final groups = LiveFollowStore.groups();
    final hiddenCount = LiveFollowVisibility.hiddenPlatforms().length;
    return Scaffold(
      appBar: AppBar(
        title: Text('我的关注', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
        actions: [
          IconButton(
            icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.visibility_off_outlined),
            tooltip: '按平台显示',
            onPressed: _showVisibilitySheet,
          ),
        ],
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
                    child: CupertinoActivityIndicator(
                      radius: 9,
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
          // Build-29 item 5: group filter chips (全部 / 未分组 / 各组).
          // Long-press a card to move that follow into a group.
          if (groups.isNotEmpty)
            SizedBox(
              height: 48,
              child: ListView(
                scrollDirection: Axis.horizontal,
                padding: const EdgeInsets.symmetric(horizontal: 10),
                children: [
                  _PlatformChip(
                    label: '全部分组',
                    selected: _groupFilter == null,
                    onTap: () => setState(() => _groupFilter = null),
                  ),
                  _PlatformChip(
                    label:
                        '未分组 (${follows.where((f) => f.group.isEmpty).length})',
                    selected: _groupFilter == '',
                    onTap: () => setState(() => _groupFilter = ''),
                  ),
                  for (final group in groups)
                    _PlatformChip(
                      label:
                          '$group (${follows.where((f) => f.group == group).length})',
                      selected: _groupFilter == group,
                      onTap: () => setState(() => _groupFilter = group),
                    ),
                ],
              ),
            ),
          if (hiddenCount > 0)
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14),
              child: Row(
                children: [
                  Icon(
                    shadows: HaoTheme.legibilityShadows(context),
                    Icons.visibility_off_outlined,
                    size: 14,
                    color: theme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '已隐藏 $hiddenCount 个平台的关注',
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: theme.textMuted,
                      fontSize: 12,
                    ),
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
                    shadows: HaoTheme.legibilityShadows(context),
                    Icons.warning_amber_outlined,
                    size: 14,
                    color: theme.textMuted,
                  ),
                  const SizedBox(width: 4),
                  Text(
                    '$_failedCount 个状态获取失败',
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: theme.textMuted,
                      fontSize: 12,
                    ),
                  ),
                ],
              ),
            ),
          Expanded(
            child: !_hasRefreshed
                ? const Center(child: CupertinoActivityIndicator())
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
                        : CustomScrollView(
                            slivers: [
                              CupertinoSliverRefreshControl(
                                // Manual pull bypasses the failure
                                // cooldown (item 1).
                                onRefresh: () => _refresh(manual: true),
                              ),
                              SliverPadding(
                                padding: const EdgeInsets.all(12),
                                sliver: SliverGrid(
                                  gridDelegate:
                                      const SliverGridDelegateWithFixedCrossAxisCount(
                                        crossAxisCount: 2,
                                        crossAxisSpacing: 12,
                                        mainAxisSpacing: 12,
                                        childAspectRatio: 16 / 10,
                                      ),
                                  delegate: SliverChildBuilderDelegate(
                                    (context, i) {
                                final follow = visible[i];
                                return _FollowCard(
                                  follow: follow,
                                  status: _statusOf(follow),
                                  watching: _watching[follow.identityKey] ?? 0,
                                  onTap: () => _openFollow(follow),
                                  onUnfollow: () => _unfollow(follow),
                                  onGroup: () => _showGroupSheet(follow),
                                );
                                    },
                                    childCount: visible.length,
                                  ),
                                ),
                              ),
                            ],
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
        child: HaoPressable(
          onTap: () {
            HaoHaptics.tap();
            onTap();
          },
          borderRadius: BorderRadius.circular(999),
          child: Text(
            '$label ($count)',
            style: TextStyle(
              shadows: HaoTheme.legibilityShadows(context),
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
          shadows: HaoTheme.legibilityShadows(context),
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
                shadows: HaoTheme.legibilityShadows(context),
                Icons.favorite_border,
                size: 40,
                color: theme.accent,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              title,
              style: TextStyle(
                shadows: HaoTheme.legibilityShadows(context),
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
                shadows: HaoTheme.legibilityShadows(context),
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
/// the heart unfollows without opening it; long-press moves the
/// follow into a group (item 5).
class _FollowCard extends StatelessWidget {
  const _FollowCard({
    required this.follow,
    required this.status,
    this.watching = 0,
    required this.onTap,
    required this.onUnfollow,
    required this.onGroup,
  });

  final LiveFollow follow;
  final LiveStatus status;

  /// Watching count from the same fresh detail the status came from
  /// (0 = unknown/offline — no pill, same rule as the live tab).
  final int watching;
  final VoidCallback onTap;
  final VoidCallback onUnfollow;

  /// Long-press: open the group picker for this follow.
  final VoidCallback onGroup;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      onLongPress: onGroup,
      child: Stack(
      fit: StackFit.expand,
      children: [
        HaoPressable(
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
                      Icons.live_tv_outlined, shadows: HaoTheme.legibilityShadows(context), 
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
                // Watching pill (B-P1-1): same style/position as the
                // live tab's card (bottom-right, black-alpha pill).
                // Shown only when the count is known and > 0.
                if (watching > 0)
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
                            metricLabelFor(follow.platform, watching),
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
                      // B-P1-1: same rule as the live tab's card — an
                      // empty title renders one nick line only; the
                      // second line is skipped, so the nick never
                      // shows twice.
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
                      if (follow.title.isNotEmpty) ...[
                        const SizedBox(height: 2),
                        Text(
                          '${follow.nick} · ${platformName(follow.platform)}${follow.group.isEmpty ? '' : ' · ${follow.group}'}',
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: Colors.white.withValues(alpha: 0.85),
                            fontSize: 12,
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
                icon: Icon(
                  Icons.favorite, shadows: HaoTheme.legibilityShadows(context), 
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
      ),
    );
  }
}
