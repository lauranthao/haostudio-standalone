// NetEase charts (Beans Discover charts: 飙升/新歌/原创/热歌 + the rest).
//
// A chart IS a NetEase playlist id — tap opens PlazaDetailPage, which
// loads the tracks via MusicApi.importPlaylist. No new detail page, no
// new track-loading path. List rows follow the plaza row style (cover +
// name + subtitle + chevron); the subtitle is the chart's update
// frequency + track count, the only honest per-chart metadata the
// toplist API returns.

import '../../core/theme/hao_radius.dart';
import 'package:flutter/cupertino.dart';
import '../../widgets/hao_pressable.dart';
import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../widgets/settings_ui.dart';
import '../../core/theme/haptics.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import '../../services/music/search_platform_store.dart';
import 'music_navigation.dart';
import 'plaza_page.dart';
import 'song_search_page.dart';
import 'widgets/mini_player_bar.dart';
import 'widgets/music_image.dart';

class ChartsPage extends StatefulWidget {
  const ChartsPage({super.key, this.api});

  /// Test seam: a fake-Dio api. Defaults to a real [MusicApi].
  final MusicApi? api;

  @override
  State<ChartsPage> createState() => _ChartsPageState();
}

class _ChartsPageState extends State<ChartsPage> {
  late final _api = widget.api ?? MusicApi();
  List<PlaylistSummary>? _charts;
  var _failed = false;

  /// Stage 2 capsule: charts are NetEase toplist ids — there is no
  /// QQ/Kugou/Kuwo chart source in this app, so when the capsule
  /// platform is not NetEase the page says so honestly instead of
  /// showing NetEase charts under another platform's name.
  late final MusicPlatform _platform = SearchPlatformStore.current();

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    if (_platform != MusicPlatform.wy) {
      if (!mounted) return;
      setState(() {
        _charts = [];
        _failed = false;
      });
      return;
    }
    final charts = await _api.neteaseCharts();
    if (!mounted) return;
    setState(() {
      _charts = charts;
      _failed = charts.isEmpty;
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      appBar: AppBar(title: Text('排行榜', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))), flexibleSpace: const HaoAppBarGlass()),
      body: _charts == null
          ? const Center(child: CupertinoActivityIndicator())
          : _platform != MusicPlatform.wy
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(shadows: HaoTheme.legibilityShadows(context), Icons.bar_chart, size: 48, color: theme.textMuted),
                  const SizedBox(height: 12),
                  Text(
                    '当前平台是${_platform.displayName}',
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: theme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '排行榜仅网易云音乐提供',
                    style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      Navigator.of(context).push(
                        CupertinoPageRoute<void>(
                          settings: const RouteSettings(
                            name: musicSubPageRouteName,
                          ),
                          builder: (_) => const SongSearchPage(),
                        ),
                      );
                    },
                    child: const Text('去搜索页切换平台'),
                  ),
                ],
              ),
            )
          : _failed
          ? Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  Icon(shadows: HaoTheme.legibilityShadows(context), Icons.bar_chart, size: 48, color: theme.textMuted),
                  const SizedBox(height: 12),
                  Text(
                    '排行榜加载失败',
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: theme.textPrimary,
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 4),
                  Text(
                    '检查网络后重试',
                    style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textMuted, fontSize: 13),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: () {
                      setState(() => _charts = null);
                      _load();
                    },
                    child: const Text('重试'),
                  ),
                ],
              ),
            )
          : ListView.builder(
              padding: EdgeInsets.fromLTRB(
                16,
                8,
                16,
                8 + MiniPlayerBar.bottomClearanceFor(context),
              ),
              itemCount: _charts!.length,
              itemBuilder: (context, i) {
                final c = _charts![i];
                final sub = [
                  if (c.desc.isNotEmpty) c.desc,
                  if (c.trackCount > 0) '${c.trackCount}首',
                ].join(' · ');
                return HaoGlassCard(
                  padding: const EdgeInsets.all(14),
                  margin: const EdgeInsets.only(bottom: 8),
                  child: HaoPressable(
                    onTap: () {
                      HaoHaptics.tap();
                      Navigator.of(context).push(
                        CupertinoPageRoute<void>(
                          settings: const RouteSettings(
                            name: musicSubPageRouteName,
                          ),
                          // isChart: the detail page writes this
                          // chart's first song cover to the charts
                          // feature-cover cache on load, so the home's
                          // 排行榜 card stays fresh (see
                          // PlazaDetailPage). The fake-Dio api is
                          // passed through for tests.
                          builder: (_) => PlazaDetailPage(
                            playlist: c,
                            api: widget.api,
                            isChart: true,
                          ),
                        ),
                      );
                    },
                    borderRadius: BorderRadius.circular(HaoRadius.sheet),
                    child: Padding(
                      padding: EdgeInsets.zero,
                      child: Row(
                        children: [
                          ClipRRect(
                            borderRadius: BorderRadius.circular(HaoRadius.large),
                            child: c.cover.isEmpty
                                ? Container(
                                    width: 52,
                                    height: 52,
                                    color: theme.accentSoft,
                                    child: Icon(
                                      shadows: HaoTheme.legibilityShadows(context),
                                      Icons.leaderboard,
                                      color: theme.textMuted,
                                    ),
                                  )
                                : Image(
                                    image: MusicImageProvider(c.cover),
                                    width: 52,
                                    height: 52,
                                    fit: BoxFit.cover,
                                    errorBuilder: (_, _, _) => Container(
                                      width: 52,
                                      height: 52,
                                      color: theme.accentSoft,
                                      child: Icon(
                                        shadows: HaoTheme.legibilityShadows(context),
                                        Icons.leaderboard,
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
                                  c.name,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    shadows: HaoTheme.legibilityShadows(context),
                                    color: theme.textPrimary,
                                    fontSize: 16,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                                if (sub.isNotEmpty)
                                  Text(
                                    sub,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      shadows: HaoTheme.legibilityShadows(context),
                                      color: theme.textSecondary,
                                      fontSize: 13,
                                    ),
                                  ),
                              ],
                            ),
                          ),
                          Icon(shadows: HaoTheme.legibilityShadows(context), Icons.chevron_right, color: theme.textMuted),
                        ],
                      ),
                    ),
                  ),
                );
              },
            ),
    );
  }
}
