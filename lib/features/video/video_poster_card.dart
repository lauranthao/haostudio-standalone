// Video poster card — Infuse copy (H4 + H9).
//
// - 2:3 portrait poster, FIXED 10px radius (NOT the theme radius —
//   media art looks identical in all 4 themes).
// - Title 13px/600 below, one muted 12px meta line (`year · type`).
// - NO rating badge on the poster (rating lives on the detail page
//   only, as in Infuse). NO coloured corner badge: the episode-count
//   badge is a subtle dark pill, shown only when total > 1.
// - Missing artwork = a dark placeholder tile (▶ glyph on a dark
//   tile), never the music cover.
// - Watched state = a small white ✓ in a dark circle top-left
//   (Infuse Phase 2; lookup is prebuilt once per render by the caller
//   via [isWatched]).

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import 'video_models.dart';
import 'widgets/referer_image.dart';

class VideoPosterCard extends StatelessWidget {
  const VideoPosterCard({
    super.key,
    required this.item,
    this.onTap,
    this.onPointerDown,
    this.isWatched = false,
    this.showCountBadge = true,
  });

  final VideoItem item;
  final VoidCallback? onTap;

  /// Pointer-down prefetch hook (detail prefetch, max 3 inflight).
  final VoidCallback? onPointerDown;
  final bool isWatched;
  final bool showCountBadge;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final total = int.tryParse(item.total) ?? 0;
    return Listener(
      onPointerDown: (_) => onPointerDown?.call(),
      child: GestureDetector(
        onTap: onTap,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            AspectRatio(
              aspectRatio: 2 / 3,
              child: Container(
                decoration: BoxDecoration(
                  // Dark tile under the image (artwork area is always
                  // dark, per the Infuse spec — hardcoded here, not a
                  // theme colour).
                  color: const Color(0xFF1C1C1E),
                  borderRadius: BorderRadius.circular(10),
                ),
                clipBehavior: Clip.antiAlias,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (item.pic.isNotEmpty)
                      RefererImage(
                        url: item.pic,
                        fit: BoxFit.cover,
                        fallback: const _MissingArtwork(),
                      )
                    else
                      const _MissingArtwork(),
                    if (isWatched)
                      const Positioned(
                        top: 6,
                        left: 6,
                        child: _WatchedMark(),
                      ),
                    if (showCountBadge && total > 1)
                      Positioned(
                        top: 6,
                        right: 6,
                        child: Container(
                          padding: const EdgeInsets.symmetric(
                            horizontal: 7,
                            vertical: 2,
                          ),
                          decoration: BoxDecoration(
                            color: const Color(0xA6000000),
                            borderRadius: BorderRadius.circular(8),
                          ),
                          child: Text(
                            '$total 集',
                            style: const TextStyle(
                              color: Colors.white,
                              fontSize: 11,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 13,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 2),
            Text(
              [
                if (item.year.isNotEmpty) item.year,
                if (item.type.isNotEmpty) item.type,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.textMuted, fontSize: 12),
            ),
          ],
        ),
      ),
    );
  }
}

class _MissingArtwork extends StatelessWidget {
  const _MissingArtwork();

  @override
  Widget build(BuildContext context) {
    return const ColoredBox(
      color: Color(0xFF1C1C1E),
      child: Center(
        child: Icon(Icons.play_arrow, color: Color(0xFF8E8E93), size: 36),
      ),
    );
  }
}

class _WatchedMark extends StatelessWidget {
  const _WatchedMark();

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 20,
      height: 20,
      decoration: const BoxDecoration(
        color: Color(0xA6000000),
        shape: BoxShape.circle,
      ),
      child: const Icon(Icons.check, color: Colors.white, size: 13),
    );
  }
}

/// Shared poster grid (3 columns, tight even gaps) used by home rows
/// (horizontal), search, type and favourites pages.
class VideoPosterGrid extends StatelessWidget {
  const VideoPosterGrid({
    super.key,
    required this.items,
    required this.onTapItem,
    this.onPointerDownItem,
    this.watchedKeys = const {},
  });

  final List<VideoItem> items;
  final void Function(VideoItem item) onTapItem;
  final void Function(VideoItem item)? onPointerDownItem;
  final Set<String> watchedKeys;

  @override
  Widget build(BuildContext context) {
    return GridView.builder(
      shrinkWrap: true,
      physics: const NeverScrollableScrollPhysics(),
      gridDelegate: const SliverGridDelegateWithFixedCrossAxisCount(
        crossAxisCount: 3,
        crossAxisSpacing: 12,
        mainAxisSpacing: 14,
        // Poster 2:3 + ~44px of title/meta below.
        childAspectRatio: 0.58,
      ),
      itemCount: items.length,
      itemBuilder: (context, i) {
        final item = items[i];
        return VideoPosterCard(
          item: item,
          isWatched: watchedKeys.contains(item.identityKey),
          onTap: () => onTapItem(item),
          onPointerDown: onPointerDownItem == null
              ? null
              : () => onPointerDownItem!(item),
        );
      },
    );
  }
}
