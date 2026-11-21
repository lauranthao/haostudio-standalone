import 'package:flutter/material.dart';

import '../../../core/theme/hao_themes.dart';

/// Volume row for the music player (Windows only — the sheet gates it
/// with `Platform.isWindows`, so iOS never sees it).
///
/// This is the APP-INTERNAL gain (MusicPlayerController.setAppVolume →
/// MpvMusicPlayer), not the system volume: the wheel / keyboard ↑/↓
/// shortcuts keep stepping the system volume, and the two gains are
/// independent in series, so they never fight. Dragging applies live
/// ([onChanged] per tick); [onChangeEnd] fires once on release so the
/// caller can persist. Tapping the speaker toggles mute ([onToggleMute]);
/// the icon follows the level (off / down / up).
///
/// Design values are copied from the player itself, not estimated:
/// horizontal padding 24 like `_progressBar`; speaker 17pt white 0.8
/// like the transport/bottom icon rows; `%` text 12pt w500 white 0.72
/// like the bottom icons; slider theme like the Settings app-volume
/// slider (trackHeight 3, thumb r8, overlay r16, inactive white 0.25
/// like the progress track) with the accent passed through the same
/// dark-page rule as the sheet's `_activeOnDark` (too-dark accent
/// falls back to white, otherwise the theme accent).
class PlayerVolumeRow extends StatelessWidget {
  const PlayerVolumeRow({
    super.key,
    required this.volume,
    required this.onChanged,
    required this.onChangeEnd,
    required this.onToggleMute,
  });

  /// Current app gain, 0..1 (clamped for display).
  final double volume;

  /// Per drag tick — apply live, do not persist yet.
  final ValueChanged<double> onChanged;

  /// Once on release — persist.
  final ValueChanged<double> onChangeEnd;

  /// Speaker tap — mute / restore.
  final VoidCallback onToggleMute;

  static Color _activeOnDark(Color accent) =>
      accent.computeLuminance() < 0.15 ? Colors.white : accent;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final v = volume.clamp(0.0, 1.0);
    final icon = v <= 0
        ? Icons.volume_off
        : v < 0.5
            ? Icons.volume_down
            : Icons.volume_up;
    final accent = _activeOnDark(theme.accent);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          GestureDetector(
            key: const ValueKey('playerVolumeMute'),
            onTap: onToggleMute,
            behavior: HitTestBehavior.opaque,
            child: Icon(
              icon,
              size: 17,
              color: Colors.white.withValues(alpha: 0.8),
            ),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: SliderTheme(
              data: SliderTheme.of(context).copyWith(
                activeTrackColor: accent,
                inactiveTrackColor: Colors.white.withValues(alpha: 0.25),
                thumbColor: accent,
                trackHeight: 3,
                thumbShape: const RoundSliderThumbShape(
                  enabledThumbRadius: 8,
                ),
                overlayShape: const RoundSliderOverlayShape(
                  overlayRadius: 16,
                ),
              ),
              child: Slider(
                key: const ValueKey('playerVolumeSlider'),
                value: v,
                onChanged: onChanged,
                onChangeEnd: onChangeEnd,
              ),
            ),
          ),
          const SizedBox(width: 12),
          SizedBox(
            width: 40,
            child: Text(
              '${(v * 100).round()}%',
              textAlign: TextAlign.right,
              style: TextStyle(
                color: Colors.white.withValues(alpha: 0.72),
                fontSize: 12,
                fontWeight: FontWeight.w500,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
