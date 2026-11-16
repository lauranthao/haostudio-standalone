// Video favourites page — local favourites only (no accounts).
//
// Lists the user's favourited videos (poster grid, same card as
// everywhere else). Tapping a card opens its detail page.

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import 'video_detail_page.dart';
import 'video_history_store.dart';
import 'video_poster_card.dart';

class VideoFavsPage extends StatelessWidget {
  const VideoFavsPage({super.key});

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final favs = VideoHistoryStore.getFavs();
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(
        title: const Text('我的收藏'),
        backgroundColor: theme.surface,
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
                      onTapItem: (item) {
                        Navigator.of(context).push(
                          MaterialPageRoute<void>(
                            builder: (_) => VideoDetailPage(
                              sourceId: item.source,
                              vodId: item.vodId,
                              preload: item,
                            ),
                          ),
                        );
                      },
                    ),
                  ),
                ),
              ],
            ),
    );
  }
}
