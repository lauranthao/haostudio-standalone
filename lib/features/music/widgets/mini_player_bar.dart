import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' hide GlassCard;

import '../../../core/theme/glass.dart';
import '../../../core/theme/haptics.dart';
import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/liquid_glass_theme.dart';
import 'music_image.dart';
import 'track_more_sheet.dart';
import '../music_player_controller.dart';

/// The floating mini player bar: cover + title + live lyric/artist line,
/// mode / prev / play-pause / next. Renders only when a song is loaded
/// (Kumone :235-247, #35 — no empty platter when idle).
///
/// Used in two places, same widget:
/// - embedded at the bottom of the music home (above the tab bar);
/// - as the app-level overlay on every music sub-page (see
///   mini_player_overlay.dart).
///
/// Design values (Kumone `MiniPlayerView`, with the differences noted
/// in the original home code):
/// - Capsule radius 999, shadow black 0.12 r10 y4, horizontal margin
///   12, 8pt gap above the tab bar. It floats above the tab bar, not
///   attached to it.
/// - Buttons are mode / prev / play / next (Kumone: prev / play /
///   next). The mode button is our existing feature — removing it to
///   match Kumone would delete functionality. Mode takes the prev/next
///   treatment (14 secondary); there is no Kumone value for a mode
///   button, so 14 secondary is the judgement call.
/// - The shell is `liquid_glass_widgets` premium glass (floating
///   chrome) instead of `.regularMaterial` — same radius/padding/
///   shadow/margin, real shader refraction instead of plain blur.
///   The 0.5pt primary-0.08 stroke is mapped to theme.hairline
///   (black 0.08 light / white 0.12 dark). Buttons inside stay plain
///   IconButtons (no glass buttons inside a glass container).
/// - No tooltips on the buttons: Tooltip needs an Overlay ancestor,
///   and the overlay placement sits above the root Navigator, where
///   there is none (a tooltip there throws "No Overlay widget found"
///   while building). The other three buttons never had tooltips.
class MiniPlayerBar extends StatefulWidget {
  const MiniPlayerBar({
    super.key,
    required this.onOpenPlayer,
    this.margin = const EdgeInsets.fromLTRB(12, 0, 12, 8),
  });

  /// Receives the bar's own global rect (its capsule, margins
  /// excluded — the render box of the bar itself, which is the outer
  /// Container; the margin sits outside the box). The opener expands
  /// the player page from that rect (see `player_expand_route.dart`);
  /// a null rect means the box was gone and the opener falls back to
  /// the plain slide.
  final void Function(Rect? barRect) onOpenPlayer;

  /// The capsule's outer margin (default the usual 12/0/12/8); the
  /// expand transition's fading bar copy passes zero because it is
  /// already positioned exactly on the bar's rect.
  final EdgeInsets margin;

  /// Bottom clearance a music sub-page's scrollable needs so its last
  /// row is not covered by the floating overlay: bar height 52 (44
  /// content + 4 + 4 padding) + 8 bottom margin + 12 gap.
  static const double bottomClearance = 72;

  /// Full bottom clearance for a music sub-page scrollable: the bar
  /// itself plus the device bottom safe area, because the overlay sits
  /// at bottom: padding.bottom (home indicator).
  static double bottomClearanceFor(BuildContext context) =>
      bottomClearance + MediaQuery.of(context).padding.bottom;

  @override
  State<MiniPlayerBar> createState() => _MiniPlayerBarState();
}

/// State for [MiniPlayerBar]: holds the GlobalKey on the capsule so
/// the expand transition can capture the bar's own rect at tap time.
/// (The build context's `findRenderObject` returns the overlay's
/// full-width Positioned box, not the capsule — the key is the only
/// exact handle. Verified by a diagnostic run: the context rect came
/// back as the full screen width, 0→390.)
class _MiniPlayerBarState extends State<MiniPlayerBar> {
  final _barKey = GlobalKey();

  @override
  Widget build(BuildContext context) {
    final player = MusicPlayerController.ensure();
    final theme = HaoTheme.of(context);
    return Obx(() {
      final song = player.currentSong;
      if (song == null) return const SizedBox.shrink();
      return GlassPressScale(
        pressedScale: 0.97,
        child: Container(
          key: _barKey,
          margin: widget.margin,
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: glassMiniPlayerShadow(context),
          ),
          child: GlassAdaptiveScope(
            // Same premium floor as the tab bar (app_shell.dart): the
            // adaptive scope may demote premium to frosted glass on a
            // busy phone; the mini player is floating chrome and must
            // stay premium. Glass parameters are the unified-page
            // chrome (ios27 optics re-tinted to the page background —
            // see HaoLiquidGlass.chromeSettings), so the bar reads as
            // part of the page instead of a separate slab.
            minQuality: GlassQuality.premium,
            child: GlassContainer(
              shape: const LiquidRoundedSuperellipse(borderRadius: 999),
              padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
              settings: HaoLiquidGlass.chromeSettings(context),
              useOwnLayer: true,
              quality: GlassQuality.premium,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    HaoHaptics.tap();
                    // The bar's own rect (the keyed Container's box —
                    // the margin sits outside it, so this is the
                    // capsule). Captured at tap time; the opener
                    // expands the player page from it. The press
                    // scale (0.97) may shrink it by up to 3% at tap
                    // time — invisible inside a 400ms spring.
                    final box = _barKey.currentContext
                            ?.findRenderObject()
                        as RenderBox?;
                    final rect = box == null
                        ? null
                        : box.localToGlobal(Offset.zero) & box.size;
                    widget.onOpenPlayer(rect);
                  },
                  borderRadius: BorderRadius.circular(999),
                  child: Row(
                    children: [
                      Container(
                        decoration: BoxDecoration(
                          borderRadius: BorderRadius.circular(6),
                          boxShadow: const [
                            BoxShadow(
                              color: Color.fromRGBO(0, 0, 0, 0.15),
                              blurRadius: 4,
                              offset: Offset(0, 1),
                            ),
                          ],
                        ),
                        child: ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: song.cover.isEmpty
                              ? Container(
                                  width: 32,
                                  height: 32,
                                  color: theme.accentSoft,
                                  child: Icon(
                                    Icons.music_note,
                                    color: theme.textMuted,
                                  ),
                                )
                              : Image(
                                  image: MusicImageProvider(song.cover),
                                  width: 32,
                                  height: 32,
                                  fit: BoxFit.cover,
                                  errorBuilder: (_, _, _) => Container(
                                    width: 32,
                                    height: 32,
                                    color: theme.accentSoft,
                                    child: Icon(
                                      Icons.music_note,
                                      color: theme.textMuted,
                                    ),
                                  ),
                                ),
                        ),
                      ),
                      const SizedBox(width: 8),
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
                                fontSize: 13,
                                fontWeight: FontWeight.w600,
                              ),
                            ),
                            const SizedBox(height: 3),
                            // Live lyric line (Beans `MiniPlayerView`): the
                            // second line shows the current lyric line while
                            // one is playing, falling back to the artist.
                            // The inner Obx only rebuilds this subtitle when
                            // the position/lyrics change.
                            Obx(() {
                              final idx = player.lyricIndexFor(
                                player.position.value,
                              );
                              final lines = player.lyrics;
                              final line = (idx >= 0 && idx < lines.length)
                                  ? lines[idx].text
                                  : null;
                              return AnimatedSwitcher(
                                duration: const Duration(milliseconds: 250),
                                child: Text(
                                  line ?? song.artist,
                                  key: ValueKey(line ?? song.artist),
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    color: theme.textSecondary,
                                    fontSize: 10,
                                  ),
                                ),
                              );
                            }),
                          ],
                        ),
                      ),
                      const SizedBox(width: 4),
                      _MiniControl(
                        buttonKey: const ValueKey('mini-mode'),
                        icon: playModeIcon(player.mode),
                        size: 14,
                        color: theme.textSecondary,
                        onPressed: () {
                          HaoHaptics.tap();
                          player.cyclePlayMode();
                        },
                      ),
                      const SizedBox(width: 4),
                      _MiniControl(
                        icon: Icons.skip_previous,
                        size: 14,
                        color: theme.textSecondary,
                        onPressed: () {
                          HaoHaptics.tap();
                          unawaited(player.prev());
                        },
                      ),
                      const SizedBox(width: 4),
                      _MiniControl(
                        icon: player.isPlaying.value
                            ? Icons.pause
                            : Icons.play_arrow,
                        size: 15,
                        color: theme.textPrimary,
                        onPressed: () {
                          HaoHaptics.tap();
                          player.togglePlayPause();
                        },
                      ),
                      const SizedBox(width: 4),
                      _MiniControl(
                        icon: Icons.skip_next,
                        size: 14,
                        color: theme.textSecondary,
                        onPressed: () {
                          HaoHaptics.tap();
                          player.next();
                        },
                      ),
                    ],
                  ),
                ),
              ),
            ),
          ),
        ),
      );
    });
  }
}

class _MiniControl extends StatelessWidget {
  const _MiniControl({
    this.buttonKey,
    required this.icon,
    required this.size,
    required this.color,
    required this.onPressed,
  });

  /// Key on the IconButton itself (tests find the mode control this way:
  /// no tooltip — Tooltip needs an Overlay ancestor and the overlay
  /// placement sits above the root Navigator, where there is none).
  final Key? buttonKey;
  final IconData icon;
  final double size;
  final Color color;
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: 44,
      height: 44,
      child: IconButton(
        key: buttonKey,
        icon: Icon(icon, size: size, color: color),
        padding: EdgeInsets.zero,
        onPressed: onPressed,
      ),
    );
  }
}
