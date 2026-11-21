// Version picker (1.1.6, browse A3 §1 + §3) — bottom sheet, not a page.
//
// A poster tap on a multi-version group opens this sheet. It shows
// the versions ALREADY in the fetched list immediately (0 network),
// then streams in further versions from the same discovery layer
// the detail race and the player use (`VideoDetailService.findAlts`
// → `CmsClient.altSourcesStream`, same `normTitle|year` key). The
// scan never blocks a tap: the representative (highest score) is
// always tappable at once, and each alt appears the moment its detail
// resolves (3 s each). Closing the sheet cancels the scan.
//
// Boundaries (decided, do not re-open):
// - Single-version groups never open the sheet — the poster tap goes
//   straight to the detail page (old behaviour, zero extra taps).
// - Emby is not in v1 groups, so every row here is CMS. CMS rows
//   carry NO quality/volume/bitrate display (hard block H1) and no
//   quality badges: `remarks` is shown verbatim as "来源标注" only.
// - The spec filter chips (全部 / 4K / 杜比视界 / HDR) filter Emby
//   rows only; with CMS-only rows a spec filter hides everything and
//   says so honestly ("CMS 源无画质信息，已隐藏") instead of
//   inventing a 1080p label.
// - Alt details are fetched per alt (the list API has no line /
//   episode counts — U1-1: line counts are NOT shown in v1).

import 'dart:async';

import 'package:flutter/material.dart';
import '../../widgets/hao_pressable.dart';

import '../../core/theme/hao_radius.dart';
import '../../core/theme/hao_settle_spring.dart';
import '../../core/theme/hao_themes.dart';
import 'emby_spec.dart';
import 'video_detail_router.dart';
import 'video_detail_service.dart';
import 'video_history_store.dart';
import 'video_models.dart';
import 'video_smart_groups.dart';

/// Open a grouped poster: one version → straight to its detail page;
/// several → the version sheet. [detailService] is a test seam.
Future<void> openGroupedVideo(
  BuildContext context,
  GroupedVideoItem group, {
  VideoDetailService? detailService,
}) {
  if (group.isSingle) {
    final item = group.representative;
    return openVideoDetail<void>(
      context,
      source: item.source,
      vodId: item.vodId,
      preload: item,
      detailService: detailService,
    );
  }
  return showVideoVersionsSheet(
    context,
    group: group,
    detailService: detailService,
  );
}

Future<void> showVideoVersionsSheet(
  BuildContext context, {
  required GroupedVideoItem group,
  VideoDetailService? detailService,
}) {
  final theme = HaoTheme.of(context);
  return showModalBottomSheet<void>(
    context: context,
    isScrollControlled: true,
    // N-10: iOS grabber + settle-spring rise (same spring as the
    // player close).
    showDragHandle: true,
    sheetAnimationStyle: const AnimationStyle(
      curve: HaoSettleSpringCurve(),
      reverseCurve: HaoSettleSpringCurve(),
    ),
    backgroundColor: theme.surface,
    shape: const RoundedRectangleBorder(
      borderRadius: BorderRadius.vertical(
        top: Radius.circular(HaoRadius.sheet),
      ),
    ),
    builder: (sheetContext) => _VersionSheet(
      group: group,
      detailService: detailService,
      onSelect: (item) {
        Navigator.of(sheetContext).pop();
        unawaited(
          openVideoDetail<void>(
            context,
            source: item.source,
            vodId: item.vodId,
            preload: item,
            detailService: detailService,
          ),
        );
      },
    ),
  );
}

class _VersionSheet extends StatefulWidget {
  const _VersionSheet({
    required this.group,
    required this.onSelect,
    this.detailService,
  });

  final GroupedVideoItem group;
  final void Function(VideoItem item) onSelect;
  final VideoDetailService? detailService;

  @override
  State<_VersionSheet> createState() => _VersionSheetState();
}

class _VersionSheetState extends State<_VersionSheet> {
  /// Alt versions found by earlier scans, by group key (audit §1.4:
  /// "按 filmKey 缓存一次结果"). In-memory only — a cold start
  /// re-scans; the list is small and the scan is capped at 15 s.
  static final Map<String, List<VideoItem>> _altCache = {};

  late final VideoDetailService _service;
  late List<VideoItem> _versions;
  StreamSubscription<AltVideoSource>? _altSub;
  bool _scanning = true;
  EmbySpecFilter _filter = EmbySpecFilter.all;

  @override
  void initState() {
    super.initState();
    _service = widget.detailService ?? VideoDetailService();
    _versions = _withRepresentativeFirst(widget.group.versions);
    final cached = _altCache[widget.group.key];
    if (cached != null) {
      for (final item in cached) {
        if (!_versions.any((v) => v.identityKey == item.identityKey)) {
          _versions.add(item);
        }
      }
    }
    _scanAlts();
  }

  @override
  void dispose() {
    unawaited(_altSub?.cancel());
    super.dispose();
  }

  List<VideoItem> _withRepresentativeFirst(List<VideoItem> versions) {
    final rep = widget.group.representative;
    final rest = versions
        .where((v) => v.identityKey != rep.identityKey)
        .toList();
    return [rep, ...rest];
  }

  String _sourceName(dynamic source) {
    try {
      for (final s in VideoSourcesStore.getAll()) {
        if (s.idKey == source.toString()) return s.name;
      }
    } catch (_) {}
    return '';
  }

  void _scanAlts() {
    final rep = widget.group.representative;
    _altSub = _service
        .findAlts(rep.name, rep.year, rep.source)
        .listen(_onAlt, onDone: _onScanDone, onError: (_) => _onScanDone());
  }

  void _onScanDone() {
    if (mounted) setState(() => _scanning = false);
  }

  Future<void> _onAlt(AltVideoSource alt) async {
    final altKey = '${alt.source}|${alt.vodId}';
    if (_versions.any((v) => v.identityKey == altKey)) return;
    // The alt stream carries source+vodId only — one detail fetch
    // (3 s, cached by the service) turns it into a displayable row.
    VideoDetail detail;
    try {
      detail = await _service
          .get(alt.source, alt.vodId)
          .timeout(const Duration(seconds: 3));
    } catch (_) {
      return;
    }
    if (!mounted) return;
    final item = VideoItem(
      source: alt.source,
      sourceName: _sourceName(alt.source),
      vodId: alt.vodId,
      name: detail.meta.name,
      pic: detail.meta.pic,
      picAlt: detail.meta.picAlt,
      year: detail.meta.year,
      type: detail.meta.type,
      area: detail.meta.area,
      score: detail.meta.score,
      total: '${detail.totalEpisodes}',
      remarks: detail.meta.remarks,
    );
    if (_versions.any((v) => v.identityKey == item.identityKey)) return;
    setState(() => _versions.add(item));
    final key = widget.group.key;
    if (key.isNotEmpty) {
      final cached = _altCache[key] ?? <VideoItem>[];
      if (!cached.any((v) => v.identityKey == item.identityKey)) {
        cached.add(item);
        if (_altCache.length > 50 && !_altCache.containsKey(key)) {
          _altCache.remove(_altCache.keys.first);
        }
        _altCache[key] = cached;
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    // v1 groups are CMS-only: a spec filter hides every row and says
    // so (audit §3.3). An Emby row (facts-backed) would pass the
    // filter via `embySpecMatchesFilter` — there are none in v1.
    final visible = _filter == EmbySpecFilter.all ? _versions : const <VideoItem>[];
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
            child: Row(
              children: [
                Expanded(
                  child: Text(
                    widget.group.representative.name,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      color: theme.textPrimary,
                      fontSize: 20,
                      fontWeight: FontWeight.w800,
                      letterSpacing: -0.02,
                    ),
                  ),
                ),
                IconButton(
                  icon: Icon(Icons.close, color: theme.textMuted),
                  tooltip: '关闭',
                  onPressed: () => Navigator.of(context).pop(),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(
              '共 ${_versions.length} 个版本',
              style: TextStyle(color: theme.textMuted, fontSize: 13),
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Row(
              children: [
                for (final f in EmbySpecFilter.values)
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: ChoiceChip(
                      label: Text(f.label),
                      selected: _filter == f,
                      selectedColor: theme.accentSoft,
                      backgroundColor: theme.surface,
                      side: BorderSide(
                        color: _filter == f
                            ? theme.accent
                            : theme.hairline,
                      ),
                      labelStyle: TextStyle(
                        color: _filter == f
                            ? theme.accent
                            : theme.textSecondary,
                        fontWeight: _filter == f
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                      onSelected: (_) => setState(() => _filter = f),
                    ),
                  ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          Divider(height: 1, color: theme.hairline),
          Expanded(
            child: visible.isEmpty
                ? Center(
                    child: Padding(
                      padding: const EdgeInsets.all(24),
                      child: Text(
                        _filter == EmbySpecFilter.all
                            ? '没有可用版本'
                            : 'CMS 源无画质信息，已隐藏',
                        textAlign: TextAlign.center,
                        style: TextStyle(
                          color: theme.textMuted,
                          fontSize: 14,
                        ),
                      ),
                    ),
                  )
                : ListView.separated(
                    padding: const EdgeInsets.symmetric(vertical: 4),
                    itemCount: visible.length,
                    separatorBuilder: (_, _) =>
                        Divider(height: 1, color: theme.hairline),
                    itemBuilder: (context, i) {
                      final item = visible[i];
                      final isRep = i == 0;
                      final total = int.tryParse(item.total) ?? 0;
                      final metaParts = <String>[
                        if (item.year.isNotEmpty) item.year,
                        if (item.hasUsableScore) '★ ${item.score}',
                        if (total > 0) '共 $total 集',
                      ];
                      return HaoPressable(
                        onTap: () => widget.onSelect(item),
                        child: Padding(
                          padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
                          child: Row(
                            children: [
                              Expanded(
                                child: Column(
                                  crossAxisAlignment:
                                      CrossAxisAlignment.start,
                                  children: [
                                    Row(
                                      children: [
                                        Flexible(
                                          child: Text(
                                            item.sourceName.isNotEmpty
                                                ? item.sourceName
                                                : '源 ${item.sourceKey}',
                                            maxLines: 1,
                                            overflow: TextOverflow.ellipsis,
                                            style: TextStyle(
                                              color: theme.textPrimary,
                                              fontSize: 15,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ),
                                        if (isRep) ...[
                                          const SizedBox(width: 8),
                                          Text(
                                            '首选',
                                            style: TextStyle(
                                              color: theme.accent,
                                              fontSize: 12,
                                              fontWeight: FontWeight.w700,
                                            ),
                                          ),
                                        ],
                                      ],
                                    ),
                                    if (metaParts.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        metaParts.join(' · '),
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: theme.textMuted,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                    // remarks is source-supplied text,
                                    // shown verbatim as a source label —
                                    // never a quality badge (H1).
                                    if (item.remarks.isNotEmpty) ...[
                                      const SizedBox(height: 2),
                                      Text(
                                        '来源标注：${item.remarks}',
                                        maxLines: 1,
                                        overflow: TextOverflow.ellipsis,
                                        style: TextStyle(
                                          color: theme.textSecondary,
                                          fontSize: 13,
                                        ),
                                      ),
                                    ],
                                  ],
                                ),
                              ),
                              const SizedBox(width: 8),
                              Icon(
                                Icons.play_circle_outline,
                                color: theme.accent,
                                size: 28,
                              ),
                            ],
                          ),
                        ),
                      );
                    },
                  ),
          ),
          if (_scanning)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 16),
              child: Text(
                '正在查找更多版本…',
                style: TextStyle(color: theme.textMuted, fontSize: 12),
              ),
            ),
        ],
      ),
    );
  }
}
