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
import '../music_player_controller.dart';

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
                    color: Colors.white.withValues(alpha: 0.3),
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
                                fontSize: 17,
                                fontWeight: FontWeight.w700,
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
                        return ListView.builder(
                          itemCount: queue.length,
                          itemBuilder: (ctx, i) {
                            final song = queue[i];
                            final isCurrent =
                                i == controller.currentIndex.value;
                            return InkWell(
                              onTap: () {
                                onClose();
                                unawaited(controller.playIndex(i));
                              },
                              child: Container(
                                color: isCurrent
                                    ? theme.accentSoft
                                    : Colors.transparent,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 16,
                                  vertical: 8,
                                ),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(6),
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
                                          : Image.network(
                                              song.cover,
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
