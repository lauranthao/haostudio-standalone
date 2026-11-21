// Video favourites page — local favourites only (no accounts).
//
// Lists the user's favourited videos (poster grid, same card as
// everywhere else). Tapping a card opens its detail page.
//
// Stateful (not Stateless) on purpose: un-favouriting a video on its
// detail page must remove it here when the user comes back — the
// history page already refreshes on return for the same reason, and
// a StatelessWidget here showed the unfavourited video until the
// page was recreated.

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import 'video_detail_router.dart';
import 'video_history_store.dart';
import 'video_models.dart';
import 'video_poster_card.dart';

class VideoFavsPage extends StatefulWidget {
  const VideoFavsPage({super.key});

  @override
  State<VideoFavsPage> createState() => _VideoFavsPageState();
}

class _VideoFavsPageState extends State<VideoFavsPage> {
  void _openDetail(VideoItem item) {
    // 1.1.6: shared routing (`video_detail_router.dart`) — Emby items
    // open EmbyDetailPage (audit P0). Same branch as the history page.
    openVideoDetail<void>(
      context,
      source: item.source,
      vodId: item.vodId,
      preload: item,
    ).then((_) {
      // Favourite may have been toggled off on the detail page.
      if (mounted) setState(() {});
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final favs = VideoHistoryStore.getFavs();
    return Scaffold(
      appBar: AppBar(
        title: const Text('我的收藏'),
      ),
      body: favs.isEmpty
          ? Center(
              child: Text(
                '还没有收藏的影片',
                style: TextStyle(color: theme.textMuted),
              ),
            )
          : CustomScrollView(
              slivers: [
                SliverPadding(
                  padding: const EdgeInsets.fromLTRB(14, 16, 14, 8),
                  sliver: SliverToBoxAdapter(
                    child: VideoPosterGrid(
                      items: favs,
                      onTapItem: _openDetail,
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
