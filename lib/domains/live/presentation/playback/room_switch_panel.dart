// Switch-room panel (L04) — bottom sheet inside a live room.
//
// Pure Live's `room_switch_panel.dart` / `room_switch_tiles.dart`:
// groups in order — live follows (by popularity), the room's source
// list, watch history, replay follows — with a header (refresh +
// last refresh time + filter box). Tapping a room switches to it;
// the current room is highlighted.
//
// This app's groups:
// - 关注: live follows only, by popularity (watching desc). The
//   follow store keeps no watching count, so opening / refreshing
//   the panel re-checks each follow's own detail (one
//   `getRoomDetail` per follow, 8 s timeout each, concurrent) and
//   keeps only the live ones — never "on the hot page" membership.
//   Before the first check lands the group shows a loading row.
// - 当前列表: the playlist the room was opened with (the live tab's
//   room list); empty-state when the room was opened without one.
// - 历史: [LiveHistoryStore] (L01), most recent first.
// - 回放关注: empty-state — replay follows do not exist yet (L14).
//
// The sheet never fakes rooms: every group with no data shows an
// honest empty state.

import 'dart:async';

import 'package:flutter/material.dart';

import '../../../../core/models/live_models.dart';
import '../../../../core/theme/hao_themes.dart';
import '../../../../core/theme/glass.dart';
import '../../../../features/video/widgets/referer_image.dart';
import '../../../../shared/platforms/sites.dart';
import '../../live_follow_store.dart';
import '../../live_history_store.dart';
import '../../live_status.dart';

/// Open the switch-room sheet. [onSelect] runs AFTER the sheet is
/// popped; the caller navigates (replacing the room page).
/// [detailOf] is a test seam for the follows refresh; production
/// passes none and uses the platform adapter's `getRoomDetail`.
Future<void> showRoomSwitchPanel({
  required BuildContext context,
  required LiveRoom currentRoom,
  required List<LiveRoom> playlist,
  required ValueChanged<LiveRoom> onSelect,
  Future<LiveRoom> Function(LiveRoom room)? detailOf,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (context) => GlassSheetBackground(
      child: _RoomSwitchPanel(
      currentRoom: currentRoom,
      playlist: playlist,
      onSelect: (room) {
        Navigator.of(context).pop();
        onSelect(room);
      },
      detailOf: detailOf,
      ),
    ),
  );
}

class _RoomSwitchPanel extends StatefulWidget {
  const _RoomSwitchPanel({
    required this.currentRoom,
    required this.playlist,
    required this.onSelect,
    this.detailOf,
  });

  final LiveRoom currentRoom;
  final List<LiveRoom> playlist;
  final ValueChanged<LiveRoom> onSelect;
  final Future<LiveRoom> Function(LiveRoom room)? detailOf;

  @override
  State<_RoomSwitchPanel> createState() => _RoomSwitchPanelState();
}

class _RoomSwitchPanelState extends State<_RoomSwitchPanel> {
  String _query = '';
  List<LiveRoom>? _liveFollows;
  DateTime? _lastRefresh;
  bool _refreshingFollows = false;

  @override
  void initState() {
    super.initState();
    _refreshFollows();
  }

  /// Re-check each follow's own detail; keep live ones by
  /// popularity. A timed-out / failed check drops that follow from
  /// this refresh (never stale-live, never a crash).
  Future<void> _refreshFollows() async {
    if (_refreshingFollows) return;
    setState(() => _refreshingFollows = true);
    final follows = LiveFollowStore.getAll().map((f) => f.toRoom()).toList();
    final detailOf = widget.detailOf;
    final checked = await Future.wait(
      follows.map((room) async {
        try {
          final detail = detailOf != null
              ? await detailOf(room).timeout(const Duration(seconds: 8))
              : await Sites.of(room.platform)
                    .getRoomDetail(room)
                    .timeout(const Duration(seconds: 8));
          return detail.liveStatus ? detail : null;
        } catch (_) {
          return null;
        }
      }),
    );
    if (!mounted) return;
    final live = checked.whereType<LiveRoom>().toList()
      ..sort((a, b) => b.watching.compareTo(a.watching));
    setState(() {
      _liveFollows = live;
      _lastRefresh = DateTime.now();
      _refreshingFollows = false;
    });
  }

  bool _matches(LiveRoom room) {
    final q = _query.trim().toLowerCase();
    if (q.isEmpty) return true;
    if (room.title.toLowerCase().contains(q)) return true;
    if (room.nick.toLowerCase().contains(q)) return true;
    if (room.roomId.toLowerCase().contains(q)) return true;
    if (platformName(room.platform).toLowerCase().contains(q)) return true;
    return false;
  }

  bool _isCurrent(LiveRoom room) =>
      room.platform == widget.currentRoom.platform &&
      room.roomId == widget.currentRoom.roomId;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final history = LiveHistoryStore.getAll()
        .map((e) => e.toRoom())
        .where(_matches)
        .toList();
    final currentList = widget.playlist.where(_matches).toList();
    final follows = _liveFollows?.where(_matches).toList();
    return SizedBox(
      height: MediaQuery.sizeOf(context).height * 0.75,
      child: Column(
        children: [
          // Header: title + refresh + last refresh time + filter.
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
            child: Row(
              children: [
                Text(
                  '切换直播间',
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 18,
                    fontWeight: FontWeight.w700,
                  ),
                ),
                const Spacer(),
                if (_lastRefresh != null)
                  Text(
                    '上次刷新 ${_formatTime(_lastRefresh!)}',
                    style: TextStyle(color: theme.textMuted, fontSize: 12),
                  ),
                IconButton(
                  icon: _refreshingFollows
                      ? SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: theme.accent,
                          ),
                        )
                      : Icon(Icons.refresh, color: theme.accent),
                  tooltip: '刷新',
                  onPressed: _refreshingFollows ? null : _refreshFollows,
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: GlassCard(
              radius: 14,
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: TextField(
                decoration: InputDecoration(
                  hintText: '筛选：标题 / 主播 / 房间号',
                  hintStyle: TextStyle(color: theme.textMuted),
                  prefixIcon: Icon(Icons.search, color: theme.textMuted),
                  border: InputBorder.none,
                  enabledBorder: InputBorder.none,
                  focusedBorder: InputBorder.none,
                  contentPadding: const EdgeInsets.symmetric(vertical: 12),
                ),
                style: TextStyle(color: theme.textPrimary),
                onChanged: (v) => setState(() => _query = v),
              ),
            ),
          ),
          const SizedBox(height: 8),
          Expanded(
            child: ListView(
              padding: const EdgeInsets.symmetric(horizontal: 16),
              children: [
                _GroupTitle(title: '关注', theme: theme),
                if (follows == null)
                  _LoadingRow(theme: theme)
                else if (follows.isEmpty)
                  _EmptyRow(
                    text: '关注的主播当前均未开播',
                    theme: theme,
                  )
                else
                  for (final room in follows)
                    _RoomRow(
                      room: room,
                      isCurrent: _isCurrent(room),
                      onTap: () => widget.onSelect(room),
                    ),
                _GroupTitle(title: '当前列表', theme: theme),
                if (currentList.isEmpty)
                  _EmptyRow(
                    text: '当前列表为空',
                    theme: theme,
                  )
                else
                  for (final room in currentList)
                    _RoomRow(
                      room: room,
                      isCurrent: _isCurrent(room),
                      onTap: () => widget.onSelect(room),
                    ),
                _GroupTitle(title: '历史', theme: theme),
                if (history.isEmpty)
                  _EmptyRow(text: '暂无观看历史', theme: theme)
                else
                  for (final room in history)
                    _RoomRow(
                      room: room,
                      isCurrent: _isCurrent(room),
                      onTap: () => widget.onSelect(room),
                    ),
                _GroupTitle(title: '回放关注', theme: theme),
                _EmptyRow(text: '暂无回放关注', theme: theme),
                const SizedBox(height: 24),
              ],
            ),
          ),
        ],
      ),
    );
  }

  static String _formatTime(DateTime t) {
    String two(int v) => v.toString().padLeft(2, '0');
    return '${two(t.hour)}:${two(t.minute)}:${two(t.second)}';
  }
}

class _GroupTitle extends StatelessWidget {
  const _GroupTitle({required this.title, required this.theme});

  final String title;
  final HaoTheme theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 6),
      child: Row(
        children: [
          Container(
            width: 3,
            height: 13,
            decoration: BoxDecoration(
              color: theme.accent,
              borderRadius: BorderRadius.circular(2),
            ),
          ),
          const SizedBox(width: 8),
          Text(
            title,
            style: TextStyle(
              color: theme.textSecondary,
              fontSize: 13,
              fontWeight: FontWeight.w700,
              letterSpacing: 0.8,
            ),
          ),
        ],
      ),
    );
  }
}

class _LoadingRow extends StatelessWidget {
  const _LoadingRow({required this.theme});

  final HaoTheme theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Row(
        children: [
          SizedBox(
            width: 16,
            height: 16,
            child: CircularProgressIndicator(
              strokeWidth: 2,
              color: theme.accent,
            ),
          ),
          const SizedBox(width: 10),
          Text(
            '正在检查开播状态…',
            style: TextStyle(color: theme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }
}

class _EmptyRow extends StatelessWidget {
  const _EmptyRow({required this.text, required this.theme});

  final String text;
  final HaoTheme theme;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Text(
        text,
        style: TextStyle(color: theme.textMuted, fontSize: 13),
      ),
    );
  }
}

/// One room row: 16:9 cover + title + nick + watching. The current
/// room gets an accent left border + a "当前" tag.
class _RoomRow extends StatelessWidget {
  const _RoomRow({
    required this.room,
    required this.isCurrent,
    required this.onTap,
  });

  final LiveRoom room;
  final bool isCurrent;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final onAccent = Theme.of(context).colorScheme.onPrimary;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 4),
      child: Material(
        color: isCurrent ? theme.accentSoft : theme.surface,
        // NOTE: do NOT pass borderRadius here — Material asserts
        // !(shape != null && borderRadius != null), and the border
        // side lives in `shape` (its RoundedRectangleBorder already
        // carries the same 14 radius).
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: isCurrent
                ? theme.accent.withValues(alpha: 0.45)
                : theme.hairline,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Container(
            decoration: BoxDecoration(
              border: Border(
                left: BorderSide(
                  color: isCurrent ? theme.accent : Colors.transparent,
                  width: 3,
                ),
              ),
            ),
            padding: const EdgeInsets.all(10),
            child: Row(
              children: [
                ClipRRect(
                  borderRadius: BorderRadius.circular(10),
                  child: room.cover.isEmpty
                      ? Container(
                          width: 96,
                          height: 54,
                          color: theme.surfaceSolid,
                          child: Icon(
                            Icons.live_tv_outlined,
                            color: theme.textMuted,
                          ),
                        )
                      // Dio loader, not Image.network (v1.0.5 phone
                      // bug: plain NetworkImage shows blank).
                      : RefererImage(
                          url: room.cover,
                          width: 96,
                          height: 54,
                          fit: BoxFit.cover,
                          fallback: Container(
                            width: 96,
                            height: 54,
                            color: theme.surfaceSolid,
                            child: Icon(
                              Icons.live_tv_outlined,
                              color: theme.textMuted,
                            ),
                          ),
                        ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Row(
                        children: [
                          Expanded(
                            child: Text(
                              room.title.isEmpty ? room.nick : room.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.textPrimary,
                                fontSize: 15,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                          ),
                          if (isCurrent)
                            Container(
                              margin: const EdgeInsets.only(left: 6),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 7,
                                vertical: 3,
                              ),
                              decoration: BoxDecoration(
                                color: theme.accent,
                                borderRadius: BorderRadius.circular(6),
                              ),
                              child: Text(
                                '当前',
                                style: TextStyle(
                                  // onPrimary: white on bright gold/ice
                                  // accents is unreadable in dark mode.
                                  color: onAccent,
                                  fontSize: 10,
                                  fontWeight: FontWeight.bold,
                                  letterSpacing: 0.5,
                                ),
                              ),
                            ),
                        ],
                      ),
                      const SizedBox(height: 2),
                      Text(
                        room.nick,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: 12,
                        ),
                      ),
                      if (room.watching > 0)
                        Text(
                          '${room.watching} 人在看 · ${platformName(room.platform)}',
                          style: TextStyle(
                            color: theme.textMuted,
                            fontSize: 12,
                          ),
                        )
                      else
                        Text(
                          platformName(room.platform),
                          style: TextStyle(
                            color: theme.textMuted,
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
      ),
    );
  }
}
