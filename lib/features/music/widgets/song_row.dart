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
import 'package:flutter/cupertino.dart';
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

  /// Long-press opens the iOS context menu (CupertinoContextMenu:
  /// preview + 播放 / 收藏 / 更多); its 更多 action opens the song
  /// quick menu (下一首播放 / 下载 / 立即播放 / 收藏) — the row's own
  /// context is passed so the menu anchors to the row (Beans
  /// context-menu pattern), not the full `···` sheet.
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
        onLongPress: null, // Long-press is owned by the
        // CupertinoContextMenu below (its 更多 action opens the
        // quick menu); leaving it here would fire both.
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
            // Fixed-width action area: heart + play only. 104pt wide:
            // two 44pt hit targets (the 44pt iOS floor) + 8pt gap to
            // the row edge; the icons themselves stay 22/26pt.
            SizedBox(
              width: 104,
              child: Row(
                mainAxisAlignment: MainAxisAlignment.end,
                children: [
                  IconButton(
                    icon: Icon(shadows: HaoTheme.legibilityShadows(context),
                      isFav ? Icons.favorite : Icons.favorite_border,
                      color: isFav ? theme.accent : theme.textMuted,
                      size: 22,
                    ),
                    tooltip: isFav ? '取消收藏' : '收藏',
                    onPressed: () {
                      HaoHaptics.tap();
                      onToggleFav();
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
                    ),
                  ),
                  IconButton(
                    icon: Icon(shadows: HaoTheme.legibilityShadows(context),
                      Icons.play_arrow,
                      color: theme.textPrimary,
                      size: 26,
                    ),
                    tooltip: '播放',
                    onPressed: () {
                      HaoHaptics.tap();
                      onPlay();
                    },
                    padding: EdgeInsets.zero,
                    constraints: const BoxConstraints(
                      minWidth: 44,
                      minHeight: 44,
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
      final content = SizedBox(
        height: 64,
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
          child: row,
        ),
      );
      return _withContextMenu(context, content);
    }
    // Glass row (Beans `SongCell` glassRow, SongCell.swift: glassRow
    // branch: rowContent padded h10, glass RoundedRectangle radius 16;
    // v padding 6 inside, rows spaced 8 apart in the list — here the
    // 4pt vertical margin on each side gives the same 8pt gap).
    final content = GlassPressScale(
      pressedScale: 0.97,
      child: GlassCard(
        radius: HaoRadius.large,
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        margin: const EdgeInsets.symmetric(vertical: 4),
        child: row,
      ),
    );
    return _withContextMenu(context, content);
  }

  /// iOS long-press menu (Apple Music pattern): the row itself is
  /// the preview; 播放 / 收藏 / 更多 are the actions. 更多 opens
  /// the existing quick menu sheet — the full controls (speed,
  /// lyric offset, download) stay there, one tap away. Rows with
  /// no [onLongPress] have no menu, exactly as before.
  ///
  /// The preview must be width-pinned: CupertinoContextMenu lays
  /// the preview out under unbounded width (FittedBox), and the
  /// row's Expanded title/artist would throw during layout
  /// ("RenderFlex children have non-zero flex but incoming width
  /// constraints are unbounded") — on a real phone the menu would
  /// open broken. LayoutBuilder gives the row its list width.
  Widget _withContextMenu(BuildContext context, Widget content) {
    if (onLongPress == null) return content;
    return LayoutBuilder(
      builder: (context, constraints) {
        final width = constraints.maxWidth.isFinite
            ? constraints.maxWidth
            : MediaQuery.sizeOf(context).width - 32;
        return CupertinoContextMenu(
          actions: [
            CupertinoContextMenuAction(
              child: const Text('播放'),
              onPressed: () {
                Navigator.of(context).pop();
                onPlay();
              },
            ),
            CupertinoContextMenuAction(
              child: Text(isFav ? '取消收藏' : '收藏'),
              onPressed: () {
                Navigator.of(context).pop();
                onToggleFav();
              },
            ),
            CupertinoContextMenuAction(
              child: const Text('更多…'),
              // Pop first, open the sheet AFTER the menu route is
              // fully gone: popping and pushing in the same frame
              // leaves the menu's duplicate row in the semantics
              // tree while the sheet builds, and the framework
              // throws in flushSemantics. The 350ms covers the
              // menu's close animation; the sheet then rises as
              // the menu finishes shrinking away (Apple Music
              // behaves the same way).
              onPressed: () async {
                Navigator.of(context).pop();
                await Future.delayed(const Duration(milliseconds: 350));
                if (!context.mounted) return;
                onLongPress!(context);
              },
            ),
          ],
          child: SizedBox(width: width, child: content),
        );
      },
    );
  }
}
