import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:hive_ce_flutter/hive_ce_flutter.dart';
// Music home — Kumone redo (P0+P1, 2026-11-18).
//
// Values are borrowed from Kumone (~/workspace/research/kumone,
// LGPL-3.0 — design values and behaviour only, no code copied into
// this closed-source app). Sources per item:
// - P0-1 feature shelf: HomeView.swift:238-276 (shelf spacing 16,
//   vertical padding 6), FeatureCard :400-457 (230x132, radius 12,
//   white 0.12 stroke 0.5pt, padding 14, icon 22, title 15 bold
//   (subtitle removed 2026-11-19 clean pass), text shadow black 0.4
//   r2 y1, cover + black 0.1->0.68 gradient). C1/C2 (REVISED 2026-11-18 — chen: the
//   all-black cards are ugly): NO theme-accent gradient — the accent
//   is black after the blue->black rule, so all five cards read black.
//   Each card gets its own Kumone gradient (topLeading->
//   bottomTrailing + white 0.18 radial highlight, same shape as
//   Kumone's FeatureCard): 搜歌 = Theme.swift:9-10 accentGradient
//   #F85B5B->#C92929; 每日推荐 fallback = HomeView.swift:401-402
//   FeatureCard default #BF2938->#F25947 (cover path unchanged);
//   歌单广场 = HomeView.swift:268-269 心动模式 #D93069->#FA6B57;
//   排行榜 = HomeView.swift:262-263 私人漫游 indigo, SHIFTED blue
//   (#29336B->#5C3D9E is purple — banned — so red lowered and blue
//   raised: #1A408C->#2959D9, hue ~220deg, reads deep blue);
//   听歌报告 = derived from :268-269 pink-orange, hue shifted
//   rose->amber: #D96114->#FA9433. No two cards share a gradient,
//   none is black or grey. Cards are coloured artwork like Kumone's
//   and do not change with the app theme (white text + shadow stay
//   readable in light and dark); the blue->black rule still applies
//   everywhere else.
// - P0-2: sections default EXPANDED (Kumone home never collapses);
//   head 22 semibold, no leading chevron (Components.swift:100-130
//   SectionHeader, title2 22 semibold); section spacing 20 and
//   head-to-content 10 (Theme.swift:63-64 iOS).
// - P0-3: library rows (IOSMainWindow.swift:736-775): 32x32 cover
//   radius 6 (Theme.Radius.small), spacing 10, name 14, count caption
//   12 secondary, text spacing 1; rows are plain inside ONE shared
//   glass container (radius 20 = Theme.Radius.panel), separated by
//   hairline dividers — no per-row radius-24 card, no 52 grey tile.
//   list.cover is already the first-track cover
//   (music_models.dart:458); a truly coverless list gets a neutral
//   accent gradient tile + note, not a grey block.
// - P0-4: no AppBar (the tab bar already says 音乐). The greeting/
//   date header was removed 2026-11-19 (clean pass); the feature
//   shelf is the page's visual anchor now.
// - P1-5: page inset 24 (Theme.Layout.contentInset), shelf spacing 16.
// - P1-6: mini player capsule (IOSMainWindow.swift:472-620
//   IOSMiniPlayerBar legacyOverlay): capsule shape, cover 32 radius 6
//   + shadow black 0.15 r4 y1, title 13 semibold, subtitle 10, text
//   spacing 3, buttons 44x44 (prev/next icon 14 semibold secondary,
//   play 15 bold primary), padding L12 R6 V4, shadow black 0.12 r10
//   y4, stroke primary 0.08 0.5pt (mapped to theme.hairline), 8pt gap
//   to the tab bar. Buttons are mode / prev / play / next — the mode
//   button is our existing feature and is NOT deleted (chen rule);
//   4x44 fits 390pt (verified by test, see
//   test/music_home_kumone_test.dart).
// - P1-7: radii only at call sites (feature card 12, container 20,
//   covers 6, SongRow compact cover 6): GlassCard's global default
//   and HaoGlassCard are untouched.
// - P1-9: import box slimmed in place (option a): field radius 12,
//   height ~40, capsule button (12.5 semibold, H14 V7, accent fill +
//   onPrimary text — the Kumone 「播放全部」 capsule shape, C4 fill
//   swapped from Kumone red gradient to theme accent), the 12pt note
//   below is merged into the hint. Position unchanged (inside 我的歌单).
// - P1-10: 最近播放 head gains a 「播放全部」 capsule (same shape as
//   the import button; no segmented picker — that is a new feature);
//   rows are SongRow compact (TrackList.swift:39-40,93-165): 64 high,
//   cover 48 radius 6, title callout 16 medium (iPhone is compact
//   width), artist footnote 13, duration 11, 1pt dividers, spacing 1.
// - P1-11: staggered entrance (Components.swift:71-92, Theme.swift
//   AppAnimation.snappy 0.25/0.8, stagger 0.04/index capped 0.4,
//   once per id, 600-item cache). Flutter has no spring-response
//   curve constant: the 250 ms settle is mapped to easeOutCubic
//   (same duration, no overshoot); delay cap, +16 offset and the
//   once-only cache are copied exactly. See [_StaggerIn].
// - P1-12: empty states are HaoEmptyState (Cards.swift:180-198
//   EmptyStateView: icon 40 tertiary, headline title, subheadline
//   subtitle, spacing 12); full-page recents empty state minHeight 300
//   (LibraryPages.swift:52-55).
//
// Order, top to bottom: feature shelf (search / daily /
// plaza / charts / listen report), then 我的歌单, then 私人漫游 /
// 心动模式 (two cards side by side), then 最近播放. Both
// sections start EXPANDED; collapse is kept (tap the head) but the
// default is open. Collapse state is per-section and persisted in
// Hive (musicPlaylistsExpanded / musicRecentExpanded): the bottom tab
// is a PageView with no AutomaticKeepAlive, so switching 2 tabs away
// disposes this State — without persistence the sections reopened by
// themselves (reported 2026-11-19).
//
// Playlist card count = tracks.length (audit P0-1) — never a stored
// count field. The import box lives inside the 我的歌单 section.

import 'package:flutter/material.dart';
import 'package:get/get.dart';

import '../../core/storage/hive_store.dart';
import '../../core/theme/appearance_store.dart';
import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../widgets/glass_dialog.dart';
import '../../core/theme/haptics.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import '../../services/music/music_store.dart';
import '../../services/music/search_platform_store.dart';
import '../../services/music/local_music_store.dart';
import 'artist_detail_page.dart';
import 'charts_page.dart';
import 'daily_page.dart';
import 'downloads_page.dart';
import 'favourites_page.dart';
import 'fm_service.dart';
import 'listen_report_page.dart';
import 'local_music_page.dart';
import 'music_navigation.dart';
import 'music_player_controller.dart';
import 'player_expand_route.dart';
import 'plaza_page.dart';
import 'playlist_detail_page.dart';
import 'song_search_page.dart';
import 'widgets/collapsible_section.dart';
import 'widgets/empty_state.dart';
import 'widgets/mini_player_bar.dart';
import 'widgets/song_row.dart';
import 'widgets/track_more_sheet.dart';
import 'widgets/music_image.dart';

class MusicTabPage extends StatefulWidget {
  const MusicTabPage({super.key, this.api});

  /// Test seam only: an injected [MusicApi] (fake Dio in render /
  /// widget tests). Null in production — the page owns a fresh one.
  /// The seam also keeps the lazy first-cover fetch offline in
  /// tests (a real api would hit the network from the test VM).
  final MusicApi? api;

  @override
  State<MusicTabPage> createState() => _MusicTabPageState();
}

/// One feature-shelf card: icon, title, destination, its own
/// Kumone gradient (see the file header — one distinct gradient per
/// card, never black/grey), and an optional real cover — when set,
/// the cover replaces the gradient, with the black scrim (top 0.1 ->
/// bottom 0.68) keeping the white title readable. 搜歌 has no cover;
/// the other four shelf cards show their first item's cover
/// (daily / plaza / charts / report — see [_featureShelf]).
/// No subtitle (removed 2026-11-19 clean pass — title sits at the
/// bottom of the card, 15 bold, unchanged).
///
/// [glass] (FM / heartbeat only, 2026-11-19 — chen approved the
/// preview): the card renders as real liquid glass instead of the
/// solid gradient — GlassCard standard + a tint wash built from the
/// tile's own gradient colour (see [_FeatureCard] for the values).
/// The four shelf cards keep [glass] false and their gradients.
class _FeatureTile {
  const _FeatureTile({
    required this.icon,
    required this.title,
    required this.gradient,
    required this.onTap,
    this.showsDate = false,
    this.cover,
    this.glass = false,
    this.glassTint,
    this.glassTintDark,
  }) : assert(
         !glass || glassTint != null,
         'a glass tile needs its tint wash base colour',
       );

  final IconData icon;
  final String title;

  /// Two-stop gradient, topLeading -> bottomTrailing (Kumone
  /// FeatureCard, HomeView.swift:415).
  final List<Color> gradient;
  final VoidCallback onTap;
  final bool showsDate;
  final String? cover;

  /// Glass switch (default false — the shelf cards stay gradient).
  final bool glass;

  /// Tint-wash base colour for the glass card: light mode. Always
  /// the tile's own gradient bright end (FM #1D4ED8, heartbeat
  /// #F43F5E — preview ~/workspace/preview/fm-glass-preview.html).
  final Color? glassTint;

  /// Tint-wash base colour for the glass card: dark mode. Null =
  /// same as [glassTint]. FM needs a lighter blue here (#3B82F6 —
  /// preview) so the wash stays visible on the dark background;
  /// heartbeat reuses #F43F5E.
  final Color? glassTintDark;
}

class _MusicTabPageState extends State<MusicTabPage> {
  final _importController = TextEditingController();
  late final MusicApi _api = widget.api ?? MusicApi();
  var _playlistsExpanded = true;
  var _recentExpanded = true;
  List<UserPlaylist> _lists = [];
  List<Song> _recent = [];
  var _importing = false;

  /// Live listenable for the recent-plays key (bug3, chen 2026-11-20:
  /// “下面的最近播放也不会实时变化”). _recent used to be read only
  /// in _refresh() (initState + _push() return), so a song that
  /// started playing while this tab stayed alive never appeared
  /// until the user left and came back. Subscribing here re-reads
  /// the key on every write (play start / track change / auto-next
  /// all go through MusicStore.addRecent in _loadCurrent).
  /// Same pattern as LiveRoomPage's danmaku-settings listenable
  /// (HiveStore.box.listenable, key-scoped, removeListener in
  /// dispose) — hive_ce's listenable is fed by box.watch() under the
  /// hood, so no StreamSubscription lifecycle to manage, and only
  /// hao_recent writes rebuild this page.
  ValueListenable<Box<dynamic>>? _recentListenable;

  /// Local-file count future (stage 2): cached per refresh, not
  /// rebuilt on every build — LocalMusicStore.list() prunes missing
  /// files, so calling it from build would rewrite Hive on each frame.
  late Future<List<Song>> _localFuture;

  MusicPlayerController get _player => MusicPlayerController.ensure();

  @override
  void initState() {
    super.initState();
    _playlistsExpanded =
        HiveStore.getBool(HiveKeys.musicPlaylistsExpanded, true);
    _recentExpanded = HiveStore.getBool(HiveKeys.musicRecentExpanded, true);
    _refresh();
    _subscribeRecent();
    // Lazy first-cover fill (plaza / charts): after the first frame,
    // so the home renders its gradients first and swaps a cover in
    // when it arrives. The fetch runs once per home lifetime and
    // only for the cards whose cached URL is missing.
    WidgetsBinding.instance.addPostFrameCallback(
      (_) => _fetchMissingCovers(),
    );
  }

  void _togglePlaylists() {
    final next = !_playlistsExpanded;
    setState(() => _playlistsExpanded = next);
    unawaited(HiveStore.put(HiveKeys.musicPlaylistsExpanded, next));
  }

  void _toggleRecent() {
    final next = !_recentExpanded;
    setState(() => _recentExpanded = next);
    unawaited(HiveStore.put(HiveKeys.musicRecentExpanded, next));
  }

  /// Subscribe to hao_recent writes (see [_recentListenable]).
  /// Guarded like LiveRoomPage: when Hive is not initialised there
  /// is simply no live update and the _refresh() snapshot applies.
  void _subscribeRecent() {
    try {
      final listenable = HiveStore.box.listenable(
        keys: [HiveKeys.musicRecent],
      );
      _recentListenable = listenable;
      listenable.addListener(_onRecentChanged);
    } catch (_) {
      // Hive unavailable — no live updates, snapshot only.
    }
  }

  /// A recent-plays write landed: re-read ONLY _recent. NOT _refresh():
  /// that also re-lists local files and re-reads the playlists, which
  /// playback never changes — re-running it on every song start would
  /// churn the local-files FutureBuilder for nothing.
  void _onRecentChanged() {
    if (!mounted) return;
    setState(() {
      _recent = MusicStore.getRecent();
    });
  }

  @override
  void dispose() {
    _recentListenable?.removeListener(_onRecentChanged);
    _importController.dispose();
    super.dispose();
  }

  void _refresh() {
    _localFuture = LocalMusicStore().list();
    setState(() {
      _lists = MusicStore.getLists();
      _recent = MusicStore.getRecent();
    });
  }

  Future<void> _push(Widget page) async {
    await pushMusicSubPage<void>(context, page);
    _refresh();
  }

  Future<void> _createList() async {
    final nameController = TextEditingController();
    final name = await showGlassDialog<String>(
      context,
      builder: (ctx) {
        final theme = HaoTheme.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '新歌单的名字',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: nameController,
              autofocus: true,
              decoration: const InputDecoration(),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: Text(
                    '取消',
                    style: TextStyle(color: theme.textSecondary),
                  ),
                ),
                TextButton(
                  onPressed: () =>
                      Navigator.of(ctx).pop(nameController.text.trim()),
                  child: Text('新建歌单', style: TextStyle(color: theme.accent)),
                ),
              ],
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
      ScaffoldMessenger.of(context)
          .showSnackBar(const SnackBar(content: Text('歌单已满（最多 10 个）')));
      return;
    }
    final id = 'l${DateTime.now().millisecondsSinceEpoch}';
    lists.add(UserPlaylist(id: id, name: name));
    await MusicStore.saveLists(lists);
    await MusicStore.setCurrentListId(id);
    _refresh();
    if (!mounted) return;
    ScaffoldMessenger.of(context)
        .showSnackBar(const SnackBar(content: Text('歌单已创建')));
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
      final res = MusicStore.addTracks(list, r.tracks);
      await MusicStore.saveLists(lists);
      await MusicStore.setCurrentListId(list.id);
      _importController.clear();
      _refresh();
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
    } finally {
      if (mounted) setState(() => _importing = false);
    }
  }

  void _playSong(Song song, List<Song> queue) {
    final idx = queue.indexWhere((s) => s.identityKey == song.identityKey);
    unawaited(_player.playQueue(queue, idx < 0 ? 0 : idx));
    _openPlayer();
  }

  void _playAllRecent() {
    if (_recent.isEmpty) return;
    _playSong(_recent.first, _recent);
  }

  void _openPlayer() {
    unawaited(openPlayerPage<void>(context));
  }

  /// Open the player from the embedded mini player bar: the page
  /// EXPANDS from the bar's rect (NetEase). Song-row / FM / heartbeat
  /// taps keep using [_openPlayer] (plain slide) — there is no bar
  /// to expand from there.
  void _openPlayerFromBar(Rect? barRect) {
    unawaited(openPlayerPage<void>(context, fromRect: barRect));
  }

  /// Start personal FM, then open the full player. When there are no
  /// local seeds at all the service returns false and a real prompt
  /// is shown instead of failing silently.
  Future<void> _startFM() async {
    final started = await FmService.ensure().startFM();
    if (!mounted) return;
    if (!started) {
      await _showFmEmptyPrompt(
        title: '私人漫游',
        body: '还没有收藏和最近播放的歌曲。先收藏几首喜欢的歌，或者听几首歌，私人漫游会从这些歌出发，为你找相似的歌。',
      );
      return;
    }
    _openPlayer();
  }

  /// Start heartbeat mode, then open the full player. With no liked
  /// songs the service returns false and a real prompt is shown.
  Future<void> _startHeartbeat() async {
    final started = await FmService.ensure().startHeartbeat();
    if (!mounted) return;
    if (!started) {
      await _showFmEmptyPrompt(
        title: '心动模式',
        body: '还没有收藏的歌曲。先去收藏几首喜欢的歌，心动模式会以其中一首为种子，为你找相似的歌。',
      );
      return;
    }
    _openPlayer();
  }

  Future<void> _showFmEmptyPrompt({
    required String title,
    required String body,
  }) async {
    await showGlassDialog<void>(
      context,
      builder: (ctx) {
        final theme = HaoTheme.of(ctx);
        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              title,
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              body,
              style: TextStyle(color: theme.textSecondary, fontSize: 14),
            ),
            const SizedBox(height: 16),
            Row(
              mainAxisAlignment: MainAxisAlignment.end,
              children: [
                TextButton(
                  onPressed: () => Navigator.of(ctx).pop(),
                  child: const Text('知道了'),
                ),
              ],
            ),
          ],
        );
      },
    );
  }

  /// Daily first cover for the 每日推荐 feature card: sync read of the
  /// cached daily list only. If the user has never opened Daily today
  /// there is no cached list and the card falls back to the theme
  /// gradient — the home page must not build the daily list itself
  /// (buildDaily does network search on a cold start).
  String? _dailyFirstCover() {
    final cached = MusicStore.getDaily(dayKeyOf(DateTime.now()));
    if (cached == null || cached.isEmpty) return null;
    final cover = cached.first.cover;
    return cover.isEmpty ? null : cover;
  }

  /// Plaza first cover for the 歌单广场 card: sync read of the
  /// cached URL only (see [_fetchMissingCovers] for the fill).
  String? _plazaFirstCover() =>
      MusicStore.getFeatureCover(HiveKeys.featureCoverPlaza);

  /// Charts first cover for the 排行榜 card: sync read of the
  /// cached URL only (see [_fetchMissingCovers] for the fill).
  String? _chartsFirstCover() =>
      MusicStore.getFeatureCover(HiveKeys.featureCoverCharts);

  /// Report first cover for the 听歌报告 card: computed live from
  /// the local listen log on every build — same range ('week') and
  /// live-event merge as ListenReportPage, so the card's #1 song
  /// always agrees with the report page. No cache, no network.
  String? _reportFirstCover() {
    final live = _player.liveListenEvent;
    final log = MusicStore.getListenLog();
    final report = ListenReport.compute(
      live == null ? log : [live, ...log],
      'week',
    );
    if (report.topSongs.isEmpty) return null;
    final cover = report.topSongs.first.song.cover;
    return cover.isEmpty ? null : cover;
  }

  /// Lazy fill for the plaza / charts first covers: one background
  /// fetch per missing card, reusing each page's own fetch
  /// (PlazaPage._load / ChartsPage._load + importPlaylist). A
  /// failed fetch leaves the gradient — never an error, never a
  /// blank card. The URL is cached, so later home opens read it
  /// synchronously and never re-fetch.
  Future<void> _fetchMissingCovers() async {
    if (!mounted) return;
    if (_plazaFirstCover() == null) {
      unawaited(_fetchPlazaCover());
    }
    if (_chartsFirstCover() == null) {
      unawaited(_fetchChartsCover());
    }
  }

  Future<void> _fetchPlazaCover() async {
    try {
      final items = await _api.plaza(SearchPlatformStore.current());
      if (!mounted) return;
      for (final item in items) {
        if (item.cover.isNotEmpty) {
          await MusicStore.setFeatureCover(
            HiveKeys.featureCoverPlaza,
            item.cover,
          );
          if (mounted) setState(() {});
          return;
        }
      }
    } catch (_) {
      // Offline / API down: keep the gradient.
    }
  }

  Future<void> _fetchChartsCover() async {
    try {
      final charts = await _api.neteaseCharts();
      if (!mounted || charts.isEmpty) return;
      final tracks = await _api.importPlaylist(
        MusicPlatform.wy,
        charts.first.id,
      );
      if (!mounted) return;
      for (final song in tracks.tracks) {
        if (song.cover.isNotEmpty) {
          await MusicStore.setFeatureCover(
            HiveKeys.featureCoverCharts,
            song.cover,
          );
          if (mounted) setState(() {});
          return;
        }
      }
    } catch (_) {
      // Offline / API down: keep the gradient.
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Obx(
      () => Scaffold(
        backgroundColor: tabScaffoldBackground(context),
        // P0-4: no AppBar — the tab bar already says 音乐; the feature
        // shelf below is the page's visual anchor.
        body: SafeArea(
          top: true,
          bottom: false,
          child: Column(
            children: [
              Expanded(
                child: ListView(
                  children: [
                    _featureShelf(theme),
                    // Gap arithmetic (Kumone sectionSpacing 20):
                    // shelf bottom padding 6 + 4 + head top padding 10.
                    // The shelf is the page's visual anchor now — the
                    // greeting/date header was removed 2026-11-19
                    // (clean pass); homeDateText itself stays, it is
                    // still used by daily_page.dart:159.
                    const SizedBox(height: 4),
                    CollapsibleSection(
                      title: '我的歌单',
                      expanded: _playlistsExpanded,
                      onToggle: _togglePlaylists,
                      showLeadingChevron: false,
                      horizontalPadding: 24,
                      verticalPadding: 10,
                      titleStyle: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                      child: _playlistsBody(theme),
                    ),
                    // Gap arithmetic: body bottom (no trailing spacer) +
                    // 10 + next head top padding 10 = sectionSpacing 20.
                    const SizedBox(height: 10),
                    _fmRow(theme),
                    // Same 10 + 10 arithmetic before the next section.
                    const SizedBox(height: 10),
                    CollapsibleSection(
                      title: '最近播放',
                      expanded: _recentExpanded,
                      onToggle: _toggleRecent,
                      showLeadingChevron: false,
                      horizontalPadding: 24,
                      verticalPadding: 10,
                      titleStyle: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 22,
                        fontWeight: FontWeight.w600,
                      ),
                      trailing: _CapsuleButton(
                        icon: Icons.play_arrow,
                        label: '播放全部',
                        enabled: _recent.isNotEmpty,
                        onTap: _playAllRecent,
                      ),
                      child: _recentBody(theme),
                    ),
                    // Kumone bottom padding: contentInset - 8 = 16.
                    const SizedBox(height: 16),
                  ],
                ),
              ),
              MiniPlayerBar(
                key: const ValueKey('homeMiniPlayer'),
                onOpenPlayer: _openPlayerFromBar,
              ),
            ],
          ),
        ),
      ),
    );
  }

  Widget _featureShelf(HaoTheme theme) {
    final tiles = <_FeatureTile>[
      // Kumone Theme.swift:9-10 accentGradient.
      _FeatureTile(
        icon: Icons.search,
        title: '搜歌',
        gradient: const [Color(0xFFF85B5B), Color(0xFFC92929)],
        onTap: () => _push(const SongSearchPage()),
      ),
      // Kumone HomeView.swift:401-402 FeatureCard default — fallback
      // when there is no cached daily cover; the cover path wins.
      _FeatureTile(
        icon: Icons.calendar_today,
        title: '每日推荐',
        gradient: const [Color(0xFFBF2938), Color(0xFFF25947)],
        showsDate: true,
        cover: _dailyFirstCover(),
        onTap: () => _push(const DailyPage()),
      ),
      // Kumone HomeView.swift:268-269 心动模式.
      // Cover: the first playlist's cover (cached, lazily filled).
      _FeatureTile(
        icon: Icons.grid_view,
        title: '歌单广场',
        gradient: const [Color(0xFFD93069), Color(0xFFFA6B57)],
        cover: _plazaFirstCover(),
        onTap: () => _push(const PlazaPage()),
      ),
      // Kumone HomeView.swift:262-263 私人漫游 indigo, shifted blue
      // (purple end banned — see the file header).
      // Cover: the #1 song of the first chart (cached, lazily
      // filled via neteaseCharts + importPlaylist).
      _FeatureTile(
        icon: Icons.leaderboard,
        title: '排行榜',
        gradient: const [Color(0xFF1A408C), Color(0xFF2959D9)],
        cover: _chartsFirstCover(),
        onTap: () => _push(const ChartsPage()),
      ),
      // Derived from HomeView.swift:268-269 pink-orange, hue shifted
      // rose -> amber (see the file header).
      // Cover: the #1 song of this week's report (computed live
      // from the local listen log — no cache, no network).
      _FeatureTile(
        icon: Icons.bar_chart,
        title: '听歌报告',
        gradient: const [Color(0xFFD96114), Color(0xFFFA9433)],
        cover: _reportFirstCover(),
        onTap: () => _push(const ListenReportPage()),
      ),
    ];
    return SingleChildScrollView(
      scrollDirection: Axis.horizontal,
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 6),
      child: Row(
        children: [
          for (var i = 0; i < tiles.length; i++) ...[
            if (i > 0) const SizedBox(width: 16),
            _StaggerIn(
              index: i,
              id: 'home-feature-$i',
              child: _FeatureCard(tile: tiles[i]),
            ),
          ],
        ],
      ),
    );
  }

  /// Personal FM + heartbeat cards, side by side between 我的歌单 and
  /// 最近播放. Same _FeatureCard rendering as the shelf (radius 12,
  /// white 0.12 stroke, icon 22 top-left, title 15 bold bottom-left,
  /// no subtitle); half width each (16 gap) at 96 high to keep the
  /// shelf's 230:132 ratio. Gradients are Kumone's: FM indigo shifted
  /// blue like the 排行榜 card (purple end banned), heartbeat red-pink.
  /// NOTE: the two gradients intentionally match the 排行榜 / 歌单广场
  /// cards (the brief says to copy Kumone's values); if that reads as
  /// duplicated, shift one of them.
  Widget _fmRow(HaoTheme theme) {
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Row(
        children: [
          Expanded(
            child: _StaggerIn(
              index: 5,
              id: 'home-fm',
              child: _FeatureCard(
                width: double.infinity,
                height: 96,
                tile: _FeatureTile(
                  icon: Icons.waves,
                  title: '私人漫游',
                  // NOTE: Kumone 私人漫游 indigo shifted blue is #1A408C->#2959D9,
                  // but 排行榜 already uses it — file rule: no two cards share a
                  // gradient. Same indigo-blue family, darker so the two read apart.
                  gradient: const [Color(0xFF0F2A5C), Color(0xFF1D4ED8)],
                  onTap: _startFM,
                  // Glass (chen-approved preview): wash base is the
                  // gradient bright end; dark mode gets the lighter
                  // #3B82F6 so the wash stays visible on dark.
                  glass: true,
                  glassTint: const Color(0xFF1D4ED8),
                  glassTintDark: const Color(0xFF3B82F6),
                ),
              ),
            ),
          ),
          const SizedBox(width: 16),
          Expanded(
            child: _StaggerIn(
              index: 6,
              id: 'home-heartbeat',
              child: _FeatureCard(
                width: double.infinity,
                height: 96,
                tile: _FeatureTile(
                  icon: Icons.favorite,
                  title: '心动模式',
                  // NOTE: Kumone 心动模式 red-pink is #D93069->#FA6B57,
                  // but 歌单广场 already uses it — file rule: no two cards share a
                  // gradient. Same red-pink family, rose end instead of orange.
                  gradient: const [Color(0xFFBE123C), Color(0xFFF43F5E)],
                  onTap: _startHeartbeat,
                  // Glass (chen-approved preview): wash base is the
                  // gradient bright end, same colour both modes.
                  glass: true,
                  glassTint: const Color(0xFFF43F5E),
                  glassTintDark: const Color(0xFFF43F5E),
                ),
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _playlistsBody(HaoTheme theme) {
    // Rows in display order, each with a stable stagger id.
    final entries = <(String, Widget)>[
      (
        'fav',
        _libraryRow(
          theme,
          icon: Icons.favorite,
          title: '我的收藏',
          subtitle: MusicStore.getFavIds().isEmpty
              ? '还没有收藏的歌曲'
              : '${MusicStore.getFavIds().length} 首歌曲',
          onTap: () => _push(const FavouritesPage()),
        ),
      ),
      (
        'dl',
        _libraryRow(
          theme,
          icon: Icons.download,
          title: '已下载',
          subtitle: _player.downloads.downloadedCount == 0
              ? '还没有下载'
              : '${_player.downloads.downloadedCount} 首歌曲',
          onTap: () => _push(const DownloadsPage()),
        ),
      ),
      ('local', _localRow(theme)),
      for (final list in _lists) ('pl-${list.id}', _playlistRow(theme, list)),
    ];
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          GlassCard(
            radius: 20,
            quality: GlassCardQuality.standard,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
            // Transparent Material so the rows' InkWells can paint
            // ripples (GlassCard itself carries no Material).
            child: Material(
              color: Colors.transparent,
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: [
                  for (var i = 0; i < entries.length; i++) ...[
                    if (i > 0) _rowDivider(theme),
                    _StaggerIn(
                      index: i,
                      id: 'home-list-${entries[i].$1}',
                      child: entries[i].$2,
                    ),
                  ],
                  if (_lists.isEmpty) ...[
                    _rowDivider(theme),
                    const Padding(
                      padding: EdgeInsets.symmetric(vertical: 16),
                      child: HaoEmptyState(
                        icon: Icons.music_note,
                        title: '还没有歌单',
                      ),
                    ),
                  ],
                ],
              ),
            ),
          ),
          // Empty state lost its subtitle line (clean pass) — give the
          // card 12 below it instead of 8 so it still breathes.
          SizedBox(height: _lists.isEmpty ? 12 : 8),
          _importRow(theme),
          const SizedBox(height: 8),
          OutlinedButton.icon(
            onPressed: _createList,
            icon: const Icon(Icons.add, size: 18),
            label: const Text('新建歌单'),
            style: OutlinedButton.styleFrom(
              foregroundColor: theme.accent,
              side: BorderSide(color: theme.hairline),
            ),
          ),
        ],
      ),
    );
  }

  /// Hairline divider between library rows. Indent 54 aligns with the
  /// text column (container padding 12 + cover 32 + gap 10); it runs
  /// to the container's right content edge.
  Widget _rowDivider(HaoTheme theme) {
    return Divider(height: 1, indent: 54, endIndent: 0, color: theme.hairline);
  }

  /// One plain library row (P0-3): 32 leading, gap 10, title 14,
  /// subtitle 12 secondary, text spacing 1, muted chevron.
  Widget _plainRow(
    HaoTheme theme, {
    required Widget leading,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return InkWell(
      onTap: () {
        HaoHaptics.tap();
        onTap();
      },
      borderRadius: BorderRadius.circular(8),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 8),
        child: Row(
          children: [
            leading,
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: [
                  Text(
                    title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: theme.textPrimary, fontSize: 14),
                  ),
                  const SizedBox(height: 1),
                  Text(
                    subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(color: theme.textSecondary, fontSize: 12),
                  ),
                ],
              ),
            ),
            Icon(Icons.chevron_right, color: theme.textMuted),
          ],
        ),
      ),
    );
  }

  /// 32x32 accent-soft icon tile (radius 6) for the entries that have
  /// no cover: 我的收藏 / 已下载 / 本地文件.
  Widget _iconTile(HaoTheme theme, IconData icon) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        color: theme.accentSoft,
        borderRadius: BorderRadius.circular(6),
      ),
      child: Icon(icon, size: 20, color: theme.accent),
    );
  }

  Widget _libraryRow(
    HaoTheme theme, {
    required IconData icon,
    required String title,
    required String subtitle,
    required VoidCallback onTap,
  }) {
    return _plainRow(
      theme,
      leading: _iconTile(theme, icon),
      title: title,
      subtitle: subtitle,
      onTap: onTap,
    );
  }

  /// Local files row (stage 2): same shape as the other entries. The
  /// count is read from Hive on every build — no cached number that
  /// can go stale after an import/delete on the LocalMusicPage.
  Widget _localRow(HaoTheme theme) {
    return FutureBuilder<List<Song>>(
      future: _localFuture,
      builder: (ctx, snap) {
        final count = snap.data?.length ?? 0;
        return _plainRow(
          theme,
          leading: _iconTile(theme, Icons.audio_file),
          title: '本地文件',
          subtitle: count == 0 ? '导入手机里的音频文件' : '$count 首歌曲',
          onTap: () => _push(const LocalMusicPage()),
        );
      },
    );
  }

  Widget _playlistRow(HaoTheme theme, UserPlaylist list) {
    return _plainRow(
      theme,
      leading: _playlistCover(theme, list),
      title: list.name,
      // Audit P0-1: count is tracks.length, recomputed here.
      subtitle: '${list.trackCount} 首歌曲',
      onTap: () => _push(PlaylistDetailPage(playlistId: list.id)),
    );
  }

  /// 32x32 playlist cover, radius 6. list.cover is already the
  /// first-track cover; a truly coverless list gets a neutral accent
  /// gradient tile + note (never a grey block).
  Widget _playlistCover(HaoTheme theme, UserPlaylist list) {
    if (list.cover.isEmpty) return _coverlessTile(theme);
    return ClipRRect(
      borderRadius: BorderRadius.circular(6),
      child: Image(
        image: MusicImageProvider(list.cover),
        width: 32,
        height: 32,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => _coverlessTile(theme),
      ),
    );
  }

  Widget _coverlessTile(HaoTheme theme) {
    return Container(
      width: 32,
      height: 32,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(6),
        gradient: LinearGradient(
          begin: Alignment.topLeft,
          end: Alignment.bottomRight,
          colors: [
            theme.accent.withValues(alpha: 0.22),
            theme.accent.withValues(alpha: 0.08),
          ],
        ),
      ),
      child: Icon(Icons.music_note, size: 20, color: theme.textMuted),
    );
  }

  /// P1-9 (a) slim import row: radius-12 field, ~40 high, capsule
  /// button; the old 12pt note below is merged into the hint.
  Widget _importRow(HaoTheme theme) {
    return Row(
      children: [
        Expanded(
          child: GlassCard(
            radius: 12,
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 2),
            child: TextField(
              controller: _importController,
              decoration: InputDecoration(
                hintText: '粘贴网易云 / QQ / 酷我 / 酷狗公开歌单链接',
                hintStyle: TextStyle(color: theme.textMuted, fontSize: 13),
                border: InputBorder.none,
                enabledBorder: InputBorder.none,
                focusedBorder: InputBorder.none,
                contentPadding: const EdgeInsets.symmetric(vertical: 8),
              ),
            ),
          ),
        ),
        const SizedBox(width: 8),
        _CapsuleButton(
          label: _importing ? '导入中…' : '导入',
          enabled: !_importing,
          onTap: _importLink,
        ),
      ],
    );
  }

  Widget _recentBody(HaoTheme theme) {
    if (_recent.isEmpty) {
      return const Padding(
        padding: EdgeInsets.symmetric(horizontal: 24),
        child: HaoEmptyState(
          icon: Icons.access_time,
          title: '暂无播放记录',
          minHeight: 300,
        ),
      );
    }
    final shown = _recent.take(5).toList();
    final favIds = MusicStore.getFavIds();
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24),
      child: Column(
        children: [
          for (var i = 0; i < shown.length; i++) ...[
            // Divider indent 94 aligns with the compact row's text
            // column (page 24 + row padding 10 + cover 48 + gap 12);
            // endIndent 34 is the row's right padding (page 24 + 10).
            if (i > 0)
              Divider(
                height: 1,
                indent: 94,
                endIndent: 34,
                color: theme.hairline,
              ),
            _StaggerIn(
              index: i,
              id: 'home-recent-${shown[i].identityKey}',
              child: SongRow(
                compact: true,
                song: shown[i],
                isFav: favIds.contains(shown[i].identityKey),
                onPlay: () => _playSong(shown[i], shown),
                onToggleFav: () async {
                  await _player.toggleFav(shown[i]);
                  _refresh();
                },
                onOpenArtist: () => _push(
                  ArtistDetailPage(
                    platform: shown[i].platform,
                    artistId: '',
                    artistName: firstArtist(shown[i].artist),
                  ),
                ),
                onLongPress: (rowCtx) =>
                    unawaited(openSongQuickMenu(rowCtx, shown[i])),
              ),
            ),
          ],
        ],
      ),
    );
  }

}

/// Kumone `FeatureCard` (HomeView.swift:400-457): 230x132, radius 12
/// (Theme.Radius.large), white 0.12 stroke 0.5pt, padding 14, icon 22
/// top-left, title 15 bold bottom-left (no subtitle — removed
/// 2026-11-19 clean pass), text shadow black 0.4 r2 y1; background is
/// gradient, or (no cover) the tile's own Kumone gradient + white 0.18
/// radial highlight (top-leading, endRadius 220). The gradient comes
/// from the tile (one distinct Kumone gradient per card — see the file
/// header); the theme accent is never used here, so the cards stay
/// coloured in all 4 themes x light/dark.
class _FeatureCard extends StatelessWidget {
  const _FeatureCard({required this.tile, this.width = 230, this.height = 132});

  final _FeatureTile tile;

  /// Card width (the shelf uses the Kumone 230; the FM / heartbeat
  /// row passes double.infinity inside its Expanded cells).
  final double width;

  /// Card height (the shelf uses the Kumone 132; the FM / heartbeat
  /// row uses 96 to keep the 230:132 ratio at half width).
  final double height;

  @override
  Widget build(BuildContext context) {
    if (tile.glass) {
      return _buildGlass(context);
    }
    final cover = tile.cover;
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: Colors.white.withValues(alpha: 0.12),
          width: 0.5,
        ),
      ),
      child: ClipRRect(
        borderRadius: BorderRadius.circular(12),
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HaoHaptics.tap();
              tile.onTap();
            },
            borderRadius: BorderRadius.circular(12),
            child: Stack(
              children: [
                Positioned.fill(
                  child: cover != null
                      ? Image(
                          image: MusicImageProvider(cover),
                          fit: BoxFit.cover,
                          errorBuilder: (_, _, _) => _gradientBackground(),
                        )
                      : _gradientBackground(),
                ),
                if (cover != null)
                  const Positioned.fill(
                    child: DecoratedBox(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            Color.fromRGBO(0, 0, 0, 0.1),
                            Color.fromRGBO(0, 0, 0, 0.68),
                          ],
                        ),
                      ),
                    ),
                  ),
                Positioned.fill(
                  child: Padding(
                    padding: const EdgeInsets.all(14),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
                        _featureIcon(Colors.white),
                        const Spacer(),
                        Text(
                          tile.title,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(
                            color: Colors.white,
                            fontSize: 15,
                            fontWeight: FontWeight.w700,
                            shadows: [
                              Shadow(
                                color: Color.fromRGBO(0, 0, 0, 0.4),
                                blurRadius: 2,
                                offset: Offset(0, 1),
                              ),
                            ],
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  /// Glass FM / heartbeat card (chen-approved preview
  /// ~/workspace/preview/fm-glass-preview.html): real liquid glass
  /// — GlassCard standard, because the cards sit in the scrolling
  /// music home (the library warns premium "may not render correctly
  /// in scrollable contexts"); radius 12, padding zero; tint wash
  /// from the tile's own gradient colour, 135° (topLeft ->
  /// bottomRight), light 0.14 -> 0.06 / dark 0.22 -> 0.10. Icon +
  /// title use theme.textPrimary (dark text in light mode, white in
  /// dark mode); the title shadow is dropped here — it only exists
  /// to lift white text off the solid gradient, and it muddies text
  /// on glass. Tap + haptics are the same InkWell as the gradient
  /// branch; layout (96 high, icon 22 top-left, title 15 bold
  /// bottom-left, 14 padding) is unchanged.
  Widget _buildGlass(BuildContext context) {
    final theme = HaoTheme.of(context);
    final isDark = Theme.of(context).brightness == Brightness.dark;
    final tintBase =
        isDark ? (tile.glassTintDark ?? tile.glassTint!) : tile.glassTint!;
    final wash = LinearGradient(
      begin: Alignment.topLeft,
      end: Alignment.bottomRight,
      colors: [
        tintBase.withValues(alpha: isDark ? 0.22 : 0.14),
        tintBase.withValues(alpha: isDark ? 0.10 : 0.06),
      ],
    );
    final foreground = theme.textPrimary;
    return SizedBox(
      width: width,
      height: height,
      child: GlassCard(
        radius: 12,
        padding: EdgeInsets.zero,
        quality: GlassCardQuality.standard,
        tint: wash,
        child: Material(
          color: Colors.transparent,
          child: InkWell(
            onTap: () {
              HaoHaptics.tap();
              tile.onTap();
            },
            borderRadius: BorderRadius.circular(12),
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  _featureIcon(foreground),
                  const Spacer(),
                  Text(
                    tile.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: foreground,
                      fontSize: 15,
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  /// The tile's own Kumone gradient + Kumone's white 0.18 radial
  /// highlight (top-leading, endRadius 220 on a 230x132 card).
  Widget _gradientBackground() {
    return Stack(
      children: [
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topLeft,
                end: Alignment.bottomRight,
                colors: tile.gradient,
              ),
            ),
          ),
        ),
        Positioned.fill(
          child: DecoratedBox(
            decoration: BoxDecoration(
              gradient: RadialGradient(
                center: Alignment.topLeft,
                radius: 1.6,
                colors: [
                  Colors.white.withValues(alpha: 0.18),
                  Colors.white.withValues(alpha: 0),
                ],
              ),
            ),
          ),
        ),
      ],
    );
  }

  /// 22 medium icon; the daily card overlays today's day number
  /// (10 bold, offset y+3) like Kumone's showsDate (HomeView.swift
  /// :427-435). [color] is white on the gradient cards and
  /// theme.textPrimary on the glass cards.
  Widget _featureIcon(Color color) {
    if (!tile.showsDate) {
      return Icon(tile.icon, size: 22, color: color);
    }
    return SizedBox(
      width: 22,
      height: 22,
      child: Stack(
        alignment: Alignment.center,
        children: [
          Icon(tile.icon, size: 22, color: color),
          Padding(
            padding: const EdgeInsets.only(top: 3),
            child: Text(
              '${DateTime.now().day}',
              style: const TextStyle(
                color: Colors.white,
                fontSize: 10,
                fontWeight: FontWeight.w700,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

/// Kumone capsule button (LibraryPages.swift:40-49 「播放全部」:
/// 12.5 semibold, H14 V7, capsule). C4: the fill is theme accent
/// (black in light, dark grey in dark — white text stays readable),
/// NOT Kumone's red accentGradient. Shared by 「播放全部」 and the
/// slimmed import button. Disabled renders at 0.4 opacity (Kumone
/// disables the button when there is nothing to play).
class _CapsuleButton extends StatelessWidget {
  const _CapsuleButton({
    required this.label,
    required this.enabled,
    required this.onTap,
    this.icon,
  });

  final String label;
  final bool enabled;
  final VoidCallback onTap;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final onAccent = Theme.of(context).colorScheme.onPrimary;
    final icon = this.icon;
    return Opacity(
      opacity: enabled ? 1 : 0.4,
      child: Material(
        color: Colors.transparent,
        child: InkWell(
          onTap: enabled
              ? () {
                  HaoHaptics.tap();
                  onTap();
                }
              : null,
          borderRadius: BorderRadius.circular(999),
          child: Container(
            decoration: BoxDecoration(
              color: theme.accent,
              borderRadius: BorderRadius.circular(999),
            ),
            padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 7),
            child: Row(
              mainAxisSize: MainAxisSize.min,
              children: [
                if (icon != null) ...[
                  Icon(icon, size: 13, color: onAccent),
                  const SizedBox(width: 2),
                ],
                Text(
                  label,
                  style: TextStyle(
                    color: onAccent,
                    fontSize: 12.5,
                    fontWeight: FontWeight.w600,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

/// Kumone staggered entrance (Components.swift:71-92, Theme.swift
/// AppAnimation.snappy + stagger): opacity 0->1 + y+16->0, spring
/// response 0.25 / damping 0.8, delay index*0.04s capped at 0.4s, each
/// id animates once (600-item cache, cleared when full). Flutter has
/// no spring-response curve constant, so the 250 ms settle is mapped
/// to Curves.easeOutCubic (same duration, no overshoot); delay cap,
/// offset and once-only cache are copied exactly. Reduce-motion
/// (MediaQuery.disableAnimations) skips the animation entirely.
class _StaggerIn extends StatefulWidget {
  const _StaggerIn({
    required this.index,
    required this.id,
    required this.child,
  });

  final int index;
  final String id;
  final Widget child;

  @override
  State<_StaggerIn> createState() => _StaggerInState();
}

class _StaggerInState extends State<_StaggerIn>
    with SingleTickerProviderStateMixin {
  static final _seen = <String>{};

  late final AnimationController _controller;
  late final Animation<double> _t;

  @override
  void initState() {
    super.initState();
    _controller = AnimationController(
      vsync: this,
      duration: const Duration(milliseconds: 250),
    );
    _t = CurvedAnimation(parent: _controller, curve: Curves.easeOutCubic);
    if (_seen.contains(widget.id)) {
      _controller.value = 1;
    } else {
      if (_seen.length > 600) _seen.clear();
      _seen.add(widget.id);
      final delayMs = widget.index * 40 > 400 ? 400 : widget.index * 40;
      Future.delayed(Duration(milliseconds: delayMs), () {
        if (mounted) _controller.forward();
      });
    }
  }

  @override
  void dispose() {
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    if (MediaQuery.of(context).disableAnimations) return widget.child;
    return AnimatedBuilder(
      animation: _t,
      builder: (_, child) => Opacity(
        opacity: _t.value,
        child: Transform.translate(
          offset: Offset(0, 16 * (1 - _t.value)),
          child: child,
        ),
      ),
      child: widget.child,
    );
  }
}

