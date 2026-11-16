// Room detail panel (L05) — bottom sheet that does NOT cover the
// video.
//
// Pure Live's `room_details.dart` / `room_info_bar.dart`: anchor +
// platform, tappable category, follow button, status, full title,
// popularity + stream duration, announcement/intro, room number +
// copy, share, open in the platform App via deep link.
//
// What this app can actually show — only what the room detail API
// provides, never faked:
// - anchor + platform, status (直播中 / 已下播), full title,
//   popularity, room number + copy, share, open-in-App: yes.
// - category: [LiveRoom] carries none — omitted, not invented.
// - start time / stream duration / announcement / intro: no adapter
//   provides them (Douyu's own comment: "Our LiveRoom has no
//   area/introduction/notice/startedAt fields") — omitted, not
//   invented. If an adapter ever carries them, add the rows then.
//
// The sheet is capped at 65% of the screen height so the 16:9 video
// at the top of the room stays visible. Deep links need a real-device
// test per platform (see live_room_links.dart).

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:share_plus/share_plus.dart';

import '../../../../core/models/live_models.dart';
import '../../../../core/theme/hao_themes.dart';
import '../../live_follow_store.dart';
import '../../live_status.dart';
import 'live_room_links.dart';

/// Open the room detail sheet for [room].
Future<void> showRoomDetailSheet({
  required BuildContext context,
  required LiveRoom room,
}) {
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    backgroundColor: HaoTheme.of(context).surfaceStrong,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (context) => _RoomDetailSheet(room: room),
  );
}

class _RoomDetailSheet extends StatefulWidget {
  const _RoomDetailSheet({required this.room});

  final LiveRoom room;

  @override
  State<_RoomDetailSheet> createState() => _RoomDetailSheetState();
}

class _RoomDetailSheetState extends State<_RoomDetailSheet> {
  late bool _followed;

  @override
  void initState() {
    super.initState();
    _followed = LiveFollowStore.isFollowedRoom(widget.room);
  }

  Future<void> _toggleFollow() async {
    final nowFollowed = await LiveFollowStore.toggle(widget.room);
    if (!mounted) return;
    setState(() => _followed = nowFollowed);
  }

  Future<void> _copyRoomId() async {
    try {
      await Clipboard.setData(ClipboardData(text: widget.room.roomId));
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('复制失败，请重试')),
      );
      return;
    }
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('已复制房间号')),
    );
  }

  Future<void> _share() async {
    try {
      await SharePlus.instance.share(
        ShareParams(text: shareTextFor(widget.room)),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('分享失败，请重试')),
      );
    }
  }

  Future<void> _openInApp() async {
    final result = await openInPlatformApp(widget.room);
    if (!mounted) return;
    switch (result) {
      case RoomExternalOpenResult.opened:
        break;
      case RoomExternalOpenResult.unavailable:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('该平台暂不支持在 App 中打开')),
        );
      case RoomExternalOpenResult.failed:
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('打开失败，请检查是否安装了该平台 App')),
        );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final room = widget.room;
    return SizedBox(
      // Capped so the video at the top of the room stays visible.
      height: MediaQuery.sizeOf(context).height * 0.65,
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(20, 4, 20, 24),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            // Anchor + platform + follow.
            Row(
              children: [
                CircleAvatar(
                  radius: 24,
                  backgroundImage: room.avatar.isEmpty
                      ? null
                      : NetworkImage(room.avatar),
                  child: room.avatar.isEmpty
                      ? Text(room.nick.isEmpty ? '?' : room.nick[0])
                      : null,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        room.nick.isEmpty ? '主播' : room.nick,
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 16,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                      const SizedBox(height: 2),
                      Text(
                        platformName(room.platform),
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ],
                  ),
                ),
                FilledButton(
                  onPressed: _toggleFollow,
                  style: FilledButton.styleFrom(
                    backgroundColor: _followed
                        ? theme.surface
                        : theme.accent,
                    foregroundColor: _followed
                        ? theme.textPrimary
                        : Colors.white,
                  ),
                  child: Text(_followed ? '已关注' : '关注'),
                ),
              ],
            ),
            const SizedBox(height: 16),
            // Status + popularity.
            Row(
              children: [
                if (room.liveStatus)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      // Red ONLY for the LIVE badge (standing rule).
                      color: theme.liveRed,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: const Text(
                      'LIVE',
                      style: TextStyle(
                        color: Colors.white,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  )
                else
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: theme.surface,
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      '已下播',
                      style: TextStyle(
                        color: theme.textMuted,
                        fontSize: 11,
                        fontWeight: FontWeight.bold,
                      ),
                    ),
                  ),
                if (room.watching > 0) ...[
                  const SizedBox(width: 10),
                  Text(
                    '${room.watching} 人在看',
                    style: TextStyle(
                      color: theme.textMuted,
                      fontSize: 13,
                    ),
                  ),
                ],
              ],
            ),
            const SizedBox(height: 12),
            // Full title.
            Text(
              room.title.isEmpty ? '（无标题）' : room.title,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 16,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 16),
            Divider(color: theme.hairline, height: 1),
            const SizedBox(height: 8),
            // Room number + copy.
            Row(
              children: [
                Expanded(
                  child: Text(
                    '房间号 ${room.roomId}',
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 14,
                    ),
                  ),
                ),
                TextButton.icon(
                  onPressed: _copyRoomId,
                  icon: Icon(Icons.copy, size: 16, color: theme.accent),
                  label: Text(
                    '复制',
                    style: TextStyle(color: theme.accent),
                  ),
                ),
              ],
            ),
            // Share + open in App.
            Row(
              children: [
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _share,
                    icon: const Icon(Icons.share_outlined, size: 18),
                    label: const Text('分享'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.textPrimary,
                      side: BorderSide(color: theme.hairline),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: OutlinedButton.icon(
                    onPressed: _openInApp,
                    icon: const Icon(Icons.open_in_new, size: 18),
                    label: Text('在${platformName(room.platform)} App 中打开'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: theme.textPrimary,
                      side: BorderSide(color: theme.hairline),
                    ),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }
}
