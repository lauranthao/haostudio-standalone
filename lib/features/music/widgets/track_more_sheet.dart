// Song `···` action sheet (fix 15).
//
// Buttons, in order: 歌曲信息 (song info), 评论 (comments — opens the
// NetEase-style comments page: 精彩评论 on top, 最新评论 below, load
// more; chen 2026-11-17), 播放列表 (play list / queue),
// 播放模式 (cycles the five play modes — 顺序播放 / 列表循环 / 单曲循环 /
// 随机播放 / 单曲播放, M-P0-1), 睡眠定时 (M-P0-3), 下一首播放 (insert
// right after the current track, M-P0-4), 下载 (save to the device for
// offline playback, M-P0-5), 倍速 slider 0.6–2.0× (M-P0-2), 取消.
// There is NO 分享 (share) button in this sheet. Tapping 播放列表 closes
// the sheet and opens the floating queue panel above the player (Apple
// Music "Up Next" style).
//
// The sheet is opened from the player `···` AND from a long-press on a
// song row in the lists — see [openTrackMoreSheet], which shows the
// sheet and handles the chosen action in one call.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/glass.dart';
import '../../../widgets/glass_dialog.dart';
import '../../../services/music/music_downloads.dart';
import '../../../services/music/music_models.dart';
import '../../../services/music/music_quality.dart';
import '../../../services/music/play_mode.dart';
import '../../../services/music/sleep_timer.dart';
import '../../../services/music/equalizer_store.dart';
import '../comments_page.dart';
import '../equalizer_page.dart';
import '../music_player_controller.dart';
import '../music_player_sheet.dart';
import 'sleep_timer_sheet.dart';
import 'music_image.dart';

enum TrackMoreAction {
  info,
  comments,
  queue,
  playMode,
  sleepTimer,
  playNext,
  download,
  equalizer,
  cancel,
}

/// Compact long-press menu (Beans `SongCell` context menu pattern):
/// an anchored popup with the four most frequent actions — NOT the
/// full `···` sheet. Beans' menu is 下一首播放 / 添加到歌单 / 下载歌曲 /
/// 立即播放；we have no user-created playlists (the heart IS the
/// add-to-collection action), so the fourth slot is 收藏/取消收藏.
/// [rowContext] is the pressed row's context — the menu anchors to
/// the row, like the iOS context menu.
Future<void> openSongQuickMenu(BuildContext rowContext, Song song) async {
  final theme = HaoTheme.of(rowContext);
  final controller = MusicPlayerController.ensure();
  final box = rowContext.findRenderObject() as RenderBox?;
  final screen = MediaQuery.of(rowContext).size;
  final anchor = box == null
      ? const RelativeRect.fromLTRB(0, 200, 0, 200)
      : RelativeRect.fromRect(
          box.localToGlobal(Offset.zero) & box.size,
          Offset.zero & screen,
        );
  final isCurrent = controller.currentSong?.identityKey == song.identityKey;
  final isFav = controller.isFav(song);
  final picked = await showMenu<_QuickAction>(
    context: rowContext,
    position: anchor,
    color: theme.surfaceSolid,
    shape: RoundedRectangleBorder(
      borderRadius: BorderRadius.circular(16),
      side: BorderSide(color: theme.hairline),
    ),
    items: [
      PopupMenuItem(
        value: _QuickAction.playNext,
        child: _QuickRow(
          icon: Icons.queue_play_next,
          label: '下一首播放',
          theme: theme,
        ),
      ),
      PopupMenuItem(
        value: _QuickAction.download,
        child: _QuickRow(icon: Icons.download, label: '下载', theme: theme),
      ),
      if (!isCurrent)
        PopupMenuItem(
          value: _QuickAction.playNow,
          child: _QuickRow(icon: Icons.play_arrow, label: '立即播放', theme: theme),
        ),
      PopupMenuItem(
        value: _QuickAction.fav,
        child: _QuickRow(
          icon: isFav ? Icons.favorite : Icons.favorite_border,
          label: isFav ? '取消收藏' : '收藏',
          theme: theme,
        ),
      ),
    ],
  );
  if (picked == null || !rowContext.mounted) return;
  switch (picked) {
    case _QuickAction.playNext:
      await handleTrackMoreAction(rowContext, song, TrackMoreAction.playNext);
    case _QuickAction.download:
      await handleTrackMoreAction(rowContext, song, TrackMoreAction.download);
    case _QuickAction.playNow:
      // Queue-aware (Beans `SongCell` 立即播放): in the queue -> jump
      // to it; otherwise play the song on its own.
      final idx = controller.queue.indexWhere(
        (s) => s.identityKey == song.identityKey,
      );
      if (idx >= 0) {
        unawaited(controller.playIndex(idx));
      } else {
        unawaited(controller.playQueue([song], 0));
      }
      if (rowContext.mounted) {
        unawaited(
          Navigator.of(rowContext).push(
            MaterialPageRoute<void>(builder: (_) => const MusicPlayerPage()),
          ),
        );
      }
    case _QuickAction.fav:
      await controller.toggleFav(song);
      if (rowContext.mounted) {
        ScaffoldMessenger.of(rowContext)
            .showSnackBar(SnackBar(content: Text(isFav ? '已取消收藏' : '已收藏')));
      }
  }
}

enum _QuickAction { playNext, download, playNow, fav }

/// One row of the quick menu: icon + label, Beans `Label` style.
class _QuickRow extends StatelessWidget {
  const _QuickRow({
    required this.icon,
    required this.label,
    required this.theme,
  });

  final IconData icon;
  final String label;
  final HaoTheme theme;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: [
        Icon(icon, color: theme.textPrimary, size: 20),
        const SizedBox(width: 12),
        Text(label, style: TextStyle(color: theme.textPrimary, fontSize: 15)),
      ],
    );
  }
}

/// Show the `···` sheet for [song] and handle the chosen action.
///
/// [fromPlayer] is true when called from the player page: the 播放列表
/// action then just raises the floating queue panel. From a list page
/// it opens the player page first, so the panel has somewhere to float.
Future<void> openTrackMoreSheet(
  BuildContext context,
  Song song, {
  bool fromPlayer = false,
}) async {
  final action = await showTrackMoreSheet(context, song);
  if (action == null || !context.mounted) return;
  await handleTrackMoreAction(context, song, action, fromPlayer: fromPlayer);
}

/// Handle one [TrackMoreAction] picked from the sheet.
Future<void> handleTrackMoreAction(
  BuildContext context,
  Song song,
  TrackMoreAction action, {
  bool fromPlayer = false,
}) async {
  final controller = MusicPlayerController.ensure();
  switch (action) {
    case TrackMoreAction.info:
      await showSongInfoDialog(context, song);
    case TrackMoreAction.comments:
      if (context.mounted) {
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => SongCommentsPage(song: song),
            ),
          ),
        );
      }
    case TrackMoreAction.queue:
      if (controller.queue.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('播放列表是空的')));
        }
        return;
      }
      controller.showQueuePanel.value = true;
      if (!fromPlayer && context.mounted) {
        // The panel floats above the player page — open it first.
        unawaited(Get.to(() => const MusicPlayerPage()));
      }
    case TrackMoreAction.playMode:
      await controller.cyclePlayMode();
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(controller.mode.label)));
      }
    case TrackMoreAction.sleepTimer:
      final picked = await showSleepTimerSheet(context);
      if (picked != null && context.mounted) {
        controller.setSleepTimer(picked);
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(
              picked == SleepTimerOption.off
                  ? '睡眠定时已关闭'
                  : '睡眠定时：${controller.sleepLabel}',
            ),
          ),
        );
      }
    case TrackMoreAction.playNext:
      final ok = await controller.playNext(song);
      if (context.mounted) {
        ScaffoldMessenger.of(context)
            .showSnackBar(SnackBar(content: Text(ok ? '已加入下一首播放' : '这首歌正在播放')));
      }
    case TrackMoreAction.equalizer:
      // Stage 3: opens the 10-band EQ page (same destination as the
      // settings playback-panel row). The sheet is already popped by
      // openTrackMoreSheet, so this push lands on the player/list page.
      if (context.mounted) {
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(
              builder: (_) => const EqualizerPage(),
            ),
          ),
        );
      }
    case TrackMoreAction.download:
      if (controller.downloads.statusFor(song) == DownloadStatus.downloaded) {
        if (context.mounted) {
          ScaffoldMessenger.of(context)
              .showSnackBar(const SnackBar(content: Text('这首歌已经下载过了')));
        }
        return;
      }
      final ok = await controller.downloads.download(song);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(ok ? '已下载，可离线播放' : '下载失败，换一首试试')),
        );
      }
    case TrackMoreAction.cancel:
      break;
  }
}

/// Icon per play mode (the label comes from PlayModeX.label).
IconData playModeIcon(PlayMode mode) {
  switch (mode) {
    case PlayMode.sequential:
      return Icons.format_list_bulleted;
    case PlayMode.listLoop:
      return Icons.repeat;
    case PlayMode.singleLoop:
      return Icons.repeat_one;
    case PlayMode.shuffle:
      return Icons.shuffle;
    case PlayMode.single:
      return Icons.looks_one;
  }
}

Future<TrackMoreAction?> showTrackMoreSheet(BuildContext context, Song song) {
  final theme = HaoTheme.of(context);
  final controller = MusicPlayerController.ensure();
  // Section header (Beans menu grouping): small muted label above
  // each group of actions.
  Widget section(String label) => Align(
    alignment: Alignment.centerLeft,
    child: Padding(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 4),
      child: Text(
        label,
        style: TextStyle(
          color: theme.textMuted,
          fontSize: 12,
          fontWeight: FontWeight.w600,
        ),
      ),
    ),
  );
  return showModalBottomSheet<TrackMoreAction>(
    context: context,
    // isScrollControlled: without it the sheet is capped at ~half the
    // screen height and tall content is clipped — the 取消 row was cut
    // off at the bottom edge on chen's phone (v1.0.6). With it the sheet
    // sizes to its content, and the SingleChildScrollView below is the
    // safety net: on a short screen the list scrolls instead of clipping.
    isScrollControlled: true,
    backgroundColor: Colors.transparent,
    barrierColor: Colors.black.withValues(alpha: 0.35),
    builder: (ctx) => GlassSheetBackground(
      radius: 20,
      child: SafeArea(
        child: SingleChildScrollView(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 14, 20, 6),
              child: Row(
                children: [
                  ClipRRect(
                    borderRadius: BorderRadius.circular(8),
                    child: song.cover.isEmpty
                        ? Container(
                            width: 44,
                            height: 44,
                            color: theme.accentSoft,
                            child: Icon(
                              Icons.music_note,
                              color: theme.textMuted,
                            ),
                          )
                        : Image(
                            image: MusicImageProvider(song.cover),
                            width: 44,
                            height: 44,
                            fit: BoxFit.cover,
                            errorBuilder: (_, _, _) => Container(
                              width: 44,
                              height: 44,
                              color: theme.accentSoft,
                              child: Icon(
                                Icons.music_note,
                                color: theme.textMuted,
                              ),
                            ),
                          ),
                  ),
                  const SizedBox(width: 12),
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontSize: 17,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        Text(
                          song.artist,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            // Beans menu grouping: playback actions first (most used
            // while listening), then the song itself, then the list.
            section('播放'),
            // M-P0-4: insert right after the current track.
            ListTile(
              leading: Icon(Icons.queue_play_next, color: theme.textPrimary),
              title: Text('下一首播放', style: TextStyle(color: theme.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.playNext),
            ),
            Obx(
              () => ListTile(
                leading: Icon(
                  playModeIcon(controller.mode),
                  color: theme.textPrimary,
                ),
                title: Text(
                  controller.mode.label,
                  style: TextStyle(color: theme.textPrimary),
                ),
                onTap: () => Navigator.of(ctx).pop(TrackMoreAction.playMode),
              ),
            ),
            // M-P0-2: speed slider 0.6–2.0×, live value, takes effect
            // immediately on the audio rate (controller.setSpeed).
            Obx(() {
              final speed = controller.speed.value;
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Row(
                      children: [
                        Icon(Icons.speed, color: theme.textPrimary),
                        const SizedBox(width: 16),
                        Text('倍速', style: TextStyle(color: theme.textPrimary)),
                        const Spacer(),
                        Text(
                          '${speed.toStringAsFixed(2)}×',
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                    SliderTheme(
                      data: SliderTheme.of(ctx).copyWith(
                        trackHeight: 4,
                        thumbShape: const RoundSliderThumbShape(
                          enabledThumbRadius: 7,
                        ),
                        activeTrackColor: theme.accent,
                        inactiveTrackColor: theme.accentSoft,
                        thumbColor: theme.accent,
                        overlayColor: theme.accentSoft,
                      ),
                      child: Slider(
                        value: speed,
                        min: 0.6,
                        max: 2.0,
                        divisions: 28,
                        label: '${speed.toStringAsFixed(2)}×',
                        onChanged: (v) => unawaited(controller.setSpeed(v)),
                      ),
                    ),
                  ],
                ),
              );
            }),
            const Divider(height: 1),
            section('歌曲'),
            // Stage 3: equalizer entry with the real on/off state
            // (same destination as the settings playback-panel row).
            AnimatedBuilder(
              animation: EqualizerStore.ensure(),
              builder: (context, _) => ListTile(
                leading: Icon(Icons.tune, color: theme.textPrimary),
                title: Text('均衡器', style: TextStyle(color: theme.textPrimary)),
                trailing: Text(
                  EqualizerStore.ensure().enabled ? '已开启' : '已关闭',
                  style: TextStyle(color: theme.textSecondary, fontSize: 13),
                ),
                onTap: () => Navigator.of(ctx).pop(TrackMoreAction.equalizer),
              ),
            ),
            ListTile(
              leading: Icon(Icons.info_outline, color: theme.textPrimary),
              title: Text('歌曲信息', style: TextStyle(color: theme.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.info),
            ),
            ListTile(
              leading: Icon(Icons.comment_outlined, color: theme.textPrimary),
              title: Text('评论', style: TextStyle(color: theme.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.comments),
            ),
            const Divider(height: 1),
            section('列表'),
            ListTile(
              leading: Icon(Icons.queue_music, color: theme.textPrimary),
              title: Text('播放列表', style: TextStyle(color: theme.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.queue),
            ),
            Obx(() {
              final option = controller.sleepOption.value;
              final remaining = controller.sleepRemaining.value;
              final subtitle = option == SleepTimerOption.off
                  ? '未设置'
                  : option == SleepTimerOption.queueEnd
                  ? '到歌单结束'
                  : remaining != null
                  ? '剩余 ${SleepTimer.formatRemaining(remaining)}'
                  : option.label;
              return ListTile(
                leading: Icon(Icons.timer, color: theme.textPrimary),
                title: Text('睡眠定时', style: TextStyle(color: theme.textPrimary)),
                trailing: Text(
                  subtitle,
                  style: TextStyle(color: theme.textSecondary, fontSize: 13),
                ),
                onTap: () => Navigator.of(ctx).pop(TrackMoreAction.sleepTimer),
              );
            }),
            // M-P0-5: download the song to the device for offline play.
            Obx(() {
              final st = controller.downloads.statusFor(song);
              final prog = controller.downloads.progress[song.identityKey];
              final subtitle = switch (st) {
                DownloadStatus.downloaded => '已下载',
                DownloadStatus.downloading =>
                  prog != null ? '下载中 ${(prog * 100).round()}%' : '下载中…',
                DownloadStatus.failed => '下载失败，点按重试',
                DownloadStatus.notDownloaded => '保存到本机，离线播放',
              };
              return ListTile(
                leading: Icon(
                  st == DownloadStatus.downloaded
                      ? Icons.download_done
                      : Icons.download,
                  color: theme.textPrimary,
                ),
                title: Text('下载', style: TextStyle(color: theme.textPrimary)),
                trailing: Text(
                  subtitle,
                  style: TextStyle(color: theme.textSecondary, fontSize: 13),
                ),
                onTap: () => Navigator.of(ctx).pop(TrackMoreAction.download),
              );
            }),
            const Divider(height: 1),
            ListTile(
              leading: Icon(Icons.close, color: theme.textPrimary),
              title: Text('取消', style: TextStyle(color: theme.textPrimary)),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.cancel),
            ),
            const SizedBox(height: 8),
          ],
        ),
      ),
    ),
    ),
  );
}

/// Song info dialog (歌曲信息): title/artist/album/duration/source/quality.
Future<void> showSongInfoDialog(BuildContext context, Song song) async {
  final theme = HaoTheme.of(context);
  final controller = MusicPlayerController.ensure();
  final dur = song.dur > 0
      ? formatDuration(song.dur)
      : formatDuration(controller.duration.value.inSeconds);
  final rows = <(String, String)>[
    ('专辑', song.album.isEmpty ? '—' : song.album),
    ('时长', dur),
    ('音源', '${song.platform.displayName}音乐'),
    ('音质', controller.actualQuality.value.label),
    ('发行', '—'),
  ];
  await showGlassDialog<void>(
    context,
    builder: (ctx) => Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: song.cover.isEmpty
                    ? Container(
                        width: 64,
                        height: 64,
                        color: theme.accentSoft,
                        child: Icon(Icons.music_note, color: theme.textMuted),
                      )
                    : Image(
                        image: MusicImageProvider(song.cover),
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 64,
                          height: 64,
                          color: theme.accentSoft,
                          child: Icon(Icons.music_note, color: theme.textMuted),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    Text(
                      song.artist,
                      style: TextStyle(color: theme.textSecondary),
                    ),
                  ],
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          for (final (label, value) in rows)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Row(
                mainAxisAlignment: MainAxisAlignment.spaceBetween,
                children: [
                  Text(label, style: TextStyle(color: theme.textMuted)),
                  Flexible(
                    child: Text(
                      value,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
          const SizedBox(height: 16),
          Row(
            mainAxisAlignment: MainAxisAlignment.end,
            children: [
              TextButton(
                onPressed: () => Navigator.of(ctx).pop(),
                child: Text('关闭', style: TextStyle(color: theme.accent)),
              ),
            ],
          ),
        ],
      ),
  );
}
