// Video history page (V-P0-1) — local watch history only.
//
// Lists watched videos from VideoHistoryStore.getAll() (most recent
// first, max 20). Each row shows the thumb, title, episode + remaining
// time, and ONE progress bar. The whole row is the single
// continue-playing affordance: tapping it opens the detail page with
// autoResume, so playback resumes at the saved position (audit P2 —
// no second "继续播放" button per item). Empty state is honest:
// "还没有观看记录". Clear-all lives in the AppBar and also clears the
// saved resume positions, so a cleared video offers no stale resume.

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import 'video_detail_page.dart';
import 'video_history_store.dart';
import 'video_models.dart';
import 'widgets/referer_image.dart';

class VideoHistoryPage extends StatefulWidget {
  const VideoHistoryPage({super.key});

  @override
  State<VideoHistoryPage> createState() => _VideoHistoryPageState();
}

class _VideoHistoryPageState extends State<VideoHistoryPage> {
  void _openDetail(WatchHistoryEntry entry) {
    Navigator.of(context)
        .push(
          MaterialPageRoute<void>(
            builder: (_) => VideoDetailPage(
              sourceId: entry.source,
              vodId: entry.vodId,
              preload: VideoItem(
                source: entry.source,
                sourceName: '',
                vodId: entry.vodId,
                name: entry.title,
                pic: entry.pic,
                picAlt: entry.picAlt,
              ),
              autoResume: true,
            ),
          ),
        )
        .then((_) {
          // Resume/progress may have changed while watching.
          if (mounted) setState(() {});
        });
  }

  Future<void> _confirmClear() async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('清空历史记录？'),
        content: const Text('将删除全部观看记录与续播位置，此操作无法恢复。'),
        actions: [
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('取消'),
          ),
          TextButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('清空'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    await VideoHistoryStore.clearAll();
    if (mounted) setState(() {});
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final history = VideoHistoryStore.getAll();
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(
        title: const Text('历史记录'),
        backgroundColor: theme.surface,
        actions: [
          if (history.isNotEmpty)
            IconButton(
              icon: const Icon(Icons.delete_outline),
              tooltip: '清空历史记录',
              onPressed: _confirmClear,
            ),
        ],
      ),
      body: history.isEmpty
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(
                    Icons.history,
                    size: 48,
                    color: theme.textMuted,
                  ),
                  const SizedBox(height: 16),
                  Text(
                    '还没有观看记录',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 17,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    '看过的影片会出现在这里',
                    style: TextStyle(
                      color: theme.textMuted,
                      fontSize: 14,
                    ),
                  ),
                ],
              ),
            )
          : ListView.separated(
              padding: const EdgeInsets.fromLTRB(14, 8, 14, 16),
              itemCount: history.length,
              separatorBuilder: (_, _) =>
                  Divider(height: 1, color: theme.hairline),
              itemBuilder: (context, i) {
                final entry = history[i];
                return _HistoryRow(
                  entry: entry,
                  onTap: () => _openDetail(entry),
                );
              },
            ),
    );
  }
}

/// One history row: 16:9 thumb + progress overlay, title, episode +
/// remaining time. The whole row is the resume affordance — no second
/// button (audit P2); the trailing play icon is a visual cue only.
class _HistoryRow extends StatelessWidget {
  const _HistoryRow({required this.entry, required this.onTap});

  final WatchHistoryEntry entry;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final metaParts = <String>[
      if (entry.epName.isNotEmpty) entry.epName,
      if (entry.remainingLabel.isNotEmpty)
        entry.remainingLabel
      else if (entry.isFinished)
        '已看完',
    ];
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 12),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            SizedBox(
              width: 120,
              child: AspectRatio(
                aspectRatio: 16 / 9,
                child: Container(
                  decoration: BoxDecoration(
                    // Theme glass, not a hardcoded dark tile (black
                    // hole in light modes). The progress scrim below
                    // stays black — it sits ON the artwork.
                    color: theme.surfaceStrong,
                    borderRadius: BorderRadius.circular(12),
                    border: Border.all(color: theme.hairline),
                  ),
                  clipBehavior: Clip.antiAlias,
                  child: Stack(
                    fit: StackFit.expand,
                    children: [
                      if (entry.pic.isNotEmpty)
                        RefererImage(
                          url: entry.pic,
                          fit: BoxFit.cover,
                          fallback: ColoredBox(
                            color: theme.surfaceStrong,
                          ),
                        )
                      else
                        Icon(
                          Icons.movie,
                          color: theme.textMuted,
                          size: 28,
                        ),
                      Positioned(
                        left: 0,
                        right: 0,
                        bottom: 0,
                        child: Container(
                          height: 6,
                          color: const Color(0x73000000),
                          alignment: Alignment.centerLeft,
                          child: FractionallySizedBox(
                            widthFactor: entry.progressFraction,
                            child: Container(
                              height: 6,
                              color: theme.accent,
                            ),
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    entry.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      height: 1.3,
                    ),
                  ),
                  if (metaParts.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      metaParts.join(' · '),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.textMuted,
                        fontSize: 13,
                        height: 1.25,
                      ),
                    ),
                  ],
                ],
              ),
            ),
            const SizedBox(width: 8),
            Icon(
              Icons.play_circle_outline,
              color: theme.accent,
              size: 28,
            ),
          ],
        ),
      ),
    );
  }
}
