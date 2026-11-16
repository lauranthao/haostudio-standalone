// Video detail page (fix 4 + Infuse D1–D10 + fix 17.5/17.6).
//
// - Fast open: cover + title on screen instantly from the preload
//   passed by the list (no waiting for the network); the whole page
//   fades in over 0.35 s. Detail race: first fetch vs 3.5 s timer,
//   then alt-source race for another 3.5 s; error card with retry as
//   soon as the race resolves empty (≤ ~4 s), never 12 s.
// - Detail top is a clean COVER (Infuse-style large cover/backdrop
//   with gradient fade-in animation). There is NO centre play button
//   on the cover — the old `vodBigPlay` is deleted, not hidden.
//   Playback starts from the big blue button below the cover
//   ("▶ 第01集", or "继续播放 · 第N集 · mm:ss" when a resume position
//   exists) and from the episode cards.
// - NO fake "Season 1" dropdown (fix 17.5): seasons are not faked
//   from CMS data; if the source has no real season list, no season
//   UI exists at all.
// - NO duplicate episode number chips (fix 17.6): episodes render
//   ONCE as horizontal cards (numbered dark tile + episode name,
//   current marked, cap 12 with a "加载更多 (n)" expander).
// - The app NEVER renders a web video player: tapping play opens the
//   native landscape player directly (VOD rule). No inline web play
//   path exists in-app.
// - Resume: a saved position only counts if > 10 s in and ≥ 30 s from
//   the end (vodLocalLoad rule).
// - Douban enrichment runs AFTER the CMS render, never blocking it;
//   Douban is primary for score/poster, fill-when-missing for the
//   rest (score shows a 豆瓣 mark).
// - Episode cards use a numbered dark tile — CMS provides no
//   per-episode stills, and repeating the poster is visibly wrong.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/video/douban_parsers.dart';
import '../../services/video/douban_service.dart';
import 'native_video_player_page.dart';
import 'video_detail_service.dart';
import 'video_history_store.dart';
import 'widgets/referer_image.dart';
import 'video_models.dart';
import 'video_title_helpers.dart';

/// Clamp persisted line/episode indices to a freshly loaded detail.
///
/// History (`WatchHistoryEntry`) stores raw indices that were valid
/// when the source list was seeded; after a re-seed the line count
/// (or episode count) can shrink, and an unclamped index makes
/// `lines[_lineIdx]` throw RangeError and crash the whole page.
/// `ResumeInfo.fromStored` already validates, but the history fallback
/// below it does not — so clamp here, once, at the single entry point.
({int lineIdx, int epIdx}) clampDetailIndices(
  List<PlayLine> lines,
  int lineIdx,
  int epIdx,
) {
  if (lines.isEmpty) return (lineIdx: 0, epIdx: 0);
  final li = lineIdx.clamp(0, lines.length - 1);
  final eps = lines[li].episodes;
  final ei = eps.isEmpty ? 0 : epIdx.clamp(0, eps.length - 1);
  return (lineIdx: li, epIdx: ei);
}

class VideoDetailPage extends StatefulWidget {
  const VideoDetailPage({
    super.key,
    required this.sourceId,
    required this.vodId,
    this.preload,
    this.autoResume = false,
  });

  final dynamic sourceId;
  final String vodId;

  /// The list item the user tapped (cover + title instantly).
  final VideoItem? preload;

  /// History page resume (V-P0-1): when true and a saved resume
  /// position exists, the player opens automatically once the detail
  /// loads — tapping a history entry resumes at the saved position.
  /// When no resume exists (never watched / finished), the page just
  /// opens normally and play starts from the beginning.
  final bool autoResume;

  @override
  State<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends State<VideoDetailPage> {
  final _detailService = VideoDetailService();
  final _douban = DoubanService();

  VideoDetail? _detail;
  dynamic _detailSourceId;
  String _detailVodId = '';
  bool _loading = true;
  bool _failed = false;
  bool _switchedSource = false;
  int _lineIdx = 0;
  int _epIdx = 0;
  ResumeInfo? _resume;
  bool _isFav = false;
  bool _watched = false;
  bool _epsExpanded = false;
  bool _synExpanded = false;
  bool _fadedIn = false;
  bool _autoResumeDone = false;

  dynamic get _sid => _detailSourceId ?? widget.sourceId;
  String get _vid => _detailVodId.isEmpty ? widget.vodId : _detailVodId;

  @override
  void initState() {
    super.initState();
    _detailSourceId = widget.sourceId;
    _detailVodId = widget.vodId;
    // 0.35 s page fade-in (fix 4; respects reduced motion via the
    // framework's animation disable — no animation then).
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) setState(() => _fadedIn = true);
    });
    unawaited(_load());
  }

  Future<void> _load() async {
    setState(() {
      _loading = true;
      _failed = false;
    });
    final result = await _detailService.loadWithRace(
      widget.sourceId,
      widget.vodId,
      preload: widget.preload,
    );
    if (!mounted) return;
    if (result == null) {
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    }
    if (result.switchedSource) {
      _switchedSource = true;
    }
    _applyDetail(result.detail, result.sourceId, result.vodId);
    if (_switchedSource && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('已切换到更快片源')),
      );
    }
  }

  void _applyDetail(VideoDetail detail, dynamic sourceId, String vodId) {
    final resume = VideoHistoryStore.loadResume(sourceId, vodId, detail.lines);
    final hist = VideoHistoryStore.find(sourceId, vodId);
    final favItem = VideoItem(
      source: sourceId,
      sourceName: detail.meta.name,
      vodId: vodId,
      name: detail.meta.name,
      pic: detail.meta.pic,
      year: detail.meta.year,
    );
    final clamped = clampDetailIndices(
      detail.lines,
      resume?.lineIdx ?? hist?.lineIdx ?? 0,
      resume?.epIdx ?? hist?.epIdx ?? 0,
    );
    setState(() {
      _detail = detail;
      _detailSourceId = sourceId;
      _detailVodId = vodId;
      _loading = false;
      _failed = false;
      _lineIdx = clamped.lineIdx;
      _epIdx = clamped.epIdx;
      _resume = resume;
      _watched = hist != null;
      _epsExpanded = false;
      _isFav = VideoHistoryStore.isFav(favItem);
    });
    // Douban enrichment AFTER the CMS render — never blocks it.
    unawaited(_enrichDouban(detail));
    // History resume (V-P0-1): open the player at the saved position
    // once, only when a resume exists. No resume -> stay on the page.
    if (widget.autoResume && resume != null && !_autoResumeDone) {
      _autoResumeDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_play());
      });
    }
  }

  Future<void> _enrichDouban(VideoDetail detail) async {
    if (detail.meta.douban != null) return;
    final dd = await _douban.detail(detail.meta.name, detail.meta.year);
    if (dd == null || !mounted) return;
    // Only merge if this detail is still on screen.
    if (_detail != detail) return;
    setState(() {
      mergeDoubanIntoMeta(detail.meta, dd);
    });
  }

  String get _currentEpName {
    final d = _detail;
    if (d == null) return '第${_epIdx + 1}集';
    if (_lineIdx < 0 || _lineIdx >= d.lines.length) {
      return '第${_epIdx + 1}集';
    }
    final eps = d.lines[_lineIdx].episodes;
    if (_epIdx < 0 || _epIdx >= eps.length) return '第${_epIdx + 1}集';
    return eps[_epIdx].name;
  }

  String get _playButtonLabel {
    if (_resume != null) {
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
    // CupertinoPageRoute (not MaterialPageRoute): the iOS edge-swipe
    // back gesture works, giving the player a second exit path that
    // never goes through _close() at all — the swipe pops the route,
    // PopScope exits fullscreen, dispose() stops playback and saves
    // progress. (v1.0.6 "still won't exit": MaterialPageRoute has no
    // swipe-back on iOS, so a user who swipes — the natural iOS
    // gesture — had no way out while the back button was hidden by
    // the auto-hiding controls.)
    await Navigator.of(context).push(
      CupertinoPageRoute<void>(
        builder: (_) => NativeVideoPlayerPage(
          detail: d,
          detailService: _detailService,
          initialLineIndex: li,
          initialEpisodeIndex: ei,
          // Resume seek: only when launching the exact episode the
          // resume points at; any other episode starts at 0.
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
      source: _sid,
      sourceName: d.meta.name,
      vodId: _vid,
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
  }

  void _showWatchedInfo() {
    final hist = VideoHistoryStore.find(_sid, _vid);
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
      backgroundColor: theme.scaffoldBackground,
      body: AnimatedOpacity(
        opacity: _fadedIn ? 1 : 0,
        duration: const Duration(milliseconds: 350),
        child: _failed
            ? _ErrorCard(onRetry: _load)
            : _loading && _detail == null
                ? _DetailSkeleton(preload: preload)
                : _buildDetail(theme),
      ),
    );
  }

  Widget _buildDetail(HaoTheme theme) {
    final d = _detail!;
    final m = d.meta;
    final castNames = m.castNames;
    final castPhotos = m.douban?.castPhotos ?? const [];
    final genreChips = m.genreChips;
    final lines = d.lines;
    final episodes = lines[_lineIdx].episodes;
    const epCap = 12;
    final showAll = _epsExpanded || episodes.length <= epCap;
    final shown = showAll ? episodes : episodes.sublist(0, epCap);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // --- Clean COVER top (Infuse hero) ---
              // No centre play button anywhere on the cover.
              _CoverHero(
                pic: m.pic,
                epLabel: _currentEpName,
              ),
              // --- Big blue play button below the cover ---
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 14, 16, 0),
                child: SizedBox(
                  width: double.infinity,
                  child: FilledButton.icon(
                    icon: const Icon(Icons.play_arrow),
                    label: Text(
                      _playButtonLabel,
                      style: const TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                      ),
                    ),
                    style: FilledButton.styleFrom(
                      backgroundColor: theme.accent,
                      // onPrimary is theme-defined per mode: white on
                      // the dark-mode light-gold / light-teal /
                      // light-blue accents is unreadable, near-black
                      // on them is not.
                      foregroundColor:
                          Theme.of(context).colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      // Rounded rectangle (14px), NOT a pill (Infuse D5).
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(14),
                      ),
                      elevation: 2,
                      shadowColor: theme.accent.withValues(alpha: 0.35),
                    ),
                    onPressed: () => _play(),
                  ),
                ),
              ),
              // --- Meta: left-aligned title + meta line ---
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
                    _MetaLine(meta: m),
                    if (genreChips.isNotEmpty) ...[
                      const SizedBox(height: 10),
                      Wrap(
                        spacing: 6,
                        runSpacing: 6,
                        children: genreChips
                            .map(
                              (g) => Container(
                                padding: const EdgeInsets.symmetric(
                                  horizontal: 10,
                                  vertical: 5,
                                ),
                                decoration: BoxDecoration(
                                  color: theme.surface,
                                  border: Border.all(
                                    color: theme.hairline,
                                  ),
                                  borderRadius: BorderRadius.circular(999),
                                ),
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
                    if (m.remarks.isNotEmpty) ...[
                      const SizedBox(height: 8),
                      Text(
                        m.remarks,
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                    if (m.director.isNotEmpty) ...[
                      const SizedBox(height: 6),
                      Text(
                        '导演：${m.director}',
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: 14,
                        ),
                      ),
                    ],
                    const SizedBox(height: 12),
                    // Secondary actions, left-aligned (Infuse D6).
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
                      ],
                    ),
                  ],
                ),
              ),
              // --- Lines ---
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
                          },
                        ),
                      );
                    },
                  ),
                ),
              ],
              // --- Episodes: horizontal cards, ONCE (fix 17.6) ---
              // No fake season dropdown (fix 17.5) and no duplicate
              // bare number chips — only these cards.
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
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: theme.hairline),
                        foregroundColor: theme.accent,
                      ),
                      child: Text('加载更多 (${episodes.length - epCap})'),
                    ),
                  ),
                ),
              // --- Synopsis ---
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
              // --- Cast (no "演员" role line — fix: no fake data) ---
              if (castNames.isNotEmpty) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 8),
                  child: Text(
                    '演员',
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                SizedBox(
                  height: 148,
                  child: ListView.builder(
                    scrollDirection: Axis.horizontal,
                    padding: const EdgeInsets.symmetric(horizontal: 16),
                    itemCount: castNames.length,
                    itemBuilder: (context, i) {
                      final name = castNames[i];
                      final photo =
                          i < castPhotos.length ? castPhotos[i] : '';
                      return Padding(
                        padding: const EdgeInsets.only(right: 12),
                        child: SizedBox(
                          width: 84,
                          child: Column(
                            children: [
                              Container(
                                width: 84,
                                height: 112,
                                alignment: Alignment.center,
                                decoration: BoxDecoration(
                                  color: theme.surface,
                                  borderRadius: BorderRadius.circular(12),
                                  border: Border.all(
                                    color: theme.hairline,
                                  ),
                                ),
                                clipBehavior: Clip.antiAlias,
                                child: RefererImage(
                                  url: photo,
                                  width: 84,
                                  height: 112,
                                  fallback: Text(
                                    name.isEmpty ? '?' : name[0],
                                    style: TextStyle(
                                      color: theme.textMuted,
                                      fontSize: 28,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                ),
                              ),
                              const SizedBox(height: 6),
                              Text(
                                name,
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                                style: TextStyle(
                                  color: theme.textPrimary,
                                  fontSize: 12,
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
                ),
              ],
              const SizedBox(height: 32),
            ],
          ),
        ),
      ],
    );
  }
}

/// Clean cover hero (Infuse D1/D2): 16:9-ish backdrop, 46vh min 300px,
/// fading into the PAGE background (not a card). Back button top-left,
/// current episode chip bottom-left. NO centre play button.
class _CoverHero extends StatelessWidget {
  const _CoverHero({
    required this.pic,
    required this.epLabel,
  });

  final String pic;
  final String epLabel;

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
              fit: BoxFit.cover,
              fallback: _CoverFallback(theme: theme),
            )
          else
            _CoverFallback(theme: theme),
          // Fade into the page background (theme scaffold bg).
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
          Positioned(
            top: MediaQuery.of(context).padding.top + 8,
            left: 12,
            child: Container(
              decoration: BoxDecoration(
                color: const Color(0x66000000),
                shape: BoxShape.circle,
              ),
              child: IconButton(
                icon: const Icon(Icons.arrow_back, color: Colors.white),
                onPressed: () => Navigator.of(context).pop(),
              ),
            ),
          ),
          Positioned(
            left: 16,
            bottom: 12,
            child: Container(
              padding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 5,
              ),
              decoration: BoxDecoration(
                color: const Color(0xA6000000),
                borderRadius: BorderRadius.circular(8),
              ),
              child: Text(
                epLabel,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 13,
                  fontWeight: FontWeight.w600,
                ),
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
      // Theme glass, not a hardcoded dark tile (black hole in the
      // four light modes). The icon is theme-muted, legible in all
      // 8 combinations.
      color: theme.surfaceStrong,
      child: Center(
        child: Icon(Icons.movie, color: theme.textMuted, size: 64),
      ),
    );
  }
}

/// Meta line: ★ score (with 豆瓣 mark when from Douban) + year · type ·
/// area · runtime. Score keeps theme text + bold; the ★ uses accent.
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
              Icon(Icons.star, color: theme.accent, size: 16),
              const SizedBox(width: 2),
              Text(
                meta.score,
                style: TextStyle(
                  color: theme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                ),
              ),
              if (meta.douban?.score != null) ...[
                const SizedBox(width: 4),
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 4,
                    vertical: 1,
                  ),
                  decoration: BoxDecoration(
                    border: Border.all(color: theme.hairline),
                    borderRadius: BorderRadius.circular(4),
                  ),
                  child: Text(
                    '豆瓣',
                    style: TextStyle(
                      color: theme.textMuted,
                      fontSize: 10,
                    ),
                  ),
                ),
              ],
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
          icon,
          color: active ? theme.accent : theme.textSecondary,
        ),
      ),
    );
  }
}

/// Episode card (fix 17.6): numbered dark tile (16:9) + episode name.
/// No per-episode stills exist in CMS — the tile is a number, never
/// the same poster repeated.
class _EpisodeCard extends StatelessWidget {
  const _EpisodeCard({
    required this.index,
    required this.name,
    required this.selected,
    required this.onTap,
  });

  final int index;
  final String name;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return GestureDetector(
      onTap: onTap,
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
                borderRadius: BorderRadius.circular(12),
                border: Border.all(
                  color:
                      selected ? theme.accent : theme.hairline,
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

/// Skeleton shown while the first fetch runs — the preload cover +
/// title are already on screen instantly (fix 4).
class _DetailSkeleton extends StatelessWidget {
  const _DetailSkeleton({this.preload});

  final VideoItem? preload;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              SizedBox(
                height: (MediaQuery.of(context).size.height * 0.46)
                    .clamp(300.0, double.infinity),
                width: double.infinity,
                child: Stack(
                  fit: StackFit.expand,
                  children: [
                    if (preload != null && preload!.pic.isNotEmpty)
                      RefererImage(
                        url: preload!.pic,
                        fit: BoxFit.cover,
                        fallback: ColoredBox(
                          color: theme.surfaceStrong,
                        ),
                      )
                    else
                      ColoredBox(
                        color: theme.surfaceStrong,
                      ),
                    Container(
                      decoration: BoxDecoration(
                        gradient: LinearGradient(
                          begin: Alignment.topCenter,
                          end: Alignment.bottomCenter,
                          colors: [
                            const Color(0x47000000),
                            Colors.transparent,
                            theme.scaffoldBackground,
                          ],
                          stops: const [0.0, 0.45, 1.0],
                        ),
                      ),
                    ),
                    Positioned(
                      top: MediaQuery.of(context).padding.top + 8,
                      left: 12,
                      child: Container(
                        decoration: const BoxDecoration(
                          color: Color(0x66000000),
                          shape: BoxShape.circle,
                        ),
                        child: IconButton(
                          icon: const Icon(
                            Icons.arrow_back,
                            color: Colors.white,
                          ),
                          onPressed: () => Navigator.of(context).pop(),
                        ),
                      ),
                    ),
                  ],
                ),
              ),
              if (preload != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(
                    preload!.name,
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                child: Row(
                  children: [
                    const SizedBox(
                      width: 20,
                      height: 20,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      '正在加载影片详情…',
                      style: TextStyle(color: theme.textMuted),
                    ),
                  ],
                ),
              ),
            ],
          ),
        ),
      ],
    );
  }
}

/// Error card with retry (shows as soon as the race resolves empty,
/// ≤ ~4 s after open — never 12 s). Retry re-runs the whole race.
class _ErrorCard extends StatelessWidget {
  const _ErrorCard({required this.onRetry});

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
            Icon(
              Icons.cloud_off,
              size: 48,
              color: theme.textMuted,
            ),
            const SizedBox(height: 16),
            Text(
              '影片加载失败',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '视频源暂时无法访问，请检查网络后重试',
              textAlign: TextAlign.center,
              style: TextStyle(color: theme.textMuted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: const Icon(Icons.refresh),
              label: const Text('重试'),
              style: FilledButton.styleFrom(
                backgroundColor: theme.accent,
                // Theme-defined onPrimary per mode (see play button).
                foregroundColor:
                    Theme.of(context).colorScheme.onPrimary,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
