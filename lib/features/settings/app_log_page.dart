// In-app runtime log viewer (chen 2026-11-20, Beans 日志 page).
//
// Settings → 日志. Title 日志, 完成 top-left closes the page, share
// top-right exports the visible (filtered) entries as a .txt file,
// delete top-right clears the log (glass confirm first). Filter tabs
// 全部 / DEBUG / INFO / WARN / ERROR; newest first; one card per entry
// with a level badge + message + timestamp.
//
// Live updates: new entries rebuild the list only while the user is at
// the top; scrolled down, a "有新日志" pill appears instead (tapping it
// jumps to the top) so reading never jumps under the finger.

import '../../core/theme/hao_radius.dart';
import 'dart:convert';

import 'package:flutter/material.dart';
import '../../widgets/hao_pressable.dart';
import 'package:get/get.dart';
import '../../widgets/hao_toast.dart';
import 'package:share_plus/share_plus.dart';

import '../../core/logging/app_log.dart';
import '../../core/theme/hao_themes.dart';
import '../../widgets/glass_dialog.dart';

class AppLogPage extends StatefulWidget {
  const AppLogPage({super.key, this.onShare});

  /// Test seam: replaces the platform share sheet. Receives the
  /// filtered export text. Defaults to sharing a .txt via share_plus.
  final Future<void> Function(String text)? onShare;

  @override
  State<AppLogPage> createState() => _AppLogPageState();
}

class _AppLogPageState extends State<AppLogPage> {
  AppLogLevel? _filter;
  final ScrollController _scrollController = ScrollController();
  var _atTop = true;
  var _hasNew = false;

  @override
  void initState() {
    super.initState();
    _scrollController.addListener(_onScroll);
    AppLog.version.addListener(_onLogChanged);
  }

  @override
  void dispose() {
    _scrollController.removeListener(_onScroll);
    _scrollController.dispose();
    AppLog.version.removeListener(_onLogChanged);
    super.dispose();
  }

  void _onScroll() {
    if (!_scrollController.hasClients) return;
    final atTop = _scrollController.offset <= 1;
    if (atTop != _atTop) {
      setState(() {
        _atTop = atTop;
        if (atTop) _hasNew = false;
      });
    }
  }

  void _onLogChanged() {
    if (!mounted) return;
    if (_atTop) {
      setState(() {});
    } else if (!_hasNew) {
      setState(() => _hasNew = true);
    }
  }

  List<AppLogEntry> get _filtered {
    final entries = AppLog.entries;
    final filtered = _filter == null
        ? entries
        : entries.where((e) => e.level == _filter).toList();
    return filtered.reversed.toList();
  }

  Future<void> _share() async {
    final text = AppLog.formatText(_filtered);
    if (text.isEmpty) {
      HaoToast.show('无日志', message:  '没有可分享的日志');
      return;
    }
    try {
      final share = widget.onShare ?? _shareViaPlatform;
      await share(text);
    } catch (_) {
      if (!mounted) return;
      HaoToast.show('分享失败', message:  '无法打开分享');
    }
  }

  /// Default share backend: hands the filtered log text to the system
  /// share sheet as a .txt file via share_plus. (Proven against the
  /// real share_plus channel in a throwaway test: the plugin writes the
  /// file to the temp dir and invokes the share method with its path.)
  static Future<void> _shareViaPlatform(String text) async {
    await SharePlus.instance.share(
      ShareParams(files: [
        XFile.fromData(
          utf8.encode(text),
          name: 'hao-studio-log.txt',
          mimeType: 'text/plain',
        ),
      ]),
    );
  }

  Future<void> _clear() async {
    final ok = await showGlassConfirmDialog(
      context,
      title: '清空日志',
      content: '将删除全部日志记录，此操作无法恢复。',
      confirmLabel: '清空',
    );
    if (!ok || !mounted) return;
    await AppLog.clear();
    if (!mounted) return;
    setState(() => _hasNew = false);
    HaoToast.show('已清空', message:  '日志记录已清空');
  }

  void _jumpToTop() {
    _scrollController.animateTo(
      0,
      duration: const Duration(milliseconds: 250),
      curve: Curves.easeOut,
    );
    setState(() => _hasNew = false);
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    final filtered = _filtered;
    return Scaffold(
      appBar: AppBar(
        title: const Text('日志'),
        centerTitle: true,
        leadingWidth: 76,
        leading: TextButton(
          onPressed: () => Get.back(),
          child: Text(
            '完成',
            style: TextStyle(color: theme.accent, fontSize: 16),
          ),
        ),
        actions: [
          IconButton(
            icon: const Icon(Icons.delete_outline),
            tooltip: '清空日志',
            onPressed: _clear,
          ),
          IconButton(
            icon: const Icon(Icons.ios_share),
            tooltip: '分享日志',
            onPressed: _share,
          ),
        ],
      ),
      body: Stack(
        children: [
          Column(
            children: [
              _FilterBar(
                filter: _filter,
                onChanged: (filter) => setState(() => _filter = filter),
              ),
              Expanded(
                child: filtered.isEmpty
                    ? Center(
                        child: Text(
                          '无日志',
                          style: TextStyle(color: theme.textSecondary),
                        ),
                      )
                    : ListView.builder(
                        controller: _scrollController,
                        itemCount: filtered.length,
                        itemBuilder: (context, index) =>
                            _LogEntryCard(entry: filtered[index]),
                      ),
              ),
            ],
          ),
          if (_hasNew && !_atTop)
            Positioned(
              left: 0,
              right: 0,
              bottom: 16,
              child: Center(
                child: _NewLogPill(onTap: _jumpToTop),
              ),
            ),
        ],
      ),
    );
  }
}

/// Filter tabs: 全部 / DEBUG / INFO / WARN / ERROR in one pill bar
/// (Beans 日志 layout). Selected segment is the opaque surface.
class _FilterBar extends StatelessWidget {
  const _FilterBar({required this.filter, required this.onChanged});

  final AppLogLevel? filter;
  final ValueChanged<AppLogLevel?> onChanged;

  static const List<(String, AppLogLevel?)> _options = [
    ('全部', null),
    ('DEBUG', AppLogLevel.debug),
    ('INFO', AppLogLevel.info),
    ('WARN', AppLogLevel.warn),
    ('ERROR', AppLogLevel.error),
  ];

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      padding: const EdgeInsets.all(3),
      decoration: BoxDecoration(
        color: theme.surfaceStrong,
        borderRadius: BorderRadius.circular(HaoRadius.large),
        border: Border.all(color: theme.hairline),
      ),
      child: Row(
        children: _options.map((option) {
          final selected = filter == option.$2;
          return Expanded(
            child: GestureDetector(
              onTap: () => onChanged(option.$2),
              child: Container(
                padding: const EdgeInsets.symmetric(vertical: 7),
                decoration: BoxDecoration(
                  color: selected ? theme.surfaceSolid : Colors.transparent,
                  borderRadius: BorderRadius.circular(HaoRadius.standard),
                ),
                alignment: Alignment.center,
                child: Text(
                  option.$1,
                  style: TextStyle(
                    color:
                        selected ? theme.textPrimary : theme.textSecondary,
                    fontSize: 13,
                    fontWeight:
                        selected ? FontWeight.w600 : FontWeight.normal,
                  ),
                ),
              ),
            ),
          );
        }).toList(),
      ),
    );
  }
}

class _LogEntryCard extends StatelessWidget {
  const _LogEntryCard({required this.entry});

  final AppLogEntry entry;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 0, 16, 8),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: theme.surfaceStrong,
        borderRadius: BorderRadius.circular(HaoRadius.large),
        border: Border.all(color: theme.hairline),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _LevelBadge(level: entry.level),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  entry.message,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 14,
                    height: 1.4,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  AppLog.formatTime(entry.time),
                  style: TextStyle(
                    color: theme.textSecondary,
                    fontSize: 11,
                    fontFamily: 'monospace',
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

class _LevelBadge extends StatelessWidget {
  const _LevelBadge({required this.level});

  final AppLogLevel level;

  /// Semantic badge colours, same in every theme (INFO blue, DEBUG
  /// grey, WARN amber, ERROR red — theme.liveRed, the app's red).
  Color _color(HaoTheme theme) => switch (level) {
        AppLogLevel.debug => const Color(0xFF8E8E93),
        AppLogLevel.info => const Color(0xFF0A84FF),
        AppLogLevel.warn => const Color(0xFFFF9F0A),
        AppLogLevel.error => theme.liveRed,
      };

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: _color(HaoTheme.of(context)),
        borderRadius: BorderRadius.circular(HaoRadius.standard),
      ),
      child: Text(
        level.label,
        style: const TextStyle(
          color: Colors.white,
          fontSize: 11,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _NewLogPill extends StatelessWidget {
  const _NewLogPill({required this.onTap});

  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Material(
      color: Colors.transparent,
      child: HaoPressable(
        onTap: onTap,
        borderRadius: BorderRadius.circular(999),
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 8),
          decoration: BoxDecoration(
            color: theme.surfaceSolid,
            borderRadius: BorderRadius.circular(999),
            border: Border.all(color: theme.hairline),
          ),
          child: Text(
            '有新日志 · 回到顶部',
            style: TextStyle(color: theme.textPrimary, fontSize: 13),
          ),
        ),
      ),
    );
  }
}
