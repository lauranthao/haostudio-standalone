// Video poster card — Infuse copy (H4 + H9).
//
// - 2:3 portrait poster, radius 8 via HaoRadius.standard (B-P2-2:
//   the old "FIXED 10px radius" comment here was wrong — the code
//   has always used the theme radius).
// - Title 13px/600 below, one muted 12px meta line (`year · type`).
// - NO rating badge on the poster (rating lives on the detail page
//   only, as in Infuse). NO coloured corner badge: the episode-count
//   badge is a subtle dark pill, shown only when total > 1.
// - Missing artwork = a dark placeholder tile (▶ glyph on a dark
//   tile), never the music cover.
// - Watched state = a small white ✓ in a dark circle top-left
//   (Infuse Phase 2; lookup is prebuilt once per render by the caller
//   via [isWatched]).

import '../../core/theme/hao_radius.dart';
import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import 'video_models.dart';
import 'widgets/referer_image.dart';

/// Metrics of the text block below the poster in [VideoPosterCard].
/// The grid's cell ratio is derived from these (see [VideoPosterGrid]),
/// so changing a size here automatically re-fits the cells — never
/// hard-code a childAspectRatio for this grid.
const double _kPosterTitleGap = 6;
const double _kTitleMetaGap = 2;
const double _kTitleFontSize = 13;
const double _kMetaFontSize = 12;
const double _kTextLineHeight = 1.25;

/// Height of the text block below the poster: gap + title line +
/// gap + meta line. 6 + 13 x 1.25 + 2 + 12 x 1.25 = 39.25.
const double kVideoPosterCardTextHeight = _kPosterTitleGap +
    _kTitleFontSize * _kTextLineHeight +
    _kTitleMetaGap +
    _kMetaFontSize * _kTextLineHeight;

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
                  // Missing-artwork tile: theme glass, NOT a hardcoded
                  // dark tile — the old 0xFF1C1C1E read as a black hole
                  // in all four light modes. Over real artwork the
                  // badges below still use black scrims (on-photo).
                  color: theme.surfaceStrong,
                  borderRadius: BorderRadius.circular(HaoRadius.standard),
                  border: Border.all(color: theme.hairline),
                  // Soft lift in light modes; invisible (harmless)
                  // on dark scaffolds. Shadow is black-alpha, not a
                  // theme colour — it is not a surface or text colour.
                  boxShadow: [
                    BoxShadow(
                      color: Colors.black.withValues(alpha: 0.10),
                      blurRadius: 12,
                      offset: const Offset(0, 4),
                    ),
                  ],
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
                            borderRadius: BorderRadius.circular(HaoRadius.standard),
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
            const SizedBox(height: _kPosterTitleGap),
            Text(
              item.name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: _kTitleFontSize,
                fontWeight: FontWeight.w600,
                height: _kTextLineHeight,
              ),
            ),
            const SizedBox(height: _kTitleMetaGap),
            Text(
              [
                if (item.year.isNotEmpty) item.year,
                if (item.type.isNotEmpty) item.type,
              ].join(' · '),
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: theme.textMuted,
                fontSize: _kMetaFontSize,
                height: _kTextLineHeight,
              ),
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
    // Theme glass + muted glyph: legible in all 4 themes x light/dark.
    final theme = HaoTheme.of(context);
    return ColoredBox(
      color: theme.surfaceStrong,
      child: Center(
        child: Icon(Icons.play_arrow, color: theme.textMuted, size: 36),
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
    return LayoutBuilder(
      builder: (context, constraints) {
        // Cell height = poster (2:3) + the card's fixed text block.
        // A fixed childAspectRatio (the old 0.58) only fits one width:
        // at 420pt it left the text block 12px short of its cell, so
        // every card overflowed and the meta line painted into the
        // row gap (chen 2026-11-17: 影视分类页显示不全). Derive the
        // ratio from the measured width so it is exact at any width.
        final maxW = constraints.maxWidth;
        final ratio = maxW.isFinite ? _cellRatio(maxW) : 0.55;
        return GridView.builder(
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          gridDelegate: SliverGridDelegateWithFixedCrossAxisCount(
            crossAxisCount: 3,
            crossAxisSpacing: 12,
            mainAxisSpacing: 16,
            childAspectRatio: ratio,
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
      },
    );
  }
}

/// Exact cell ratio for a 3-column grid of [VideoPosterCard]s at the
/// given grid width: column width / (poster height + text block).
double _cellRatio(double gridWidth) {
  final colW = (gridWidth - 2 * 12) / 3;
  return colW / (colW * 3 / 2 + kVideoPosterCardTextHeight);
}
