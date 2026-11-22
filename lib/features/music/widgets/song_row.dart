// Shared song row (fix 10) — the SINGLE row widget every list uses, so
// the rule cannot drift per page.
//
// - Exactly two action buttons: heart (favourite — the heart IS the
//   add-to-collection action) and play. NO `+` button anywhere.
// - NO "会员歌" text anywhere (fix 10).
// - Title truncates cleanly with an ellipsis and NEVER runs under the
//   action buttons: the title/meta column flexes, the action area has a
//   fixed width reserved on the right.
// - Tapping the row (cover or meta) plays; heart toggles favourite
//   without playing; tapping the artist name opens the artist page.

import '../../../core/theme/hao_radius.dart';
import 'package:flutter/material.dart';
import '../../../widgets/hao_pressable.dart';

import '../../../core/theme/glass.dart';
import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/haptics.dart';
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
    this.compact = false,
  });

  final Song song;
  final bool isFav;
  final VoidCallback onPlay;
  final VoidCallback onToggleFav;
  final VoidCallback? onOpenArtist;
  final VoidCallback? onOpenAlbum;

  /// Long-press opens the song quick menu (下一首播放 / 下载 / 立即播放 /
  /// 收藏) — the row's own context is passed so the menu anchors to
  /// the row (Beans context-menu pattern), not the full `···` sheet.
  final void Function(BuildContext)? onLongPress;

  /// Optional leading widget (rank number, drag handle, ...).
  final Widget? leading;

  final bool showPlatformBadge;
  final bool showDuration;

  /// Kumone `TrackRow` compact (TrackList.swift:39-40,93-165), used by
  /// the music home 最近播放 list only: plain row, 64 high, no glass
  /// card (the owning list draws 1pt dividers), cover 48 radius 6,
  /// title 16 medium, duration 11. Default false: every other page
  /// keeps the glass row exactly as it was.
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    // Compact values are Kumone TrackRow compact (see [compact]);
    // the glass row below keeps its own values.
    final titleSize = compact ? 16.0 : 15.0;
    final titleWeight = compact ? FontWeight.w500 : FontWeight.w600;
    final coverRadius = compact ? HaoRadius.small : HaoRadius.standard;
    final durationSize = compact ? 11.0 : 12.0;
    final row = Material(
      color: Colors.transparent,
      child: HaoPressable(
        onTap: () {
          HaoHaptics.tap();
          onPlay();
        },
        onLongPress: onLongPress == null
            ? null
            : () {
                HaoHaptics.medium();
                onLongPress!(context);
              },
        borderRadius: BorderRadius.circular(
          compact ? HaoRadius.standard : HaoRadius.large,
        ),
        child: Row(
          children: [
            if (leading != null) ...[leading!, const SizedBox(width: 8)],
            ClipRRect(
              borderRadius: BorderRadius.circular(coverRadius),
              child: song.cover.isEmpty
                  ? Container(
                      width: 48,
                      height: 48,
                      color: theme.accentSoft,
                      child: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.music_note, color: theme.textMuted),
                    )
                  : Image(
                      // 200px thumb (coverThumb): the full coverHi URL
                      // is up to 1.4 MB; a 48px row never needs it.
                      image: MusicImageProvider(coverThumb(song.cover)),
                      width: 48,
                      height: 48,
                      fit: BoxFit.cover,
                      errorBuilder: (_, _, _) => Container(
                        width: 48,
                        height: 48,
                        color: theme.accentSoft,
                        child: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.music_note, color: theme.textMuted),
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
                          style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                            color: theme.textPrimary,
                            fontSize: titleSize,
                            fontWeight: titleWeight,
                          ),
                        ),
                      ),
                      if (showPlatformBadge) ...[
                        const SizedBox(width: 6),
                        Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 6,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: theme.accentSoft,
                            borderRadius: BorderRadius.circular(HaoRadius.small),
                          ),
                          child: Text(
                            song.platform.badgeName,
                            style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
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
                            style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
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
                          style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
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
                              style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
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
                          style: TextStyle(shadows: HaoTheme.legibilityShadows(context),
                            color: theme.textMuted,
                            fontSize: durationSize,
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
                    icon: Icon(shadows: HaoTheme.legibilityShadows(context),
                      isFav ? Icons.favorite : Icons.favorite_border,
                      color: isFav ? theme.accent : theme.textMuted,
                      size: 22,
                    ),
                    onPressed: () {
                      HaoHaptics.tap();
                      onToggleFav();
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 40,
                      minHeight: 40,
                    ),
                  ),
                  IconButton(
                    icon: Icon(shadows: HaoTheme.legibilityShadows(context),
                      Icons.play_arrow,
                      color: theme.textPrimary,
                      size: 26,
                    ),
                    onPressed: () {
                      HaoHaptics.tap();
                      onPlay();
                    },
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
    if (compact) {
      // Plain 64-high row: the owning list draws the dividers.
      return SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: row,
        ),
      );
    }
    // Glass row (Beans `SongCell` glassRow, SongCell.swift: glassRow
    // branch: rowContent padded h10, glass RoundedRectangle radius 16;
    // v padding 6 inside, rows spaced 8 apart in the list — here the
    // 4pt vertical margin on each side gives the same 8pt gap).
    return GlassPressScale(
      pressedScale: 0.97,
      child: GlassCard(
        radius: HaoRadius.large,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: row,
      ),
    );
  }
}
