import 'dart:async';

// Album detail page — Apple Music reference (memory 2026-11-16).
//
// Large centred cover, album/artist name, year and quality info, large
// black play capsule in the middle with shuffle and add on either side,
// numbered track list below. Only REAL quality info is shown — no Dolby
// Atmos label, since there is no Dolby source (the quality shown is the
// user's current playback tier).
//
// When opened without an album id (e.g. from a song row), the track list
// falls back to searching the album name on the platform and filtering
// to the artist — the same intentional workaround as Kuwo album tracks.

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/clipboard_service.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_quality.dart';
import '../../services/music/music_store.dart';
import 'music_player_controller.dart';
import 'music_player_sheet.dart';
import 'widgets/song_row.dart';
import 'widgets/track_more_sheet.dart';

class AlbumDetailPage extends StatefulWidget {
  const AlbumDetailPage({
    super.key,
    required this.platform,
    required this.albumId,
    required this.albumName,
    required this.artistName,
    this.albumCover = '',
    this.albumYear = 0,
  });

  final MusicPlatform platform;
  final String albumId;
  final String albumName;
  final String artistName;
  final String albumCover;
  final int albumYear;

  @override
  State<AlbumDetailPage> createState() => _AlbumDetailPageState();
}

class _AlbumDetailPageState extends State<AlbumDetailPage> {
  final _api = MusicApi();
  AlbumDetail? _detail;
  var _loading = true;
  var _failed = false;

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    try {
      AlbumDetail detail;
      if (widget.albumId.isEmpty) {
        // No album id: search the album name and filter to the artist.
        final found = await _api
            .searchOne(widget.platform, widget.albumName)
            .catchError((_) => <Song>[]);
        final an = normalizeName(widget.artistName);
        final mine = found.where((s) {
          return an.isEmpty ||
              normalizeName(firstArtist(s.artist)) == an ||
              normalizeName(s.artist).contains(an);
        }).toList();
        detail = AlbumDetail(
          name: widget.albumName,
          pic: widget.albumCover,
          artist: widget.artistName,
          publishTime: 0,
          songs: (mine.isEmpty ? found : mine)
              .where((s) => s.album.isEmpty || s.album == widget.albumName)
              .toList(),
        );
      } else {
        detail = await _api.albumSongs(
          widget.albumId,
          widget.platform,
          widget.albumName,
          widget.artistName,
        );
      }
      if (!mounted) return;
      setState(() {
        _detail = detail;
        _loading = false;
        _failed = detail.songs.isEmpty;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  List<Song> get _songs => _detail?.songs ?? [];

  void _playAll({bool shuffle = false}) {
    if (_songs.isEmpty) return;
    final songs = List<Song>.of(_songs);
    if (shuffle) songs.shuffle();
    unawaited(_player.playQueue(songs, 0, label: widget.albumName));
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const MusicPlayerPage()),
      ),
    );
  }

  Future<void> _addToPlaylist() async {
    final lists = MusicStore.getLists();
    if (lists.isEmpty) {
      final list = UserPlaylist(
        id: 'l${DateTime.now().millisecondsSinceEpoch}',
        name: '我的歌单',
      );
      lists.add(list);
      await MusicStore.saveLists(lists);
      await _addSongsTo(list);
      return;
    }
    if (lists.length == 1) {
      await _addSongsTo(lists.first);
      return;
    }
    final picked = await showDialog<UserPlaylist>(
      context: context,
      builder: (ctx) {
        final theme = HaoTheme.of(ctx);
        return SimpleDialog(
          backgroundColor: theme.surfaceSolid,
          title: Text('选择歌单', style: TextStyle(color: theme.textPrimary)),
          children: [
            for (final l in lists)
              SimpleDialogOption(
                onPressed: () => Navigator.of(ctx).pop(l),
                child: Text(l.name, style: TextStyle(color: theme.textPrimary)),
              ),
          ],
        );
      },
    );
    if (picked != null) await _addSongsTo(picked);
  }

  Future<void> _addSongsTo(UserPlaylist list) async {
    final lists = MusicStore.getLists();
    final target = lists.firstWhere(
      (l) => l.id == list.id,
      orElse: () => list,
    );
    final seen = target.tracks.map((t) => t.songId).toSet();
    var added = 0;
    for (final s in _songs) {
      if (seen.contains(s.songId)) continue;
      if (target.tracks.length >= 200) break;
      target.tracks.add(s);
      added++;
    }
    if (!lists.any((l) => l.id == target.id)) lists.add(target);
    await MusicStore.saveLists(lists);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已加入歌单 $added 首 → ${target.name}')),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(
        title: Text(widget.albumName, maxLines: 1),
        actions: [
          IconButton(
            icon: const Icon(Icons.share),
            onPressed: () => ClipboardService.copyWithFeedback(
              context,
              '${widget.albumName} - ${widget.artistName}',
              successMessage: '已复制专辑分享内容',
            ),
          ),
        ],
      ),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
          : _failed
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '专辑加载失败',
                        style: TextStyle(color: theme.textPrimary),
                      ),
                      const SizedBox(height: 12),
                      ElevatedButton(
                        onPressed: () {
                          setState(() => _loading = true);
                          _load();
                        },
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.accent,
                          foregroundColor: Colors.white,
                        ),
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : ListView(
                  padding: const EdgeInsets.symmetric(horizontal: 16),
                  children: [
                    const SizedBox(height: 8),
                    _cover(theme),
                    const SizedBox(height: 16),
                    Text(
                      _detail!.name.isEmpty ? widget.albumName : _detail!.name,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _detail!.artist.isEmpty
                          ? widget.artistName
                          : _detail!.artist,
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      _metaLine(),
                      textAlign: TextAlign.center,
                      style: TextStyle(color: theme.textMuted, fontSize: 13),
                    ),
                    const SizedBox(height: 20),
                    _actions(theme),
                    const SizedBox(height: 16),
                    Divider(color: theme.hairline, height: 1),
                    const SizedBox(height: 8),
                    for (var i = 0; i < _songs.length; i++)
                      _trackRow(theme, _songs[i], i),
                    const SizedBox(height: 24),
                  ],
                ),
    );
  }

  /// Year + real quality info only — never a Dolby label.
  String _metaLine() {
    final year = _detail!.year > 0
        ? _detail!.year
        : widget.albumYear > 0
            ? widget.albumYear
            : 0;
    final parts = <String>[];
    if (year > 0) parts.add('$year年');
    parts.add(_player.userQuality.value.label);
    return parts.join(' · ');
  }

  Widget _cover(HaoTheme theme) {
    final cover = _detail!.pic.isEmpty ? widget.albumCover : _detail!.pic;
    final size = MediaQuery.of(context).size.width * 0.62;
    return Center(
      child: ClipRRect(
        borderRadius: BorderRadius.circular(16),
        child: cover.isEmpty
            ? Container(
                width: size,
                height: size,
                color: theme.accentSoft,
                child: Icon(Icons.album, color: theme.textMuted, size: 72),
              )
            : Image.network(
                cover,
                width: size,
                height: size,
                fit: BoxFit.cover,
                errorBuilder: (_, _, _) => Container(
                  width: size,
                  height: size,
                  color: theme.accentSoft,
                  child: Icon(Icons.album, color: theme.textMuted, size: 72),
                ),
              ),
      ),
    );
  }

  Widget _actions(HaoTheme theme) {
    final isDark = Theme.of(context).brightness == Brightness.dark;
    return Row(
      mainAxisAlignment: MainAxisAlignment.center,
      children: [
        _circleButton(
          theme,
          Icons.shuffle,
          '随机播放',
          () => _playAll(shuffle: true),
        ),
        const SizedBox(width: 24),
        ElevatedButton.icon(
          onPressed: () => _playAll(),
          icon: const Icon(Icons.play_arrow, size: 22),
          label: const Text(
            '播放',
            style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700),
          ),
          style: ElevatedButton.styleFrom(
            backgroundColor: isDark ? Colors.white : const Color(0xFF1C1C1E),
            foregroundColor: isDark ? Colors.black : Colors.white,
            padding: const EdgeInsets.symmetric(horizontal: 36, vertical: 14),
            shape: const StadiumBorder(),
          ),
        ),
        const SizedBox(width: 24),
        _circleButton(theme, Icons.add, '加入歌单', _addToPlaylist),
      ],
    );
  }

  Widget _circleButton(
    HaoTheme theme,
    IconData icon,
    String label,
    VoidCallback onTap,
  ) {
    return InkWell(
      onTap: onTap,
      borderRadius: BorderRadius.circular(24),
      child: Container(
        width: 48,
        height: 48,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: theme.surface,
          border: Border.all(color: theme.hairline),
        ),
        child: Icon(icon, color: theme.textPrimary, size: 22),
      ),
    );
  }

  Widget _trackRow(HaoTheme theme, Song song, int index) {
    final favIds = MusicStore.getFavIds();
    return SongRow(
      song: song,
      isFav: favIds.contains(song.identityKey),
      onPlay: () {
        unawaited(_player.playQueue(_songs, index));
        unawaited(
          Navigator.of(context).push(
            MaterialPageRoute<void>(builder: (_) => const MusicPlayerPage()),
          ),
        );
      },
      onToggleFav: () async {
        await _player.toggleFav(song);
        setState(() {});
      },
      leading: Text(
        '${index + 1}',
        style: TextStyle(
          color: theme.textMuted,
          fontWeight: FontWeight.w700,
        ),
      ),
      onLongPress: () => unawaited(openTrackMoreSheet(context, song)),
    );
  }
}
