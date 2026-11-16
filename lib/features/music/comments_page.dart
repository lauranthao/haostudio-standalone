// Song comments page (chen 2026-11-17) — NetEase-style, two sections:
//
// - 精彩评论 on top: the highest-liked comments, merged across platforms.
// - 最新评论 below: the rest, newest first, with 加载更多 paging.
// The service already existed in MusicApi.comments (wy/tx/kg/kw fetchers
// + cross-platform aggregation); this page is the missing UI — fix 15
// removed the comments button from the track sheet, this adds it back
// as a 评论 row in the sheet that opens this page.
//
// All colours come from the active theme (HaoTheme), so the page follows
// all 4 themes in light and dark mode.

import 'package:flutter/material.dart';

import '../../core/theme/hao_themes.dart';
import '../../services/music/music_api.dart';
import '../../services/music/music_models.dart';
import 'widgets/music_image.dart';

/// Relative time for a comment timestamp (epoch ms, NetEase style).
String formatCommentTime(int epochMs) {
  if (epochMs <= 0) return '';
  final dt = DateTime.fromMillisecondsSinceEpoch(epochMs);
  final diff = DateTime.now().difference(dt);
  if (diff.inMinutes < 1) return '刚刚';
  if (diff.inHours < 1) return '${diff.inMinutes}分钟前';
  if (diff.inDays < 1) return '${diff.inHours}小时前';
  if (diff.inDays < 30) return '${diff.inDays}天前';
  return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-'
      '${dt.day.toString().padLeft(2, '0')}';
}

/// Like count: 93945 -> "9.4万", small counts stay raw.
String formatCommentLikes(int likes) {
  if (likes >= 10000) return '${(likes / 10000).toStringAsFixed(1)}万';
  return '$likes';
}

class SongCommentsPage extends StatefulWidget {
  const SongCommentsPage({super.key, required this.song, this.api});

  final Song song;

  /// Injected for tests; defaults to a real [MusicApi].
  final MusicApi? api;

  @override
  State<SongCommentsPage> createState() => _SongCommentsPageState();
}

class _SongCommentsPageState extends State<SongCommentsPage> {
  late final MusicApi _api;
  var _hot = <CommentItem>[];
  var _latest = <CommentItem>[];
  var _hasMore = false;
  var _loading = true;
  var _loadingMore = false;
  var _error = false;

  @override
  void initState() {
    super.initState();
    _api = widget.api ?? MusicApi();
    _loadInitial();
  }

  Future<void> _loadInitial() async {
    try {
      final r = await _api.comments(
        widget.song.songId,
        widget.song.platform,
        widget.song.title,
        widget.song.artist,
        0,
      );
      if (!mounted) return;
      setState(() {
        _hot = r.hot;
        _latest = r.latest;
        _hasMore = r.hasMore;
        _loading = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() {
        _error = true;
        _loading = false;
      });
    }
  }

  Future<void> _loadMore() async {
    if (_loadingMore || !_hasMore) return;
    setState(() => _loadingMore = true);
    try {
      final r = await _api.comments(
        widget.song.songId,
        widget.song.platform,
        widget.song.title,
        widget.song.artist,
        _latest.length,
      );
      if (!mounted) return;
      setState(() {
        _latest = [..._latest, ...r.latest];
        _hasMore = r.hasMore;
        _loadingMore = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _loadingMore = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('加载更多失败，稍后再试')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final theme = HaoTheme.of(context);
    return Scaffold(
      backgroundColor: theme.scaffoldBackground,
      appBar: AppBar(
        title: const Text('评论'),
        centerTitle: true,
      ),
      body: _loading
          ? Center(
              child: CircularProgressIndicator(color: theme.accent),
            )
          : _error
              ? Center(
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: [
                      Icon(
                        Icons.chat_bubble_outline,
                        size: 48,
                        color: theme.textMuted,
                      ),
                      const SizedBox(height: 12),
                      Text(
                        '评论加载失败',
                        style: TextStyle(color: theme.textSecondary),
                      ),
                      const SizedBox(height: 12),
                      TextButton(
                        onPressed: () {
                          setState(() {
                            _loading = true;
                            _error = false;
                          });
                          _loadInitial();
                        },
                        child: Text('重试', style: TextStyle(color: theme.accent)),
                      ),
                    ],
                  ),
                )
              : ListView.builder(
                  itemCount: _itemCount,
                  itemBuilder: (context, index) => _buildItem(index),
                ),
    );
  }

  /// 1 song header + (1 header + hot rows)? + (1 header + latest rows)?
  /// + 1 footer; when both lists are empty the second item is the empty
  /// note instead of sections.
  int get _itemCount {
    if (_hot.isEmpty && _latest.isEmpty) return 2;
    var n = 1;
    if (_hot.isNotEmpty) n += 1 + _hot.length;
    if (_latest.isNotEmpty) n += 1 + _latest.length;
    return n + 1;
  }

  Widget _buildItem(int index) {
    if (index == 0) return _songHeader();
    if (_hot.isEmpty && _latest.isEmpty) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 48),
        child: Center(
          child: Text(
            '暂无评论',
            style: TextStyle(color: HaoTheme.of(context).textMuted),
          ),
        ),
      );
    }
    var i = index - 1;
    if (_hot.isNotEmpty) {
      if (i == 0) return _sectionHeader('精彩评论', _hot.length);
      i -= 1;
      if (i < _hot.length) return _commentRow(_hot[i]);
      i -= _hot.length;
    }
    if (_latest.isNotEmpty) {
      if (i == 0) return _sectionHeader('最新评论', _latest.length);
      i -= 1;
      if (i < _latest.length) return _commentRow(_latest[i]);
      i -= _latest.length;
    }
    return _footer();
  }

  Widget _songHeader() {
    final theme = HaoTheme.of(context);
    final song = widget.song;
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 12, 16, 8),
      child: Row(
        children: [
          ClipRRect(
            borderRadius: BorderRadius.circular(10),
            child: song.cover.isEmpty
                ? Container(
                    width: 44,
                    height: 44,
                    color: theme.accentSoft,
                    child: Icon(Icons.music_note, color: theme.textMuted),
                  )
                : Image(
                    image: MusicImageProvider(song.cover),
                    width: 44,
                    height: 44,
                    fit: BoxFit.cover,
                    errorBuilder: (_, _, _) => Container(
                      width: 44,
                      height: 44,
                      color: theme.accentSoft,
                      child: Icon(Icons.music_note, color: theme.textMuted),
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
                  song.title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 15,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                Text(
                  song.artist,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    color: theme.textSecondary,
                    fontSize: 13,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _sectionHeader(String title, int count) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.fromLTRB(16, 16, 16, 4),
      child: Row(
        children: [
          Text(
            title,
            style: TextStyle(
              color: theme.textPrimary,
              fontSize: 16,
              fontWeight: FontWeight.w800,
            ),
          ),
          const SizedBox(width: 6),
          Text(
            '$count',
            style: TextStyle(color: theme.textMuted, fontSize: 13),
          ),
        ],
      ),
    );
  }

  Widget _commentRow(CommentItem c) {
    final theme = HaoTheme.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          _avatar(c),
          const SizedBox(width: 12),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        c.nick.isEmpty ? '匿名用户' : c.nick,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          color: theme.textPrimary,
                          fontWeight: FontWeight.w600,
                          fontSize: 14,
                        ),
                      ),
                    ),
                    Text(
                      formatCommentTime(c.time),
                      style: TextStyle(
                        color: theme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 4),
                Text(
                  c.content,
                  style: TextStyle(
                    color: theme.textPrimary,
                    fontSize: 14,
                    height: 1.5,
                  ),
                ),
                const SizedBox(height: 6),
                Row(
                  children: [
                    Icon(
                      Icons.thumb_up_outlined,
                      size: 14,
                      color: theme.textMuted,
                    ),
                    const SizedBox(width: 4),
                    Text(
                      formatCommentLikes(c.likes),
                      style: TextStyle(
                        color: theme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                    const SizedBox(width: 12),
                    Text(
                      c.platform.displayName,
                      style: TextStyle(
                        color: theme.textMuted,
                        fontSize: 12,
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                Divider(height: 1, color: theme.hairline),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _avatar(CommentItem c) {
    final theme = HaoTheme.of(context);
    final initial = c.nick.isEmpty ? '?' : c.nick[0];
    final fallback = Container(
      width: 36,
      height: 36,
      decoration: BoxDecoration(
        color: theme.accentSoft,
        shape: BoxShape.circle,
      ),
      alignment: Alignment.center,
      child: Text(
        initial,
        style: TextStyle(
          color: theme.textSecondary,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
    if (c.avatar.isEmpty) return fallback;
    return ClipOval(
      child: Image(
        image: MusicImageProvider(c.avatar),
        width: 36,
        height: 36,
        fit: BoxFit.cover,
        errorBuilder: (_, _, _) => fallback,
      ),
    );
  }

  Widget _footer() {
    final theme = HaoTheme.of(context);
    if (_loadingMore) {
      return Padding(
        padding: const EdgeInsets.symmetric(vertical: 20),
        child: Center(
          child: SizedBox(
            width: 24,
            height: 24,
            child: CircularProgressIndicator(
              color: theme.accent,
              strokeWidth: 2,
            ),
          ),
        ),
      );
    }
    if (_hasMore) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 24),
        child: OutlinedButton(
          onPressed: _loadMore,
          style: OutlinedButton.styleFrom(
            side: BorderSide(color: theme.accent),
            shape: RoundedRectangleBorder(
              borderRadius: BorderRadius.circular(20),
            ),
          ),
          child: Text('加载更多', style: TextStyle(color: theme.accent, fontWeight: FontWeight.w600)),
        ),
      );
    }
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Center(
        child: Text(
          '没有更多了',
          style: TextStyle(color: theme.textMuted, fontSize: 13),
        ),
      ),
    );
  }
}
