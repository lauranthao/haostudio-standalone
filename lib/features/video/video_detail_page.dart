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
// - 1.1.6 缺集接续: the episode row merges the current line with the
//   episodes only other sources carry (exact episode number, never a
//   title guess). A missing chip is greyed with an "其他源" badge;
//   tapping it switches to the source carrying that episode and
//   plays it from 0 (a vanished target toasts and stays put — never
//   a wrong episode).
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

import '../../core/theme/hao_radius.dart';
import 'dart:async';
import 'dart:ui' as ui;

import 'package:dio/dio.dart';
import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/player/vod_features.dart';
import '../../core/theme/glass.dart';
import '../../core/theme/hao_themes.dart';
import '../../services/video/cms_client.dart';
import '../../services/video/douban_parsers.dart';
import '../../services/video/douban_service.dart';
import '../../services/video/poster_patch_service.dart';
import '../../widgets/glass_dialog.dart';
import '../../widgets/hao_nav_bar.dart';
import 'missing_episode_chips.dart';
import 'native_video_player_page.dart';
import 'skip_intro_dialog.dart';
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

/// Alt-source DETAILS for the missing-episode union, streamed
/// fastest-first (see [CmsClient.altDetailsStream]): each alt's parsed
/// detail is yielded the moment it is fetched, dead sources skipped
/// silently — the episode row never waits on the whole scan.
typedef AltDetailsStreamer = Stream<VideoDetail> Function(
  String title,
  String year,
  dynamic excludeSourceId, {
  CancelToken? cancelToken,
});

class VideoDetailPage extends StatefulWidget {
  const VideoDetailPage({
    super.key,
    required this.sourceId,
    required this.vodId,
    this.preload,
    this.autoResume = false,
    this.startEpName,
    this.detailService,
    this.altDetails,
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

  /// 1.1.6 下一集: open at the episode with this exact name and
  /// auto-play it from 0 (the 下一集 card). A name that is not in
  /// these lines falls back to the normal open — never a guessed
  /// index, never the previous episode's position.
  final String? startEpName;

  /// Test seam only: an injected [VideoDetailService] (canned fetch in
  /// render tests). Null in production — the page owns a fresh one.
  final VideoDetailService? detailService;

  /// Test seam only: alt-source details for the missing-episode union
  /// (canned stream in tests). Null in production — the page owns a
  /// [CmsClient] stream.
  final AltDetailsStreamer? altDetails;

  @override
  State<VideoDetailPage> createState() => _VideoDetailPageState();
}

class _VideoDetailPageState extends State<VideoDetailPage> {
  late final VideoDetailService _detailService =
      widget.detailService ?? VideoDetailService();
  final _douban = DoubanService();
  final _posterPatch = PosterPatchService();
  late final AltDetailsStreamer _altDetailsStreamer = widget.altDetails ??
      ((title, year, exclude, {cancelToken}) => CmsClient().altDetailsStream(
            title,
            year,
            exclude,
            cancelToken: cancelToken,
          ));

  /// Cancels the in-flight detail race when the page is left
  /// (V-P1-4): without it the CMS requests run on to their 8 s
  /// timeouts after the user has already gone. A cancellation is
  /// never recorded as a source failure.
  final _loadToken = CancelToken();

  /// Multi-source episode union (1.1.6 缺集接续): alt details arrive
  /// streaming from [CmsClient.altDetailsStream] and each one extends
  /// the union; the episode row re-renders with missing chips as they
  /// land. Cancelled when the page leaves or a new detail applies.
  CancelToken? _unionCancel;
  StreamSubscription<VideoDetail>? _unionSub;
  List<VideoDetail> _altDetails = const [];
  Map<int, EpisodeUnionTarget> _union = const {};

  @override
  void dispose() {
    _loadToken.cancel();
    _unionSub?.cancel();
    _unionCancel?.cancel();
    super.dispose();
  }

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
  // I-影视 item 5 (防剧透): prefs read once in initState; reveal
  // flags are per-detail (reset in _applyDetail).
  bool _spoilerHideSynopsis = false;
  bool _spoilerBlurUnwatched = false;
  bool _synRevealed = false;
  bool _coverRevealed = false;
  // I-影视 item 4 (元数据手动纠错): the source values before any
  // override, so "恢复默认" can put them back (Douban enrichment
  // mutates the same meta object afterwards, so the pristine
  // values live here, not on the meta).
  String _origTitle = '';
  String _origYear = '';
  String _origPoster = '';
  bool _fadedIn = false;
  bool _autoResumeDone = false;

  dynamic get _sid => _detailSourceId ?? widget.sourceId;
  String get _vid => _detailVodId.isEmpty ? widget.vodId : _detailVodId;

  @override
  void initState() {
    super.initState();
    _detailSourceId = widget.sourceId;
    _detailVodId = widget.vodId;
    _spoilerHideSynopsis = vodSpoilerHideSynopsis();
    _spoilerBlurUnwatched = vodSpoilerBlurUnwatched();
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
      cancelToken: _loadToken,
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
    // The detail we switch away from stays a playable source for
    // the episodes the new base lacks — the union scan keeps it.
    final previousDetail = _detail;
    // P1-15: the winning source's own resume key first; when the
    // detail race switched sources, that key does not exist yet, so
    // fall back to the film-level row (title + year, any source)
    // mapped onto THESE lines by episode name.
    final resume =
        VideoHistoryStore.loadResume(sourceId, vodId, detail.lines) ??
        VideoHistoryStore.loadResumeForFilm(
          title: detail.meta.name,
          year: detail.meta.year,
          lines: detail.lines,
        );
    // Film-level lookup: the same film watched on another source still
    // resumes at its latest episode (history dedups by film, not by
    // source+vodId). Year-qualified so a remake never resumes into
    // the original's episode.
    final hist = VideoHistoryStore.findByTitle(
      detail.meta.name,
      year: detail.meta.year,
    );
    final favItem = VideoItem(
      source: sourceId,
      sourceName: detail.meta.name,
      vodId: vodId,
      name: detail.meta.name,
      pic: detail.meta.pic,
      year: detail.meta.year,
    );
    // 1.1.6 下一集: open at the episode with this exact name and
    // play it from 0. A name that is not in these lines falls back
    // to the normal open (never a guessed index).
    final start = widget.startEpName != null
        ? findEpisodeByName(detail.lines, widget.startEpName!)
        : null;
    final clamped = start != null
        ? (lineIdx: start.lineIdx, epIdx: start.epIdx)
        : clampDetailIndices(
            detail.lines,
            resume?.lineIdx ?? hist?.lineIdx ?? 0,
            resume?.epIdx ?? hist?.epIdx ?? 0,
          );
    // I-影视 item 4: manual metadata correction — capture the
    // pristine source values first, then apply the local override
    // in place BEFORE the first paint (it wins over the CMS
    // values; _enrichDouban below re-applies it after the Douban
    // merge, so it wins there too).
    _origTitle = detail.meta.name;
    _origYear = detail.meta.year;
    _origPoster = detail.meta.pic;
    applyMetadataOverrideInPlace(
      detail.meta,
      metadataOverrideFor(sourceId, vodId),
    );
    setState(() {
      _detail = detail;
      _detailSourceId = sourceId;
      _detailVodId = vodId;
      _loading = false;
      _failed = false;
      _lineIdx = clamped.lineIdx;
      _epIdx = clamped.epIdx;
      // A start episode plays from 0: the saved resume belongs to a
      // different episode and must not leak its position in.
      _resume = start != null ? null : resume;
      _watched = hist != null;
      _epsExpanded = false;
      _isFav = VideoHistoryStore.isFav(favItem);
      _synRevealed = false;
      _coverRevealed = false;
    });
    // Douban enrichment AFTER the CMS render — never blocks it.
    unawaited(_enrichDouban(detail));
    // Missing-episode union: alt details stream in after the render
    // (never blocking it) and missing chips appear as they land.
    _startUnionScan(detail, previousBase: previousDetail);
    // History resume (V-P0-1): open the player at the saved position
    // once, only when a resume exists. No resume -> stay on the page.
    // A start episode auto-plays regardless of any resume.
    if ((widget.autoResume && resume != null || start != null) &&
        !_autoResumeDone) {
      _autoResumeDone = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) unawaited(_play());
      });
    }
  }

  Future<void> _enrichDouban(VideoDetail detail) async {
    if (detail.meta.douban != null) return;
    final dd = await _douban.detail(detail.meta.name, detail.meta.year);
    // Only merge if this detail is still on screen.
    if (!mounted || _detail != detail) return;
    if (dd == null) {
      // Douban failed: fallback poster (Bangumi → Bilibili PGC),
      // cached for the wall. A miss keeps the CMS poster — never an
      // error, never a retry storm (failures cache 1 h).
      final patched =
          await _posterPatch.patchFor(detail.meta.name, detail.meta.year);
      if (patched != null && mounted && _detail == detail) {
        setState(() {
          detail.meta.pic = patched;
        });
        // I-影视 item 4: a user-corrected poster still wins over
        // the patched one.
        applyMetadataOverrideInPlace(
          detail.meta,
          metadataOverrideFor(_detailSourceId, _detailVodId),
        );
        if (mounted) setState(() {});
      }
      return;
    }
    setState(() {
      mergeDoubanIntoMeta(detail.meta, dd);
    });
    // I-影视 item 4: re-apply after the Douban merge — a manual
    // correction wins over Douban too (title / year / poster).
    applyMetadataOverrideInPlace(
      detail.meta,
      metadataOverrideFor(_detailSourceId, _detailVodId),
    );
    if (mounted) setState(() {});
  }

  /// Start (or restart) the missing-episode union scan for [base]:
  /// the previous scan is cancelled, the union is rebuilt from the
  /// new base plus every alt detail known so far, and the stream
  /// appends further alts as they arrive — one setState per alt, so
  /// missing chips appear progressively, never after a long wait.
  /// No parseable episode numbers anywhere in the base (a movie's
  /// single 正片): the union is empty by construction, so no scan
  /// and no network at all.
  void _startUnionScan(VideoDetail base, {VideoDetail? previousBase}) {
    unawaited(_unionSub?.cancel());
    _unionCancel?.cancel();
    final token = _unionCancel = CancelToken();
    // The detail we just switched away from is still a playable
    // source for the episodes the new base lacks — keep it in the
    // union so the user can switch back through a missing chip.
    final known = <VideoDetail>[
      if (previousBase != null && !identical(previousBase, base))
        previousBase,
    ];
    _altDetails = known;
    _union = buildEpisodeUnion(base: base, alts: known);
    final hasNumbered = base.lines
        .expand((l) => l.episodes)
        .any((e) => e.episodeNumber != null);
    if (!hasNumbered) return;
    _unionSub = _altDetailsStreamer(
      base.meta.name,
      base.meta.year,
      base.source,
      cancelToken: token,
    ).listen(
      (alt) {
        if (!mounted || _detail != base || token.isCancelled) return;
        final key = '${alt.source}|${alt.vodId}';
        if (_altDetails.any((d) => '${d.source}|${d.vodId}' == key)) {
          return;
        }
        setState(() {
          _altDetails = [..._altDetails, alt];
          _union = buildEpisodeUnion(base: base, alts: _altDetails);
        });
      },
      onError: (_) {},
      cancelOnError: false,
    );
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
    // P2-2: the resume text is only true for the episode the resume
    // points at. Switching line / tapping another episode card moves
    // _lineIdx/_epIdx without clearing _resume, so an unguarded label
    // would show the old episode's time next to the new episode's
    // name. No match -> plain episode name, never a stale time.
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

  /// Play a missing episode: switch the page to the alt detail that
  /// carries this exact episode number and play it from 0. The
  /// number is resolved with [findEpisodeByNumber] against the alt
  /// detail's lines at tap time — never by title, never a neighbour
  /// episode. When no alt carries it any more, toast and stay put:
  /// never play a wrong episode.
  Future<void> _playMissingEpisode(
    int episodeNumber,
    EpisodeUnionTarget target,
  ) async {
    VideoDetail? alt;
    for (final d in _altDetails) {
      if (d.source == target.source && d.vodId == target.vodId) {
        alt = d;
        break;
      }
    }
    final found =
        alt == null ? null : findEpisodeByNumber(alt.lines, episodeNumber);
    if (alt == null || found == null) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('该集暂无可播片源')),
      );
      return;
    }
    // Suppress _applyDetail's auto-play: we play the tapped episode
    // explicitly below, and its own resume must not leak in either.
    _autoResumeDone = true;
    _applyDetail(alt, target.source, target.vodId);
    if (!mounted) return;
    setState(() {
      _lineIdx = found.lineIdx;
      _epIdx = found.epIdx;
      _resume = null;
    });
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('已切换片源播放第$episodeNumber集')),
    );
    await _play(found.lineIdx, found.epIdx);
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

  /// Manual metadata correction (I-影视 item 4): title / year /
  /// poster, local override only. An empty field keeps the source
  /// value (never blanks it). "恢复默认" clears the override and
  /// restores the pristine source values (Douban poster when the
  /// enrichment already landed, else the CMS poster). Douban stays
  /// the only metadata source — no TMDB anywhere.
  Future<void> _showMetadataCorrection() async {
    final d = _detail;
    if (d == null) return;
    final theme = HaoTheme.of(context);
    final titleCtrl = TextEditingController(text: d.meta.name);
    final yearCtrl = TextEditingController(text: d.meta.year);
    final posterCtrl = TextEditingController(text: d.meta.pic);
    final saved = await showGlassDialog<bool>(
      context,
      builder: (ctx) {
        Widget field(
          TextEditingController ctrl,
          String label,
          String hint,
        ) {
          return Padding(
            padding: const EdgeInsets.only(top: 12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  label,
                  style: TextStyle(
                    color: theme.textSecondary,
                    fontSize: 13,
                  ),
                ),
                const SizedBox(height: 4),
                // iOS 原生输入框 (chen 铁律：新增界面一律 Cupertino，
                // 不用 Material TextField)。
                CupertinoTextField(
                  controller: ctrl,
                  style: TextStyle(color: theme.textPrimary),
                  placeholder: hint,
                  placeholderStyle: TextStyle(color: theme.textMuted),
                  padding: const EdgeInsets.symmetric(
                    horizontal: 10,
                    vertical: 8,
                  ),
                  decoration: BoxDecoration(
                    color: theme.surface,
                    border: Border.all(color: theme.hairline),
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
              ],
            ),
          );
        }

        return Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: [
            Text(
              '纠错',
              style: TextStyle(
                color: theme.textPrimary,
                fontSize: 17,
                fontWeight: FontWeight.w700,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              '只改本地显示，不改片源；留空保持原值。',
              style: TextStyle(color: theme.textSecondary, fontSize: 13),
            ),
            field(titleCtrl, '标题', d.meta.name),
            field(yearCtrl, '年份', d.meta.year),
            field(posterCtrl, '海报链接', d.meta.pic),
            const SizedBox(height: 16),
            Row(
              children: [
                Expanded(
                  // iOS 原生按钮 (chen 铁律：不用 Material
                  // OutlinedButton / FilledButton)。
                  child: CupertinoButton(
                    onPressed: () => Navigator.of(ctx).pop(false),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: const Text('恢复默认'),
                  ),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: CupertinoButton.filled(
                    onPressed: () => Navigator.of(ctx).pop(true),
                    padding: const EdgeInsets.symmetric(vertical: 10),
                    child: const Text('保存'),
                  ),
                ),
              ],
            ),
          ],
        );
      },
    );
    if (saved == null || !mounted) return;
    final detail = _detail;
    if (detail == null) return;
    // Empty field = "no correction for this field" = restore the
    // source value (not "keep whatever the last correction set":
    // clearing a corrected title must put the original back).
    // The recompute below runs for both 保存 and 恢复默认 — the
    // only difference is which override was persisted.
    final override = saved
        ? VodMetadataOverride(
            title: titleCtrl.text.trim().isEmpty
                ? null
                : titleCtrl.text.trim(),
            year: yearCtrl.text.trim().isEmpty
                ? null
                : yearCtrl.text.trim(),
            poster: posterCtrl.text.trim().isEmpty
                ? null
                : posterCtrl.text.trim(),
          )
        : const VodMetadataOverride();
    await saveMetadataOverride(
      source: _detailSourceId,
      vodId: _detailVodId,
      override: override,
    );
    if (!mounted) return;
    setState(() {
      detail.meta.name = override.title ?? _origTitle;
      detail.meta.year = override.year ?? _origYear;
      final doubanPoster = detail.meta.douban?.poster ?? '';
      detail.meta.pic = override.poster ??
          (doubanPoster.isNotEmpty ? doubanPoster : _origPoster);
    });
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final preload = widget.preload;
    return Scaffold(
      // Fixed back button over the body: the hero's own button lived
      // inside the scrolling cover, so once the user scrolled down
      // (and always in the load-failed card) there was no visible
      // exit — only the edge swipe. One pinned button covers every
      // state (loading / loaded / failed) at any scroll offset.
      body: Stack(
        children: [
          AnimatedOpacity(
            opacity: _fadedIn ? 1 : 0,
            duration: const Duration(milliseconds: 350),
            child: _failed
                ? _ErrorCard(onRetry: _load)
                : _loading && _detail == null
                    ? _DetailSkeleton(preload: preload)
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
    final castNames = m.castNames;
    final castPhotos = m.douban?.castPhotos ?? const [];
    final genreChips = m.genreChips;
    final lines = d.lines;
    final episodes = lines[_lineIdx].episodes;
    // 1.1.6 缺集接续: the row merges the current line with the
    // missing episodes other sources carry (exact number match).
    // Present chips keep their shape, order and tap behaviour;
    // missing chips are greyed with an "其他源" badge.
    final chips = mergeEpisodeChips(base: episodes, union: _union);
    const epCap = 12;
    final showAll = _epsExpanded || chips.length <= epCap;
    final shown = showAll ? chips : chips.sublist(0, epCap);

    return CustomScrollView(
      slivers: [
        SliverToBoxAdapter(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              // --- Clean COVER top (Infuse hero) ---
              // No centre play button anywhere on the cover, and no
              // episode pill on it either — the big play button below
              // already names the episode.
              // I-影视 item 5: spoiler blur — an unwatched title's
              // cover is blurred until tapped (watched titles are
              // never blurred; episode cards carry no stills, so
              // the cover is the only thumbnail that exists).
              if (_spoilerBlurUnwatched && !_watched && !_coverRevealed)
                Stack(
                  children: [
                    ImageFiltered(
                      imageFilter: ui.ImageFilter.blur(
                        sigmaX: 18,
                        sigmaY: 18,
                      ),
                      child: _CoverHero(pic: m.pic),
                    ),
                    Positioned.fill(
                      child: Center(
                        // iOS 原生按钮 (chen 铁律：不用 Material
                        // FilledButton)。
                        child: CupertinoButton.filled(
                          onPressed: () =>
                              setState(() => _coverRevealed = true),
                          child: const Row(
                            mainAxisSize: MainAxisSize.min,
                            children: [
                              Icon(Icons.visibility),
                              SizedBox(width: 6),
                              Text('点按查看海报'),
                            ],
                          ),
                        ),
                      ),
                    ),
                  ],
                )
              else
                _CoverHero(pic: m.pic),
              // --- Big blue play button below the cover ---
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
                      // onPrimary is theme-defined per mode: white on
                      // the dark-mode light-gold / light-teal /
                      // light-blue accents is unreadable, near-black
                      // on them is not.
                      foregroundColor:
                          Theme.of(context).colorScheme.onPrimary,
                      padding: const EdgeInsets.symmetric(vertical: 16),
                      // Rounded rectangle (14px), NOT a pill (Infuse D5).
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
              // --- Meta: left-aligned title + meta line ---
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      m.name,
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
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
                                    shadows: HaoTheme.legibilityShadows(context),
                                    color: theme.textMuted,
                                    fontSize: 13,
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
                          shadows: HaoTheme.legibilityShadows(context),
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
                          shadows: HaoTheme.legibilityShadows(context),
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
                        const SizedBox(width: 12),
                        // I-影视 item 4: manual metadata correction
                        // (title / year / poster, local only).
                        _CircleAction(
                          icon: Icons.edit,
                          active: false,
                          tooltip: '纠错',
                          onTap: () => unawaited(_showMetadataCorrection()),
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
                            shadows: HaoTheme.legibilityShadows(context),
                            color: selected
                                ? theme.accent
                                : theme.textSecondary,
                            fontWeight: selected
                                ? FontWeight.w600
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
                        shadows: HaoTheme.legibilityShadows(context),
                        color: theme.textPrimary,
                        fontSize: 20,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                    const Spacer(),
                    Text(
                      '(${chips.length})',
                      style: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
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
                    final chip = shown[i];
                    if (chip.isMissing) {
                      final num = chip.episodeNumber!;
                      return Padding(
                        padding: const EdgeInsets.only(right: 10),
                        child: _EpisodeCard(
                          number: num.toString().padLeft(2, '0'),
                          name: '第$num集',
                          selected: false,
                          missing: true,
                          onTap: () =>
                              _playMissingEpisode(num, chip.target!),
                        ),
                      );
                    }
                    final epIdx = chip.epIdx!;
                    final selected = epIdx == _epIdx;
                    final ep = episodes[epIdx];
                    // Big number = the episode's own number when it has
                    // one (a gapped line's 第4集 is `04`, not its row
                    // position `03` — with missing chips merged in, a
                    // position number would collide with the missing
                    // chip's number); unparseable names (正片/花絮)
                    // keep the old position number.
                    final numText = (ep.episodeNumber ?? (epIdx + 1))
                        .toString()
                        .padLeft(2, '0');
                    return Padding(
                      padding: const EdgeInsets.only(right: 10),
                      child: _EpisodeCard(
                        number: numText,
                        name: ep.name,
                        selected: selected,
                        onTap: () => _play(_lineIdx, epIdx),
                        // Long-press: per-episode custom skip-intro
                        // seconds (1.1.6, CMS has no markers).
                        onLongPress: () => unawaited(
                          showSkipIntroDialog(
                            context,
                            title: m.name,
                            episodeName: ep.name,
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
                      style: OutlinedButton.styleFrom(
                        side: BorderSide(color: theme.hairline),
                        foregroundColor: theme.accent,
                      ),
                      child: Text('加载更多 (${chips.length - epCap})', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
                    ),
                  ),
                ),
              // --- Synopsis ---
              // I-影视 item 5: spoiler hide — the synopsis is
              // replaced by a placeholder until the user taps to
              // reveal it (per detail load; the reveal never
              // persists — the next visit hides it again).
              if (m.plainContent.isNotEmpty &&
                  _spoilerHideSynopsis &&
                  !_synRevealed) ...[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 20, 16, 0),
                  child: Row(
                    children: [
                      Icon(
                        Icons.visibility_off,
                        size: 18,
                        color: theme.textMuted,
                      ),
                      const SizedBox(width: 8),
                      Expanded(
                        child: Text(
                          '简介已隐藏（防剧透）',
                          style: TextStyle(
                            shadows: HaoTheme.legibilityShadows(context),
                            color: theme.textSecondary,
                            fontSize: 15,
                          ),
                        ),
                      ),
                      // iOS 原生按钮 (chen 铁律：不用 Material TextButton)。
                      CupertinoButton(
                        onPressed: () =>
                            setState(() => _synRevealed = true),
                        padding: EdgeInsets.zero,
                        child: const Text('查看简介'),
                      ),
                    ],
                  ),
                ),
              ] else if (m.plainContent.isNotEmpty) ...[
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
                          shadows: HaoTheme.legibilityShadows(context),
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
                          child: Text(_synExpanded ? '收起' : '展开全文', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
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
                      shadows: HaoTheme.legibilityShadows(context),
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
                                  borderRadius: BorderRadius.circular(HaoRadius.large),
                                  border: Border.all(
                                    color: theme.hairline,
                                  ),
                                ),
                                clipBehavior: Clip.antiAlias,
                                // No manual width/height (G-P1-2):
                                // RefererImage sizes itself from the
                                // 84×112 layout constraints now, so
                                // one sizing path exists, not two.
                                child: RefererImage(
                                  url: photo,
                                  fallback: Text(
                                    name.isEmpty ? '?' : name[0],
                                    style: TextStyle(
                                      shadows: HaoTheme.legibilityShadows(context),
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
                                  shadows: HaoTheme.legibilityShadows(context),
                                  color: theme.textPrimary,
                                  fontSize: 13,
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
  const _CoverHero({required this.pic});

  final String pic;

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
        child: Icon(shadows: HaoTheme.legibilityShadows(context), Icons.movie, color: theme.textMuted, size: 64),
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
              Icon(shadows: HaoTheme.legibilityShadows(context), Icons.star, color: theme.accent, size: 16),
              const SizedBox(width: 2),
              Text(
                meta.score,
                style: TextStyle(
                  shadows: HaoTheme.legibilityShadows(context),
                  color: theme.textPrimary,
                  fontSize: 14,
                  fontWeight: FontWeight.w600,
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
                    borderRadius: BorderRadius.circular(HaoRadius.badge),
                  ),
                  child: Text(
                    '豆瓣',
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
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
            style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textMuted, fontSize: 14),
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
          shadows: HaoTheme.legibilityShadows(context),
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
    required this.number,
    required this.name,
    required this.selected,
    required this.onTap,
    this.onLongPress,
    this.missing = false,
  });

  /// Big tile number: base episodes show their episode number when
  /// it parses (else their row position), missing episodes their
  /// exact episode number.
  final String number;
  final String name;
  final bool selected;
  final VoidCallback onTap;
  final VoidCallback? onLongPress;

  /// Missing-episode chip: greyed (muted name) + an "其他源" badge.
  /// Present episodes never set this — their shape is untouched.
  final bool missing;

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
            Stack(
              children: [
                Container(
                  width: 128,
                  height: 72,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(
                    color: selected ? theme.accentSoft : theme.surface,
                    borderRadius: BorderRadius.circular(HaoRadius.large),
                    border: Border.all(
                      color:
                          selected ? theme.accent : theme.hairline,
                      width: selected ? 1.5 : 1,
                    ),
                  ),
                  child: Text(
                    number,
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: selected ? theme.accent : theme.textMuted,
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
                if (missing)
                  Positioned(
                    top: 6,
                    right: 6,
                    child: Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 6,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: theme.surface,
                        borderRadius: BorderRadius.circular(999),
                        border: Border.all(color: theme.hairline),
                      ),
                      child: Text(
                        '其他源',
                        style: TextStyle(
                          shadows: HaoTheme.legibilityShadows(context),
                          color: theme.textMuted,
                          fontSize: 10,
                          fontWeight: FontWeight.w600,
                        ),
                      ),
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 6),
            Text(
              name,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                shadows: HaoTheme.legibilityShadows(context),
                color: selected
                    ? theme.accent
                    : missing
                        ? theme.textMuted
                        : theme.textPrimary,
                fontSize: 13,
                fontWeight:
                    selected ? FontWeight.w600 : FontWeight.w400,
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
                  ],
                ),
              ),
              if (preload != null)
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 16, 16, 0),
                  child: Text(
                    preload!.name,
                    style: TextStyle(
                      shadows: HaoTheme.legibilityShadows(context),
                      color: theme.textPrimary,
                      fontSize: 30,
                      fontWeight: FontWeight.w800,
                    ),
                  ),
                ),
              Padding(
                padding: const EdgeInsets.fromLTRB(16, 24, 16, 0),
                child: const SizedBox(
                  width: 20,
                  height: 20,
                  child: CupertinoActivityIndicator(),
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
              shadows: HaoTheme.legibilityShadows(context),
              Icons.cloud_off,
              size: 48,
              color: theme.textMuted,
            ),
            const SizedBox(height: 16),
            Text(
              '影片加载失败',
              style: TextStyle(
                shadows: HaoTheme.legibilityShadows(context),
                color: theme.textPrimary,
                fontSize: 18,
                fontWeight: FontWeight.w600,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              '视频源暂时无法访问，请检查网络后重试',
              textAlign: TextAlign.center,
              style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textMuted),
            ),
            const SizedBox(height: 20),
            FilledButton.icon(
              onPressed: onRetry,
              icon: Icon(Icons.refresh, shadows: HaoTheme.legibilityShadows(context),),
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
