// Emby detail page (build 28).
//
// Independent from VideoDetailPage: it calls EmbyClient.detail()
// directly and NEVER goes through VideoDetailService.loadWithRace
// (that race is CMS-only: same-title alt sources + Douban merge).
// Playback goes to the same NativeVideoPlayerPage, but with a
// zero-alt detail service, so the player's play-time source switch
// (_trySwitchSource) can never swap an Emby film onto a CMS source.
//
// Layout values are copied from VideoDetailPage's widgets (that file
// is outside this group's files, so its private widgets can't be
// imported): cover hero 46vh/min 300 with the same fade gradient,
// big play button (17/700, vertical 16, radius large), title 30/800,
// meta line, genre chips, 46px circle actions, line ChoiceChips,
// 128x72 episode cards, synopsis 15/1.8. No Douban anywhere here:
// Emby items carry their own Overview / rating / genres.

import 'dart:async';

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/player/kernel/player_kernel.dart';
import '../../core/storage/safe_json.dart';
import '../../core/theme/glass.dart';
import '../../core/theme/hao_radius.dart';
import '../../core/theme/hao_themes.dart';
import '../../services/video/emby_client.dart';
import '../../services/video/emby_models.dart';
import '../../widgets/hao_nav_bar.dart';
import 'emby_spec.dart';
import 'native_video_player_page.dart';
import 'skip_intro_dialog.dart';
import 'video_detail_service.dart';
import 'video_history_store.dart';
import 'video_models.dart';
import 'video_title_helpers.dart';
import 'widgets/referer_image.dart';

class EmbyDetailPage extends StatefulWidget {
  const EmbyDetailPage({
    super.key,
    required this.itemId,
    this.preload,
    this.autoResume = false,
    this.startEpName,
    this.client,
  });

  final String itemId;

  /// Item from the tab/search row: paints the hero + title instantly.
  final VideoItem? preload;
  final bool autoResume;

  /// 1.1.6 下一集: same contract as `VideoDetailPage.startEpName` —
  /// open at the episode with this exact name and auto-play it from
  /// 0. The target may sit in a season whose episodes are not loaded
  /// yet (lazy seasons): `_load` then loads the empty seasons and
  /// re-resolves before playing.
  final String? startEpName;

  /// Test seam: production passes null and the page loads the stored
  /// config itself.
  final EmbyClient? client;

  @override
  State<EmbyDetailPage> createState() => _EmbyDetailPageState();
}

class _EmbyDetailPageState extends State<EmbyDetailPage> {
  /// Zero-alt service: findAlts yields nothing, so the player can
  /// never switch an Emby title onto a CMS source. The default
  /// fetchDetail is never reached (the switch loop only runs on
  /// yielded alts).
  late final VideoDetailService _zeroAltService = VideoDetailService(
    findAlts: (title, year, exclude, {cancelToken}) =>
        const Stream<AltVideoSource>.empty(),
  );

  final _loadToken = CancelToken();

  VideoDetail? _detail;
  bool _loading = true;
  bool _failed = false;
  String _errorMessage = '';
  int _lineIdx = 0;
  int _epIdx = 0;
  ResumeInfo? _resume;
  bool _isFav = false;
  bool _watched = false;
  bool _epsExpanded = false;
  bool _synExpanded = false;
  bool _fadedIn = false;
  bool _autoResumeDone = false;

  /// True once the start episode (下一集) resolved to loaded lines.
  bool _startResolved = false;

  /// Raw season rows (Id + IndexNumber) in the same sorted order as
  /// [_detail]'s lines — the detail page needs the season id to lazy
  /// -load a season ([EmbyClient.seasonEpisodes]), and lines carry
  /// no ids. Only filled for series.
  List<Map<String, dynamic>> _seasons = [];

  /// Seasons currently loading (line indices). A line with no
  /// episodes yet is "not loaded", never "missing".
  final Set<int> _seasonLoading = {};

  /// Server-side rating for this item (UserData.Likes): true =
  /// liked, false = disliked, null = no rating on record.
  bool? _likes;

  EmbyClient? get _client {
    if (widget.client != null) return widget.client;
    final config = EmbyConfigStore.load();
    if (config == null || !config.isConfigured) return null;
    return EmbyClient(config: config);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _fadedIn = true);
    });
    unawaited(_load());
  }

  @override
  void dispose() {
    _loadToken.cancel();
    super.dispose();
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final client = _client;
    if (client == null) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = '还没有连接 Emby，请在设置里连接';
      });
      return;
    }
    VideoDetail detail;
    try {
      detail = await client.detail(widget.itemId, cancelToken: _loadToken);
    } on DioException catch (e) {
      if (e.type == DioExceptionType.cancel) return;
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = '连不上 Emby 服务器，检查地址和网络';
      });
      return;
    } on EmbyException catch (e) {
      if (!mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _errorMessage = e.message;
      });
      return;
    }
    if (!mounted) return;
    _applyDetail(detail);
    // Server user data (favorite / rating / single-episode resume)
    // and, for series, the season-id list for lazy season loads.
    // Best-effort and parallel: either failing must not fail the
    // page — local state stays the fallback. Series detection: a
    // series detail's lines are season lines ('第 N 季' / '季');
    // movies and bare episodes have the single '直链' line.
    final seriesLike = detail.lines.any((l) => l.name.contains('季'));
    final extrasFuture = _loadServerExtras(detail, loadSeasons: seriesLike);
    unawaited(extrasFuture);
    // 下一集 start: the target episode may sit in a season whose
    // episodes are not loaded yet — wait for the season list, load
    // the empty seasons, then re-resolve. Best-effort: an
    // unresolvable name falls back to the normal open.
    if (widget.startEpName != null && !_startResolved) {
      await extrasFuture;
      if (mounted) await _resolveStartEpisode();
    }
    if ((widget.autoResume && _resume != null || _startResolved) &&
        !_autoResumeDone) {
      _autoResumeDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_play());
      });
    }
  }

  /// Resolve the start episode (下一集) against the loaded lines,
  /// loading any still-empty season first. Sets the indices + clears
  /// the resume (the next episode starts at 0).
  Future<void> _resolveStartEpisode() async {
    final d = _detail;
    final name = widget.startEpName;
    if (d == null || name == null || name.isEmpty) return;
    var found = findEpisodeByName(d.lines, name);
    if (found == null) {
      for (var i = 0; i < d.lines.length; i++) {
        if (d.lines[i].episodes.isEmpty) {
          await _loadSeason(i);
          if (!mounted) return;
        }
      }
      found = findEpisodeByName(d.lines, name);
    }
    if (found == null || !mounted) return;
    setState(() {
      _lineIdx = found!.lineIdx;
      _epIdx = found.epIdx;
      _resume = null;
    });
    _startResolved = true;
  }

  /// Fetch the server-side extras for this item: UserData
  /// (favorite / rating / resume) always, season rows only for
  /// series. Applies them to the page state; never throws.
  Future<void> _loadServerExtras(
    VideoDetail detail, {
    bool loadSeasons = true,
  }) async {
    final client = _client;
    if (client == null) return;
    EmbyUserData? userData;
    List<Map<String, dynamic>> seasons = const [];
    try {
      userData = await client.userData(
        widget.itemId,
        cancelToken: _loadToken,
      );
    } catch (_) {
      userData = null;
    }
    if (loadSeasons) {
      try {
        seasons = await client.seasons(
          widget.itemId,
          cancelToken: _loadToken,
        );
      } catch (_) {
        seasons = const [];
      }
    }
    if (!mounted) return;
    setState(() {
      _seasons = seasons;
      if (userData != null) {
        // Server favorite wins over the local flag for Emby items;
        // the rating has no local equivalent at all.
        _isFav = userData.isFavorite;
        _likes = userData.likes;
      }
    });
    // The resume line may be a season whose episodes were not
    // loaded yet (lazy detail): load it now that season ids exist.
    final d = _detail;
    if (d != null &&
        _lineIdx >= 0 &&
        _lineIdx < d.lines.length &&
        d.lines[_lineIdx].episodes.isEmpty) {
      unawaited(_loadSeason(_lineIdx));
    }
    // A single-episode detail (movie / bare episode) can resume
    // from the server position when there is no local resume: the
    // series case is per-episode and stays local-only (see
    // _applyDetail).
    if (userData != null &&
        _resume == null &&
        detail.lines.length == 1 &&
        detail.lines.first.episodes.length == 1) {
      final pos = userData.playbackPositionSeconds;
      final dur = (detail.meta.runtime ?? 0) * 60.0;
      if (pos > 10 && (dur <= 0 || pos < dur - 30)) {
        if (!mounted) return;
        setState(() {
          _resume = ResumeInfo(
            lineIdx: 0,
            epIdx: 0,
            epName: detail.lines.first.episodes.first.name,
            position: pos,
            duration: dur,
          );
        });
      }
    }
  }

  /// Load one season's episodes on demand (1.1.6 lazy load): the
  /// line's episodes are replaced in place; nothing else on the
  /// page moves. No-op when the line already has episodes or a load
  /// for it is in flight.
  Future<void> _loadSeason(int lineIdx) async {
    final d = _detail;
    final client = _client;
    if (d == null || client == null) return;
    if (lineIdx < 0 || lineIdx >= d.lines.length) return;
    if (d.lines[lineIdx].episodes.isNotEmpty) return;
    if (_seasonLoading.contains(lineIdx)) return;
    final seasonId = lineIdx < _seasons.length
        ? (jStrN(_seasons[lineIdx]['Id']) ?? '')
        : '';
    if (seasonId.isEmpty) return;
    setState(() => _seasonLoading.add(lineIdx));
    List<PlayEpisode> eps;
    try {
      eps = await client.seasonEpisodes(
        widget.itemId,
        seasonId,
        cancelToken: _loadToken,
      );
    } catch (_) {
      if (mounted) setState(() => _seasonLoading.remove(lineIdx));
      return;
    }
    if (!mounted) return;
    final lines = List<PlayLine>.of(d.lines);
    lines[lineIdx] = PlayLine(name: lines[lineIdx].name, episodes: eps);
    setState(() {
      _seasonLoading.remove(lineIdx);
      _detail = VideoDetail(
        source: d.source,
        vodId: d.vodId,
        meta: d.meta,
        mediaType: d.mediaType,
        lines: lines,
      );
    });
  }

  void _applyDetail(VideoDetail detail) {
    // Same resume rule as the CMS detail page: this source's own
    // resume key first, then the film-level row (title + year).
    final resume = VideoHistoryStore.loadResume(
          EmbyClient.sourceId,
          detail.vodId,
          detail.lines,
        ) ??
        VideoHistoryStore.loadResumeForFilm(
          title: detail.meta.name,
          year: detail.meta.year,
          lines: detail.lines,
        );
    final hist = VideoHistoryStore.findByTitle(
      detail.meta.name,
      year: detail.meta.year,
    );
    final favItem = VideoItem(
      source: EmbyClient.sourceId,
      sourceName: 'Emby',
      vodId: detail.vodId,
      name: detail.meta.name,
      pic: detail.meta.pic,
      year: detail.meta.year,
    );
    // 1.1.6 下一集: open at the episode with this exact name (when
    // it is already in the loaded lines — `_load` re-resolves after
    // loading lazy seasons) and play it from 0.
    final start = widget.startEpName != null
        ? findEpisodeByName(detail.lines, widget.startEpName!)
        : null;
    final clamped = start != null
        ? (start.lineIdx, start.epIdx)
        : _clampIndices(
            detail.lines,
            resume?.lineIdx ?? hist?.lineIdx ?? 0,
            resume?.epIdx ?? hist?.epIdx ?? 0,
          );
    if (start != null) _startResolved = true;
    setState(() {
      _detail = detail;
      _loading = false;
      _failed = false;
      _lineIdx = clamped.$1;
      _epIdx = clamped.$2;
      // A start episode plays from 0: the saved resume belongs to a
      // different episode and must not leak its position in.
      _resume = start != null ? null : resume;
      _watched = hist != null;
      _epsExpanded = false;
      _isFav = VideoHistoryStore.isFav(favItem);
    });
  }

  (int, int) _clampIndices(List<PlayLine> lines, int line, int ep) {
    if (lines.isEmpty) return (0, 0);
    final li = line.clamp(0, lines.length - 1);
    final eps = lines[li].episodes;
    if (eps.isEmpty) return (li, 0);
    return (li, ep.clamp(0, eps.length - 1));
  }

  String get _currentEpName {
    final d = _detail;
    if (d == null) return '';
    final eps = d.lines[_lineIdx].episodes;
    if (_epIdx < 0 || _epIdx >= eps.length) return '';
    return eps[_epIdx].name;
  }

  String get _playButtonLabel {
    if (_resume != null &&
        _resume!.lineIdx == _lineIdx &&
        _resume!.epIdx == _epIdx) {
      return '继续播放 · $_currentEpName · ${formatMmSs(_resume!.position)}';
    }
    return _currentEpName;
  }

  Future<void> _play([int? line, int? ep]) async {
    final d = _detail;
    if (d == null) return;
    final li = line ?? _lineIdx;
    final ei = ep ?? _epIdx;
    setState(() {
      _lineIdx = li;
      _epIdx = ei;
    });
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => NativeVideoPlayerPage(
          detail: d,
          // Zero-alt: Emby playback never switches sources.
          detailService: _zeroAltService,
          initialLineIndex: li,
          initialEpisodeIndex: ei,
          initialPosition: (_resume != null &&
                  _resume!.lineIdx == li &&
                  _resume!.epIdx == ei)
              ? _resume!.position
              : 0,
          onClose: (lineIdx, epIdx, position) {
            if (!mounted) return;
            setState(() {
              _lineIdx = lineIdx;
              _epIdx = epIdx;
              _watched = true;
            });
          },
        ),
      ),
    );
  }

  Future<void> _toggleFav() async {
    final d = _detail;
    if (d == null) return;
    final item = VideoItem(
      source: EmbyClient.sourceId,
      sourceName: 'Emby',
      vodId: d.vodId,
      name: d.meta.name,
      pic: d.meta.pic,
      picAlt: d.meta.picAlt,
      year: d.meta.year,
    );
    final nowFav = await VideoHistoryStore.toggleFav(item);
    if (!mounted) return;
    setState(() => _isFav = nowFav);
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text(nowFav ? '已收藏' : '已取消收藏')),
    );
    // Server favorite (1.1.6): best-effort, local state stays the
    // fallback — a failed write shows a note but never reverts the
    // local toggle (the user did tap it).
    final client = _client;
    if (client != null) {
      final ok = await client.setFavorite(d.vodId, nowFav);
      if (!ok && mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(content: Text('收藏只保存在本机，未同步到服务器')),
        );
      }
    }
  }

  /// Like toggle (1.1.6): Emby's rating API is a like/dislike flag,
  /// not stars — the app exposes a single "like" toggle (tap again
  /// to clear). A failed write never changes the displayed state.
  Future<void> _toggleLike() async {
    final d = _detail;
    final client = _client;
    if (d == null || client == null) return;
    final wantLike = _likes != true;
    final ok = wantLike
        ? await client.rateItem(d.vodId, likes: true)
        : await client.clearRating(d.vodId);
    if (!mounted) return;
    if (!ok) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('评分未同步到服务器')),
      );
      return;
    }
    setState(() => _likes = wantLike ? true : null);
  }

  void _showWatchedInfo() {
    final hist = VideoHistoryStore.findByTitle(
      _detail?.meta.name ?? '',
      year: _detail?.meta.year ?? '',
    );
    final theme = HaoTheme.of(context);
    if (!_watched || hist == null) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('暂无观看记录')),
      );
      return;
    }
    final pct = hist.duration > 0
        ? (hist.position / hist.duration * 100).round().clamp(0, 100)
        : 0;
    final done = hist.isFinished;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          '继续观看：${hist.epName.isNotEmpty ? hist.epName : '第${hist.epIdx + 1}集'} · ${done ? '已看完' : '$pct%'}',
        ),
        backgroundColor: theme.surfaceSolid,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final preload = widget.preload;
    return Scaffold(
      // Fixed back button over the body (same dead end as the CMS
      // detail page): the hero's button lived inside the scrolling
      // cover, and the load-failed card had no exit at all.
      body: Stack(
        children: [
          AnimatedOpacity(
            opacity: _fadedIn ? 1 : 0,
            duration: const Duration(milliseconds: 350),
            child: _failed
                ? _ErrorCard(message: _errorMessage, onRetry: _load)
                : _loading && _detail == null
                    ? preload != null
                        ? _LoadingWithPreload(
                            preload: preload,
                            imageHeaders: _client?.imageHeaders,
                          )
                        : const Center(child: CupertinoActivityIndicator())
                    : _buildDetail(theme),
          ),
          const HaoCoverBackButton(),
        ],
      ),
    );
  }

  Widget _buildDetail(HaoTheme theme) {
    final d = _detail!;
    final m = d.meta;
    final genreChips = m.genreChips;
    final lines = d.lines;
    final episodes = lines[_lineIdx].episodes;
    // Spec line (DV / 4K badges + size + bitrate + container/codec)
    // follows the CURRENT episode's stream facts, read back from
    // its URL markers: for a film that is the film; for a series
    // the line changes with the selected episode (per-episode facts
    // are the honest ones). No markers = no line, never a guess.
    // CMS rows never reach this page, so no CMS row can ever be
    // labelled 4K here.
    final specFacts = _epIdx >= 0 && _epIdx < episodes.length
        ? streamFactsOf(episodes[_epIdx].url)
        : null;
    // EmbySpecLine takes EmbyStreamFacts; the markers parse to
    // StreamFacts, so convert field-for-field (dvCompatId has no
    // marker and stays null — it never gates anything).
    final specLineFacts = specFacts == null
        ? null
        : EmbyStreamFacts(
            container: specFacts.container,
            videoCodec: specFacts.videoCodec,
            audioCodec: specFacts.audioCodec,
            dolbyVision: specFacts.dolbyVision,
            dvProfile: specFacts.dvProfile,
            width: specFacts.width,
            height: specFacts.height,
            bitRate: specFacts.bitRate,
            size: specFacts.size,
          );
    const epCap = 12;
    final showAll = _epsExpanded || episodes.length <= epCap;
    final shown = showAll ? episodes : episodes.sublist(0, epCap);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              _CoverHero(
                pic: m.backdrop.isNotEmpty ? m.backdrop : m.pic,
                imageHeaders: _client?.imageHeaders,
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: Icon(Icons.play_arrow, shadows: HaoTheme.legibilityShadows(context),),
                    label: Text(
                      _playButtonLabel,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.accent,
                      foregroundColor:
                          Theme.of(context).colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(HaoRadius.large),
                      ),
                      elevation: 2,
                      shadowColor: theme.accent.withValues(alpha: 0.35),
                    ),
                    onPressed: () => _play(),
                  ),
                ),
              ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.name,
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 30,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.02,
                        height: 1.15,
                      ),
                    ),
                    const SizedBox(height: 8),
                    if (specLineFacts != null) ...[
                      EmbySpecLine(facts: specLineFacts),
                      const SizedBox(height: 8),
                    ],
                    _MetaLine(meta: m),
                    if (genreChips.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: genreChips
                            .map(
                              (g) => GlassCard(
                                radius: 999,
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                shadow: GlassShadow.none,
                                child: Text(
                                  g,
                                  style: TextStyle(
                                    color: theme.textMuted,
                                    fontSize: 12,
                                    fontWeight: FontWeight.w600,
                                  ),
                                ),
                              ),
                            )
                            .toList(),
                      ),
                    ],
                    // Cast: the server sends People on every item.
                    // The synopsis lives only at the bottom of the
                    // page (expandable plainContent) — rendering
                    // m.content here too showed the same Overview
                    // twice (b30).
                    if (m.director.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        '导演：${m.director}',
                        style: TextStyle(
                          shadows: HaoTheme.legibilityShadows(context),
                          color: theme.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                    if (m.actor.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        '主演：${m.actor}',
                        style: TextStyle(
                          shadows: HaoTheme.legibilityShadows(context),
                          color: theme.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    Row(
                      children: [
                        _CircleAction(
                          icon: Icons.check,
                          active: _watched,
                          tooltip: '已看',
                          onTap: _showWatchedInfo,
                        ),
                        const SizedBox(width: 12),
                        _CircleAction(
                          icon: _isFav
                              ? Icons.favorite
                              : Icons.favorite_border,
                          active: _isFav,
                          tooltip: '收藏',
                          onTap: _toggleFav,
                        ),
                        const SizedBox(width: 12),
                        _CircleAction(
                          icon: _likes == true
                              ? Icons.thumb_up
                              : Icons.thumb_up_outlined,
                          active: _likes == true,
                          tooltip: '喜欢',
                          onTap: _toggleLike,
                        ),
                      ],
                    ),
                  ],
                ),
              ),
              if (lines.length > 1) ...[
                const SizedBox(height: 20),
                SizedBox(
                  height: 36,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 12),
                    itemCount: lines.length,
                    itemBuilder: (context, i) {
                      final selected = i == _lineIdx;
                      return Padding(
                        padding: const EdgeInsets.symmetric(horizontal: 4),
                        child: ChoiceChip(
                          label: Text(lines[i].name),
                          selected: selected,
                          selectedColor: theme.accentSoft,
                          backgroundColor: theme.surface,
                          side: BorderSide(
                            color: selected
                                ? theme.accent
                                : theme.hairline,
                          ),
                          labelStyle: TextStyle(
                            shadows: HaoTheme.legibilityShadows(context),
                            color: selected
                                ? theme.accent
                                : theme.textSecondary,
                            fontWeight: selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            fontSize: 14,
                          ),
                          onSelected: (_) {
                            setState(() {
                              _lineIdx = i;
                              _epIdx = 0;
                              _epsExpanded = false;
                            });
                            // Lazy season: an empty line loads its
                            // episodes on demand, never up front.
                            unawaited(_loadSeason(i));
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                child: Row(
                  children: [
                    Text(
                      '选集',
                      style: TextStyle(
                        color: theme.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '(${episodes.length})',
                      style: TextStyle(
                        color: theme.textMuted,
                        fontSize: 14,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(height: 10),
              if (episodes.isEmpty && _seasonLoading.contains(_lineIdx))
                const SizedBox(
                  height: 108,
                  child: Center(child: CupertinoActivityIndicator()),
                )
              else
                SizedBox(
                  height: 108,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: shown.length,
                    itemBuilder: (context, i) {
                      final selected = i == _epIdx;
                      return Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: _EpisodeCard(
                          index: i,
                          name: shown[i].name,
                          selected: selected,
                          onTap: () => _play(_lineIdx, i),
                          // Long-press: per-episode custom skip-intro
                          // seconds (1.1.6). Emby episodes with
                          // Chapters markers ignore this value
                          // (markers win); it still applies if the
                          // same title is ever played from CMS.
                          onLongPress: () => unawaited(
                            showSkipIntroDialog(
                              context,
                              title: m.name,
                              episodeName: shown[i].name,
                            ),
                          ),
                        ),
                      );
                    },
                  ),
                ),
              if (!showAll)
                Padding(
                  padding: const EdgeInsets.only(top: 10),
                  child: Center(
                    child: OutlinedButton(
                      onPressed: () =>
                          setState(() => _epsExpanded = true),
                      child: Text('加载更多 (${episodes.length - epCap})'),
                    ),
                  ),
                ),
              if (m.plainContent.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Text(
                        m.plainContent,
                        maxLines: _synExpanded ? null : 3,
                        overflow: _synExpanded
                            ? TextOverflow.visible
                            : TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontSize: 15,
                          height: 1.8,
                        ),
                      ),
                      if (m.plainContent.length > 120)
                        TextButton(
                          onPressed: () => setState(
                            () => _synExpanded = !_synExpanded,
                          ),
                          child: Text(_synExpanded ? '收起' : '展开全文'),
                        ),
                    ],
                  ),
                ),
              ],
              const SizedBox(height: 28),
            ],
          ),
        ),
      ],
    );
  }
}

/// Cover hero — VideoDetailPage._CoverHero's values: 46vh, min 300,
/// same fade gradient, back button top-left in a dark circle. No
/// centre play button, no episode pill on the cover.
class _CoverHero extends StatelessWidget {
  const _CoverHero({required this.pic, this.imageHeaders});

  final String pic;
  final Map<String, String>? imageHeaders;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final size = MediaQuery.of(context).size;
    final height = (size.height * 0.46).clamp(300.0, double.infinity);
    return SizedBox(
      height: height,
      width: double.infinity,
      child: Stack(
        fit: StackFit.expand,
        children: [
          if (pic.isNotEmpty)
            RefererImage(
              url: pic,
              headers: imageHeaders,
              fit: BoxFit.cover,
              fallback: _CoverFallback(theme: theme),
            )
          else
            _CoverFallback(theme: theme),
          Container(
            decoration: BoxDecoration(
              gradient: LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: [
                  const Color(0x47000000),
                  Colors.transparent,
                  Colors.transparent,
                  theme.scaffoldBackground.withValues(alpha: 0.55),
                  theme.scaffoldBackground,
                ],
                stops: const [0.0, 0.22, 0.45, 0.78, 1.0],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _CoverFallback extends StatelessWidget {
  const _CoverFallback({required this.theme});

  final HaoTheme theme;

  @override
  Widget build(BuildContext context) {
    return ColoredBox(
      color: theme.surfaceStrong,
      child: Center(
        child: Icon(Icons.movie, shadows: HaoTheme.legibilityShadows(context),  color: theme.textMuted, size: 64),
      ),
    );
  }
}

/// Spec badges for the Emby detail page (1.1.6): 'DV' + '4K', facts
/// only, Emby detail page only.
///
/// - 'DV' means the source file carries Dolby Vision (any profile —
///   the badge never claims the picture is playing as DV: P7 plays
///   its HDR10 base layer, P8 plays natively on AVPlayer in MP4).
/// - '4K' means frame width >= 3840 or height >= 2160.
/// - No signal = no badge, never a guess. CMS has no such signals,
///   so this widget never appears on CMS pages; episode / line cards
///   have no badges either (facts do not reach them).
///
/// Design values copied from the genre chips in this file
/// (GlassCard radius 999, horizontal 10 / vertical 5, spacing 6) —
/// the only delta is 12/700 + textPrimary instead of 12/600 +
/// textMuted, so specs read as specs, not genres. Theme variables
/// only; no purple, no red.
class EmbySpecBadges extends StatelessWidget {
  const EmbySpecBadges({super.key, required this.facts});

  /// Facts behind the badges: the current episode's stream facts,
  /// read back from its URL markers (see _buildDetail). Null when
  /// the URL carries no markers.
  final StreamFacts? facts;

  /// Labels in display order. Empty when the facts say nothing.
  static List<String> labelsFor(StreamFacts? facts) {
    if (facts == null) return const [];
    return [
      if (facts.dolbyVision) 'DV',
      if (facts.is4K) '4K',
    ];
  }

  @override
  Widget build(BuildContext context) {
    final labels = labelsFor(facts);
    if (labels.isEmpty) return const SizedBox.shrink();
    final theme = HaoTheme.of(context);
    return Wrap(
      spacing: 6,
      runSpacing: 6,
      children: labels
          .map(
            (label) => GlassCard(
              radius: 999,
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 5,
              ),
              shadow: GlassShadow.none,
              child: Text(
                label,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ),
          )
          .toList(),
    );
  }
}

/// Meta line — VideoDetailPage._MetaLine's values, minus the Douban
/// mark (Emby never merges Douban): ★ score + year · type · runtime.
class _MetaLine extends StatelessWidget {
  const _MetaLine({required this.meta});

  final VideoMeta meta;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final parts = <String>[];
    if (meta.genreChips.isEmpty && meta.type.isNotEmpty) {
      parts.add(meta.type);
    }
    if (meta.area.isNotEmpty) parts.add(meta.area);
    if (meta.runtime != null) parts.add('${meta.runtime}分钟');
    final rest = [
      if (meta.releaseDate.isNotEmpty)
        meta.releaseDate
      else if (meta.year.isNotEmpty)
        meta.year,
      ...parts,
    ].join(' · ');
    return Wrap(
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      children: [
        if (meta.hasUsableScore)
          Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              Icon(Icons.star, shadows: HaoTheme.legibilityShadows(context),  color: theme.accent, size: 16),
              const SizedBox(width: 2),
              Text(
                meta.score,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
            ],
          ),
        if (rest.isNotEmpty)
          Text(
            rest,
            style: TextStyle(color: theme.textMuted, fontSize: 14),
          ),
      ],
    );
  }
}

class _CircleAction extends StatelessWidget {
  const _CircleAction({
    required this.icon,
    required this.active,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final bool active;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      child: Container(
        width: 46,
        height: 46,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          border: Border.all(
            color: active ? theme.accent : theme.hairline,
            width: 1.5,
          ),
          color: active ? theme.accentSoft : Colors.transparent,
        ),
        child: Icon(
          icon, shadows: HaoTheme.legibilityShadows(context), 
          color: active ? theme.accent : theme.textSecondary,
        ),
      ),
    );
  }
}

/// Episode card — VideoDetailPage._EpisodeCard's values: 128x72
/// numbered tile, number 22/800, name 13 below. No per-episode
/// stills (same rule as CMS: the tile is a number, never a repeated
/// poster).
class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({
    required this.index,
    required this.name,
    required this.selected,
    required this.onTap,
    this.onLongPress,
  });

  final int index;
  final String name;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      onTap: onTap,
      onLongPress: onLongPress,
      child: SizedBox(
        width: 128,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Container(
              width: 128,
              height: 72,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: selected ? theme.accentSoft : theme.surface,
                borderRadius: BorderRadius.circular(HaoRadius.large),
                border: Border.all(
                  color: selected ? theme.accent : theme.hairline,
                  width: selected ? 1.5 : 1,
                ),
              ),
              child: Text(
                (index + 1).toString().padLeft(2, '0'),
                style: TextStyle(
                  color: selected ? theme.accent : theme.textMuted,
                  fontSize: 22,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                color: selected ? theme.accent : theme.textPrimary,
                fontSize: 13,
                fontWeight:
                    selected ? FontWeight.w700 : FontWeight.w400,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

/// Loading state with the preload cover + title already on screen
/// (same idea as the CMS detail skeleton, minimal form).
class _LoadingWithPreload extends StatelessWidget {
  const _LoadingWithPreload({required this.preload, this.imageHeaders});

  final VideoItem preload;
  final Map<String, String>? imageHeaders;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        _CoverHero(
          pic: preload.backdrop.isNotEmpty ? preload.backdrop : preload.pic,
          imageHeaders: imageHeaders,
        ),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
          child: Text(
            preload.name,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 30,
              fontWeight: FontWeight.w800,
              letterSpacing: -0.02,
              height: 1.15,
            ),
          ),
        ),
        const SizedBox(height: 32),
        const Center(child: CupertinoActivityIndicator()),
      ],
    );
  }
}

class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.message, required this.onRetry});

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(32),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(Icons.cloud_off, shadows: HaoTheme.legibilityShadows(context),  size: 48, color: theme.textMuted),
            const SizedBox(height: 16),
            Text(
              '加载失败',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textMuted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh, shadows: HaoTheme.legibilityShadows(context),),
              label: const Text('重试'),
            ),
          ],
        ),
      ),
    );
  }
}
