import 'dart:async';

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart' hide GlassCard;

import '../../../core/theme/glass.dart';
import '../../../core/theme/haptics.dart';
import '../../../core/theme/hao_themes.dart';
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
class MiniPlayerBar extends StatelessWidget {
  const MiniPlayerBar({super.key, required this.onOpenPlayer});

  final VoidCallback onOpenPlayer;

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
  Widget build(BuildContext context) {
    final player = MusicPlayerController.ensure();
    final theme = HaoTheme.of(context);
    return Obx(() {
      final song = player.currentSong;
      if (song == null) return const SizedBox.shrink();
      return GlassPressScale(
        pressedScale: 0.97,
        child: Container(
          margin: const EdgeInsets.fromLTRB(12, 0, 12, 8),
          decoration: BoxDecoration(
            borderRadius: BorderRadius.circular(999),
            boxShadow: glassMiniPlayerShadow(context),
          ),
          child: GlassAdaptiveScope(
            // Same premium floor as the tab bar (app_shell.dart): the
            // adaptive scope may demote premium to frosted glass on a
            // busy phone; the mini player is floating chrome and must
            // stay premium. Glass parameters themselves are already
            // the demo's (ios27 preset + premium).
            minQuality: GlassQuality.premium,
            child: GlassContainer(
              shape: const LiquidRoundedSuperellipse(borderRadius: 999),
              padding: const EdgeInsets.fromLTRB(12, 4, 6, 4),
              useOwnLayer: true,
              quality: GlassQuality.premium,
              child: Material(
                color: Colors.transparent,
                child: InkWell(
                  onTap: () {
                    HaoHaptics.tap();
                    onOpenPlayer();
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
