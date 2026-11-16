import 'dart:async';

// Daily picks (app.js:3308-3346) — date header + 播放全部.
//
// ~20 songs: half most-played + half discovery via top artists; same-day
// stable (date-seeded shuffle, cached per day). Cold-start hint when
// there is no listen history at all.

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/music/daily_service.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import 'artist_detail_page.dart';
import 'music_player_controller.dart';
import 'music_player_sheet.dart';
import 'widgets/song_row.dart';

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

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final r = await _service.buildDaily();
    if (!mounted) return;
    setState(() {
      _tracks = r.tracks;
      _cold = r.cold;
      _loading = false;
    });
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
    unawaited(_player.playQueue(tracks, 0, label: '每日推荐'));
    unawaited(
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const MusicPlayerPage()),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final now = DateTime.now();
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(title: const Text('每日推荐')),
      body: _loading
          ? const Center(child: CircularProgressIndicator())
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
                        style: TextStyle(color: theme.textSecondary),
                      ),
                    ),
                    Padding(
                      padding: const EdgeInsets.symmetric(horizontal: 16),
                      child: ElevatedButton.icon(
                        onPressed: _playAll,
                        icon: const Icon(Icons.play_arrow),
                        label: const Text('播放全部'),
                        style: ElevatedButton.styleFrom(
                          backgroundColor: theme.accent,
                          foregroundColor: Colors.white,
                        ),
                      ),
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
                        itemCount: _tracks!.length,
                        itemBuilder: (ctx, i) {
                          final song = _tracks![i];
                          final favIds = MusicStore.getFavIds();
                          return Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: [
                              SongRow(
                                song: song,
                                isFav: favIds.contains(song.identityKey),
                                onPlay: () {
                                  unawaited(
                                    _player.playQueue(_tracks!, i),
                                  );
                                  unawaited(
                                    Navigator.of(context).push(
                                      MaterialPageRoute<void>(
                                        builder: (_) =>
                                            const MusicPlayerPage(),
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
