import '../../core/theme/hao_radius.dart';
import 'dart:async';

// Playlist plaza (fix 9).
//
// Platform selector (网易云/QQ音乐/酷我/酷狗音乐） is STICKY: the selected
// platform is stored, the selector always shows the stored platform, and
// loading fetches ONLY that platform. If the selected platform returns no
// items or errors, show that platform's error/empty state — never silently
// change the selector to wy and show wy data. Cross-platform fallback
// order wy/tx/kw/kg applies ONLY when the user has never chosen (default
// wy) or an explicit retry action; it is never an automatic silent switch.
// Kuwo requests use https; Kugou uses its mobile CDN search endpoint.
// Cache per platform; a platform switch cancels the in-flight load for
// the previous platform (sequence guard) so a late response cannot
// overwrite the newly selected platform.
//
// Stage 2: the plaza shares the ONE search-platform capsule
// (SearchPlatformStore) with the search page — the plaza opens on the
// capsule platform, and changing the platform here changes the capsule
// too (both writes go through both stores, so the legacy plaza key
// stays in sync for any reader that still uses it).

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/storage/hive_store.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/glass.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import '../../services/music/search_platform_store.dart';
import 'music_navigation.dart';
import 'music_player_controller.dart';
import 'player_expand_route.dart';
import 'widgets/mini_player_bar.dart';
import 'widgets/song_row.dart';
import 'widgets/track_more_sheet.dart';
import 'widgets/music_image.dart';
import '../../widgets/platform_logo.dart';
import '../../widgets/play_count_badge.dart';

enum _PlazaSort { rec, hot, fresh }

class PlazaPage extends StatefulWidget {
  const PlazaPage({super.key, this.api});

  /// Test seam only: an injected [MusicApi] (fake Dio in render
  /// tests). Null in production — the page owns a fresh one.
  final MusicApi? api;

  @override
  State<PlazaPage> createState() => _PlazaPageState();
}

class _PlazaPageState extends State<PlazaPage> {
  late final MusicApi _api = widget.api ?? MusicApi();
  final _cache = <MusicPlatform, List<PlaylistSummary>>{};
  late MusicPlatform _platform;
  var _sort = _PlazaSort.rec;
  var _loading = false;
  var _failed = false;
  var _seq = 0;

  @override
  void initState() {
    super.initState();
    _platform = SearchPlatformStore.current();
    _load(_platform);
  }

  Future<void> _load(MusicPlatform pf) async {
    final seq = ++_seq;
    if (_cache.containsKey(pf)) {
      if (mounted) {
        setState(() {
          _platform = pf;
          _loading = false;
          _failed = false;
        });
      }
      return;
    }
    if (mounted) {
      setState(() {
        _platform = pf;
        _loading = true;
        _failed = false;
      });
    }
    List<PlaylistSummary> items;
    try {
      items = await _api.plaza(pf);
    } catch (_) {
      items = [];
    }
    // Sequence guard: a late response for the previous platform must
    // never overwrite the newly selected platform.
    if (seq != _seq || !mounted) return;
    _cache[pf] = items;
    // Keep the home's 歌单广场 card fresh: the first playlist's
    // cover is cached for the home to read (no fetch from the home).
    if (items.isNotEmpty && items.first.cover.isNotEmpty) {
      unawaited(
        MusicStore.setFeatureCover(
          HiveKeys.featureCoverPlaza,
          items.first.cover,
        ),
      );
    }
    setState(() {
      _loading = false;
      _failed = items.isEmpty;
    });
  }

  Future<void> _selectPlatform(MusicPlatform pf) async {
    if (pf == _platform && _cache.containsKey(pf)) return;
    await SearchPlatformStore.set(pf);
    await MusicStore.setPlazaPlatform(pf);
    await _load(pf);
  }

  List<PlaylistSummary> get _sorted {
    final items = List<PlaylistSummary>.of(_cache[_platform] ?? []);
    switch (_sort) {
      case _PlazaSort.rec:
        return items;
      case _PlazaSort.hot:
        items.sort((a, b) => b.playCount.compareTo(a.playCount));
        return items;
      case _PlazaSort.fresh:
        items.sort((a, b) => b.time.compareTo(a.time));
        return items;
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final items = _sorted;
    return Scaffold(
      appBar: AppBar(title: Text('歌单广场', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))), flexibleSpace: const HaoAppBarGlass()),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
            child: Text(
              '各大音乐平台的热门歌单，点进去就能听，也能一键导入到我的歌单',
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textSecondary, fontSize: 13),
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
            child: Row(
              children: [
                Expanded(
                  child: GlassCard(
                    radius: HaoRadius.sheet,
                    padding: const EdgeInsets.symmetric(horizontal: 10),
                    child: DropdownButton<MusicPlatform>(
                      value: _platform,
                      isExpanded: true,
                      underline: const SizedBox.shrink(),
                      items: [
                        for (final pf in kPlazaPlatforms)
                          DropdownMenuItem(
                            value: pf,
                            child: Row(
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                // Real brand logo (chen 2026-11-18) —
                                // the closed button shows the same row.
                                PlatformLogo(platform: pf, size: 20),
                                const SizedBox(width: 8),
                                // Flexible + ellipsis: the header row is
                                // tight at 390pt; a 3-char name overflowed
                                // 4.5px, 4-char names 21px (the logo added
                                // 28px to the button). The name must shrink
                                // instead of overflowing the button.
                                Flexible(
                                  child: Text(
                                    pf.displayName,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(shadows: HaoTheme.legibilityShadows(context)),
                                  ),
                                ),
                              ],
                            ),
                          ),
                      ],
                      onChanged: (v) {
                        if (v != null) _selectPlatform(v);
                      },
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                for (final (sort, label) in [
                  (_PlazaSort.rec, '推荐'),
                  (_PlazaSort.hot, '最热'),
                  (_PlazaSort.fresh, '最新'),
                ])
                  Padding(
                    padding: const EdgeInsets.only(left: 4),
                    child: ChoiceChip(
                      label: Text(label),
                      selected: _sort == sort,
                      selectedColor: theme.accentSoft,
                      side: BorderSide(color: theme.hairline),
                      labelStyle: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: _sort == sort
                            ? theme.accent
                            : theme.textSecondary,
                        fontWeight: _sort == sort
                            ? FontWeight.w700
                            : FontWeight.w400,
                      ),
                      onSelected: (_) => setState(() => _sort = sort),
                    ),
                  ),
              ],
            ),
          ),
          Expanded(
            child: _loading
                ? const Center(child: CupertinoActivityIndicator())
                : _failed
                    ? _errorState(theme)
                    : items.isEmpty
                        ? Center(
                            child: Text(
                              '${_platform.displayName}暂时没有歌单',
                              style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textMuted),
                            ),
                          )
                        : ListView.builder(
                            padding: EdgeInsets.only(
                              bottom:
                                  MiniPlayerBar.bottomClearanceFor(context),
                            ),
                            itemCount: items.length,
                            itemBuilder: (ctx, i) {
                              final p = items[i];
                              return ListTile(
                                leading: ClipRRect(
                                  borderRadius: BorderRadius.circular(HaoRadius.standard),
                                  child: p.cover.isEmpty
                                      ? Container(
                                          width: 52,
                                          height: 52,
                                          color: theme.accentSoft,
                                          child: Icon(
                                            shadows: HaoTheme.legibilityShadows(ctx),
                                            Icons.music_note,
                                            color: theme.textMuted,
                                          ),
                                        )
                                      : Image(
                                          image: MusicImageProvider(p.cover),
                                          width: 52,
                                          height: 52,
                                          fit: BoxFit.cover,
                                          errorBuilder: (_, _, _) =>
                                              Container(
                                            width: 52,
                                            height: 52,
                                            color: theme.accentSoft,
                                            child: Icon(
                                              shadows: HaoTheme.legibilityShadows(ctx),
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
                                    shadows: HaoTheme.legibilityShadows(ctx),
                                    color: theme.textPrimary,
                                    fontSize: 15,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                // 播放量只在角标里出现一次（Kumone
                                // PlayCountBadge）：副标题不再重复 raw
                                // 数字，避免“12.3万”和“123456次播放”
                                // 两处打架；playCount 为 0 时角标不
                                // 显示，副标题也不画“0次播放”。
                                subtitle: Text(
                                  p.creator.isEmpty
                                      ? p.platform.displayName
                                      : p.creator,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    shadows: HaoTheme.legibilityShadows(ctx),
                                    color: theme.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                                // Kumone 把角标放封面右上角（Cards.swift:28-30），
                                // 但本页卡片是 ListTile 行、封面只有 52px，
                                // 角标最窄约 47px，6px 内嵌会溢出封面左缘，
                                // 所以落点改为行尾（badge + chevron）。
                                trailing: Row(
                                  mainAxisSize: MainAxisSize.min,
                                  children: [
                                    if (p.playCount > 0)
                                      PlayCountBadge(count: p.playCount),
                                    if (p.playCount > 0)
                                      const SizedBox(width: 8),
                                    Icon(
                                      shadows: HaoTheme.legibilityShadows(ctx),
                                      Icons.chevron_right,
                                      color: theme.textMuted,
                                    ),
                                  ],
                                ),
                                onTap: () => Navigator.of(context).push(
                                  CupertinoPageRoute<void>(
                                    settings: const RouteSettings(
                                        name: musicSubPageRouteName),
                                    builder: (_) =>
                                        PlazaDetailPage(playlist: p),
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

  Widget _errorState(HaoTheme theme) {
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: [
          Text(
            '${_platform.displayName}歌单加载失败',
            style: TextStyle(
              shadows: HaoTheme.legibilityShadows(context),
              color: theme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w700,
            ),
          ),
          const SizedBox(height: 4),
          Text(
            '当前选择仍是${_platform.displayName}，没有切换到其他平台',
            style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textMuted, fontSize: 13),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: () {
              _cache.remove(_platform);
              _load(_platform);
            },
            child: const Text('重试'),
          ),
        ],
      ),
    );
  }
}

/// Plaza playlist detail: track list + 一键导入 to my playlists.
class PlazaDetailPage extends StatefulWidget {
  const PlazaDetailPage({
    super.key,
    required this.playlist,
    this.api,
    this.isChart = false,
  });

  final PlaylistSummary playlist;

  /// Test seam (same pattern as ChartsPage.api): a fake-Dio api.
  /// Defaults to a real [MusicApi].
  final MusicApi? api;

  /// True when opened from the charts list: the chart's first song
  /// cover is written to the charts feature-cover cache on load, so
  /// the home's 排行榜 card stays fresh (a chart's #1 song changes
  /// weekly; the cache used to refresh only when empty, so the card
  /// went stale). False for plaza / search playlists (their covers
  /// have their own cache key, written by PlazaPage._load).
  final bool isChart;

  @override
  State<PlazaDetailPage> createState() => _PlazaDetailPageState();
}

class _PlazaDetailPageState extends State<PlazaDetailPage> {
  late final _api = widget.api ?? MusicApi();
  List<Song>? _tracks;
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
      final r = await _api.importPlaylist(
        widget.playlist.platform,
        widget.playlist.id,
      );
      if (!mounted) return;
      setState(() {
        _tracks = r.tracks;
        _loading = false;
        _failed = r.tracks.isEmpty;
      });
      // Charts: keep the home's 排行榜 card fresh — copy the
      // PlazaPage._load pattern (first cover -> cache). The #1 song
      // changes weekly, so the cache is refreshed on every chart
      // open, not only when empty. Empty covers never overwrite a
      // good cached cover (setFeatureCover ignores them).
      if (widget.isChart) {
        for (final song in r.tracks) {
          if (song.cover.isNotEmpty) {
            unawaited(
              MusicStore.setFeatureCover(
                HiveKeys.featureCoverCharts,
                song.cover,
              ),
            );
            break;
          }
        }
      }
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  Future<void> _importAll() async {
    final tracks = _tracks;
    if (tracks == null || tracks.isEmpty) return;
    final lists = MusicStore.getLists();
    var list = lists.where((l) => l.name == widget.playlist.name).firstOrNull;
    list ??= UserPlaylist(
      id: 'l${DateTime.now().millisecondsSinceEpoch}',
      name: widget.playlist.name,
    );
    if (!lists.contains(list)) lists.add(list);
    final res = MusicStore.addTracks(list, tracks);
    await MusicStore.saveLists(lists);
    await MusicStore.setCurrentListId(list.id);
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          res.dropped > 0
              ? '导入成功 ${res.added} 首，还有 ${res.dropped} 首没进来（每歌单最多 ${MusicStore.maxTracksPerList} 首）→ ${list.name}'
              : '导入成功 ${res.added} 首 → ${list.name}',
        ),
      ),
    );
  }

  void _playAll() {
    final tracks = _tracks;
    if (tracks == null || tracks.isEmpty) return;
    unawaited(_player.playQueue(tracks, 0, label: widget.playlist.name));
    unawaited(openPlayerPage<void>(context));
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final p = widget.playlist;
    // Favourites read once per build, not per row: getFavIds() parses
    // the whole favourites JSON on every call, and the row builder
    // runs once per visible row per scroll frame.
    final favIds = MusicStore.getFavIds();
    return Scaffold(
      appBar: AppBar(title: Text(p.name, maxLines: 1, style: TextStyle(shadows: HaoTheme.legibilityShadows(context))), flexibleSpace: const HaoAppBarGlass()),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : _failed
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text('歌单加载失败', style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary, fontSize: 16, fontWeight: FontWeight.w700)),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () {
                          setState(() => _loading = true);
                          _load();
                        },
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.all(16),
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(HaoRadius.large),
                            child: p.cover.isEmpty
                                ? Container(
                                    width: 96,
                                    height: 96,
                                    color: theme.accentSoft,
                                    child: Icon(
                                      shadows: HaoTheme.legibilityShadows(context),
                                      Icons.music_note,
                                      color: theme.textMuted,
                                      size: 40,
                                    ),
                                  )
                                : Image(
                                    image: MusicImageProvider(p.cover),
                                    width: 96,
                                    height: 96,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Container(
                                      width: 96,
                                      height: 96,
                                      color: theme.accentSoft,
                                      child: Icon(
                                        shadows: HaoTheme.legibilityShadows(context),
                                        Icons.music_note,
                                        color: theme.textMuted,
                                        size: 40,
                                      ),
                                    ),
                                  ),
                          ),
                          const SizedBox(width: 16),
                          Expanded(
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                Text(
                                  p.name,
                                  style: TextStyle(
                                    shadows: HaoTheme.legibilityShadows(context),
                                    color: theme.textPrimary,
                                    fontSize: 20,
                                    fontWeight: FontWeight.w800,
                                  ),
                                ),
                                const SizedBox(height: 4),
                                Text(
                                  '${p.platform.displayName} · ${p.creator}',
                                  style: TextStyle(
                                    shadows: HaoTheme.legibilityShadows(context),
                                    color: theme.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                                const SizedBox(height: 2),
                                Text(
                                  '${_tracks?.length ?? 0} 首歌曲',
                                  style: TextStyle(
                                    shadows: HaoTheme.legibilityShadows(context),
                                    color: theme.textSecondary,
                                    fontSize: 13,
                                  ),
                                ),
                              ],
                            ),
                          ),
                        ],
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Row(
                        children: [
                          Expanded(
                            child: FilledButton.icon(
                              onPressed: _playAll,
                              icon: Icon(Icons.play_arrow, shadows: HaoTheme.legibilityShadows(context),),
                              label: const Text('播放全部'),
                            ),
                          ),
                          const SizedBox(width: 8),
                          Expanded(
                            child: OutlinedButton.icon(
                              onPressed: _importAll,
                              icon: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.download),
                              label: Text('一键导入', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        padding: EdgeInsets.only(
                          bottom: MiniPlayerBar.bottomClearanceFor(context),
                        ),
                        itemCount: _tracks?.length ?? 0,
                        itemBuilder: (ctx, i) {
                          final song = _tracks![i];
                          return SongRow(
                            song: song,
                            isFav: favIds.contains(song.identityKey),
                            onPlay: () {
                              unawaited(
                                _player.playQueue(_tracks!, i),
                              );
                              unawaited(openPlayerPage<void>(context));
                            },
                            onToggleFav: () async {
                              await _player.toggleFav(song);
                              setState(() {});
                            },
                            onLongPress: (rowCtx) =>
                                unawaited(openSongQuickMenu(rowCtx, song)),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
