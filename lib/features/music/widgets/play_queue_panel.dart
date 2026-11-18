import 'dart:async';

// Floating play-queue panel (fix 15) — Apple Music "Up Next" style.
//
// A floating card above the player (not a full page, not a bottom sheet
// that covers the player): queue rows show cover/title/artist with the
// current track marked; tapping a queue row plays that track; the panel
// scrolls if the queue is long; Cancel/close dismisses it; tapping
// outside dismisses it.

import 'package:flutter/material.dart';
import 'package:get/get.dart';
import 'package:liquid_glass_widgets/liquid_glass_widgets.dart';

import '../../../core/theme/hao_themes.dart';
import '../../../core/theme/haptics.dart';
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
          // Kumone redo: library glass (standard — the queue is a
          // dense reorderable list, never premium shader) instead of
          // the self-made GlassCard. Rows inside stay solid.
          child: GlassContainer(
            shape: const LiquidRoundedSuperellipse(borderRadius: 24),
            quality: GlassQuality.standard,
            useOwnLayer: true,
            padding: EdgeInsets.zero,
            child: SizedBox(
              width: MediaQuery.of(context).size.width * 0.86,
              height: MediaQuery.of(context).size.height * 0.62,
              child: Column(
                children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(20, 16, 8, 8),
                    child: Row(
                      children: [
                        // Queue count in the header (Beans
                        // `QueueView`: "接下来 (N 首）").
                        Expanded(
                          child: Obx(
                            () => Text(
                              '播放列表 · ${controller.queue.length} 首',
                              style: TextStyle(
                                color: theme.textPrimary,
                                fontSize: 18,
                                fontWeight: FontWeight.w800,
                              ),
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
                        // Clear queue (stage 2, Beans `QueueView`:
                        // topBarTrailing `···` menu with a trash
                        // "清空队列" item — `PlayerManager.clearQueue`
                        // keeps only the current song). Disabled when
                        // there is nothing to clear beyond the song
                        // playing (0 or 1 items), so the menu can
                        // never offer a no-op.
                        // NOTE: no Obx here — the PopupMenuButton's
                        // builder reads no observable at build time
                        // (queue.length is read inside itemBuilder,
                        // which runs when the menu OPENS, outside the
                        // build). Wrapping it in Obx threw GetX's
                        // "improper use of a GetX" every time the panel
                        // opened (RxInterface.notifyChildren throws
                        // when the builder tracks nothing). The menu
                        // item's enabled state is evaluated fresh at
                        // open time, so no rebuild is needed at all.
                        // Same rule as the player star button (no Obx
                        // around non-Rx reads).
                        PopupMenuButton<String>(
                          icon: Icon(
                            Icons.more_horiz,
                            color: theme.textSecondary,
                          ),
                          tooltip: '更多',
                          onSelected: (value) {
                            if (value == 'clear') {
                              HaoHaptics.tap();
                              controller.clearQueue();
                            }
                          },
                          itemBuilder: (ctx) => [
                            PopupMenuItem<String>(
                              value: 'clear',
                              enabled: controller.queue.length > 1,
                              child: Row(
                                children: [
                                  Icon(
                                    Icons.delete_outline,
                                    size: 18,
                                    color: theme.textSecondary,
                                  ),
                                  const SizedBox(width: 8),
                                  const Text('清空队列'),
                                ],
                              ),
                            ),
                          ],
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
                        final n = (seenKeys[s.identityKey] ?? 0) + 1;
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
                          final isCurrent = i == controller.currentIndex.value;
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
                                            image: MusicImageProvider(
                                              song.cover,
                                            ),
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
                                    disabledColor: theme.textMuted.withValues(
                                      alpha: 0.35,
                                    ),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 32,
                                    ),
                                    onPressed: i == 0
                                        ? null
                                        : () => controller.moveQueueUp(i),
                                  ),
                                  IconButton(
                                    icon: const Icon(
                                      Icons.arrow_downward,
                                      size: 18,
                                    ),
                                    color: theme.textSecondary,
                                    disabledColor: theme.textMuted.withValues(
                                      alpha: 0.35,
                                    ),
                                    padding: EdgeInsets.zero,
                                    constraints: const BoxConstraints(
                                      minWidth: 32,
                                      minHeight: 32,
                                    ),
                                    onPressed: i == queue.length - 1
                                        ? null
                                        : () => controller.moveQueueDown(i),
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
      ],
    );
  }
}
