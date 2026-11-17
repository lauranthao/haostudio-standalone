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
import '../../services/music/search_prewarm.dart';
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
  StreamSubscription<SearchStreamUpdate>? _searchSub;
  // Prewarm: resolve the first few visible songs' URLs while the
  // user is still looking, so tapping one plays from the cache.
  final _prewarm = SearchPrewarm();
  // Page-side generation: a new search cancels the old subscription
  // and bumps this, so stale stream callbacks can never touch the new
  // list (the service has the same guard; both must hold).
  var _pageGen = 0;
  // Platforms with at least one search leg not yet settled (from the
  // latest stream update). Shown in the footer while streaming.
  Set<MusicPlatform> _pendingPlatforms = {};

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
    unawaited(_searchSub?.cancel());
    _prewarm.cancel();
    _queryController.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _onScroll() {
    // No `_loading` guard: while a search streams in, already-loaded
    // rows can be revealed by scrolling; new legs append below.
    if (_type != _SearchType.song) return;
    if (_shown >= _songs.length) return;
    if (_scrollController.position.pixels >=
        _scrollController.position.maxScrollExtent - 200) {
      setState(() => _shown = (_shown + kSearchPageSize).clamp(0, _songs.length));
    }
  }

  Future<void> _search() async {
    final q = _queryController.text.trim();
    if (q.isEmpty) return;
    // Record the term once a search is actually started — not on an
    // empty query, not when the page is just opened. Best-effort, and
    // fire-and-forget: the Hive write must not sit on the critical
    // path to the first result (the search starts immediately).
    unawaited(MusicStore.saveSearchQuery(q).catchError((_) {}));
    if (_type == _SearchType.song) {
      _searchSongs(q);
      return;
    }
    setState(() {
      _loading = true;
      _searched = true;
      _error = '';
      _shown = kSearchPageSize;
    });
    try {
      if (_type == _SearchType.playlist) {
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
      } else {
        // _SearchType.artist (song is handled above by _searchSongs).
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

  /// Streaming song search: results appear as each platform leg
  /// returns (the fastest, usually ~1 s), the rest append after it.
  /// Starting a new search cancels the old subscription and bumps the
  /// generation, so stale emissions can never touch the new list.
  void _searchSongs(String q) {
    final gen = ++_pageGen;
    unawaited(_searchSub?.cancel());
    _prewarm.cancel();
    setState(() {
      _loading = true;
      _searched = true;
      _error = '';
      _shown = kSearchPageSize;
      _songs = [];
      _pendingPlatforms = {};
    });
    _searchSub = _searchService.searchAllStream(q).listen(
      (update) {
        if (!mounted || gen != _pageGen) return;
        setState(() {
          _songs = update.songs;
          _pendingPlatforms = update.pending;
        });
        // Warm the first few visible rows' URLs while the user is
        // still looking, so tapping one plays from the cache.
        _prewarm.prewarm(update.songs);
      },
      onError: (_) {
        if (!mounted || gen != _pageGen) return;
        setState(() {
          _loading = false;
          _error = '搜索失败，请重试';
        });
      },
      onDone: () {
        if (!mounted || gen != _pageGen) return;
        setState(() {
          _loading = false;
          if (_songs.isEmpty) _error = '没搜到，换个歌名试试';
        });
      },
      cancelOnError: false,
    );
  }

  /// Footer text while legs are still pending, e.g. "正在搜索 QQ、酷狗…".
  /// Falls back to a plain "正在搜索…" when no platform names are known
  /// (the last update already settled every leg — transient).
  String get _pendingLabel {
    if (_pendingPlatforms.isEmpty) return '正在搜索…';
    final names = _pendingPlatforms.map((p) => p.badgeName).join('、');
    return '正在搜索 $names…';
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
                      filled: true,
                      fillColor: theme.surface,
                      border: OutlineInputBorder(
                        borderRadius: BorderRadius.circular(14),
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
                    borderRadius: BorderRadius.circular(14),
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
                    foregroundColor: Theme.of(context).colorScheme.onPrimary,
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
    // Streaming: show the list as soon as the first leg returns, even
    // while other legs are still pending. The full-screen spinner is
    // only for "nothing yet" (song search with no results so far);
    // playlist/artist searches are not streamed, so they keep the
    // plain `_loading` spinner.
    if (_loading && (_type != _SearchType.song || _songs.isEmpty)) {
      return const Center(child: CircularProgressIndicator());
    }
    if (!_searched) {
      final history = MusicStore.getSearchHistory();
      if (history.isEmpty) {
        return Center(
          child: Text(
            '搜一首歌、歌单或歌手',
            style: TextStyle(color: theme.textMuted, fontSize: 15),
          ),
        );
      }
      return ListView(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        children: [
          _SearchHistory(
            history: history,
            onTap: (q) {
              _queryController.text = q;
              unawaited(_search());
            },
            onClear: () async {
              await MusicStore.clearSearchHistory();
              if (mounted) setState(() {});
            },
          ),
          const SizedBox(height: 28),
          Center(
            child: Text(
              '搜一首歌、歌单或歌手',
              style: TextStyle(color: theme.textMuted, fontSize: 15),
            ),
          ),
        ],
      );
    }
    if (_error.isNotEmpty) {
      return Center(
        child: Text(_error, style: TextStyle(color: theme.textMuted, fontSize: 15)),
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
              if (_loading) {
                // Legs still pending: more results may arrive. Never
                // show "已加载全部" while a search is still streaming.
                return Padding(
                  padding: const EdgeInsets.all(16),
                  child: Row(
                    mainAxisAlignment: MainAxisAlignment.center,
                    children: [
                      const SizedBox(
                        width: 14,
                        height: 14,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      ),
                      const SizedBox(width: 8),
                      Text(
                        _pendingLabel,
                        style: TextStyle(color: theme.textMuted),
                      ),
                    ],
                  ),
                );
              }
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
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 15,
                  fontWeight: FontWeight.w600,
                ),
              ),
              subtitle: Text(
                '${p.platform.displayName} · ${p.creator} · ${p.playCount}次播放',
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(color: theme.textSecondary, fontSize: 13),
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
              title: Text(a.name, style: TextStyle(color: theme.textPrimary, fontSize: 15, fontWeight: FontWeight.w600)),
              subtitle: Text(
                '${a.platform.displayName} · ${a.musicSize} 首 · ${a.albumSize} 张专辑',
                style: TextStyle(color: theme.textSecondary, fontSize: 13),
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

/// Search history section (same shape as the video search page's
/// `_ChipSection`): title + clear on one row, up to 8 recent terms as
/// chips. Tapping a chip re-runs that search; clearing removes the
/// whole section (it only renders when history is non-empty).
class _SearchHistory extends StatelessWidget {
  const _SearchHistory({
    required this.history,
    required this.onTap,
    required this.onClear,
  });

  final List<String> history;
  final void Function(String query) onTap;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Text(
              '搜索历史',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w800,
                letterSpacing: -0.01,
              ),
            ),
            const Spacer(),
            TextButton(
              onPressed: onClear,
              style: TextButton.styleFrom(
                padding: const EdgeInsets.symmetric(horizontal: 8),
                minimumSize: Size.zero,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              child: Text('清除', style: TextStyle(color: theme.textMuted, fontSize: 14)),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: history
              .take(8)
              .map(
                (q) => ActionChip(
                  label: Text(q),
                  labelStyle: TextStyle(
                    color: theme.textSecondary,
                    fontSize: 14,
                    fontWeight: FontWeight.w500,
                  ),
                  backgroundColor: theme.surface,
                  side: BorderSide(color: theme.hairline),
                  onPressed: () => onTap(q),
                ),
              )
              .toList(),
        ),
      ],
    );
  }
}
