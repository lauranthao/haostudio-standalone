import 'dart:async';

// My playlist detail — tracks, play all, rename, delete, remove songs.
//
// Card count shown on the home page is tracks.length (audit P0-1); this
// page renders the same list. Songs are removed with a swipe (Dismissible)
// — the song row itself keeps heart + play only (fix 10).

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import 'artist_detail_page.dart';
import 'music_player_controller.dart';
import 'music_player_sheet.dart';
import 'widgets/song_row.dart';

class PlaylistDetailPage extends StatefulWidget {
  const PlaylistDetailPage({super.key, required this.playlistId});

  final String playlistId;

  @override
  State<PlaylistDetailPage> createState() => _PlaylistDetailPageState();
}

class _PlaylistDetailPageState extends State<PlaylistDetailPage> {
  UserPlaylist? _list;

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  void _refresh() {
    final lists = MusicStore.getLists();
    setState(() {
      _list = lists.where((l) => l.id == widget.playlistId).firstOrNull;
    });
  }

  Future<void> _save() async {
    final lists = MusicStore.getLists();
    final idx = lists.indexWhere((l) => l.id == widget.playlistId);
    if (idx >= 0 && _list != null) {
      lists[idx] = _list!;
      await MusicStore.saveLists(lists);
    }
    _refresh();
  }

  Future<void> _rename() async {
    final list = _list;
    if (list == null) return;
    final nameController = TextEditingController(text: list.name);
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final theme = HaoTheme.of(ctx);
        return AlertDialog(
          backgroundColor: theme.surfaceSolid,
          title: Text('重命名歌单', style: TextStyle(color: theme.textPrimary)),
          content: TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(hintText: '新歌单的名字'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('取消', style: TextStyle(color: theme.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(nameController.text.trim()),
              child: Text('保存', style: TextStyle(color: theme.accent)),
            ),
          ],
        );
      },
    );
    if (name == null || name.isEmpty || name == list.name) return;
    list.name = name;
    await _save();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('歌单已重命名')),
    );
  }

  Future<void> _deleteList() async {
    final list = _list;
    if (list == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (ctx) {
        final theme = HaoTheme.of(ctx);
        return AlertDialog(
          backgroundColor: theme.surfaceSolid,
          title: Text('删除歌单', style: TextStyle(color: theme.textPrimary)),
          content: Text(
            '确定删除这个歌单吗？里面的歌也会一起删除。',
            style: TextStyle(color: theme.textSecondary),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(false),
              child: Text('取消', style: TextStyle(color: theme.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(true),
              child: const Text('删除', style: TextStyle(color: Colors.red)),
            ),
          ],
        );
      },
    );
    if (ok != true) return;
    final lists = MusicStore.getLists()
        .where((l) => l.id != widget.playlistId)
        .toList();
    await MusicStore.saveLists(lists);
    if (!mounted) return;
    Navigator.of(context).pop();
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('歌单已删除')),
    );
  }

  void _playAll() {
    final tracks = _list?.tracks ?? [];
    if (tracks.isEmpty) return;
    unawaited(_player.playQueue(tracks, 0, label: _list!.name));
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const MusicPlayerPage()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final list = _list;
    if (list == null) {
      return Scaffold(
        backgroundColor: theme.scaffoldBackground,
        appBar: AppBar(title: const Text('我的歌单')),
        body: Center(
          child: Text('这个歌单找不到了', style: TextStyle(color: theme.textMuted)),
        ),
      );
    }
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(
        title: Text(list.name, maxLines: 1),
        actions: [
          IconButton(icon: const Icon(Icons.edit), onPressed: _rename),
          IconButton(icon: const Icon(Icons.delete), onPressed: _deleteList),
        ],
      ),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 8, 16, 12),
            child: Row(
              children: [
                Text(
                  // Audit P0-1: count is tracks.length.
                  '${list.trackCount} 首歌曲',
                  style: TextStyle(color: theme.textSecondary),
                ),
                const Spacer(),
                ElevatedButton.icon(
                  onPressed: list.tracks.isEmpty ? null : _playAll,
                  icon: const Icon(Icons.play_arrow),
                  label: const Text('播放全部'),
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.accent,
                    foregroundColor: Colors.white,
                  ),
                ),
              ],
            ),
          ),
          Expanded(
            child: list.tracks.isEmpty
                ? Center(
                    child: Text(
                      '歌单为空，搜一首歌加进来吧',
                      style: TextStyle(color: theme.textMuted),
                    ),
                  )
                : ListView.builder(
                    itemCount: list.tracks.length,
                    itemBuilder: (ctx, i) {
                      final song = list.tracks[i];
                      final favIds = MusicStore.getFavIds();
                      return Dismissible(
                        key: ValueKey(
                          '${song.identityKey}|$i',
                        ),
                        direction: DismissDirection.endToStart,
                        background: Container(
                          color: theme.accentSoft,
                          alignment: Alignment.centerRight,
                          padding: const EdgeInsets.only(right: 20),
                          child: Icon(
                            Icons.delete,
                            color: theme.textSecondary,
                          ),
                        ),
                        confirmDismiss: (_) async {
                          final ok = await showDialog<bool>(
                            context: context,
                            builder: (dctx) {
                              final t = HaoTheme.of(dctx);
                              return AlertDialog(
                                backgroundColor: t.surfaceSolid,
                                title: Text(
                                  '删除歌曲',
                                  style: TextStyle(color: t.textPrimary),
                                ),
                                content: Text(
                                  '确定删除这首歌吗？',
                                  style: TextStyle(color: t.textSecondary),
                                ),
                                actions: [
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(dctx).pop(false),
                                    child: Text(
                                      '取消',
                                      style: TextStyle(color: t.textSecondary),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () =>
                                        Navigator.of(dctx).pop(true),
                                    child: const Text(
                                      '删除',
                                      style: TextStyle(color: Colors.red),
                                    ),
                                  ),
                                ],
                              );
                            },
                          );
                          return ok == true;
                        },
                        onDismissed: (_) async {
                          list.tracks.removeAt(i);
                          await _save();
                        },
                        child: SongRow(
                          song: song,
                          isFav: favIds.contains(song.identityKey),
                          onPlay: () {
                            unawaited(
                              _player.playQueue(list.tracks, i),
                            );
                            unawaited(
                              Navigator.of(context).push(
                                MaterialPageRoute<void>(
                                  builder: (_) => const MusicPlayerPage(),
                                ),
                              ),
                            );
                          },
                          onToggleFav: () async {
                            await _player.toggleFav(song);
                            setState(() {});
                          },
                          onOpenArtist: () => Navigator.of(context).push(
                            MaterialPageRoute<void>(
                              builder: (_) => ArtistDetailPage(
                                platform: song.platform,
                                artistId: '',
                                artistName: firstArtist(song.artist),
                              ),
                            ),
                          ),
                        ),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}
