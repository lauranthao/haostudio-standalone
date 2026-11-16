// Song `···` action sheet (fix 15).
//
// Buttons, in order: 歌曲信息 (song info), 播放列表 (play list / queue),
// 播放模式 (cycles the five play modes — 顺序播放 / 列表循环 / 单曲循环 /
// 随机播放 / 单曲播放, M-P0-1), 睡眠定时 (M-P0-3), 下一首播放 (insert
// right after the current track, M-P0-4), 下载 (save to the device for
// offline playback, M-P0-5), 倍速 slider 0.6–2.0× (M-P0-2), 取消.
// There is NO 分享 (share) button and NO 评论 (comments) button in this
// sheet. Tapping 播放列表 closes the sheet and opens the floating queue
// panel above the player (Apple Music "Up Next" style).
//
// The sheet is opened from the player `···` AND from a long-press on a
// song row in the lists — see [openTrackMoreSheet], which shows the
// sheet and handles the chosen action in one call.

import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../services/music/music_downloads.dart';
import '../../../services/music/music_models.dart';
import '../../../services/music/music_quality.dart';
import '../../../services/music/play_mode.dart';
import '../../../services/music/sleep_timer.dart';
import '../music_player_controller.dart';
import '../music_player_sheet.dart';
import 'sleep_timer_sheet.dart';

enum TrackMoreAction {
  info,
  queue,
  playMode,
  sleepTimer,
  playNext,
  download,
  cancel,
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
  await handleTrackMoreAction(
    context,
    song,
    action,
    fromPlayer: fromPlayer,
  );
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
    case TrackMoreAction.queue:
      if (controller.queue.isEmpty) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('播放列表是空的')),
          );
        }
        return;
      }
      controller.showQueuePanel.value = true;
      if (!fromPlayer && context.mounted) {
        // The panel floats above the player page — open it first.
        unawaited(
          Get.to(() => const MusicPlayerPage()),
        );
      }
    case TrackMoreAction.playMode:
      await controller.cyclePlayMode();
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(content: Text(controller.mode.label)),
        );
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
                  : '睡眠定时：${picked.label}',
            ),
          ),
        );
      }
    case TrackMoreAction.playNext:
      final ok = await controller.playNext(song);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? '已加入下一首播放' : '这首歌正在播放'),
          ),
        );
      }
    case TrackMoreAction.download:
      if (controller.downloads.statusFor(song) ==
          DownloadStatus.downloaded) {
        if (context.mounted) {
          ScaffoldMessenger.of(context).showSnackBar(
            const SnackBar(content: Text('这首歌已经下载过了')),
          );
        }
        return;
      }
      final ok = await controller.downloads.download(song);
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: Text(ok ? '已下载，可离线播放' : '下载失败，换一首试试'),
          ),
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

Future<TrackMoreAction?> showTrackMoreSheet(
  BuildContext context,
  Song song,
) {
  final theme = HaoTheme.of(context);
  final controller = MusicPlayerController.ensure();
  return showModalBottomSheet<TrackMoreAction>(
    context: context,
    backgroundColor: theme.surfaceSolid,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(top: Radius.circular(20)),
    ),
    builder: (ctx) => SafeArea(
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
                      : Image.network(
                          song.cover,
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
                          fontSize: 15,
                          fontWeight: FontWeight.w600,
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
          ListTile(
            leading: Icon(Icons.info_outline, color: theme.textPrimary),
            title: Text('歌曲信息', style: TextStyle(color: theme.textPrimary)),
            onTap: () => Navigator.of(ctx).pop(TrackMoreAction.info),
          ),
          ListTile(
            leading: Icon(Icons.queue_music, color: theme.textPrimary),
            title: Text('播放列表', style: TextStyle(color: theme.textPrimary)),
            onTap: () => Navigator.of(ctx).pop(TrackMoreAction.queue),
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
          Obx(
            () {
              final option = controller.sleepOption.value;
              final remaining = controller.sleepRemaining.value;
              final subtitle = option == SleepTimerOption.off
                  ? '未设置'
                  : option == SleepTimerOption.queueEnd
                      ? '到歌单结束'
                      : remaining != null
                          ? '剩余 ${_remainingText(remaining)}'
                          : option.label;
              return ListTile(
                leading: Icon(Icons.timer, color: theme.textPrimary),
                title: Text(
                  '睡眠定时',
                  style: TextStyle(color: theme.textPrimary),
                ),
                trailing: Text(
                  subtitle,
                  style: TextStyle(color: theme.textSecondary, fontSize: 13),
                ),
                onTap: () =>
                    Navigator.of(ctx).pop(TrackMoreAction.sleepTimer),
              );
            },
          ),
          // M-P0-4: insert right after the current track.
          ListTile(
            leading:
                Icon(Icons.queue_play_next, color: theme.textPrimary),
            title: Text(
              '下一首播放',
              style: TextStyle(color: theme.textPrimary),
            ),
            onTap: () => Navigator.of(ctx).pop(TrackMoreAction.playNext),
          ),
          // M-P0-5: download the song to the device for offline play.
          Obx(
            () {
              final st = controller.downloads.statusFor(song);
              final prog =
                  controller.downloads.progress[song.identityKey];
              final subtitle = switch (st) {
                DownloadStatus.downloaded => '已下载',
                DownloadStatus.downloading => prog != null
                    ? '下载中 ${(prog * 100).round()}%'
                    : '下载中…',
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
                title: Text(
                  '下载',
                  style: TextStyle(color: theme.textPrimary),
                ),
                trailing: Text(
                  subtitle,
                  style:
                      TextStyle(color: theme.textSecondary, fontSize: 13),
                ),
                onTap: () =>
                    Navigator.of(ctx).pop(TrackMoreAction.download),
              );
            },
          ),
          // M-P0-2: speed slider 0.6–2.0×, live value, takes effect
          // immediately on the audio rate (controller.setSpeed).
          Obx(
            () {
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
                        Text(
                          '倍速',
                          style: TextStyle(color: theme.textPrimary),
                        ),
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
                        onChanged: (v) =>
                            unawaited(controller.setSpeed(v)),
                      ),
                    ),
                  ],
                ),
              );
            },
          ),
          ListTile(
            leading: Icon(Icons.close, color: theme.textPrimary),
            title: Text('取消', style: TextStyle(color: theme.textPrimary)),
            onTap: () => Navigator.of(ctx).pop(TrackMoreAction.cancel),
          ),
          const SizedBox(height: 8),
        ],
      ),
    ),
  );
}

String _remainingText(Duration remaining) {
  final total = remaining.inSeconds;
  final m = total ~/ 60;
  final s = total % 60;
  return '$m:${s.toString().padLeft(2, '0')}';
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
  await showDialog<void>(
    context: context,
    builder: (ctx) => AlertDialog(
      backgroundColor: theme.surfaceSolid,
      content: Column(
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
                        child: Icon(
                          Icons.music_note,
                          color: theme.textMuted,
                        ),
                      )
                    : Image.network(
                        song.cover,
                        width: 64,
                        height: 64,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 64,
                          height: 64,
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
        ],
      ),
      actions: [
        TextButton(
          onPressed: () => Navigator.of(ctx).pop(),
          child: Text('关闭', style: TextStyle(color: theme.accent)),
        ),
      ],
    ),
  );
}
