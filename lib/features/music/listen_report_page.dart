import 'dart:async';

// Listen report (audit P0-3 + fix 17.2).
//
// Durations are stored in SECONDS; total minutes = totalSeconds / 60.
// Ranges week (7 d) / month (30 d) / all; top songs, top artists,
// platform split, per-day (or per-month for "all") bars. Statistics
// accumulate only from launch, so the report starts thin — expected.

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import 'music_player_controller.dart';
import 'music_player_sheet.dart';
import 'widgets/song_row.dart';

class ListenReportPage extends StatefulWidget {
  const ListenReportPage({super.key});

  @override
  State<ListenReportPage> createState() => _ListenReportPageState();
}

class _ListenReportPageState extends State<ListenReportPage> {
  var _range = 'week';

  MusicPlayerController get _player => MusicPlayerController.ensure();

  ListenReport get _report =>
      ListenReport.compute(MusicStore.getListenLog(), _range);

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final report = _report;
    // Favourites read once per build, not per top-song row:
    // getFavIds() parses the whole favourites JSON on every call.
    final favIds = MusicStore.getFavIds();
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(title: const Text('听歌报告')),
      body: ListView(
        padding: const EdgeInsets.all(16),
        children: [
          Row(
            children: [
              for (final (value, label) in [
                ('week', '本周'),
                ('month', '本月'),
                ('all', '全部'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _range == value,
                    selectedColor: theme.accentSoft,
                    side: BorderSide(color: theme.hairline),
                    labelStyle: TextStyle(
                      color: _range == value
                          ? theme.accent
                          : theme.textSecondary,
                      fontWeight: _range == value
                          ? FontWeight.w700
                          : FontWeight.w400,
                    ),
                    onSelected: (_) => setState(() => _range = value),
                  ),
                ),
            ],
          ),
          const SizedBox(height: 16),
          if (report.totalPlays == 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Text(
                  '还没有听歌记录，统计从现在开始累计',
                  style: TextStyle(color: theme.textMuted),
                ),
              ),
            )
          else ...[
            Row(
              children: [
                _stat(theme, '${report.totalPlays}', '播放次数'),
                const SizedBox(width: 12),
                _stat(theme, report.totalTimeText, '总时长'),
              ],
            ),
            const SizedBox(height: 24),
            _sectionTitle(theme, _range == 'all' ? '每月播放' : '每日播放'),
            _bars(theme, report),
            const SizedBox(height: 24),
            _sectionTitle(theme, '常听歌曲'),
            for (var i = 0; i < report.topSongs.length; i++)
              _topSongRow(theme, report.topSongs, i, favIds),
            const SizedBox(height: 24),
            if (report.topArtists.isNotEmpty) ...[
              _sectionTitle(theme, '常听歌手'),
              for (var i = 0; i < report.topArtists.length; i++)
                _rankRow(
                  theme,
                  i,
                  report.topArtists[i].artist,
                  '${report.topArtists[i].plays}次',
                ),
            ],
            const SizedBox(height: 24),
            if (report.topPlatforms.isNotEmpty) ...[
              _sectionTitle(theme, '平台分布'),
              for (final p in report.topPlatforms)
                _platformRow(theme, p, report),
            ],
          ],
        ],
      ),
    );
  }

  Widget _stat(HaoTheme theme, String value, String label) {
    return Expanded(
      child: Container(
        padding: const EdgeInsets.symmetric(vertical: 20),
        decoration: BoxDecoration(
          color: theme.surface,
          borderRadius: BorderRadius.circular(20),
          border: Border.all(color: theme.hairline),
        ),
        child: Column(
          children: [
            Text(
              value,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 26,
                fontWeight: FontWeight.w800,
              ),
            ),
            Text(label, style: TextStyle(color: theme.textSecondary, fontSize: 13)),
          ],
        ),
      ),
    );
  }

  Widget _sectionTitle(HaoTheme theme, String title) {
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Text(
        title,
        style: TextStyle(
          color: theme.textPrimary,
          fontSize: 18,
          fontWeight: FontWeight.w800,
        ),
      ),
    );
  }

  Widget _bars(HaoTheme theme, ListenReport report) {
    final maxPlays = report.perDay.fold<int>(
      1,
      (m, d) => d.plays > m ? d.plays : m,
    );
    return SizedBox(
      height: 120,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: [
          for (final d in report.perDay)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: d.plays > 0
                          ? (96 * d.plays / maxPlays)
                              .clamp(6.0, 96.0)
                          : 2,
                      decoration: BoxDecoration(
                        color: d.plays > 0 ? theme.accent : theme.accentSoft,
                        borderRadius: BorderRadius.circular(4),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      d.label,
                      style: TextStyle(
                        color: theme.textMuted,
                        fontSize: 9,
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }

  Widget _topSongRow(
    HaoTheme theme,
    List<TopSong> topSongs,
    int index,
    Set<String> favIds,
  ) {
    final top = topSongs[index];
    return Row(
      children: [
        SizedBox(
          width: 28,
          child: Text(
            '${index + 1}',
            style: TextStyle(
              color: theme.textMuted,
              fontSize: 14,
              fontWeight: FontWeight.w700,
            ),
          ),
        ),
        Expanded(
          child: SongRow(
            song: top.song,
            isFav: favIds.contains(top.song.identityKey),
            onPlay: () {
              // Use the already-computed list: calling _report here
              // re-ran the whole listen-log parse + aggregation on
              // every tap just to rebuild the same queue.
              final songs = topSongs.map((t) => t.song).toList();
              unawaited(_player.playQueue(songs, index));
              unawaited(
                Navigator.of(context).push(
                  MaterialPageRoute<void>(
                    builder: (_) => const MusicPlayerPage(),
                  ),
                ),
              );
            },
            onToggleFav: () async {
              await _player.toggleFav(top.song);
              setState(() {});
            },
          ),
        ),
        Text(
          '${top.plays}次',
          style: TextStyle(color: theme.textSecondary, fontSize: 13),
        ),
      ],
    );
  }

  Widget _rankRow(HaoTheme theme, int index, String title, String sub) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 28,
            child: Text(
              '${index + 1}',
              style: TextStyle(
                color: theme.textMuted,
                fontSize: 14,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
          Expanded(
            child: Text(
              title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(color: theme.textPrimary, fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          Text(sub, style: TextStyle(color: theme.textSecondary)),
        ],
      ),
    );
  }

  Widget _platformRow(
    HaoTheme theme,
    TopPlatform p,
    ListenReport report,
  ) {
    final maxPf = report.topPlatforms.fold<int>(
      1,
      (m, x) => x.plays > m ? x.plays : m,
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 6),
      child: Row(
        children: [
          SizedBox(
            width: 64,
            child: Text(
              MusicPlatformX.fromCode(p.platform).displayName,
              style: TextStyle(color: theme.textPrimary, fontSize: 15, fontWeight: FontWeight.w500),
            ),
          ),
          Expanded(
            child: Container(
              height: 8,
              decoration: BoxDecoration(
                color: theme.accentSoft,
                borderRadius: BorderRadius.circular(4),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: (p.plays / maxPf).clamp(0.05, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.accent,
                    borderRadius: BorderRadius.circular(4),
                  ),
                ),
              ),
            ),
          ),
          const SizedBox(width: 8),
          Text('${p.plays}', style: TextStyle(color: theme.textSecondary)),
        ],
      ),
    );
  }
}
