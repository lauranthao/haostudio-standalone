import '../../core/theme/hao_radius.dart';
import 'dart:async';

// Listen report (audit P0-3 + fix 17.2).
//
// Durations are stored in SECONDS; total minutes = totalSeconds / 60.
// Ranges are CALENDAR ranges: 本周 = Monday 00:00 local to now,
// 本月 = the 1st 00:00 local to now, 全部 = everything. Top songs,
// top artists, platform split, per-day (or per-month for "all")
// bars. Statistics accumulate only from launch, so the report
// starts thin — expected.
//
// Bar labels are sparse when there are many bars: a month has up
// to 31 ~12pt columns but an "MM-dd" label needs ~22pt, so showing
// every label makes them overlap. See showBarLabel.

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../core/theme/glass.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import '../../services/music/year_review.dart';
import 'music_player_controller.dart';
import 'player_expand_route.dart';
import 'widgets/mini_player_bar.dart';
import 'widgets/song_row.dart';
import '../../widgets/hao_nav_bar.dart';

/// Empty-state text for the selected range. The empty state is
/// about the SELECTED range: "本周还没有听歌记录" when this week is
/// empty even if other ranges have plays.
@visibleForTesting
String listenReportEmptyText(String range) => range == 'week'
    ? '本周还没有听歌记录'
    : range == 'month'
        ? '本月还没有听歌记录'
        : '还没有听歌记录，统计从现在开始累计';

/// Whether bar `index` of `total` bars shows its date label.
///
/// A month has up to 31 columns of ~12pt each, but an "MM-dd" label
/// at 9pt needs ~22pt — showing every label makes them overlap (or
/// wrap into two lines). Short ranges show all labels; long ones
/// show every 5th + the last.
@visibleForTesting
bool showBarLabel(int index, int total) {
  if (total <= 10) return true;
  return index % 5 == 0 || index == total - 1;
}

class ListenReportPage extends StatefulWidget {
  const ListenReportPage({super.key});

  @override
  State<ListenReportPage> createState() => _ListenReportPageState();
}

class _ListenReportPageState extends State<ListenReportPage> {
  var _range = 'week';

  MusicPlayerController get _player => MusicPlayerController.ensure();

  ListenReport get _report {
    // The song playing right now has no persisted event yet (the
    // session is only written when it finishes), so merge the
    // in-progress snapshot in: otherwise the report shows an empty
    // state while a song is playing. The snapshot is NOT persisted,
    // so when the session later finalises the real event replaces
    // it — no double count.
    final live = _player.liveListenEvent;
    final log = MusicStore.getListenLog();
    return ListenReport.compute(
      live == null ? log : [live, ...log],
      _range,
    );
  }

  /// 年度回顾 (build 29): this year's totals + monthly bars + top
  /// songs/artists, from the same listen log. The live in-progress
  /// session merges in exactly like [_report].
  YearReview get _yearReview {
    final live = _player.liveListenEvent;
    final log = MusicStore.getListenLog();
    return YearReview.compute(
      live == null ? log : [live, ...log],
      DateTime.now().year,
    );
  }

  /// The empty state is about the SELECTED range: "本周还没有听歌记录"
  /// when this week is empty even if other ranges have plays.
  String get _emptyText => _range == 'year'
      ? '今年还没有听歌记录'
      : listenReportEmptyText(_range);

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final isYear = _range == 'year';
    final report = isYear ? null : _report;
    final yearReview = isYear ? _yearReview : null;
    // Favourites read once per build, not per top-song row:
    // getFavIds() parses the whole favourites JSON on every call.
    final favIds = MusicStore.getFavIds();
    return Scaffold(
      appBar: HaoNavBar(
        title: '听歌报告',
      ),
      body: ListView(
        padding: EdgeInsets.fromLTRB(
          16,
          16,
          16,
          16 + MiniPlayerBar.bottomClearanceFor(context),
        ),
        children: [
          Row(
            children: [
              for (final (value, label) in [
                ('week', '本周'),
                ('month', '本月'),
                ('all', '全部'),
                ('year', '年度'),
              ])
                Padding(
                  padding: const EdgeInsets.only(right: 8),
                  child: ChoiceChip(
                    label: Text(label),
                    selected: _range == value,
                    selectedColor: theme.accentSoft,
                    side: BorderSide(color: theme.hairline),
                    labelStyle: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
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
          if (isYear)
            _yearBody(theme, yearReview!, favIds)
          else if (report!.totalPlays == 0)
            Center(
              child: Padding(
                padding: const EdgeInsets.symmetric(vertical: 48),
                child: Text(
                  _emptyText,
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

  /// 年度回顾 body (build 29): year totals + 12 monthly bars + top
  /// songs / artists of the year. Empty year → the empty state.
  Widget _yearBody(HaoTheme theme, YearReview year, Set<String> favIds) {
    if (year.totalPlays == 0) {
      return Center(
        child: Padding(
          padding: const EdgeInsets.symmetric(vertical: 48),
          child: Text(
            _emptyText,
            style: TextStyle(color: theme.textMuted),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            _stat(theme, '${year.totalPlays}', '播放次数'),
            const SizedBox(width: 12),
            _stat(theme, year.totalTimeText, '总时长'),
            const SizedBox(width: 12),
            _stat(theme, '${year.daysListened}', '听歌天数'),
          ],
        ),
        const SizedBox(height: 24),
        _sectionTitle(theme, '${year.year}年 · 每月播放'),
        SizedBox(
          height: 120,
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: [
              for (var i = 0; i < 12; i++)
                Expanded(
                  child: Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 2),
                    child: Column(
                      mainAxisAlignment: MainAxisAlignment.end,
                      children: [
                        Container(
                          height: year.monthlyPlays[i] > 0
                              ? (96 *
                                      year.monthlyPlays[i] /
                                      year.monthlyPlays.fold<int>(
                                        1,
                                        (m, x) => x > m ? x : m,
                                      ))
                                  .clamp(6.0, 96.0)
                              : 2,
                          decoration: BoxDecoration(
                            color: year.monthlyPlays[i] > 0
                                ? theme.accent
                                : theme.accentSoft,
                            borderRadius:
                                BorderRadius.circular(HaoRadius.badge),
                          ),
                        ),
                        const SizedBox(height: 4),
                        SizedBox(
                          height: 12,
                          child: Text(
                            '${i + 1}月',
                            style: TextStyle(
                              color: theme.textMuted,
                              fontSize: 9,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
            ],
          ),
        ),
        const SizedBox(height: 24),
        _sectionTitle(theme, '年度常听歌曲'),
        for (var i = 0; i < year.topSongs.length; i++)
          _topSongRow(theme, year.topSongs, i, favIds),
        const SizedBox(height: 24),
        if (year.topArtists.isNotEmpty) ...[
          _sectionTitle(theme, '年度常听歌手'),
          for (var i = 0; i < year.topArtists.length; i++)
            _rankRow(
              theme,
              i,
              year.topArtists[i].artist,
              '${year.topArtists[i].plays}次',
            ),
        ],
      ],
    );
  }

  Widget _stat(HaoTheme theme, String value, String label) {
    return Expanded(
      child: GlassCard(
        radius: 24,
        quality: GlassCardQuality.standard,
        padding: const EdgeInsets.symmetric(vertical: 20),
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
          for (var i = 0; i < report.perDay.length; i++)
            Expanded(
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 2),
                child: Column(
                  mainAxisAlignment: MainAxisAlignment.end,
                  children: [
                    Container(
                      height: report.perDay[i].plays > 0
                          ? (96 * report.perDay[i].plays / maxPlays)
                              .clamp(6.0, 96.0)
                          : 2,
                      decoration: BoxDecoration(
                        color: report.perDay[i].plays > 0
                            ? theme.accent
                            : theme.accentSoft,
                        borderRadius: BorderRadius.circular(HaoRadius.badge),
                      ),
                    ),
                    const SizedBox(height: 4),
                    // Every column keeps a fixed-height label slot
                    // so the bars stay on one baseline; hidden
                    // labels just leave the slot empty.
                    SizedBox(
                      height: 12,
                      child: showBarLabel(i, report.perDay.length)
                          ? Text(
                              report.perDay[i].label,
                              style: TextStyle(
                                color: theme.textMuted,
                                fontSize: 9,
                              ),
                            )
                          : null,
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
              unawaited(openPlayerPage<void>(context));
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
                borderRadius: BorderRadius.circular(HaoRadius.badge),
              ),
              child: FractionallySizedBox(
                alignment: Alignment.centerLeft,
                widthFactor: (p.plays / maxPf).clamp(0.05, 1.0),
                child: Container(
                  decoration: BoxDecoration(
                    color: theme.accent,
                    borderRadius: BorderRadius.circular(HaoRadius.badge),
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
