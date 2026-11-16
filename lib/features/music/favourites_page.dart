// Favourites page (M-P0-7) — lists favourited songs.
//
// Entry: the 我的收藏 card on the music home (inside 我的歌单).
// Reuses the shared SongRow: heart + play only, no ＋, no "会员歌".
// Tapping the heart again removes the song from the list; tapping the
// row plays the whole favourites list from that song. Empty state is
// honest: "还没有收藏的歌曲".

import 'dart:async';

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import 'artist_detail_page.dart';
import 'music_player_controller.dart';
import 'music_player_sheet.dart';
import 'widgets/song_row.dart';
import 'widgets/track_more_sheet.dart';

class FavouritesPage extends StatefulWidget {
  const FavouritesPage({super.key});

  @override
  State<FavouritesPage> createState() => _FavouritesPageState();
}

class _FavouritesPageState extends State<FavouritesPage> {
  List<Song> _songs = [];

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    setState(() {
      _songs = MusicStore.getFavSongs();
    });
  }

  void _playSong(Song song) {
    final idx = _songs.indexWhere((s) => s.identityKey == song.identityKey);
    unawaited(_player.playQueue(_songs, idx < 0 ? 0 : idx, label: '我的收藏'));
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const MusicPlayerPage()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(title: const Text('我的收藏')),
      body: _songs.isEmpty
          ? Center(
              child: Text(
                '还没有收藏的歌曲',
                style: TextStyle(color: theme.textMuted, fontSize: 15),
              ),
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
                  child: Text(
                    '共 ${_songs.length} 首',
                    style: TextStyle(
                      color: theme.textSecondary,
                      fontSize: 13,
                    ),
                  ),
                ),
                Expanded(
                  child: ListView.builder(
                    itemCount: _songs.length,
                    itemBuilder: (ctx, i) {
                      final song = _songs[i];
                      return SongRow(
                        song: song,
                        isFav: true,
                        onPlay: () => _playSong(song),
                        onToggleFav: () async {
                          await _player.toggleFav(song);
                          _refresh();
                        },
                        onOpenArtist: () => unawaited(
                          Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ArtistDetailPage(
                                platform: song.platform,
                                artistId: '',
                                artistName: firstArtist(song.artist),
                              ),
                            ),
                          ),
                        ),
                        onLongPress: () =>
                            unawaited(openTrackMoreSheet(context, song)),
                      );
                    },
                  ),
                ),
              ],
            ),
    );
  }
}
