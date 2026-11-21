import '../../core/theme/hao_radius.dart';
import 'dart:async';

// Artist detail page (fix 5).
//
// Big photo hero + large artist name + round play button; below are the
// three collapsible sections — 专辑 (Albums), 单曲与EP (Singles & EPs),
// 代表作 (Fan Favourites). Tapping a head collapses/expands that section
// (chevron rotates 90° over 0.2 s); state is per-section and independent.
// Share uses the clipboard fallback chain and ALWAYS gives visible
// feedback (fix 5).

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../core/theme/glass.dart';
import '../../services/clipboard_service.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import 'album_detail_page.dart';
import 'music_navigation.dart';
import 'music_player_controller.dart';
import 'player_expand_route.dart';
import 'widgets/collapsible_section.dart';
import 'widgets/song_row.dart';
import 'widgets/track_more_sheet.dart';
import 'widgets/mini_player_bar.dart';
import 'widgets/music_image.dart';

class ArtistDetailPage extends StatefulWidget {
  const ArtistDetailPage({
    super.key,
    required this.platform,
    required this.artistId,
    required this.artistName,
  });

  final MusicPlatform platform;
  final String artistId;
  final String artistName;

  @override
  State<ArtistDetailPage> createState() => _ArtistDetailPageState();
}

class _ArtistDetailPageState extends State<ArtistDetailPage> {
  final _api = MusicApi();
  ArtistDetail? _detail;
  var _loading = true;
  var _failed = false;
  var _albumsExpanded = true;
  var _singlesExpanded = true;
  var _topExpanded = true;

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      var id = widget.artistId;
      if (id.isEmpty && widget.platform == MusicPlatform.wy) {
        // No artist id from a song row — resolve by name first.
        final found = await _api.searchWyArtists(widget.artistName);
        if (found.isNotEmpty) id = found.first.id;
      }
      final detail = id.isEmpty && widget.platform == MusicPlatform.wy
          ? ArtistDetail(name: widget.artistName)
          : await _api.artistDetail(widget.platform, id, widget.artistName);
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        _failed = detail.songs.isEmpty && detail.albums.isEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  List<AlbumSummary> get _albums =>
      (_detail?.albums ?? [])
          .where((a) => a.songCount > 3 && !_isSingleOrEp(a))
          .toList();

  List<AlbumSummary> get _singles =>
      (_detail?.albums ?? [])
          .where((a) => a.songCount <= 3 || _isSingleOrEp(a))
          .toList();

  bool _isSingleOrEp(AlbumSummary a) =>
      a.name.contains('单曲') || a.name.toUpperCase().contains('EP');

  List<Song> get _topSongs => (_detail?.songs ?? []).take(10).toList();

  void _playAll() {
    final songs = _detail?.songs ?? [];
    if (songs.isEmpty) return;
    unawaited(_player.playQueue(songs, 0, label: widget.artistName));
    unawaited(openPlayerPage<void>(context));
  }

  Future<void> _share() async {
    await ClipboardService.copyWithFeedback(
      context,
      widget.artistName,
      successMessage: '已复制歌手名',
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    // Favourites read once per build, not per song row: getFavIds()
    // parses the whole favourites JSON on every call.
    final favIds = MusicStore.getFavIds();
    return Scaffold(
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? _errorState(theme)
              : CustomScrollView(
                  slivers: [
                    SliverAppBar(
                      expandedHeight: 280,
                      pinned: true,
                      flexibleSpace: FlexibleSpaceBar(
                        background: _detail!.pic.isEmpty
                            ? Container(color: theme.accentSoft)
                            : Image(
                                image: MusicImageProvider(_detail!.pic),
                                fit: BoxFit.cover,
                                errorBuilder: (_, _, _) =>
                                    Container(color: theme.accentSoft),
                              ),
                      ),
                      actions: [
                        IconButton(
                          icon: const Icon(Icons.share),
                          onPressed: _share,
                        ),
                      ],
                    ),
                    SliverToBoxAdapter(
                      child: Padding(
                        padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
                        child: Row(
                          children: [
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                mainAxisSize: MainAxisSize.min,
                                children: [
                                  Text(
                                    _detail!.name,
                                    style: TextStyle(
                                      color: theme.textPrimary,
                                      fontSize: 26,
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${_detail!.musicSize} 首歌曲 · ${_detail!.albumSize} 张专辑',
                                    style: TextStyle(
                                      color: theme.textSecondary,
                                      fontSize: 14,
                                      fontWeight: FontWeight.w500,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                            FloatingActionButton(
                              onPressed: _playAll,
                              backgroundColor: theme.accent,
                              foregroundColor: Theme.of(context).colorScheme.onPrimary,
                              child: const Icon(Icons.play_arrow, size: 32),
                            ),
                          ],
                        ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: CollapsibleSection(
                        title: '代表作',
                        expanded: _topExpanded,
                        onToggle: () => setState(
                          () => _topExpanded = !_topExpanded,
                        ),
                        child: _topSongs.isEmpty
                            ? _empty(theme, '这个歌手还没有歌曲')
                            : Column(
                                children: [
                                  for (var i = 0; i < _topSongs.length; i++)
                                    _songRow(_topSongs[i], _topSongs, i, favIds),
                                ],
                              ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: CollapsibleSection(
                        title: '专辑',
                        expanded: _albumsExpanded,
                        onToggle: () => setState(
                          () => _albumsExpanded = !_albumsExpanded,
                        ),
                        child: _albums.isEmpty
                            ? _empty(theme, '这个歌手还没有专辑')
                            : Column(
                                children: [
                                  for (final a in _albums) _albumRow(theme, a),
                                ],
                              ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: CollapsibleSection(
                        title: '单曲与EP',
                        expanded: _singlesExpanded,
                        onToggle: () => setState(
                          () => _singlesExpanded = !_singlesExpanded,
                        ),
                        child: _singles.isEmpty
                            ? _empty(theme, '暂无单曲与 EP')
                            : Column(
                                children: [
                                  for (final a in _singles)
                                    _albumRow(theme, a),
                                ],
                              ),
                      ),
                    ),
                    SliverToBoxAdapter(
                      child: SizedBox(
                        height:
                            24 + MiniPlayerBar.bottomClearanceFor(context),
                      ),
                    ),
                  ],
                ),
    );
  }

  Widget _empty(HaoTheme theme, String text) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
      child: Text(text, style: TextStyle(color: theme.textMuted)),
    );
  }

  Widget _errorState(HaoTheme theme) {
    return Scaffold(
      appBar: AppBar(title: Text(widget.artistName)),
      body: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Text('歌手详情加载失败', style: TextStyle(color: theme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            ElevatedButton(
              onPressed: () {
                setState(() => _loading = true);
                _load();
              },
              style: ElevatedButton.styleFrom(
                backgroundColor: theme.accent,
                foregroundColor: Theme.of(context).colorScheme.onPrimary,
              ),
              child: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }

  Widget _songRow(Song song, List<Song> queue, int index, Set<String> favIds) {
    return SongRow(
      song: song,
      isFav: favIds.contains(song.identityKey),
      onPlay: () {
        unawaited(_player.playQueue(queue, index));
        unawaited(openPlayerPage<void>(context));
      },
      onToggleFav: () async {
        await _player.toggleFav(song);
        setState(() {});
      },
      leading: Text(
        '${index + 1}',
        style: TextStyle(
          color: HaoTheme.of(context).textMuted,
          fontSize: 15,
          fontWeight: FontWeight.w700,
        ),
      ),
      onLongPress: (rowCtx) =>
                                unawaited(openSongQuickMenu(rowCtx, song)),
    );
  }

  Widget _albumRow(HaoTheme theme, AlbumSummary album) {
    return GlassCard(
      radius: 16,
      padding: const EdgeInsets.symmetric(vertical: 4),
      margin: const EdgeInsets.fromLTRB(16, 4, 16, 4),
      child: Material(
        color: Colors.transparent,
        child: ListTile(
      leading: ClipRRect(
        borderRadius: BorderRadius.circular(HaoRadius.standard),
        child: album.cover.isEmpty
            ? Container(
                width: 48,
                height: 48,
                color: theme.accentSoft,
                child: Icon(Icons.album, color: theme.textMuted),
              )
            : Image(
                image: MusicImageProvider(album.cover),
                width: 48,
                height: 48,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  width: 48,
                  height: 48,
                  color: theme.accentSoft,
                  child: Icon(Icons.album, color: theme.textMuted),
                ),
              ),
      ),
      title: Text(
        album.name,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          color: theme.textPrimary,
          fontSize: 15,
          fontWeight: FontWeight.w600,
        ),
      ),
      subtitle: Text(
        album.year > 0
            ? '${album.year}年 · ${album.songCount} 首'
            : '${album.songCount} 首',
        style: TextStyle(color: theme.textSecondary, fontSize: 13),
      ),
      trailing: Icon(Icons.chevron_right, color: theme.textMuted),
      onTap: () {
        HaoHaptics.tap();
        Navigator.of(context).push(
          MaterialPageRoute<void>(
            settings: const RouteSettings(name: musicSubPageRouteName),
            builder: (_) => AlbumDetailPage(
              platform: widget.platform,
              albumId: album.id,
              albumName: album.name,
              artistName: album.artist.isEmpty
                  ? widget.artistName
                  : album.artist,
              albumCover: album.cover,
              albumYear: album.year,
            ),
          ),
        );
      },
        ),
      ),
    );
  }
}
