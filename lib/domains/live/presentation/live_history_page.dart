// Live watch history page (L01) — local history only.
//
// Entries from [LiveHistoryStore] (most recent first), grouped by day
// (今天 / 昨天 / 2–6 天前 / 更早), newest first. Top: a filter box
// (title / anchor / roomId / platform) + a refresh-online-status
// button (re-checks each entry's live status with a per-item timeout;
// failures are marked 状态未知, never stale-live) + limit setting +
// clear-all (confirm first). Each card has a single delete button and
// a follow toggle; tapping a card opens the room (and re-records it).
// Empty state is honest: "还没有直播观看记录".
//
// Pure Live reference: features/history/history_page.dart,
// history_sections.dart, history_refresh.dart, history_limit_dialog.dart.

import '../../../core/theme/hao_radius.dart';
import 'dart:async';

import 'package:flutter/cupertino.dart';
import '../../../widgets/hao_pressable.dart';
import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/theme/glass.dart';
import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/haptics.dart';
import '../../../features/video/widgets/referer_image.dart';
import '../../../widgets/glass_dialog.dart';
import '../../../widgets/hao_search_field.dart';
import '../../../shared/platforms/live_site.dart';
import '../live_follow_store.dart';
import '../live_history_retention.dart';
import '../live_history_store.dart';
import '../live_status.dart';
import 'live_status_badge.dart';
import 'playback/live_room_page.dart';

class LiveHistoryPage extends StatefulWidget {
  const LiveHistoryPage({super.key, this.siteOf, this.onOpenRoom});

  /// Injected for tests; defaults to the real platform adapters.
  final LiveSite Function(String platformId)? siteOf;

  /// Injected for tests; defaults to opening [LiveRoomPage].
  final void Function(LiveHistoryEntry entry)? onOpenRoom;

  @override
  State<LiveHistoryPage> createState() => _LiveHistoryPageState();
}

class _LiveHistoryPageState extends State<LiveHistoryPage> {
  String _query = '';
  Map<String, LiveStatus> _statuses = const {};
  bool _refreshing = false;
  int _failedCount = 0;

  List<LiveHistoryEntry> get _entries =>
      LiveHistoryStore.filter(LiveHistoryStore.getAll(), _query);

  Future<void> _refreshStatuses() async {
    if (_refreshing) return;
    setState(() {
      _refreshing = true;
      _failedCount = 0;
    });
    final entries = LiveHistoryStore.getAll();
    final statuses = await refreshRoomStatuses(
      entries.map((e) => e.toRoom()).toList(),
      siteOf: widget.siteOf,
    );
    if (!mounted) return;
    setState(() {
      _statuses = statuses;
      _refreshing = false;
      _failedCount = statuses.values
          .where((s) => s == LiveStatus.unknown)
          .length;
    });
    if (_failedCount > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('$_failedCount 个状态获取失败，请重试')),
      );
    }
  }

  void _openEntry(LiveHistoryEntry entry) {
    if (widget.onOpenRoom != null) {
      widget.onOpenRoom!(entry);
      return;
    }
    // Re-entering re-records the entry (moves it to the front).
    unawaited(LiveHistoryStore.recordEntry(entry));
    Get.to(() => LiveRoomPage(room: entry.toRoom()));
  }

  Future<void> _deleteEntry(LiveHistoryEntry entry) async {
    await LiveHistoryStore.remove(entry.platform, entry.roomId);
    if (mounted) setState(() {});
  }

  Future<void> _confirmClear() async {
    // Glass confirm, like every other destructive confirm in the app
    // (playlist delete, video history clear).
    final confirmed = await showGlassConfirmDialog(
      context,
      title: '清空直播历史？',
      content: '将删除全部直播观看记录，此操作无法恢复。',
      confirmLabel: '清空',
    );
    if (confirmed != true || !mounted) return;
    await LiveHistoryStore.clear();
    if (mounted) setState(() {});
  }

  Future<void> _showLimitDialog() async {
    const presets = [20, 50, 100, 200];
    var selected = LiveHistoryStore.limit;
    final customController = TextEditingController(
      text: presets.contains(selected) || selected == 0
          ? ''
          : '$selected',
    );
    // Glass dialog, like every other dialog in the app (glass_dialog
    // rule): same shell, same title/action styles as the glass
    // confirm; chips / field / warning are unchanged.
    final chosen = await showGlassDialog<int>(
      context,
      builder: (ctx) => StatefulBuilder(
        builder: (context, setDialogState) {
          final wouldDelete = LiveHistoryStore.wouldDeleteCount(selected);
          final theme = HaoTheme.of(context);
          return Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                '历史记录上限',
                style: TextStyle(
                  shadows: HaoTheme.legibilityShadows(context),
                  color: theme.textPrimary,
                  fontSize: 17,
                  fontWeight: FontWeight.w700,
                ),
              ),
              const SizedBox(height: 12),
              Wrap(
                  spacing: 8,
                  runSpacing: 8,
                  children: [
                    for (final p in presets)
                      ChoiceChip(
                        label: Text('$p 条'),
                        selected: selected == p,
                        selectedColor: theme.accentSoft,
                        shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(HaoRadius.panel),
                        ),
                        side: BorderSide(
                          color: selected == p
                              ? theme.accent
                              : theme.hairline,
                        ),
                        labelStyle: TextStyle(
                          shadows: HaoTheme.legibilityShadows(context),
                          color: selected == p
                              ? theme.accent
                              : theme.textSecondary,
                          fontWeight: selected == p
                              ? FontWeight.w700
                              : FontWeight.w500,
                        ),
                        onSelected: (_) {
                          setDialogState(() => selected = p);
                        },
                      ),
                    ChoiceChip(
                      label: const Text('不限'),
                      selected: selected == 0,
                      selectedColor: theme.accentSoft,
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(HaoRadius.panel),
                      ),
                      side: BorderSide(
                        color: selected == 0
                            ? theme.accent
                            : theme.hairline,
                      ),
                      labelStyle: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: selected == 0
                            ? theme.accent
                            : theme.textSecondary,
                        fontWeight: selected == 0
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                      onSelected: (_) {
                        setDialogState(() => selected = 0);
                      },
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: customController,
                  keyboardType: TextInputType.number,
                  decoration: const InputDecoration(
                    labelText: '自定义条数（0 = 不限）',
                    border: OutlineInputBorder(),
                  ),
                  onChanged: (value) {
                    final parsed = int.tryParse(value.trim());
                    if (parsed != null && parsed >= 0) {
                      setDialogState(() => selected = parsed);
                    }
                  },
                ),
                if (wouldDelete > 0) ...[
                  const SizedBox(height: 12),
                  Text(
                    '缩小上限将删除最旧的 $wouldDelete 条记录。',
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: theme.accent,
                      fontSize: 13,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ],
              const SizedBox(height: 16),
              Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(),
                    child: Text(
                      '取消',
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary),
                    ),
                  ),
                  TextButton(
                    onPressed: () => Navigator.of(context).pop(selected),
                    child: Text(
                      '确定',
                      style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.accent),
                    ),
                  ),
                ],
              ),
            ],
          );
        },
      ),
    );
    customController.dispose();
    if (chosen == null || !mounted) return;
    await LiveHistoryStore.setLimit(chosen);
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final all = LiveHistoryStore.getAll();
    final entries = _entries;
    final groups = LiveHistoryStore.grouped(entries);
    final limitLabel = LiveHistoryStore.limit == 0
        ? '不限'
        : '${LiveHistoryStore.limit} 条';
    final retention = liveHistoryRetention();
    return Scaffold(
      appBar: AppBar(
        title: Text('直播历史', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
        actions: [
          IconButton(
            icon: _refreshing
                ? const SizedBox(
                    width: 20,
                    height: 20,
                    child: CupertinoActivityIndicator(),
                  )
                : Icon(shadows: HaoTheme.legibilityShadows(context), Icons.refresh),
            tooltip: '刷新在线状态',
            onPressed: _refreshing ? null : _refreshStatuses,
          ),
          IconButton(
            icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.delete_outline),
            tooltip: '清空历史记录',
            onPressed: all.isEmpty ? null : _confirmClear,
          ),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 4),
            child: HaoSearchField(
              hintText: '搜索标题 / 主播 / 房间号 / 平台',
              onChanged: (value) => setState(() => _query = value),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 4, 14, 0),
            child: Row(
              children: [
                Text(
                  all.isEmpty
                      ? '共 0 条'
                      : '共 ${all.length} 条 · 上限 $limitLabel',
                  style: TextStyle(
                    shadows: HaoTheme.legibilityShadows(context),
                    color: theme.textMuted,
                    fontSize: 13,
                  ),
                ),
                const Spacer(),
                TextButton(
                  onPressed: _showLimitDialog,
                  child: Text(
                    '上限设置',
                    style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.accent, fontSize: 13),
                  ),
                ),
              ],
            ),
          ),
          // Build-29 item 11b: retention period. Shrinking it prunes
          // expired entries at once (the count is shown before
          // confirming, like the limit dialog).
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 0, 14, 0),
            child: Row(
              children: [
                Text(
                  '保留期',
                  style: TextStyle(
                    shadows: HaoTheme.legibilityShadows(context),
                    color: theme.textMuted,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(width: 8),
                Expanded(
                  child: SingleChildScrollView(
                    scrollDirection: Axis.horizontal,
                    child: Row(
                      children: [
                        for (final r in LiveHistoryRetention.values)
                          Padding(
                            padding: const EdgeInsets.only(right: 6),
                            child: ChoiceChip(
                              label: Text(r.label),
                              selected: retention == r,
                              selectedColor: theme.accentSoft,
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(
                                  HaoRadius.panel,
                                ),
                              ),
                              side: BorderSide(
                                color: retention == r
                                    ? theme.accent
                                    : theme.hairline,
                              ),
                              labelStyle: TextStyle(
                                shadows: HaoTheme.legibilityShadows(context),
                                color: retention == r
                                    ? theme.accent
                                    : theme.textSecondary,
                                fontSize: 12,
                                fontWeight: retention == r
                                    ? FontWeight.w700
                                    : FontWeight.w500,
                              ),
                              onSelected: (_) async {
                                final wouldDelete = retentionWouldDelete(
                                  LiveHistoryStore.getAll(),
                                  r.days,
                                );
                                if (wouldDelete > 0) {
                                  final confirmed =
                                      await showGlassConfirmDialog(
                                        context,
                                        title: '缩短保留期？',
                                        content:
                                            '将删除超过 ${r.label}的最旧 $wouldDelete 条记录，此操作无法恢复。',
                                        confirmLabel: '删除并切换',
                                      );
                                  if (confirmed != true) return;
                                }
                                await setLiveHistoryRetention(r);
                                await LiveHistoryStore.pruneExpired();
                                if (mounted) setState(() {});
                              },
                            ),
                          ),
                      ],
                    ),
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
            child: all.isEmpty
                ? Center(
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
                            Icons.live_tv_outlined,
                            size: 40,
                            color: theme.accent,
                          ),
                        ),
                        const SizedBox(height: 16),
                        Text(
                          '还没有直播观看记录',
                          style: TextStyle(
                            shadows: HaoTheme.legibilityShadows(context),
                            color: theme.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  )
                : entries.isEmpty
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Icon(
                              shadows: HaoTheme.legibilityShadows(context),
                              Icons.search_off_outlined,
                              size: 40,
                              color: theme.textMuted,
                            ),
                            const SizedBox(height: 12),
                            Text(
                              '没有匹配的记录',
                              style: TextStyle(
                                shadows: HaoTheme.legibilityShadows(context),
                                color: theme.textSecondary,
                                fontSize: 15,
                              ),
                            ),
                          ],
                        ),
                      )
                    : ListView.builder(
                        padding: const EdgeInsets.fromLTRB(14, 4, 14, 16),
                        itemCount: groups.fold<int>(
                          0,
                          (sum, g) => sum + 1 + g.$2.length,
                        ),
                        itemBuilder: (context, index) {
                          var remaining = index;
                          for (final (section, items) in groups) {
                            if (remaining == 0) {
                              return _SectionHeader(label: section.label);
                            }
                            remaining -= 1;
                            if (remaining < items.length) {
                              final entry = items[remaining];
                              return _HistoryCard(
                                entry: entry,
                                status: _statuses[entry.identityKey],
                                onTap: () => _openEntry(entry),
                                onDelete: () => _deleteEntry(entry),
                                onFollowChanged: () =>
                                    setState(() {}),
                              );
                            }
                            remaining -= items.length;
                          }
                          return const SizedBox.shrink();
                        },
                      ),
          ),
        ],
      ),
    );
  }
}

class _SectionHeader extends StatelessWidget {
  const _SectionHeader({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(2, 16, 2, 8),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 14,
            decoration: BoxDecoration(
              color: theme.accent,
              borderRadius: BorderRadius.circular(HaoRadius.badge),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              shadows: HaoTheme.legibilityShadows(context),
              color: theme.textPrimary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 1.2,
            ),
          ),
        ],
      ),
    );
  }
}

/// One history card: 16:9 thumb, title, anchor + platform + time, a
/// live-status badge (only shown after a refresh), a follow toggle and
/// a single delete button. Tapping the card opens the room.
class _HistoryCard extends StatefulWidget {
  const _HistoryCard({
    required this.entry,
    required this.status,
    required this.onTap,
    required this.onDelete,
    required this.onFollowChanged,
  });

  final LiveHistoryEntry entry;
  final LiveStatus? status;
  final VoidCallback onTap;
  final VoidCallback onDelete;
  final VoidCallback onFollowChanged;

  @override
  State<_HistoryCard> createState() => _HistoryCardState();
}

class _HistoryCardState extends State<_HistoryCard> {
  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final entry = widget.entry;
    final followed = LiveFollowStore.isFollowed(
      entry.platform,
      entry.roomId,
    );
    return GlassCard(
      radius: 16,
      padding: const EdgeInsets.all(12),
      margin: const EdgeInsets.only(bottom: 12),
      child: Material(
        color: Colors.transparent,
        child: HaoPressable(
          onTap: () {
            HaoHaptics.tap();
            widget.onTap();
          },
          borderRadius: BorderRadius.circular(HaoRadius.large),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                width: 120,
                child: AspectRatio(
                  aspectRatio: 16 / 9,
                  child: Container(
                    decoration: BoxDecoration(
                      // Theme surface (was hard-coded 0xFF1C1C1E).
                      color: theme.surfaceSolid,
                      borderRadius: BorderRadius.circular(HaoRadius.standard),
                    ),
                    clipBehavior: Clip.antiAlias,
                    child: Stack(
                      fit: StackFit.expand,
                      children: [
                        if (entry.cover.isNotEmpty)
                          // Dio loader, not Image.network (v1.0.5 phone
                          // bug: plain NetworkImage shows blank).
                          RefererImage(
                            url: entry.cover,
                            fit: BoxFit.cover,
                            fallback: ColoredBox(
                              color: theme.surfaceSolid,
                            ),
                          )
                        else
                          Icon(
                            Icons.live_tv_outlined, shadows: HaoTheme.legibilityShadows(context), 
                            color: theme.textMuted,
                            size: 28,
                          ),
                        if (widget.status != null)
                          Positioned(
                            top: 6,
                            left: 6,
                            child: LiveStatusBadge(
                              status: widget.status!,
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      entry.title.isEmpty ? entry.nick : entry.title,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        height: 1.35,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      '${entry.nick} · ${platformName(entry.platform)}',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      _formatTime(entry.atDate),
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  IconButton(
                    icon: Icon(
                      shadows: HaoTheme.legibilityShadows(context),
                      followed ? Icons.favorite : Icons.favorite_border,
                      color: followed ? theme.accent : theme.textMuted,
                      size: 20,
                    ),
                    tooltip: followed ? '取消关注' : '关注',
                    onPressed: () async {
                      await LiveFollowStore.toggle(entry.toRoom());
                      widget.onFollowChanged();
                      if (mounted) setState(() {});
                    },
                  ),
                  IconButton(
                    icon: Icon(
                      shadows: HaoTheme.legibilityShadows(context),
                      Icons.close,
                      color: theme.textMuted,
                      size: 20,
                    ),
                    tooltip: '删除这条记录',
                    onPressed: widget.onDelete,
                  ),
                ],
              ),
            ],
          ),
        ),
      ),
    );
  }
}

String _formatTime(DateTime at) {
  final now = DateTime.now();
  final today = DateTime(now.year, now.month, now.day);
  final day = DateTime(at.year, at.month, at.day);
  final diff = today.difference(day).inDays;
  final hm =
      '${at.hour.toString().padLeft(2, '0')}:${at.minute.toString().padLeft(2, '0')}';
  if (diff <= 0) return '今天 $hm';
  if (diff == 1) return '昨天 $hm';
  return '${at.month}月${at.day}日 $hm';
}
