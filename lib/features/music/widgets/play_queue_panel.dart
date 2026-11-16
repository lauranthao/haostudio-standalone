import 'dart:async';

// Floating play-queue panel (fix 15) — Apple Music "Up Next" style.
//
// A floating card above the player (not a full page, not a bottom sheet
// that covers the player): queue rows show cover/title/artist with the
// current track marked; tapping a queue row plays that track; the panel
// scrolls if the queue is long; Cancel/close dismisses it; tapping
// outside dismisses it.

import 'dart:ui';

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../services/music/play_mode.dart';
import '../music_player_controller.dart';
import 'track_more_sheet.dart';
import 'music_image.dart';

class PlayQueuePanel extends StatelessWidget {
  const PlayQueuePanel({super.key, required this.onClose});

  final VoidCallback onClose;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final controller = MusicPlayerController.ensure();
    return Stack(
      children: [
        Positioned.fill(
          child: GestureDetector(
            onTap: onClose,
            child: Container(color: Colors.black.withValues(alpha: 0.3)),
          ),
        ),
        Center(
          child: ClipRRect(
            borderRadius: BorderRadius.circular(24),
            child: BackdropFilter(
              filter: ImageFilter.blur(
                sigmaX: theme.glassBlurSigma,
                sigmaY: theme.glassBlurSigma,
              ),
              child: Container(
                width: MediaQuery.of(context).size.width * 0.86,
                height: MediaQuery.of(context).size.height * 0.62,
                decoration: BoxDecoration(
                  color: theme.surfaceStrong,
                  borderRadius: BorderRadius.circular(24),
                  border: Border.all(
                    color: theme.textPrimary.withValues(alpha: 0.22),
                    width: 1,
                  ),
                ),
                child: Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                      child: Row(
                        children: [
                          Expanded(
                            child: Text(
                              '播放列表',
                              style: TextStyle(
                                color: theme.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                          ),
                          // Play-mode button (M-P0-1): cycles the five
                          // modes, icon + label, same control as the
                          // player `···` sheet.
                          Obx(
                            () => TextButton.icon(
                              onPressed: () =>
                                  unawaited(controller.cyclePlayMode()),
                              icon: Icon(
                                playModeIcon(controller.mode),
                                color: theme.accent,
                                size: 18,
                              ),
                              label: Text(
                                controller.mode.label,
                                style: TextStyle(
                                  color: theme.accent,
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ),
                          ),
                          IconButton(
                            icon: Icon(Icons.close, color: theme.textSecondary),
                            onPressed: onClose,
                          ),
                        ],
                      ),
                    ),
                    Expanded(
                      child: Obx(() {
                        final queue = controller.queue;
                        if (queue.isEmpty) {
                          return Center(
                            child: Text(
                              '队列为空',
                              style: TextStyle(color: theme.textMuted),
                            ),
                          );
                        }
                        // M-P0-4: rows reorder by drag handle or ↑/↓
                        // buttons; the current track stays highlighted.
                        // Keys are occurrence-qualified (precomputed in
                        // list order) so a song that appears twice in
                        // the queue still has unique keys, which
                        // ReorderableListView requires.
                        final rowKeys = <String>[];
                        final seenKeys = <String, int>{};
                        for (final s in queue) {
                          final n =
                              (seenKeys[s.identityKey] ?? 0) + 1;
                          seenKeys[s.identityKey] = n;
                          rowKeys.add('${s.identityKey}#$n');
                        }
                        // onReorderItem already adjusts newIndex for
                        // the removed item — it is the final index.
                        return ReorderableListView.builder(
                          buildDefaultDragHandles: false,
                          itemCount: queue.length,
                          onReorderItem: (oldIndex, newIndex) {
                            controller.moveQueueItem(oldIndex, newIndex);
                          },
                          itemBuilder: (ctx, i) {
                            final song = queue[i];
                            final isCurrent =
                                i == controller.currentIndex.value;
                            return InkWell(
                              key: ValueKey(rowKeys[i]),
                              onTap: () {
                                onClose();
                                unawaited(controller.playIndex(i));
                              },
                              child: Container(
                                color: isCurrent
                                    ? theme.accentSoft
                                    : Colors.transparent,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 8,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    ReorderableDragStartListener(
                                      index: i,
                                      child: Icon(
                                        Icons.drag_handle,
                                        color: theme.textMuted,
                                        size: 20,
                                      ),
                                    ),
                                    const SizedBox(width: 4),
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(8),
                                      child: song.cover.isEmpty
                                          ? Container(
                                              width: 40,
                                              height: 40,
                                              color: theme.accentSoft,
                                              child: Icon(
                                                Icons.music_note,
                                                color: theme.textMuted,
                                                size: 20,
                                              ),
                                            )
                                          : Image(
                                              image: MusicImageProvider(song.cover),
                                              width: 40,
                                              height: 40,
                                              fit: BoxFit.cover,
                                              errorBuilder: (_, _, _) =>
                                                  Container(
                                                width: 40,
                                                height: 40,
                                                color: theme.accentSoft,
                                                child: Icon(
                                                  Icons.music_note,
                                                  color: theme.textMuted,
                                                  size: 20,
                                                ),
                                              ),
                                            ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        mainAxisSize: MainAxisSize.min,
                                        children: [
                                          Text(
                                            song.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: isCurrent
                                                  ? theme.accent
                                                  : theme.textPrimary,
                                              fontWeight: isCurrent
                                                  ? FontWeight.w700
                                                  : FontWeight.w500,
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
                                    if (isCurrent)
                                      Icon(
                                        Icons.equalizer,
                                        color: theme.accent,
                                        size: 20,
                                      ),
                                    // ↑/↓ move buttons (M-P0-4).
                                    IconButton(
                                      icon: const Icon(
                                        Icons.arrow_upward,
                                        size: 18,
                                      ),
                                      color: theme.textSecondary,
                                      disabledColor: theme.textMuted
                                          .withValues(alpha: 0.35),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 32,
                                        minHeight: 32,
                                      ),
                                      onPressed: i == 0
                                          ? null
                                          : () =>
                                              controller.moveQueueUp(i),
                                    ),
                                    IconButton(
                                      icon: const Icon(
                                        Icons.arrow_downward,
                                        size: 18,
                                      ),
                                      color: theme.textSecondary,
                                      disabledColor: theme.textMuted
                                          .withValues(alpha: 0.35),
                                      padding: EdgeInsets.zero,
                                      constraints: const BoxConstraints(
                                        minWidth: 32,
                                        minHeight: 32,
                                      ),
                                      onPressed: i == queue.length - 1
                                          ? null
                                          : () =>
                                              controller.moveQueueDown(i),
                                    ),
                                  ],
                                ),
                              ),
                            );
                          },
                        );
                      }),
                    ),
                    Padding(
                      padding: const EdgeInsets.all(12),
                      child: SizedBox(
                        width: double.infinity,
                        child: TextButton(
                          onPressed: onClose,
                          child: Text(
                            '取消',
                            style: TextStyle(color: theme.textSecondary),
                          ),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}
