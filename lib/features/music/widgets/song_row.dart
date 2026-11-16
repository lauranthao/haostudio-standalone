// Shared song row (fix 10) — the SINGLE row widget every list uses, so
// the rule cannot drift per page.
//
// - Exactly two action buttons: heart (favourite — the heart IS the
//   add-to-collection action) and play. NO `+` button anywhere.
// - NO "会员歌" text anywhere (the vipOnly flag is kept for gating logic
//   only and is never rendered).
// - Title truncates cleanly with an ellipsis and NEVER runs under the
//   action buttons: the title/meta column flexes, the action area has a
//   fixed width reserved on the right.
// - Tapping the row (cover or meta) plays; heart toggles favourite
//   without playing; tapping the artist name opens the artist page.

import 'package:flutter/material.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../services/music/music_models.dart';
import 'music_image.dart';

class SongRow extends StatelessWidget {
  const SongRow({
    super.key,
    required this.song,
    required this.isFav,
    required this.onPlay,
    required this.onToggleFav,
    this.onOpenArtist,
    this.onOpenAlbum,
    this.leading,
    this.showPlatformBadge = true,
    this.showDuration = true,
    this.onLongPress,
  });

  final Song song;
  final bool isFav;
  final VoidCallback onPlay;
  final VoidCallback onToggleFav;
  final VoidCallback? onOpenArtist;
  final VoidCallback? onOpenAlbum;

  /// Long-press opens the song `···` menu (下一首播放 / 下载 / 倍速).
  final VoidCallback? onLongPress;

  /// Optional leading widget (rank number, drag handle, ...).
  final Widget? leading;

  final bool showPlatformBadge;
  final bool showDuration;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return InkWell(
      onTap: onPlay,
      onLongPress: onLongPress,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
        child: Row(
          children: [
            if (leading != null) ...[
              leading!,
              const SizedBox(width: 8),
            ],
            ClipRRect(
              borderRadius: BorderRadius.circular(8),
              child: song.cover.isEmpty
                  ? Container(
                      width: 48,
                      height: 48,
                      color: theme.accentSoft,
                      child: Icon(
                        Icons.music_note,
                        color: theme.textMuted,
                      ),
                    )
                  : Image(
                      image: MusicImageProvider(song.cover),
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 48,
                        height: 48,
                        color: theme.accentSoft,
                        child: Icon(
                          Icons.music_note,
                          color: theme.textMuted,
                        ),
                      ),
                    ),
            ),
            const SizedBox(width: 12),
            // Flex-constrained meta column: title can never run under
            // the fixed-width action area on the right.
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Row(
                    children: [
                      Expanded(
                        child: Text(
                          song.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontSize: 15,
                            fontWeight: FontWeight.w500,
                          ),
                        ),
                      ),
                      if (showPlatformBadge) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 5,
                            vertical: 1,
                          ),
                          decoration: BoxDecoration(
                            color: theme.accentSoft,
                            borderRadius: BorderRadius.circular(4),
                          ),
                          child: Text(
                            song.platform.badgeName,
                            style: TextStyle(
                              color: theme.accent,
                              fontSize: 10,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ],
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: [
                      Expanded(
                        child: GestureDetector(
                          onTap: onOpenArtist,
                          child: Text(
                            song.artist,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              color: onOpenArtist != null
                                  ? theme.accent
                                  : theme.textSecondary,
                              fontSize: 13,
                            ),
                          ),
                        ),
                      ),
                      if (song.album.isNotEmpty) ...[
                        Text(
                          ' · ',
                          style: TextStyle(
                            color: theme.textMuted,
                            fontSize: 13,
                          ),
                        ),
                        Flexible(
                          child: GestureDetector(
                            onTap: onOpenAlbum,
                            child: Text(
                              song.album,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                color: theme.textSecondary,
                                fontSize: 13,
                              ),
                            ),
                          ),
                        ),
                      ],
                      if (showDuration && song.dur > 0) ...[
                        const SizedBox(width: 6),
                        Text(
                          formatDuration(song.dur),
                          style: TextStyle(
                            color: theme.textMuted,
                            fontSize: 12,
                          ),
                        ),
                      ],
                    ],
                  ),
                ],
              ),
            ),
            // Fixed-width action area: heart + play only.
            SizedBox(
              width: 96,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    icon: Icon(
                      isFav ? Icons.favorite : Icons.favorite_border,
                      color: isFav ? theme.accent : theme.textMuted,
                      size: 22,
                    ),
                    onPressed: onToggleFav,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                  ),
                  IconButton(
                    icon: Icon(
                      Icons.play_arrow,
                      color: theme.textPrimary,
                      size: 26,
                    ),
                    onPressed: onPlay,
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }
}
