import 'dart:async';

// Song search (fix 12).
//
// Input + type dropdown (歌曲/歌单/歌手） + 搜索 button only. Song search has
// NO platform picker: every search queries all four platforms by default
// (aggregated, round-robin merged, platform badges), infinite scroll with
// a sentinel ("已加载全部" at the end, no next-page button). A new query
// cancels the previous search (generation guard in SongSearchService).

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import '../../services/music/song_search_service.dart';
import 'album_detail_page.dart';
import 'artist_detail_page.dart';
import 'music_player_controller.dart';
import 'music_player_sheet.dart';
import 'plaza_page.dart';
import 'widgets/song_row.dart';
import 'widgets/track_more_sheet.dart';
import 'widgets/music_image.dart';

enum _SearchType { song, playlist, artist }

class SongSearchPage extends StatefulWidget {
  const SongSearchPage({super.key});

  @override
  State<SongSearchPage> createState() => _SongSearchPageState();
}

class _SongSearchPageState extends State<SongSearchPage> {
  final _queryController = TextEditingController();
  final _scrollController = ScrollController();
  final _searchService = SongSearchService();
  final _api = MusicApi();

  var _type = _SearchType.song;
  var _loading = false;
  var _searched = false;
  List<Song> _songs = [];
  var _shown = kSearchPageSize;
  List<PlaylistSummary> _playlists = [];
  List<ArtistSummary> _artists = [];
  String _error = '';

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
  }

  @override
  void dispose() {
    _queryController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    if (_type != _SearchType.song || _loading) return;
    if (_shown >= _songs.length) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      setState(() => _shown = (_shown + kSearchPageSize).clamp(0, _songs.length));
    }
  }

  Future<void> _search() async {
    final q = _queryController.text.trim();
    if (q.isEmpty) return;
    setState(() {
      _loading = true;
      _searched = true;
      _error = '';
      _shown = kSearchPageSize;
    });
    try {
      switch (_type) {
        case _SearchType.song:
          final results = await _searchService.searchAll(q);
          if (!mounted) return;
          setState(() {
            _songs = results;
            if (results.isEmpty) _error = '没搜到，换个歌名试试';
          });
        case _SearchType.playlist:
          final settled = await Future.wait([
            _api.searchWyPlaylists(q, 1).catchError(
                  (_) => (items: <PlaylistSummary>[], total: 0),
                ),
            _api.searchKwPlaylists(q, 1).catchError(
                  (_) => (items: <PlaylistSummary>[], total: 0),
                ),
          ]);
          if (!mounted) return;
          setState(() {
            _playlists = [...settled[0].items, ...settled[1].items];
            if (_playlists.isEmpty) _error = '没搜到相关歌单';
          });
        case _SearchType.artist:
          final settled = await Future.wait([
            _api.searchWyArtists(q).catchError((_) => <ArtistSummary>[]),
            _api.searchTxArtists(q, 1).catchError((_) => <ArtistSummary>[]),
            _api.searchKwArtists(q).catchError((_) => <ArtistSummary>[]),
          ]);
          if (!mounted) return;
          setState(() {
            _artists = settled.expand((l) => l).toList();
            if (_artists.isEmpty) _error = '没搜到相关歌手';
          });
      }
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _playSong(Song song, List<Song> queue) {
    final idx = queue.indexWhere((s) => s.identityKey == song.identityKey);
    unawaited(_player.playQueue(queue, idx < 0 ? 0 : idx));
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
      appBar: AppBar(title: const Text('搜歌')),
      body: Column(
        children: [
          Padding(
            padding: const EdgeInsets.all(16),
            child: Row(
              children: [
                Expanded(
                  child: TextField(
                    controller: _queryController,
                    textInputAction: TextInputAction.search,
                    onSubmitted: (_) => _search(),
                    decoration: InputDecoration(
                      hintText: '搜索歌曲 / 歌手…',
                      hintStyle: TextStyle(color: theme.textMuted),
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(12),
                        borderSide: BorderSide(color: theme.hairline),
                      ),
                      contentPadding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 10,
                      ),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Container(
                  padding: const EdgeInsets.symmetric(horizontal: 8),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.hairline),
                    borderRadius: BorderRadius.circular(12),
                  ),
                  child: DropdownButton<_SearchType>(
                    value: _type,
                    underline: const SizedBox.shrink(),
                    items: const [
                      DropdownMenuItem(value: _SearchType.song, child: Text('歌曲')),
                      DropdownMenuItem(
                        value: _SearchType.playlist,
                        child: Text('歌单'),
                      ),
                      DropdownMenuItem(
                        value: _SearchType.artist,
                        child: Text('歌手'),
                      ),
                    ],
                    onChanged: (v) {
                      if (v != null) setState(() => _type = v);
                    },
                  ),
                ),
                const SizedBox(width: 8),
                ElevatedButton(
                  onPressed: _loading ? null : _search,
                  style: ElevatedButton.styleFrom(
                    backgroundColor: theme.accent,
                    foregroundColor: Colors.white,
                  ),
                  child: const Text('搜索'),
                ),
              ],
            ),
          ),
          Expanded(child: _results(theme)),
        ],
      ),
    );
  }

  Widget _results(HaoTheme theme) {
    if (_loading) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_searched) {
      return Center(
        child: Text('搜一首歌、歌单或歌手', style: TextStyle(color: theme.textMuted)),
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Text(_error, style: TextStyle(color: theme.textMuted)),
      );
    }
    switch (_type) {
      case _SearchType.song:
        final shown = _songs.take(_shown).toList();
        final favIds = MusicStore.getFavIds();
        return ListView.builder(
          controller: _scrollController,
          itemCount: shown.length + 1,
          itemBuilder: (ctx, i) {
            if (i >= shown.length) {
              final hasMore = _songs.length > _shown;
              return Padding(
                padding: const EdgeInsets.all(16),
                child: Text(
                  hasMore ? '加载中…' : '已加载全部',
                  textAlign: TextAlign.center,
                  style: TextStyle(color: theme.textMuted),
                ),
              );
            }
            final song = shown[i];
            return SongRow(
              song: song,
              isFav: favIds.contains(song.identityKey),
              onPlay: () => _playSong(song, _songs),
              onToggleFav: () async {
                await _player.toggleFav(song);
                setState(() {});
              },
              onOpenArtist: () => _openArtist(song),
              onOpenAlbum: song.album.isEmpty
                  ? null
                  : () => _openAlbum(song),
              onLongPress: () => unawaited(openTrackMoreSheet(context, song)),
            );
          },
        );
      case _SearchType.playlist:
        return ListView.builder(
          itemCount: _playlists.length,
          itemBuilder: (ctx, i) {
            final p = _playlists[i];
            return ListTile(
              leading: ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: p.cover.isEmpty
                    ? Container(
                        width: 48,
                        height: 48,
                        color: theme.accentSoft,
                        child: Icon(Icons.music_note, color: theme.textMuted),
                      )
                    : Image(
                        image: MusicImageProvider(p.cover),
                        width: 48,
                        height: 48,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 48,
                          height: 48,
                          color: theme.accentSoft,
                          child: Icon(
                            Icons.music_note,
                            color: theme.textMuted,
                          ),
                        ),
                      ),
              ),
              title: Text(
                p.name,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.textPrimary),
              ),
              subtitle: Text(
                '${p.platform.displayName} · ${p.creator} · ${p.playCount}次播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.textSecondary),
              ),
              trailing: Icon(Icons.chevron_right, color: theme.textMuted),
              onTap: () => _openPlazaDetail(p),
            );
          },
        );
      case _SearchType.artist:
        return ListView.builder(
          itemCount: _artists.length,
          itemBuilder: (ctx, i) {
            final a = _artists[i];
            return ListTile(
              leading: CircleAvatar(
                backgroundImage:
                    a.cover.isEmpty ? null : MusicImageProvider(a.cover),
                backgroundColor: theme.accentSoft,
                child: a.cover.isEmpty
                    ? Icon(Icons.person, color: theme.textMuted)
                    : null,
              ),
              title: Text(a.name, style: TextStyle(color: theme.textPrimary)),
              subtitle: Text(
                '${a.platform.displayName} · ${a.musicSize} 首 · ${a.albumSize} 张专辑',
                style: TextStyle(color: theme.textSecondary),
              ),
              trailing: Icon(Icons.chevron_right, color: theme.textMuted),
              onTap: () => Navigator.of(context).push(
                MaterialPageRoute<void>(
                  builder: (_) => ArtistDetailPage(
                    platform: a.platform,
                    artistId: a.id,
                    artistName: a.name,
                  ),
                ),
              ),
            );
          },
        );
    }
  }

  void _openArtist(Song song) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => ArtistDetailPage(
          platform: song.platform,
          artistId: '',
          artistName: firstArtist(song.artist),
        ),
      ),
    );
  }

  void _openAlbum(Song song) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => AlbumDetailPage(
          platform: song.platform,
          albumId: '',
          albumName: song.album,
          artistName: firstArtist(song.artist),
        ),
      ),
    );
  }

  void _openPlazaDetail(PlaylistSummary p) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => PlazaDetailPage(playlist: p),
      ),
    );
  }
}
