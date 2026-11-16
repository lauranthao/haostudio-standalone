import 'dart:async';

// Music home (fix 11).
//
// Order, top to bottom: greeting/date, quick-action tiles (search /
// daily / plaza / listen report), then 我的歌单 (My Playlists), then
// 最近播放 (Recently Played). Both sections start COLLAPSED and expand
// only when the user taps the section head (chevron rotates 90° when
// open, 0.2 s). Collapsed state is per-section and kept for the session.
//
// Playlist card count = tracks.length (audit P0-1) — never a stored
// count field. The import box lives inside the 我的歌单 section.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import 'artist_detail_page.dart';
import 'daily_page.dart';
import 'downloads_page.dart';
import 'favourites_page.dart';
import 'listen_report_page.dart';
import 'music_player_controller.dart';
import 'music_player_sheet.dart';
import 'plaza_page.dart';
import 'playlist_detail_page.dart';
import 'song_search_page.dart';
import 'widgets/collapsible_section.dart';
import 'widgets/song_row.dart';
import 'widgets/track_more_sheet.dart';
import 'widgets/music_image.dart';

class MusicTabPage extends StatefulWidget {
  const MusicTabPage({super.key});

  @override
  State<MusicTabPage> createState() => _MusicTabPageState();
}

class _MusicTabPageState extends State<MusicTabPage> {
  final _importController = TextEditingController();
  var _playlistsExpanded = false;
  var _recentExpanded = false;
  List<UserPlaylist> _lists = [];
  List<Song> _recent = [];
  var _importing = false;

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _refresh();
  }

  @override
  void dispose() {
    _importController.dispose();
    super.dispose();
  }

  void _refresh() {
    setState(() {
      _lists = MusicStore.getLists();
      _recent = MusicStore.getRecent();
    });
  }

  Future<void> _push(Widget page) async {
    await Navigator.of(context).push(
      MaterialPageRoute<void>(builder: (_) => page),
    );
    _refresh();
  }

  Future<void> _createList() async {
    final nameController = TextEditingController();
    final name = await showDialog<String>(
      context: context,
      builder: (ctx) {
        final theme = HaoTheme.of(ctx);
        return AlertDialog(
          backgroundColor: theme.surfaceSolid,
          title: Text('新歌单的名字', style: TextStyle(color: theme.textPrimary)),
          content: TextField(
            controller: nameController,
            autofocus: true,
            decoration: const InputDecoration(hintText: '歌单名'),
          ),
          actions: [
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(),
              child: Text('取消', style: TextStyle(color: theme.textSecondary)),
            ),
            TextButton(
              onPressed: () => Navigator.of(ctx).pop(nameController.text.trim()),
              child: Text('新建歌单', style: TextStyle(color: theme.accent)),
            ),
          ],
        );
      },
    );
    nameController.dispose();
    if (name == null || name.isEmpty) return;
    final lists = MusicStore.getLists();
    if (lists.length >= 10) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('歌单已满（最多 10 个）')),
      );
      return;
    }
    final id = 'l${DateTime.now().millisecondsSinceEpoch}';
    lists.add(UserPlaylist(id: id, name: name));
    await MusicStore.saveLists(lists);
    await MusicStore.setCurrentListId(id);
    _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(content: Text('歌单已创建')),
    );
  }

  Future<void> _importLink() async {
    final url = _importController.text.trim();
    if (url.isEmpty || _importing) return;
    setState(() => _importing = true);
    try {
      final r = await MusicApi().importFromLink(url);
      if (r == null || r.tracks.isEmpty) {
        if (!mounted) return;
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('导入失败：请粘贴网易云 / QQ / 酷我公开歌单链接')),
        );
        return;
      }
      final lists = MusicStore.getLists();
      var list = lists.where((l) => l.name == r.name).firstOrNull;
      list ??= UserPlaylist(
        id: 'l${DateTime.now().millisecondsSinceEpoch}',
        name: r.name.isEmpty ? '我的歌单' : r.name,
      );
      if (!lists.contains(list)) lists.add(list);
      final seen = list.tracks.map((t) => t.identityKey).toSet();
      var added = 0;
      for (final t in r.tracks) {
        if (seen.contains(t.identityKey)) continue;
        if (list.tracks.length >= 200) break;
        list.tracks.add(t);
        added++;
      }
      await MusicStore.saveLists(lists);
      await MusicStore.setCurrentListId(list.id);
      _importController.clear();
      _refresh();
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(content: Text('导入成功 $added 首 → ${list.name}')),
      );
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _playSong(Song song, List<Song> queue) {
    final idx = queue.indexWhere((s) => s.identityKey == song.identityKey);
    unawaited(_player.playQueue(queue, idx < 0 ? 0 : idx));
    _openPlayer();
  }

  void _openPlayer() {
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
      appBar: AppBar(title: const Text('音乐')),
      body: Column(
        children: [
          Expanded(
            child: ListView(
              children: [
                _greeting(theme),
                _quickTiles(theme),
                CollapsibleSection(
                  title: '我的歌单',
                  expanded: _playlistsExpanded,
                  onToggle: () => setState(
                    () => _playlistsExpanded = !_playlistsExpanded,
                  ),
                  child: _playlistsBody(theme),
                ),
                CollapsibleSection(
                  title: '最近播放',
                  expanded: _recentExpanded,
                  onToggle: () =>
                      setState(() => _recentExpanded = !_recentExpanded),
                  child: _recentBody(theme),
                ),
                const SizedBox(height: 16),
              ],
            ),
          ),
          _miniPlayer(theme),
        ],
      ),
    );
  }

  Widget _greeting(HaoTheme theme) {
    final now = DateTime.now();
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Text(
            greetingFor(now),
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 26,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            homeDateText(now),
            style: TextStyle(color: theme.textSecondary, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _quickTiles(HaoTheme theme) {
    final tiles = <(IconData, String, VoidCallback)>[
      (Icons.search, '搜歌', () => _push(const SongSearchPage())),
      (Icons.calendar_today, '每日推荐', () => _push(const DailyPage())),
      (Icons.grid_view, '歌单广场', () => _push(const PlazaPage())),
      (
        Icons.bar_chart,
        '听歌报告',
        () => _push(const ListenReportPage()),
      ),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      child: Row(
        children: [
          for (final (icon, label, onTap) in tiles)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 4),
                child: InkWell(
                  onTap: onTap,
                  borderRadius: BorderRadius.circular(20),
                  child: Container(
                    padding: const EdgeInsets.symmetric(vertical: 18),
                    decoration: BoxDecoration(
                      color: theme.surface,
                      borderRadius: BorderRadius.circular(20),
                      border: Border.all(color: theme.hairline),
                      boxShadow: [
                        BoxShadow(
                          color: theme.textPrimary.withValues(alpha: 0.06),
                          blurRadius: 12,
                          offset: const Offset(0, 4),
                        ),
                      ],
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: [
                        Icon(icon, color: theme.accent, size: 28),
                        const SizedBox(height: 6),
                        Text(
                          label,
                          style: TextStyle(
                            color: theme.textPrimary,
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _playlistsBody(HaoTheme theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          // Favourites entry (M-P0-7): opens the 我的收藏 page.
          _favCard(theme),
          const SizedBox(height: 8),
          // Downloads entry (M-P0-5): opens the 已下载 page.
          _downloadsCard(theme),
          const SizedBox(height: 8),
          Row(
            children: [
              Expanded(
                child: TextField(
                  controller: _importController,
                  decoration: InputDecoration(
                    hintText: '粘贴网易云 / QQ / 酷我歌单链接',
                    hintStyle: TextStyle(color: theme.textMuted, fontSize: 13),
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
              ElevatedButton(
                onPressed: _importing ? null : _importLink,
                style: ElevatedButton.styleFrom(
                  backgroundColor: theme.accent,
                  foregroundColor: Theme.of(context).colorScheme.onPrimary,
                ),
                child: Text(_importing ? '导入中…' : '一键导入'),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            '支持网易云、QQ、酷我、酷狗公开歌单链接。',
            style: TextStyle(color: theme.textMuted, fontSize: 12),
          ),
          const SizedBox(height: 8),
          if (_lists.isEmpty)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Text(
                '歌单还是空的，搜一首歌加进来吧',
                style: TextStyle(color: theme.textMuted),
              ),
            ),
          for (final list in _lists)
            _playlistCard(theme, list),
          OutlinedButton.icon(
            onPressed: _createList,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建歌单'),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.accent,
              side: BorderSide(color: theme.hairline),
            ),
          ),
          const SizedBox(height: 8),
        ],
      ),
    );
  }

  Widget _favCard(HaoTheme theme) {
    final count = MusicStore.getFavIds().length;
    return Card(
      color: theme.surface,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _push(const FavouritesPage()),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: theme.accentSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.favorite, color: theme.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '我的收藏',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      count == 0 ? '还没有收藏的歌曲' : '$count 首歌曲',
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _downloadsCard(HaoTheme theme) {
    final count = _player.downloads.downloadedCount;
    return Card(
      color: theme.surface,
      margin: EdgeInsets.zero,
      child: InkWell(
        onTap: () => _push(const DownloadsPage()),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              Container(
                width: 52,
                height: 52,
                decoration: BoxDecoration(
                  color: theme.accentSoft,
                  borderRadius: BorderRadius.circular(12),
                ),
                child: Icon(Icons.download, color: theme.accent),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      '已下载',
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      count == 0 ? '离线听歌，还没有下载' : '$count 首歌曲',
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _playlistCard(HaoTheme theme, UserPlaylist list) {
    return Card(
      color: theme.surface,
      margin: const EdgeInsets.only(bottom: 8),
      child: InkWell(
        onTap: () => _push(PlaylistDetailPage(playlistId: list.id)),
        borderRadius: BorderRadius.circular(20),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(12),
                child: list.cover.isEmpty
                    ? Container(
                        width: 52,
                        height: 52,
                        color: theme.accentSoft,
                        child: Icon(
                          Icons.music_note,
                          color: theme.textMuted,
                        ),
                      )
                    : Image(
                        image: MusicImageProvider(list.cover),
                        width: 52,
                        height: 52,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 52,
                          height: 52,
                          color: theme.accentSoft,
                          child: Icon(
                            Icons.music_note,
                            color: theme.textMuted,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      list.name,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 16,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    // Audit P0-1: count is tracks.length, recomputed here.
                    Text(
                      '${list.trackCount} 首歌曲',
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 13,
                      ),
                    ),
                  ],
                ),
              ),
              Icon(Icons.chevron_right, color: theme.textMuted),
            ],
          ),
        ),
      ),
    );
  }

  Widget _recentBody(HaoTheme theme) {
    if (_recent.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
        child: Text(
          '还没有播放记录，搜首歌播一下吧',
          style: TextStyle(color: theme.textMuted),
        ),
      );
    }
    final shown = _recent.take(5).toList();
    final favIds = MusicStore.getFavIds();
    return Column(
      children: [
        for (final song in shown)
          SongRow(
            song: song,
            isFav: favIds.contains(song.identityKey),
            onPlay: () => _playSong(song, shown),
            onToggleFav: () async {
              await _player.toggleFav(song);
              _refresh();
            },
            onOpenArtist: () => _push(
              ArtistDetailPage(
                platform: song.platform,
                artistId: '',
                artistName: firstArtist(song.artist),
              ),
            ),
            onLongPress: () => unawaited(openTrackMoreSheet(context, song)),
          ),
      ],
    );
  }

  Widget _miniPlayer(HaoTheme theme) {
    return Obx(() {
      final song = _player.currentSong;
      if (song == null) return const SizedBox.shrink();
      return GestureDetector(
        onTap: _openPlayer,
        child: Container(
          decoration: BoxDecoration(
            color: theme.surfaceStrong,
            border: Border(top: BorderSide(color: theme.hairline)),
            boxShadow: [
              BoxShadow(
                color: theme.textPrimary.withValues(alpha: 0.08),
                blurRadius: 16,
                offset: const Offset(0, -4),
              ),
            ],
          ),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          child: Row(
            children: [
              ClipRRect(
                borderRadius: BorderRadius.circular(8),
                child: song.cover.isEmpty
                    ? Container(
                        width: 40,
                        height: 40,
                        color: theme.accentSoft,
                        child: Icon(Icons.music_note, color: theme.textMuted),
                      )
                    : Image(
                        image: MusicImageProvider(song.cover),
                        width: 40,
                        height: 40,
                        fit: BoxFit.cover,
                        errorBuilder: (_, _, _) => Container(
                          width: 40,
                          height: 40,
                          color: theme.accentSoft,
                          child: Icon(
                            Icons.music_note,
                            color: theme.textMuted,
                          ),
                        ),
                      ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    Text(
                      song.title,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    Text(
                      song.artist,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        color: theme.textSecondary,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
              ),
              IconButton(
                icon: Icon(
                  playModeIcon(_player.mode),
                  color: theme.textPrimary,
                ),
                tooltip: '播放模式',
                onPressed: () => _player.cyclePlayMode(),
              ),
              IconButton(
                icon: Icon(
                  _player.isPlaying.value
                      ? Icons.pause
                      : Icons.play_arrow,
                  color: theme.textPrimary,
                ),
                onPressed: () => _player.togglePlayPause(),
              ),
              IconButton(
                icon: Icon(Icons.skip_next, color: theme.textPrimary),
                onPressed: () => _player.next(),
              ),
            ],
          ),
        ),
      );
    });
  }
}
