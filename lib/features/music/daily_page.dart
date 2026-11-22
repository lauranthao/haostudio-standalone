import 'dart:async';

// Daily picks (app.js:3308-3346) — date header + 播放全部.
//
// ~20 songs: half most-played + half discovery via top artists; same-day
// stable (date-seeded shuffle, cached per day). Cold-start hint when
// there is no listen history at all.

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/theme/hao_radius.dart';
import '../../core/theme/hao_themes.dart';
import '../../services/music/daily_service.dart';
import '../../services/music/multi_queue_store.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import 'artist_detail_page.dart';
import 'music_navigation.dart';
import 'music_player_controller.dart';
import 'player_expand_route.dart';
import 'widgets/mini_player_bar.dart';
import 'widgets/music_image.dart';
import 'widgets/song_row.dart';
import 'widgets/track_more_sheet.dart';
import '../../widgets/hao_nav_bar.dart';

class DailyPage extends StatefulWidget {
  const DailyPage({super.key});

  @override
  State<DailyPage> createState() => _DailyPageState();
}

class _DailyPageState extends State<DailyPage> {
  final _service = DailyService();
  List<Song>? _tracks;
  var _cold = false;
  var _loading = true;
  var _failed = false;

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    // buildDaily has no internal catch-all: without this, any throw
    // (e.g. a Hive write failing mid-save) left the spinner spinning
    // forever with no retry — every sibling page has this guard.
    try {
      final r = await _service.buildDaily();
      if (!mounted) return;
      setState(() {
        _tracks = r.tracks;
        _cold = r.cold;
        _loading = false;
        _failed = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
    }
  }

  String _reasonText(Song s) {
    switch (s.reasonKey) {
      case 'becauseListen':
        return '因为你常听 ${s.reasonArg}';
      case 'becauseArtist':
        return '因为你常听 ${s.reasonArg}';
      case 'hotPick':
        return '热门推荐';
      default:
        return '';
    }
  }

  void _playAll() {
    final tracks = _tracks;
    if (tracks == null || tracks.isEmpty) return;
    unawaited(
      _player.playQueue(
        tracks,
        0,
        label: '每日推荐',
        sourceKey: QueueSource.daily(dayKeyOf(DateTime.now())),
        resumeFromMemory: true,
      ),
    );
    unawaited(openPlayerPage<void>(context));
  }

  /// Play the 今日一 Pick inside the daily queue (same source, so
  /// the queue position is remembered like the rest of the list).
  void _playPick(Song pick) {
    final tracks = _tracks;
    if (tracks == null || tracks.isEmpty) return;
    final idx = tracks.indexWhere((s) => s.identityKey == pick.identityKey);
    if (idx < 0) return;
    unawaited(
      _player.playQueue(
        tracks,
        idx,
        label: '每日推荐',
        sourceKey: QueueSource.daily(dayKeyOf(DateTime.now())),
      ),
    );
    unawaited(openPlayerPage<void>(context));
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final now = DateTime.now();
    // Favourites read once per build, not per row: getFavIds() parses
    // the whole favourites JSON on every call, and the row builder
    // runs once per visible row per scroll frame.
    final favIds = MusicStore.getFavIds();
    return Scaffold(
      appBar: HaoNavBar(
        title: '每日推荐',
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : _failed
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '每日推荐加载失败',
                        style: TextStyle(color: theme.textPrimary),
                      ),
                      const SizedBox(height: 12),
                      FilledButton(
                        onPressed: () {
                          setState(() {
                            _loading = true;
                            _failed = false;
                          });
                          _load();
                        },
                        child: const Text('重试'),
                      ),
                    ],
                  ),
                )
              : _tracks == null || _tracks!.isEmpty
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Text(
                        '多听几首歌，明天就有推荐啦',
                        style: TextStyle(color: theme.textMuted),
                      ),
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
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        homeDateText(now),
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: Text(
                        '每日推荐',
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 24,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
                      child: Text(
                        '一半是你常听的，一半是为你发现的',
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: FilledButton.icon(
                        onPressed: _playAll,
                        icon: Icon(Icons.play_arrow, shadows: HaoTheme.legibilityShadows(context),),
                        label: const Text('播放全部'),
                      ),
                    ),
                    // 今日一 Pick (build 29): one deterministic song
                    // of the day from this list — same song all day,
                    // a different one tomorrow.
                    Builder(
                      builder: (ctx) {
                        final pick =
                            DailyService.pickOfDay(_tracks!, now: now);
                        if (pick == null) return const SizedBox.shrink();
                        return Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                          child: Material(
                            color: Colors.transparent,
                            child: InkWell(
                              onTap: () => _playPick(pick),
                              borderRadius: BorderRadius.circular(HaoRadius.large),
                              child: Container(
                                padding: const EdgeInsets.all(12),
                                decoration: BoxDecoration(
                                  borderRadius: BorderRadius.circular(HaoRadius.large),
                                  color: theme.accent.withValues(alpha: 0.1),
                                  border: Border.all(
                                    color: theme.accent.withValues(alpha: 0.3),
                                    width: 0.8,
                                  ),
                                ),
                                child: Row(
                                  children: [
                                    ClipRRect(
                                      borderRadius: BorderRadius.circular(HaoRadius.standard),
                                      child: pick.cover.isEmpty
                                          ? Container(
                                              width: 48,
                                              height: 48,
                                              color: theme.accentSoft,
                                              child: Icon(
                                                Icons.music_note,
                                                shadows: HaoTheme.legibilityShadows(context),
                                                color: theme.textMuted,
                                              ),
                                            )
                                          : Image(
                                              image: MusicImageProvider(
                                                pick.cover,
                                              ),
                                              width: 48,
                                              height: 48,
                                              fit: BoxFit.cover,
                                            ),
                                    ),
                                    const SizedBox(width: 12),
                                    Expanded(
                                      child: Column(
                                        crossAxisAlignment:
                                            CrossAxisAlignment.start,
                                        children: [
                                          Text(
                                            '今日一 Pick',
                                            style: TextStyle(
                                              shadows: HaoTheme.legibilityShadows(context),
                                              color: theme.accent,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          const SizedBox(height: 2),
                                          Text(
                                            pick.title,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              shadows: HaoTheme.legibilityShadows(context),
                                              color: theme.textPrimary,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                          Text(
                                            pick.artist,
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: theme.textSecondary,
                                              fontSize: 13,
                                            ),
                                          ),
                                        ],
                                      ),
                                    ),
                                    Icon(
                                      Icons.play_circle_filled,
                                      shadows: HaoTheme.legibilityShadows(context),
                                      color: theme.accent,
                                      size: 32,
                                    ),
                                  ],
                                ),
                              ),
                            ),
                          ),
                        );
                      },
                    ),
                    if (_cold)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 12, 16, 0),
                        child: Text(
                          '多听几首歌，明天推荐会更准',
                          style: TextStyle(
                            color: theme.textSecondary,
                            fontSize: 13,
                          ),
                        ),
                      ),
                    const SizedBox(height: 8),
                    Expanded(
                      child: ListView.builder(
                        padding: EdgeInsets.only(
                          bottom: MiniPlayerBar.bottomClearanceFor(context),
                        ),
                        itemCount: _tracks!.length,
                        itemBuilder: (ctx, i) {
                          final song = _tracks![i];
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SongRow(
                                song: song,
                                isFav: favIds.contains(song.identityKey),
                                onPlay: () {
                                  unawaited(
                                    _player.playQueue(
                                      _tracks!,
                                      i,
                                      sourceKey: QueueSource.daily(
                                        dayKeyOf(DateTime.now()),
                                      ),
                                    ),
                                  );
                                  unawaited(openPlayerPage<void>(context));
                                },
                                onToggleFav: () async {
                                  await _player.toggleFav(song);
                                  setState(() {});
                                },
                                onOpenArtist: () => Navigator.of(context).push(
                                  CupertinoPageRoute<void>(
                                    settings: const RouteSettings(
                                        name: musicSubPageRouteName),
                                    builder: (_) => ArtistDetailPage(
                                      platform: song.platform,
                                      artistId: '',
                                      artistName: firstArtist(song.artist),
                                    ),
                                  ),
                                ),
                                onLongPress: (rowCtx) =>
                                unawaited(openSongQuickMenu(rowCtx, song)),
                              ),
                              Padding(
                                padding: const EdgeInsets.only(
                                  left: 72,
                                  bottom: 4,
                                ),
                                child: Text(
                                  _reasonText(song),
                                  style: TextStyle(
                                    color: theme.textMuted,
                                    fontSize: 12,
                                  ),
                                ),
                              ),
                            ],
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}
