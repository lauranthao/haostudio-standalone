// Video type page — one CMS type, filterable + paged.
//
// Port of `directVideoByType` + `loadVideoType` (app.js:1402, 3473):
// single source from the type map; filtered fetches (area≠all or
// year≠all) pull a 10-page CMS window and filter client-side; page
// count is divided by 10 when filtered. Only `by=hits|score` is
// passed through. Pager: 上一页 / 下一页 + x/y indicator.

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';
import 'package:glassy_ui_ios/glassy_ui_ios.dart';

import '../../core/theme/hao_themes.dart';
import '../../widgets/hao_glass_button.dart';
import '../../services/video/cms_client.dart';
import '../../services/video/poster_patch_service.dart';
import 'video_detail_service.dart';
import 'video_models.dart';
import 'video_poster_card.dart';
import 'video_smart_groups.dart';
import 'video_version_sheet.dart';

class VideoTypePage extends StatefulWidget {
  const VideoTypePage({super.key, required this.typeName});

  final String typeName;

  @override
  State<VideoTypePage> createState() => _VideoTypePageState();
}

class _VideoTypePageState extends State<VideoTypePage> {
  final _cms = CmsClient();
  final _detailService = VideoDetailService();
  final _posterPatch = PosterPatchService();

  List<VideoItem> _items = [];
  bool _loading = true;
  bool _failed = false;
  String? _error;
  int _page = 1;
  int _pagecount = 1;
  int _seq = 0;

  String _area = 'all';
  String _year = 'all';
  String _by = '';

  static const List<String> _areas = [
    'all',
    '大陆',
    '香港',
    '台湾',
    '美国',
    '韩国',
    '日本',
    '英国',
    'other',
  ];

  static const Map<String, String> _areaLabels = {
    'all': '全部地区',
    '大陆': '大陆',
    '香港': '香港',
    '台湾': '台湾',
    '美国': '美国',
    '韩国': '韩国',
    '日本': '日本',
    '英国': '英国',
    'other': '其他',
  };

  static const List<String> _years = [
    'all',
    '2026',
    '2025',
    '2024',
    '2023',
    '2022',
    'earlier',
  ];

  static const Map<String, String> _yearLabels = {
    'all': '全部年份',
    '2026': '2026',
    '2025': '2025',
    '2024': '2024',
    '2023': '2023',
    '2022': '2022',
    'earlier': '2021以前',
  };

  static const Map<String, String> _byLabels = {
    '': '默认排序',
    'hits': '最多播放',
    'score': '最高评分',
  };

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    final seq = ++_seq;
    setState(() {
      _loading = true;
      _failed = false;
    });
    VideoByTypeResult r;
    try {
      r = await _cms
          .byType(
            widget.typeName,
            _page,
            area: _area,
            year: _year,
            by: _by,
          )
          .timeout(const Duration(seconds: 25));
    } on TimeoutException {
      if (seq != _seq || !mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
      });
      return;
    } catch (e) {
      if (seq != _seq || !mounted) return;
      setState(() {
        _loading = false;
        _failed = true;
        _error = e.toString().contains('type not found') ? 'type not found' : null;
      });
      return;
    }
    if (seq != _seq || !mounted) return;
    setState(() {
      _loading = false;
      _items = r.items;
      _pagecount = r.pagecount;
    });
  }

  void _setFilter({String? area, String? year, String? by}) {
    final nextArea = area ?? _area;
    final nextYear = year ?? _year;
    final nextBy = by ?? _by;
    // Tapping the already-selected chip used to re-run _load (full
    // spinner + a network request for identical data). No-op instead.
    if (nextArea == _area && nextYear == _year && nextBy == _by) return;
    setState(() {
      _area = nextArea;
      _year = nextYear;
      _by = nextBy;
      _page = 1;
    });
    unawaited(_load());
  }

  void _setPage(int delta) {
    final next = _page + delta;
    if (next < 1 || next > _pagecount) return;
    setState(() => _page = next);
    unawaited(_load());
  }

  void _openDetail(VideoItem item) {
    // 1.1.6 Smart Groups: same film on one page shows one card; a
    // multi-version card opens the version sheet, a single version
    // goes straight to its detail page.
    GroupedVideoItem? group;
    for (final g in groupVideoItems(_items)) {
      if (g.representative.identityKey == item.identityKey) {
        group = g;
        break;
      }
    }
    unawaited(
      openGroupedVideo(
        context,
        group ??
            GroupedVideoItem(
              key: '',
              representative: item,
              versions: [item],
            ),
        detailService: _detailService,
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    // Grouped render: one card per film. Cached poster patches apply
    // to poster-less items (no network at render).
    final groups = groupVideoItems(
      _posterPatch.withCachedPatches(_items),
    );
    final representatives =
        groups.map((g) => g.representative).toList();
    return Scaffold(
      appBar: AppBar(
        title: Text(widget.typeName, style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
      ),
      body: Column(
        children: [
          // Filter bar (area / year / sort chips).
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 12, 12, 4),
            child: Row(
              children: [
                for (final a in _areas)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      label: Text(_areaLabels[a]!),
                      selected: _area == a,
                      selectedColor: theme.accentSoft,
                      backgroundColor: theme.surface,
                      side: BorderSide(
                        color: _area == a
                            ? theme.accent
                            : theme.hairline,
                      ),
                      labelStyle: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: _area == a
                            ? theme.accent
                            : theme.textSecondary,
                        fontWeight: _area == a
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                      onSelected: (_) => _setFilter(area: a),
                    ),
                  ),
              ],
            ),
          ),
          SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 4),
            child: Row(
              children: [
                for (final y in _years)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      label: Text(_yearLabels[y]!),
                      selected: _year == y,
                      selectedColor: theme.accentSoft,
                      backgroundColor: theme.surface,
                      side: BorderSide(
                        color: _year == y
                            ? theme.accent
                            : theme.hairline,
                      ),
                      labelStyle: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: _year == y
                            ? theme.accent
                            : theme.textSecondary,
                        fontWeight: _year == y
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                      onSelected: (_) => _setFilter(year: y),
                    ),
                  ),
                for (final b in _byLabels.keys)
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 3),
                    child: ChoiceChip(
                      label: Text(_byLabels[b]!),
                      selected: _by == b,
                      selectedColor: theme.accentSoft,
                      backgroundColor: theme.surface,
                      side: BorderSide(
                        color:
                            _by == b ? theme.accent : theme.hairline,
                      ),
                      labelStyle: TextStyle(
                        shadows: HaoTheme.legibilityShadows(context),
                        color: _by == b
                            ? theme.accent
                            : theme.textSecondary,
                        fontWeight: _by == b
                            ? FontWeight.w700
                            : FontWeight.w500,
                      ),
                      onSelected: (_) => _setFilter(by: b),
                    ),
                  ),
              ],
            ),
          ),
          // Hairline under the filters: separates controls from
          // results in every theme/mode (theme hairline, not grey).
          Divider(height: 1, color: theme.hairline),
          Expanded(
            child: _loading
                ? const Center(child: CupertinoActivityIndicator())
                : _failed
                    ? Center(
                        child: Column(
                          mainAxisSize: MainAxisSize.min,
                          children: [
                            Text(
                              _error == 'type not found'
                                  ? '该分类不存在'
                                  : '视频源暂时无法访问',
                              style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textPrimary),
                            ),
                            const SizedBox(height: 16),
                            HaoGlassButton(
                              label: '重试',
                              onPressed: _load,
                              style: NativeStyle(
                                tintColor: theme.accent,
                              ),
                              fallback: FilledButton(
                                onPressed: _load,
                                style: FilledButton.styleFrom(
                                  backgroundColor: theme.accent,
                                  // Theme-defined onPrimary per mode.
                                  foregroundColor: Theme.of(context)
                                      .colorScheme
                                      .onPrimary,
                                ),
                                child: const Text('重试'),
                              ),
                            ),
                          ],
                        ),
                      )
                    : _items.isEmpty
                        ? Center(
                            child: Text(
                              '没有影片',
                              style: TextStyle(shadows: HaoTheme.legibilityShadows(context), color: theme.textMuted),
                            ),
                          )
                        : CustomScrollView(
                            slivers: [
                              SliverPadding(
                                padding: const EdgeInsets.fromLTRB(
                                  14,
                                  12,
                                  14,
                                  8,
                                ),
                                sliver: SliverToBoxAdapter(
                                  child: VideoPosterGrid(
                                    items: representatives,
                                    onTapItem: _openDetail,
                                    onPointerDownItem: (item) =>
                                        _detailService.prefetch(
                                      item.source,
                                      item.vodId,
                                    ),
                                  ),
                                ),
                              ),
                              SliverToBoxAdapter(
                                child: Padding(
                                  padding: const EdgeInsets.symmetric(
                                    vertical: 16,
                                  ),
                                  child: Row(
                                    mainAxisAlignment:
                                        MainAxisAlignment.center,
                                    children: [
                                      OutlinedButton(
                                        onPressed: _page <= 1
                                            ? null
                                            : () => _setPage(-1),
                                        style: OutlinedButton.styleFrom(
                                          side: BorderSide(
                                            color: theme.hairline,
                                          ),
                                        ),
                                        child: Text('上一页', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
                                      ),
                                      Padding(
                                        padding: const EdgeInsets.symmetric(
                                          horizontal: 16,
                                        ),
                                        child: Text(
                                          '$_page/$_pagecount',
                                          style: TextStyle(
                                            shadows: HaoTheme.legibilityShadows(context),
                                            color: theme.textMuted,
                                            fontWeight: FontWeight.w600,
                                          ),
                                        ),
                                      ),
                                      OutlinedButton(
                                        onPressed: _page >= _pagecount
                                            ? null
                                            : () => _setPage(1),
                                        style: OutlinedButton.styleFrom(
                                          side: BorderSide(
                                            color: theme.hairline,
                                          ),
                                        ),
                                        child: Text('下一页', style: TextStyle(shadows: HaoTheme.legibilityShadows(context))),
                                      ),
                                    ],
                                  ),
                                ),
                              ),
                            ],
                          ),
          ),
        ],
      ),
    );
  }
}
