// 影视分类显示/隐藏/重排 (I-影视 item 10) — editor page.
//
// Home rows are CMS types (VideoHomeRow.name). This page edits the
// single persisted prefs (HiveKeys.vodCategoryPrefs, via
// vod_features.dart): hidden names + manual order. The home tab
// applies them in _patchedHome on every entry (the page rebuilds
// on each tab switch — no KeepAlive), so a change here shows on
// the next visit to the 影视 tab, with no app restart.
//
// Opened from Settings → 影视播放 → 影视分类排序. Every change
// persists immediately (no separate save button to forget).

import 'dart:async';

import 'package:flutter/cupertino.dart';
import 'package:flutter/material.dart';

import '../../core/player/vod_features.dart';
import '../../core/theme/hao_themes.dart';
import '../../core/theme/haptics.dart';
import '../../widgets/native_switch.dart';
import '../video/video_home_service.dart';
import '../../widgets/hao_nav_bar.dart';

class VideoCategoriesPage extends StatefulWidget {
  const VideoCategoriesPage({super.key});

  @override
  State<VideoCategoriesPage> createState() => _VideoCategoriesPageState();
}

class _VideoCategoriesPageState extends State<VideoCategoriesPage> {
  final _homeService = VideoHomeService();
  List<({String name, bool hidden})> _entries = const [];
  bool _loading = true;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    // Fetched names: the cached home rows first (no network on
    // entry); fall back to the type map when no cache exists.
    var names = _homeService.loadCached()?.rows.map((r) => r.name).toList() ??
        const <String>[];
    if (names.isEmpty) {
      try {
        names = await _homeService.typeNames();
      } catch (_) {
        names = const [];
      }
    }
    if (!mounted) return;
    setState(() {
      _entries = categoryEditorEntries(names, readCategoryPrefs());
      _loading = false;
    });
  }

  Future<void> _persist() async {
    final prefs = VideoCategoryPrefs(
      hidden: {for (final e in _entries) if (e.hidden) e.name},
      order: [for (final e in _entries) e.name],
    );
    await saveCategoryPrefs(prefs);
  }

  Future<void> _toggle(int index, bool hidden) async {
    HaoHaptics.select();
    setState(() {
      _entries = [
        for (var i = 0; i < _entries.length; i++)
          if (i == index)
            (name: _entries[i].name, hidden: hidden)
          else
            _entries[i],
      ];
    });
    await _persist();
  }

  Future<void> _reorder(int oldIndex, int newIndex) async {
    // onReorderItem already adjusts newIndex for the removed item.
    setState(() {
      final list = List.of(_entries);
      final item = list.removeAt(oldIndex);
      list.insert(newIndex, item);
      _entries = list;
    });
    await _persist();
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      appBar: HaoNavBar(
        title: '影视分类排序',
      ),
      body: _loading
          ? const Center(child: CupertinoActivityIndicator())
          : _entries.isEmpty
              ? Center(
                  child: Text(
                    '暂无分类，先打开一次影视页加载',
                    style: TextStyle(color: theme.textMuted),
                  ),
                )
              : Column(
                  children: [
                    Padding(
                      padding: const EdgeInsets.fromLTRB(16, 12, 16, 4),
                      child: Text(
                        '长按拖动排序；关闭的分类不在影视页显示。回到影视页即生效。',
                        style: TextStyle(
                          color: theme.textSecondary,
                          fontSize: 13,
                        ),
                      ),
                    ),
                    Expanded(
                      child: ReorderableListView.builder(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 8,
                          vertical: 8,
                        ),
                        itemCount: _entries.length,
                        onReorderItem: (oldIndex, newIndex) =>
                            unawaited(_reorder(oldIndex, newIndex)),
                        itemBuilder: (context, i) {
                          final entry = _entries[i];
                          // iOS 原生样式素行 (chen 铁律：不用 Material
                          // ListTile)。拖动排序机制仍用 ReorderableListView：
                          // Flutter 没有 Cupertino 版可重排列表。G 组已评估
                          // SwiftUI List 经 PlatformView 的方案：做不了——
                          // 拖拽态要逐帧过 MethodChannel 同步、行是 Flutter
                          // 玻璃行得在 SwiftUI 里重写一遍、VM 无 Xcode 验
                          // 不了；结论见 G 组汇报，本波留 Flutter 机制，
                          // 行样式已全是 iOS 原生（素行 + 三横线抓手）。
                          return Container(
                            key: ValueKey(entry.name),
                            padding: const EdgeInsets.symmetric(
                              horizontal: 16,
                              vertical: 12,
                            ),
                            child: Row(
                              children: [
                                Expanded(
                                  child: Text(
                                    entry.name,
                                    style: TextStyle(
                                      color: entry.hidden
                                          ? theme.textMuted
                                          : theme.textPrimary,
                                      fontSize: 16,
                                    ),
                                  ),
                                ),
                                HaoNativeSwitch(
                                  value: !entry.hidden,
                                  onChanged: (v) =>
                                      unawaited(_toggle(i, !v)),
                                  activeColor: theme.accent,
                                  semanticsLabel: entry.name,
                                ),
                                const SizedBox(width: 12),
                                // G-设置 (Wave 2): iOS reorder grip
                                // (three horizontal lines, the
                                // UITableView edit-mode grip) — the
                                // old Material drag_handle is gone.
                                // The drag itself is still
                                // ReorderableListView (see below).
                                Icon(
                                  CupertinoIcons.line_horizontal_3,
                                  color: theme.textMuted,
                                ),
                              ],
                            ),
                          );
                        },
                      ),
                    ),
                  ],
                ),
    );
  }
}

/// Visible-category helper for tests / callers that only need the
/// names: fetched names minus hidden, in manual order.
List<String> visibleCategoryNames(
  List<String> fetchedNames,
  VideoCategoryPrefs prefs,
) =>
    categoryEditorEntries(fetchedNames, prefs)
        .where((e) => !e.hidden)
        .map((e) => e.name)
        .toList();
