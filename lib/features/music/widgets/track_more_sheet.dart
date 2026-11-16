// Song `···` action sheet (fix 15).
//
// Buttons, in order: 歌曲信息 (song info), 播放列表 (play list / queue),
// 顺序播放 (sequential play mode), 取消 (cancel). There is NO 分享 (share)
// button and NO 评论 (comments) button in this sheet.
// Tapping 播放列表 closes the sheet and opens the floating queue panel
// above the player (Apple Music "Up Next" style).

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../services/music/music_models.dart';
import '../../../services/music/music_quality.dart';
import '../music_player_controller.dart';

enum TrackMoreAction { info, queue, sequential, cancel }

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
                controller.playMode.value == 'shuffle'
                    ? Icons.shuffle
                    : Icons.repeat,
                color: theme.textPrimary,
              ),
              title: Text(
                controller.playMode.value == 'shuffle' ? '随机播放' : '顺序播放',
                style: TextStyle(color: theme.textPrimary),
              ),
              onTap: () => Navigator.of(ctx).pop(TrackMoreAction.sequential),
            ),
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
